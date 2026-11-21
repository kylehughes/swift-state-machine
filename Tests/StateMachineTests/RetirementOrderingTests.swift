import Combine
import StateMachine
import Testing

// A confined owner retains what a change may displace until the change is complete, then releases it.
// These tests check that every path releases what it retained, that a release which ends a
// registration keeps that registration from receiving anything more, and that a registration ended
// by its own callback, or by its owner's release, receives nothing after that.

/// Runs its action when it is destroyed.
private final class Sentinel {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    deinit { action() }
}

/// Runs its action when it is destroyed, from whichever context releases it.
private final class SendableSentinel: Sendable {
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    deinit { action() }
}

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// A value any thread can replace and read.
private final class Shared<Value: Sendable>: Sendable {
    private let storage: AtomicRecordStorage<Value>
    init(_ value: Value) { storage = AtomicRecordStorage(value) }
    var value: Value { storage.load().value }
    func update(_ change: (inout Value) -> Void) {
        while true {
            let before = storage.load()
            var after = before.value
            change(&after)
            if storage.install(.init(after), replacing: before) { return }
        }
    }
}

/// The number of change records a confined host retains now.
///
/// Each is released once its change is complete, so an idle host retains none.
private func retainedRecords(of host: Any) -> Int {
    // A main-actor host keeps its confined values, the change records among them, in one object.
    let children = Mirror(reflecting: host).children
    let holder = children.first { $0.label == "confined" }.map { Mirror(reflecting: $0.value).children } ?? children
    guard let records = holder.first(where: { $0.label == "displaced" }) else {
        Issue.record("The host keeps no displaced change records")
        return -1
    }
    return Mirror(reflecting: records.value).children.count
}

private enum Failure: Error { case rejected }

private let scope = RuntimeScopeID(kind: 1)
private let operation = RuntimeOperation(kind: 0, scope: scope)

/// A terminal outcome carrying a value whose destructor runs a test's action.
private struct Parked {
    let ticket: RuntimeTicket
    let sentinel: Sentinel?
}

/// A `Sendable` terminal outcome carrying a value whose destructor runs a test's action.
private struct SendableParked: Sendable {
    let ticket: RuntimeTicket
    let sentinel: SendableSentinel?
}

private typealias MainHost = RuntimeMainActorHost<Int, Int, Parked, Never>
private typealias Engine = RuntimeState<Int, Int>

/// The sentinel the next driver call returns in its outcome.
@MainActor private final class OutcomeSource {
    var next: (() -> Sentinel)?
    func take() -> Sentinel? {
        defer { next = nil }
        return next?()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorRetirementTests {
    private let outcomes = OutcomeSource()
    private let parked = Signal()

    // Every outcome is refused, so a delivered outcome stays parked until the owner disposes it.
    private func makeHost() -> MainHost {
        let outcomes = outcomes
        let parked = parked
        return MainHost(
            0,
            scopes: [scope],
            driver: { work in Parked(ticket: work.ticket, sentinel: outcomes.take()) },
            ticket: { $0.ticket },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
            reconciliationRequired: { _ in parked.raise() }
        )
    }

    private func park(on owner: MainHost, _ sentinel: (() -> Sentinel)? = nil) async throws -> RuntimePendingID {
        outcomes.next = sentinel
        let plan = Engine.Plan(starts: [.init(operation, descriptor: 0)])
        _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: 0, plan: plan))
        await parked.wait()
        return try #require(owner.pendingCompletions().first).id
    }

    @Test func reconcilingASettledCompletionRetainsNothing() async throws {
        let owner = makeHost()
        let id = try await park(on: owner)
        guard case .discarded(let settled) = owner.discardPending(id: id) else { throw Failure.rejected }
        #expect(await owner.flush(through: settled))
        #expect(retainedRecords(of: owner) == 0)
        for _ in 0 ..< 64 {
            guard case .notPending = owner.reconcile(id: id) else { throw Failure.rejected }
        }
        #expect(retainedRecords(of: owner) == 0)
        await owner.shutdown()
    }

    // B registers first. A discards the only completion while it is offered its first collection, and
    // releasing the collection that held the completion ends B, so B is not offered the empty one.
    @Test func releasingAnOfferedCollectionKeepsTheRegistrationItEndsFromTheNextOffer() async throws {
        let owner = makeHost()
        var trace: [String] = []
        var b: MainActorSnapshotSubscription?
        _ = try await park(on: owner) {
            Sentinel {
                trace.append("ended B")
                b?.cancel()
            }
        }
        b = try owner.subscribePending { trace.append("B\($0.count)") }
        weak let host = owner
        let a = try owner.subscribePending { rows in
            trace.append("A\(rows.count)")
            if let first = rows.first { _ = host?.discardPending(id: first.id) }
        }
        #expect(trace == ["B1", "A1", "ended B", "A0"])
        a.cancel()
        await owner.shutdown()
    }
}

