import Dispatch
import StateMachine
import StateMachineExamples
import Testing
import os

/// Observer callbacks neither hold back accepted work nor outlive an abandoned owner silently.
@Suite(.timeLimit(.minutes(1))) struct ObserverOrderingTests {
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

    // The observer blocks the owner's actor, on a cooperative-pool thread, until the driver has started on
    // another one.
    @Test(.parksCooperativeThread) func anObserverWaitingOnItsOwnRevisionsWorkSeesThatWorkStart() async throws {
        let user = try UserID("kyle")
        let started = DispatchSemaphore(value: 0)
        let observed = OSAllocatedUnfairLock<DispatchTimeoutResult?>(initialState: nil)
        let owner = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    started.signal()
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        let subscription = try await owner.subscribe { snapshot in
            guard case .loading = snapshot, observed.withLock({ $0 == nil }) else { return }
            // The bound only limits a failing run; a passing run is signalled at once.
            let result = started.wait(timeout: .now() + 5)
            observed.withLock { $0 = result }
        }
        let receipt = try await owner.send(.load(ProfileRequest(userID: user)))
        #expect(await owner.flush(through: receipt) == .processed)
        #expect(observed.withLock { $0 } == .success)
        subscription.cancel()
        await owner.shutdown()
    }

    /// A latch a driver awaits without observing task cancellation, so only the test releases it.
    private final class Gate: Sendable {
        private struct State {
            var isOpen = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func open() {
            let waiters = state.withLock { state in
                state.isOpen = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let isOpen = state.withLock { state in
                    if !state.isOpen { state.waiters.append(continuation) }
                    return state.isOpen
                }
                if isOpen { continuation.resume() }
            }
        }
    }

    /// A timed-out result names the one execution that is still tracked.
    private func expectOneOutstandingExecution(_ result: GeneratedProfile.ShutdownResult) {
        guard case .timedOut(let diagnostics) = result else {
            Issue.record("Shutdown reported quiescence while a driver was still running")
            return
        }
        #expect(diagnostics.outstandingExecutions.count == 1)
        #expect(diagnostics.outstandingExecutions.first?.disposition == .issued)
        #expect(diagnostics.outstandingExecutions.first?.preparation == nil)
        #expect(diagnostics.pendingCompletions.isEmpty)
        #expect(diagnostics.processedThrough <= diagnostics.acceptedRevision)
    }

    @Test func aSharedOwnerStopsWaitingAtItsDeadlineAndKeepsTrackingTheWork() async throws {
        let user = try UserID("kyle")
        let started = Signal()
        let release = Gate()
        let owner = GeneratedProfile.Shared(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    started.raise()
                    await release.wait()
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        try owner.send(.load(ProfileRequest(userID: user)))
        await started.wait()
        expectOneOutstandingExecution(await owner.shutdown(deadline: .now))
        #expect(!owner.isQuiescent)
        release.open()
        guard case .quiescent = await owner.shutdown() else {
            Issue.record("Shutdown did not join the released driver")
            return
        }
        #expect(owner.isQuiescent)
    }

    @Test func anActorOwnerStopsWaitingAtItsDeadlineAndKeepsTrackingTheWork() async throws {
        let user = try UserID("kyle")
        let started = Signal()
        let release = Gate()
        let owner = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    started.raise()
                    await release.wait()
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        _ = try await owner.send(.load(ProfileRequest(userID: user)))
        await started.wait()
        expectOneOutstandingExecution(await owner.shutdown(deadline: .now))
        #expect(await !owner.isQuiescent)
        release.open()
        guard case .quiescent = await owner.shutdown() else {
            Issue.record("Shutdown did not join the released driver")
            return
        }
        #expect(await owner.isQuiescent)
    }

    @MainActor @Test func aMainActorOwnerStopsWaitingAtItsDeadlineAndKeepsTrackingTheWork() async throws {
        let user = try UserID("kyle")
        let started = Signal()
        let release = Gate()
        let owner = GeneratedProfile.MainActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    started.raise()
                    await release.wait()
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        _ = try owner.send(.load(ProfileRequest(userID: user)))
        await started.wait()
        expectOneOutstandingExecution(await owner.shutdown(deadline: .now))
        #expect(!owner.isQuiescent)
        release.open()
        guard case .quiescent = await owner.shutdown() else {
            Issue.record("Shutdown did not join the released driver")
            return
        }
        #expect(owner.isQuiescent)
    }

    /// A timed-out result always names something still unsettled.
    private func expectSettledOrOutstanding(_ result: GeneratedProfile.ShutdownResult) {
        guard case .timedOut(let diagnostics) = result else { return }
        let outstanding =
            !diagnostics.outstandingExecutions.isEmpty || !diagnostics.pendingCompletions.isEmpty
            || diagnostics.hasQueuedBatches || diagnostics.isDraining || diagnostics.isRetrying
            || diagnostics.processedThrough < diagnostics.acceptedRevision
        #expect(outstanding, "A timed-out shutdown reported nothing outstanding: \(diagnostics)")
    }

    /// A driver that returns once the test opens its gate.
    private static func gatedDrivers(started: Signal, release: Gate) -> GeneratedProfile.Drivers {
        .init(
            fetch: { _ in
                started.raise()
                await release.wait()
                return .failure(.unavailable)
            },
            audit: { _ in .failure(.unavailable) }
        )
    }

    // Each iteration opens the gate and asks for a deadline that has already passed while the
    // released driver settles; whichever way the observation falls, it is never empty.
    @Test func aDeadlineThatPassesAsSharedWorkSettlesNeverReportsNothingOutstanding() async throws {
        let user = try UserID("kyle")
        for _ in 0 ..< 16 {
            let started = Signal()
            let release = Gate()
            let owner = GeneratedProfile.Shared(
                .init(userID: user),
                drivers: Self.gatedDrivers(started: started, release: release)
            )
            try owner.send(.load(ProfileRequest(userID: user)))
            await started.wait()
            release.open()
            expectSettledOrOutstanding(await owner.shutdown(deadline: .now))
            #expect(await owner.shutdown() == .quiescent)
        }
    }

    @Test func aDeadlineThatPassesAsActorWorkSettlesNeverReportsNothingOutstanding() async throws {
        let user = try UserID("kyle")
        for _ in 0 ..< 16 {
            let started = Signal()
            let release = Gate()
            let owner = GeneratedProfile.ActorHost(
                .init(userID: user),
                drivers: Self.gatedDrivers(started: started, release: release)
            )
            try await owner.send(.load(ProfileRequest(userID: user)))
            await started.wait()
            release.open()
            expectSettledOrOutstanding(await owner.shutdown(deadline: .now))
            #expect(await owner.shutdown() == .quiescent)
        }
    }

    @MainActor @Test func aDeadlineThatPassesAsMainActorWorkSettlesNeverReportsNothingOutstanding() async throws {
        let user = try UserID("kyle")
        for _ in 0 ..< 16 {
            let started = Signal()
            let release = Gate()
            let owner = GeneratedProfile.MainActorHost(
                .init(userID: user),
                fetchDriver: { _ in
                    started.raise()
                    await release.wait()
                    return .failure(.unavailable)
                },
                auditDriver: { _ in .failure(.unavailable) }
            )
            try owner.send(.load(ProfileRequest(userID: user)))
            await started.wait()
            release.open()
            expectSettledOrOutstanding(await owner.shutdown(deadline: .now))
            #expect(await owner.shutdown() == .quiescent)
        }
    }

    @Test func aSharedOwnerCountsItsRunningWorkAndRegistrations() async throws {
        let user = try UserID("kyle")
        let started = Signal()
        let release = Gate()
        let owner = GeneratedProfile.Shared(
            .init(userID: user),
            drivers: Self.gatedDrivers(started: started, release: release)
        )
        #expect(owner.subscriberCount == 0)
        let subscription = try owner.subscribe { _ in }
        let snapshots = try owner.snapshots()
        #expect(owner.subscriberCount == 2)
        subscription.cancel()
        #expect(owner.subscriberCount == 1)
        try owner.send(.load(ProfileRequest(userID: user)))
        await started.wait()
        #expect(owner.runningCount == 1)
        release.open()
        #expect(await owner.shutdown() == .quiescent)
        #expect(owner.runningCount == 0)
        // Closing released the remaining registration.
        #expect(owner.subscriberCount == 0)
        withExtendedLifetime(snapshots) {}
    }

    @Test func flushingAnotherOwnersReceiptReportsAForeignOwner() async throws {
        let user = try UserID("kyle")
        let drivers = GeneratedProfile.Drivers(
            fetch: { _ in .failure(.unavailable) },
            audit: { _ in .failure(.unavailable) }
        )
        let shared = GeneratedProfile.Shared(.init(userID: user), drivers: drivers)
        let other = GeneratedProfile.Shared(.init(userID: user), drivers: drivers)
        let receipt = other.close()
        #expect(await shared.flush(through: receipt) == .foreignOwner)
        #expect(await other.flush(through: receipt) == .processed)
        let actor = GeneratedProfile.ActorHost(.init(userID: user), drivers: drivers)
        #expect(await actor.flush(through: receipt) == .foreignOwner)
        let actorReceipt = await actor.close()
        #expect(await actor.flush(through: actorReceipt) == .processed)
        await shared.shutdown()
        await other.shutdown()
        await actor.shutdown()
    }

    @MainActor @Test func flushingAnotherOwnersReceiptOnTheMainActorReportsAForeignOwner() async throws {
        let user = try UserID("kyle")
        let first = GeneratedProfile.MainActorHost(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        let second = GeneratedProfile.MainActorHost(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        let receipt = first.close()
        #expect(await second.flush(through: receipt) == .foreignOwner)
        #expect(await first.flush(through: receipt) == .processed)
        second.close()
        await first.shutdown()
        await second.shutdown()
    }

    @Test func releasingAnActorOwnerFinishesItsRetainedRegistration() async throws {
        var owner: GeneratedProfile.ActorHost? = GeneratedProfile.ActorHost(
            .init(userID: try UserID("kyle")),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        let finished = Signal()
        let closed = OSAllocatedUnfairLock(initialState: false)
        let subscription = try await owner?
            .subscribe(
                { snapshot in if snapshot.isClosed { closed.withLock { $0 = true } } },
                onFinish: { finished.raise() }
            )
        owner = nil
        await finished.wait()
        #expect(!closed.withLock { $0 })
        subscription?.cancel()
    }

    @MainActor @Test func releasingAMainActorOwnerFinishesItsRetainedRegistration() async throws {
        var owner: GeneratedProfile.MainActorHost? = GeneratedProfile.MainActorHost(
            .init(userID: try UserID("kyle")),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        let finished = Signal()
        var closed = false
        let subscription = try owner?
            .subscribe(
                { snapshot in if snapshot.isClosed { closed = true } },
                onFinish: { finished.raise() }
            )
        owner = nil
        await finished.wait()
        #expect(!closed)
        subscription?.cancel()
    }
}

/// A registration's initial value, like a synchronous read, shows the admitted state at once; event
/// handlers and later deliveries follow commit order.
@Suite struct InitialObservationOrderingTests {
    @MainActor @Test func aNewSubscriptionSeesTheAdmittedStateBeforeThatCommitsEventHandlerRuns() async throws {
        var logged: [String] = []
        let host = GeneratedTransfers.MainActorHost(
            downloadDriver: { _, _ in .success("") },
            onLogged: { logged.append($0) }
        )
        let offline = try host.send(.goOffline)
        var seen: [UInt64] = []
        let subscription = try host.subscribe({ seen.append($0.revision) }, onFinish: {})
        #expect(seen == [offline.revision])
        #expect(host.snapshot().revision == offline.revision)
        #expect(logged.isEmpty)
        #expect(await host.flush(through: offline) == .processed)
        #expect(logged == ["offline"])
        // The subscription had already seen this revision, so processing its batch delivers nothing new.
        #expect(seen == [offline.revision])
        subscription.cancel()
        await host.shutdown()
    }
}
