/// A raw managed delivery disposition, without granting a domain facade's authority.
@frozen nonisolated public enum RuntimeHostDelivery<Model, Descriptor> {
    case committed(RuntimeState<Model, Descriptor>.Snapshot)
    case pending(RuntimePendingID, RuntimePendingStatus)
    case inProgress
    case notPending
    case stale
    case foreignOwner
    case discarded(RuntimeState<Model, Descriptor>.Snapshot)
    case rejected(RuntimeState<Model, Descriptor>.Rejection)
}

extension RuntimeHostDelivery: Sendable where Model: Sendable, Descriptor: Sendable {}

/// Failure to register another live managed observer.
nonisolated public enum RuntimeHostSubscriptionFailure: Error { case capacityExceeded }

nonisolated struct RuntimeConfinedExecution: Sendable {
    let ticket: RuntimeTicket
    let identity: RuntimeIdentity
    let worker: Task<Void, Never>
    var watcher: Task<Void, Never>?
}

/// Explicit MainActor ownership of one observer registration.
@MainActor public final class RuntimeMainActorSubscription {
    private let action: @MainActor @Sendable () -> Void
    private var cancelled = false

    package init(_ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
    /// Removes the registration synchronously; an already-claimed callback may finish.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        action()
    }
    deinit {
        let action = action
        Task { @MainActor in action() }
    }
}
