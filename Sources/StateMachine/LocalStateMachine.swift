/// A manually driven owner whose caller performs every step synchronously.
///
/// Generated `Local` types conform so a harness such as `ManualMachineTest` in `StateMachineTesting`
/// can drive any graph's `Local` through one generic surface. Conforming confers no authority because
/// each requirement is part of the owner's sealed public surface or reads graph metadata from a value
/// the caller already holds. None of them constructs a snapshot, a proposal, a ticket, or a completion.
nonisolated public protocol LocalStateMachine: ~Copyable {
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
    /// The payload of the graph's initial phase, which `reset(to:)` installs.
    associatedtype InitialPhase

    /// The declared structure of this owner's graph.
    static var graph: StateMachineGraph { get }
    /// The identifier of the phase a snapshot holds, as ``StateMachineGraph/Phase/id`` names it.
    static func phase(of snapshot: Snapshot) -> String
    /// The receipt of an admitted proposal, or `nil` when admission rejected it.
    static func receipt(of result: CommitResult) -> Receipt?
    /// The identifier of the router or edge, as ``StateMachineGraph/Router/id`` and
    /// ``StateMachineGraph/Edge/id`` name them, whose authored function refused an input that `send`
    /// rejected from a snapshot in `phase`, or `nil` when no authored function refused it because no
    /// edge leaves the phase for the input or because admission refused the candidate.
    static func rejectingRoute(of rejection: SendRejection, in phase: String) -> String?

    /// Returns an immutable historical observation.
    borrowing func snapshot() -> Snapshot
    /// Whether `snapshot` was taken from this owner in any incarnation. A reset keeps the same owner.
    borrowing func owns(_ snapshot: Snapshot) -> Bool
    /// Routes, prepares, and admits one input against the current root.
    @discardableResult mutating func send(_ input: Input) throws(SendRejection) -> Receipt
    /// Consumes a proposal and admits it only if its observation is still current.
    mutating func commit(_ prepared: consuming Prepared) -> CommitResult
    /// Ends admission while retaining historical read access.
    @discardableResult mutating func close() -> Receipt
    /// Replaces the model with `initial` in a fresh incarnation, revoking outstanding work.
    @discardableResult mutating func reset(to initial: InitialPhase) throws(CommitRejection) -> Receipt
    /// Resets as `reset(to:)` does, but only while the owner still holds the root `expected` observed.
    @discardableResult mutating func reset(
        to initial: InitialPhase,
        expecting expected: Snapshot
    ) throws(CommitRejection) -> Receipt
}

extension LocalStateMachine where Self: ~Copyable {
    /// Attributes no rejection, for an owner that cannot name the function that refused an input.
    public static func rejectingRoute(of rejection: SendRejection, in phase: String) -> String? { nil }
}

/// A manually driven owner whose schema declares a default construction of its initial payload.
///
/// The generated `Local` of a graph whose `@Initial` case declares a default payload conforms, and
/// its own `reset()` and `reset(expecting:)` install that default.
nonisolated public protocol DefaultingLocalStateMachine: LocalStateMachine, ~Copyable {
    /// A fresh initial payload, constructed as the schema's declared default constructs it.
    static func defaultInitialPhase() -> InitialPhase
}

extension DefaultingLocalStateMachine where Self: ~Copyable {
    /// Replaces the model with a fresh default initial payload in a fresh incarnation, revoking
    /// outstanding work, as `reset(to:)` does with ``defaultInitialPhase()``.
    @discardableResult public mutating func reset() throws(CommitRejection) -> Receipt {
        try reset(to: Self.defaultInitialPhase())
    }
    /// Resets as ``reset()`` does, but only while the owner still holds the root `expected` observed.
    @discardableResult public mutating func reset(expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        try reset(to: Self.defaultInitialPhase(), expecting: expected)
    }
}

/// A manually driven owner whose schema declares a `@Restoration` function.
///
/// The generated `Local` of such a graph conforms.
nonisolated public protocol RestoringLocalStateMachine: LocalStateMachine, ~Copyable {
    /// The saved data the `@Restoration` function validates.
    associatedtype RestorationArchive
    /// Why a restoring reset changed nothing, either `CommitRejection` or the schema's
    /// `ResetRejection` when the `@Restoration` function throws.
    associatedtype RestorationRejection: Error

    /// Replaces the model with the phase restored from saved data in a fresh incarnation.
    ///
    /// The saved data is `sending`, so a `@Restoration` function that takes it as `sending` receives
    /// it, and `Sendable` saved data passes like any other argument.
    @discardableResult mutating func reset(
        restoring saved: sending RestorationArchive
    ) throws(RestorationRejection) -> Receipt
    /// Resets as `reset(restoring:)` does, but only while the owner still holds the root `expected` observed.
    @discardableResult mutating func reset(
        restoring saved: sending RestorationArchive,
        expecting expected: Snapshot
    ) throws(RestorationRejection) -> Receipt
}

