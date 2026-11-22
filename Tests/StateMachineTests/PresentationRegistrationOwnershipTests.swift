import Combine
import Dispatch
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

// A presentation owns a registration from the moment its owner returns it, decides what it shows and
// whether it is live from that registration, and retries a refusal only when an earlier attempt of
// its own actually held the slot. Each test fixes one interleaving with holds and signals, and runs
// for both presentation classes.

private typealias Snapshot = GeneratedTransfers.Snapshot

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

// MARK: Both presentation classes

/// The two presentation classes, which share one observation core.
enum PresentationClass: CaseIterable, CustomTestStringConvertible, Sendable {
    case combine, observation

    var testDescription: String {
        switch self {
        case .combine: "SnapshotObservableObject"
        case .observation: "SnapshotPresentation"
        }
    }
}

/// What a test observes of a presentation's publications, recorded from the callbacks a view would
/// receive.
///
/// The Combine class publishes each value; Observation reports each change before it is stored, so
/// for that class the recorded report is the negation of the value read in the callback and a
/// snapshot change is recorded without its revision.
@MainActor private final class Watch {
    private(set) var reports: [Bool] = []
    private(set) var shown: [UInt64?] = []
    /// Runs inside each snapshot publication's callback.
    var onShow: (() -> Void)?
    /// Runs inside each observation-state publication's callback.
    var onReport: (() -> Void)?
    fileprivate var cancellables: [AnyCancellable] = []

    func report(_ value: Bool) {
        reports.append(value)
        onReport?()
    }
    func show(_ revision: UInt64?) {
        shown.append(revision)
        onShow?()
    }
}

/// The members both presentation classes share, for a generated transfer snapshot.
@MainActor private protocol Presenting: AnyObject {
    var snapshot: Snapshot { get }
    var isObserving: Bool { get }
    @discardableResult func apply(_ next: Snapshot) -> Bool
    func observe(_ snapshots: SnapshotSequence<Snapshot>)
    func observe<Host: MainActorStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot
    func observe<Host: SharedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot
    func observe<Host: ActorStateMachineHost>(_ host: Host) async throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot
    func follow(_ snapshots: SnapshotSequence<Snapshot>) async
    func stopObserving()
    /// Records the presentation's publications from now on.
    func watch() -> Watch
    /// Returns once the presentation reports a live observation.
    func untilLive() async
}

extension SnapshotObservableObject: Presenting where Snapshot == GeneratedTransfers.Snapshot {
    fileprivate func untilLive() async { await untilObserving(self) }
    fileprivate func watch() -> Watch {
        let watch = Watch()
        watch.cancellables.append($isObserving.dropFirst().sink { [unowned watch] in watch.report($0) })
        watch.cancellables.append(presentedSnapshots.dropFirst().sink { [unowned watch] in watch.show($0.revision) })
        return watch
    }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
extension SnapshotPresentation: Presenting where Snapshot == GeneratedTransfers.Snapshot {
    fileprivate func untilLive() async { await untilObserving(self) }
    fileprivate func watch() -> Watch {
        let watch = Watch()
        trackReports(into: watch)
        trackSnapshots(into: watch)
        return watch
    }
    private func trackReports(into watch: Watch) {
        withObservationTracking {
            _ = isObserving
        } onChange: { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                watch.report(!self.isObserving)
                self.trackReports(into: watch)
            }
        }
    }
    private func trackSnapshots(into watch: Watch) {
        withObservationTracking {
            _ = snapshot
        } onChange: { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                self.trackSnapshots(into: watch)
                watch.show(nil)
            }
        }
    }
}

/// Creates a presentation of `kind`, or `nil` where the Observation class is unavailable.
@MainActor private func presentation(
    _ kind: PresentationClass,
    _ initial: Snapshot,
    revision: (@MainActor (Snapshot) -> UInt64)? = nil
) -> (any Presenting)? {
    switch kind {
    case .combine:
        return revision.map { SnapshotObservableObject(initial, revision: $0) } ?? SnapshotObservableObject(initial)
    case .observation:
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
        return revision.map { SnapshotPresentation(initial, revision: $0) } ?? SnapshotPresentation(initial)
    }
}

// MARK: Owners that pause or reenter

