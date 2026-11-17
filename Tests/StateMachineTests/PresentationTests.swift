import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

@MainActor @Suite struct PresentationTests {
    private enum Failure: Error { case unexpected }

    private func host(_ user: UserID) -> GeneratedProfile.MainActorHost {
        GeneratedProfile.MainActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
    }

    @Test func sendPublishesInTheSameTurnAndReportsOneRejectionChannel() async throws {
        let user = try UserID("kyle")
        let presentation = try StateMachinePresentation(host(user))
        #expect(presentation.isObserving)
        #expect(presentation.snapshot.revision == 0)
        let receipt = try presentation.send(.load(ProfileRequest(userID: user)))
        #expect(receipt.revision == 1)
        #expect(presentation.snapshot.revision == 1)
        guard case .loading = presentation.snapshot else { throw Failure.unexpected }
        do {
            try presentation.send(.retry)
            Issue.record("An input with no edge from the current phase was admitted")
        } catch {
            guard case .preparation(.invalidPhase) = error else { throw Failure.unexpected }
        }
        #expect(presentation.snapshot.revision == 1)
        let closed = presentation.close()
        #expect(presentation.snapshot.isClosed)
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(!presentation.isObserving)
        do {
            try presentation.send(.cancel)
            Issue.record("A closed owner admitted an input")
        } catch {
            guard case .commit(.closed) = error else { throw Failure.unexpected }
        }
        await presentation.host.shutdown()
        #expect(presentation.host.isQuiescent)
    }