/// One whole FIFO batch that a manually driven owner transfers to its caller.
///
/// Generated `CommandBatch` types conform.
nonisolated public protocol LocalCommandBatch {
    /// The receipt of the acceptance the batch belongs to.
    associatedtype Receipt
    /// One closed start, cancellation, or event command.
    associatedtype Command
    /// The atomic acceptance represented by this batch.
    var receipt: Receipt { get }
    /// The batch's commands, with cancellations first and starts and events in authored effect order.
    var commands: [Command] { get }
    /// Whether this is the separately reserved close batch.
    var terminal: Bool { get }
}

/// A manually driven owner whose acceptances queue command batches for its caller to drain.
///
/// The generated `Local` of a graph that declares an `@Operation` or an `@Event` conforms.
nonisolated public protocol DrainingLocalStateMachine: LocalStateMachine, ~Copyable {
    /// One closed start, cancellation, or event command.
    associatedtype Command
    /// One whole FIFO batch with its historical receipt.
    associatedtype CommandBatch: LocalCommandBatch
    where CommandBatch.Receipt == Receipt, CommandBatch.Command == Command

    /// Transfers whole FIFO batches, at most `limit` of them.
    mutating func drainCommands(limit: Int) -> [CommandBatch]
    /// How many whole batches a drain would transfer, without transferring any.
    var queuedBatchCount: Int { get }
    /// Whether closure, the transfer of every batch, and every execution obligation have settled.
    var isQuiescent: Bool { get }
}

/// A manually driven owner whose caller executes its operations and delivers their completions.
///
/// The generated `Local` of a graph that declares an `@Operation` conforms.
nonisolated public protocol DeliveringLocalStateMachine: DrainingLocalStateMachine, ~Copyable {
    /// The closed typed terminal outcomes of the graph's operations.
    associatedtype Completion
    /// A sealed handle to one execution's bookkeeping.
    associatedtype ExecutionHandle
    /// The opaque identity of one retained terminal outcome.
    associatedtype PendingCompletionID: Hashable
    /// A retained terminal outcome and its delivery diagnostics.
    associatedtype PendingCompletion
    /// The decision `deliver` made about one terminal outcome.
    associatedtype DeliveryResult
    /// The result of one more attempt to admit a retained outcome.
    associatedtype ReconcileResult
    /// The result of revoking a retained outcome's operation.
    associatedtype DiscardResult

    /// The receipt of a delivery that committed, or `nil` when the outcome was retained or not taken.
    static func receipt(of result: DeliveryResult) -> Receipt?
    /// The receipt of a retained outcome's admission, or `nil` when it did not commit.
    static func receipt(of result: ReconcileResult) -> Receipt?
    /// The receipt of a discard's authority-only commit, or `nil` when nothing was discarded.
    static func receipt(of result: DiscardResult) -> Receipt?
    /// The identifier of the router or completion edge, as ``StateMachineGraph/Router/id`` and
    /// ``StateMachineGraph/Edge/id`` name them, whose authored function refused the outcome in the
    /// `deliver` that returned `result`, or `nil` when that call's own preparation did not refuse it
    /// because the outcome committed, waits for capacity, was already retained, was not taken, or
    /// admission refused its candidate.
    static func rejectingRoute(of result: DeliveryResult) -> String?
    /// The identifier of the router or completion edge whose authored function refused the outcome in
    /// the `reconcile(id:)` that returned `result`, or `nil` when that call's own preparation did not
    /// refuse it, as for a delivery.
    static func rejectingRoute(of result: ReconcileResult) -> String?

    /// Retains the first outcome and attempts one typed preparation against the current root.
    mutating func deliver(_ completion: Completion) -> DeliveryResult
    /// Records actual termination independently of cancellation and completion delivery.
    mutating func acknowledgeExecution(
        _ execution: ExecutionHandle,
        disposition: ExecutionDisposition
    ) -> AcknowledgmentResult
    /// Claims one fresh preparation attempt for a retained outcome.
    mutating func reconcile(id: PendingCompletionID) -> ReconcileResult
    /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
    mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult
    /// Revokes one retained operation using an atomic authority-only commit.
    mutating func discardPending(id: PendingCompletionID) -> DiscardResult
    /// Reads immutable retained first-outcome records without claiming preparation.
    borrowing func pendingCompletions() -> [PendingCompletion]
}