/// An actor owner that forwards to a generated host and runs a hook at a chosen step of a call.
nonisolated private final class HookedActorHost: ActorStateMachineHost {
    typealias Inner = GeneratedTransfers.ActorHost
    typealias Hook = @Sendable () async -> Void
    let inner: Inner
    private let hooks = OSAllocatedUnfairLock(initialState: Hooks())
    private struct Hooks {
        var afterRegistering: Hook?
        var afterRefusal: [Hook] = []
        var duringSnapshotRead: Hook?
        var registrations = 0
    }

    init(_ inner: Inner) { self.inner = inner }

    /// How many times `snapshots()` asked the inner host to register.
    var registrations: Int { hooks.withLock { $0.registrations } }
    /// Runs `hook` once, inside the next `snapshots()` after the inner host registered.
    func afterRegistering(_ hook: @escaping Hook) { hooks.withLock { $0.afterRegistering = hook } }
    /// Runs `hook` once, inside a later `snapshots()` that the inner host refuses, before it throws;
    /// hooks run in the order they were added, one per refusal.
    func afterRefusal(_ hook: @escaping Hook) { hooks.withLock { $0.afterRefusal.append(hook) } }
    /// Raises `signal` from a main-actor job queued inside the next refusal, before that refusal is
    /// returned, so a test that waits for it runs after the refused observation has handled it.
    func reportRefusal(_ signal: Signal) {
        afterRefusal { Task { @MainActor in signal.raise() } }
    }
    /// Runs `hook` once, inside the next `snapshot()`, after it read the inner snapshot and before it
    /// returns it.
    func duringSnapshotRead(_ hook: @escaping Hook) { hooks.withLock { $0.duringSnapshotRead = hook } }

    private func takeSnapshotHook() -> Hook? {
        hooks.withLock { hooks in
            defer { hooks.duringSnapshotRead = nil }
            return hooks.duringSnapshotRead
        }
    }
    private func takeRegistrationHook() -> Hook? {
        hooks.withLock { hooks in
            defer { hooks.afterRegistering = nil }
            return hooks.afterRegistering
        }
    }

    func snapshot() async -> Inner.Snapshot {
        let current = await inner.snapshot()
        await takeSnapshotHook()?()
        return current
    }
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Inner.Snapshot> {
        hooks.withLock { $0.registrations += 1 }
        let snapshots: SnapshotSequence<Inner.Snapshot>
        do {
            snapshots = try await inner.snapshots()
        } catch {
            let hook = hooks.withLock { hooks in hooks.afterRefusal.isEmpty ? nil : hooks.afterRefusal.removeFirst() }
            await hook?()
            throw error
        }
        await takeRegistrationHook()?()
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

/// A shared owner of one's own whose sequence the test feeds and finishes by hand.
nonisolated private final class FedSharedHost: SharedStateMachineHost {
    typealias Feed = (receive: @Sendable (Snapshot) -> Void, finish: @Sendable () -> Void)
    let inner: GeneratedTransfers.Shared
    private let feed = OSAllocatedUnfairLock<Feed?>(initialState: nil)

    init(_ inner: GeneratedTransfers.Shared) { self.inner = inner }

    /// Finishes the sequence the host registered last.
    func finish() { feed.withLock { $0 }?.finish() }

    func snapshot() -> Snapshot { inner.snapshot() }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> {
        let current = inner.snapshot()
        return try SnapshotSequence { receive, finish in
            feed.withLock { $0 = (receive, finish) }
            receive(current)
            return SnapshotSubscription(onCancel: {})
        }
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.snapshots(transform)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform)
    }
}

/// A shared owner that forwards to a generated host and runs a hook inside the next `snapshot()`, after
/// it read the inner snapshot and before it returns it.
nonisolated private final class ReadHookedSharedHost: SharedStateMachineHost {
    let inner: GeneratedTransfers.Shared
    private let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(_ inner: GeneratedTransfers.Shared) { self.inner = inner }

    func duringSnapshotRead(_ action: @escaping @Sendable () -> Void) { hook.withLock { $0 = action } }

    func snapshot() -> Snapshot {
        let current = inner.snapshot()
        let action = hook.withLock { hook in
            defer { hook = nil }
            return hook
        }
        action?()
        return current
    }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> { try inner.snapshots() }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.snapshots(transform)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform)
    }
}

/// A shared owner that forwards to a generated host and runs a hook inside a refused registration,
/// before it throws.
nonisolated private final class RefusingSharedHost: SharedStateMachineHost {
    let inner: GeneratedTransfers.Shared
    private let state = OSAllocatedUnfairLock<(hook: (@Sendable () -> Void)?, calls: Int)>(initialState: (nil, 0))

    init(_ inner: GeneratedTransfers.Shared) { self.inner = inner }

    var registrations: Int { state.withLock { $0.calls } }
    /// Runs `action` inside the next refused registration only.
    func onRefusal(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.hook = action } }

    func snapshot() -> Snapshot { inner.snapshot() }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> {
        state.withLock { $0.calls += 1 }
        do {
            return try inner.snapshots()
        } catch {
            let action = state.withLock { state in
                defer { state.hook = nil }
                return state.hook
            }
            action?()
            throw error
        }
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.snapshots(transform)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform)
    }
}

/// A box for a presentation that a closure created before it refers to it.
@MainActor private final class Later {
    var presentation: (any Presenting)?
}

