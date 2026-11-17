/// An opaque identity for one execution whose physical termination is still tracked.
///
/// The handle compares executions for identity only; it grants no authority over the operation.
nonisolated public struct RuntimeExecutionHandle: Equatable, Sendable {
    fileprivate let ticket: RuntimeTicket
}

/// An opaque identity for one delivery preparation that is still executing.
///
/// The handle compares preparations for identity only; it grants no authority over the retained outcome.
nonisolated public struct RuntimePreparationHandle: Equatable, Sendable {
    fileprivate let claim: RuntimeDeliveryClaim
}

/// An execution and delivery obligation that remained tracked when a shutdown deadline expired.
nonisolated public struct RuntimeOutstandingExecution: Equatable, Sendable {
    /// The opaque identity of the operation whose physical termination is still tracked.
    public let execution: RuntimeExecutionHandle
    /// The execution disposition at the diagnostic observation.
    public let disposition: RuntimeExecutionDisposition
    /// The separate delivery disposition at the diagnostic observation.
    public let delivery: RuntimeDeliveryDisposition
    /// The preparation still executing for this operation, when present.
    public let preparation: RuntimePreparationHandle?
}

/// The obligations a managed owner still tracked when its shutdown deadline expired.
///
/// The value is a coherent historical observation. It holds no model data and no authority to
/// change the owner, so it is safe to log, compare, and send across isolation boundaries.
nonisolated public struct RuntimeShutdownDiagnostics: Equatable, Sendable {
    /// The owner's last accepted revision at the observation.
    public let acceptedRevision: UInt64
    /// The revision of the last fully processed FIFO batch.
    public let processedThrough: UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    public let hasQueuedBatches: Bool
    /// Whether a FIFO processing turn still owns responsibility.
    public let isDraining: Bool
    /// The identities of the retained terminal envelopes.
    public let pendingCompletions: [RuntimePendingID]
    /// The executions, deliveries, and preparations that remain tracked.
    public let outstandingExecutions: [RuntimeOutstandingExecution]

    package init<Model, Descriptor>(
        engine: RuntimeState<Model, Descriptor>,
        processedThrough: UInt64,
        isDraining: Bool,
        pendingCompletions: [RuntimePendingID]
    ) {
        acceptedRevision = engine.snapshot.revision
        self.processedThrough = processedThrough
        hasQueuedBatches = engine.hasQueuedBatches
        self.isDraining = isDraining
        self.pendingCompletions = pendingCompletions
        outstandingExecutions = engine.executionReservations.map { reservation in
            RuntimeOutstandingExecution(
                execution: RuntimeExecutionHandle(ticket: reservation.ticket),
                disposition: reservation.execution,
                delivery: reservation.delivery,
                preparation: reservation.preparationClaim.map { RuntimePreparationHandle(claim: $0) }
            )
        }
    }
}
