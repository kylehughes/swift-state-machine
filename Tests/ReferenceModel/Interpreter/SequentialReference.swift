/// Specification interpreter only.
///
/// It imports no production runtime and executes no tasks.
/// Explicit begin/finish and pop/process commands represent scheduler gates.
enum ReferenceScope: Int, CaseIterable, Sendable { case load, authentication, child }
enum ReferenceRestorationPolicy: Equatable, Sendable { case rejectLoading, cancelLoading }

enum ReferencePhase: Equatable, Sendable {
    case idle(Int)
    case loading(Int)
    case loaded(Int)
    case failed(request: Int, failure: Int)
}
struct ReferenceRoot: Equatable, Sendable {
    var phase: ReferencePhase
    var presentation: Int
    init(_ phase: ReferencePhase = .idle(1), presentation: Int = 0) {
        self.phase = phase
        self.presentation = presentation
    }
}
struct ReferenceStamp: Equatable, Sendable {
    let owner: UInt64
    let incarnation: UInt64
    let revision: UInt64
}
struct ReferenceSnapshot: Equatable, Sendable {
    let stamp: ReferenceStamp
    let root: ReferenceRoot
    let closed: Bool
}
enum ReferencePolicy: Equatable, Sendable {
    case latest, rejectWhenActive
    case parallel(Int)
}
struct ReferenceStart: Equatable, Sendable {
    let kind: Int
    let scope: ReferenceScope
    let dependencies: [ReferenceScope]
    let policy: ReferencePolicy
    let input: Int
    init(
        kind: Int = 0,
        scope: ReferenceScope = .load,
        dependencies: [ReferenceScope] = [.authentication],
        policy: ReferencePolicy = .latest,
        input: Int = 1
    ) {
        self.kind = kind
        self.scope = scope
        self.dependencies = dependencies
        self.policy = policy
        self.input = input
    }
}
struct ReferenceTicket: Equatable, Sendable {
    let owner: UInt64
    let incarnation: UInt64
    let operation: UInt64
    let start: ReferenceStart
    let activations: [ReferenceScope: UInt64]
}
struct ReferencePlan: Equatable, Sendable {
    var invalidates: [ReferenceScope]
    var starts: [ReferenceStart]
    var retires: [UInt64]
    var reset: Bool
    init(
        invalidates: [ReferenceScope] = [],
        starts: [ReferenceStart] = [],
        retires: [UInt64] = [],
        reset: Bool = false
    ) {
        self.invalidates = invalidates
        self.starts = starts
        self.retires = retires
        self.reset = reset
    }
}
struct ReferenceCandidate: Equatable, Sendable {
    let expected: ReferenceStamp
    let next: ReferenceRoot
    let requirements: [ReferenceTicket]
    let plan: ReferencePlan
}
enum ReferenceRejection: Error, Equatable, Sendable {
    case domain, invalidPhase, invalidPlan, planTooLarge
    case foreignOwner, closed, obsoleteIncarnation, inactiveAuthority, conflict
    case alreadyActive, parallelLimit, revisionExhausted, commitQueue, executionReservations
}
enum ReferenceAdmission: Equatable, Sendable {
    case committed(ReferenceSnapshot)
    case rejected(ReferenceRejection)
}
enum ReferenceOutcome: Equatable, Sendable {
    case success(Int)
    case failure(Int)
}
enum ReferenceDeliveryPolicy: Sendable { case manual, retry }
enum ReferencePendingStatus: Equatable, Sendable {
    case awaitingAdmission, preparing, waitingForCapacity, retryScheduled, reconciliationRequired
}
struct ReferenceConfiguration: Sendable {
    let queue: Int
    let descriptors: Int
    let reservations: Int
    let subscribers: Int
    let delivery: ReferenceDeliveryPolicy
    init(
        queue: Int = 256,
        descriptors: Int = 64,
        reservations: Int = 256,
        subscribers: Int = 128,
        delivery: ReferenceDeliveryPolicy = .manual
    ) {
        precondition(queue > 0 && descriptors > 0 && reservations > 0 && subscribers > 0)
        self.queue = queue
        self.descriptors = descriptors
        self.reservations = reservations
        self.subscribers = subscribers
        self.delivery = delivery
    }
}
struct ReferenceBatch: Equatable, Sendable {
    let snapshot: ReferenceSnapshot
    /// The revoked operations the batch cancels: all but retired work whose outcome was retained.
    let cancelled: [UInt64]
    let starts: [ReferenceTicket]
    let terminal: Bool
}
enum ReferenceExecution: Equatable, Sendable { case queued, running, terminated, skipped }
struct ReferenceReservation: Equatable, Sendable {
    let ticket: ReferenceTicket
    var execution: ReferenceExecution = .queued
    var deliverySettled = false
    var cancellationRequested = false
    var claims: [UInt64] = []
}
struct ReferencePending: Equatable, Sendable {
    let ticket: ReferenceTicket
    let outcome: ReferenceOutcome
    var status: ReferencePendingStatus = .awaitingAdmission
    var lastRejection: ReferenceRejection?
    var attempts: UInt64 = 0
    var attemptsSaturated = false
    var claim: UInt64?
    var candidate: ReferenceCandidate?
    /// Delivery turns that spent their whole preparation budget on conflicts.
    var conflictTurns = 0
}
struct ReferenceAttempt: Equatable, Sendable {
    let operation: UInt64
    let identity: UInt64
    let snapshot: ReferenceSnapshot
    let ticket: ReferenceTicket
    let outcome: ReferenceOutcome
}
enum ReferenceClaimResult: Equatable, Sendable {
    case claimed(ReferenceAttempt)
    case inProgress, notPending
}
enum ReferenceDelivery: Equatable, Sendable {
    case committed(ReferenceSnapshot)
    case pending(UInt64, ReferencePendingStatus)
    case inProgress, notPending
    case discarded(ReferenceRejection)
}
struct ReferenceSubscriber: Equatable, Sendable {
    var watermark: UInt64
    var mailbox: ReferenceSnapshot?
    var terminal: Bool
    var delivered: [ReferenceSnapshot] = []
}