/// The actor that owns an isolated host whose refused outcomes stay parked.
private actor IsolatedBench {
    typealias Host = RuntimeIsolatedHost<IsolatedBench, Int, Int, Parked, Never>
    private var host: Host!
    private var outcome: (() -> Sentinel)?
    private let parked = Signal()
    private var trace: [String] = []
    private var b: IsolatedSnapshotSubscription<IsolatedBench>?

    init() async {
        let parked = parked
        host = Host(
            0,
            scopes: [scope],
            isolation: self,
            driver: { bench, work in Parked(ticket: work.ticket, sentinel: bench.takeOutcome()) },
            ticket: { $0.ticket },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
            reconciliationRequired: { _ in parked.raise() }
        )
    }

    private func takeOutcome() -> Sentinel? {
        defer { outcome = nil }
        return outcome?()
    }

    private func park(_ sentinel: (() -> Sentinel)? = nil) async throws -> RuntimePendingID {
        outcome = sentinel
        let plan = Engine.Plan(starts: [.init(operation, descriptor: 0)])
        _ = host.commit(try Engine.prepare(on: host.snapshot(isolation: self), next: 0, plan: plan), isolation: self)
        await parked.wait()
        return try #require(host.pendingCompletions(isolation: self).first).id
    }

    /// Returns the records retained after settling a completion, and after reconciling it 64 times.
    func reconcileSettled() async throws -> (settled: Int, reconciled: Int) {
        let id = try await park()
        guard case .discarded(let settled) = host.discardPending(id: id, isolation: self) else {
            throw Failure.rejected
        }
        _ = await host.flush(through: settled, isolation: self)
        let before = retainedRecords(of: host!)
        for _ in 0 ..< 64 {
            guard case .notPending = host.reconcile(id: id, isolation: self) else { throw Failure.rejected }
        }
        return (before, retainedRecords(of: host!))
    }

    /// Returns what two pending-completion registrations observed when A discards during its first collection.
    func discardDuringASecondRegistration() async throws -> [String] {
        _ = try await park {
            Sentinel {
                self.trace.append("ended B")
                self.b?.cancel(isolation: self)
            }
        }
        b = try host.subscribePending({ self.trace.append("B\($0.count)") }, isolation: self)
        let a = try host.subscribePending(
            { rows in
                self.trace.append("A\(rows.count)")
                if let first = rows.first { _ = self.host.discardPending(id: first.id, isolation: self) }
            },
            isolation: self
        )
        a.cancel()
        return trace
    }

    func shutdown() async { await host.shutdown(isolation: self) }
}

@Suite(.timeLimit(.minutes(1))) struct IsolatedRetirementTests {
    @Test func reconcilingASettledCompletionRetainsNothing() async throws {
        let bench = await IsolatedBench()
        let (settled, reconciled) = try await bench.reconcileSettled()
        #expect(settled == 0 && reconciled == 0)
        await bench.shutdown()
    }

    @Test func releasingAnOfferedCollectionKeepsTheRegistrationItEndsFromTheNextOffer() async throws {
        let bench = await IsolatedBench()
        #expect(try await bench.discardDuringASecondRegistration() == ["B1", "A1", "ended B", "A0"])
        await bench.shutdown()
    }
}

private typealias ActorHost = RuntimeActorHost<Int, Int, SendableParked, Never>

extension RuntimeActorHost {
    /// The number of change records this host retains now, read in its own turn.
    fileprivate func retainedRecordCount() -> Int { retainedRecords(of: self) }
}

@Suite(.timeLimit(.minutes(1))) struct ActorRetirementTests {
    private func makeHost(parked: Signal, outcome: Shared<SendableSentinel?>) -> ActorHost {
        ActorHost(
            0,
            scopes: [scope],
            driver: { work in
                var sentinel: SendableSentinel?
                outcome.update { swap(&sentinel, &$0) }
                return SendableParked(ticket: work.ticket, sentinel: sentinel)
            },
            ticket: { $0.ticket },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
            reconciliationRequired: { _ in parked.raise() }
        )
    }

    private func park(on owner: ActorHost, _ parked: Signal) async throws -> RuntimePendingID {
        let plan = Engine.Plan(starts: [.init(operation, descriptor: 0)])
        _ = await owner.commit(try Engine.prepare(on: await owner.snapshot(), next: 0, plan: plan))
        await parked.wait()
        return try #require(await owner.pendingCompletions().first).id
    }

    @Test func reconcilingASettledCompletionRetainsNothing() async throws {
        let parked = Signal()
        let owner = makeHost(parked: parked, outcome: Shared(nil))
        let id = try await park(on: owner, parked)
        guard case .discarded(let settled) = await owner.discardPending(id: id) else { throw Failure.rejected }
        #expect(await owner.flush(through: settled))
        #expect(await owner.retainedRecordCount() == 0)
        for _ in 0 ..< 64 {
            guard case .notPending = await owner.reconcile(id: id) else { throw Failure.rejected }
        }
        #expect(await owner.retainedRecordCount() == 0)
        await owner.shutdown()
    }

    @Test func releasingAnOfferedCollectionKeepsTheRegistrationItEndsFromTheNextOffer() async throws {
        let parked = Signal()
        let trace = Shared<[String]>([])
        let b = Shared<SnapshotSubscription?>(nil)
        let outcome = Shared<SendableSentinel?>(
            SendableSentinel {
                trace.update { $0.append("ended B") }
                b.value?.cancel()
            }
        )
        let owner = makeHost(parked: parked, outcome: outcome)
        _ = try await park(on: owner, parked)
        let registered = try await owner.subscribePending { rows in trace.update { $0.append("B\(rows.count)") } }
        b.update { $0 = registered }
        let a = try await owner.subscribePending { [weak owner] rows in
            trace.update { $0.append("A\(rows.count)") }
            guard let owner, let first = rows.first else { return }
            _ = owner.assumeIsolated { $0.discardPending(id: first.id) }
        }
        #expect(trace.value == ["B1", "A1", "ended B", "A0"])
        a.cancel()
        await owner.shutdown()
    }
}

