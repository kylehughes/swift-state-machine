import Combine
import StateMachine

/// An `ObservableObject` projection of one complete `MainActor` snapshot across Apple platforms.
///
/// Supports the package's deployment targets, including iOS 16.
/// This object owns observation only. The enclosing screen or service owns the live
/// machine and decides when navigating away closes its work scope.
@MainActor public final class SnapshotPresentation<Snapshot>: ObservableObject {
    /// The latest complete snapshot; independently published phase fields cannot diverge.
    @Published public private(set) var snapshot: Snapshot
    /// Whether this presentation currently owns a live registration.
    @Published public private(set) var isObserving = false
    private let revision: @MainActor (Snapshot) -> UInt64
    private var watermark: UInt64
    private var subscription: RuntimeMainActorSubscription?

    /// Creates a historical projection without subscribing or starting work.
    public init(_ initial: Snapshot, revision: @escaping @MainActor (Snapshot) -> UInt64) {
        snapshot = initial
        watermark = revision(initial)
        self.revision = revision
    }
    /// Applies a newer complete snapshot synchronously; delayed delivery cannot regress the model.
    @discardableResult public func apply(_ next: Snapshot) -> Bool {
        let nextRevision = revision(next)
        guard nextRevision > watermark else { return false }
        watermark = nextRevision
        snapshot = next
        return true
    }
    /// Replaces observation ownership, receiving initial and terminal snapshots through the host.
    public func observe(
        _ register: (
            @escaping @MainActor (Snapshot) -> Void,
            @escaping @MainActor () -> Void
        ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription
    ) throws(RuntimeHostSubscriptionFailure) {
        stopObserving()
        isObserving = true
        do {
            subscription = try register(
                { [weak self] in self?.apply($0) },
                { [weak self] in self?.isObserving = false }
            )
        } catch {
            isObserving = false
            throw error
        }
    }
    /// Removes this presentation's registration synchronously.
    public func stopObserving() {
        subscription?.cancel()
        subscription = nil
        isObserving = false
    }
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
