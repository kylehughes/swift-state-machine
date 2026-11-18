/// A retained identity for a lower-guarantee runtime.
///
/// It carries no facade authority.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public final class RuntimeIdentity: Sendable {
    /// Creates a fresh identity that cannot compare equal to an earlier retained marker.
    public init() {}
}

/// An engine-owned scope key.
///
/// Resolve domain instance keys before entering the runtime.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeScopeID: Equatable, Sendable {
    /// A generated primitive scope-kind tag.
    public let kind: UInt32
    /// A retained instance marker, or nil for a static scope.
    public let instance: RuntimeIdentity?
    /// Creates a raw key without granting any generated facade authority.
    public init(kind: UInt32, instance: RuntimeIdentity? = nil) {
        self.kind = kind
        self.instance = instance
    }
    /// Compares primitive tags and retained marker identity only.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.instance === rhs.instance
    }
}

/// Schema-declared active-authority admission policy.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public enum RuntimeOperationPolicy: Equatable, Sendable {
    /// Replaces active members of this scope activation and operation kind.
    case latest
    /// Rejects while another member is active.
    case rejectWhenActive
    /// Bounds active authority independently of physical execution reservations.
    case parallel(Int)
}

/// A primitive operation declaration for a generated plan.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeOperation: Sendable {
    /// The generated operation-kind tag.
    public let kind: UInt32
    /// The lifetime scope.
    public let scope: RuntimeScopeID
    /// Every additional semantic lifetime dependency.
    public let dependencies: [RuntimeScopeID]
    /// The declared group admission policy.
    public let policy: RuntimeOperationPolicy
    /// Creates operation metadata; preparation validates limits and referenced scopes.
    public init(
        kind: UInt32,
        scope: RuntimeScopeID,
        dependencies: [RuntimeScopeID] = [],
        policy: RuntimeOperationPolicy = .latest
    ) {
        self.kind = kind
        self.scope = scope
        self.dependencies = dependencies
        self.policy = policy
    }
}

/// Validated count bounds for an owner's admission, plans, and execution reservations.
///
/// A generated `Local` owner takes these directly; managed owners take them inside `ManagedConfiguration`.
nonisolated public struct Limits: Sendable {
    /// Ordinary queued batches.
    public let commits: Int
    /// Descriptors in one plan.
    public let descriptors: Int
    /// Outstanding execution and delivery reservations.
    public let executions: Int
    /// The documented positive capacities for an ordinary owner.
    public static let `default` = Limits(validatedCommits: 256, descriptors: 64, executions: 256)
    private init(validatedCommits: Int, descriptors: Int, executions: Int) {
        commits = validatedCommits
        self.descriptors = descriptors
        self.executions = executions
    }
    /// Validates positive capacities.
    public init(commits: Int = 256, descriptors: Int = 64, executions: Int = 256) throws(Failure) {
        guard commits > 0, descriptors > 0, executions > 0 else { throw .nonpositiveCapacity }
        self.commits = commits
        self.descriptors = descriptors
        self.executions = executions
    }
    /// Invalid raw configuration.
    public enum Failure: Error, Sendable { case nonpositiveCapacity }
}

/// A raw operation identity.
///
/// Generated facades must keep their tickets private.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeTicket: Equatable, Sendable {
    fileprivate struct Binding: Sendable {
        let scope: RuntimeScopeID
        let activation: RuntimeIdentity
    }
    fileprivate let owner: RuntimeIdentity
    fileprivate let incarnation: RuntimeIdentity
    fileprivate let operation: RuntimeIdentity
    fileprivate let kind: UInt32
    fileprivate let bindings: [Binding]
    /// Compares only retained owner, incarnation, and operation identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner === rhs.owner && lhs.incarnation === rhs.incarnation && lhs.operation === rhs.operation
    }
}

/// A sealed raw preparation attempt; facades retain it privately.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeDeliveryClaim: Equatable, Sendable {
    fileprivate let ticket: RuntimeTicket
    fileprivate let attempt: RuntimeIdentity
    func matches(_ other: Self) -> Bool { ticket == other.ticket && attempt === other.attempt }
    /// Compares the operation and its retained preparation identity.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.matches(rhs) }
}