@Suite(.timeLimit(.minutes(1))) struct SharedFinishTests {
    private func makeHost() throws -> RuntimeSharedHost<Int, Int, RuntimeTicket, Never> {
        RuntimeSharedHost(
            0,
            scopes: [],
            limits: try Limits(),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
    }

    // The registration's callbacks are released once its last delivery has returned, which is when
    // a finish would already have run.
    @Test func aSubscriptionCancelledByItsClosedSnapshotDoesNotFinish() async throws {
        let owner = try makeHost()
        let finishes = Shared(0)
        let released = Signal()
        let token = Shared<SnapshotSubscription?>(nil)
        do {
            let marker = SendableSentinel { released.raise() }
            let registered = try owner.subscribe(
                { snapshot in
                    withExtendedLifetime(marker) {}
                    if snapshot.isClosed { token.value?.cancel() }
                },
                onFinish: { finishes.update { $0 += 1 } }
            )
            token.update { $0 = registered }
        }
        _ = owner.close()
        await released.wait()
        #expect(finishes.value == 0)
        #expect(token.value != nil)
    }

    // The first collection is delivered before closing, so the callback that cancels receives the final one.
    @Test func aPendingSubscriptionCancelledByItsFinalCollectionDoesNotFinish() async throws {
        let owner = try makeHost()
        let finishes = Shared(0)
        let seeded = Signal()
        let released = Signal()
        let token = Shared<SnapshotSubscription?>(nil)
        let deliveries = Shared(0)
        do {
            let marker = SendableSentinel { released.raise() }
            let registered = try owner.subscribePending(
                { _ in
                    withExtendedLifetime(marker) {}
                    deliveries.update { $0 += 1 }
                    if deliveries.value == 1 { seeded.raise() } else { token.value?.cancel() }
                },
                onFinish: { finishes.update { $0 += 1 } }
            )
            token.update { $0 = registered }
        }
        await seeded.wait()
        _ = owner.close()
        await released.wait()
        #expect(deliveries.value == 2)
        #expect(finishes.value == 0)
        #expect(token.value != nil)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PublisherAttachmentTests {
    // The owner is released before any subscriber exists, so no demand ever covered its seed.
    @Test func aSubscriberAttachingAfterAnOpenOwnerIsReleasedReceivesOnlyTheFinish() async throws {
        var owner: RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>? = RuntimeMainActorHost(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let publisher = try #require(owner).snapshotPublisher { $0.revision }
        weak let released = owner
        owner = nil
        #expect(released == nil)
        var values: [UInt64] = []
        let finished = Signal()
        let sink = publisher.sink(receiveCompletion: { _ in finished.raise() }, receiveValue: { values.append($0) })
        await finished.wait()
        #expect(values.isEmpty)
        sink.cancel()
    }

    // Closing promises the closed snapshot, so a subscriber attaching after the owner is released
    // still receives it.
    @Test func aSubscriberAttachingAfterAClosedOwnerIsReleasedReceivesTheClosedSnapshot() async throws {
        var owner: RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>? = RuntimeMainActorHost(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let publisher = try #require(owner).snapshotPublisher { $0.revision }
        let closed = try #require(owner).close()
        #expect(try await #require(owner).flush(through: closed))
        weak let released = owner
        owner = nil
        #expect(released == nil)
        var values: [UInt64] = []
        let finished = Signal()
        let sink = publisher.sink(receiveCompletion: { _ in finished.raise() }, receiveValue: { values.append($0) })
        await finished.wait()
        #expect(values == [closed.revision])
        sink.cancel()
    }
}
