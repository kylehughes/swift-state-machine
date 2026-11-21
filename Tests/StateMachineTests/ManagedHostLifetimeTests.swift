import StateMachine
import Testing
import os

private typealias Engine = RuntimeState<Int, Int>
private typealias Ledger = RuntimeDeliveryLedger<Int, Int, RuntimeTicket, Never>
private typealias SharedHost = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>
private typealias ActorHost = RuntimeActorHost<Int, Int, RuntimeTicket, Never>

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

/// Drivers that stay suspended until the test releases them.
private actor HeldDrivers {
    private var held: [(RuntimeTicket, CheckedContinuation<RuntimeTicket, Never>)] = []
    private var released = false
    let starts: AsyncStream<RuntimeTicket>
    private let started: AsyncStream<RuntimeTicket>.Continuation

    init() { (starts, started) = AsyncStream.makeStream() }
    func run(_ work: RuntimeWork<Int>) async -> RuntimeTicket {
        if released { return work.ticket }
        return await withCheckedContinuation {
            held.append((work.ticket, $0))
            started.yield(work.ticket)
        }
    }
    func releaseAll() {
        released = true
        let prior = held
        held = []
        for (ticket, continuation) in prior { continuation.resume(returning: ticket) }
    }
}

extension RuntimeActorHost where Model == Int, Descriptor == Int {
    /// Accepts two batches in one actor turn, so one drain turn processes both.
    fileprivate func advanceTwice() throws -> Engine.Snapshot {
        _ = commit(try Engine.prepare(on: snapshot(), next: snapshot().model + 1))
        _ = commit(try Engine.prepare(on: snapshot(), next: snapshot().model + 1))
        return snapshot()
    }
}

