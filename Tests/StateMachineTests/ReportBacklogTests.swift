import StateMachine
import StateMachineTestSupport
import Testing
import os

// A `Shared` owner keeps at most one undelivered image of its retained completions: an image that a
// newer one supersedes before a held reconciliation handler lets the report queue move is replaced in
// place, so the payloads of completed work are not kept alive behind the handler, and the registration
// still receives the newest collection once the handler returns. Its report delivery and its batch
// drainer each detach their backlog in one installation, rather than taking one element per
// installation from a queue that the installed version still shares.

private typealias Core = RuntimeState<Int, Int>
private struct Refusal: Error {}
private let scope = RuntimeScopeID(kind: 1)

/// An operation's terminal value, whose release a test observes: operation 0 is refused, every other
/// one is admitted.
private final class Payload: Sendable {
    let ticket: RuntimeTicket
    let descriptor: Int
    init(_ work: RuntimeWork<Int>) {
        ticket = work.ticket
        descriptor = work.descriptor
    }
}

/// Weak references to every payload a driver made.
private final class Payloads: Sendable {
    private let made = OSAllocatedUnfairLock(initialState: [Int: WeakPayload]())
    func make(_ work: RuntimeWork<Int>) -> Payload {
        let payload = Payload(work)
        made.withLock { $0[work.descriptor] = WeakPayload(payload) }
        return payload
    }
    /// How many payloads other than operation 0's are still alive.
    var alive: Int { made.withLock { $0.filter { $0.key != 0 && $0.value.payload != nil }.count } }
}

/// A weak reference to a payload.
private struct WeakPayload: Sendable {
    weak var payload: Payload?
    init(_ payload: Payload) { self.payload = payload }
}

/// Holds the thread of the first handler call after `arm()` until the test opens it.
private final class HandlerHold: Sendable {
    private let gate = ThreadGate()
    private let armed = OSAllocatedUnfairLock(initialState: false)
    private let entered = AsyncStream<Void>.makeStream()
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { calls.withLock { $0 } }
    func arm() { armed.withLock { $0 = true } }
    func handle() {
        calls.withLock { $0 += 1 }
        guard armed.withLock({ exchange(&$0, with: false) }) else { return }
        entered.continuation.yield(())
        gate.wait()
    }
    func reached() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func open() { gate.open() }
}

/// The descriptors of the last collection a pending-completion registration received.
private final class LastImage: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (received: 0, descriptors: [Int]?.none))
    func receive(_ descriptors: [Int]) { state.withLock { $0 = ($0.received + 1, descriptors) } }
    var received: Int { state.withLock { $0.received } }
    var descriptors: [Int]? { state.withLock { $0.descriptors } }
}

/// The sizes an observer of `BacklogDetachment` was told, in order.
private final class Detachments: Sendable {
    private let sizes = OSAllocatedUnfairLock(initialState: [Int]())
    func record(_ size: Int) { sizes.withLock { $0.append(size) } }
    var all: [Int] { sizes.withLock { $0 } }
}

/// Waits, up to ten seconds, until `condition` holds.
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
}

private func start(_ descriptor: Int, kind: UInt32, on snapshot: Core.Snapshot) throws -> Core.Candidate {
    try Core.prepare(
        on: snapshot,
        next: descriptor,
        plan: .init(starts: [.init(.init(kind: kind, scope: scope), descriptor: descriptor)])
    )
}