    @Test func domainRejectionKeepsItsTypedCase() async throws {
        let presentation = try StateMachinePresentation(host(try UserID("kyle")))
        let foreign = try ProfileRequest(userID: try UserID("someone-else"))
        do {
            try presentation.send(.load(foreign))
            Issue.record("A request for another user was admitted")
        } catch {
            guard case .preparation(.begin(.wrongUser)) = error else { throw Failure.unexpected }
        }
        #expect(presentation.snapshot.revision == 0)
        presentation.close()
        await presentation.host.shutdown()
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func observableModelTracksItsSnapshotAndPublishesInTheSameTurn() async throws {
        let user = try UserID("kyle")
        let model = try ObservableStateMachinePresentation(host(user))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            changed.withLock { $0 = true }
        }
        #expect(!changed.withLock { $0 })
        let receipt = try model.send(.load(ProfileRequest(userID: user)))
        #expect(changed.withLock { $0 })
        #expect(model.snapshot.revision == receipt.revision)
        #expect(model.isObserving)
        model.close()
        #expect(model.snapshot.isClosed)
        #expect(!model.isObserving)
        await model.host.shutdown()
        #expect(model.host.isQuiescent)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SequencePresentationTests {
    private typealias Host = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>
    private typealias Engine = Host.Engine

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

    private func host() throws -> Host {
        Host(
            manual: 0,
            scopes: [],
            limits: try RuntimeLimits(),
            ticket: { $0 },
            prepare: { _ in .failure(.plan(.invalidPlan)) }
        )
    }

    private func advance(_ owner: Host) throws {
        _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: owner.snapshot().model + 1))
    }

    @Test func generatedSnapshotsNeedNoRevisionProjection() throws {
        let owner = GeneratedProfile.Shared(
            .init(userID: try UserID("kyle")),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        let presentation = SnapshotPresentation(owner.snapshot())
        let closed = owner.close()
        #expect(presentation.apply(closed.snapshot))
        #expect(!presentation.apply(owner.snapshot()))
        #expect(presentation.snapshot.isClosed)
    }

    @Test func publishesASharedOwnersSnapshotsUntilItCloses() async throws {
        let owner = try host()
        let presentation = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        presentation.observe(try owner.snapshots())
        #expect(presentation.isObserving)
        let ended = Signal()
        var published: [UInt64] = []
        let snapshots = presentation.$snapshot.dropFirst().sink { published.append($0.revision) }
        let observing = presentation.$isObserving.dropFirst().sink { if !$0 { ended.raise() } }
        try advance(owner)
        let closed = owner.close()
        // Completion edge: the sequence delivered the closed snapshot and then ended.
        await ended.wait()
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        #expect(zip(published, published.dropFirst()).allSatisfy { $0 < $1 })
        #expect(published.last == closed.revision)
        #expect(!presentation.isObserving)
        snapshots.cancel()
        observing.cancel()
    }

    @Test func stoppingDiscardsLaterSnapshotsAndAReplacementKeepsObserving() async throws {
        let owner = try host()
        let presentation = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        // Each `observe` first stops the previous observation, then starts its own.
        let expected = [false, true, false, false, true, false]
        var observing: [Bool] = []
        let ended = Signal()
        let history = presentation.$isObserving.dropFirst()
            .sink {
                observing.append($0)
                if observing.count == expected.count { ended.raise() }
            }
        let detached = Signal()
        presentation.observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        try advance(owner)
        presentation.stopObserving()
        // Cleanup edge: the stopped consumer has removed its registration.
        await detached.wait()
        #expect(presentation.snapshot.revision == 0)
        presentation.observe(try owner.snapshots())
        let closed = owner.close()
        await ended.wait()
        #expect(observing == expected)
        #expect(presentation.snapshot.revision == closed.revision)
        history.cancel()
    }

    @Test func followReturnsAfterTheClosedSnapshot() async throws {
        let owner = try host()
        let presentation = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        try advance(owner)
        let closed = owner.close()
        await presentation.follow(try owner.snapshots())
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        #expect(!presentation.isObserving)
    }

    @Test func cancellingTheFollowingTaskStopsObservingAndFreesItsSlot() async throws {
        let owner = try host()
        let presentation = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        let started = Signal()
        let observing = presentation.$isObserving.dropFirst().sink { if $0 { started.raise() } }
        let detached = Signal()
        let snapshots = try owner.snapshots({ $0 }, onDetach: { detached.raise() })
        let following = Task { await presentation.follow(snapshots) }
        // Attachment edge: `follow` has taken ownership of the observation.
        await started.wait()
        following.cancel()
        await following.value
        #expect(!presentation.isObserving)
        // Cleanup edge: the cancelled consumer has removed its registration.
        await detached.wait()
        observing.cancel()
    }

    @Test func stoppingEndsAFollowingTask() async throws {
        let owner = try host()
        let presentation = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        let started = Signal()
        let observing = presentation.$isObserving.dropFirst().sink { if $0 { started.raise() } }
        let snapshots = try owner.snapshots()
        let following = Task { await presentation.follow(snapshots) }
        await started.wait()
        presentation.stopObserving()
        await following.value
        try advance(owner)
        #expect(presentation.snapshot.revision == 0 && !presentation.isObserving)
        observing.cancel()
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func observableModelFollowsASharedOwnerUntilItCloses() async throws {
        let owner = try host()
        let model = ObservableSnapshotPresentation(owner.snapshot(), revision: \.revision)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            changed.withLock { $0 = true }
        }
        try advance(owner)
        let closed = owner.close()
        await model.follow(try owner.snapshots())
        #expect(changed.withLock { $0 })
        #expect(model.snapshot.isClosed && model.snapshot.revision == closed.revision)
        #expect(!model.isObserving)
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func observableModelStopsApplyingAfterItStopsObserving() async throws {
        let owner = try host()
        let model = ObservableSnapshotPresentation(owner.snapshot(), revision: \.revision)
        let detached = Signal()
        model.observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        #expect(model.isObserving)
        try advance(owner)
        model.stopObserving()
        // Cleanup edge: the stopped consumer has removed its registration.
        await detached.wait()
        #expect(model.snapshot.revision == 0 && !model.isObserving)
    }
}
