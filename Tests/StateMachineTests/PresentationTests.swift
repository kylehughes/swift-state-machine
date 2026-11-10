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
