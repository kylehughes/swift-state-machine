/// Why an owner refused to install a prepared candidate, or to reset.
///
/// Admission installs nothing when it reports one of these. When several apply, it reports the
/// first in declaration order, so a candidate from another owner or for a closed owner reports
/// that provenance before any defect in its effect plan.
nonisolated public enum CommitRejection: Error, Equatable, Sendable {
    /// The candidate was prepared from another owner's snapshot.
    case foreignOwner
    /// Admission has ended.
    case closed
    /// The candidate's effect plan is defective, which preparation found before any admission check.
    case plan(PlanRejection)
    /// A reset replaced the incarnation the candidate was prepared in.
    case obsoleteIncarnation
    /// An operation the candidate requires, or the delivery it finishes, is no longer active.
    case inactiveAuthority
    /// Another commit changed the root after the candidate's snapshot.
    case conflict
    /// The work the candidate starts would violate its operation's admission policy.
    case operationPolicy(PolicyFailure)
    /// The owner has used its last ordinary revision.
    case revisionExhausted
    /// An otherwise admissible candidate found a bounded queue or reservation pool full.
    case capacityExceeded(Capacity)

    /// The admission policy a candidate's work would violate.
    public enum PolicyFailure: Equatable, Sendable {
        /// The operation admits one active execution, and one is still active.
        case alreadyActive
        /// The operation's parallel limit is already reached.
        case parallelLimit
    }

    /// The bound a candidate found full.
    ///
    /// Draining batches or acknowledging work frees it.
    public enum Capacity: Equatable, Sendable {
        /// Every slot for queued command batches is occupied.
        case commitQueue
        /// Every execution and retained-delivery reservation is occupied.
        case executionReservations
    }
}