@Suite(.timeLimit(.minutes(2))) struct ReportBacklogTests {
    private typealias Host = RuntimeSharedHost<Int, Int, Payload, Refusal>

    // With one pending-completion registration, A's explicit reconciliation is refused on a thread of
    // the test's own, whose handler holds it. Twelve more operations then start and commit one at a
    // time. Their payloads are released while the handler is still held, and once it returns the
    // registration's last collection is A's.
    @Test func completedPayloadsAreNotKeptAliveBehindAHeldHandler() async throws {
        let hold = HandlerHold()
        defer { hold.open() }
        let payloads = Payloads()
        let owner = Host(
            0,
            scopes: [scope],
            limits: try .init(commits: 3, descriptors: 2, executions: 2),
            policy: .manual,
            driver: { payloads.make($0) },
            ticket: { $0.ticket },
            prepare: { attempt in
                guard attempt.outcome.descriptor != 0 else { return .failure(.preparation(Refusal())) }
                let ticket = attempt.outcome.ticket
                return .success(
                    try! Core.prepare(
                        on: attempt.snapshot,
                        next: 100 + attempt.outcome.descriptor,
                        requiring: [ticket],
                        plan: .init(retire: [ticket], finishingClaims: [attempt.claim])
                    )
                )
            },
            reconciliationRequired: { _ in hold.handle() }
        )
        let image = LastImage()
        let subscription = try owner.subscribePending { image.receive($0.map(\.outcome.descriptor)) }
        _ = owner.commit(try start(0, kind: 1, on: owner.snapshot()))
        try await eventually { owner.pendingCompletions().first?.status == .reconciliationRequired }
        let id = try #require(owner.pendingCompletions().first?.id)
        let (finished, finishing) = AsyncStream<Void>.makeStream()
        hold.arm()
        runOnOwnThread {
            _ = owner.reconcile(id: id)
            finishing.yield(())
        }
        await hold.reached()
        for index in 1 ... 12 {
            guard case .committed = owner.commit(try start(index, kind: 2, on: owner.snapshot())) else {
                Issue.record("Expected start \(index) to be admitted")
                return
            }
            try await eventually { owner.snapshot().model == 100 + index }
            #expect(owner.snapshot().model == 100 + index)
        }
        try await eventually { payloads.alive == 0 }
        #expect(payloads.alive == 0, "\(payloads.alive) completed payloads alive while the handler is held")
        let before = image.received
        hold.open()
        var iterator = finished.makeAsyncIterator()
        _ = await iterator.next()
        try await eventually { image.received > before && image.descriptors == [0] }
        #expect(image.descriptors == [0])
        #expect(hold.count == 2)
        _ = owner.discardPending(id: id)
        subscription.cancel()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }

    // Every retained completion's explicit reconciliation is refused. The first is made on a thread of
    // the test's own, whose handler holds it while the rest are reconciled and queue their reports.
    // Once it returns, its delivery takes every queued report in one installation, at either size.
    @Test(arguments: [32, 128]) func aReportBacklogIsDetachedInOneInstallation(_ count: Int) async throws {
        let hold = HandlerHold()
        defer { hold.open() }
        let owner = RuntimeSharedHost<Int, Int, RuntimeTicket, Refusal>(
            0,
            scopes: [scope],
            limits: try .init(commits: count + 1, descriptors: 1, executions: count),
            policy: .manual,
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.preparation(Refusal())) },
            reconciliationRequired: { _ in hold.handle() }
        )
        let operation = RuntimeOperation(kind: 1, scope: scope, policy: .parallel(count))
        for index in 0 ..< count {
            let candidate = try Core.prepare(
                on: owner.snapshot(),
                next: index,
                plan: .init(starts: [.init(operation, descriptor: index, key: RuntimeKey(index))])
            )
            guard case .committed = owner.commit(candidate) else {
                Issue.record("Expected start \(index) to be admitted")
                return
            }
        }
        try await eventually {
            let pending = owner.pendingCompletions()
            return pending.count == count && pending.allSatisfy { $0.status == .reconciliationRequired }
        }
        let ids = owner.pendingCompletions().map(\.id)
        try #require(ids.count == count)
        let detachments = Detachments()
        let (finished, finishing) = AsyncStream<Void>.makeStream()
        hold.arm()
        runOnOwnThread {
            BacklogDetachment.$observe.withValue({ detachments.record($0) }) {
                _ = owner.reconcile(id: ids[0])
            }
            finishing.yield(())
        }
        await hold.reached()
        for id in ids.dropFirst() { _ = owner.reconcile(id: id) }
        hold.open()
        var iterator = finished.makeAsyncIterator()
        _ = await iterator.next()
        let sizes = detachments.all
        #expect(sizes.reduce(0, +) == count, "\(sizes)")
        #expect(sizes.count <= 3, "\(sizes)")
        #expect(hold.count == 2 * count)
        for id in ids { _ = owner.discardPending(id: id) }
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }

    // The batch drainer holds the first batch's emission while the test queues the rest. Once it
    // continues, it detaches the whole backlog in one installation and emits every batch in order.
    @Test(.parksCooperativeThread, arguments: [64, 256])
    func aBatchBacklogIsDetachedInOneInstallation(_ count: Int) async throws {
        let gate = ThreadGate()
        defer { gate.open() }
        let (entered, entering) = AsyncStream<Void>.makeStream()
        let emitted = OSAllocatedUnfairLock(initialState: [Int]())
        let owner = RuntimeSharedHost<Int, Int, RuntimeTicket, Refusal>(
            0,
            scopes: [scope],
            limits: try .init(commits: count + 1, descriptors: 1, executions: 1),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.preparation(Refusal())) },
            emit: { descriptor in
                emitted.withLock { $0.append(descriptor) }
                guard descriptor == 0 else { return }
                entering.yield(())
                gate.wait()
            }
        )
        func emission(_ index: Int) throws -> Core.Candidate {
            try Core.prepare(on: owner.snapshot(), next: index, plan: .init(emissions: [.init(index, position: 0)]))
        }
        let detachments = Detachments()
        try BacklogDetachment.$observe.withValue({ detachments.record($0) }) {
            _ = owner.commit(try emission(0))
        }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        for index in 1 ... count {
            guard case .committed = owner.commit(try emission(index)) else {
                Issue.record("Expected edit \(index) to be admitted")
                return
            }
        }
        gate.open()
        try await eventually { emitted.withLock { $0.count } == count + 1 }
        #expect(emitted.withLock { $0 } == Array(0 ... count))
        let sizes = detachments.all
        #expect(sizes.reduce(0, +) == count + 1, "\(sizes)")
        #expect(sizes.count <= 3, "\(sizes)")
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }
}
