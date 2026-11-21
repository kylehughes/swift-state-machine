import Observation

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
    /// The identifier of the graph edge the acceptance took, as ``StateMachineGraph/Edge/id`` names it,
    /// or `nil` for a change that takes no edge, such as a reset or closure.
    var edgeID: String? { get }
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
    /// A sealed proposal produced by an edge method of an observed phase.
    associatedtype Prepared: ~Copyable
    /// Whether a proposal was admitted, and the current snapshot when it was not.
    associatedtype CommitResult

    /// Captures a complete historical observation.
    func snapshot() -> Snapshot
    /// Routes, prepares, and admits one input in a single isolated turn.
    @discardableResult func send(_ input: Input) throws(SendRejection) -> Receipt
    /// Consumes a proposal and admits it only if its observation is still current.
    func commit(_ prepared: consuming Prepared) -> CommitResult
    /// Subscribes to initial, accepted, and terminal complete snapshots, taking a subscriber slot when called.
    func subscribe(
        _ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription
    /// Registers a single-pass sequence of `Sendable` projections, computed on the main actor, that any
    /// isolation domain can consume, taking a subscriber slot when called.
    ///
    /// It offers each projection, equal to the one before it or not.
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection>
    /// Registers a single-pass sequence of `Equatable` projections, computed on the main actor, that
    /// omits each projection equal to the one before it, taking a subscriber slot when called.
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection>
    /// Closes admission while preserving historical model data.
    @discardableResult func close() -> Receipt
}

extension MainActorStateMachineHost {
    /// Registers a single-pass sequence of `Sendable` projections through ``subscribe(_:onFinish:)``,
    /// taking a subscriber slot when called.
    ///
    /// A host of your own, such as a test double, inherits this projection from its subscription.
    /// Ending the sequence stops delivery at once and cancels the subscription on the main actor.
    /// The sequence's `cancel()` cancels it before returning when the call is isolated to the main
    /// actor, including after a call elsewhere came first, and so does a read isolated to the main
    /// actor that finds the sequence ended. A call or a read from another actor or from a nonisolated
    /// function, such as a destructor, the release of the sequence, and the owner's finish leave the
    /// cancellation to the next main-actor turn. A host that frees its slot when its subscription is
    /// cancelled therefore admits a replacement in the same main-actor turn as a main-actor call of
    /// `cancel()`, and the unread element that call discards is released only after that, so its
    /// destructor can register again. An element that a call elsewhere discards after the owner's
    /// finish or another call queued the cancellation waits for that turn's cancellation the same way.
    public func snapshots<Projection: Sendable>(
        _ transform: @escaping @MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try SnapshotSequence(mainActor: { transform($0) }) { (receive, finish, gate) throws(SubscriptionFailure) in
            try subscribe({ if gate.isOpen { receive($0) } }, onFinish: { if gate.isOpen { finish() } })
        }
    }
    /// Registers a single-pass sequence of `Equatable` projections through ``subscribe(_:onFinish:)``,
    /// omitting each projection equal to the one before it, and takes a subscriber slot when called.
    ///
    /// A host of your own, such as a test double, inherits this projection from its subscription,
    /// and ending it cancels that subscription as ``snapshots(_:)`` describes.
    public func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let distinct = RuntimeDistinctProjection<Projection>()
        return try SnapshotSequence(mainActor: { distinct.admit(transform($0)) }) {
            (receive, finish, gate) throws(SubscriptionFailure) in
            try subscribe({ if gate.isOpen { receive($0) } }, onFinish: { if gate.isOpen { finish() } })
        }
    }
}

