import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

// A presentation replaces one observation with the next. These tests start the next observation
// from inside the work of the one it replaces: from a callback of the change it publishes, from the
// owner's `subscribe` before that call returns, or while an actor owner still holds the earlier
// registration's slot. Each must end with exactly one live registration and a truthful
// `isObserving`.

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

/// Counts calls from any thread.
private final class Counter: Sendable {
    private let storage = AtomicRecordStorage(0)
    var value: Int { storage.load().value }
    /// Records one call and returns how many came before it.
    func next() -> Int {
        while true {
            let before = storage.load()
            if storage.install(.init(before.value + 1), replacing: before) { return before.value }
        }
    }
}

@MainActor private func transfers(subscribers: Int) throws -> GeneratedTransfers.MainActorHost {
    GeneratedTransfers.MainActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

/// The most fallbacks a test allows, so that a recursion fails the test instead of exhausting the stack.
private let fallbackLimit = 8

/// Observes a fallback whenever an Observation presentation reports that its observation is ending.
///
/// Observation reports a change before it is stored, so a presentation whose observation is ending
/// still reads `true` in the callback.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private final class FallbackOnEnd<Snapshot> {
    private let presentation: SnapshotPresentation<Snapshot>
    private let fallback: @MainActor () -> Void
    private var armed = false
    private(set) var fallbacks = 0

    init(_ presentation: SnapshotPresentation<Snapshot>, fallback: @escaping @MainActor () -> Void) {
        self.presentation = presentation
        self.fallback = fallback
    }

    func arm() {
        armed = true
        track()
    }
    func disarm() { armed = false }

    private func track() {
        withObservationTracking {
            _ = presentation.isObserving
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func changed() {
        guard armed else { return }
        changes += 1
        let ending = presentation.isObserving
        track()
        guard ending, fallbacks < fallbackLimit else { return }
        fallbacks += 1
        fallback()
    }

    /// How many changes of `isObserving` the presentation reported while armed.
    private(set) var changes = 0
}

/// Observes a fallback whenever a Combine presentation reports that its observation ended, and
/// records every value it publishes.
@MainActor private final class FallbackOnPublishedEnd {
    private(set) var published: [Bool] = []
    private(set) var fallbacks = 0
    private(set) var failure: SubscriptionFailure?
    private var subscription: AnyCancellable?

    init<Snapshot>(
        _ presentation: SnapshotObservableObject<Snapshot>,
        fallback: @escaping @MainActor () throws(SubscriptionFailure) -> Void
    ) {
        subscription = presentation.$isObserving.dropFirst()
            .sink { [unowned self] observing in
                published.append(observing)
                guard !observing, fallbacks < fallbackLimit else { return }
                fallbacks += 1
                do throws(SubscriptionFailure) { try fallback() } catch { failure = error }
            }
    }

    func disarm() { subscription = nil }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationPublicationTests {
    // The sink observes a backup when observation ends. The presentation reports the end, then the
    // backup's registration, once each and in that order.
    @Test func observingAFallbackWhenObservationEndsReportsTheEndThenTheFallback() throws {
        let primary = try transfers(subscribers: 1)
        let backup = try transfers(subscribers: 1)
        let presentation = SnapshotObservableObject(primary.snapshot())
        try presentation.observe(primary)
        let fallback = FallbackOnPublishedEnd(presentation) { () throws(SubscriptionFailure) in
            try presentation.observe(backup)
        }
        presentation.stopObserving()
        fallback.disarm()
        #expect(fallback.published == [false, true])
        #expect(fallback.fallbacks == 1)
        #expect(fallback.failure == nil)
        #expect(presentation.isObserving)
        #expect(primary.subscriberCount == 0 && backup.subscriberCount == 1)
        presentation.stopObserving()
        #expect(backup.subscriberCount == 0)
    }

    // The backup has no free slot. The refused fallback reports nothing more, so the end that
    // started it is the only one, and the fallback receives the refusal.
    @Test func aRefusedFallbackReportsTheEndOnceAndThrows() throws {
        let primary = try transfers(subscribers: 1)
        let backup = try transfers(subscribers: 1)
        let holder = try backup.subscribe { _ in }
        let presentation = SnapshotObservableObject(primary.snapshot())
        try presentation.observe(primary)
        let fallback = FallbackOnPublishedEnd(presentation) { () throws(SubscriptionFailure) in
            try presentation.observe(backup)
        }
        presentation.stopObserving()
        fallback.disarm()
        #expect(fallback.published == [false])
        #expect(fallback.fallbacks == 1)
        #expect(fallback.failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(primary.subscriberCount == 0 && backup.subscriberCount == 1)
        holder.cancel()
    }

    @Test func aRefusedSharedFallbackReportsTheEndOnceAndThrows() throws {
        let primary = try transfers(subscribers: 1)
        let backup = GeneratedTransfers.Shared(
            downloadDriver: { _, _ in .success("") },
            onLogged: { _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 1)
        )
        let holder = try backup.snapshots()
        let presentation = SnapshotObservableObject(primary.snapshot())
        try presentation.observe(primary)
        let fallback = FallbackOnPublishedEnd(presentation) { () throws(SubscriptionFailure) in
            try presentation.observe(backup)
        }
        presentation.stopObserving()
        fallback.disarm()
        #expect(fallback.published == [false])
        #expect(fallback.fallbacks == 1)
        #expect(fallback.failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        withExtendedLifetime(holder) {}
    }

    @Test func anObservationPresentationObservingAFallbackWhenObservationEndsReportsTheEndThenTheFallback() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let primary = try transfers(subscribers: 1)
        let backup = try transfers(subscribers: 1)
        let presentation = SnapshotPresentation(primary.snapshot())
        try presentation.observe(primary)
        let fallback = FallbackOnEnd(presentation) { try? presentation.observe(backup) }
        fallback.arm()
        presentation.stopObserving()
        fallback.disarm()
        #expect(fallback.fallbacks == 1)
        #expect(fallback.changes == 2)
        #expect(presentation.isObserving)
        #expect(primary.subscriberCount == 0 && backup.subscriberCount == 1)
        presentation.stopObserving()
        #expect(backup.subscriberCount == 0)
    }

    @Test func anObservationPresentationReportsARefusedFallbacksEndOnce() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let primary = try transfers(subscribers: 1)
        let backup = try transfers(subscribers: 1)
        let holder = try backup.subscribe { _ in }
        let presentation = SnapshotPresentation(primary.snapshot())
        try presentation.observe(primary)
        var failure: SubscriptionFailure?
        let fallback = FallbackOnEnd(presentation) {
            do throws(SubscriptionFailure) { try presentation.observe(backup) } catch { failure = error }
        }
        fallback.arm()
        presentation.stopObserving()
        fallback.disarm()
        #expect(fallback.fallbacks == 1)
        #expect(fallback.changes == 1)
        #expect(failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(primary.subscriberCount == 0 && backup.subscriberCount == 1)
        holder.cancel()
    }

    // Stopping a stopped presentation publishes nothing, so a sink that stops again on every end runs once.
    @Test func stoppingADrivingPresentationFromItsEndReportsTheEndOnce() throws {
        let presentation = StateMachineObservableObject(try transfers(subscribers: 1))
        #expect(presentation.isObserving)
        var ends = 0
        let stopping = presentation.$isObserving.dropFirst()
            .sink { observing in
                guard !observing, ends < fallbackLimit else { return }
                ends += 1
                presentation.stopObserving()
            }
        presentation.stopObserving()
        stopping.cancel()
        #expect(ends == 1)
        #expect(!presentation.isObserving)
        #expect(presentation.host.subscriberCount == 0)
    }

    @Test func stoppingAnObservationDrivingPresentationFromItsEndReportsTheEndOnce() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let presentation = StateMachinePresentation(try transfers(subscribers: 1))
        let stopping = StopOnEnd(presentation)
        stopping.arm()
        presentation.stopObserving()
        #expect(stopping.ends == 1)
        #expect(!presentation.isObserving)
        #expect(presentation.host.subscriberCount == 0)
    }
}