/// IDs are abstract symbols within a history.
///
/// Callers assign distinct owner symbols;
/// local symbols are checked, never wrapped. This is a test oracle, not a sealed facade.
struct SequentialReference: Sendable {
    let owner: UInt64
    let configuration: ReferenceConfiguration
    private(set) var root: ReferenceRoot
    private(set) var incarnation: UInt64 = 1
    private(set) var revision: UInt64
    private(set) var closed = false
    private(set) var activations: [ReferenceScope: UInt64] = [.load: 2, .authentication: 3, .child: 4]
    private(set) var active: [ReferenceTicket] = []
    private(set) var reservations: [ReferenceReservation] = []
    private(set) var pending: [ReferencePending] = []
    private(set) var batches: [ReferenceBatch] = []
    private(set) var terminal: ReferenceBatch?
    private(set) var inFlight: ReferenceBatch?
    private(set) var processedThrough: UInt64 = 0
    private(set) var terminalProcessed = false
    private(set) var drainerScheduled = false
    private(set) var subscribers: [UInt64: ReferenceSubscriber] = [:]
    private(set) var runnerEvents: [String] = []
    private(set) var ready: [UInt64] = []
    private var symbol: UInt64 = 4

    init(
        owner: UInt64,
        root: ReferenceRoot = .init(),
        configuration: ReferenceConfiguration = .init(),
        revision: UInt64 = 0
    ) {
        precondition(revision < UInt64.max)
        self.owner = owner
        self.root = root
        self.configuration = configuration
        self.revision = revision
    }
    var snapshot: ReferenceSnapshot {
        .init(stamp: .init(owner: owner, incarnation: incarnation, revision: revision), root: root, closed: closed)
    }
    var isQuiescent: Bool {
        closed && terminalProcessed && reservations.isEmpty && pending.isEmpty
    }
    private mutating func fresh() -> UInt64 {
        precondition(symbol < UInt64.max, "Reference symbol space exhausted; never reuse identity")
        symbol += 1
        return symbol
    }
    func valid(_ ticket: ReferenceTicket) -> Bool {
        !closed && ticket.owner == owner && ticket.incarnation == incarnation && active.contains(ticket)
            && ticket.activations.allSatisfy { activations[$0.key] == $0.value }
    }
    func prepare(
        on observation: ReferenceSnapshot,
        next: ReferenceRoot,
        requirements: [ReferenceTicket] = [],
        plan: ReferencePlan = .init()
    )
        throws(ReferenceRejection) -> ReferenceCandidate
    {
        if plan.starts.count + plan.invalidates.count > configuration.descriptors
            || plan.starts.count > configuration.reservations
        {
            throw .planTooLarge
        }
        for (index, start) in plan.starts.enumerated() {
            if case .parallel(let limit) = start.policy, limit <= 0 { throw .invalidPlan }
            if start.scope == .load {
                guard case .loading = next.phase else { throw .invalidPlan }
            }
            for previous in plan.starts.prefix(index) where previous.scope == start.scope && previous.kind == start.kind
            {
                guard case .parallel = start.policy, previous.policy == start.policy else { throw .invalidPlan }
            }
        }
        return .init(expected: observation.stamp, next: next, requirements: requirements, plan: plan)
    }
    enum Input: Equatable, Sendable {
        case load(Int)
        case refresh(Int)
        case retry, cancel
        case presentation(Int)
        case authentication, removeReinsertChild
    }
    func prepare(
        _ input: Input,
        on observation: ReferenceSnapshot? = nil
    )
        throws(ReferenceRejection) -> ReferenceCandidate
    {
        let observed = observation ?? snapshot
        var next = observed.root
        var plan = ReferencePlan()
        switch (input, observed.root.phase) {
        case (.load(let request), .idle), (.refresh(let request), .loaded):
            guard request > 0 else { throw .domain }
            next.phase = .loading(request)
            plan = .init(invalidates: [.load], starts: [.init(input: request)])
        case (.retry, .failed(let request, _)):
            next.phase = .loading(request)
            plan = .init(invalidates: [.load], starts: [.init(input: request)])
        case (.cancel, .loading(let request)):
            next.phase = .idle(request)
            plan.invalidates = [.load]
        case (.presentation(let value), _): next.presentation = value
        case (.authentication, _): plan.invalidates = [.authentication]
        case (.removeReinsertChild, _): plan.invalidates = [.child]
        default: throw .invalidPhase
        }
        return try prepare(on: observed, next: next, plan: plan)
    }
    func prepareCompletion(
        _ ticket: ReferenceTicket,
        outcome: ReferenceOutcome,
        on observation: ReferenceSnapshot? = nil,
        successorStarts: [ReferenceStart] = []
    ) throws(ReferenceRejection) -> ReferenceCandidate {
        let observed = observation ?? snapshot
        guard case .loading(let request) = observed.root.phase else { throw .invalidPhase }
        var next = observed.root
        switch outcome {
        case .success(let value):
            guard value > 0 else { throw .domain }
            next.phase = .loaded(value)
        case .failure(let value): next.phase = .failed(request: request, failure: value)
        }
        return try prepare(
            on: observed,
            next: next,
            requirements: [ticket],
            plan: .init(starts: successorStarts, retires: [ticket.operation])
        )
    }
    func prepareReset(
        _ replacement: ReferenceRoot,
        starts: [ReferenceStart] = []
    )
        throws(ReferenceRejection) -> ReferenceCandidate
    {
        if case .loading = replacement.phase, starts.isEmpty { throw .domain }
        return try prepare(on: snapshot, next: replacement, plan: .init(starts: starts, reset: true))
    }

