/// How a manually executed operation ended, independently of cancellation or completion delivery.
///
/// Every generated schema with operations names this type `ExecutionDisposition`.
nonisolated public enum ExecutionDisposition: Equatable, Hashable, Sendable {
    /// The work ran and its execution has ended.
    case terminated
    /// The caller never began the work, for example because it was cancelled before it started.
    case skippedBeforeStart
}

/// Whether an owner recorded the end of a physical execution.
///
/// Every generated schema with operations names this type `AcknowledgmentResult`.
nonisolated public enum AcknowledgmentResult: Equatable, Hashable, Sendable {
    /// The owner recorded the end of the execution.
    case recorded
    /// The execution's end was already acknowledged, or its obligation was already released.
    case duplicate
    /// The execution belongs to a different owner.
    case foreignOwner
}

/// Whether `flush(through:)` waited for a receipt's batch to be processed.
///
/// Every generated managed owner names this type `FlushResult`.
nonisolated public enum FlushResult: Equatable, Hashable, Sendable {
    /// The owner processed every batch through the receipt. For a graph with operations, it has made
    /// their cancellation and launch decisions. For one without operations, it has offered every
    /// snapshot through the receipt to its subscriptions.
    case processed
    /// The receipt was issued by a different owner, so there was nothing to wait for.
    case foreignOwner
}
