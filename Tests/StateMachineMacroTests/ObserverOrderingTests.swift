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

    @Test func anObserverWaitingOnItsOwnRevisionsWorkSeesThatWorkStart() async throws {
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
        #expect(await owner.flush(through: receipt))
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
        expectOneOutstandingExecution(await owner.shutdownAndWait(deadline: .now))
        #expect(!owner.isQuiescent)
        release.open()
        guard case .quiescent = await owner.shutdownAndWait() else {
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
        expectOneOutstandingExecution(await owner.shutdownAndWait(deadline: .now))
        #expect(await !owner.isQuiescent)
        release.open()
        guard case .quiescent = await owner.shutdownAndWait() else {
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
        expectOneOutstandingExecution(await owner.shutdownAndWait(deadline: .now))
        #expect(!owner.isQuiescent)
        release.open()
        guard case .quiescent = await owner.shutdownAndWait() else {
            Issue.record("Shutdown did not join the released driver")
            return
        }
        #expect(owner.isQuiescent)
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