/// A committed descriptor and its raw operation ticket.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeWork<Descriptor> {
    /// Pairs an inert descriptor with an existing raw ticket without granting facade authority.
    public init(descriptor: Descriptor, ticket: RuntimeTicket) {
        self.descriptor = descriptor
        self.ticket = ticket
    }
    /// The inert domain descriptor.
    public let descriptor: Descriptor
    /// The operation ticket issued by admission.
    public let ticket: RuntimeTicket
}

/// A reusable value engine with whole-root admission and bounded FIFO output.
///
/// This is a lower-guarantee kernel: it trusts schema eligibility, domain validation,
/// value semantics, and honest execution acknowledgments. It grants no authority in a
/// generated facade. Shared hosts install its complete immutable versions atomically;
/// Local and actor-confined hosts retain this value directly. Sendability is conditional
/// on the payloads; the shared installation primitive requires that conformance.
/// No method explicitly calls domain validation, reduction, or effect closures; payload
/// destruction may execute user code outside shared installation locks.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeState<Model, Descriptor> {
    fileprivate struct Scope: Sendable {
        let key: RuntimeScopeID
        let activation: RuntimeIdentity
    }
    /// A retained historical record and its raw validation context.
    public struct Snapshot {
        /// The historical immutable domain record.
        public let model: Model
        /// The owner-lifetime accepted revision.
        public let revision: UInt64
        /// Whether admission has permanently ended.
        public let isClosed: Bool
        fileprivate let owner: RuntimeIdentity
        fileprivate let incarnation: RuntimeIdentity
        fileprivate let revisionIdentity: RuntimeIdentity
        fileprivate let scopes: [Scope]
        fileprivate let limits: Limits
    }
    /// A scope lifecycle edit, including fresh activation after reinsertion.
    public enum ScopeEdit: Sendable {
        /// Installs a fresh activation, invalidating all earlier bindings to this key.
        case activate(RuntimeScopeID)
        /// Removes the current activation and invalidates its dependent authority.
        case remove(RuntimeScopeID)
    }
    /// A typed inert start description.
    public struct Start {
        /// The generated operation metadata.
        public let operation: RuntimeOperation
        /// The inert descriptor.
        public let descriptor: Descriptor
        /// Creates a description without starting work.
        public init(_ operation: RuntimeOperation, descriptor: Descriptor) {
            self.operation = operation
            self.descriptor = descriptor
        }
    }
    /// The complete authority changes and ordered starts of one candidate.
    public struct Plan {
        /// Scope changes in generated order.
        public let scopes: [ScopeEdit]
        /// Accepted-only terminal retirements.
        public let retire: [RuntimeTicket]
        /// Starts in authored order.
        public let starts: [Start]
        /// Whether to create a fresh owner incarnation.
        public let reset: Bool
        /// Explicit compact control descriptors, excluding implicit phase lifecycle edits.
        public let controlCount: Int
        /// The admitting preparation's completed attempt, acknowledged only on acceptance.
        public let finishingClaims: [RuntimeDeliveryClaim]
        /// Creates an inert plan; `prepare` validates it before a candidate exists.
        public init(
            scopes: [ScopeEdit] = [],
            retire: [RuntimeTicket] = [],
            starts: [Start] = [],
            reset: Bool = false,
            controlCount: Int = 0,
            finishingClaims: [RuntimeDeliveryClaim] = []
        ) {
            self.scopes = scopes
            self.retire = retire
            self.starts = starts
            self.reset = reset
            self.controlCount = controlCount
            self.finishingClaims = finishingClaims
        }
    }
    /// An immutable candidate; raw clients can prepare only against a captured snapshot.
    public struct Candidate {
        fileprivate let expected: Snapshot
        fileprivate let model: Model
        fileprivate let required: [RuntimeTicket]
        fileprivate let plan: Plan
        fileprivate let scopes: [Scope]
        fileprivate let incarnation: RuntimeIdentity
        // Delivery must retire its own terminal authority. The ledger owns the
        // attempt acknowledgment; an authored candidate cannot finish another claim.
        func validatedForDelivery(_ claim: RuntimeDeliveryClaim) -> Candidate? {
            guard required.contains(claim.ticket), plan.retire.contains(claim.ticket) else { return nil }
            return Candidate(
                expected: expected,
                model: model,
                required: required,
                plan: Plan(
                    scopes: plan.scopes,
                    retire: plan.retire,
                    starts: plan.starts,
                    reset: plan.reset,
                    controlCount: plan.controlCount,
                    finishingClaims: [claim]
                ),
                scopes: scopes,
                incarnation: incarnation
            )
        }
        func withoutFinishingClaims() -> Candidate {
            Candidate(
                expected: expected,
                model: model,
                required: required,
                plan: Plan(
                    scopes: plan.scopes,
                    retire: plan.retire,
                    starts: plan.starts,
                    reset: plan.reset,
                    controlCount: plan.controlCount
                ),
                scopes: scopes,
                incarnation: incarnation
            )
        }
    }
    /// Admission rejection reasons; `commit(_:)` reports them in declaration order.
    ///
    /// `commit(_:)` never reports `.plan`, because a defective plan never becomes a `Candidate`.
    /// ``reject(_:)`` reports it for a ``DefectivePlan`` after the provenance checks that precede it.
    public typealias Rejection = CommitRejection
    /// A plan defect that preparation found, kept with the snapshot the plan was prepared on.
    public struct DefectivePlan {
        /// The defect.
        public let reason: PlanRejection
        fileprivate let expected: Snapshot
        /// Records a defect found while preparing a plan against `expected`.
        public init(_ reason: PlanRejection, preparedOn expected: Snapshot) {
            self.reason = reason
            self.expected = expected
        }
        /// The rejection that admission reports for this plan while `current` is its owner's state.
        ///
        /// A snapshot from another owner and closure take precedence over the defect, so a plan whose
        /// defect only closure caused, because closing removes every scope, reports `.closed`.
        public func rejection(against current: Snapshot) -> Rejection {
            if expected.owner !== current.owner { return .foreignOwner }
            if current.isClosed { return .closed }
            return .plan(reason)
        }
    }
    /// A validated candidate, or the defect preparation found in its plan.
    @frozen public enum Proposal {
        /// A candidate that admission can install.
        case candidate(Candidate)
        /// A plan that admission reports through ``reject(_:)``.
        case defective(DefectivePlan)
    }
    /// Which accepted batches an owner queues for draining.
    public enum BatchRecording: Sendable {
        /// Every acceptance and the terminal batch, for an owner that publishes each acceptance
        /// from its queue.
        case everyAcceptance
        /// Only acceptances that cancel or start work, and the terminal batch, for a manual owner
        /// whose caller receives every other receipt from the commit itself.
        case commands
    }
    /// Historical acceptance or a rejection with coherent current observation.
    @frozen public enum Admission {
        /// All model, authority, reservation, and batch changes installed together.
        case committed(Snapshot)
        /// No proposed change was installed.
        case rejected(Rejection, current: Snapshot)
    }
    /// A committed typed command.
    @frozen public enum Command {
        /// Cancel this exact operation; execution remains reserved until acknowledged.
        case cancel(RuntimeTicket)
        /// Consider this start against live authority before physical registration.
        case start(RuntimeWork<Descriptor>)
    }
    /// A whole FIFO receipt and its commands.
    public struct Batch {
        /// The historical accepted record.
        public let snapshot: Snapshot
        /// Commands in deterministic cancellation-then-authored-start order.
        public let commands: [Command]
        /// Whether this uses the separately reserved lifecycle slot.
        public let terminal: Bool
    }
    /// Execution acknowledgment independent of result admission.
    @frozen public enum Acknowledgment: Equatable, Sendable {
        /// Actual termination was recorded.
        case recorded
        /// This obligation was already acknowledged or released.
        case duplicate
        /// This ticket belongs to a different owner.
        case foreignOwner
    }
    /// Historical operational bookkeeping; changing it does not revise the model.
    package struct ReservationSnapshot: Sendable {
        /// The exact raw operation identity.
        package let ticket: RuntimeTicket
        /// Known execution disposition.
        package let execution: ShutdownDiagnostics.ExecutionDisposition
        /// Retained delivery disposition.
        package let delivery: ShutdownDiagnostics.DeliveryDisposition
        /// Whether client preparation still owns an attempt claim.
        package let isPreparing: Bool
        /// The opaque identity of an executing preparation, when present.
        package let preparationClaim: RuntimeDeliveryClaim?
    }
    /// A first-envelope retention decision; payload ownership stays with the facade.
    package enum OutcomeRetention: Sendable {
        /// The caller may install its first typed envelope in the same transaction.
        case retained
        /// An envelope or settled disposition already exists; keep the first payload.
        case duplicate
        /// The operation cannot authorize a new retained result.
        case inactiveAuthority
        /// The ticket belongs to another raw owner.
        case foreignOwner
    }
    private struct Reservation: Sendable {
        let ticket: RuntimeTicket
        var execution: ShutdownDiagnostics.ExecutionDisposition = .queued
        var delivery: ShutdownDiagnostics.DeliveryDisposition = .awaitingOutcome
        var claim: RuntimeIdentity?
        var releasable: Bool {
            switch execution {
            case .queued, .issued: false
            case .terminated, .skipped:
                if case .settled = delivery { claim == nil } else { false }
            }
        }
    }
    private let owner = RuntimeIdentity()
    private var incarnation = RuntimeIdentity()
    private var revisionIdentity = RuntimeIdentity()
    private var revision: UInt64 = 0
    private var model: Model
    private var closed = false
    private let limits: Limits
    private var scopes: [Scope]
    private var active: [RuntimeTicket] = []
    private var reservations: [Reservation] = []
    private var queue: [Batch] = []
    private var terminal: Batch?
    private var closeSnapshot: Snapshot?
    private let recording: BatchRecording

    /// Creates independent raw ownership with fresh initial scope activations.
    ///
    /// With `.commands` recording, an acceptance that cancels and starts nothing queues no batch and
    /// takes no queue slot, so a run of such acceptances never waits for a drain.
    public init(
        _ model: Model,
        scopes: [RuntimeScopeID] = [],
        limits: Limits,
        recording: BatchRecording = .everyAcceptance
    ) {
        self.model = model
        self.limits = limits
        self.recording = recording
        var initial: [Scope] = []
        for key in scopes where !initial.contains(where: { $0.key == key }) {
            initial.append(Scope(key: key, activation: RuntimeIdentity()))
        }
        self.scopes = initial
    }

    /// The current immutable record and retained validation identities.
    public var snapshot: Snapshot {
        Snapshot(
            model: model,
            revision: revision,
            isClosed: closed,
            owner: owner,
            incarnation: incarnation,
            revisionIdentity: revisionIdentity,
            scopes: scopes,
            limits: limits
        )
    }
    /// Whether a historical observation belongs to this raw owner.
    public func owns(_ snapshot: Snapshot) -> Bool { snapshot.owner === owner }
    /// Whether ordinary or terminal FIFO output remains queued.
    public var hasQueuedBatches: Bool { !queue.isEmpty || terminal != nil }
    /// Whether closure, FIFO transfer, and all execution/delivery obligations have settled.
    public var isQuiescent: Bool { closed && !hasQueuedBatches && reservations.isEmpty }

    /// Validates a complete plan outside any shared installation lock, keeping a defect's provenance.
    public static func propose(
        on expected: Snapshot,
        next model: Model,
        requiring required: [RuntimeTicket] = [],
        plan: Plan = Plan()
    ) -> Proposal {
        do throws(PlanRejection) {
            return .candidate(try prepare(on: expected, next: model, requiring: required, plan: plan))
        } catch {
            return .defective(DefectivePlan(error, preparedOn: expected))
        }
    }

    /// Validates a complete plan outside any shared installation lock.
    public static func prepare(
        on expected: Snapshot,
        next model: Model,
        requiring required: [RuntimeTicket] = [],
        plan: Plan = Plan()
    ) throws(PlanRejection) -> Candidate {
        guard plan.controlCount >= 0 else { throw .invalidPlan }
        guard plan.starts.count <= expected.limits.descriptors,
            plan.controlCount <= expected.limits.descriptors - plan.starts.count,
            plan.starts.count <= expected.limits.executions
        else { throw .planTooLarge }
        let incarnation = plan.reset ? RuntimeIdentity() : expected.incarnation
        var scopes = expected.scopes
        if plan.reset { scopes = scopes.map { Scope(key: $0.key, activation: RuntimeIdentity()) } }
        var edited: [RuntimeScopeID] = []
        for edit in plan.scopes {
            let key: RuntimeScopeID
            switch edit {
            case .activate(let value), .remove(let value): key = value
            }
            guard !edited.contains(key) else { throw .invalidPlan }
            edited.append(key)
            scopes.removeAll { $0.key == key }
            if case .activate = edit { scopes.append(Scope(key: key, activation: RuntimeIdentity())) }
        }
        for (index, start) in plan.starts.enumerated() {
            guard scopes.contains(where: { $0.key == start.operation.scope }),
                start.operation.dependencies.allSatisfy({ key in scopes.contains { $0.key == key } })
            else { throw .invalidPlan }
            if case .parallel(let count) = start.operation.policy, count <= 0 { throw .invalidPlan }
            for previous in plan.starts.prefix(index)
            where previous.operation.scope == start.operation.scope && previous.operation.kind == start.operation.kind {
                guard case .parallel = start.operation.policy, previous.operation.policy == start.operation.policy
                else {
                    throw .invalidPlan
                }
            }
        }
        return Candidate(
            expected: expected,
            model: model,
            required: required,
            plan: plan,
            scopes: scopes,
            incarnation: incarnation
        )
    }

    /// Checks current operation authority independently of the starting root revision.
    public func isActive(_ ticket: RuntimeTicket) -> Bool {
        !closed && ticket.owner === owner && ticket.incarnation === incarnation
            && active.contains { $0.operation === ticket.operation }
            && Self.bindingsValid(ticket, scopes: scopes)
    }
    private static func bindingsValid(_ ticket: RuntimeTicket, scopes: [Scope]) -> Bool {
        ticket.bindings.allSatisfy { binding in
            scopes.contains { $0.key == binding.scope && $0.activation === binding.activation }
        }
    }
    private func reject(_ reason: Rejection) -> Admission { .rejected(reason, current: snapshot) }

    /// Reports a defective plan with ordinary admission precedence and installs nothing.
    public func reject(_ defect: DefectivePlan) -> Admission { reject(defect.rejection(against: snapshot)) }

    /// Preflights every store and installs the complete accepted successor.
    public mutating func commit(_ candidate: Candidate) -> Admission {
        if candidate.expected.owner !== owner { return reject(.foreignOwner) }
        if closed { return reject(.closed) }
        if candidate.expected.incarnation !== incarnation { return reject(.obsoleteIncarnation) }
        if !candidate.required.allSatisfy({ isActive($0) }) { return reject(.inactiveAuthority) }
        if !candidate.plan.finishingClaims.allSatisfy({ claim in
            reservations.contains { $0.ticket == claim.ticket && $0.claim === claim.attempt }
        }) {
            return reject(.inactiveAuthority)
        }
        if candidate.expected.revisionIdentity !== revisionIdentity { return reject(.conflict) }
        let plan = candidate.plan
        var remaining = active.filter { ticket in
            !plan.reset && Self.bindingsValid(ticket, scopes: candidate.scopes)
                && !plan.retire.contains { $0.operation === ticket.operation }
        }
        var works: [RuntimeWork<Descriptor>] = []
        for start in plan.starts {
            // Preparation established every binding; generated tables use primitive keys only.
            let scope = candidate.scopes.first { $0.key == start.operation.scope }!
            let group = remaining.filter {
                $0.kind == start.operation.kind && $0.bindings.first?.activation === scope.activation
            }
            switch start.operation.policy {
            case .latest:
                remaining.removeAll { ticket in group.contains { $0.operation === ticket.operation } }
            case .rejectWhenActive:
                if !group.isEmpty { return reject(.operationPolicy(.alreadyActive)) }
            case .parallel(let limit):
                if group.count >= limit { return reject(.operationPolicy(.parallelLimit)) }
            }
            var bindings = [RuntimeTicket.Binding(scope: scope.key, activation: scope.activation)]
            for key in start.operation.dependencies {
                let dependency = candidate.scopes.first { $0.key == key }!
                bindings.append(.init(scope: key, activation: dependency.activation))
            }
            let ticket = RuntimeTicket(
                owner: owner,
                incarnation: candidate.incarnation,
                operation: RuntimeIdentity(),
                kind: start.operation.kind,
                bindings: bindings
            )
            remaining.append(ticket)
            works.append(RuntimeWork(descriptor: start.descriptor, ticket: ticket))
        }
        if revision == UInt64.max - 1 { return reject(.revisionExhausted) }
        let revoked = active.filter { ticket in !remaining.contains { $0.operation === ticket.operation } }
        // A commandless acceptance under `.commands` recording queues nothing, so it needs no slot.
        let queues = recording == .everyAcceptance || !revoked.isEmpty || !works.isEmpty
        if queues, queue.count >= limits.commits { return reject(.capacityExceeded(.commitQueue)) }
        var prospective = reservations
        for index in prospective.indices
        where revoked.contains(where: { $0.operation === prospective[index].ticket.operation }) {
            prospective[index].delivery = .settled
        }
        for claim in plan.finishingClaims {
            if let index = prospective.firstIndex(where: { $0.ticket == claim.ticket && $0.claim === claim.attempt }) {
                prospective[index].claim = nil
            }
        }
        prospective.removeAll { $0.releasable }
        if works.count > limits.executions - prospective.count {
            return reject(.capacityExceeded(.executionReservations))
        }
        prospective.append(contentsOf: works.map { Reservation(ticket: $0.ticket) })
        model = candidate.model
        scopes = candidate.scopes
        incarnation = candidate.incarnation
        active = remaining
        reservations = prospective
        revision += 1
        revisionIdentity = RuntimeIdentity()
        let accepted = snapshot
        if queues {
            queue.append(
                Batch(
                    snapshot: accepted,
                    commands: revoked.map { .cancel($0) } + works.map { .start($0) },
                    terminal: false
                )
            )
        }
        return .committed(accepted)
    }

    /// Idempotently closes with the reserved final revision and independent queue slot.
    public mutating func close() -> Snapshot {
        if let closeSnapshot { return closeSnapshot }
        let cancelled = active
        for index in reservations.indices { reservations[index].delivery = .settled }
        reservations.removeAll { $0.releasable }
        active = []
        scopes = []
        closed = true
        revision += 1
        revisionIdentity = RuntimeIdentity()
        let final = snapshot
        closeSnapshot = final
        terminal = Batch(snapshot: final, commands: cancelled.map { .cancel($0) }, terminal: true)
        return final
    }

    /// Transfers whole FIFO batches, acknowledging revoked queued starts as skipped.
    public mutating func drain(limit: Int) -> [Batch] {
        guard limit > 0 else { return [] }
        var result: [Batch] = []
        while result.count < limit {
            let batch: Batch
            if !queue.isEmpty {
                batch = queue.removeFirst()
            } else if let final = terminal {
                batch = final
                terminal = nil
            } else {
                break
            }
            var commands: [Command] = []
            for command in batch.commands {
                if case .start(let work) = command, !isActive(work.ticket) {
                    if let index = reservations.firstIndex(where: { $0.ticket.operation === work.ticket.operation }) {
                        reservations[index].execution = .skipped
                        reservations[index].delivery = .settled
                    }
                } else {
                    if case .start(let work) = command,
                        let index = reservations.firstIndex(where: { $0.ticket == work.ticket })
                    {
                        reservations[index].execution = .issued
                    }
                    commands.append(command)
                }
            }
            reservations.removeAll { $0.releasable }
            result.append(Batch(snapshot: batch.snapshot, commands: commands, terminal: batch.terminal))
        }
        return result
    }

    /// Returns immutable reservation diagnostics without granting mutation authority.
    package var executionReservations: [ReservationSnapshot] {
        reservations.map { reservation in
            ReservationSnapshot(
                ticket: reservation.ticket,
                execution: reservation.execution,
                delivery: reservation.delivery,
                isPreparing: reservation.claim != nil,
                preparationClaim: reservation.claim.map {
                    RuntimeDeliveryClaim(ticket: reservation.ticket, attempt: $0)
                }
            )
        }
    }

    /// Claims first-envelope retention.
    ///
    /// Install the typed envelope in the same host transaction.
    package mutating func retainOutcome(for ticket: RuntimeTicket) -> OutcomeRetention {
        guard ticket.owner === owner else { return .foreignOwner }
        guard isActive(ticket), let index = reservations.firstIndex(where: { $0.ticket == ticket }) else {
            return .inactiveAuthority
        }
        guard reservations[index].delivery == .awaitingOutcome else { return .duplicate }
        reservations[index].delivery = .pending
        return .retained
    }

    /// Claims one pending-envelope preparation attempt without evaluating user code.
    package mutating func claimDelivery(for ticket: RuntimeTicket) -> RuntimeDeliveryClaim? {
        guard isActive(ticket), let index = reservations.firstIndex(where: { $0.ticket == ticket }),
            reservations[index].delivery == .pending, reservations[index].claim == nil
        else { return nil }
        let attempt = RuntimeIdentity()
        reservations[index].claim = attempt
        return RuntimeDeliveryClaim(ticket: ticket, attempt: attempt)
    }

    /// Acknowledges an attempt's exit even after invalidation or close disposed its envelope.
    package mutating func finishDeliveryClaim(_ claim: RuntimeDeliveryClaim) {
        guard let index = reservations.firstIndex(where: { $0.ticket == claim.ticket && $0.claim === claim.attempt })
        else {
            return
        }
        reservations[index].claim = nil
        reservations.removeAll { $0.releasable }
    }

    /// Records physical termination without pretending its outcome was admitted.
    public mutating func acknowledge(_ ticket: RuntimeTicket, skippedBeforeStart: Bool = false) -> Acknowledgment {
        guard ticket.owner === owner else { return .foreignOwner }
        guard let index = reservations.firstIndex(where: { $0.ticket.operation === ticket.operation }),
            reservations[index].execution != .terminated, reservations[index].execution != .skipped
        else { return .duplicate }
        reservations[index].execution = skippedBeforeStart ? .skipped : .terminated
        reservations.removeAll { $0.releasable }
        return .recorded
    }
}

extension RuntimeWork: Sendable where Descriptor: Sendable {}
extension RuntimeState: Sendable where Model: Sendable, Descriptor: Sendable {}
extension RuntimeState.Snapshot: Sendable where Model: Sendable {}
extension RuntimeState.Start: Sendable where Descriptor: Sendable {}
extension RuntimeState.Plan: Sendable where Descriptor: Sendable {}
extension RuntimeState.Candidate: Sendable where Model: Sendable, Descriptor: Sendable {}
extension RuntimeState.Admission: Sendable where Model: Sendable {}
extension RuntimeState.DefectivePlan: Sendable where Model: Sendable {}
extension RuntimeState.Proposal: Sendable where Model: Sendable, Descriptor: Sendable {}
extension RuntimeState.Command: Sendable where Descriptor: Sendable {}
extension RuntimeState.Batch: Sendable where Model: Sendable, Descriptor: Sendable {}