// MARK: Ownership from the owner's return

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationRegistrationOwnershipTests {
    // The actor owner registered and the presentation is reading the snapshot it will show. Stopping
    // releases the registration before it returns.
    @Test(arguments: PresentationClass.allCases)
    func stoppingDuringTheSnapshotReadReleasesTheRegistrationAtOnce(_ kind: PresentationClass) async throws {
        let inner = try actorTransfers()
        let host = HookedActorHost(inner)
        guard let presentation = presentation(kind, await inner.snapshot()) else { return }
        let watch = presentation.watch()
        let reading = Signal()
        let proceed = Signal()
        host.duringSnapshotRead {
            reading.raise()
            await proceed.wait()
        }
        let observing = Task { try await presentation.observe(host) }
        await reading.wait()
        presentation.stopObserving()
        #expect(await inner.subscriberCount == 0)
        proceed.raise()
        try await observing.value
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.isEmpty)
        #expect(await inner.subscriberCount == 0)
        await inner.shutdown()
    }

    // The snapshot read of the first observation waits for a second observation of the same
    // capacity-one owner. The second replaces the first, which releases its slot, so the second
    // registers and the read then returns.
    @Test(arguments: PresentationClass.allCases)
    func aSnapshotReadThatAwaitsAnotherObservationOfTheSameOwnerCompletes(_ kind: PresentationClass) async throws {
        let inner = try actorTransfers()
        let host = HookedActorHost(inner)
        guard let presentation = presentation(kind, await inner.snapshot()) else { return }
        let later = Later()
        later.presentation = presentation
        host.duringSnapshotRead { @MainActor in try? await later.presentation?.observe(host) }
        try await presentation.observe(host)
        #expect(presentation.isObserving)
        #expect(await inner.subscriberCount == 1)
        #expect(host.registrations == 2)
        presentation.stopObserving()
        #expect(await inner.subscriberCount == 0)
        await inner.shutdown()
    }

    // Another owner replaces the observation while it reads its snapshot.
    @Test(arguments: PresentationClass.allCases)
    func replacingWithAnotherOwnerDuringTheSnapshotReadReleasesTheFirst(_ kind: PresentationClass) async throws {
        let inner = try actorTransfers()
        let host = HookedActorHost(inner)
        let other = try sharedTransfers()
        guard let presentation = presentation(kind, await inner.snapshot()) else { return }
        let reading = Signal()
        let proceed = Signal()
        host.duringSnapshotRead {
            reading.raise()
            await proceed.wait()
        }
        let observing = Task { try await presentation.observe(host) }
        await reading.wait()
        try presentation.observe(other)
        #expect(await inner.subscriberCount == 0)
        proceed.raise()
        try await observing.value
        #expect(presentation.isObserving)
        #expect(other.subscriberCount == 1)
        #expect(await inner.subscriberCount == 0)
        presentation.stopObserving()
        await inner.shutdown()
    }

    // The presentation sampled the open snapshot, and the owner then closed and delivered its closed
    // snapshot to the registration before the sample returned. The registration's closed snapshot is
    // newer, so the presentation shows it, and an ended registration reports no observation.
    @Test(arguments: PresentationClass.allCases)
    func closingDuringTheSnapshotReadShowsTheClosedSnapshot(_ kind: PresentationClass) async throws {
        let inner = try actorTransfers()
        let host = HookedActorHost(inner)
        guard let presentation = presentation(kind, await inner.snapshot()) else { return }
        let watch = presentation.watch()
        let reading = Signal()
        let proceed = Signal()
        host.duringSnapshotRead {
            reading.raise()
            await proceed.wait()
        }
        let observing = Task { try await presentation.observe(host) }
        await reading.wait()
        let closed = await inner.close()
        _ = await inner.flush(through: closed)
        proceed.raise()
        try await observing.value
        #expect(presentation.snapshot.isClosed)
        #expect(presentation.snapshot.revision == closed.snapshot.revision)
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.count == 1)
        #expect(await inner.subscriberCount == 0)
    }

    // The owner's sequence finishes from inside the publication of the first snapshot. The
    // registration has ended by the time the presentation would report it, so it reports nothing.
    @Test(arguments: PresentationClass.allCases)
    func aSequenceFinishedDuringTheFirstPublicationIsNotReported(_ kind: PresentationClass) throws {
        let host = FedSharedHost(try sharedTransfers())
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let watch = presentation.watch()
        watch.onShow = { [unowned watch] in
            watch.onShow = nil
            host.finish()
        }
        try presentation.observe(host)
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.count == 1)
    }

    // The same finish, from a sequence observed directly.
    @Test(arguments: PresentationClass.allCases)
    func aDirectlyObservedSequenceFinishedDuringItsFirstPublicationIsNotReported(_ kind: PresentationClass) throws {
        let host = FedSharedHost(try sharedTransfers())
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let watch = presentation.watch()
        watch.onShow = { [unowned watch] in
            watch.onShow = nil
            host.finish()
        }
        presentation.observe(try host.snapshots())
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.count == 1)
    }
}

// MARK: Sequences another consumer claimed

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationClaimTests {
    // A sequence whose first iterator already belongs to another consumer: the presentation owns
    // nothing, reports nothing, and stopping it leaves that consumer's registration in place.
    @Test(arguments: PresentationClass.allCases)
    func observingAClaimedSequenceOwnsNothing(_ kind: PresentationClass) async throws {
        let host = try sharedTransfers(subscribers: 2)
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let watch = presentation.watch()
        let snapshots = try host.snapshots()
        var first = snapshots.makeAsyncIterator()
        #expect(await first.next()?.revision == 0)
        presentation.observe(snapshots)
        #expect(!presentation.isObserving)
        presentation.stopObserving()
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.isEmpty)
        #expect(host.subscriberCount == 1)
        try host.send(.goOffline)
        #expect(await first.next()?.revision == 1)
    }

    @Test(arguments: PresentationClass.allCases)
    func followingAClaimedSequenceReturnsAtOnceAndOwnsNothing(_ kind: PresentationClass) async throws {
        let host = try sharedTransfers(subscribers: 2)
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let watch = presentation.watch()
        let snapshots = try host.snapshots()
        var first = snapshots.makeAsyncIterator()
        #expect(await first.next()?.revision == 0)
        await presentation.follow(snapshots)
        presentation.stopObserving()
        #expect(watch.reports.isEmpty)
        #expect(host.subscriberCount == 1)
        try host.send(.goOffline)
        #expect(await first.next()?.revision == 1)
    }

    // A follow whose task is already cancelled follows nothing and releases the sequence.
    @Test(arguments: PresentationClass.allCases)
    func followingInACancelledTaskReportsNothingAndReleasesTheSequence(_ kind: PresentationClass) async throws {
        let host = try sharedTransfers()
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let watch = presentation.watch()
        let snapshots = try host.snapshots()
        let started = Signal()
        let cancelled = Signal()
        let following = Task { @MainActor in
            started.raise()
            await cancelled.wait()
            await presentation.follow(snapshots)
        }
        await started.wait()
        following.cancel()
        cancelled.raise()
        await following.value
        #expect(watch.reports.isEmpty)
        #expect(!presentation.isObserving)
        #expect(host.subscriberCount == 0)
    }
}

