/// Owner-bound identity of one retained terminal envelope in the raw runtime.
nonisolated public struct RuntimePendingID: Equatable, Sendable {
    private let identity: RuntimeIdentity
    fileprivate init() { identity = RuntimeIdentity() }
    /// Compares retained envelope identity only.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity === rhs.identity }
}

/// Explicit opt-in to reevaluating pure completion preparation after root conflicts.
nonisolated public enum RuntimeCompletionPolicy: Sendable {
    case manualOnConflict
    case retryPure
}

/// Historical delivery state, independent of physical execution termination.
nonisolated public enum RuntimePendingStatus: Equatable, Sendable {
    case awaitingAdmission
    case preparing
    case waitingForCapacity
    case reconciliationRequired
    case retryScheduled
}

/// Reusable retained-envelope algorithm for value, isolated, and shared hosts.
///
/// Hosts install this value and the associated runtime together. Ledger mutations do not explicitly invoke
/// domain closures; payload destruction and claimed preparation occur outside installation locks.
nonisolated public struct RuntimeDeliveryLedger<Model, Descriptor, Outcome, DomainFailure: Error> {
    /// The associated lower-guarantee value engine.
    public typealias Engine = RuntimeState<Model, Descriptor>
    /// A prepared candidate or its typed domain or permanent plan failure.
    public typealias Preparation = Result<Engine.Candidate, PreparationFailure<DomainFailure>>
    /// The last preparation or admission failure, without erasing its type.
    public enum Rejection: Sendable {
        case preparation(PreparationFailure<DomainFailure>)
        case admission(Engine.Rejection)
    }
    /// A historical projection of one first retained envelope.
    public struct Pending {
        /// The opaque identity of this retained envelope.
        public let id: RuntimePendingID
        /// The first retained terminal outcome.
        public let outcome: Outcome
        /// The delivery state when this projection was captured.
        public let status: RuntimePendingStatus
        /// The last failed preparation or admission, when present.
        public let lastRejection: Rejection?
        /// The saturating count of claimed preparations; capacity retries do not increment it.
        public let attempts: UInt64
        /// Whether the preparation count has reached its representable limit.
        public var attemptsSaturated: Bool { attempts == UInt64.max }
    }
    /// One exclusive preparation claim and its captured root observation.
    public struct Attempt {
        /// The opaque identity of this retained envelope.
        public let id: RuntimePendingID
        /// The first retained terminal outcome.
        public let outcome: Outcome
        /// The root observation captured while claiming this attempt.
        public let snapshot: Engine.Snapshot
        /// The raw claim to include in this attempt's accepted finishing plan.
        public let claim: RuntimeDeliveryClaim
        fileprivate let ticket: RuntimeTicket
    }
    /// Whether this caller acquired the only preparation claim.
    @frozen public enum ClaimResult {
        case claimed(Attempt)
        case inProgress
        case notPending
    }
    /// Whether the first envelope is retained, the operation is stale, or the ticket is another owner's.
    @frozen public enum Retention {
        case pending(RuntimePendingID)
        /// The operation's authority is inactive or its outcome was already settled.
        case stale
        /// The ticket was issued by a different owner, which is a caller error rather than a race.
        case foreignOwner
    }
    /// The outcome of one completed preparation and admission attempt.
    @frozen public enum Finish {
        case committed(Engine.Snapshot)
        case pending(RuntimePendingID, RuntimePendingStatus)
        case notPending
    }
    fileprivate struct Entry {
        let id: RuntimePendingID
        let ticket: RuntimeTicket
        let outcome: Outcome
        var status: RuntimePendingStatus = .awaitingAdmission
        var reason: Rejection?
        var attempts: UInt64 = 0
        var candidate: Engine.Candidate?
        var claim: RuntimeDeliveryClaim?
    }
    private var entries: [Entry] = []
    /// Creates an empty ledger for one associated runtime.
    public init() {}
    /// The number of retained envelopes, including any claimed by preparation.
    public var pendingCount: Int { entries.count }
    /// Historical typed projections; projecting does not claim preparation.
    public var pending: [Pending] {
        entries.map {
            Pending(id: $0.id, outcome: $0.outcome, status: $0.status, lastRejection: $0.reason, attempts: $0.attempts)
        }
    }
    /// Retains the first outcome together with its engine delivery disposition.
    public mutating func retain(_ outcome: Outcome, for ticket: RuntimeTicket, in engine: inout Engine) -> Retention {
        if let existing = entries.first(where: { $0.ticket == ticket }) { return .pending(existing.id) }
        switch engine.retainOutcome(for: ticket) {
        case .retained: break
        case .foreignOwner: return .foreignOwner
        case .duplicate, .inactiveAuthority: return .stale
        }
        let entry = Entry(id: RuntimePendingID(), ticket: ticket, outcome: outcome)
        entries.append(entry)
        return .pending(entry.id)
    }
    /// Removes invalidated envelopes while engine claims continue retaining reservations.
    public mutating func prune(in engine: Engine) {
        entries.removeAll { !engine.isActive($0.ticket) }
    }
    /// Claims one pending envelope and captures a fresh root before domain evaluation.
    ///
    /// A `scheduledRetry` claim belongs to a queued scheduler turn. It is granted only while the
    /// envelope is still `retryScheduled`: an attempt that finished after the turn was queued made
    /// a newer decision, and the queued turn reports `notPending` instead of overriding it.
    public mutating func claim(
        _ id: RuntimePendingID,
        in engine: inout Engine,
        scheduledRetry: Bool = false
    ) -> ClaimResult {
        prune(in: engine)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .notPending }
        guard entries[index].claim == nil else { return .inProgress }
        if scheduledRetry, entries[index].status != .retryScheduled { return .notPending }
        guard let claim = engine.claimDelivery(for: entries[index].ticket) else { return .notPending }
        entries[index].claim = claim
        entries[index].candidate = nil
        entries[index].status = .preparing
        if entries[index].attempts < UInt64.max { entries[index].attempts += 1 }
        return .claimed(
            Attempt(
                id: id,
                outcome: entries[index].outcome,
                snapshot: engine.snapshot,
                claim: claim,
                ticket: entries[index].ticket
            )
        )
    }
    /// Finishes exactly one preparation; capacity preserves the immutable candidate.
    ///
    /// A terminal candidate must require and retire this attempt's operation. A malformed
    /// plan retains the first envelope for reconciliation. Only this attempt's claim is
    /// acknowledged; unrelated still-running preparations keep their reservations.
    public mutating func finish(_ attempt: Attempt, preparation: Preparation, in engine: inout Engine) -> Finish {
        defer { engine.finishDeliveryClaim(attempt.claim) }
        guard
            let index = entries.firstIndex(where: { $0.id == attempt.id && $0.claim?.matches(attempt.claim) == true }),
            engine.isActive(attempt.ticket)
        else {
            prune(in: engine)
            return .notPending
        }
        entries[index].claim = nil
        switch preparation {
        case .failure(let rejection):
            entries[index].status = .reconciliationRequired
            entries[index].reason = .preparation(rejection)
            return .pending(attempt.id, .reconciliationRequired)
        case .success(let candidate):
            guard let terminal = candidate.validatedForDelivery(attempt.claim) else {
                entries[index].status = .reconciliationRequired
                entries[index].reason = .preparation(.plan(.invalidPlan))
                return .pending(attempt.id, .reconciliationRequired)
            }
            return admit(terminal, index: index, in: &engine)
        }
    }
    private mutating func admit(_ candidate: Engine.Candidate, index: Int, in engine: inout Engine) -> Finish {
        switch engine.commit(candidate) {
        case .committed(let snapshot):
            entries.remove(at: index)
            prune(in: engine)
            return .committed(snapshot)
        case .rejected(let reason, _):
            guard engine.isActive(entries[index].ticket) else {
                entries.remove(at: index)
                return .notPending
            }
            switch reason {
            case .capacityExceeded:
                entries[index].candidate = candidate.withoutFinishingClaims()
                entries[index].status = .waitingForCapacity
            default:
                entries[index].candidate = nil
                entries[index].status = .reconciliationRequired
            }
            entries[index].reason = .admission(reason)
            return .pending(entries[index].id, entries[index].status)
        }
    }
    /// Marks one pure-conflict result eligible for a later bounded scheduler round.
    public mutating func scheduleRetry(_ id: RuntimePendingID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].claim == nil else { return }
        entries[index].status = .retryScheduled
    }
    /// Admission-only retry; no router or reducer is evaluated here.
    public mutating func retryCapacity(in engine: inout Engine) -> [Finish] {
        prune(in: engine)
        let ids = entries.filter { $0.candidate != nil }.map(\.id)
        var results: [Finish] = []
        for id in ids {
            guard let index = entries.firstIndex(where: { $0.id == id }), let candidate = entries[index].candidate
            else { continue }
            results.append(admit(candidate, index: index, in: &engine))
        }
        return results
    }
    /// Admission-only retry of one retained candidate; no router or reducer is evaluated here.
    ///
    /// Reports the current status when the entry holds no prepared candidate.
    public mutating func retryAdmission(_ id: RuntimePendingID, in engine: inout Engine) -> Finish {
        prune(in: engine)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .notPending }
        guard let candidate = entries[index].candidate else { return .pending(id, entries[index].status) }
        return admit(candidate, index: index, in: &engine)
    }
    /// Explicit authority-only discard observes normal revision and queue checks.
    public mutating func discard(_ id: RuntimePendingID, in engine: inout Engine) -> Engine.Admission? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let ticket = entries[index].ticket
        guard
            let candidate = try? Engine.prepare(
                on: engine.snapshot,
                next: engine.snapshot.model,
                requiring: [ticket],
                plan: .init(retire: [ticket], controlCount: 1)
            )
        else { return nil }
        let result = engine.commit(candidate)
        if case .committed = result { prune(in: engine) }
        return result
    }
}

