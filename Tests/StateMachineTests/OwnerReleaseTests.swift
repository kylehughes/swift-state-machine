import Combine
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing

private typealias Engine = RuntimeState<Int, Int>
private typealias SharedHost = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>
private typealias MainHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>

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

private func sharedTransfers() -> GeneratedTransfers.Shared {
    GeneratedTransfers.Shared(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
}

@MainActor private func mainTransfers() -> GeneratedTransfers.MainActorHost {
    GeneratedTransfers.MainActorHost(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
}

private func actorTransfers() -> GeneratedTransfers.ActorHost {
    GeneratedTransfers.ActorHost(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
}

@MainActor private func makeMainHost() -> MainHost {
    MainHost(
        0,
        scopes: [],
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

private func makeSharedHost(subscribers: Int) throws -> SharedHost {
    SharedHost(
        manual: 0,
        scopes: [],
        limits: try Limits(),
        subscriberCapacity: subscribers,
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

/// A subscriber that requests nothing and signals its completion.
private final class Undemanding: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var subscription: (any Subscription)?
    private(set) var received: [UInt64] = []
    private let completed: Signal
    init(_ completed: Signal) { self.completed = completed }
    func receive(subscription: any Subscription) { self.subscription = subscription }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        received.append(input)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { completed.raise() }
}

/// An observer that the owner keeps until its storage is destroyed, so its finish shows that the
/// owner's storage was released, whatever another observer of that owner still holds.
private struct StorageWitness {
    let finished = Signal()
    private let token: GeneratedTransfers.Subscription

    init(_ owner: GeneratedTransfers.Shared) throws {
        let finished = finished
        token = try owner.subscribe({ _ in }, onFinish: { finished.raise() })
    }

    func waitForRelease() async {
        await finished.wait()
        withExtendedLifetime(token) {}
    }
}

/// No observer keeps its owner: dropping the owner destroys it at once, and each observer then ends,
/// which shows the owner's storage released its registrations, whether the observer was read, left
/// between reads, cancelled, or never read.
@Suite(.timeLimit(.minutes(1))) struct SharedOwnerReleaseTests {
    @Test func anUnreadSequenceKeepsNeitherItsOwnerNorItsStorage() async throws {
        var owner: GeneratedTransfers.Shared? = sharedTransfers()
        let snapshots = try #require(owner).snapshots()
        weak let released = owner
        owner = nil
        #expect(released == nil)
        // The sequence ends only once the owner's storage has released its registration.
        for await _ in snapshots {}
    }

    @Test func aSequenceLeftBetweenReadsKeepsNeitherItsOwnerNorItsStorage() async throws {
        var owner: GeneratedTransfers.Shared? = sharedTransfers()
        let snapshots = try #require(owner).snapshots()
        var iterator = snapshots.makeAsyncIterator()
        #expect(await iterator.next()?.revision == 0)
        weak let released = owner
        owner = nil
        #expect(released == nil)
        #expect(await iterator.next() == nil)
    }

    @Test func aCancelledSequenceKeepsNeitherItsOwnerNorItsStorage() async throws {
        var owner: GeneratedTransfers.Shared? = sharedTransfers()
        let witness = try StorageWitness(try #require(owner))
        let snapshots = try #require(owner).snapshots()
        snapshots.cancel()
        weak let released = owner
        owner = nil
        #expect(released == nil)
        await witness.waitForRelease()
        withExtendedLifetime(snapshots) {}
    }

    @Test func aClaimedConsumerKeepsNeitherItsOwnerNorItsStorage() async throws {
        var owner: GeneratedTransfers.Shared? = sharedTransfers()
        let snapshots = try #require(owner).snapshots()
        let consumer = try #require(snapshots.claim())
        weak let released = owner
        owner = nil
        #expect(released == nil)
        while await consumer.next() != nil {}
    }

    @MainActor @Test func aPublisherWithASubscriberKeepsNeitherItsOwnerNorItsStorage() async throws {
        var owner: GeneratedTransfers.Shared? = sharedTransfers()
        let completed = Signal()
        let subscriber = Undemanding(completed)
        try #require(owner).snapshotPublisher { $0.revision }.subscribe(subscriber)
        weak let released = owner
        owner = nil
        #expect(released == nil)
        // The subscriber completes only once the owner's storage has released the publisher's registration.
        await completed.wait()
        #expect(subscriber.received.isEmpty)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorOwnerReleaseTests {
    @Test func anUnreadStreamKeepsNeitherItsOwnerNorItsRegistration() async throws {
        var owner: MainHost? = makeMainHost()
        var snapshots = try #require(owner).snapshots()
        weak let released = owner
        owner = nil
        #expect(released == nil)
        while await snapshots.next() != nil {}
    }

    @Test func aCancelledStreamKeepsItsOwnerNoLonger() throws {
        var owner: MainHost? = makeMainHost()
        var snapshots = try #require(owner).snapshots()
        snapshots.cancel()
        weak let released = owner
        owner = nil
        #expect(released == nil)
    }

    @Test func anUnreadSendableSequenceKeepsNeitherItsOwnerNorItsRegistration() async throws {
        var owner: GeneratedTransfers.MainActorHost? = mainTransfers()
        let snapshots = try #require(owner).snapshots()
        weak let released = owner
        owner = nil
        #expect(released == nil)
        for await _ in snapshots {}
    }

    @Test func aPublisherWithASubscriberKeepsItsOwnerNoLonger() async throws {
        var owner: GeneratedTransfers.MainActorHost? = mainTransfers()
        let completed = Signal()
        let subscriber = Undemanding(completed)
        try #require(owner).snapshotPublisher { $0.revision }.subscribe(subscriber)
        weak let released = owner
        owner = nil
        #expect(released == nil)
        await completed.wait()
        #expect(subscriber.received.isEmpty)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ActorOwnerReleaseWithObserversTests {
    // An actor's executor can hold it for a moment after its last job, so the test reads the weak
    // reference only after the end of observation shows that the owner's destructor ran.
    @Test func aPublisherWithASubscriberKeepsItsActorOwnerNoLonger() async throws {
        var owner: GeneratedTransfers.ActorHost? = actorTransfers()
        let completed = Signal()
        let subscriber = Undemanding(completed)
        try await #require(owner).snapshotPublisher { $0.revision }.subscribe(subscriber)
        weak let released = owner
        owner = nil
        await completed.wait()
        #expect(released == nil)
        #expect(subscriber.received.isEmpty)
    }

    @Test func anUnreadSequenceKeepsItsActorOwnerNoLonger() async throws {
        var owner: GeneratedTransfers.ActorHost? = actorTransfers()
        let snapshots = try await #require(owner).snapshots()
        weak let released = owner
        owner = nil
        for await _ in snapshots {}
        #expect(released == nil)
    }
}

/// A presentation never keeps its owner, and dropping a presentation while it observes releases its
/// registration.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationReleaseTests {
    @Test func aPresentationOutlivingItsSharedOwnerEndsTheObservation() async throws {
        var owner: GeneratedTransfers.Shared? = sharedTransfers()
        let presentation = SnapshotObservableObject(try #require(owner).snapshot())
        try presentation.observe(try #require(owner))
        #expect(presentation.isObserving)
        let ended = Signal()
        let cancellable = presentation.$isObserving.dropFirst().sink { if !$0 { ended.raise() } }
        weak let released = owner
        owner = nil
        #expect(released == nil)
        await ended.wait()
        #expect(!presentation.isObserving)
        cancellable.cancel()
    }

    @Test func droppingAnObservingPresentationReleasesItsRegistration() async throws {
        let owner = try makeSharedHost(subscribers: 1)
        let detached = Signal()
        var presentation: SnapshotObservableObject<Engine.Snapshot>? = SnapshotObservableObject(
            owner.snapshot(),
            revision: \.revision
        )
        try #require(presentation).observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        await untilObserving(try #require(presentation))
        #expect(owner.subscriberCount == 1)
        weak let released = presentation
        presentation = nil
        #expect(released == nil)
        // The owner releases the callbacks only after the registration is removed.
        await detached.wait()
        #expect(owner.subscriberCount == 0)
        _ = owner.close()
    }

    @Test func droppingAnObservingObservationPresentationReleasesItsRegistration() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let owner = try makeSharedHost(subscribers: 1)
        let detached = Signal()
        var presentation: SnapshotPresentation<Engine.Snapshot>? = SnapshotPresentation(
            owner.snapshot(),
            revision: \.revision
        )
        try #require(presentation).observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        await untilObserving(try #require(presentation))
        weak let released = presentation
        presentation = nil
        #expect(released == nil)
        await detached.wait()
        #expect(owner.subscriberCount == 0)
        _ = owner.close()
    }
}
