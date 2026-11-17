import Combine
import Observation
import StateMachine

/// An `ObservableObject` that drives one `MainActor` owner and publishes its complete snapshot.
///
/// Create it with a generated `MainActorHost`, read ``snapshot`` from a view, and call
/// ``send(_:)`` from its actions. An accepted input is visible in the same turn; snapshots
/// that arrive later through the subscription, such as an operation's result, are published
/// as they are delivered. Supports the package's deployment targets, including iOS 16.
@MainActor public final class StateMachinePresentation<Host: MainActorStateMachineHost>: ObservableObject {
    /// The latest complete snapshot; independently published phase fields cannot diverge.
    @Published public private(set) var snapshot: Host.Snapshot
    /// Whether this presentation still holds a live registration with its owner.
    @Published public private(set) var isObserving = false
    /// The owner, for delivery, reconciliation, and shutdown that the presentation does not wrap.
    public let host: Host
    private var watermark: UInt64
    private var publishing = false
    private var deferred: Host.Snapshot?
    private var subscription: RuntimeMainActorSubscription?

    /// Observes an owner from its current snapshot; this starts no work.
    public init(_ host: Host) throws(RuntimeHostSubscriptionFailure) {
        self.host = host
        let initial = host.snapshot()
        snapshot = initial
        watermark = initial.revision
        // A closed owner finishes inside `subscribe`, and that finish must be the last word.
        isObserving = true
        subscription = try host.subscribe(
            { [weak self] in self?.apply($0) },
            onFinish: { [weak self] in self?.isObserving = false }
        )
    }

    /// Admits one input and publishes its accepted snapshot before returning.
    @discardableResult public func send(_ input: Host.Input) throws(Host.SendRejection) -> Host.Receipt {
        let receipt = try host.send(input)
        apply(receipt.snapshot)
        return receipt
    }

    /// Admits a proposal from an edge of the snapshot a view rendered, exposing the result before returning.
    ///
    /// The proposal is checked against the owner's current revision, so an action offered from
    /// a snapshot that has since been replaced is rejected instead of applied to newer state.
    public func commit(_ prepared: consuming Host.Prepared) -> Host.CommitResult {
        let result = host.commit(prepared)
        apply(host.snapshot())
        return result
    }

    /// Stops observing, closes the owner, and publishes its terminal snapshot before returning.
    @discardableResult public func close() -> Host.Receipt {
        stopObserving()
        let receipt = host.close()
        apply(receipt.snapshot)
        return receipt
    }

    /// Removes this presentation's registration synchronously without closing the owner.
    public func stopObserving() {
        subscription?.cancel()
        subscription = nil
        isObserving = false
    }

    /// Publishes a snapshot only when it is newer, so a delayed delivery cannot regress the model.
    private func apply(_ next: Host.Snapshot) {
        guard next.revision > watermark else { return }
        watermark = next.revision
        guard !publishing else {
            deferred = next
            return
        }
        publishing = true
        snapshot = next
        // An observer that applied a newer snapshot during the assignment deferred it here,
        // so the outer assignment cannot overwrite the newer value.
        while let newer = deferred {
            deferred = nil
            snapshot = newer
        }
        publishing = false
    }
}

/// An `@Observable` model that drives one `MainActor` owner and exposes its complete snapshot.
///
/// The Observation counterpart of ``StateMachinePresentation``, for apps whose deployment
/// target permits it. Only ``snapshot`` and ``isObserving`` are tracked; the owner and its
/// authority are excluded from observation.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
@MainActor @Observable public final class ObservableStateMachinePresentation<Host: MainActorStateMachineHost> {
    /// The latest complete snapshot; independently observed phase fields cannot diverge.
    public private(set) var snapshot: Host.Snapshot
    /// Whether this model still holds a live registration with its owner.
    public private(set) var isObserving = false
    /// The owner, for delivery, reconciliation, and shutdown that the model does not wrap.
    @ObservationIgnored public let host: Host
    @ObservationIgnored private var watermark: UInt64
    @ObservationIgnored private var publishing = false
    @ObservationIgnored private var deferred: Host.Snapshot?
    @ObservationIgnored private var subscription: RuntimeMainActorSubscription?

    /// Observes an owner from its current snapshot; this starts no work.
    public init(_ host: Host) throws(RuntimeHostSubscriptionFailure) {
        self.host = host
        let initial = host.snapshot()
        snapshot = initial
        watermark = initial.revision
        // A closed owner finishes inside `subscribe`, and that finish must be the last word.
        isObserving = true
        subscription = try host.subscribe(
            { [weak self] in self?.apply($0) },
            onFinish: { [weak self] in self?.isObserving = false }
        )
    }

    /// Admits one input and exposes its accepted snapshot before returning.
    @discardableResult public func send(_ input: Host.Input) throws(Host.SendRejection) -> Host.Receipt {
        let receipt = try host.send(input)
        apply(receipt.snapshot)
        return receipt
    }

    /// Admits a proposal from an edge of the snapshot a view rendered, exposing the result before returning.
    ///
    /// The proposal is checked against the owner's current revision, so an action offered from
    /// a snapshot that has since been replaced is rejected instead of applied to newer state.
    public func commit(_ prepared: consuming Host.Prepared) -> Host.CommitResult {
        let result = host.commit(prepared)
        apply(host.snapshot())
        return result
    }

    /// Stops observing, closes the owner, and exposes its terminal snapshot before returning.
    @discardableResult public func close() -> Host.Receipt {
        stopObserving()
        let receipt = host.close()
        apply(receipt.snapshot)
        return receipt
    }

    /// Removes this model's registration synchronously without closing the owner.
    public func stopObserving() {
        subscription?.cancel()
        subscription = nil
        isObserving = false
    }

    /// Exposes a snapshot only when it is newer, so a delayed delivery cannot regress the model.
    private func apply(_ next: Host.Snapshot) {
        guard next.revision > watermark else { return }
        watermark = next.revision
        guard !publishing else {
            deferred = next
            return
        }
        publishing = true
        snapshot = next
        // An observer that applied a newer snapshot during the assignment deferred it here,
        // so the outer assignment cannot overwrite the newer value.
        while let newer = deferred {
            deferred = nil
            snapshot = newer
        }
        publishing = false
    }
}