/// The base class of every generated `MainActorHost`, which makes it `Observable` wherever the
/// Observation framework exists.
///
/// It has no state and no members of its own. On iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1,
/// and Mac Catalyst 17 and later, a generated host is `Observable`: a SwiftUI view can read it
/// directly, and the environment can carry it. Its `currentSnapshot`, `snapshot()`, `runningCount`,
/// `subscriberCount`, and `pendingCompletions()` each register a read of their own value, so a commit
/// invalidates a reader of the snapshot without invalidating a reader of the running count, and
/// tracking takes no subscriber slot. Earlier systems observe through a subscription, a snapshot
/// sequence, or a presentation.
@MainActor open class ObservableMainActorHost {
    /// Creates the base of a generated host.
    public init() {}
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
extension ObservableMainActorHost: Observable {}

/// A shared owner that any isolation domain can observe.
///
/// Generated `Shared` types conform. Conforming confers no authority: every requirement is
/// already part of the owner's sealed public surface.
nonisolated public protocol SharedStateMachineHost: AnyObject, Sendable {
    /// A complete historical observation of this owner.
    associatedtype Snapshot: StateMachineSnapshot & Sendable
    /// Captures a complete historical observation.
    func snapshot() -> Snapshot
    /// Registers a single-pass sequence of the latest complete snapshots, taking a subscriber slot when called.
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot>
    /// Registers a single-pass sequence of `Sendable` projections, computed on the registration's
    /// serial delivery path outside every lock, taking a subscriber slot when called.
    ///
    /// It offers each projection, equal to the one before it or not.
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection>
    /// Registers a single-pass sequence of `Equatable` projections, computed on the registration's
    /// serial delivery path outside every lock, that omits each projection equal to the one before it,
    /// taking a subscriber slot when called.
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection>
}

/// An owner isolated to an actor of its own that any isolation domain can observe.
///
/// Generated `ActorHost` types conform. Conforming confers no authority: every requirement is
/// already part of the owner's sealed public surface.
nonisolated public protocol ActorStateMachineHost: AnyObject, Sendable {
    /// A complete historical observation of this owner.
    associatedtype Snapshot: StateMachineSnapshot & Sendable
    /// Captures a complete historical observation.
    func snapshot() async -> Snapshot
    /// Registers a single-pass sequence of the latest complete snapshots, taking a subscriber slot when called.
    func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<Snapshot>
    /// Registers a single-pass sequence of `Sendable` projections, computed in the owner's actor turn,
    /// taking a subscriber slot when called.
    ///
    /// It offers each projection, equal to the one before it or not.
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection>
    /// Registers a single-pass sequence of `Equatable` projections, computed in the owner's actor turn,
    /// that omits each projection equal to the one before it, taking a subscriber slot when called.
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection>
}

/// An owner confined to one caller-chosen actor.
///
/// Generated `IsolatedHost` types conform. Every requirement runs on `Owner` and is already part of
/// the owner's sealed public surface, so conforming confers no authority.
nonisolated public protocol IsolatedStateMachineHost: AnyObject {
    /// The actor this owner is confined to.
    associatedtype Owner: Actor
    /// A complete historical observation of this owner.
    associatedtype Snapshot: StateMachineSnapshot
    /// Captures a complete historical observation.
    func snapshot(isolation: isolated Owner) -> Snapshot
    /// Subscribes to initial, accepted, and terminal complete snapshots, delivered on `Owner`, taking a
    /// subscriber slot when called.
    ///
    /// The registration stays in `Owner`'s region, and only `Owner` can cancel it, which removes it at
    /// once. Dropping it stops delivery and frees its slot at once; the host releases its callbacks
    /// when it next sweeps its registrations or is destroyed.
    func subscribe(
        _ receive: @escaping (Snapshot) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Owner>
    /// Registers a single-pass sequence of `Sendable` projections, computed on `Owner`, that any
    /// isolation domain can consume, taking a subscriber slot when called.
    ///
    /// It offers each projection, equal to the one before it or not.
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection>
    /// Registers a single-pass sequence of `Equatable` projections, computed on `Owner`, that omits
    /// each projection equal to the one before it, taking a subscriber slot when called.
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection>
}
