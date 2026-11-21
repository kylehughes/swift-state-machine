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
    @Test func observingManyOwnersWithParkedRegistrationsExaminesAFewAttemptsEach() async {
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
        for host in hosts { await host.release() }
        for observation in observations { await observation.value }
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
}
