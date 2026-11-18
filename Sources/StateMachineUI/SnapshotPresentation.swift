import Combine
import Observation
import StateMachine

/// An `ObservableObject` projection of one complete `MainActor` snapshot across Apple platforms.
///
/// The Combine counterpart of ``SnapshotPresentation``, with the same members, for apps that
/// deploy before iOS 17. It supports every deployment target of the package, including iOS 16.
/// This object owns observation only. The enclosing screen or service owns the live
/// machine and decides when navigating away closes its work scope.
@MainActor public final class SnapshotObservableObject<Snapshot>: ObservableObject {
    /// The latest complete snapshot; independently published phase fields cannot diverge.
    @Published public private(set) var snapshot: Snapshot
    /// Whether this presentation currently owns a live registration.
    @Published public private(set) var isObserving = false
    private let revision: @MainActor (Snapshot) -> UInt64
    private var watermark: UInt64
    private var publishing = false
    private var deferred: Snapshot?
    private var subscription: MainActorSnapshotSubscription?
    private var observation: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Creates a historical projection without subscribing or starting work.
    public init(_ initial: Snapshot, revision: @escaping @MainActor (Snapshot) -> UInt64) {
        snapshot = initial
        watermark = revision(initial)
        self.revision = revision
    }
    deinit { observation?.cancel() }
    /// Applies a newer complete snapshot synchronously; delayed delivery cannot regress the model.
    @discardableResult public func apply(_ next: Snapshot) -> Bool {
        let nextRevision = revision(next)
        guard nextRevision > watermark else { return false }
        watermark = nextRevision
        publish(next)
        return true
    }
    // Assigns in arrival order. An observer that applies a newer snapshot while one is being
    // assigned defers it, so the outer assignment cannot overwrite the newer value.
    private func publish(_ next: Snapshot) {
        guard !publishing else {
            deferred = next
            return
        }
        publishing = true
        snapshot = next
        while let newer = deferred {
            deferred = nil
            snapshot = newer
        }
        publishing = false
    }
    /// Replaces observation ownership, receiving initial and terminal snapshots through the host.
    ///
    /// Pass `current` when `register` subscribes to a different owner than the one shown so far: the
    /// presentation shows it at once and restarts its revision check from it, because each owner counts
    /// its own revisions. Without it, the registration continues the same owner's history, and a
    /// delivery that is not newer than the snapshot shown is discarded. Deliveries and the finish of a
    /// replaced observation are always discarded.
    ///
    /// A callback that runs while this method shows `current` or calls `register` can start another
    /// observation. The newer observation keeps its registration, and this one is cancelled.
    public func observe(
        startingAt current: Snapshot? = nil,
        _ register: (
            @escaping @MainActor (Snapshot) -> Void,
            @escaping @MainActor () -> Void
        ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription
    ) throws(SubscriptionFailure) {
        guard let observing = replaceObservation(startingAt: current) else { return }
        let registration: MainActorSnapshotSubscription
        do {
            registration = try register(
                { [weak self] in if self?.generation == observing { self?.apply($0) } },
                { [weak self] in if self?.generation == observing { self?.isObserving = false } }
            )
        } catch {
            if generation == observing { isObserving = false }
            throw error
        }
        // A callback that ran during registration may have started a newer observation, which keeps
        // its own registration; this one is cancelled instead of replacing it.
        guard generation == observing else {
            registration.cancel()
            return
        }
        subscription = registration
    }
    /// Replaces observation ownership with a sequence from a shared or actor owner.
    ///
    /// Each snapshot is applied on the main actor through the revision check. `isObserving`
    /// becomes `false` when the sequence ends; `snapshot` keeps the last value applied.
    ///
    /// Pass `current` when `snapshots` comes from a different owner than the one shown so far: the
    /// presentation shows it at once and restarts its revision check from it, because each owner counts
    /// its own revisions. Without it, the sequence continues the same owner's history. Snapshots that
    /// a replaced observation still delivers are discarded. If a callback starts another observation
    /// while `current` is shown, the newer observation wins and this sequence is not followed.
    public func observe(_ snapshots: SnapshotSequence<Snapshot>, startingAt current: Snapshot? = nil)
    where Snapshot: Sendable {
        _ = start(snapshots, startingAt: current)
    }
    // Starts following a sequence and returns its task, or `nil` when a callback that ran while
    // the new source was shown started a newer observation, which then owns the presentation.
    private func start(
        _ snapshots: SnapshotSequence<Snapshot>,
        startingAt current: Snapshot?
    ) -> Task<Void, Never>? where Snapshot: Sendable {
        guard let observing = replaceObservation(startingAt: current) else { return nil }
        let task = Task { [weak self] in
            for await next in snapshots {
                // `stopObserving` cancels on the main actor, so a value that was already
                // in flight is discarded here and never applied after the stop. The loop
                // continues so that the cancelled iterator ends and removes its registration.
                if Task.isCancelled { continue }
                guard let self else { return }
                if self.generation == observing { self.apply(next) }
            }
            if !Task.isCancelled, self?.generation == observing { self?.isObserving = false }
        }
        observation = task
        return task
    }
    /// Observes a sequence for as long as the calling task runs.
    ///
    /// Returns when the sequence ends, when the calling task is cancelled, or when
    /// ``stopObserving()`` or another observation replaces this one. This suits SwiftUI's
    /// `task` modifier, which cancels the task when the view disappears. Pass `current` for a
    /// sequence from a different owner, as with ``observe(_:startingAt:)``.
    public func follow(_ snapshots: SnapshotSequence<Snapshot>, startingAt current: Snapshot? = nil) async
    where Snapshot: Sendable {
        guard let task = start(snapshots, startingAt: current) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled, observation == task { stopObserving() }
    }
    /// Removes this presentation's registration synchronously.
    public func stopObserving() { _ = endObservation() }
    // Ends the current observation and claims a new generation before anything is published, so a
    // callback that starts another observation during the publication claims a later one.
    private func endObservation() -> UInt64 {
        generation &+= 1
        let claimed = generation
        subscription?.cancel()
        subscription = nil
        observation?.cancel()
        observation = nil
        isObserving = false
        return claimed
    }
    // Ends the current observation and, for a new source, shows its snapshot and restarts the
    // revision check from it. Returns the generation the new observation's deliveries must carry,
    // or `nil` when a callback started a newer observation while this one was being shown.
    private func replaceObservation(startingAt current: Snapshot?) -> UInt64? {
        let observing = endObservation()
        if let current {
            watermark = revision(current)
            publish(current)
        }
        guard generation == observing else { return nil }
        isObserving = true
        return generation == observing ? observing : nil
    }
}

extension SnapshotObservableObject where Snapshot: StateMachineSnapshot {
    /// Creates a historical projection of a generated snapshot without subscribing or starting work.
    public convenience init(_ initial: Snapshot) { self.init(initial, revision: { $0.revision }) }
}

/// An `@Observable` projection of one complete `MainActor` snapshot.
///
/// Only ``snapshot`` and ``isObserving`` are tracked. This object owns observation only. The
/// enclosing screen or service owns the live machine and decides when navigating away closes its
/// work scope. It requires iOS 17 or a matching release; ``SnapshotObservableObject`` has the same
/// members for earlier ones.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
@MainActor @Observable public final class SnapshotPresentation<Snapshot> {
    /// The latest complete snapshot; independently observed phase fields cannot diverge.
    public private(set) var snapshot: Snapshot
    /// Whether this model currently owns a live registration.
    public private(set) var isObserving = false
    @ObservationIgnored private let revision: @MainActor (Snapshot) -> UInt64
    @ObservationIgnored private var watermark: UInt64
    @ObservationIgnored private var publishing = false
    @ObservationIgnored private var deferred: Snapshot?
    @ObservationIgnored private var subscription: MainActorSnapshotSubscription?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    /// Creates a historical projection without subscribing or starting work.
    public init(_ initial: Snapshot, revision: @escaping @MainActor (Snapshot) -> UInt64) {
        snapshot = initial
        watermark = revision(initial)
        self.revision = revision
    }
    deinit { observation?.cancel() }
    /// Applies a newer complete snapshot synchronously; delayed delivery cannot regress the model.
    @discardableResult public func apply(_ next: Snapshot) -> Bool {
        let nextRevision = revision(next)
        guard nextRevision > watermark else { return false }
        watermark = nextRevision
        publish(next)
        return true
    }
    // Assigns in arrival order. An observer that applies a newer snapshot while one is being
    // assigned defers it, so the outer assignment cannot overwrite the newer value.
    private func publish(_ next: Snapshot) {
        guard !publishing else {
            deferred = next
            return
        }
        publishing = true
        snapshot = next
        while let newer = deferred {
            deferred = nil
            snapshot = newer
        }
        publishing = false
    }
    /// Replaces observation ownership, receiving initial and terminal snapshots through the host.
    ///
    /// Pass `current` when `register` subscribes to a different owner than the one shown so far: the
    /// model shows it at once and restarts its revision check from it, because each owner counts
    /// its own revisions. Without it, the registration continues the same owner's history, and a
    /// delivery that is not newer than the snapshot shown is discarded. Deliveries and the finish of a
    /// replaced observation are always discarded.
    ///
    /// A callback that runs while this method shows `current` or calls `register` can start another
    /// observation. The newer observation keeps its registration, and this one is cancelled.
    public func observe(
        startingAt current: Snapshot? = nil,
        _ register: (
            @escaping @MainActor (Snapshot) -> Void,
            @escaping @MainActor () -> Void
        ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription
    ) throws(SubscriptionFailure) {
        guard let observing = replaceObservation(startingAt: current) else { return }
        let registration: MainActorSnapshotSubscription
        do {
            registration = try register(
                { [weak self] in if self?.generation == observing { self?.apply($0) } },
                { [weak self] in if self?.generation == observing { self?.isObserving = false } }
            )
        } catch {
            if generation == observing { isObserving = false }
            throw error
        }
        // A callback that ran during registration may have started a newer observation, which keeps
        // its own registration; this one is cancelled instead of replacing it.
        guard generation == observing else {
            registration.cancel()
            return
        }
        subscription = registration
    }
    /// Replaces observation ownership with a sequence from a shared or actor owner.
    ///
    /// Each snapshot is applied on the main actor through the revision check. `isObserving`
    /// becomes `false` when the sequence ends; `snapshot` keeps the last value applied.
    ///
    /// Pass `current` when `snapshots` comes from a different owner than the one shown so far: the
    /// model shows it at once and restarts its revision check from it, because each owner counts
    /// its own revisions. Without it, the sequence continues the same owner's history. Snapshots that
    /// a replaced observation still delivers are discarded. If a callback starts another observation
    /// while `current` is shown, the newer observation wins and this sequence is not followed.
    public func observe(_ snapshots: SnapshotSequence<Snapshot>, startingAt current: Snapshot? = nil)
    where Snapshot: Sendable {
        _ = start(snapshots, startingAt: current)
    }
    // Starts following a sequence and returns its task, or `nil` when a callback that ran while
    // the new source was shown started a newer observation, which then owns the presentation.
    private func start(
        _ snapshots: SnapshotSequence<Snapshot>,
        startingAt current: Snapshot?
    ) -> Task<Void, Never>? where Snapshot: Sendable {
        guard let observing = replaceObservation(startingAt: current) else { return nil }
        let task = Task { [weak self] in
            for await next in snapshots {
                // `stopObserving` cancels on the main actor, so a value that was already
                // in flight is discarded here and never applied after the stop. The loop
                // continues so that the cancelled iterator ends and removes its registration.
                if Task.isCancelled { continue }
                guard let self else { return }
                if self.generation == observing { self.apply(next) }
            }
            if !Task.isCancelled, self?.generation == observing { self?.isObserving = false }
        }
        observation = task
        return task
    }
    /// Observes a sequence for as long as the calling task runs.
    ///
    /// Returns when the sequence ends, when the calling task is cancelled, or when
    /// ``stopObserving()`` or another observation replaces this one. This suits SwiftUI's
    /// `task` modifier, which cancels the task when the view disappears. Pass `current` for a
    /// sequence from a different owner, as with ``observe(_:startingAt:)``.
    public func follow(_ snapshots: SnapshotSequence<Snapshot>, startingAt current: Snapshot? = nil) async
    where Snapshot: Sendable {
        guard let task = start(snapshots, startingAt: current) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled, observation == task { stopObserving() }
    }
    /// Removes this model's registration synchronously.
    public func stopObserving() { _ = endObservation() }
    // Ends the current observation and claims a new generation before anything is published, so a
    // callback that starts another observation during the publication claims a later one.
    private func endObservation() -> UInt64 {
        generation &+= 1
        let claimed = generation
        subscription?.cancel()
        subscription = nil
        observation?.cancel()
        observation = nil
        isObserving = false
        return claimed
    }
    // Ends the current observation and, for a new source, shows its snapshot and restarts the
    // revision check from it. Returns the generation the new observation's deliveries must carry,
    // or `nil` when a callback started a newer observation while this one was being shown.
    private func replaceObservation(startingAt current: Snapshot?) -> UInt64? {
        let observing = endObservation()
        if let current {
            watermark = revision(current)
            publish(current)
        }
        guard generation == observing else { return nil }
        isObserving = true
        return generation == observing ? observing : nil
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
extension SnapshotPresentation where Snapshot: StateMachineSnapshot {
    /// Creates a historical projection of a generated snapshot without subscribing or starting work.
    public convenience init(_ initial: Snapshot) { self.init(initial, revision: { $0.revision }) }
}

/// A capacity-one bridge from Sendable background snapshots to MainActor presentation.
///
/// Offers replace pending UI data, never effect commands. Exactly one responsible
/// delivery task exists per active cohort, regardless of the number of offered updates.
nonisolated public final class MainActorSnapshotIngress<Snapshot: Sendable>: Sendable {
    private struct Envelope: Sendable {
        let value: Snapshot
        let revision: UInt64
    }
    private struct State: Sendable {
        var pending: Envelope?
        var watermark: UInt64?
        var scheduled = false
        var closed = false
    }
    private let state = AtomicRecordStorage(State())
    private let receive: @MainActor @Sendable (Snapshot) -> Void
    /// Selects the isolated presentation callback without retaining a live machine.
    public init(_ receive: @escaping @MainActor @Sendable (Snapshot) -> Void) { self.receive = receive }
    /// Stages only a newer revision and schedules at most one responsible delivery task.
    public func offer(_ snapshot: Snapshot, revision: UInt64) {
        while true {
            let before = state.load()
            guard !before.value.closed, before.value.watermark.map({ revision > $0 }) ?? true else { return }
            var after = before.value
            after.pending = Envelope(value: snapshot, revision: revision)
            after.watermark = revision
            let wake = !after.scheduled
            after.scheduled = true
            guard state.install(.init(after), replacing: before) else { continue }
            if wake { Task { @MainActor in self.deliver() } }
            return
        }
    }
    /// Stops future application, permitting an already-claimed callback to finish.
    public func cancel() {
        while true {
            let before = state.load()
            var after = before.value
            after.closed = true
            after.pending = nil
            if state.install(.init(after), replacing: before) { return }
        }
    }
    @MainActor private func deliver() {
        var count = 0
        while true {
            let before = state.load()
            var after = before.value
            guard !after.closed, let envelope = after.pending else {
                after.scheduled = false
                if state.install(.init(after), replacing: before) { return }
                continue
            }
            after.pending = nil
            guard state.install(.init(after), replacing: before) else { continue }
            receive(envelope.value)
            count += 1
            if count == 32 {
                Task { @MainActor in
                    await Task.yield()
                    self.deliver()
                }
                return
            }
        }
    }
}