    mutating func commit(_ candidate: ReferenceCandidate, acknowledging claim: UInt64? = nil) -> ReferenceAdmission {
        if candidate.expected.owner != owner { return .rejected(.foreignOwner) }
        if closed { return .rejected(.closed) }
        if candidate.expected.incarnation != incarnation { return .rejected(.obsoleteIncarnation) }
        if candidate.requirements.contains(where: { !valid($0) }) { return .rejected(.inactiveAuthority) }
        if candidate.expected.revision != revision { return .rejected(.conflict) }
        var plan = candidate.plan
        if case .loading = root.phase {
            if case .loading = candidate.next.phase {
            } else if !plan.invalidates.contains(.load) {
                plan.invalidates.append(.load)
            }
        }
        var remaining = active.filter { ticket in
            !plan.reset && !plan.retires.contains(ticket.operation)
                && !plan.invalidates.contains(where: { ticket.activations[$0] != nil })
        }
        // Policy is evaluated against a prospective ledger; nothing below mutates live state on rejection.
        var prospectiveStarts: [ReferenceStart] = []
        for start in plan.starts {
            let oldGroup = remaining.filter { $0.start.scope == start.scope && $0.start.kind == start.kind }
            let newGroup = prospectiveStarts.filter { $0.scope == start.scope && $0.kind == start.kind }
            switch start.policy {
            case .latest: remaining.removeAll { $0.start.scope == start.scope && $0.start.kind == start.kind }
            case .rejectWhenActive:
                if !oldGroup.isEmpty || !newGroup.isEmpty { return .rejected(.alreadyActive) }
            case .parallel(let limit):
                if oldGroup.count + newGroup.count + 1 > limit { return .rejected(.parallelLimit) }
            }
            prospectiveStarts.append(start)
        }
        if revision == UInt64.max - 1 { return .rejected(.revisionExhausted) }
        if batches.count >= configuration.queue { return .rejected(.commitQueue) }
        let revoked = active.filter { !remaining.contains($0) }.map(\.operation)
        var nextReservations = reservations
        for index in nextReservations.indices {
            if revoked.contains(nextReservations[index].ticket.operation) {
                nextReservations[index].deliverySettled = true
            }
            if let claim { nextReservations[index].claims.removeAll { $0 == claim } }
        }
        nextReservations.removeAll { Self.releasable($0) }
        if nextReservations.count + plan.starts.count > configuration.reservations {
            return .rejected(.executionReservations)
        }
        if plan.reset { incarnation = fresh() }
        for scope in ReferenceScope.allCases where plan.reset || plan.invalidates.contains(scope) {
            activations[scope] = fresh()
        }
        var starts: [ReferenceTicket] = []
        for start in plan.starts {
            var required: [ReferenceScope: UInt64] = [:]
            for scope in [start.scope] + start.dependencies { required[scope] = activations[scope] }
            let ticket = ReferenceTicket(
                owner: owner,
                incarnation: incarnation,
                operation: fresh(),
                start: start,
                activations: required
            )
            starts.append(ticket)
            remaining.append(ticket)
            nextReservations.append(.init(ticket: ticket))
        }
        // Retiring work whose outcome is retained settles what it already returned, so the batch
        // cancels only the rest of the revoked work.
        let cancelled = revoked.filter { operation in
            !plan.retires.contains(operation) || !pending.contains { $0.ticket.operation == operation }
        }
        active = remaining
        reservations = nextReservations
        pending.removeAll { revoked.contains($0.ticket.operation) }
        ready.removeAll { revoked.contains($0) }
        root = candidate.next
        revision += 1
        batches.append(.init(snapshot: snapshot, cancelled: cancelled, starts: starts, terminal: false))
        drainerScheduled = true
        return .committed(snapshot)
    }
    private static func releasable(_ reservation: ReferenceReservation) -> Bool {
        (reservation.execution == .terminated || reservation.execution == .skipped) && reservation.deliverySettled
            && reservation.claims.isEmpty
    }
    private mutating func reap() { reservations.removeAll { Self.releasable($0) } }
    @discardableResult mutating func close() -> ReferenceSnapshot {
        if closed { return snapshot }
        let revoked = active.map(\.operation)
        closed = true
        revision += 1
        active.removeAll()
        pending.removeAll()
        ready.removeAll()
        for index in reservations.indices { reservations[index].deliverySettled = true }
        reap()
        terminal = .init(snapshot: snapshot, cancelled: revoked, starts: [], terminal: true)
        drainerScheduled = true
        return snapshot
    }
    static func restore(
        owner: UInt64,
        root: ReferenceRoot,
        configuration: ReferenceConfiguration = .init(),
        loading policy: ReferenceRestorationPolicy = .rejectLoading
    ) throws(ReferenceRejection) -> SequentialReference {
        var validated = root
        if case .loading(let request) = root.phase {
            guard policy == .cancelLoading else { throw .domain }
            validated.phase = .idle(request)
        }
        return .init(owner: owner, root: validated, configuration: configuration)
    }
    func fork(
        owner freshOwner: UInt64,
        loading policy: ReferenceRestorationPolicy = .rejectLoading
    ) throws(ReferenceRejection) -> SequentialReference {
        guard freshOwner != owner else { throw .domain }
        return try Self.restore(owner: freshOwner, root: root, configuration: configuration, loading: policy)
    }
    mutating func popBatch() -> ReferenceBatch? {
        guard inFlight == nil else { return nil }
        if !batches.isEmpty {
            inFlight = batches.removeFirst()
            return inFlight
        }
        if let batch = terminal {
            terminal = nil
            inFlight = batch
            return batch
        }
        drainerScheduled = false
        return nil
    }
    mutating func process(_ batch: ReferenceBatch) {
        guard inFlight == batch else { return }
        for operation in batch.cancelled {
            if let index = reservations.firstIndex(where: { $0.ticket.operation == operation }),
                reservations[index].execution == .running
            {
                reservations[index].cancellationRequested = true
                runnerEvents.append("cancel:\(operation)")
            }
        }
        runnerEvents.append("offer:\(batch.snapshot.stamp.revision)")
        for id in subscribers.keys.sorted() { offer(batch.snapshot, to: id, terminal: batch.terminal) }
        for ticket in batch.starts {
            guard let index = reservations.firstIndex(where: { $0.ticket == ticket }) else { continue }
            if valid(ticket) {
                reservations[index].execution = .running
                runnerEvents.append("start:\(ticket.operation)")
            } else {
                reservations[index].execution = .skipped
                runnerEvents.append("skip:\(ticket.operation)")
            }
        }
        processedThrough = max(processedThrough, batch.snapshot.stamp.revision)
        if batch.terminal { terminalProcessed = true }
        inFlight = nil
        reap()
    }
    @discardableResult mutating func drain(limit: Int = 32) -> [ReferenceBatch] {
        var result: [ReferenceBatch] = []
        for _ in 0 ..< max(0, limit) {
            guard let batch = popBatch() else { break }
            result.append(batch)
            process(batch)
        }
        return result
    }
    mutating func acknowledge(_ ticket: ReferenceTicket, skipped: Bool = false) {
        guard ticket.owner == owner, let index = reservations.firstIndex(where: { $0.ticket == ticket }) else { return }
        if skipped && reservations[index].execution == .running { return }
        reservations[index].execution = skipped ? .skipped : .terminated
        reap()
    }
    func flushed(through receipt: ReferenceSnapshot) -> Bool? {
        guard receipt.stamp.owner == owner else { return nil }
        return processedThrough >= receipt.stamp.revision
    }
    mutating func subscribe() -> UInt64? {
        guard closed || subscribers.values.filter({ !$0.terminal }).count < configuration.subscribers else {
            return nil
        }
        let id = fresh()
        subscribers[id] = .init(watermark: revision, mailbox: snapshot, terminal: closed)
        return id
    }
    private mutating func offer(_ value: ReferenceSnapshot, to id: UInt64, terminal: Bool) {
        guard var subscriber = subscribers[id], !subscriber.terminal else { return }
        guard value.stamp.revision > subscriber.watermark else { return }
        subscriber.watermark = value.stamp.revision
        subscriber.mailbox = value
        subscriber.terminal = terminal
        subscribers[id] = subscriber
    }
    mutating func consumeSubscriber(_ id: UInt64) -> ReferenceSnapshot? {
        guard var subscriber = subscribers[id], let value = subscriber.mailbox else { return nil }
        subscriber.mailbox = nil
        subscriber.delivered.append(value)
        subscribers[id] = subscriber
        return value
    }
    mutating func unsubscribe(_ id: UInt64) { subscribers.removeValue(forKey: id) }

