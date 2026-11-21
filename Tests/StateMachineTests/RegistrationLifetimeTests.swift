import Combine
import Foundation
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

/// A value read from any thread.
private final class Recorded<Value: Sendable>: Sendable {
    private let storage = AtomicRecordStorage<Value?>(nil)
    var value: Value? { storage.load().value }
    func record(_ value: Value) {
        while true {
            let before = storage.load()
            if storage.install(.init(value), replacing: before) { return }
        }
    }
}

/// Records that it has been destroyed.
///
/// A test that finds it alive before a synchronous main-actor call and destroyed after it knows the
/// call released it, on the main actor.
private final class OwnerTurnMarker: Sendable {
    private let destroyed: Recorded<Bool>
    init(_ destroyed: Recorded<Bool>) { self.destroyed = destroyed }
    deinit { destroyed.record(true) }
}

/// Holds the last reference to a value until a detached task takes it, so it is released off the main actor.
private final class OffActorRelease<Value: Sendable>: Sendable {
    private let storage: AtomicRecordStorage<Value?>
    init(_ value: Value) { storage = AtomicRecordStorage(value) }
    func release() async {
        let storage = storage
        await Task.detached {
            let held = storage.load()
            _ = storage.install(.init(nil), replacing: held)
        }
        .value
    }
}

/// A main-actor object whose nonisolated destructor releases the registration token it stores.
@MainActor private final class TokenHolder {
    let token: GeneratedNote.IsolatedSubscription<MainActor>
    init(_ token: GeneratedNote.IsolatedSubscription<MainActor>) { self.token = token }
}

/// A main-actor object whose nonisolated destructor releases the host it stores.
@MainActor private final class HostHolder {
    let host: GeneratedNote.IsolatedHost<MainActor>
    init(_ host: GeneratedNote.IsolatedHost<MainActor>) { self.host = host }
}

@MainActor private func note() -> GeneratedNote.IsolatedHost<MainActor> {
    GeneratedNote.IsolatedHost(
        isolation: MainActor.shared,
        saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) }
    )
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct IsolatedRegistrationReleaseTests {
    // The token is not `Sendable`, but an object on the owning actor that stores it can be released
    // elsewhere. Its destructor then ends the registration through its gate alone, and the owning
    // actor releases the callbacks on its next turn with the host.
    @Test func aTokenReleasedOffTheActorLeavesItsCallbacksToTheOwningActor() async throws {
        let host = note()
        let destroyed = Recorded<Bool>()
        let release: OffActorRelease<TokenHolder>
        do {
            let marker = OwnerTurnMarker(destroyed)
            release = OffActorRelease(
                TokenHolder(try host.subscribe({ [marker] _ in withExtendedLifetime(marker) {} }))
            )
        }
        #expect(host.subscriberCount() == 1)
        await release.release()
        #expect(host.subscriberCount() == 0)
        #expect(destroyed.value == nil)
        _ = host.snapshot()
        #expect(destroyed.value == true)
        host.close()
    }

    @Test func aConfinedStreamEndsWhenItsHostIsReleasedOffTheActor() async throws {
        var holder: HostHolder? = HostHolder(note())
        var snapshots = try #require(holder).host.snapshots()
        #expect(await snapshots.next()?.revision == 0)
        let release = OffActorRelease(try #require(holder))
        holder = nil
        await release.release()
        #expect(await snapshots.next() == nil)
    }

    // An ended projection takes no slot at once; the host releases its transform on its next turn of any kind.
    @Test func anEndedProjectionReleasesItsTransformOnTheHostsNextTurn() async throws {
        let host = note()
        let destroyed = Recorded<Bool>()
        let consumer: Task<Void, Never>
        do {
            let marker = OwnerTurnMarker(destroyed)
            let titles = try host.snapshots { [marker] snapshot in
                withExtendedLifetime(marker) {}
                return snapshot.revision
            }
            consumer = Task.detached { for await _ in titles {} }
        }
        consumer.cancel()
        await consumer.value
        #expect(host.subscriberCount() == 0)
        #expect(destroyed.value == nil)
        _ = host.snapshot()
        #expect(destroyed.value == true)
        host.close()
    }
}

private typealias MainHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>
private typealias Engine = RuntimeState<Int, Int>
private let scope = RuntimeScopeID(kind: 1)
private let operation = RuntimeOperation(kind: 0, scope: scope)

// Every outcome is refused, so a delivered outcome stays parked until it is discarded.
@MainActor private func parkingHost(subscribers: Int = 128, parked: Signal? = nil) throws -> MainHost {
    MainHost(
        0,
        scopes: [scope],
        configuration: try ManagedConfiguration(subscribers: subscribers),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
        reconciliationRequired: { _ in parked?.raise() }
    )
}

@MainActor private func park(on owner: MainHost, _ parked: Signal) async throws {
    let plan = Engine.Plan(starts: [.init(operation, descriptor: 0)])
    _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: 0, plan: plan))
    await parked.wait()
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct InitialPendingPublicationTests {
    // The projection discards the completion it is shown, so the publication it causes offers the
    // empty collection first. The seed it was computing must not be offered after that.
    @Test func aProjectionThatDiscardsDuringItsSeedEndsWithTheNewestCollection() async throws {
        let parked = Signal()
        let owner = try parkingHost(parked: parked)
        try await park(on: owner, parked)
        #expect(owner.pendingCompletions().count == 1)
        weak let host = owner
        let counts = try owner.sendablePendingCompletionUpdates { rows -> Int in
            if let first = rows.first { _ = host?.discardPending(id: first.id) }
            return rows.count
        }
        var iterator = counts.makeAsyncIterator()
        #expect(owner.pendingCompletions().count == 0)
        #expect(await iterator.next() == 0)
        await owner.shutdown()
    }

    @Test func anIsolatedProjectionThatDiscardsDuringItsSeedEndsWithTheNewestCollection() async throws {
        let bench = await PendingBench()
        let (latest, remaining) = try await bench.latestCountAfterASeedDiscards()
        #expect(remaining == 0)
        #expect(latest == 0)
        await bench.shutdown()
    }
}

