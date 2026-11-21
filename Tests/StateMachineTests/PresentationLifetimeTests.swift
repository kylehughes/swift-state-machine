import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing

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

@MainActor private func transfers(subscribers: Int) throws -> GeneratedTransfers.MainActorHost {
    GeneratedTransfers.MainActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

/// An actor that owns a capacity-one host and presents it twice on the main actor.
private actor Shelf {
    private var host: GeneratedTransfers.IsolatedHost<Shelf>!

    init() async throws {
        host = GeneratedTransfers.IsolatedHost(
            isolation: self,
            downloadDriver: { _, _, _ in .success("") },
            onLogged: { _, _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 1)
        )
    }

    func presentTwice(on presentation: SnapshotObservableObject<GeneratedTransfers.Snapshot>) async throws -> Int {
        try await presentation.observe(host)
        try await presentation.observe(host)
        return host.subscriberCount()
    }

    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func presentTwice(on presentation: SnapshotPresentation<GeneratedTransfers.Snapshot>) async throws -> Int {
        try await presentation.observe(host)
        try await presentation.observe(host)
        return host.subscriberCount()
    }

    func send(_ input: GeneratedTransfers.Input) throws -> UInt64 { try host.send(input).revision }
    func close() { host.close() }
}

/// Replacing an observation frees the old slot first, and releasing a source ends the observation.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationLifetimeTests {
    @Test func observingTheSameCapacityOneOffMainOwnerAgainReusesItsSlot() async throws {
        let shelf = try await Shelf()
        let presentation = SnapshotObservableObject(try transfers(subscribers: 1).snapshot())
        #expect(try await shelf.presentTwice(on: presentation) == 1)
        #expect(presentation.isObserving)
        let next = try await shelf.send(.goOffline)
        let (applied, apply) = AsyncStream<UInt64>.makeStream()
        let cancellable = presentation.presentedSnapshots.sink { apply.yield($0.revision) }
        for await revision in applied where revision >= next { break }
        cancellable.cancel()
        presentation.stopObserving()
        await shelf.close()
    }

    @Test func anObservationPresentationObservesTheSameCapacityOneOffMainOwnerAgain() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let shelf = try await Shelf()
        let presentation = SnapshotPresentation(try transfers(subscribers: 1).snapshot())
        #expect(try await shelf.presentTwice(on: presentation) == 1)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        await shelf.close()
    }

    @Test func rebindingFromTheObservingPublisherFindsTheOldSlotFree() throws {
        let host = try transfers(subscribers: 1)
        let presentation = SnapshotObservableObject(host.snapshot())
        try presentation.observe(host)
        var failure: SubscriptionFailure?
        var armed = true
        let rebinding = presentation.$isObserving.sink { observing in
            guard armed, !observing else { return }
            armed = false
            do throws(SubscriptionFailure) { try presentation.observe(host) } catch { failure = error }
        }
        try presentation.observe(host)
        rebinding.cancel()
        #expect(failure == nil)
        #expect(!armed)
        #expect(presentation.isObserving)
        #expect(host.subscriberCount == 1)
        presentation.stopObserving()
        #expect(host.subscriberCount == 0)
    }

    @Test func releasingAnIsolatedMainActorSourceEndsTheObservation() async throws {
        var host: GeneratedNote.IsolatedHost<MainActor>? = GeneratedNote.IsolatedHost(
            isolation: MainActor.shared,
            saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) }
        )
        let presentation = SnapshotObservableObject(try #require(host).snapshot())
        try presentation.observe(try #require(host))
        #expect(presentation.isObserving)
        let ended = Signal()
        let cancellable = presentation.$isObserving.dropFirst().sink { if !$0 { ended.raise() } }
        host = nil
        await ended.wait()
        #expect(!presentation.isObserving)
        cancellable.cancel()
    }

    @Test func anObservationPresentationEndsWhenItsIsolatedMainActorSourceIsReleased() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        var host: GeneratedNote.IsolatedHost<MainActor>? = GeneratedNote.IsolatedHost(
            isolation: MainActor.shared,
            saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) }
        )
        let presentation = SnapshotPresentation(try #require(host).snapshot())
        try presentation.observe(try #require(host))
        let ended = Signal()
        withObservationTracking {
            _ = presentation.isObserving
        } onChange: {
            ended.raise()
        }
        host = nil
        await ended.wait()
        #expect(!presentation.isObserving)
    }

    @Test func stoppingAnIsolatedMainActorObservationRemovesItsRegistrationAtOnce() throws {
        let host = GeneratedNote.IsolatedHost(
            isolation: MainActor.shared,
            saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) }
        )
        let presentation = SnapshotObservableObject(host.snapshot())
        try presentation.observe(host)
        #expect(host.subscriberCount() == 1)
        presentation.stopObserving()
        #expect(host.subscriberCount() == 0)
    }
}

/// A subscriber that asks for two values, returns demand from its second, and records what arrives.
///
/// It is not `Sendable`: the publisher calls it on the main actor, where the test creates it.
private final class ReturningDemand: Subscriber {
    typealias Input = GeneratedTransfers.Snapshot
    typealias Failure = Never
    private(set) var subscription: (any Subscription)?
    private(set) var revisions: [UInt64] = []
    let completed = Signal()

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(.max(2))
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        revisions.append(input.revision)
        return revisions.count == 2 ? .max(1) : .none
    }
    func receive(completion: Subscribers.Completion<Never>) { completed.raise() }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SnapshotPublisherDemandTests {
    @Test func demandReturnedFromADeliveryNeverStrandsALaterRequest() async throws {
        let host = try transfers(subscribers: 4)
        let subscriber = ReturningDemand()
        try host.snapshotPublisher().subscribe(subscriber)
        #expect(subscriber.revisions == [0])
        // The publisher's wake for the initial request is queued on the main actor before this one.
        await withCheckedContinuation { continuation in Task { @MainActor in continuation.resume() } }
        #expect(await host.flush(through: try host.send(.goOffline)) == .processed)
        #expect(await host.flush(through: try host.send(.goOnline)) == .processed)
        #expect(subscriber.revisions == [0, 1, 2])
        let closed = host.close()
        #expect(await host.flush(through: closed) == .processed)
        // The closed snapshot waits for demand; one explicit request delivers it and the completion.
        subscriber.subscription?.request(.max(1))
        await subscriber.completed.wait()
        #expect(subscriber.revisions == [0, 1, 2, closed.revision])
    }
}
