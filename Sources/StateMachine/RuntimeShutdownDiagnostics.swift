/// The obligations a managed owner still tracked when its shutdown deadline expired.
///
/// The value is a coherent historical observation, captured in the same critical section or actor
/// turn that found the deadline expired, so it always names at least one unsettled obligation. It
/// holds no model data and no authority to change the owner, so it is safe to log, compare, and
/// send across isolation boundaries.
nonisolated public struct ShutdownDiagnostics: Equatable, Sendable {
    /// Execution lifetime, independently of retained result delivery.
    public enum ExecutionDisposition: Equatable, Sendable {
        /// Accepted but not transferred for physical execution.
        case queued
        /// Transferred for physical execution, with termination still owed.
        case issued
        /// Actual termination was acknowledged.
        case terminated
        /// A revoked queued start was definitely skipped.
        case skipped
    }

    /// Result delivery lifetime, independently of physical execution.
    public enum DeliveryDisposition: Equatable, Sendable {
        /// No terminal envelope has yet been retained.
        case awaitingOutcome
        /// The first terminal envelope is retained by the facade ledger.
        case pending
        /// Delivery committed or was explicitly disposed after invalidation.
        case settled
    }

    /// An opaque identity for one execution whose physical termination is still tracked.
    ///
    /// The handle compares executions for identity only; it grants no authority over the operation.
    public struct ExecutionHandle: Equatable, Sendable {
        fileprivate let ticket: RuntimeTicket
    }

    /// An opaque identity for one delivery preparation that is still executing.
    ///
    /// The handle compares preparations for identity only; it grants no authority over the retained outcome.
    public struct PreparationHandle: Equatable, Sendable {
        fileprivate let claim: RuntimeDeliveryClaim
    }

    /// An execution and delivery obligation that remained tracked when a shutdown deadline expired.
    public struct OutstandingExecution: Equatable, Sendable {
        /// The opaque identity of the operation whose physical termination is still tracked.
        public let execution: ExecutionHandle
        /// The execution disposition at the diagnostic observation.
        public let disposition: ExecutionDisposition
        /// The separate delivery disposition at the diagnostic observation.
        public let delivery: DeliveryDisposition
        /// The preparation still executing for this operation, when present.
        public let preparation: PreparationHandle?
    }

    /// The owner's last accepted revision at the observation.
    public let acceptedRevision: UInt64
    /// The revision of the last fully processed FIFO batch.
    public let processedThrough: UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    public let hasQueuedBatches: Bool
    /// Whether a FIFO processing turn still owns responsibility.
    public let isDraining: Bool
    /// Whether an automatic retry of a retained completion is still scheduled.
    public let isRetrying: Bool
    /// The identities of the retained terminal envelopes.
    public let pendingCompletions: [RuntimePendingID]
    /// The executions, deliveries, and preparations that remain tracked.
    public let outstandingExecutions: [OutstandingExecution]

    package init<Model, Descriptor>(
        engine: RuntimeState<Model, Descriptor>,
        processedThrough: UInt64,
        isDraining: Bool,
        isRetrying: Bool,
        pendingCompletions: [RuntimePendingID]
    ) {
        acceptedRevision = engine.snapshot.revision
        self.processedThrough = processedThrough
        hasQueuedBatches = engine.hasQueuedBatches
        self.isDraining = isDraining
        self.isRetrying = isRetrying
        self.pendingCompletions = pendingCompletions
        outstandingExecutions = engine.executionReservations.map { reservation in
            OutstandingExecution(
                execution: ExecutionHandle(ticket: reservation.ticket),
                disposition: reservation.execution,
                delivery: reservation.delivery,
                preparation: reservation.preparationClaim.map { PreparationHandle(claim: $0) }
            )
        }
    }
}
