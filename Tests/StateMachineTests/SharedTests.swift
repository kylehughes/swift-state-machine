import Dispatch
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

private final class SharedCallbackLifetime: Sendable {
    let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

@Suite(.timeLimit(.minutes(1))) struct SharedTests {
    private typealias Flow = ReferenceProfile

    private func owner(configuration: Flow.Configuration = .default) throws -> Flow.Shared {
        Flow.Shared(.init(userID: try UserID("kyle")), configuration: configuration)
    }

    @Test func competingCandidatesCommitExactlyOneWholeRoot() async throws {
        let shared = try owner()
        let before = shared.snapshot()
        let results = await withTaskGroup(of: Flow.CommitResult.self) { group in
            for label in ["first", "second"] {
                group.addTask { shared.commit(before.presentationChanged(label)) }
            }
            var results: [Flow.CommitResult] = []
            for await result in group { results.append(result) }
            return results
        }
        let accepted = results.compactMap { result -> Flow.Receipt? in
            if case .committed(let receipt) = result { return receipt }
            return nil
        }
        let rejected = results.compactMap { result -> Flow.CommitRejection? in
            if case .rejected(let reason, let current) = result {
                #expect(current.ordinal == 1)
                #expect(current.model == before.model)
                return reason
            }
            return nil
        }
        #expect(accepted.count == 1)
        #expect(rejected == [.conflict])
        let winner = try #require(accepted.first)
        #expect(shared.snapshot().presentation == winner.snapshot.presentation)
        #expect(shared.snapshot().ordinal == 1)
        #expect(shared.drainCommands(limit: 10).map(\.receipt.ordinal) == [1])
        #expect(before.ordinal == 0)
        #expect(before.presentation.isEmpty)
    }

    @Test func copiesAliasHistoryAndUnrelatedEditRejectsStaleTransition() throws {
        let shared = try owner()
        let alias = shared
        let before = shared.snapshot()
        guard case .idle(let idle) = before else {
            Issue.record("Expected initial idle snapshot")
            return
        }
        let request = try ProfileRequest(userID: idle.value.userID)
        let stale = try idle.load(request)
        guard case .committed = alias.commit(before.presentationChanged("new presentation")) else {
            Issue.record("Alias edit was rejected")
            return
        }
        guard case .rejected(.conflict, let current) = shared.commit(stale) else {
            Issue.record("Stale whole-root transition was admitted")
            return
        }
        #expect(current.presentation == "new presentation")
        #expect(current.model == before.model)
        #expect(shared.snapshot().ordinal == alias.snapshot().ordinal)
        guard case .idle(let fresh) = current,
            case .committed(let loaded) = shared.commit(try fresh.load(request))
        else {
            Issue.record("Fresh transition was rejected")
            return
        }
        #expect(loaded.snapshot.presentation == "new presentation")
        #expect(alias.snapshot().ordinal == 2)
        #expect(before.presentation.isEmpty)
        #expect(before.model == .idle(idle.value))
    }

    @Test func foreignForkRestoreAndResetDoNotInheritSnapshotAuthority() throws {
        let shared = try owner()
        let before = shared.snapshot()
        let archive = try Flow.Archive(model: before.model, presentation: "restored")
        let unrelated = try owner()
        let fork = try shared.fork()
        let restored = Flow.Shared.restore(archive)
        for other in [unrelated, fork, restored] {
            guard case .rejected(.foreignOwner, let current) = other.commit(before.presentationChanged("foreign"))
            else {
                Issue.record("Equal model or archive granted foreign authority")
                continue
            }
            #expect(current.ordinal == 0)
            #expect(other.drainCommands(limit: 10).isEmpty)
            guard case .committed = other.commit(other.snapshot().presentationChanged("own")) else {
                Issue.record("Fresh owner proof was rejected")
                continue
            }
        }
        guard case .committed(let reset) = shared.reset(archive, expected: before) else {
            Issue.record("Reset was rejected")
            return
        }
        #expect(reset.ordinal == 1)
        guard case .rejected(.obsoleteIncarnation, let current) = shared.commit(before.presentationChanged("old"))
        else {
            Issue.record("Reset retained old incarnation authority")
            return
        }
        #expect(current.presentation == "restored")
        guard case .committed(let fresh) = shared.commit(current.presentationChanged("fresh")) else {
            Issue.record("New incarnation proof was rejected")
            return
        }
        #expect(fresh.ordinal == 2)
        #expect(before.ordinal == 0)
        #expect(before.presentation.isEmpty)
    }

    @Test func batchesAreFIFOAndCloseUsesReservedSlot() throws {
        let shared = try owner(configuration: .init(commitCapacity: 2))
        for label in ["one", "two"] {
            guard case .committed = shared.commit(shared.snapshot().presentationChanged(label)) else {
                Issue.record("Ordinary slot rejected")
                return
            }
        }
        guard
            case .rejected(.capacityExceeded(.commitQueue), let current) = shared.commit(
                shared.snapshot().presentationChanged("overflow")
            )
        else {
            Issue.record("Full queue did not reject atomically")
            return
        }
        #expect(current.presentation == "two")
        #expect(current.ordinal == 2)
        let closed = shared.close()
        #expect(closed.ordinal == 3)
        #expect(closed.snapshot.isClosed)
        #expect(shared.close().ordinal == 3)
        #expect(!shared.isQuiescent)
        #expect(shared.drainCommands(limit: 0).isEmpty)
        let first = shared.drainCommands(limit: 1)
        #expect(first.map(\.receipt.ordinal) == [1])
        #expect(first.map(\.receipt.snapshot.presentation) == ["one"])
        #expect(first.allSatisfy { !$0.terminal && $0.commands.isEmpty })
        let remaining = shared.drainCommands(limit: 10)
        #expect(remaining.map(\.receipt.ordinal) == [2, 3])
        #expect(remaining.map(\.terminal) == [false, true])
        #expect(remaining.allSatisfy { $0.commands.isEmpty })
        #expect(shared.isQuiescent)
        #expect(shared.drainCommands(limit: 10).isEmpty)
    }

    @Test func queuedCommandsKeepReceiptOrderAndIssuedWorkRequiresAcknowledgment() throws {
        let shared = try owner(configuration: .init(commitCapacity: 2))
        guard case .idle(let idle) = shared.snapshot() else {
            Issue.record("Expected idle snapshot")
            return
        }
        let request = try ProfileRequest(userID: idle.value.userID)
        guard case .committed = shared.commit(try idle.load(request)) else {
            Issue.record("Initial start rejected")
            return
        }
        let issued = shared.drainCommands(limit: 1)
        let issuedBatch = try #require(issued.first)
        let command = try #require(issuedBatch.commands.first)
        guard case .start(let work) = command,
            case .loading(let loading) = shared.snapshot(),
            case .committed = shared.commit(loading.cancel()),
            case .idle(let nextIdle) = shared.snapshot(),
            case .committed = shared.commit(try nextIdle.load(request))
        else {
            Issue.record("Start/cancel/restart history failed")
            return
        }
        #expect(issuedBatch.receipt.ordinal == 1)
        #expect(work.input == request)
        let closed = shared.close()
        #expect(closed.ordinal == 4)
        let batches = shared.drainCommands(limit: 10)
        #expect(batches.map(\.receipt.ordinal) == [2, 3, 4])
        #expect(batches.map(\.terminal) == [false, false, true])
        #expect(batches.map { $0.commands.count } == [1, 0, 1])
        // The second start was revoked before drain, so it never issues work.
        // Both accepted cancellations remain in their original FIFO batches.
        for batch in batches where !batch.commands.isEmpty {
            guard case .cancel = batch.commands[0] else {
                Issue.record("Expected cancellation command in committed position")
                continue
            }
        }
        #expect(!shared.isQuiescent)
        #expect(shared.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
        #expect(shared.acknowledgeExecution(work.execution, disposition: .terminated) == .duplicate)
        #expect(shared.isQuiescent)
    }

    @Test func subscriberCanReadCommitAndCloseReentrantly() async throws {
        let shared = try owner()
        let (events, continuation) = AsyncStream<UInt64>.makeStream()
        let subscription = try shared.subscribe { snapshot in
            continuation.yield(snapshot.ordinal)
            #expect(shared.snapshot().ordinal == snapshot.ordinal)
            if snapshot.ordinal == 0 {
                guard case .committed = shared.commit(snapshot.presentationChanged("from callback")) else {
                    Issue.record("Reentrant commit was rejected")
                    continuation.finish()
                    return
                }
            } else if snapshot.ordinal == 1 {
                _ = shared.close()
            }
        } onFinish: {
            continuation.finish()
        }
        defer { subscription.cancel() }
        var ordinals: [UInt64] = []
        for await ordinal in events { ordinals.append(ordinal) }
        #expect(ordinals == [0, 1, 2])
        #expect(shared.snapshot().presentation == "from callback")
        #expect(shared.snapshot().isClosed)
        #expect(shared.drainCommands(limit: 10).map(\.receipt.ordinal) == [1, 2])
    }

    @Test(arguments: [false, true])
    func lateSubscriberReceivesClosedSnapshotThenFinishes(afterDrain: Bool) async throws {
        let shared = try owner()
        let closed = shared.close()
        if afterDrain { _ = shared.drainCommands(limit: 10) }
        let (events, continuation) = AsyncStream<UInt64>.makeStream()
        let subscription = try shared.subscribe { snapshot in
            #expect(snapshot.isClosed)
            continuation.yield(snapshot.ordinal)
        } onFinish: {
            continuation.finish()
        }
        defer { subscription.cancel() }
        var ordinals: [UInt64] = []
        for await ordinal in events { ordinals.append(ordinal) }
        #expect(ordinals == [closed.ordinal])
    }

    @Test(.parksCooperativeThread) func slowSubscriberCoalescesToFinalValueWithoutLosingBatches() async throws {
        let shared = try owner()
        let release = DispatchSemaphore(value: 0)
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (events, continuation) = AsyncStream<UInt64>.makeStream()
        let subscription = try shared.subscribe { snapshot in
            continuation.yield(snapshot.ordinal)
            if snapshot.ordinal == 0 {
                entry.yield(())
                entry.finish()
                // The callback API is synchronous: hold this one claimed delivery
                // while the test drives commits. This timeout only bounds failure.
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
        } onFinish: {
            continuation.finish()
        }
        defer {
            release.signal()
            subscription.cancel()
        }
        var ready = entered.makeAsyncIterator()
        _ = try #require(await ready.next())
        for index in 1 ... 20 {
            guard case .committed = shared.commit(shared.snapshot().presentationChanged("value \(index)")) else {
                Issue.record("Commit rejected while subscriber was blocked")
                return
            }
        }
        let closed = shared.close()
        release.signal()
        var ordinals: [UInt64] = []
        for await ordinal in events { ordinals.append(ordinal) }
        #expect(ordinals == [0, closed.ordinal])
        #expect(zip(ordinals, ordinals.dropFirst()).allSatisfy { $0 < $1 })
        #expect(shared.snapshot().presentation == "value 20")
        let batches = shared.drainCommands(limit: 100)
        #expect(batches.map(\.receipt.ordinal) == Array(UInt64(1) ... UInt64(21)))
        #expect(batches.last?.terminal == true)
        #expect(shared.isQuiescent)
    }

    @Test func packageRunnerReentrantConsumerContinuesAcrossThirtyTwoBatchTurns() async throws {
        let holder = OSAllocatedUnfairLock<Flow.Shared?>(initialState: nil)
        let (events, continuation) = AsyncStream<UInt64>.makeStream()
        let shared = Flow.Shared(.init(userID: try UserID("kyle"))) { batch in
            continuation.yield(batch.receipt.ordinal)
            guard !batch.terminal else {
                continuation.finish()
                return
            }
            guard let owner = holder.withLock({ $0 }) else {
                Issue.record("Missing runner owner")
                continuation.finish()
                return
            }
            #expect(owner.snapshot().ordinal == batch.receipt.ordinal)
            if batch.receipt.ordinal < 40 {
                guard case .committed = owner.commit(owner.snapshot().presentationChanged("reentrant")) else {
                    Issue.record("Reentrant runner submission rejected")
                    continuation.finish()
                    return
                }
            } else {
                _ = owner.close()
            }
        }
        holder.withLock { $0 = shared }
        defer { holder.withLock { $0 = nil } }
        guard case .committed = shared.commit(shared.snapshot().presentationChanged("first")) else {
            Issue.record("Initial runner commit rejected")
            return
        }
        var ordinals: [UInt64] = []
        for await ordinal in events { ordinals.append(ordinal) }
        #expect(ordinals == Array(UInt64(1) ... UInt64(41)))
        #expect(shared.snapshot().isClosed)
        // The stream is finished inside the callback; join the drainer before querying cleanup.
        #expect(await shared.shutdownAndWait(deadline: .now.advanced(by: .seconds(10))) == .quiescent)
        #expect(shared.isQuiescent)
        #expect(shared.drainCommands(limit: 100).isEmpty)
    }

    @Test(.parksCooperativeThread) func packageRunnerSerializesBacklogAndRacingProducersWithClose() async throws {
        struct CallbackState: Sendable {
            var active = 0
            var maximum = 0
        }
        let callbacks = OSAllocatedUnfairLock(initialState: CallbackState())
        let release = DispatchSemaphore(value: 0)
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (events, continuation) = AsyncStream<Flow.CommandBatch>.makeStream()
        let shared = Flow.Shared(.init(userID: try UserID("kyle"))) { batch in
            callbacks.withLock {
                $0.active += 1
                $0.maximum = max($0.maximum, $0.active)
            }
            if batch.receipt.ordinal == 1 {
                entry.yield(())
                entry.finish()
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
            callbacks.withLock { $0.active -= 1 }
            continuation.yield(batch)
            if batch.terminal { continuation.finish() }
        }
        defer { release.signal() }
        guard case .committed = shared.commit(shared.snapshot().presentationChanged("first")) else {
            Issue.record("Initial runner commit rejected")
            return
        }
        var readiness = entered.makeAsyncIterator()
        _ = try #require(await readiness.next())
        // A claimed callback holds the sole consumer while more than one turn of
        // batches accumulates. Producers and close then contend on that backlog.
        for index in 2 ... 65 {
            guard case .committed = shared.commit(shared.snapshot().presentationChanged("queued \(index)")) else {
                Issue.record("Backlog commit rejected")
                return
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    let result = shared.commit(shared.snapshot().presentationChanged("racing \(index)"))
                    switch result {
                    case .committed: break
                    case .rejected(let reason, _):
                        #expect(reason == .conflict || reason == .closed)
                    }
                }
            }
            group.addTask { _ = shared.close() }
        }
        let final = shared.snapshot()
        release.signal()
        var batches: [Flow.CommandBatch] = []
        for await batch in events { batches.append(batch) }
        #expect(batches.map(\.receipt.ordinal) == Array(UInt64(1) ... final.ordinal))
        #expect(batches.filter(\.terminal).count == 1)
        #expect(batches.last?.receipt.ordinal == final.ordinal)
        #expect(batches.last?.receipt.snapshot.isClosed == true)
        #expect(callbacks.withLock { $0.maximum } == 1)
        #expect(callbacks.withLock { $0.active } == 0)
        // The stream is finished inside the callback; join the drainer before querying cleanup.
        #expect(await shared.shutdownAndWait(deadline: .now.advanced(by: .seconds(10))) == .quiescent)
        #expect(shared.isQuiescent)
    }

    @Test func packageRunnerRepeatedEnqueueAtCallbackReturnDoesNotLoseWakeups() async throws {
        let (events, continuation) = AsyncStream<UInt64>.makeStream()
        let shared = Flow.Shared(.init(userID: try UserID("kyle"))) { batch in
            continuation.yield(batch.receipt.ordinal)
            if batch.terminal { continuation.finish() }
        }
        var delivered = events.makeAsyncIterator()
        // Every next submission follows observation of the previous consumer
        // invocation. It may meet the drainer before or after its empty CAS;
        // this public seam does not force the private empty-state boundary.
        for index in 1 ... 64 {
            guard case .committed(let receipt) = shared.commit(shared.snapshot().presentationChanged("round \(index)"))
            else {
                Issue.record("Sequential enqueue rejected")
                return
            }
            #expect(receipt.ordinal == UInt64(index))
            #expect(await delivered.next() == receipt.ordinal)
        }
        let terminal = shared.close()
        #expect(await delivered.next() == terminal.ordinal)
        #expect(await delivered.next() == nil)
        // The stream is finished inside the callback; join the drainer before querying cleanup.
        #expect(await shared.shutdownAndWait(deadline: .now.advanced(by: .seconds(10))) == .quiescent)
        #expect(shared.isQuiescent)
    }

    @Test(arguments: [1, 128])
    func subscriberCapacityRejectsOverflowAndCancellationReleasesSlot(capacity: Int) throws {
        let configuration = capacity == 128 ? Flow.Configuration.default : try .init(subscriberCapacity: capacity)
        #expect(configuration.subscriberCapacity == capacity)
        let shared = try owner(configuration: configuration)
        var subscriptions: [Flow.Subscription] = []
        defer { subscriptions.forEach { $0.cancel() } }
        for _ in 0 ..< capacity {
            subscriptions.append(try shared.subscribe { _ in })
        }
        #expect(throws: Flow.SubscriptionFailure.self) {
            try shared.subscribe { _ in }
        }
        // Keep the canceled token alive: cancel must free capacity immediately.
        subscriptions[0].cancel()
        subscriptions.append(try shared.subscribe { _ in })
        #expect(throws: Flow.SubscriptionFailure.self) {
            try shared.subscribe { _ in }
        }
    }

