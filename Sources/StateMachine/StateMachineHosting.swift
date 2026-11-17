/// A complete observation that carries its accepted revision.
///
/// Generated `Snapshot` types conform, which lets a presentation discard a delayed
/// delivery instead of regressing the visible model.
nonisolated public protocol StateMachineSnapshot {
    /// The owner-lifetime accepted revision of this observation.
    var revision: UInt64 { get }
}

/// A receipt that carries the complete snapshot it accepted.
nonisolated public protocol StateMachineReceipt {
    /// The observation type of the issuing owner.
    associatedtype Snapshot: StateMachineSnapshot
    /// The accepted historical observation.
    var snapshot: Snapshot { get }
}

/// A `MainActor` owner that a presentation can drive and observe.
///
/// Generated `MainActorHost` types conform. Conforming confers no authority: every
/// requirement is already part of the owner's sealed public surface.
@MainActor public protocol MainActorStateMachineHost: AnyObject {
    /// The closed dynamic inputs this owner routes.
    associatedtype Input
    /// A complete historical observation of this owner.
    associatedtype Snapshot: StateMachineSnapshot
    /// The receipt for one accepted change.
    associatedtype Receipt: StateMachineReceipt where Receipt.Snapshot == Snapshot
    /// Why `send` did not admit an input.
    associatedtype SendRejection: Error

    /// Captures a complete historical observation.
    func snapshot() -> Snapshot
    /// Routes, prepares, and admits one input in a single isolated turn.
    @discardableResult func send(_ input: Input) throws(SendRejection) -> Receipt
    /// Subscribes to initial, accepted, and terminal complete snapshots.
    func subscribe(
        _ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription
    /// Closes admission while preserving historical model data.
    func close() -> Receipt
}