// MARK: Restarting the revision check

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationRestartTests {
    // While the revision closure evaluates a new owner's first snapshot, the owner advances and the
    // closure applies the newer snapshot. The restart then keeps the newer one.
    @Test(arguments: PresentationClass.allCases)
    func aNewerSnapshotAppliedDuringASharedRestartIsKept(_ kind: PresentationClass) throws {
        let host = try sharedTransfers()
        let later = Later()
        var armed = false
        guard
            let presentation = presentation(
                kind,
                host.snapshot(),
                revision: { snapshot in
                    if armed {
                        armed = false
                        _ = try? host.send(.goOffline)
                        #expect(later.presentation?.apply(host.snapshot()) == true)
                    }
                    return snapshot.revision
                }
            )
        else { return }
        later.presentation = presentation
        let watch = presentation.watch()
        armed = true
        try presentation.observe(host)
        #expect(presentation.snapshot.revision == 1)
        #expect(watch.shown.count == 1)
        if kind == .combine { #expect(watch.shown == [1]) }
        presentation.stopObserving()
    }

    @Test(arguments: PresentationClass.allCases)
    func aNewerSnapshotAppliedDuringAMainActorRestartIsKept(_ kind: PresentationClass) throws {
        let host = try mainActorTransfers()
        let later = Later()
        var armed = false
        guard
            let presentation = presentation(
                kind,
                host.snapshot(),
                revision: { snapshot in
                    if armed {
                        armed = false
                        _ = try? host.send(.goOffline)
                        _ = later.presentation?.apply(host.snapshot())
                    }
                    return snapshot.revision
                }
            )
        else { return }
        later.presentation = presentation
        let watch = presentation.watch()
        armed = true
        try presentation.observe(host)
        #expect(presentation.snapshot.revision == 1)
        if kind == .combine { #expect(watch.shown == [1]) }
        presentation.stopObserving()
    }

    @Test(arguments: PresentationClass.allCases)
    func aNewerSnapshotAppliedDuringAnActorRestartIsKept(_ kind: PresentationClass) async throws {
        let host = try actorTransfers()
        let later = Later()
        let advanced = try await {
            try await host.send(.goOffline)
            return await host.snapshot()
        }()
        let fresh = try actorTransfers()
        var armed = false
        guard
            let presentation = presentation(
                kind,
                await fresh.snapshot(),
                revision: { snapshot in
                    if armed {
                        armed = false
                        _ = later.presentation?.apply(advanced)
                    }
                    return snapshot.revision
                }
            )
        else { return }
        later.presentation = presentation
        let watch = presentation.watch()
        armed = true
        try await presentation.observe(fresh)
        #expect(presentation.snapshot.revision == 1)
        if kind == .combine { #expect(watch.shown == [1]) }
        presentation.stopObserving()
        await host.shutdown()
        await fresh.shutdown()
    }

    // While the presentation reads the owner's snapshot, the owner advances and the newer snapshot is
    // applied; the read then returns the older one. The observation already accepted the newer one, so
    // the restart keeps it.
    @Test(arguments: PresentationClass.allCases)
    func aNewerSnapshotAppliedDuringTheSnapshotReadIsKept(_ kind: PresentationClass) throws {
        let inner = try sharedTransfers()
        let host = ReadHookedSharedHost(inner)
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let later = Later()
        later.presentation = presentation
        let watch = presentation.watch()
        host.duringSnapshotRead {
            MainActor.assumeIsolated {
                _ = try? inner.send(.goOffline)
                #expect(later.presentation?.apply(inner.snapshot()) == true)
            }
        }
        try presentation.observe(host)
        #expect(presentation.snapshot.revision == 1)
        #expect(watch.shown.count == 1)
        if kind == .combine { #expect(watch.shown == [1]) }
        presentation.stopObserving()
    }

    // A sequence's first element arrives after the observation applied a newer snapshot. The restart
    // keeps the newer one, and the sequence's later elements continue from it.
    @Test(arguments: PresentationClass.allCases)
    func aNewerSnapshotAppliedBeforeASequencesFirstElementIsKept(_ kind: PresentationClass) async throws {
        let owner = try sharedTransfers()
        let initial = owner.snapshot()
        try owner.send(.goOffline)
        let applied = owner.snapshot()
        try owner.send(.goOnline)
        let latest = owner.snapshot()
        let feed = OSAllocatedUnfairLock<(@Sendable (Snapshot) -> Void)?>(initialState: nil)
        let snapshots = try SnapshotSequence<Snapshot> { receive, _ in
            feed.withLock { $0 = receive }
            return SnapshotSubscription(onCancel: {})
        }
        let seedRead = Signal()
        let latestRead = Signal()
        let following = Later()
        guard
            let presentation = presentation(
                kind,
                initial,
                revision: { snapshot in
                    // The follow task reads each element's revision before it shows the element, in the
                    // same main-actor job.
                    guard following.presentation != nil else { return snapshot.revision }
                    if snapshot.revision == initial.revision { seedRead.raise() }
                    if snapshot.revision == latest.revision { latestRead.raise() }
                    return snapshot.revision
                }
            )
        else { return }
        let watch = presentation.watch()
        presentation.observe(snapshots)
        // Nothing is shown from the sequence yet, so the observation is not live yet.
        #expect(!presentation.isObserving)
        #expect(presentation.apply(applied))
        following.presentation = presentation
        feed.withLock { $0 }?(initial)
        await seedRead.wait()
        feed.withLock { $0 }?(latest)
        await latestRead.wait()
        #expect(presentation.snapshot.revision == latest.revision)
        if kind == .combine { #expect(watch.shown == [applied.revision, latest.revision]) }
        #expect(watch.shown.count == 2)
        // The kept snapshot is the observation's first, so it went live then.
        #expect(presentation.isObserving)
        #expect(watch.reports == [true])
        presentation.stopObserving()
    }
}

// MARK: Refusals that no earlier attempt caused

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationRefusalCauseTests {
    // An independent registration holds the only slot. A is refused and, inside that refusal, B
    // observes the same owner and is refused too while A is still inside its call. B's refusal is
    // thrown at once, and A's, which B replaced, is not: no third registration, and no observation.
    @Test(arguments: PresentationClass.allCases)
    func aSynchronousRefusalInsideAnEarlierRegistrationThrowsAtOnce(_ kind: PresentationClass) throws {
        let inner = try sharedTransfers()
        let host = RefusingSharedHost(inner)
        guard let presentation = presentation(kind, host.snapshot()) else { return }
        let later = Later()
        later.presentation = presentation
        let watch = presentation.watch()
        let independent = try inner.snapshots()
        host.onRefusal {
            MainActor.assumeIsolated {
                // B is refused while A is still inside its registration call.
                #expect(throws: SubscriptionFailure.capacityExceeded) { try later.presentation?.observe(host) }
                independent.cancel()
            }
        }
        try presentation.observe(host)
        #expect(host.registrations == 2)
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(inner.subscriberCount == 0)
    }

    // Across suspensions, B does not ask the owner while A is still inside its registration call: A's
    // refusal is held inside the owner, B waits for A, and the independent registration ends. Once A's
    // refusal has returned, B registers, and the slot is free.
    @Test(arguments: PresentationClass.allCases)
    func anAsyncObservationWaitsForAnEarlierRefusedAttemptThenRegisters(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let inner = try actorTransfers()
        let host = HookedActorHost(inner)
        guard let presentation = presentation(kind, await inner.snapshot()) else { return }
        let independent = try await inner.snapshots()
        let refused = Signal()
        let proceed = Signal()
        host.afterRefusal {
            refused.raise()
            await proceed.wait()
        }
        let first = Task { try await presentation.observe(host) }
        await refused.wait()
        let second = Task.immediate { @MainActor in try await presentation.observe(host) }
        #expect(host.registrations == 1)
        independent.cancel()
        proceed.raise()
        try await first.value
        try await second.value
        #expect(host.registrations == 2)
        #expect(presentation.isObserving)
        #expect(await inner.subscriberCount == 1)
        presentation.stopObserving()
        await inner.shutdown()
    }
}

// MARK: The hand-off from an owner confined to another actor

/// An owner confined to `Owner` that forwards to a generated host and can run a hook on the owning
/// actor right after the inner host registered, before the registration is returned.
private final class HookedIsolatedHost<Owner: Actor>: IsolatedStateMachineHost {
    typealias Inner = GeneratedTransfers.IsolatedHost<Owner>
    let inner: Inner
    /// Runs once, on the owning actor, inside the next `snapshots(_:isolation:)` after registering.
    var afterRegistering: (() -> Void)?
    /// Runs once, on the owning actor, inside the next `snapshot(isolation:)`.
    var duringSnapshotRead: (() -> Void)?
    /// How many snapshots the presentation read.
    private(set) var snapshotReads = 0
    /// The subscriber count once the last snapshot read's hook returned, before the read returned.
    private(set) var subscribersAfterSnapshotHook: Int?

    init(_ inner: Inner) { self.inner = inner }

    func snapshot(isolation: isolated Owner) -> Snapshot {
        snapshotReads += 1
        if let hook = duringSnapshotRead {
            duringSnapshotRead = nil
            hook()
            subscribersAfterSnapshotHook = inner.subscriberCount(isolation: isolation)
        }
        return inner.snapshot(isolation: isolation)
    }
    func subscribe(
        _ receive: @escaping (Snapshot) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Owner> {
        try inner.subscribe(receive, onFinish: onFinish, isolation: isolation)
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let snapshots = try inner.snapshots(transform, isolation: isolation)
        let hook = afterRegistering
        afterRegistering = nil
        hook?()
        return snapshots
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform, isolation: isolation)
    }
}

/// An actor that owns a capacity-one hooked host confined to it.
private actor Bench {
    private var host: HookedIsolatedHost<Bench>!

    init() async throws {
        host = HookedIsolatedHost(
            GeneratedTransfers.IsolatedHost(
                isolation: self,
                downloadDriver: { _, _, _ in .success("") },
                onLogged: { _, _ in },
                configuration: try GeneratedTransfers.Configuration(subscribers: 1)
            )
        )
    }

    /// Parks the owning actor's thread after the next registration, until `proceed` is signaled.
    func parkAfterRegistering(reached: Signal, proceed: DispatchSemaphore) {
        host.afterRegistering = {
            reached.raise()
            proceed.wait()
        }
    }
    func observe(on presentation: SnapshotObservableObject<Snapshot>) async throws {
        try await presentation.observe(host)
    }
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func observe(on presentation: SnapshotPresentation<Snapshot>) async throws {
        try await presentation.observe(host)
    }
    /// Parks the owning actor's thread inside the next snapshot read, until `proceed` is signaled.
    func parkDuringSnapshotRead(reached: Signal, proceed: DispatchSemaphore) {
        host.duringSnapshotRead = {
            reached.raise()
            proceed.wait()
        }
    }
    func snapshotReads() -> Int { host.snapshotReads }
    func subscribersAfterSnapshotHook() -> Int? { host.subscribersAfterSnapshotHook }
    func subscriberCount() -> Int { host.inner.subscriberCount() }
    func close() { host.inner.close() }
}

@MainActor @Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct PresentationHandoffOwnershipTests {
    // The owning actor has registered and not yet returned the registration when the presentation
    // stops. The hand-off already belongs to the stopped observation, so the owning actor releases the
    // registration as soon as the host returns it, and reads no snapshot for it.
    @Test(arguments: PresentationClass.allCases)
    func stoppingBeforeTheOwningActorReturnsTheRegistrationReleasesItThere(_ kind: PresentationClass) async throws {
        let bench = try await Bench()
        guard let presentation = presentation(kind, try mainActorTransfers().snapshot()) else { return }
        let watch = presentation.watch()
        let reached = Signal()
        let proceed = DispatchSemaphore(value: 0)
        await bench.parkAfterRegistering(reached: reached, proceed: proceed)
        let observing = Task { @MainActor in
            switch presentation {
            case let combine as SnapshotObservableObject<Snapshot>: try await bench.observe(on: combine)
            default:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
                    let observation = presentation as? SnapshotPresentation<Snapshot>
                else { return }
                try await bench.observe(on: observation)
            }
        }
        await reached.wait()
        presentation.stopObserving()
        proceed.signal()
        try await observing.value
        #expect(await bench.snapshotReads() == 0)
        #expect(await bench.subscriberCount() == 0)
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.isEmpty)
        await bench.close()
    }

    // The owning actor holds the registration in the hand-off and is reading the snapshot when the
    // presentation stops. The stop releases the registration from the main actor at once, so it is
    // gone before the owning actor's turn continues.
    @Test(arguments: PresentationClass.allCases)
    func stoppingWhileTheOwningActorReadsTheSnapshotReleasesTheRegistrationAtOnce(
        _ kind: PresentationClass
    ) async throws {
        let bench = try await Bench()
        guard let presentation = presentation(kind, try mainActorTransfers().snapshot()) else { return }
        let watch = presentation.watch()
        let reached = Signal()
        let proceed = DispatchSemaphore(value: 0)
        await bench.parkDuringSnapshotRead(reached: reached, proceed: proceed)
        let observing = Task { @MainActor in
            switch presentation {
            case let combine as SnapshotObservableObject<Snapshot>: try await bench.observe(on: combine)
            default:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
                    let observation = presentation as? SnapshotPresentation<Snapshot>
                else { return }
                try await bench.observe(on: observation)
            }
        }
        await reached.wait()
        presentation.stopObserving()
        proceed.signal()
        try await observing.value
        #expect(await bench.subscribersAfterSnapshotHook() == 0)
        #expect(await bench.subscriberCount() == 0)
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        #expect(watch.shown.isEmpty)
        await bench.close()
    }
}

// MARK: Code that runs inside a presentation's own steps

/// A sequence of an owner of the test's own, which the test feeds element by element.
private final class Feed: Sendable {
    private let callbacks = OSAllocatedUnfairLock<
        (receive: (@Sendable (Snapshot) -> Void)?, finish: (@Sendable () -> Void)?)
    >(
        initialState: (nil, nil)
    )
    private let cancellations = OSAllocatedUnfairLock(initialState: 0)

    /// How many times the sequence cancelled its token.
    var cancelled: Int { cancellations.withLock { $0 } }

    /// Registers the sequence, offering `first` before the registration returns when there is one.
    func sequence(first: Snapshot? = nil) throws -> SnapshotSequence<Snapshot> {
        try SnapshotSequence<Snapshot> { receive, finish in
            callbacks.withLock { $0 = (receive, finish) }
            if let first { receive(first) }
            return SnapshotSubscription { [cancellations] in cancellations.withLock { $0 += 1 } }
        }
    }
    func offer(_ snapshot: Snapshot) { callbacks.withLock { $0.receive }?(snapshot) }
}

/// Snapshots of one owner at revisions `0..<count`, in order.
private func revisions(_ count: Int) throws -> [Snapshot] {
    let owner = try sharedTransfers()
    var snapshots = [owner.snapshot()]
    while snapshots.count < count {
        try owner.send(snapshots.count.isMultiple(of: 2) ? .goOnline : .goOffline)
        snapshots.append(owner.snapshot())
    }
    return snapshots
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationReentrantObservationTests {
    // A is live at revision 1. `apply` is handed A's revision 9, and computing that revision starts an
    // observation of B, whose first snapshot is revision 0. Revision 9 belongs to the observation that
    // B replaced, so it is not applied, and B's own later snapshot is.
    @Test(arguments: PresentationClass.allCases)
    func anAppliedSnapshotWhoseRevisionStartsAnotherObservationIsDiscarded(_ kind: PresentationClass) throws {
        let a = try revisions(10)
        let b = try revisions(2)
        let ownerB = Feed()
        let later = Later()
        var armed = false
        guard
            let presentation = presentation(
                kind,
                a[0],
                revision: { snapshot in
                    if armed, snapshot.revision == 9 {
                        armed = false
                        later.presentation?.observe(try! ownerB.sequence(first: b[0]))
                    }
                    return snapshot.revision
                }
            )
        else { return }
        later.presentation = presentation
        let ownerA = Feed()
        presentation.observe(try ownerA.sequence(first: a[1]))
        #expect(presentation.snapshot.revision == 1 && presentation.isObserving)
        armed = true
        #expect(!presentation.apply(a[9]))
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.isObserving)
        // B's next snapshot passes the revision check that B's first one restarted.
        #expect(presentation.apply(b[1]))
        #expect(presentation.snapshot.revision == 1)
        presentation.stopObserving()
        #expect(ownerA.cancelled == 1 && ownerB.cancelled == 1)
    }

    // The snapshot callback for `apply(1)` starts an observation of a sequence whose first element is
    // revision 2. That element is assigned only after the callback returns, and the observation is
    // reported live after it, while revision 2 is shown.
    @Test(arguments: PresentationClass.allCases)
    func aSequenceObservedFromASnapshotCallbackIsLiveOnlyOnceItsFirstSnapshotIsPublished(
        _ kind: PresentationClass
    ) throws {
        let a = try revisions(2)
        let b = try revisions(3)
        guard let presentation = presentation(kind, a[0]) else { return }
        let later = Later()
        later.presentation = presentation
        let watch = presentation.watch()
        let ownerB = Feed()
        var showsBeforeReport: [Int] = []
        var shownAtReport: [UInt64] = []
        watch.onShow = {
            if watch.shown.count == 1 { later.presentation?.observe(try! ownerB.sequence(first: b[2])) }
        }
        watch.onReport = {
            showsBeforeReport.append(watch.shown.count)
            if let presentation = later.presentation { shownAtReport.append(presentation.snapshot.revision) }
        }
        #expect(presentation.apply(a[1]))
        #expect(watch.shown.count == 2)
        #expect(watch.reports == [true])
        #expect(showsBeforeReport == [2])
        #expect(shownAtReport == [2])
        #expect(presentation.snapshot.revision == 2 && presentation.isObserving)
        presentation.stopObserving()
    }

    // The same, for a main-actor owner whose registration delivers its first snapshot inside the
    // registration call.
    @Test(arguments: PresentationClass.allCases)
    func aMainActorOwnerObservedFromASnapshotCallbackIsLiveOnlyOnceItsFirstSnapshotIsPublished(
        _ kind: PresentationClass
    ) throws {
        let a = try revisions(2)
        let owner = try mainActorTransfers()
        try owner.send(.goOffline)
        try owner.send(.goOnline)
        guard let presentation = presentation(kind, a[0]) else { return }
        let later = Later()
        later.presentation = presentation
        let watch = presentation.watch()
        var showsBeforeReport: [Int] = []
        watch.onShow = {
            if watch.shown.count == 1 { try? later.presentation?.observe(owner) }
        }
        watch.onReport = { showsBeforeReport.append(watch.shown.count) }
        #expect(presentation.apply(a[1]))
        #expect(watch.reports == [true])
        #expect(showsBeforeReport == [2])
        #expect(presentation.snapshot.revision == 2 && presentation.isObserving)
        #expect(owner.subscriberCount == 1)
        presentation.stopObserving()
        #expect(owner.subscriberCount == 0)
    }

    // A sequence that has delivered nothing yet shows nothing, so the observation is not live until its
    // first element is shown.
    @Test(arguments: PresentationClass.allCases)
    func aSequenceWithoutAnElementIsLiveOnceItsFirstIsShown(_ kind: PresentationClass) async throws {
        let snapshots = try revisions(4)
        guard let presentation = presentation(kind, snapshots[0]) else { return }
        let watch = presentation.watch()
        let owner = Feed()
        presentation.observe(try owner.sequence())
        #expect(!presentation.isObserving)
        #expect(watch.reports.isEmpty)
        owner.offer(snapshots[3])
        await presentation.untilLive()
        #expect(presentation.snapshot.revision == 3)
        #expect(watch.reports == [true])
        presentation.stopObserving()
        #expect(owner.cancelled == 1)
    }

    // Each snapshot the presentation shows makes its sequence deliver the next one. `observe` applies at
    // most 32 of them, the first among them, before it returns, and the rest follow on later main-actor
    // turns. The registration is open throughout, so the observation is live from the first turn.
    @Test(arguments: PresentationClass.allCases)
    func aSequenceFedFromItsOwnSnapshotCallbackLetsTheObservationReturn(_ kind: PresentationClass) async throws {
        let snapshots = try revisions(100)
        guard let presentation = presentation(kind, snapshots[0]) else { return }
        let watch = presentation.watch()
        let owner = Feed()
        let last = Signal()
        watch.onShow = {
            let shown = watch.shown.count
            if shown < snapshots.count { owner.offer(snapshots[shown]) } else { last.raise() }
        }
        presentation.observe(try owner.sequence(first: snapshots[0]))
        let shownBeforeReturn = watch.shown.count
        #expect(shownBeforeReturn <= 32)
        #expect(presentation.isObserving)
        await last.wait()
        #expect(watch.shown.count == snapshots.count)
        #expect(presentation.snapshot.revision == 99)
        #expect(watch.reports == [true])
        presentation.stopObserving()
    }
}

/// An actor owner with one subscriber slot of its own, whose registration call can be held, and whose
/// token runs a hook when it is cancelled.
nonisolated private final class SlotActorHost: ActorStateMachineHost {
    typealias Hook = @Sendable () async -> Void
    private struct State {
        var held = 0
        var registrations = 0
        var afterRegistering: Hook?
        var afterRefusal: Hook?
        var onCancel: (@Sendable () -> Void)?
        var callbacks: [@Sendable () -> Void] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let seed: Snapshot

    init(seed: Snapshot) { self.seed = seed }

    /// How many times `snapshots()` was asked to register.
    var registrations: Int { state.withLock { $0.registrations } }
    /// Whether a registration holds the slot.
    var held: Int { state.withLock { $0.held } }
    /// Runs `hook` once, inside the next `snapshots()` that registers, before it returns.
    func afterRegistering(_ hook: @escaping Hook) { state.withLock { $0.afterRegistering = hook } }
    /// Raises `signal` from a main-actor job queued inside the next refusal, before that refusal is
    /// returned, so a test that waits for it runs after the refused observation has handled it.
    func reportRefusal(_ signal: Signal) {
        state.withLock { $0.afterRefusal = { Task { @MainActor in signal.raise() } } }
    }
    /// Runs `hook` when a registration's token is cancelled, after it freed the slot.
    func onCancel(_ hook: @escaping @Sendable () -> Void) { state.withLock { $0.onCancel = hook } }

    func snapshot() async -> Snapshot { seed }
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> {
        let admitted = state.withLock { state -> Bool in
            state.registrations += 1
            guard state.held == 0 else { return false }
            state.held += 1
            return true
        }
        guard admitted else {
            await state.withLock { state in
                defer { state.afterRefusal = nil }
                return state.afterRefusal
            }?()
            throw .capacityExceeded
        }
        await state.withLock { state in
            defer { state.afterRegistering = nil }
            return state.afterRegistering
        }?()
        let seed = seed
        return try SnapshotSequence<Snapshot> { [state] receive, finish in
            state.withLock { $0.callbacks += [{ receive(seed) }, finish] }
            receive(seed)
            return SnapshotSubscription { [state] in
                state.withLock { state in
                    state.held -= 1
                    return state.onCancel
                }?()
            }
        }
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        throw .capacityExceeded
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        throw .capacityExceeded
    }
}

/// The task of an observation, which a hook that runs on another thread cancels.
private final class ObservationTask: Sendable {
    private let task = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
    func hold(_ task: Task<Void, any Error>) { self.task.withLock { $0 = task } }
    func cancel() { task.withLock { $0 }?.cancel() }
    var value: Void {
        get async throws { try await task.withLock { $0 }?.value }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationCancelledWaitTests {
    // A holds the only slot inside its registration call. B replaces A and waits for A without asking
    // the owner. A's registration returns and is released, and that release cancels B's task, in the
    // same main-actor turn in which it frees the slot. The cancellation ends B's wait, and B registers
    // once, with the slot free: two registration calls, and B observes.
    @Test(arguments: PresentationClass.allCases)
    func aWaitCancelledWhileItsPredecessorReleasesTheSlotRegistersOnce(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = SlotActorHost(seed: try sharedTransfers().snapshot())
        guard let presentation = presentation(kind, await host.snapshot()) else { return }
        let holding = Signal()
        let proceed = Signal()
        host.afterRegistering {
            holding.raise()
            await proceed.wait()
        }
        let first = Task { try await presentation.observe(host) }
        await holding.wait()
        let second = ObservationTask()
        second.hold(Task.immediate { @MainActor in try await presentation.observe(host) })
        host.onCancel { second.cancel() }
        proceed.raise()
        try await first.value
        try await second.value
        #expect(host.registrations == 2)
        #expect(presentation.isObserving)
        #expect(host.held == 1)
        presentation.stopObserving()
    }
}