    mutating func retain(_ ticket: ReferenceTicket, outcome: ReferenceOutcome) -> ReferenceDelivery {
        if let current = pending.first(where: { $0.ticket == ticket }) {
            return .pending(ticket.operation, current.status)
        }
        guard valid(ticket) else { return .discarded(closed ? .closed : .inactiveAuthority) }
        pending.append(.init(ticket: ticket, outcome: outcome))
        return .pending(ticket.operation, .awaitingAdmission)
    }
    mutating func beginAttempt(_ operation: UInt64) -> ReferenceClaimResult {
        guard let index = pending.firstIndex(where: { $0.ticket.operation == operation }) else { return .notPending }
        guard pending[index].claim == nil else { return .inProgress }
        let claim = fresh()
        pending[index].claim = claim
        pending[index].status = .preparing
        if pending[index].attempts == UInt64.max {
            pending[index].attemptsSaturated = true
        } else {
            pending[index].attempts += 1
        }
        if let reserved = reservations.firstIndex(where: { $0.ticket.operation == operation }) {
            reservations[reserved].claims.append(claim)
        }
        return .claimed(
            .init(
                operation: operation,
                identity: claim,
                snapshot: snapshot,
                ticket: pending[index].ticket,
                outcome: pending[index].outcome
            )
        )
    }
    private mutating func exitClaim(_ attempt: ReferenceAttempt) {
        for index in reservations.indices { reservations[index].claims.removeAll { $0 == attempt.identity } }
        if let index = pending.firstIndex(where: {
            $0.ticket.operation == attempt.operation && $0.claim == attempt.identity
        }) {
            pending[index].claim = nil
        }
        reap()
    }
    /// Finishes one claimed preparation.
    ///
    /// Only an `automatic` attempt, which a delivery or a scheduled turn makes, schedules another
    /// after losing a conflict under the retry policy. An explicit reconciliation that loses one
    /// leaves the outcome for another explicit decision.
    mutating func finishAttempt(
        _ attempt: ReferenceAttempt,
        preparation: Result<ReferenceCandidate, ReferenceRejection>,
        automatic: Bool = false
    ) -> ReferenceDelivery {
        guard
            let index = pending.firstIndex(where: {
                $0.ticket.operation == attempt.operation && $0.claim == attempt.identity
            })
        else {
            exitClaim(attempt)
            return .discarded(closed ? .closed : .inactiveAuthority)
        }
        switch preparation {
        case .failure(let reason):
            pending[index].status = .reconciliationRequired
            pending[index].lastRejection = reason
            exitClaim(attempt)
            return .pending(attempt.operation, .reconciliationRequired)
        case .success(let candidate):
            let result = commit(candidate, acknowledging: attempt.identity)
            exitClaim(attempt)
            return record(result, operation: attempt.operation, candidate: candidate, automatic: automatic)
        }
    }
    private mutating func record(
        _ result: ReferenceAdmission,
        operation: UInt64,
        candidate: ReferenceCandidate,
        automatic: Bool
    ) -> ReferenceDelivery {
        switch result {
        case .committed(let receipt): return .committed(receipt)
        case .rejected(let reason):
            guard let index = pending.firstIndex(where: { $0.ticket.operation == operation }) else {
                return .discarded(reason)
            }
            pending[index].lastRejection = reason
            switch reason {
            case .foreignOwner, .closed, .obsoleteIncarnation, .inactiveAuthority:
                pending.remove(at: index)
                if let reserved = reservations.firstIndex(where: { $0.ticket.operation == operation }) {
                    reservations[reserved].deliverySettled = true
                }
                reap()
                return .discarded(reason)
            case .commitQueue, .executionReservations:
                pending[index].candidate = candidate
                pending[index].status = .waitingForCapacity
            case .conflict:
                pending[index].candidate = nil
                let retries = automatic && configuration.delivery == .retry
                pending[index].status = retries ? .retryScheduled : .reconciliationRequired
                if retries && !ready.contains(operation) { ready.append(operation) }
            default:
                pending[index].candidate = nil
                pending[index].status = .reconciliationRequired
            }
            return .pending(operation, pending[index].status)
        }
    }
    mutating func reconcile(_ operation: UInt64) -> ReferenceDelivery {
        switch beginAttempt(operation) {
        case .inProgress: return .inProgress
        case .notPending: return .notPending
        case .claimed(let attempt):
            do {
                let candidate = try prepareCompletion(attempt.ticket, outcome: attempt.outcome, on: attempt.snapshot)
                return finishAttempt(attempt, preparation: .success(candidate))
            } catch { return finishAttempt(attempt, preparation: .failure(error)) }
        }
    }
    mutating func retryCapacity(_ operation: UInt64) -> ReferenceDelivery {
        guard let current = pending.first(where: { $0.ticket.operation == operation }),
            let candidate = current.candidate
        else { return .notPending }
        guard current.claim == nil else { return .inProgress }
        // A managed host retries capacity on its own, so a conflict it finds follows the automatic policy.
        return record(commit(candidate), operation: operation, candidate: candidate, automatic: true)
    }
    /// How many delivery turns, counting the first, one retained outcome may spend on conflicts.
    ///
    /// A turn that spends its whole budget on conflicts schedules another until this many have been
    /// spent. After the last, the outcome waits for explicit reconciliation.
    static let conflictTurnLimit = 16
    /// Explicit interference values describe commits between preparation and admission.
    ///
    /// No time, random source, effect, or mutable external dependency is reevaluated.
    mutating func deliveryTurn(_ operation: UInt64, interference: [Input] = []) -> ReferenceDelivery {
        let budget = configuration.delivery == .retry ? 4 : 1
        ready.removeAll { $0 == operation }
        var result = ReferenceDelivery.notPending
        for attemptIndex in 0 ..< budget {
            switch beginAttempt(operation) {
            case .inProgress: return .inProgress
            case .notPending: return .notPending
            case .claimed(let attempt):
                let preparation: Result<ReferenceCandidate, ReferenceRejection>
                do {
                    preparation = .success(
                        try prepareCompletion(attempt.ticket, outcome: attempt.outcome, on: attempt.snapshot)
                    )
                } catch { preparation = .failure(error) }
                if interference.indices.contains(attemptIndex), let edit = try? prepare(interference[attemptIndex]) {
                    _ = commit(edit)
                }
                result = finishAttempt(attempt, preparation: preparation, automatic: true)
                guard case .pending(_, .retryScheduled) = result else { return result }
            }
        }
        guard case .pending(_, .retryScheduled) = result,
            let index = pending.firstIndex(where: { $0.ticket.operation == operation })
        else { return result }
        pending[index].conflictTurns += 1
        guard pending[index].conflictTurns >= Self.conflictTurnLimit else { return result }
        pending[index].status = .reconciliationRequired
        ready.removeAll { $0 == operation }
        return .pending(operation, .reconciliationRequired)
    }
    /// One rotating ready round.
    ///
    /// The caller must represent an executor yield before a follow-up round.
    mutating func scheduledRound() -> [ReferenceDelivery] {
        let round = ready
        ready.removeAll()
        return round.map { deliveryTurn($0) }
    }
    mutating func discard(_ operation: UInt64) -> ReferenceDelivery {
        guard let current = pending.first(where: { $0.ticket.operation == operation }) else { return .notPending }
        do {
            let candidate = try prepare(
                on: snapshot,
                next: root,
                requirements: [current.ticket],
                plan: .init(retires: [operation])
            )
            switch commit(candidate) {
            case .committed(let receipt): return .committed(receipt)
            case .rejected(let reason): return .discarded(reason)
            }
        } catch { return .discarded(error) }
    }
}
