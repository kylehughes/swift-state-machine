import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

// A presentation acquires a registration from an owner, and a later observation can replace one that
// is still acquiring. These tests drive every step of that acquisition from the owner's side: a
// registration that holds the only slot, a refusal, a replacement while a refused observation waits,
// a closed owner, and the publications each step makes.

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
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    /// The number of calls recorded so far.
    var count: Int { storage.withLock { $0 } }
    /// Records one call and returns how many came before it.
    func next() -> Int {
        storage.withLock { count in
            defer { count += 1 }
            return count
        }
    }
}

/// An actor owner that forwards to a generated host and can hold its registrations.
///
/// Each call of `snapshots()` is numbered from zero. A hold placed on a call stops it before the inner
/// host registers it, or after the inner host has registered it and while it still holds the slot,
/// until the test lets it continue. A refusal is reported from a main-actor job queued before the
/// refusal is returned, so a test that waits for it runs after the refused observation has handled it.
nonisolated private final class PacedActorHost: ActorStateMachineHost {
    typealias Inner = GeneratedTransfers.ActorHost
    enum Point: Sendable {
        case beforeRegistering
        case afterRegistering
        /// After the inner host refused the call, before the refusal is returned.
        case afterRefusal
    }
    struct Hold: Sendable {
        let reached = Signal()
        let proceed = Signal()
    }
    let inner: Inner
    private let calls = Counter()
    private let holds = OSAllocatedUnfairLock(initialState: [Int: (Point, Hold)]())
    private let refusals = OSAllocatedUnfairLock(initialState: [Int: Signal]())

    init(_ inner: Inner) { self.inner = inner }

    /// The number of registration calls made so far.
    var callCount: Int { calls.count }
    /// Holds registration call `call` at `point`.
    func hold(_ call: Int, at point: Point) -> Hold {
        let hold = Hold()
        holds.withLock { $0[call] = (point, hold) }
        return hold
    }
    /// Raised once registration call `call` has been refused and its caller has handled the refusal.
    func refusal(of call: Int) -> Signal {
        refusals.withLock { refusals in
            if let signal = refusals[call] { return signal }
            let signal = Signal()
            refusals[call] = signal
            return signal
        }
    }

    func snapshot() async -> Inner.Snapshot { await inner.snapshot() }
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Inner.Snapshot> {
        let call = calls.next()
        let hold = holds.withLock { $0[call] }
        if let (point, hold) = hold, point == .beforeRegistering {
            hold.reached.raise()
            await hold.proceed.wait()
        }
        let snapshots: SnapshotSequence<Inner.Snapshot>
        do {
            snapshots = try await inner.snapshots()
        } catch {
            if let (point, hold) = hold, point == .afterRefusal {
                hold.reached.raise()
                await hold.proceed.wait()
            }
            let refused = refusal(of: call)
            Task { @MainActor in refused.raise() }
            throw error
        }
        if let (point, hold) = hold, point == .afterRegistering {
            hold.reached.raise()
            await hold.proceed.wait()
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

/// A shared owner that forwards to a generated host and runs a hook inside `snapshots()`, after the
/// inner host has registered and before the registration is returned.
nonisolated private final class ReenteringSharedHost: SharedStateMachineHost {
    typealias Inner = GeneratedTransfers.Shared
    let inner: Inner
    private let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(_ inner: Inner) { self.inner = inner }

    /// Runs `action` inside the next registration only.
    func reenter(_ action: @escaping @Sendable () -> Void) { hook.withLock { $0 = action } }

    func snapshot() -> Inner.Snapshot { inner.snapshot() }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Inner.Snapshot> {
        let snapshots = try inner.snapshots()
        let action = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        action?()
        return snapshots
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Inner.Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.snapshots(transform)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Inner.Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform)
    }
}

private func actorTransfers(subscribers: Int = 1) throws -> GeneratedTransfers.ActorHost {
    GeneratedTransfers.ActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

private func sharedTransfers(subscribers: Int = 1) throws -> GeneratedTransfers.Shared {
    GeneratedTransfers.Shared(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

@MainActor private func mainActorTransfers(subscribers: Int = 1) throws -> GeneratedTransfers.MainActorHost {
    GeneratedTransfers.MainActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

/// An actor that owns a capacity-one host confined to it.
private actor Desk {
    private var host: GeneratedTransfers.IsolatedHost<Desk>!

    init() async throws {
        host = GeneratedTransfers.IsolatedHost(
            isolation: self,
            downloadDriver: { _, _, _ in .success("") },
            onLogged: { _, _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 1)
        )
    }

    func subscriberCount() -> Int { host.subscriberCount() }
    func close() { host.close() }
    func advance() throws { try host.send(.goOffline) }

    /// Observes this owner while another registration holds its only slot, and returns the refusal.
    func observeWhileFull(
        on presentation: SnapshotObservableObject<GeneratedTransfers.Snapshot>
    ) async
        -> SubscriptionFailure?
    {
        guard let holder = try? host.subscribe({ _ in }) else { return nil }
        defer { holder.cancel() }
        do throws(SubscriptionFailure) {
            try await presentation.observe(host)
            return nil
        } catch {
            return error
        }
    }
    func observe(on presentation: SnapshotObservableObject<GeneratedTransfers.Snapshot>) async throws {
        try await presentation.observe(host)
    }
}

/// Records every value a Combine presentation publishes after subscription.
@MainActor private final class Published<Value> {
    private(set) var values: [Value] = []
    private var subscription: AnyCancellable?
    init(_ publisher: some Publisher<Value, Never>) {
        subscription = publisher.dropFirst().sink { [unowned self] in values.append($0) }
    }
}

// An asynchronous observation of an actor owner registers only once every earlier registration with
// that owner that the presentation is still making or removing has returned. Each test starts the
// waiting observation with `Task.immediate`, which returns once that observation is suspended in its
// wait, before it has asked the owner anything.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationSupersededWaitTests {
    // A holds the actor owner's only slot inside its registration. B, which replaced A, waits for A
    // without asking the owner. Stopping replaces B, which returns at once, before A has released
    // anything, and never registers.
    @Test func stoppingEndsAnObservationThatWaitsForAnEarlierOne() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        #expect(host.callCount == 1)
        presentation.stopObserving()
        try await second.value
        held.proceed.raise()
        try await first.value
        #expect(!presentation.isObserving)
        #expect(host.callCount == 1)
        #expect(await host.inner.subscriberCount == 0)
        await host.inner.shutdown()
    }

    // Observing an unrelated owner replaces B the same way.
    @Test func observingAnotherOwnerEndsAnObservationThatWaits() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let other = try sharedTransfers()
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        try presentation.observe(other)
        try await second.value
        #expect(presentation.isObserving)
        held.proceed.raise()
        try await first.value
        #expect(presentation.isObserving)
        #expect(host.callCount == 1)
        #expect(other.subscriberCount == 1)
        #expect(await host.inner.subscriberCount == 0)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    // C replaces the waiting B, which returns, and waits for A in its place; once A has released the
    // slot, C registers. B never asks the owner.
    @Test func aLaterObservationReplacesTheWaitingOneAndRegistersOnceTheSlotIsFree() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        let third = Task.immediate { @MainActor in try await presentation.observe(host) }
        try await second.value
        held.proceed.raise()
        try await first.value
        try await third.value
        #expect(presentation.isObserving)
        #expect(host.callCount == 2)
        #expect(await host.inner.subscriberCount == 1)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    // Many observations replace one another while the owner is still inside the first registration
    // call. Each waits without asking the owner and returns once the next replaces it, so the owner
    // sees one call outstanding, not one per observation, and the presentation keeps no list of earlier
    // calls for each of them. Once the first call returns, only the last observation registers.
    @Test func overlappingObservationsWaitWithoutCallingTheOwner() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        var waiting: [Task<Void, any Error>] = []
        for _ in 0 ..< 200 {
            waiting.append(Task.immediate { @MainActor in try await presentation.observe(host) })
        }
        #expect(host.callCount == 1)
        for task in waiting.dropLast() { try await task.value }
        held.proceed.raise()
        try await first.value
        try await waiting.last?.value
        #expect(host.callCount == 2)
        #expect(presentation.isObserving)
        #expect(await host.inner.subscriberCount == 1)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    // B waits while A holds the slot and registers once A has released it, without a refusal.
    @Test func aWaitingObservationRegistersOnceItsPredecessorHasReleasedTheSlot() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        held.proceed.raise()
        try await first.value
        try await second.value
        #expect(presentation.isObserving)
        #expect(host.callCount == 2)
        #expect(await host.inner.subscriberCount == 1)
        presentation.stopObserving()
        await host.inner.shutdown()
    }

    // Cancelling the waiting observation's task ends its wait: it registers at once, and the owner,
    // whose only slot A still holds, refuses it, which it throws.
    @Test func cancellingAWaitingObservationsTaskRegistersAtOnce() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        second.cancel()
        await #expect(throws: SubscriptionFailure.capacityExceeded) { try await second.value }
        #expect(!presentation.isObserving)
        held.proceed.raise()
        try await first.value
        #expect(!presentation.isObserving)
        #expect(await host.inner.subscriberCount == 0)
        await host.inner.shutdown()
    }

    // B waits for A; once A has released the slot, an independent registration takes it before the
    // owner registers B, which the owner then refuses: B throws the refusal.
    @Test func aRefusalAfterTheWaitIsThrown() async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = PacedActorHost(try actorTransfers())
        let presentation = SnapshotObservableObject(await host.inner.snapshot())
        let held = host.hold(0, at: .afterRegistering)
        let registering = host.hold(1, at: .beforeRegistering)
        let first = Task { try await presentation.observe(host) }
        await held.reached.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        held.proceed.raise()
        try await first.value
        await registering.reached.wait()
        let independent = try await host.inner.snapshots()
        registering.proceed.raise()
        await #expect(throws: SubscriptionFailure.capacityExceeded) { try await second.value }
        #expect(!presentation.isObserving)
        #expect(await host.inner.subscriberCount == 1)
        withExtendedLifetime(independent) {}
        await host.inner.shutdown()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationRefusalPublicationTests {
    // The owner is full and has moved on to revision 1 while the presentation shows revision 0. The
    // refusal leaves the shown snapshot and publishes nothing.
    @Test func aRefusedSharedObservationShowsNothing() throws {
        let host = try sharedTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        let shown = Published(presentation.presentedSnapshots)
        try host.send(.goOffline)
        let holder = try host.snapshots()
        #expect(throws: SubscriptionFailure.capacityExceeded) { try presentation.observe(host) }
        #expect(presentation.snapshot.revision == 0)
        #expect(shown.values.isEmpty)
        #expect(!presentation.isObserving)
        withExtendedLifetime(holder) {}
    }

    @Test func aRefusedActorObservationShowsNothing() async throws {
        let host = try actorTransfers()
        let presentation = SnapshotObservableObject(await host.snapshot())
        let shown = Published(presentation.presentedSnapshots)
        try await host.send(.goOffline)
        let holder = try await host.snapshots()
        await #expect(throws: SubscriptionFailure.capacityExceeded) { try await presentation.observe(host) }
        #expect(presentation.snapshot.revision == 0)
        #expect(shown.values.isEmpty)
        withExtendedLifetime(holder) {}
        await host.shutdown()
    }

    @Test func aRefusedOffMainObservationShowsNothing() async throws {
        let desk = try await Desk()
        let presentation = SnapshotObservableObject(try mainActorTransfers().snapshot())
        let shown = Published(presentation.presentedSnapshots)
        try await desk.advance()
        #expect(await desk.observeWhileFull(on: presentation) == .capacityExceeded)
        #expect(presentation.snapshot.revision == 0)
        #expect(shown.values.isEmpty)
        await desk.close()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationSharedReentryTests {
    // The shared owner's registration takes its only slot and, before returning it, observes the same
    // owner again. The inner observation is refused while the outer one holds that slot and throws at
    // once; it replaced the outer one, which releases what it registered, so the slot ends free.
    @Test func reobservingASharedOwnerFromInsideItsRegistrationThrowsTheRefusal() throws {
        let host = ReenteringSharedHost(try sharedTransfers())
        let presentation = SnapshotObservableObject(host.snapshot())
        let failure = OSAllocatedUnfairLock<SubscriptionFailure?>(initialState: nil)
        host.reenter {
            MainActor.assumeIsolated {
                do throws(SubscriptionFailure) {
                    try presentation.observe(host)
                } catch {
                    failure.withLock { $0 = error }
                }
            }
        }
        try presentation.observe(host)
        #expect(failure.withLock { $0 } == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(host.inner.subscriberCount == 0)
        try presentation.observe(host)
        #expect(presentation.isObserving)
        #expect(host.inner.subscriberCount == 1)
        presentation.stopObserving()
        #expect(host.inner.subscriberCount == 0)
    }

    @Test func anObservationPresentationReobservingASharedOwnerFromInsideItsRegistrationThrows() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = ReenteringSharedHost(try sharedTransfers())
        let presentation = SnapshotPresentation(host.snapshot())
        var thrown: SubscriptionFailure?
        host.reenter {
            MainActor.assumeIsolated {
                do throws(SubscriptionFailure) { try presentation.observe(host) } catch { thrown = error }
            }
        }
        try presentation.observe(host)
        #expect(thrown == .capacityExceeded)
        #expect(!presentation.isObserving)
        #expect(host.inner.subscriberCount == 0)
    }
}

/// Counts the changes of an Observation presentation's `isObserving`, and runs `onFirstStart` from the
/// first change that starts an observation.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private final class ObservingTracker {
    private let presentation: SnapshotPresentation<GeneratedTransfers.Snapshot>
    private var onFirstStart: (@MainActor () -> Void)?
    private(set) var changes = 0

    init(
        _ presentation: SnapshotPresentation<GeneratedTransfers.Snapshot>,
        onFirstStart: @escaping @MainActor () -> Void
    ) {
        self.presentation = presentation
        self.onFirstStart = onFirstStart
    }

    func track() {
        withObservationTracking {
            _ = presentation.isObserving
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func changed() {
        changes += 1
        // Observation reports a change before it is stored, so `false` here means it becomes `true`.
        let starting = !presentation.isObserving
        track()
        guard starting, let action = onFirstStart else { return }
        onFirstStart = nil
        action()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationReportOrderTests {
    // The first `true` starts a callback that stops and observes a second owner. Each transition is
    // published once and in order.
    @Test func aStopAndStartInsideTheTrueCallbackPublishesEachChange() throws {
        let first = try sharedTransfers()
        let second = try sharedTransfers()
        let presentation = SnapshotObservableObject(first.snapshot())
        var published: [Bool] = []
        var armed = true
        let subscription = presentation.$isObserving.dropFirst()
            .sink { observing in
                published.append(observing)
                guard observing, armed else { return }
                armed = false
                presentation.stopObserving()
                try? presentation.observe(second)
            }
        try presentation.observe(first)
        #expect(published == [true, false, true])
        #expect(presentation.isObserving)
        #expect(first.subscriberCount == 0)
        #expect(second.subscriberCount == 1)
        presentation.stopObserving()
        withExtendedLifetime(subscription) {}
    }

    @Test func anObservationPresentationPublishesEachChangeOfANestedStopAndStart() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let first = try sharedTransfers()
        let second = try sharedTransfers()
        let presentation = SnapshotPresentation(first.snapshot())
        let tracker = ObservingTracker(presentation) {
            presentation.stopObserving()
            try? presentation.observe(second)
        }
        tracker.track()
        try presentation.observe(first)
        #expect(tracker.changes == 3)
        #expect(presentation.isObserving)
        #expect(first.subscriberCount == 0)
        #expect(second.subscriberCount == 1)
        presentation.stopObserving()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationClosedOwnerTests {
    @Test func observingAClosedSharedOwnerShowsItsClosedSnapshotWithoutObserving() throws {
        let host = try sharedTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        let reports = Published(presentation.$isObserving)
        let closed = host.close()
        try presentation.observe(host)
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(presentation.snapshot.isClosed)
        #expect(reports.values.isEmpty)
        #expect(!presentation.isObserving)
        #expect(host.subscriberCount == 0)
    }

    @Test func observingAClosedActorOwnerShowsItsClosedSnapshotWithoutObserving() async throws {
        let host = try actorTransfers()
        let presentation = SnapshotObservableObject(await host.snapshot())
        let reports = Published(presentation.$isObserving)
        let closed = await host.close()
        try await presentation.observe(host)
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(reports.values.isEmpty)
        #expect(await host.subscriberCount == 0)
    }

    @Test func observingAClosedOffMainOwnerShowsItsClosedSnapshotWithoutObserving() async throws {
        let desk = try await Desk()
        let presentation = SnapshotObservableObject(try mainActorTransfers().snapshot())
        let reports = Published(presentation.$isObserving)
        await desk.close()
        try await desk.observe(on: presentation)
        #expect(presentation.snapshot.isClosed)
        #expect(reports.values.isEmpty)
        #expect(await desk.subscriberCount() == 0)
    }

    // A closed owner's sequence has already ended when it returns it, so it holds no registration:
    // observing it shows the closed snapshot and reports no observation, as observing the owner does.
    @Test func observingAClosedOwnersSequenceShowsItsClosedSnapshotWithoutObserving() async throws {
        let host = try sharedTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        let reports = Published(presentation.$isObserving)
        let closed = host.close()
        let snapshots = try host.snapshots()
        presentation.observe(snapshots)
        #expect(!presentation.isObserving)
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(presentation.snapshot.isClosed)
        #expect(reports.values.isEmpty)
        #expect(host.subscriberCount == 0)
    }

    @Test func followingAClosedOwnersSequenceShowsItsClosedSnapshotWithoutObserving() async throws {
        let host = try sharedTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        let reports = Published(presentation.$isObserving)
        let closed = host.close()
        await presentation.follow(try host.snapshots())
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(presentation.snapshot.isClosed)
        #expect(reports.values.isEmpty)
        #expect(!presentation.isObserving)
    }

    @Test func anObservationPresentationOfAClosedOwnersSequenceIsNotObserving() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = try sharedTransfers()
        let presentation = SnapshotPresentation(host.snapshot())
        let closed = host.close()
        presentation.observe(try host.snapshots())
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(!presentation.isObserving)
        await presentation.follow(try host.snapshots())
        #expect(presentation.snapshot.isClosed)
        #expect(!presentation.isObserving)
    }

    // A sequence that is still live is reported until it ends. The owner delivers the sequence's first
    // element on its own task, which can run before `observe(_:)` reads the sequence or after it
    // returns; either way the observation is reported live only once that element is shown.
    @Test func observingALiveSequenceReportsTheObservationUntilItEnds() async throws {
        enum Event: Equatable { case shown, closed, live, ended }
        let host = try sharedTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        var events: [Event] = []
        let ended = Signal()
        let shown = presentation.presentedSnapshots.dropFirst().sink { events.append($0.isClosed ? .closed : .shown) }
        let reports = presentation.$isObserving.dropFirst()
            .sink { observing in
                events.append(observing ? .live : .ended)
                if !observing { ended.raise() }
            }
        presentation.observe(try host.snapshots())
        await untilObserving(presentation)
        host.close()
        await ended.wait()
        #expect(events == [.shown, .live, .closed, .ended])
        #expect(presentation.snapshot.isClosed)
        shown.cancel()
        reports.cancel()
    }

    @Test func observingAClosedMainActorOwnerShowsItsClosedSnapshotWithoutObserving() throws {
        let host = try mainActorTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        let reports = Published(presentation.$isObserving)
        host.close()
        try presentation.observe(host)
        #expect(presentation.snapshot.isClosed)
        #expect(reports.values.isEmpty)
        #expect(host.subscriberCount == 0)
    }
}