extension RuntimeDeliveryLedger: Sendable where Model: Sendable, Descriptor: Sendable, Outcome: Sendable {}
extension RuntimeDeliveryLedger.Entry: Sendable where Model: Sendable, Descriptor: Sendable, Outcome: Sendable {}
extension RuntimeDeliveryLedger.Pending: Sendable where Outcome: Sendable {}
extension RuntimeDeliveryLedger.Attempt: Sendable where Model: Sendable, Outcome: Sendable {}
extension RuntimeDeliveryLedger.ClaimResult: Sendable where Model: Sendable, Outcome: Sendable {}
extension RuntimeDeliveryLedger.Retention: Sendable {}
extension RuntimeDeliveryLedger.Finish: Sendable where Model: Sendable {}

extension RuntimeDeliveryLedger {
    /// The result of a bounded preparation turn.
    public enum Reconciliation {
        case finished(Finish)
        case inProgress
        case notPending
    }
    /// Runs the shared preparation policy using host-owned atomic claim/admission hooks.
    ///
    /// Each hook returns before the next is entered. Preparation therefore needs no
    /// shared lock, and actor-confined hosts can use the same algorithm without Sendable payloads.
    public static func reconcile(
        _ id: RuntimePendingID,
        policy: RuntimeCompletionPolicy,
        automatic: Bool,
        claim: () -> ClaimResult,
        prepare: (Attempt) -> Preparation,
        finish: (Attempt, Preparation) -> (Finish, Rejection?),
        scheduleRetry: (RuntimePendingID) -> Void
    ) -> Reconciliation {
        var preparations = 0
        while true {
            switch claim() {
            case .inProgress: return .inProgress
            case .notPending: return .notPending
            case .claimed(let attempt):
                let candidate = prepare(attempt)
                preparations += 1
                let (result, reason) = finish(attempt, candidate)
                if case .pending = result, automatic, case .retryPure = policy, case .admission(.conflict) = reason {
                    if preparations < 4 { continue }
                    scheduleRetry(id)
                    return .finished(.pending(id, .retryScheduled))
                }
                return .finished(result)
            }
        }
    }
}

/// Bounded by retained pending IDs, with one responsible scheduler per ready cohort.
nonisolated public struct RuntimeDeliveryReadyQueue: Sendable {
    private var ids: [RuntimePendingID] = []
    private var scheduled = false
    /// Creates an empty ready queue.
    public init() {}
    /// Returns true only when this insertion must schedule a turn.
    public mutating func enqueue(_ id: RuntimePendingID) -> Bool {
        if !ids.contains(id) { ids.append(id) }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
    /// Removes queued identities that no longer have retained envelopes.
    public mutating func prune(keeping pending: [RuntimePendingID]) { ids.removeAll { !pending.contains($0) } }
    /// Whether no ready IDs or responsible scheduling turn remain.
    public var isIdle: Bool { !scheduled && ids.isEmpty }
    /// Transfers one rotating round while retaining its scheduler responsibility.
    public mutating func takeRound() -> [RuntimePendingID] {
        let result = ids
        ids = []
        return result
    }
    /// Returns whether exactly one yielded continuation must own the next round.
    public mutating func finishRound() -> Bool {
        if ids.isEmpty {
            scheduled = false
            return false
        }
        return true
    }
}

extension RuntimeDeliveryLedger.Rejection: Equatable where DomainFailure: Equatable {}