    @Test(.parksCooperativeThread) func unsubscribeAllowsClaimedCallbackAndReleasesCaptureWhileTokenRemainsAlive()
        async throws
    {
        let shared = try owner(configuration: .init(subscriberCapacity: 1))
        let release = DispatchSemaphore(value: 0)
        let ordinals = OSAllocatedUnfairLock(initialState: [UInt64]())
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (released, lifetimeEnded) = AsyncStream<Void>.makeStream()
        let subscription = try shared.subscribe {
            [
                lifetime = SharedCallbackLifetime(onRelease: {
                    lifetimeEnded.yield(())
                    lifetimeEnded.finish()
                })
            ] snapshot in
            withExtendedLifetime(lifetime) {
                ordinals.withLock { $0.append(snapshot.ordinal) }
                entry.yield(())
                entry.finish()
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
        }
        defer {
            release.signal()
            subscription.cancel()
        }
        var readiness = entered.makeAsyncIterator()
        _ = try #require(await readiness.next())
        guard case .committed = shared.commit(shared.snapshot().presentationChanged("pending")) else {
            Issue.record("Pending edit rejected")
            return
        }
        subscription.cancel()
        subscription.cancel()
        // This offer happens after removal; the previous pending offer was
        // canceled while the initial callback was already in flight.
        guard case .committed = shared.commit(shared.snapshot().presentationChanged("after cancel")) else {
            Issue.record("Post-cancel edit rejected")
            return
        }
        let replacement = try shared.subscribe { _ in }
        defer { replacement.cancel() }
        _ = shared.close()
        release.signal()
        var releaseEvents = released.makeAsyncIterator()
        _ = try #require(await releaseEvents.next())
        // Capture destruction is a teardown barrier for this callback. The
        // retained canceled token cannot keep its registration closure alive.
        withExtendedLifetime(subscription) {
            #expect(ordinals.withLock { $0 } == [0])
        }
    }

    @Test func packageRunnerAwaitsCancellationBeforeObservationAndStartBeforeProcessed() async throws {
        struct Stages: Sendable {
            var cancelCount = 0
            var startCount = 0
            var firstCancellationCompleted = false
            var firstStartCompleted = false
        }
        let stages = OSAllocatedUnfairLock(initialState: Stages())
        let holder = OSAllocatedUnfairLock<Flow.Shared?>(initialState: nil)
        let (cancelEntered, entered) = AsyncStream<Void>.makeStream()
        let (cancelRelease, release) = AsyncStream<Void>.makeStream()
        let (observed, observedEvent) = AsyncStream<Void>.makeStream()
        let (processed, processedEvent) = AsyncStream<UInt64>.makeStream()
        let shared = Flow.Shared(
            .init(userID: try UserID("kyle")),
            cancel: { _ in
                let first = stages.withLock { state in
                    state.cancelCount += 1
                    return state.cancelCount == 1
                }
                if first {
                    entered.yield(())
                    entered.finish()
                    var gate = cancelRelease.makeAsyncIterator()
                    _ = await gate.next()
                    stages.withLock { $0.firstCancellationCompleted = true }
                }
            },
            start: { _ in
                let first = stages.withLock { state in
                    state.startCount += 1
                    return state.startCount == 1
                }
                if first {
                    #expect(stages.withLock { $0.firstCancellationCompleted })
                    // An offer schedules a callback; callback invocation need not
                    // precede entry to this hook. Await its explicit event here.
                    var callback = observed.makeAsyncIterator()
                    _ = await callback.next()
                    #expect(holder.withLock { $0?.snapshot().presentation } == "reentrant observation")
                    stages.withLock { $0.firstStartCompleted = true }
                }
            },
            processed: { batch in
                if batch.receipt.ordinal == 1 {
                    #expect(stages.withLock { $0.firstStartCompleted })
                }
                processedEvent.yield(batch.receipt.ordinal)
                if batch.terminal { processedEvent.finish() }
            }
        )
        holder.withLock { $0 = shared }
        defer {
            holder.withLock { $0 = nil }
            release.finish()
            observedEvent.finish()
        }
        let subscription = try shared.subscribe { snapshot in
            if snapshot.ordinal == 1 {
                #expect(stages.withLock { $0.firstCancellationCompleted })
                guard case .committed = shared.commit(snapshot.presentationChanged("reentrant observation")) else {
                    Issue.record("Observation reentry rejected")
                    observedEvent.finish()
                    return
                }
                observedEvent.yield(())
                observedEvent.finish()
            }
        }
        defer { subscription.cancel() }
        guard case .committed = shared.commit(shared.snapshot().presentationChanged("first")) else {
            Issue.record("Initial commit rejected")
            return
        }
        var cancellation = cancelEntered.makeAsyncIterator()
        _ = try #require(await cancellation.next())
        #expect(shared.snapshot().ordinal == 1)
        release.yield(())
        release.finish()
        var completions = processed.makeAsyncIterator()
        #expect(await completions.next() == 1)
        _ = shared.close()
        var remaining: [UInt64] = []
        while let ordinal = await completions.next() { remaining.append(ordinal) }
        #expect(remaining == [2, 3])
    }

}