/// The actor that owns an isolated host whose refused outcomes stay parked.
private actor PendingBench {
    typealias Host = RuntimeIsolatedHost<PendingBench, Int, Int, RuntimeTicket, Never>
    private var host: Host!
    private let parked = Signal()

    init() async {
        let parked = parked
        host = Host(
            0,
            scopes: [scope],
            isolation: self,
            driver: { _, work in work.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
            reconciliationRequired: { _ in parked.raise() }
        )
    }

    func latestCountAfterASeedDiscards() async throws -> (Int?, Int) {
        let plan = Engine.Plan(starts: [.init(operation, descriptor: 0)])
        _ = host.commit(try Engine.prepare(on: host.snapshot(isolation: self), next: 0, plan: plan), isolation: self)
        await parked.wait()
        let counts = try host.sendablePendingCompletionUpdates(
            { rows -> Int in
                if let first = rows.first { _ = self.host.discardPending(id: first.id, isolation: self) }
                return rows.count
            },
            isolation: self
        )
        let remaining = host.pendingCompletions(isolation: self).count
        var iterator = counts.makeAsyncIterator()
        return (await iterator.next(), remaining)
    }

    func shutdown() async { await host.shutdown(isolation: self) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SendableProjectionSlotTests {
    // The consumer runs on the main actor and checks the slot in the same turn its iterator ends.
    @Test func anEndedSnapshotProjectionFreesItsSlotInTheTurnItEnds() async throws {
        let owner = try parkingHost(subscribers: 1)
        let revisions = try owner.sendableSnapshots { $0.revision }
        let consumer = Task { @MainActor in
            var iterator = revisions.makeAsyncIterator()
            _ = await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            let ended = await iterator.next() == nil
            return (ended, owner.subscriberCount, (try? owner.sendableSnapshots { $0.revision }) != nil)
        }
        let (ended, count, replaced) = await consumer.value
        #expect(ended && count == 0 && replaced)
        await owner.shutdown()
    }

    @Test func anEndedPendingProjectionFreesItsSlotInTheTurnItEnds() async throws {
        let owner = try parkingHost(subscribers: 1)
        let counts = try owner.sendablePendingCompletionUpdates { $0.count }
        let consumer = Task { @MainActor in
            var iterator = counts.makeAsyncIterator()
            _ = await iterator.next()
            withUnsafeCurrentTask { $0?.cancel() }
            let ended = await iterator.next() == nil
            return (ended, owner.subscriberCount, (try? owner.sendablePendingCompletionUpdates { $0.count }) != nil)
        }
        let (ended, count, replaced) = await consumer.value
        #expect(ended && count == 0 && replaced)
        await owner.shutdown()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorTeardownTests {
    // Releasing an open host queues the finishes of its live registrations. A registration
    // cancelled in the same turn must not begin its finish; the control registration, registered
    // later, finishes in the same queued turn and marks that the turn has run.
    @Test func aRegistrationCancelledAfterItsHostIsReleasedDoesNotFinish() async throws {
        var owner: MainHost? = try parkingHost()
        var cancelledFinished = false
        let controlFinished = Signal()
        let cancelled = try #require(owner).subscribe({ _ in }, onFinish: { cancelledFinished = true })
        let control = try #require(owner).subscribe({ _ in }, onFinish: { controlFinished.raise() })
        owner = nil
        cancelled.cancel()
        await controlFinished.wait()
        #expect(!cancelledFinished)
        _ = control
    }
}

/// A subscriber that requests nothing and records its completion.
private final class Undemanding: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var subscription: (any Subscription)?
    private(set) var received: [UInt64] = []
    private(set) var finished = false
    private let completed: Signal
    init(_ completed: Signal) { self.completed = completed }
    func receive(subscription: any Subscription) { self.subscription = subscription }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        received.append(input)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        finished = true
        completed.raise()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PublisherReleaseTests {
    // Releasing an open owner promises no closed snapshot, so an undemanded ordinary value is
    // discarded and the subscriber finishes without demand.
    @Test func releasingAnOpenOwnerFinishesASubscriberWithoutDemand() async throws {
        var owner: MainHost? = try parkingHost()
        let completed = Signal()
        let subscriber = Undemanding(completed)
        try #require(owner).snapshotPublisher { $0.revision }.subscribe(subscriber)
        owner = nil
        await completed.wait()
        #expect(subscriber.finished)
        #expect(subscriber.received.isEmpty)
    }

    // Closing promises the closed snapshot, so it waits for demand and then finishes.
    @Test func closingKeepsTheClosedSnapshotForDemand() async throws {
        let owner = try parkingHost()
        let completed = Signal()
        let subscriber = Undemanding(completed)
        try owner.snapshotPublisher { $0.revision }.subscribe(subscriber)
        let closed = owner.close()
        #expect(await owner.flush(through: closed))
        #expect(!subscriber.finished)
        subscriber.subscription?.request(.max(1))
        await completed.wait()
        #expect(subscriber.received == [closed.revision])
        #expect(subscriber.finished)
    }

    @Test func releasingAnOpenSharedOwnerFinishesASubscriberWithoutDemand() async throws {
        var owner: RuntimeSharedHost<Int, Int, RuntimeTicket, Never>? = RuntimeSharedHost(
            0,
            scopes: [],
            limits: try Limits(),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let completed = Signal()
        let subscriber = Undemanding(completed)
        try #require(owner).snapshotPublisher { $0.revision }.subscribe(subscriber)
        owner = nil
        await completed.wait()
        #expect(subscriber.finished)
        #expect(subscriber.received.isEmpty)
    }
}

@MainActor private func transfers(subscribers: Int) throws -> GeneratedTransfers.MainActorHost {
    GeneratedTransfers.MainActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SeedReentryTests {
    // The seed arrives while the host is still registering. A callback of its publication that
    // observes the same capacity-one host again must find the first registration owned by the
    // presentation, end it, and take the slot.
    @Test func reobservingFromTheSeedKeepsOneRegistration() throws {
        let host = try transfers(subscribers: 1)
        let presentation = SnapshotObservableObject(host.snapshot())
        var failure: (any Error)?
        var armed = true
        let rebinding = presentation.presentedSnapshots.dropFirst()
            .sink { _ in
                guard armed else { return }
                armed = false
                do { try presentation.observe(host) } catch { failure = error }
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

    @Test func reobservingAnObservationPresentationFromTheSeedKeepsOneRegistration() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = try transfers(subscribers: 1)
        let presentation = SnapshotPresentation(host.snapshot())
        var failure: (any Error)?
        withObservationTracking {
            _ = presentation.snapshot
        } onChange: {
            MainActor.assumeIsolated {
                do { try presentation.observe(host) } catch { failure = error }
            }
        }
        try presentation.observe(host)
        #expect(failure == nil)
        #expect(presentation.isObserving)
        #expect(host.subscriberCount == 1)
        presentation.stopObserving()
        #expect(host.subscriberCount == 0)
    }
}

/// A snapshot whose payload runs an action when its last copy is destroyed.
private struct GuardedSnapshot {
    final class Payload {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        deinit { action() }
    }
    let revision: UInt64
    let payload: Payload?
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationDisplacedSnapshotTests {
    // The replaced snapshot's destructor reads the presentation, which already shows its successor.
    @Test func applyingASnapshotReleasesTheReplacedOneAfterShowingItsSuccessor() {
        var observed: UInt64?
        weak var weakPresentation: SnapshotObservableObject<GuardedSnapshot>?
        let presentation = SnapshotObservableObject(
            GuardedSnapshot(revision: 0, payload: .init { observed = weakPresentation?.snapshot.revision }),
            revision: { $0.revision }
        )
        weakPresentation = presentation
        #expect(presentation.apply(GuardedSnapshot(revision: 1, payload: nil)))
        #expect(observed == 1)
    }

    @Test func anObservationPresentationReleasesTheReplacedSnapshotAfterShowingItsSuccessor() {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        var observed: UInt64?
        weak var weakPresentation: SnapshotPresentation<GuardedSnapshot>?
        let presentation = SnapshotPresentation(
            GuardedSnapshot(revision: 0, payload: .init { observed = weakPresentation?.snapshot.revision }),
            revision: { $0.revision }
        )
        weakPresentation = presentation
        #expect(presentation.apply(GuardedSnapshot(revision: 1, payload: nil)))
        #expect(observed == 1)
    }
}

/// A subscriber that requests every value and records what it receives.
private final class Demanding: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var received: [UInt64] = []
    private(set) var finished = false
    private let completed: Signal
    init(_ completed: Signal) { self.completed = completed }
    func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        received.append(input)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        finished = true
        completed.raise()
    }
}

/// The callbacks a `Sendable` owner holds for one publisher registration, which a test calls and
/// releases as that owner would.
@MainActor private final class OwnerCallbacks {
    var receive: (@Sendable (UInt64) -> Void)?
    var finish: (@Sendable () -> Void)?
    var released: (@Sendable () -> Void)?
    // The owner's lifetime gate, which its release without closing closes before any notice.
    private let lifetime = RuntimeRegistrationGate()

    /// Registers a publisher whose closed snapshots are the odd revisions.
    func publisher() throws -> SnapshotPublisher<UInt64> {
        try SnapshotPublisher({ $0 }, isFinal: { $0 % 2 == 1 }, ownerLifetime: lifetime) {
            (receive, finish, released) throws(SubscriptionFailure) in
            self.receive = receive
            self.finish = finish
            self.released = released
            return SnapshotSubscription({})
        }
    }

    /// Reports the owner's release without closing and releases the receive callback, as an owner
    /// released while open does before its queued finish.
    func releaseOpen() {
        lifetime.close()
        released?()
        receive = nil
    }
    /// Releases the receive callback, as a closed owner does after its last delivery.
    func releaseReceive() { receive = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SendablePublisherReleaseTests {
    // The owner delivered its open seed and released the registration; its finish has not run. The
    // seed is still on its way to the main actor when the subscriber attaches, and the subscriber's
    // first demand finds the publisher finished, with nothing to deliver.
    @Test func demandAfterAnOpenOwnersReleaseFinishesWithoutTheSeedStillInIngress() throws {
        let owner = OwnerCallbacks()
        let publisher = try owner.publisher()
        owner.receive?(0)
        owner.releaseOpen()
        let subscriber = Demanding(Signal())
        publisher.subscribe(subscriber)
        #expect(subscriber.finished)
        #expect(subscriber.received.isEmpty)
        owner.finish?()
    }

    // The seed has reached the main-actor channel before the release. The main actor runs its
    // enqueued jobs in order, so the test's own job, enqueued after the seed's hand-off, runs after it.
    @Test func demandAfterAnOpenOwnersReleaseFinishesWithoutTheSeedInTheChannel() async throws {
        let owner = OwnerCallbacks()
        let publisher = try owner.publisher()
        owner.receive?(0)
        await Task { @MainActor in }.value
        owner.releaseOpen()
        let subscriber = Demanding(Signal())
        publisher.subscribe(subscriber)
        #expect(subscriber.finished)
        #expect(subscriber.received.isEmpty)
        owner.finish?()
    }

    // An ordinary snapshot and the finish of an owner released without closing reach the ingress in
    // one update. The finish promises nothing more, so the snapshot is discarded.
    @Test func aFinishIsNotOvertakenByAnOrdinarySnapshotFromTheSameUpdate() async throws {
        let owner = OwnerCallbacks()
        let publisher = try owner.publisher()
        let completed = Signal()
        let subscriber = Demanding(completed)
        publisher.subscribe(subscriber)
        owner.receive?(2)
        owner.finish?()
        await completed.wait()
        #expect(subscriber.received.isEmpty)
        owner.releaseReceive()
    }

    // A closed owner delivers its closed snapshot, finishes, and releases its callbacks before the
    // snapshot reaches the main actor. The closed snapshot waits for demand.
    @Test func aClosedSnapshotStillInIngressWaitsForDemand() async throws {
        let owner = OwnerCallbacks()
        let publisher = try owner.publisher()
        let completed = Signal()
        let subscriber = Undemanding(completed)
        publisher.subscribe(subscriber)
        owner.receive?(3)
        owner.finish?()
        owner.releaseReceive()
        #expect(!subscriber.finished)
        subscriber.subscription?.request(.max(1))
        await completed.wait()
        #expect(subscriber.received == [3])
    }

    // A closed owner reports no release, so the closed snapshot reaches a late subscriber through the
    // ingress, and the publisher then finishes.
    @Test func aClosedSnapshotStillInIngressReachesALateSubscriber() async throws {
        let owner = OwnerCallbacks()
        let publisher = try owner.publisher()
        owner.receive?(3)
        owner.finish?()
        owner.releaseReceive()
        let completed = Signal()
        let subscriber = Demanding(completed)
        publisher.subscribe(subscriber)
        await completed.wait()
        #expect(subscriber.received == [3])
        #expect(subscriber.finished)
    }
}

/// Records whether it has been destroyed.
private final class ReleaseMarker: Sendable {
    private let destroyed: Recorded<Bool>
    init(_ destroyed: Recorded<Bool>) { self.destroyed = destroyed }
    deinit { destroyed.record(true) }
}

private func actorTransfers() -> GeneratedTransfers.ActorHost {
    GeneratedTransfers.ActorHost(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ActorOwnerReleaseTests {
    // An actor owner released without closing releases each registration's receive callback before
    // it finishes that registration.
    @Test func anActorOwnerReleasesItsReceiveCallbacksBeforeItFinishes() async throws {
        var owner: GeneratedTransfers.ActorHost? = actorTransfers()
        let destroyed = Recorded<Bool>()
        let releasedFirst = Recorded<Bool>()
        let finished = Signal()
        let token: GeneratedTransfers.Subscription
        do {
            let marker = ReleaseMarker(destroyed)
            let host = try #require(owner)
            token = try await host.subscribe(
                { [marker] _ in withExtendedLifetime(marker) {} },
                onFinish: {
                    releasedFirst.record(destroyed.value == true)
                    finished.raise()
                }
            )
        }
        owner = nil
        await finished.wait()
        #expect(releasedFirst.value == true)
        withExtendedLifetime(token) {}
    }

    // The control registration finishes after the publisher's registration in the owner's queued
    // finish, so the subscriber attaches after the owner released the publisher's callback.
    @Test func demandAfterAnActorOwnersReleaseFinishesWithoutAValue() async throws {
        var owner: GeneratedTransfers.ActorHost? = actorTransfers()
        let publisher = try await #require(owner).snapshotPublisher { $0.revision }
        let finished = Signal()
        let control = try await #require(owner).subscribe({ _ in }, onFinish: { finished.raise() })
        owner = nil
        await finished.wait()
        let subscriber = Demanding(Signal())
        publisher.subscribe(subscriber)
        #expect(subscriber.finished)
        #expect(subscriber.received.isEmpty)
        withExtendedLifetime(control) {}
    }
}