/// Stops a driving Observation presentation again whenever it reports that its registration is ending.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private final class StopOnEnd<Host: MainActorStateMachineHost> {
    private let presentation: StateMachinePresentation<Host>
    private(set) var ends = 0

    init(_ presentation: StateMachinePresentation<Host>) { self.presentation = presentation }

    func arm() {
        withObservationTracking {
            _ = presentation.isObserving
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func changed() {
        // The change is reported before it is stored, so an ending registration still reads `true`.
        let ending = presentation.isObserving
        arm()
        guard ending, ends < fallbackLimit else { return }
        ends += 1
        presentation.stopObserving()
    }
}

/// A `MainActor` owner that forwards to a generated host and runs a hook after that host registers
/// an observer and before it returns the registration.
@MainActor private final class RegisteringHost: MainActorStateMachineHost {
    typealias Inner = GeneratedTransfers.MainActorHost
    let inner: Inner
    /// Runs once, inside the next `subscribe`, after the inner host registered and delivered its seed.
    var whileRegistering: (@MainActor () -> Void)?

    init(_ inner: Inner) { self.inner = inner }

    func snapshot() -> Inner.Snapshot { inner.snapshot() }
    func send(_ input: Inner.Input) throws(Inner.SendRejection) -> Inner.Receipt { try inner.send(input) }
    func commit(_ prepared: consuming Inner.Prepared) -> Inner.CommitResult { inner.commit(prepared) }
    func subscribe(
        _ receive: @escaping @MainActor (Inner.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        let token = try inner.subscribe(receive, onFinish: onFinish)
        let hook = whileRegistering
        whileRegistering = nil
        hook?()
        return token
    }
    func close() -> Inner.Receipt { inner.close() }
}

/// An owner confined to the main actor that forwards to a generated host and runs a hook after that
/// host registers an observer and before it returns the registration.
private final class RegisteringIsolatedHost<Owner: Actor>: IsolatedStateMachineHost {
    typealias Inner = GeneratedTransfers.IsolatedHost<Owner>
    let inner: Inner
    /// Runs once, on the owning actor, inside the next `subscribe`, after the inner host registered.
    var whileRegistering: (() -> Void)?
    /// Whether a refused registration's callbacks are kept, as an owner that releases them late does.
    var keepsRefusedCallbacks = false
    /// The callbacks of the registrations the inner host refused, while they are kept.
    var refusedCallbacks: [(receive: (Inner.Snapshot) -> Void, finish: () -> Void)] = []

    init(_ inner: Inner) { self.inner = inner }

    func snapshot(isolation: isolated Owner) -> Inner.Snapshot { inner.snapshot(isolation: isolation) }
    func subscribe(
        _ receive: @escaping (Inner.Snapshot) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Owner> {
        let token: IsolatedSnapshotSubscription<Owner>
        do {
            token = try inner.subscribe(receive, onFinish: onFinish, isolation: isolation)
        } catch {
            if keepsRefusedCallbacks { refusedCallbacks.append((receive, onFinish)) }
            throw error
        }
        let hook = whileRegistering
        whileRegistering = nil
        hook?()
        return token
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (Inner.Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.snapshots(transform, isolation: isolation)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (Inner.Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform, isolation: isolation)
    }
}

@MainActor private func isolatedTransfers(subscribers: Int) throws -> GeneratedTransfers.IsolatedHost<MainActor> {
    GeneratedTransfers.IsolatedHost(
        isolation: MainActor.shared,
        downloadDriver: { _, _, _ in .success("") },
        onLogged: { _, _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationReentrantRegistrationTests {
    // Registering changes the owner's subscriber count, and the Observation callback of that change
    // observes the same capacity-one owner again before the first registration is returned. The newer
    // observation is refused while the superseded one holds the slot and throws at once; the
    // superseded one releases its registration, so nothing is observed until the caller observes again.
    @Test(arguments: PresentationClass.allCases)
    func reobservingFromASubscriberCountChangeThrowsTheRefusal(_ kind: PresentationClass) throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = try transfers(subscribers: 1)
        let presentation = ReentryPresentation(kind, host.snapshot())
        var failure: SubscriptionFailure?
        var reobserved = false
        withObservationTracking {
            _ = host.subscriberCount
        } onChange: {
            MainActor.assumeIsolated {
                reobserved = true
                do throws(SubscriptionFailure) { try presentation.observe(host) } catch { failure = error }
            }
        }
        try presentation.observe(host)
        #expect(reobserved)
        #expect(failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(host.subscriberCount == 0)
        try presentation.observe(host)
        #expect(presentation.isObserving)
        #expect(host.subscriberCount == 1)
        presentation.stopObserving()
        #expect(host.subscriberCount == 0)
    }

    @Test(arguments: PresentationClass.allCases)
    func reobservingAnIsolatedOwnerFromInsideItsRegistrationThrowsTheRefusal(_ kind: PresentationClass) throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let inner = try isolatedTransfers(subscribers: 1)
        let host = RegisteringIsolatedHost(inner)
        let presentation = ReentryPresentation(kind, inner.snapshot())
        var failure: SubscriptionFailure?
        host.whileRegistering = {
            do throws(SubscriptionFailure) { try presentation.observe(host) } catch { failure = error }
        }
        try presentation.observe(host)
        #expect(failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(inner.subscriberCount() == 0)
        try presentation.observe(host)
        #expect(presentation.isObserving)
        #expect(inner.subscriberCount() == 1)
        presentation.stopObserving()
        #expect(inner.subscriberCount() == 0)
    }

    // The refused attempt's callbacks, which an owner may call or release late, belong to that attempt
    // alone, so its finish does not end a later observation of the same owner.
    @Test(arguments: PresentationClass.allCases)
    func aRefusedAttemptsLateFinishDoesNotEndALaterObservation(_ kind: PresentationClass) throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let inner = try isolatedTransfers(subscribers: 1)
        let host = RegisteringIsolatedHost(inner)
        host.keepsRefusedCallbacks = true
        let presentation = ReentryPresentation(kind, inner.snapshot())
        host.whileRegistering = { try? presentation.observe(host) }
        try presentation.observe(host)
        try #require(host.refusedCallbacks.count == 1)
        try presentation.observe(host)
        host.refusedCallbacks[0].finish()
        #expect(presentation.isObserving)
        #expect(inner.subscriberCount() == 1)
        presentation.stopObserving()
        #expect(inner.subscriberCount() == 0)
        host.refusedCallbacks = []
    }

    // The owner releases the refused attempt's callbacks, which queues that attempt's finish on the
    // main actor. The main actor runs its enqueued jobs in order, so the test's own job, enqueued
    // after it, runs after that finish.
    @Test(arguments: PresentationClass.allCases)
    func aRefusedAttemptsReleaseDoesNotEndALaterObservation(_ kind: PresentationClass) async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let inner = try isolatedTransfers(subscribers: 1)
        let host = RegisteringIsolatedHost(inner)
        let presentation = ReentryPresentation(kind, inner.snapshot())
        host.whileRegistering = { try? presentation.observe(host) }
        try presentation.observe(host)
        try presentation.observe(host)
        await Task { @MainActor in }.value
        #expect(presentation.isObserving)
        #expect(inner.subscriberCount() == 1)
        presentation.stopObserving()
        #expect(inner.subscriberCount() == 0)
    }

    // A registration with one owner cannot hold another owner's slot, so a refusal by an owner that
    // no superseded registration uses reaches the caller at once.
    @Test func anUnrelatedRegistrationDoesNotSuppressARefusal() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let primary = try transfers(subscribers: 1)
        let backup = try transfers(subscribers: 1)
        let holder = try backup.subscribe { _ in }
        let presentation = SnapshotObservableObject(primary.snapshot())
        var failure: SubscriptionFailure?
        withObservationTracking {
            _ = primary.subscriberCount
        } onChange: {
            MainActor.assumeIsolated {
                do throws(SubscriptionFailure) { try presentation.observe(backup) } catch { failure = error }
            }
        }
        try presentation.observe(primary)
        #expect(failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(primary.subscriberCount == 0 && backup.subscriberCount == 1)
        holder.cancel()
    }

    @Test func anObservationPresentationReportsARefusalThatNoSupersededRegistrationCauses() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let primary = try transfers(subscribers: 1)
        let backup = try transfers(subscribers: 1)
        let holder = try backup.subscribe { _ in }
        let presentation = SnapshotPresentation(primary.snapshot())
        var failure: SubscriptionFailure?
        withObservationTracking {
            _ = primary.subscriberCount
        } onChange: {
            MainActor.assumeIsolated {
                do throws(SubscriptionFailure) { try presentation.observe(backup) } catch { failure = error }
            }
        }
        try presentation.observe(primary)
        #expect(failure == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(primary.subscriberCount == 0 && backup.subscriberCount == 1)
        holder.cancel()
    }

    // A refusal while no superseded observation holds the slot still reports the refusal.
    @Test func aRefusalWithoutASupersededRegistrationStillThrows() throws {
        let host = try transfers(subscribers: 1)
        let holder = try host.subscribe { _ in }
        let presentation = SnapshotObservableObject(host.snapshot())
        #expect(throws: SubscriptionFailure.capacityExceeded) { try presentation.observe(host) }
        #expect(!presentation.isObserving)
        holder.cancel()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationStagingTests {
    // A forwarding owner delivers a closed owner's seed and finish, then observes an open owner before
    // returning the closed owner's registration. The open owner's observation keeps its own record of
    // what arrived while it registered, so it stays live.
    @Test func aFinishStagedForOneOwnerDoesNotEndTheNextOwnersObservation() throws {
        let closed = RegisteringHost(try transfers(subscribers: 1))
        closed.inner.close()
        let open = try transfers(subscribers: 1)
        let presentation = SnapshotObservableObject(open.snapshot())
        closed.whileRegistering = { try? presentation.observe(open) }
        try presentation.observe(closed)
        #expect(presentation.isObserving)
        #expect(open.subscriberCount == 1)
        #expect(!presentation.snapshot.isClosed)
        presentation.stopObserving()
        #expect(open.subscriberCount == 0)
    }

    @Test func anObservationPresentationKeepsEachOwnersStagedFinishToItsOwnObservation() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let closed = RegisteringHost(try transfers(subscribers: 1))
        closed.inner.close()
        let open = try transfers(subscribers: 1)
        let presentation = SnapshotPresentation(open.snapshot())
        closed.whileRegistering = { try? presentation.observe(open) }
        try presentation.observe(closed)
        #expect(presentation.isObserving)
        #expect(open.subscriberCount == 1)
        #expect(!presentation.snapshot.isClosed)
        presentation.stopObserving()
        #expect(open.subscriberCount == 0)
    }
}

/// An actor owner that forwards to a generated host.
///
/// Its first registration waits after the inner host accepts it, still holding the slot, until the
/// test lets it return; a refused registration raises `refused`.
nonisolated private final class HeldActorHost: ActorStateMachineHost {
    typealias Inner = GeneratedTransfers.ActorHost
    let inner: Inner
    let acquired = Signal()
    let proceed = Signal()
    let refused = Signal()
    private let attempts = Counter()

    init(_ inner: Inner) { self.inner = inner }

    func snapshot() async -> Inner.Snapshot { await inner.snapshot() }
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Inner.Snapshot> {
        let attempt = attempts.next()
        let snapshots: SnapshotSequence<Inner.Snapshot>
        do {
            snapshots = try await inner.snapshots()
        } catch {
            refused.raise()
            throw error
        }
        if attempt == 0 {
            acquired.raise()
            await proceed.wait()
        }
        return snapshots
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Inner.Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try await inner.snapshots(transform)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Inner.Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try await inner.distinctSnapshots(transform)
    }
}

private func actorTransfers(subscribers: Int) throws -> GeneratedTransfers.ActorHost {
    GeneratedTransfers.ActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

/// An actor that owns a capacity-one host and starts two observations of it on the main actor at once.
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

    func presentTwiceAtOnce(on presentation: SnapshotObservableObject<GeneratedTransfers.Snapshot>) async throws -> Int
    {
        let first = Task { try await presentation.observe(self.host) }
        let second = Task { try await presentation.observe(self.host) }
        try await first.value
        try await second.value
        return host.subscriberCount()
    }

    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func presentTwiceAtOnce(on presentation: SnapshotPresentation<GeneratedTransfers.Snapshot>) async throws -> Int {
        let first = Task { try await presentation.observe(self.host) }
        let second = Task { try await presentation.observe(self.host) }
        try await first.value
        try await second.value
        return host.subscriberCount()
    }

    func subscriberCount() -> Int { host.subscriberCount() }
    func close() { host.close() }

    /// Observes this owner while another registration holds its only slot, and returns the refusal.
    func observeWhileFull(
        on presentation: SnapshotObservableObject<GeneratedTransfers.Snapshot>
    ) async -> SubscriptionFailure? {
        guard let holder = try? host.subscribe({ _ in }) else { return nil }
        defer { holder.cancel() }
        do throws(SubscriptionFailure) {
            try await presentation.observe(host)
            return nil
        } catch {
            return error
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationOverlappingRegistrationTests {
    // The first observation holds the actor owner's only slot while it returns to the main actor. The
    // second, which replaced it, waits without asking the owner until the first has released its
    // registration, and then registers.
    @Test func overlappingObservationsOfAnActorOwnerKeepOneRegistration() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let inner = try actorTransfers(subscribers: 1)
        let host = HeldActorHost(inner)
        let presentation = SnapshotObservableObject(await inner.snapshot())
        let first = Task { try await presentation.observe(host) }
        await host.acquired.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        host.proceed.raise()
        try await first.value
        try await second.value
        #expect(presentation.isObserving)
        #expect(await inner.subscriberCount == 1)
        presentation.stopObserving()
        await inner.shutdown()
    }

    @Test func overlappingObservationsOfAnActorOwnerKeepOneRegistrationInAnObservationPresentation()
        async throws
    {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let inner = try actorTransfers(subscribers: 1)
        let host = HeldActorHost(inner)
        let presentation = SnapshotPresentation(await inner.snapshot())
        let first = Task { try await presentation.observe(host) }
        await host.acquired.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        host.proceed.raise()
        try await first.value
        try await second.value
        #expect(presentation.isObserving)
        #expect(await inner.subscriberCount == 1)
        presentation.stopObserving()
        await inner.shutdown()
    }

    // Two observations start on the owning actor at once. Whichever order their registrations and
    // hand-offs take, the later one ends with the only slot.
    @Test func overlappingObservationsOfAnOffMainOwnerKeepOneRegistration() async throws {
        for _ in 0 ..< 24 {
            let shelf = try await Shelf()
            let presentation = SnapshotObservableObject(try transfers(subscribers: 1).snapshot())
            #expect(try await shelf.presentTwiceAtOnce(on: presentation) == 1)
            #expect(presentation.isObserving)
            presentation.stopObserving()
            #expect(await shelf.subscriberCount() == 0)
            await shelf.close()
        }
    }

    @Test func overlappingObservationsOfAnOffMainOwnerKeepOneRegistrationInAnObservationPresentation()
        async throws
    {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        for _ in 0 ..< 24 {
            let shelf = try await Shelf()
            let presentation = SnapshotPresentation(try transfers(subscribers: 1).snapshot())
            #expect(try await shelf.presentTwiceAtOnce(on: presentation) == 1)
            #expect(presentation.isObserving)
            presentation.stopObserving()
            #expect(await shelf.subscriberCount() == 0)
            await shelf.close()
        }
    }

    // A refusal by another owner reaches its caller at once: the earlier observation, still waiting
    // for its own owner's snapshot, cannot hold this owner's slot.
    @Test func aRefusalByAnotherActorOwnerDoesNotWaitForAnEarlierObservation() async throws {
        let first = GatedActorHost(try actorTransfers(subscribers: 1))
        let full = try actorTransfers(subscribers: 1)
        let holder = try await full.snapshots()
        let presentation = SnapshotObservableObject(await full.snapshot())
        let held = first.hold(.snapshot)
        let earlier = Task { try await presentation.observe(first) }
        await held.reached.wait()
        await #expect(throws: SubscriptionFailure.capacityExceeded) { try await presentation.observe(full) }
        #expect(!presentation.isObserving)
        held.proceed.raise()
        try await earlier.value
        #expect(await first.inner.subscriberCount == 0)
        #expect(!presentation.isObserving)
        withExtendedLifetime(holder) {}
        await full.shutdown()
        await first.inner.shutdown()
    }

    // The earlier observation has registered and holds the only slot while it reads the snapshot it
    // will show. The later one, which replaced it, is refused, waits until the earlier one has released
    // its registration, and registers again.
    @Test func aRefusalWaitsForAnEarlierObservationReadingItsSnapshot() async throws {
        let host = GatedActorHost(try actorTransfers(subscribers: 1))
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(.snapshot)
        let earlier = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let later = Task { try await presentation.observe(host) }
        held.proceed.raise()
        try await earlier.value
        try await later.value
        #expect(presentation.isObserving)
        #expect(await host.inner.subscriberCount == 1)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    // The earlier observation is inside its registration call when the later one replaces it. The
    // later one waits for that call; the earlier one's registration belongs to an observation that was
    // replaced, so it is released, and the later one then registers and stays live.
    @Test func aReplacedObservationsRegistrationIsReleasedBeforeItsSuccessorRegisters() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = GatedActorHost(try actorTransfers(subscribers: 1))
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(.registration)
        let earlier = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let later = Task.immediate { @MainActor in try await presentation.observe(host) }
        held.proceed.raise()
        try await earlier.value
        try await later.value
        #expect(presentation.isObserving)
        #expect(await host.inner.subscriberCount == 1)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    @Test func anObservationPresentationsReplacedRegistrationIsReleasedBeforeItsSuccessorRegisters() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = GatedActorHost(try actorTransfers(subscribers: 1))
        let presentation = SnapshotPresentation(await host.inner.snapshot())
        let held = host.hold(.registration)
        let earlier = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let later = Task.immediate { @MainActor in try await presentation.observe(host) }
        held.proceed.raise()
        try await earlier.value
        try await later.value
        #expect(presentation.isObserving)
        #expect(await host.inner.subscriberCount == 1)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    @Test func anObservationPresentationsRefusalByAnotherOwnerDoesNotWait() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let first = GatedActorHost(try actorTransfers(subscribers: 1))
        let full = try actorTransfers(subscribers: 1)
        let holder = try await full.snapshots()
        let presentation = SnapshotPresentation(await full.snapshot())
        let held = first.hold(.snapshot)
        let earlier = Task { try await presentation.observe(first) }
        await held.reached.wait()
        await #expect(throws: SubscriptionFailure.capacityExceeded) { try await presentation.observe(full) }
        held.proceed.raise()
        try await earlier.value
        #expect(!presentation.isObserving)
        withExtendedLifetime(holder) {}
        await full.shutdown()
        await first.inner.shutdown()
    }

    // An owner confined to another actor refuses while an observation of an actor owner is still in
    // flight; that observation uses another owner's slots, so the refusal reaches the caller at once.
    @Test func anOffMainRefusalDoesNotWaitForAnotherOwnersObservation() async throws {
        let first = GatedActorHost(try actorTransfers(subscribers: 1))
        let shelf = try await Shelf()
        let presentation = SnapshotObservableObject(try transfers(subscribers: 1).snapshot())
        let held = first.hold(.snapshot)
        let earlier = Task { try await presentation.observe(first) }
        await held.reached.wait()
        #expect(await shelf.observeWhileFull(on: presentation) == .capacityExceeded)
        held.proceed.raise()
        try await earlier.value
        #expect(!presentation.isObserving)
        await shelf.close()
        await first.inner.shutdown()
    }
}

/// An actor owner that forwards to a generated host and can hold one call at a chosen step.
nonisolated private final class GatedActorHost: ActorStateMachineHost {
    typealias Inner = GeneratedTransfers.ActorHost
    /// Where a held call waits.
    enum Step: Sendable {
        /// Before the call reads the owner's snapshot.
        case snapshot
        /// Before the call registers with the owner.
        case registration
    }
    /// One held call: it raises `reached` at its step and continues once `proceed` is raised.
    struct Hold: Sendable {
        let reached = Signal()
        let proceed = Signal()
    }
    let inner: Inner
    private let holds = OSAllocatedUnfairLock(initialState: [(Step, Hold)]())

    init(_ inner: Inner) { self.inner = inner }

    /// Holds the next call that reaches `step`.
    func hold(_ step: Step) -> Hold {
        let hold = Hold()
        holds.withLock { $0.append((step, hold)) }
        return hold
    }

    private func pass(_ step: Step) async {
        let hold = holds.withLock { holds -> Hold? in
            guard let index = holds.firstIndex(where: { $0.0 == step }) else { return nil }
            return holds.remove(at: index).1
        }
        guard let hold else { return }
        hold.reached.raise()
        await hold.proceed.wait()
    }

    func snapshot() async -> Inner.Snapshot {
        await pass(.snapshot)
        return await inner.snapshot()
    }
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Inner.Snapshot> {
        await pass(.registration)
        return try await inner.snapshots()
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Inner.Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try await inner.snapshots(transform)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Inner.Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try await inner.distinctSnapshots(transform)
    }
}

/// Either presentation class, for the synchronous observations of the reentrant registration tests.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private final class ReentryPresentation {
    typealias Snapshot = GeneratedTransfers.Snapshot
    private let combine: SnapshotObservableObject<Snapshot>?
    private let observation: SnapshotPresentation<Snapshot>?

    init(_ kind: PresentationClass, _ initial: Snapshot) {
        switch kind {
        case .combine:
            combine = SnapshotObservableObject(initial)
            observation = nil
        case .observation:
            combine = nil
            observation = SnapshotPresentation(initial)
        }
    }

    var isObserving: Bool { combine?.isObserving ?? observation!.isObserving }
    func observe<Host: MainActorStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        if let combine { try combine.observe(host) } else { try observation!.observe(host) }
    }
    func observe<Host: IsolatedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Owner == MainActor, Host.Snapshot == Snapshot {
        if let combine { try combine.observe(host) } else { try observation!.observe(host) }
    }
    func stopObserving() {
        combine?.stopObserving()
        observation?.stopObserving()
    }
}
