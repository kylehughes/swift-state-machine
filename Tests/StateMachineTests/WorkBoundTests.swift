import Combine
import StateMachine
import StateMachineUI
import Testing

// Work that grows with the number of registrations or reports stays within a bound linear in what each
// step has to handle, counted by the work the step reports rather than by the time it takes.

private typealias RawHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// A `MainActor` host of the test's own that admits every registration and delivers its snapshot.
@MainActor private final class OpenHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Mark
    struct Receipt: StateMachineReceipt {
        let snapshot: Mark
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    func snapshot() -> Mark { Mark(revision: 1) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Mark) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        receive(Mark(revision: 1))
        return MainActorSnapshotSubscription {}
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Mark(revision: 1)) }
}

/// An actor owner whose registration call parks until the test releases it, and then refuses.
private actor ParkedHost: ActorStateMachineHost {
    typealias Snapshot = Mark
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let entered: AsyncStream<Void>.Continuation

    init(entered: AsyncStream<Void>.Continuation) { self.entered = entered }

    func snapshot() -> Mark { Mark(revision: 0) }
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Mark> {
        entered.yield(())
        if !released { await withCheckedContinuation { parked.append($0) } }
        throw .capacityExceeded
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Mark) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        throw .capacityExceeded
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Mark) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        throw .capacityExceeded
    }
    func release() {
        released = true
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct WorkBoundTests {
    // A presentation observes many different actor owners in turn, and each owner keeps its
    // registration call parked, so every earlier attempt still holds its slot when the next observation
    // asks whether it must wait. None of them is related to the next, and the presentation finds that
    // without examining them: each observation examines a few attempts and serial positions, not every
    // earlier attempt, which would add up to about half the square of their number.
    //
    // The registration calls then return, oldest first or newest first, and removing each returned
    // attempt examines and moves a few serials, not every later one.
    @Test(arguments: [false, true])
    func observingManyOwnersWithParkedRegistrationsExaminesAFewAttemptsEach(newestFirst: Bool) async {
        let count = 400
        let presentation = SnapshotObservableObject(Mark(revision: 0))
        let (entered, entering) = AsyncStream<Void>.makeStream()
        var arrivals = entered.makeAsyncIterator()
        var hosts: [ParkedHost] = []
        var observations: [Task<Void, Never>] = []
        for _ in 0 ..< count {
            let host = ParkedHost(entered: entering)
            hosts.append(host)
            observations.append(Task { @MainActor in try? await presentation.observe(host) })
            _ = await arrivals.next()
        }
        let examined = presentation.examinedRegistrationAttempts
        #expect(examined <= count * 40, "\(examined)")
        for host in newestFirst ? hosts.reversed() : hosts {
            await host.release()
            // Each call returns and its attempt is removed before the next host is released.
            await Task.yield()
        }
        for observation in observations { await observation.value }
        let returned = presentation.examinedRegistrationAttempts - examined
        #expect(returned <= count * 40, "\(returned)")
        #expect(!presentation.isObserving)
    }

    // Creating and resetting an owner activates each of its scopes once, in order, and keeps the first
    // of a repeated key. Each key is examined once against the keys already kept, rather than against
    // each of them, which would add up to about half the square of their number.
    @Test func activatingManyScopesExaminesEachKeyOnce() throws {
        let markers = (0 ..< 1_000).map { _ in RuntimeIdentity() }
        let distinct =
            markers.map { RuntimeScopeID(kind: 1, instance: $0) }
            + (0 ..< 1_000).map { RuntimeScopeID(kind: UInt32($0 + 2)) }
        let keys = distinct + distinct.prefix(10)
        var examined = 0
        #expect(RuntimeState<Int, Int>.distinctScopeKeys(keys, examined: &examined) == distinct)
        #expect(examined == keys.count)
        var engine = RuntimeState<Int, Int>(0, scopes: keys, limits: try .init())
        guard case .committed = engine.reset(1, scopes: keys) else {
            Issue.record("Expected the reset to be accepted")
            return
        }
    }
    // From the report that an observation is live, the presentation's callback starts and stops an
    // observation many times, which queues two reports each time; they are made in order once the
    // callback returns.
    @Test func manyReportsQueuedFromOneCallbackAreMadeInOrder() throws {
        let count = 2_000
        let host = OpenHost()
        let presentation = SnapshotObservableObject(Mark(revision: 0))
        var reported: [Bool] = []
        var armed = true
        let watch = presentation.$isObserving.dropFirst()
            .sink { live in
                reported.append(live)
                guard live, armed else { return }
                armed = false
                for _ in 0 ..< count {
                    try? presentation.observe(host)
                    presentation.stopObserving()
                }
            }
        try presentation.observe(host)
        var expected = [true, false]
        for _ in 0 ..< count { expected += [true, false] }
        #expect(reported == expected)
        withExtendedLifetime(watch) {}
    }

    // The queue of reports takes each report once, also while more are queued as it is drained, so a
    // million reports, half of them queued during the drain, come out in the order they went in, and
    // reclaiming the storage of the reports taken moves fewer reports than there are.
    @Test func theReportQueueTakesEachReportOnce() {
        var queue = PendingReports()
        let count = 1_000_000
        for index in 0 ..< count / 2 { queue.append(index % 3 == 0) }
        var taken = 0
        var mismatches = 0
        var next = count / 2
        while let report = queue.first {
            if report != (taken % 3 == 0) { mismatches += 1 }
            queue.removeFirst()
            taken += 1
            if next < count {
                queue.append(next % 3 == 0)
                next += 1
            }
        }
        #expect(taken == count)
        #expect(mismatches == 0)
        #expect(queue.count == 0)
        #expect(queue.moved < count, "\(queue.moved)")
    }

    // A transition into a phase with many scopes activates each once and removes as many others, in
    // one pass over the edits and one over the scopes held, rather than a scan of both for each edit.
    @Test func editingManyScopesExaminesEachOnce() throws {
        let count = 2_000
        let held = (0 ..< count).map { RuntimeScopeID(kind: UInt32($0 + 1)) }
        let activated = (0 ..< count).map { _ in RuntimeScopeID(kind: 0, instance: RuntimeIdentity()) }
        let edits =
            activated.map { RuntimeState<Int, Int>.ScopeEdit.activate($0) }
            + held.prefix(count / 2).map { .remove($0) }
        var examined = 0
        let result = try #require(
            RuntimeState<Int, Int>.applying(edits, to: held, key: { $0 }, activating: { $0 }, examined: &examined)
        )
        #expect(result == Array(held.suffix(count / 2)) + activated)
        #expect(examined == edits.count + held.count)
        var repeated = 0
        #expect(
            RuntimeState<Int, Int>
                .applying(
                    [.activate(held[0]), .remove(held[0])],
                    to: held,
                    key: { $0 },
                    activating: { $0 },
                    examined: &repeated
                ) == nil
        )
        let engine = RuntimeState<Int, Int>(0, scopes: held, limits: try .init())
        _ = try RuntimeState<Int, Int>.prepare(on: engine.snapshot, next: 1, plan: .init(scopes: edits))
    }

    // With many operations active, an edit that keeps every scope and ticket examines each operation,
    // reservation, and key a few times, not each operation against every other.
    @Test func anUnrelatedEditWithManyActiveOperationsIsLinear() throws {
        let count = 1_000
        let scope = RuntimeScopeID(kind: 1)
        var engine = RuntimeState<Int, Int>(
            0,
            scopes: [scope],
            limits: try .init(commits: count + 1, descriptors: 1, executions: count)
        )
        let operation = RuntimeOperation(kind: 1, scope: scope, policy: .parallel(count))
        for index in 0 ..< count {
            let candidate = try RuntimeState<Int, Int>
                .prepare(
                    on: engine.snapshot,
                    next: index,
                    plan: .init(starts: [.init(operation, descriptor: index, key: RuntimeKey(index))])
                )
            guard case .committed = engine.commit(candidate) else {
                Issue.record("Expected start \(index) to be admitted")
                return
            }
        }
        let before = engine.admissionWork
        guard case .committed = engine.commit(try RuntimeState<Int, Int>.prepare(on: engine.snapshot, next: -1)) else {
            Issue.record("Expected the edit to be admitted")
            return
        }
        let work = engine.admissionWork - before
        #expect(work <= 8 * count, "\(work)")
    }

    // Draining a backlog of batches one at a time moves a number of queued batches linear in the
    // backlog, and releases each batch's snapshot once it is transferred.
    @Test func drainingABacklogMovesALinearNumberOfBatches() throws {
        let count = 4_000
        var engine = RuntimeState<Box, Int>(Box(-1), limits: try .init(commits: count))
        weak var first: Box?
        for index in 0 ..< count {
            let box = Box(index)
            if index == 0 { first = box }
            let candidate = try RuntimeState<Box, Int>
                .prepare(
                    on: engine.snapshot,
                    next: box,
                    plan: .init(emissions: [.init(index, position: 0)])
                )
            guard case .committed = engine.commit(candidate) else {
                Issue.record("Expected edit \(index) to be admitted")
                return
            }
        }
        var drained: [Int] = []
        for _ in 0 ..< count {
            for batch in engine.drain(limit: 1) {
                for command in batch.commands { if case .emit(let value) = command { drained.append(value) } }
            }
            if drained.count == 1 { #expect(first == nil) }
        }
        #expect(drained == Array(0 ..< count))
        #expect(engine.queueMoves <= count, "\(engine.queueMoves)")
    }
}

/// A model whose release a test observes.
private final class Box: Sendable {
    let value: Int
    init(_ value: Int) { self.value = value }
}
