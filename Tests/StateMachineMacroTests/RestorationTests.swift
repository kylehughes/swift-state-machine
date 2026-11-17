import StateMachine
import StateMachineExamples
import Testing
import os

/// Saved data restores into a resting phase with fresh authority, never into running work.
@Suite(.timeLimit(.minutes(1))) struct RestorationTests {
    private enum Failure: Error { case unexpected }

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

    private let user: UserID
    private let request: ProfileRequest
    private let saved: Profile
    private let fetched: Profile

    init() throws {
        user = try UserID("kyle")
        request = try ProfileRequest(userID: user)
        saved = Profile(userID: user, name: "Saved")
        fetched = Profile(userID: user, name: "Fetched")
    }

    /// Drivers whose fetch succeeds with `fetched`; audits are never started by these tests.
    private var sharedDrivers: GeneratedProfile.Drivers {
        let fetched = fetched
        return .init(fetch: { _ in .success(fetched) }, audit: { _ in .failure(.unavailable) })
    }

    @Test func aLocalOwnerRestoresANonInitialPhaseAtRevisionZero() throws {
        let owner = try GeneratedProfile.Local(restoring: .loaded(saved))
        let snapshot = owner.snapshot()
        #expect(snapshot.revision == 0)
        guard case .loaded(let loaded) = snapshot else { throw Failure.unexpected }
        #expect(loaded.value.profile == saved)
        #expect(owner.pendingCompletions().isEmpty)
    }

    @Test func managedOwnersRestoreANonInitialPhaseAtRevisionZero() async throws {
        let shared = try GeneratedProfile.Shared(restoring: .failed(request, .unauthorized), drivers: sharedDrivers)
        let actor = try GeneratedProfile.ActorHost(restoring: .loaded(saved), drivers: sharedDrivers)
        let restoredShared = shared.snapshot()
        let restoredActor = await actor.snapshot()
        #expect(restoredShared.revision == 0 && restoredActor.revision == 0)
        guard case .failed(let failed) = restoredShared, case .loaded(let loaded) = restoredActor else {
            throw Failure.unexpected
        }
        #expect(failed.value.request == request && failed.value.failure == .unauthorized)
        #expect(loaded.value.profile == saved)
        #expect(await actor.runningCount == 0)
        await shared.shutdown()
        await actor.shutdown()
    }

    @MainActor @Test func aMainActorOwnerRestoresANonInitialPhaseAtRevisionZero() async throws {
        let owner = try GeneratedProfile.MainActorHost(
            restoring: .failed(request, .unavailable),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        let snapshot = owner.snapshot()
        #expect(snapshot.revision == 0)
        guard case .failed(let failed) = snapshot else { throw Failure.unexpected }
        #expect(failed.value.failure == .unavailable)
        #expect(owner.runningCount == 0)
        await owner.shutdown()
    }

    @Test func aRejectedArchiveThrowsItsTypedFailureBeforeAnyOwnerExists() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try GeneratedProfile.Shared(
                restoring: .loading(request),
                drivers: .init(
                    fetch: { _ in
                        started.withLock { $0 = true }
                        return .failure(.unavailable)
                    },
                    audit: { _ in .failure(.unavailable) }
                )
            )
            Issue.record("An interrupted load was restored")
        } catch {
            #expect(error == .interruptedLoading)
        }
        do {
            _ = try GeneratedProfile.Local(restoring: .loading(request))
            Issue.record("An interrupted load was restored")
        } catch {
            #expect(error == .interruptedLoading)
        }
        #expect(!started.withLock { $0 })
    }

    @Test func aRestoredLocalOwnerTakesItsPhaseEdgesAndRunsTheWorkTheyStart() throws {
        var owner = try GeneratedProfile.Local(restoring: .loaded(saved))
        let receipt = try owner.send(.refresh(request))
        #expect(receipt.revision == 1)
        guard case .fetch(let work)? = owner.drainCommands(limit: 1).first?.commands.first else {
            throw Failure.unexpected
        }
        #expect(work.input == request)
        guard case .committed(let completed) = owner.deliver(work.succeeded(fetched)) else { throw Failure.unexpected }
        #expect(completed.revision == 2)
        let acknowledgment = owner.acknowledgeExecution(work.execution, disposition: .terminated)
        #expect(acknowledgment == .recorded)
        guard case .loaded(let loaded) = owner.snapshot() else { throw Failure.unexpected }
        #expect(loaded.value.profile == fetched)
    }

    @Test func aRestoredLocalOwnerRejectsAnInputWithNoEdgeFromItsPhase() throws {
        var owner = try GeneratedProfile.Local(restoring: .idle(user))
        do {
            try owner.send(.retry)
            Issue.record("An input with no edge from the restored phase was admitted")
        } catch {
            guard case .preparation(.invalidPhase) = error else { throw Failure.unexpected }
        }
        let receipt = try owner.send(.load(request))
        #expect(receipt.revision == 1)
    }

    @Test func aRestoredSharedOwnerRunsTheWorkItsEdgesStart() async throws {
        let owner = try GeneratedProfile.Shared(restoring: .failed(request, .unavailable), drivers: sharedDrivers)
        let loaded = Signal()
        let subscription = try owner.subscribe { snapshot in
            if case .loaded = snapshot { loaded.raise() }
        }
        let receipt = try owner.send(.retry)
        #expect(receipt.revision == 1)
        await loaded.wait()
        guard case .loaded(let observed) = owner.snapshot() else { throw Failure.unexpected }
        #expect(observed.value.profile == fetched)
        #expect(observed.revision == 2)
        subscription.cancel()
        await owner.shutdown()
    }

    @Test func aRestoredActorOwnerRunsTheWorkItsEdgesStart() async throws {
        let owner = try GeneratedProfile.ActorHost(restoring: .idle(user), drivers: sharedDrivers)
        let loaded = Signal()
        let subscription = try await owner.subscribe { snapshot in
            if case .loaded = snapshot { loaded.raise() }
        }
        let receipt = try await owner.send(.load(request))
        #expect(receipt.revision == 1)
        await loaded.wait()
        guard case .loaded(let observed) = await owner.snapshot() else { throw Failure.unexpected }
        #expect(observed.value.profile == fetched)
        subscription.cancel()
        await owner.shutdown()
    }

    @MainActor @Test func aRestoredMainActorOwnerRunsTheWorkItsEdgesStart() async throws {
        let fetched = fetched
        let owner = try GeneratedProfile.MainActorHost(
            restoring: .loaded(saved),
            drivers: .init(fetch: { _ in .success(fetched) }, audit: { _ in .failure(.unavailable) })
        )
        let loaded = Signal()
        let subscription = try owner.subscribe { snapshot in
            if case .loaded(let observed) = snapshot, observed.revision == 2 { loaded.raise() }
        }
        let receipt = try owner.send(.refresh(request))
        #expect(receipt.revision == 1)
        await loaded.wait()
        guard case .loaded(let observed) = owner.snapshot() else { throw Failure.unexpected }
        #expect(observed.value.profile == fetched)
        subscription.cancel()
        await owner.shutdown()
    }

    @Test func aRestoredOwnerRejectsAnObservationFromAnOwnerWithEqualData() throws {
        var initial = GeneratedProfile.Local(.init(userID: user))
        var restored = try GeneratedProfile.Local(restoring: .idle(user))
        guard case .idle(let foreign) = initial.snapshot(), case .idle(let own) = restored.snapshot() else {
            throw Failure.unexpected
        }
        #expect(foreign.value.userID == own.value.userID && foreign.revision == own.revision)
        guard case .rejected(.foreignOwner, _) = restored.commit(try foreign.begin(request)) else {
            throw Failure.unexpected
        }
        guard case .rejected(.foreignOwner, _) = initial.commit(try own.begin(request)) else {
            throw Failure.unexpected
        }
        guard case .committed = restored.commit(try own.begin(request)) else { throw Failure.unexpected }
    }

    @Test func aRestoredOwnerRejectsACompletionFromAnotherRestoredOwner() throws {
        var first = try GeneratedProfile.Local(restoring: .loaded(saved))
        var second = try GeneratedProfile.Local(restoring: .loaded(saved))
        try first.send(.refresh(request))
        try second.send(.refresh(request))
        guard case .fetch(let foreign)? = first.drainCommands(limit: 1).first?.commands.first,
            case .fetch(let own)? = second.drainCommands(limit: 1).first?.commands.first
        else { throw Failure.unexpected }
        guard case .foreignOwner = second.deliver(foreign.succeeded(fetched)) else { throw Failure.unexpected }
        #expect(second.pendingCompletions().isEmpty)
        let acknowledgment = second.acknowledgeExecution(foreign.execution, disposition: .terminated)
        #expect(acknowledgment == .foreignOwner)
        guard case .committed = second.deliver(own.succeeded(fetched)) else { throw Failure.unexpected }
    }
}