@Suite(.timeLimit(.minutes(1))) struct ManagedHostLifetimeTests {
    private let scope = RuntimeScopeID(kind: 1)

    private func starting(_ snapshot: Engine.Snapshot) throws -> Engine.Candidate {
        try Engine.prepare(
            on: snapshot,
            next: 1,
            plan: .init(starts: [.init(.init(kind: 1, scope: scope), descriptor: 1)])
        )
    }

    private static func terminal(_ attempt: Ledger.Attempt) -> Ledger.Preparation {
        .success(
            try! Engine.prepare(
                on: attempt.snapshot,
                next: 42,
                requiring: [attempt.outcome],
                plan: .init(retire: [attempt.outcome], finishingClaims: [attempt.claim])
            )
        )
    }

    @Test func aCallbackSubscriptionCancelledInsideItsCallbackBeginsNoLaterCallback() async throws {
        let owner = ActorHost(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let token = OSAllocatedUnfairLock<SnapshotSubscription?>(initialState: nil)
        let received = OSAllocatedUnfairLock(initialState: [UInt64]())
        let subscription = try await owner.subscribe { snapshot in
            received.withLock { $0.append(snapshot.revision) }
            if snapshot.revision == 1 { token.withLock { $0 }?.cancel() }
        }
        token.withLock { $0 = subscription }
        // Revisions 1 and 2 are queued together, so one drain turn reaches 2 right after the cancel.
        let last = try await owner.advanceTwice()
        #expect(await owner.flush(through: last))
        #expect(received.withLock { $0 } == [0, 1])
        #expect(await owner.subscriberCount == 0)
        _ = await owner.close()
        await owner.shutdown()
    }

    @Test func cancellingAnActorRegistrationFreesItsSlotBeforeTheNextRegistration() async throws {
        let owner = ActorHost(
            0,
            scopes: [],
            configuration: try ManagedConfiguration(subscribers: 1),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        for _ in 0 ..< 3 {
            let token = try await owner.subscribe { _ in }
            token.cancel()
            #expect(await owner.subscriberCount == 0)
        }
        _ = await owner.close()
        await owner.shutdown()
    }

    @Test func releasingAnOpenSharedOwnerFinishesItsCallbackSubscribers() async throws {
        let seeded = Signal()
        let finished = Signal()
        let received = OSAllocatedUnfairLock(initialState: [Bool]())
        var owner: SharedHost? = SharedHost(
            manual: 0,
            scopes: [],
            limits: try Limits(),
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let token = try #require(owner)
            .subscribe(
                { snapshot in
                    received.withLock { $0.append(snapshot.isClosed) }
                    seeded.raise()
                },
                onFinish: { finished.raise() }
            )
        await seeded.wait()
        owner = nil
        // An owner released without closing finishes the registration without a closed snapshot.
        await finished.wait()
        #expect(received.withLock { $0 } == [false])
        token.cancel()
    }

    @Test func aSharedOwnerReportsRunningWorkersSynchronously() async throws {
        let drivers = HeldDrivers()
        let owner = SharedHost(
            0,
            scopes: [scope],
            limits: try Limits(),
            driver: { await drivers.run($0) },
            ticket: { $0 },
            prepare: { Self.terminal($0) }
        )
        let counts = OSAllocatedUnfairLock(initialState: [Int]())
        let observed = Signal()
        // A synchronous callback can read the count alongside the snapshot it receives.
        let token = try owner.subscribe { snapshot in
            guard snapshot.model == 42, !snapshot.isClosed else { return }
            counts.withLock { $0.append(owner.runningCount) }
            observed.raise()
        }
        #expect(owner.runningCount == 0)
        _ = owner.commit(try starting(owner.snapshot()))
        var starts = drivers.starts.makeAsyncIterator()
        _ = await starts.next()
        #expect(owner.runningCount == 1)
        await drivers.releaseAll()
        await observed.wait()
        // The worker left the coordinator before its outcome committed.
        #expect(counts.withLock { $0 } == [0])
        _ = owner.close()
        await owner.shutdown()
        #expect(owner.runningCount == 0)
        token.cancel()
    }

    private enum RetryEvent: Sendable {
        case parked(Ledger.Pending)
        case overran
    }

    @Test func pureConflictRetriesContinueAcrossTurnsThenParkForReconciliation() async throws {
        let preparations = OSAllocatedUnfairLock(initialState: 0)
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let conflict = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let (events, event) = AsyncStream<RetryEvent>.makeStream()
        let owner = SharedHost(
            0,
            scopes: [scope],
            limits: try Limits(commits: 256),
            policy: .retry,
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { attempt in
                let count = preparations.withLock {
                    $0 += 1
                    return $0
                }
                let candidate = Self.terminal(attempt)
                // Every preparation loses to a concurrent unrelated commit, until the test gives up.
                if count <= 100 { conflict.withLock { $0 }?() } else if count == 101 { event.yield(.overran) }
                return candidate
            },
            reconciliationRequired: { pending in
                notifications.withLock { $0 += 1 }
                event.yield(.parked(pending))
            }
        )
        conflict.withLock {
            $0 = { _ = owner.commit(try! Engine.prepare(on: owner.snapshot(), next: owner.snapshot().model + 1)) }
        }
        _ = owner.commit(try starting(owner.snapshot()))
        var iterator = events.makeAsyncIterator()
        guard case .parked(let pending) = await iterator.next() else {
            Issue.record("Pure conflict retries continued without bound")
            conflict.withLock { $0 = nil }
            _ = owner.close()
            await owner.shutdown()
            return
        }
        // Sixteen turns of four preparations each.
        #expect(preparations.withLock { $0 } == 64)
        #expect(pending.attempts == 64)
        #expect(pending.status == .reconciliationRequired)
        guard case .admission(.conflict) = pending.lastRejection else {
            Issue.record("A parked retry must report its root conflict")
            return
        }
        #expect(owner.pendingCompletions().first?.status == .reconciliationRequired)
        conflict.withLock { $0 = nil }
        guard case .committed(let snapshot) = owner.reconcile(id: pending.id) else {
            Issue.record("Explicit reconciliation did not commit the parked outcome")
            return
        }
        #expect(snapshot.model == 42)
        #expect(notifications.withLock { $0 } == 1)
        _ = owner.close()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(5))) == nil)
        event.finish()
    }
}
