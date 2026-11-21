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

/// A domain instance key that names one keyed operation's work, such as an item identifier.
///
/// Preparation hashes and compares keys against an observation's key table, outside every lock, and
/// resolves each to a retained engine identity. Admission then compares identities only. A key that
/// no active work holds leaves the table, so inserting it again resolves to a fresh identity.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeKey: Sendable {
    private let value: any Hashable & Sendable
    private let hash: Int
    /// Captures a key and its hash value.
    public init<Key: Hashable & Sendable>(_ key: Key) {
        value = key
        hash = key.hashValue
    }
    /// Whether two keys are equal, comparing their hash values first.
    func matches(_ other: RuntimeKey) -> Bool {
        hash == other.hash && Self.equal(value, other.value)
    }
    private static func equal<Value: Hashable & Sendable>(_ value: Value, _ other: any Hashable & Sendable) -> Bool {
        (other as? Value) == value
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
    /// The resolved identity of a keyed operation's key, or `nil` for an unkeyed operation.
    fileprivate let key: RuntimeIdentity?
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
    /// One key that active work of a keyed operation holds, and the identity it resolves to.
    fileprivate struct KeyEntry: Sendable {
        let kind: UInt32
        let key: RuntimeKey
        let identity: RuntimeIdentity
    }
    /// A retained historical record and its raw validation context.
    public struct Snapshot {
        /// The historical immutable domain record.
        public let model: Model
        /// The owner-lifetime accepted revision.
        public let revision: UInt64
        /// Whether admission has permanently ended.
        public let isClosed: Bool
        /// The identifier of the graph edge whose acceptance produced this root, or `nil` for the
        /// initial root, a reset, closure, or a change that takes no declared edge.
        public let edge: String?
        fileprivate let owner: RuntimeIdentity
        fileprivate let incarnation: RuntimeIdentity
        fileprivate let revisionIdentity: RuntimeIdentity
        fileprivate let scopes: [Scope]
        fileprivate let keys: [KeyEntry]
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
        /// The instance key of a keyed operation, which admission applies its policy to.
        public let key: RuntimeKey?
        /// Creates a description without starting work.
        public init(_ operation: RuntimeOperation, descriptor: Descriptor, key: RuntimeKey? = nil) {
            self.operation = operation
            self.descriptor = descriptor
            self.key = key
        }
    }
    /// A request to revoke a keyed operation's work: one key's, or with no key, all of it.
    public struct Cancellation: Sendable {
        /// The generated operation-kind tag.
        public let kind: UInt32
        /// The key whose work to revoke, or `nil` to revoke every key's.
        public let key: RuntimeKey?
        /// Describes a cancellation; a key that no active work holds cancels nothing.
        public init(kind: UInt32, key: RuntimeKey?) {
            self.kind = kind
            self.key = key
        }
    }
    /// A cancellation whose key preparation resolved to the identity active work holds.
    fileprivate struct ResolvedCancellation: Sendable {
        let kind: UInt32
        /// The resolved key identity, or `nil` for every key of the kind.
        let key: RuntimeIdentity?
        func revokes(_ ticket: RuntimeTicket) -> Bool {
            ticket.kind == kind && (key == nil || ticket.key === key)
        }
    }
    /// A typed inert emission, published in its acceptance's batch and never executed.
    public struct Emission {
        /// The inert descriptor.
        public let descriptor: Descriptor
        /// How many of the plan's starts precede it in authored order.
        public let position: Int
        /// Creates an emission that follows the first `position` starts of its plan.
        public init(_ descriptor: Descriptor, position: Int) {
            self.descriptor = descriptor
            self.position = position
        }
    }
    /// The complete authority changes, ordered starts, and ordered emissions of one candidate.
    public struct Plan {
        /// Scope changes in generated order.
        public let scopes: [ScopeEdit]
        /// Accepted-only terminal retirements.
        ///
        /// Retiring an operation whose outcome is retained settles the result its work already
        /// returned, so the batch queues no cancellation for that ticket. Retiring an operation with no
        /// retained outcome revokes work that may still be running, and the batch cancels it. Only the
        /// ticket a plan retires is spared: work the same plan revokes otherwise, and every ticket a
        /// reset or closure revokes, is cancelled whether or not its outcome is retained.
        public let retire: [RuntimeTicket]
        /// Keyed revocations, applied before the starts.
        public let cancellations: [Cancellation]
        /// Starts in authored order.
        public let starts: [Start]
        /// Emissions in authored order, each placed among the starts by its position.
        public let emissions: [Emission]
        /// Whether to create a fresh owner incarnation.
        public let reset: Bool
        /// Explicit compact control descriptors, excluding implicit phase lifecycle edits.
        public let controlCount: Int
        /// The admitting preparation's completed attempt, acknowledged only on acceptance.
        public let finishingClaims: [RuntimeDeliveryClaim]
        /// The identifier of the graph edge that produced the plan, which the accepted snapshot records,
        /// or `nil` for a change that takes no declared edge.
        public let edge: String?
        /// Creates an inert plan; `prepare` validates it before a candidate exists.
        public init(
            scopes: [ScopeEdit] = [],
            retire: [RuntimeTicket] = [],
            cancellations: [Cancellation] = [],
            starts: [Start] = [],
            emissions: [Emission] = [],
            reset: Bool = false,
            controlCount: Int = 0,
            finishingClaims: [RuntimeDeliveryClaim] = [],
            edge: String? = nil
        ) {
            self.edge = edge
            self.scopes = scopes
            self.retire = retire
            self.cancellations = cancellations
            self.starts = starts
            self.emissions = emissions
            self.reset = reset
            self.controlCount = controlCount
            self.finishingClaims = finishingClaims
        }
        fileprivate func finishing(_ claims: [RuntimeDeliveryClaim]) -> Plan {
            Plan(
                scopes: scopes,
                retire: retire,
                cancellations: cancellations,
                starts: starts,
                emissions: emissions,
                reset: reset,
                controlCount: controlCount,
                finishingClaims: claims,
                edge: edge
            )
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
        /// The key table after preparation resolved the plan's keys against the expected one.
        fileprivate let keys: [KeyEntry]
        /// The resolved key identity of each start, in the plan's order.
        fileprivate let startKeys: [RuntimeIdentity?]
        /// The cancellations whose keys active work held when the plan was prepared.
        fileprivate let cancellations: [ResolvedCancellation]
        fileprivate func with(_ plan: Plan) -> Candidate {
            Candidate(
                expected: expected,
                model: model,
                required: required,
                plan: plan,
                scopes: scopes,
                incarnation: incarnation,
                keys: keys,
                startKeys: startKeys,
                cancellations: cancellations
            )
        }
        // Delivery must retire its own terminal authority. The ledger owns the
        // attempt acknowledgment; an authored candidate cannot finish another claim.
        func validatedForDelivery(_ claim: RuntimeDeliveryClaim) -> Candidate? {
            guard required.contains(claim.ticket), plan.retire.contains(claim.ticket) else { return nil }
            return with(plan.finishing([claim]))
        }
        func withoutFinishingClaims() -> Candidate { with(plan.finishing([])) }
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
        /// Only acceptances that cancel or start work or emit, and the terminal batch, for a manual
        /// owner whose caller receives every other receipt from the commit itself.
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
        /// Publish this inert emission; it carries no authority and starts nothing.
        case emit(Descriptor)
    }
    /// A whole FIFO receipt and its commands.
    public struct Batch {
        /// The historical accepted record.
        public let snapshot: Snapshot
        /// Cancellations, then starts and emissions in authored order.
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
        /// Known execution state.
        package let execution: ShutdownDiagnostics.ExecutionState
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
        var execution: ShutdownDiagnostics.ExecutionState = .queued
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
    /// The graph edge of the acceptance that produced the current root.
    private var edge: String?
    private var model: Model
    private var closed = false
    private let limits: Limits
    private var scopes: [Scope] { didSet { activations = Set(scopes.map(SeenActivation.init)) } }
    // The identities of `scopes`' activations, so checking a ticket's bindings looks each one up once.
    private var activations: Set<SeenActivation> = []
    private var keys: [KeyEntry] = []
    private var active: [RuntimeTicket] = [] {
        didSet { operations = Set(active.map { ObjectIdentifier($0.operation) }) }
    }
    // The identities of `active`'s operations, so checking a ticket's activity looks it up once.
    private var operations: Set<ObjectIdentifier> = []
    private var reservations: [Reservation] = []
    private var queue = RuntimeFIFO<Batch>()
    // Batches a drainer detached from `queue` and has not yet taken, which still hold their slots.
    private var detached = 0
    private var terminal: Batch?
    private var closeSnapshot: Snapshot?
    /// How many queued batches draining has moved within the queue's storage, which tests read as its
    /// work.
    package var queueMoves: Int { queue.moved }
    private let recording: BatchRecording

    /// Creates independent raw ownership with fresh initial scope activations.
    ///
    /// With `.commands` recording, an acceptance that cancels, starts, and emits nothing queues no
    /// batch and takes no queue slot, so a run of such acceptances never waits for a drain.
    public init(
        _ model: Model,
        scopes: [RuntimeScopeID] = [],
        limits: Limits,
        recording: BatchRecording = .everyAcceptance
    ) {
        self.model = model
        self.limits = limits
        self.recording = recording
        var examined = 0
        let distinct = Self.distinctScopeKeys(scopes, examined: &examined)
            .map {
                Scope(key: $0, activation: RuntimeIdentity())
            }
        self.scopes = distinct
        activations = Set(distinct.map(SeenActivation.init))
    }

    /// The scope keys of `keys` in order, each once, as its first occurrence places it.
    ///
    /// It examines each key once against the keys already kept, through a set of their primitive
    /// identities, so activating many scopes costs work linear in their number; `examined` counts the
    /// examinations, which tests read as that work.
    package static func distinctScopeKeys(_ keys: [RuntimeScopeID], examined: inout Int) -> [RuntimeScopeID] {
        var seen = Set<SeenScope>()
        var distinct: [RuntimeScopeID] = []
        for key in keys {
            examined += 1
            if seen.insert(SeenScope(key)).inserted { distinct.append(key) }
        }
        return distinct
    }
    /// The elements of `elements`, each with a scope key, after `edits`, or `nil` when an edit names a
    /// key that another edit of the same plan names.
    ///
    /// Each edit removes the element of its key, and an activation then adds a fresh one, so the result
    /// keeps the unedited elements in order, followed by the activated ones in the order of their
    /// edits. It takes one pass over the edits and one over the elements, through a set of primitive
    /// key identities, so a transition into a phase with many scopes costs work linear in their number;
    /// `examined` counts the elements and edits examined, which tests read as that work.
    package static func applying<Element>(
        _ edits: [ScopeEdit],
        to elements: [Element],
        key: (Element) -> RuntimeScopeID,
        activating activate: (RuntimeScopeID) -> Element,
        examined: inout Int
    ) -> [Element]? {
        var edited = Set<SeenScope>()
        var activated: [Element] = []
        for edit in edits {
            examined += 1
            switch edit {
            case .activate(let value):
                guard edited.insert(SeenScope(value)).inserted else { return nil }
                activated.append(activate(value))
            case .remove(let value):
                guard edited.insert(SeenScope(value)).inserted else { return nil }
            }
        }
        guard !edited.isEmpty else { return elements }
        var result: [Element] = []
        for element in elements {
            examined += 1
            if !edited.contains(SeenScope(key(element))) { result.append(element) }
        }
        return result + activated
    }
    /// A scope key's primitive identity: its kind and the identity of its instance marker, which the
    /// key retains while it is compared.
    private struct SeenScope: Hashable {
        let kind: UInt32
        let instance: ObjectIdentifier?
        init(_ key: RuntimeScopeID) {
            kind = key.kind
            instance = key.instance.map(ObjectIdentifier.init)
        }
    }
    /// The operation, scope, and resolved key that the starts of one parallel group share, in a plan or
    /// among the active operations of one scope activation.
    private struct StartGroup: Hashable {
        let scope: SeenScope
        let kind: UInt32
        let key: ObjectIdentifier?
        init(_ scope: RuntimeScopeID, kind: UInt32, key: RuntimeIdentity?) {
            self.scope = SeenScope(scope)
            self.kind = kind
            self.key = key.map(ObjectIdentifier.init)
        }
    }
    /// The operation, scope activation, and key identity that determine one admission group.
    private struct ActiveGroup: Hashable {
        let kind: UInt32
        let activation: ObjectIdentifier?
        let key: ObjectIdentifier?
        init(kind: UInt32, activation: RuntimeIdentity?, key: RuntimeIdentity?) {
            self.kind = kind
            self.activation = activation.map(ObjectIdentifier.init)
            self.key = key.map(ObjectIdentifier.init)
        }
        init(_ ticket: RuntimeTicket) {
            self.init(kind: ticket.kind, activation: ticket.bindings.first?.activation, key: ticket.key)
        }
    }
    /// A scope activation's primitive identity: its key's, and the identity of the activation.
    private struct SeenActivation: Hashable {
        let scope: SeenScope
        let activation: ObjectIdentifier
        init(_ scope: Scope) {
            self.scope = SeenScope(scope.key)
            activation = ObjectIdentifier(scope.activation)
        }
        init(_ binding: RuntimeTicket.Binding) {
            scope = SeenScope(binding.scope)
            activation = ObjectIdentifier(binding.activation)
        }
    }

    /// The current immutable record and retained validation identities.
    public var snapshot: Snapshot {
        Snapshot(
            model: model,
            revision: revision,
            isClosed: closed,
            edge: edge,
            owner: owner,
            incarnation: incarnation,
            revisionIdentity: revisionIdentity,
            scopes: scopes,
            keys: keys,
            limits: limits
        )
    }
    /// Whether a historical observation belongs to this raw owner.
    public func owns(_ snapshot: Snapshot) -> Bool { snapshot.owner === owner }
    /// Whether ordinary or terminal FIFO output remains queued.
    public var hasQueuedBatches: Bool { !queue.isEmpty || detached > 0 || terminal != nil }
    /// How many whole batches a drain would transfer, including the terminal batch.
    public var queuedBatchCount: Int { queue.count + detached + (terminal == nil ? 0 : 1) }
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
        guard plan.controlCount >= 0,
            plan.emissions.enumerated()
                .allSatisfy({ index, emission in
                    emission.position >= 0 && emission.position <= plan.starts.count
                        && (index == 0 || plan.emissions[index - 1].position <= emission.position)
                })
        else { throw .invalidPlan }
        let descriptors = plan.starts.count + plan.emissions.count
        // Each cancellation is one compact control descriptor, like an explicit invalidation.
        guard descriptors <= expected.limits.descriptors,
            plan.controlCount <= expected.limits.descriptors - descriptors - plan.cancellations.count,
            plan.starts.count <= expected.limits.executions
        else { throw .planTooLarge }
        let incarnation = plan.reset ? RuntimeIdentity() : expected.incarnation
        var scopes = expected.scopes
        if plan.reset { scopes = scopes.map { Scope(key: $0.key, activation: RuntimeIdentity()) } }
        var examined = 0
        guard
            let edited = Self.applying(
                plan.scopes,
                to: scopes,
                key: \.key,
                activating: { Scope(key: $0, activation: RuntimeIdentity()) },
                examined: &examined
            )
        else { throw .invalidPlan }
        scopes = edited
        // Keys are hashed and compared here, outside every lock, against the observed key table.
        // Cancellations resolve first, so a key cancelled and started in one plan gets a fresh identity.
        var keys = plan.reset ? [] : expected.keys
        var cancellations: [ResolvedCancellation] = []
        for cancellation in plan.cancellations {
            guard let key = cancellation.key else {
                cancellations.append(ResolvedCancellation(kind: cancellation.kind, key: nil))
                keys.removeAll { $0.kind == cancellation.kind }
                continue
            }
            guard let index = keys.firstIndex(where: { $0.kind == cancellation.kind && $0.key.matches(key) }) else {
                continue
            }
            cancellations.append(ResolvedCancellation(kind: cancellation.kind, key: keys[index].identity))
            keys.remove(at: index)
        }
        var startKeys: [RuntimeIdentity?] = []
        for start in plan.starts {
            guard let key = start.key else {
                startKeys.append(nil)
                continue
            }
            if let entry = keys.first(where: { $0.kind == start.operation.kind && $0.key.matches(key) }) {
                startKeys.append(entry.identity)
            } else {
                let entry = KeyEntry(kind: start.operation.kind, key: key, identity: RuntimeIdentity())
                keys.append(entry)
                startKeys.append(entry.identity)
            }
        }
        // Each start joins the group of the plan's earlier starts of its operation and key, counted in one
        // table, so a wide plan examines each start once.
        let held = Set(scopes.map { SeenScope($0.key) })
        var groups: [StartGroup: (policy: RuntimeOperationPolicy, count: Int)] = [:]
        var work = scopes.count
        defer { EngineWork.report(work) }
        for (index, start) in plan.starts.enumerated() {
            work += 1 + start.operation.dependencies.count
            guard held.contains(SeenScope(start.operation.scope)),
                start.operation.dependencies.allSatisfy({ held.contains(SeenScope($0)) })
            else { throw .invalidPlan }
            if case .parallel(let count) = start.operation.policy, count <= 0 { throw .invalidPlan }
            let key = StartGroup(start.operation.scope, kind: start.operation.kind, key: startKeys[index])
            var group = 1
            if let earlier = groups[key] {
                guard case .parallel = start.operation.policy, earlier.policy == start.operation.policy else {
                    throw .invalidPlan
                }
                group = earlier.count + 1
            }
            groups[key] = (start.operation.policy, group)
            // A keyed operation's policy applies per key, so one key's starts in a plan stay within its limit.
            if start.key != nil, case .parallel(let limit) = start.operation.policy, group > limit {
                throw .invalidPlan
            }
        }
        return Candidate(
            expected: expected,
            model: model,
            required: required,
            plan: plan,
            scopes: scopes,
            incarnation: incarnation,
            keys: keys,
            startKeys: startKeys,
            cancellations: cancellations
        )
    }

    /// The identity that active work of the operation kind `kind` holds for `key`, or `nil` when none does.
    package func keyIdentity(kind: UInt32, key: RuntimeKey) -> RuntimeIdentity? {
        keys.first { $0.kind == kind && $0.key.matches(key) }?.identity
    }

    /// Checks current operation authority independently of the starting root revision.
    public func isActive(_ ticket: RuntimeTicket) -> Bool {
        !closed && ticket.owner === owner && ticket.incarnation === incarnation
            && operations.contains(ObjectIdentifier(ticket.operation))
            && ticket.bindings.allSatisfy { activations.contains(SeenActivation($0)) }
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
        // Identity sets of the candidate's scope activations, and below of the surviving operations and
        // keys, keep an edit that leaves many operations active linear in their number; the arrays keep
        // their order, which commands follow.
        let activations = Set(candidate.scopes.map(SeenActivation.init))
        var work = candidate.scopes.count + active.count
        defer { EngineWork.report(work) }
        let retiring = Set(plan.retire.map { ObjectIdentifier($0.operation) })
        var remaining = active.filter { ticket in
            !plan.reset && ticket.bindings.allSatisfy { activations.contains(SeenActivation($0)) }
                && !retiring.contains(ObjectIdentifier(ticket.operation))
                && !candidate.cancellations.contains { $0.revokes(ticket) }
        }
        // The surviving operations of each group, and the plan's starts as they join it, are kept in one
        // table, so a wide plan examines each start and each surviving operation once.
        var groups: [ActiveGroup: [ObjectIdentifier]] = [:]
        if !plan.starts.isEmpty {
            work += remaining.count
            for ticket in remaining {
                groups[ActiveGroup(ticket), default: []].append(ObjectIdentifier(ticket.operation))
            }
        }
        let planned = Dictionary(
            candidate.scopes.map { (SeenScope($0.key), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var replaced: Set<ObjectIdentifier> = []
        var works: [RuntimeWork<Descriptor>] = []
        for (start, key) in zip(plan.starts, candidate.startKeys) {
            // Preparation established every binding and resolved every key; admission compares identities only.
            let scope = planned[SeenScope(start.operation.scope)]!
            let group = ActiveGroup(kind: start.operation.kind, activation: scope.activation, key: key)
            let members = groups[group, default: []]
            work += 1 + start.operation.dependencies.count
            switch start.operation.policy {
            case .latest:
                replaced.formUnion(members)
                groups[group] = []
            case .rejectWhenActive:
                if !members.isEmpty { return reject(.operationPolicy(.alreadyActive)) }
            case .parallel(let limit):
                if members.count >= limit { return reject(.operationPolicy(.parallelLimit)) }
            }
            var bindings = [RuntimeTicket.Binding(scope: scope.key, activation: scope.activation)]
            for key in start.operation.dependencies {
                let dependency = planned[SeenScope(key)]!
                bindings.append(.init(scope: key, activation: dependency.activation))
            }
            let ticket = RuntimeTicket(
                owner: owner,
                incarnation: candidate.incarnation,
                operation: RuntimeIdentity(),
                kind: start.operation.kind,
                bindings: bindings,
                key: key
            )
            remaining.append(ticket)
            groups[group, default: []].append(ObjectIdentifier(ticket.operation))
            works.append(RuntimeWork(descriptor: start.descriptor, ticket: ticket))
        }
        if !replaced.isEmpty {
            work += remaining.count
            remaining.removeAll { replaced.contains(ObjectIdentifier($0.operation)) }
        }
        if revision == UInt64.max - 1 { return reject(.revisionExhausted) }
        let survivors = Set(remaining.map { ObjectIdentifier($0.operation) })
        let revoked = active.filter { !survivors.contains(ObjectIdentifier($0.operation)) }
        let revokedOperations = Set(revoked.map { ObjectIdentifier($0.operation) })
        work += remaining.count + active.count + reservations.count
        // Retiring work whose outcome is retained settles what that work already returned, so it gets no
        // cancellation; it keeps its execution reservation until its termination is acknowledged.
        let retained =
            plan.retire.isEmpty
            ? []
            : Set(reservations.filter { $0.delivery == .pending }.map { ObjectIdentifier($0.ticket.operation) })
        let cancelled = revoked.filter { ticket in
            !retiring.contains(ObjectIdentifier(ticket.operation))
                || !retained.contains(ObjectIdentifier(ticket.operation))
        }
        // A commandless acceptance under `.commands` recording queues nothing, so it needs no slot.
        let queues = recording == .everyAcceptance || !cancelled.isEmpty || !works.isEmpty || !plan.emissions.isEmpty
        if queues, queue.count + detached >= limits.commits { return reject(.capacityExceeded(.commitQueue)) }
        var prospective = reservations
        for index in prospective.indices
        where revokedOperations.contains(ObjectIdentifier(prospective[index].ticket.operation)) {
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
        // A key that no remaining work holds leaves the table; inserting it again mints a fresh identity.
        let held = Set(remaining.compactMap { $0.key.map(ObjectIdentifier.init) })
        work += candidate.keys.count
        keys = candidate.keys.filter { held.contains(ObjectIdentifier($0.identity)) }
        reservations = prospective
        revision += 1
        revisionIdentity = RuntimeIdentity()
        edge = plan.edge
        let accepted = snapshot
        if queues {
            var commands = cancelled.map { Command.cancel($0) }
            var emissions = plan.emissions[...]
            for (index, work) in works.enumerated() {
                while let emission = emissions.first, emission.position == index {
                    commands.append(.emit(emission.descriptor))
                    emissions.removeFirst()
                }
                commands.append(.start(work))
            }
            commands += emissions.map { .emit($0.descriptor) }
            queue.append(Batch(snapshot: accepted, commands: commands, terminal: false))
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
        keys = []
        closed = true
        revision += 1
        revisionIdentity = RuntimeIdentity()
        edge = nil
        let final = snapshot
        closeSnapshot = final
        terminal = Batch(snapshot: final, commands: cancelled.map { .cancel($0) }, terminal: true)
        return final
    }

    /// Replaces the model with `model` in a fresh incarnation whose only active scopes are `scopes`.
    ///
    /// Without `expected`, a reset expects no revision: it revokes every operation, retires every key,
    /// and queues the cancellations with its acceptance, whatever the current root. With `expected`, it
    /// replaces only that root, and otherwise rejects as a commit prepared on it would: `.foreignOwner`
    /// for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after another reset, and
    /// `.conflict` after any other acceptance. It still observes closure and revision exhaustion, and,
    /// as a commit does, the commit queue's capacity whenever it queues a batch: always under
    /// `.everyAcceptance` recording, and under `.commands` recording only when it revokes work. A
    /// rejection changes nothing.
    /// Revoked work keeps its execution reservation until it terminates or is skipped.
    public mutating func reset(
        _ model: Model,
        scopes activated: [RuntimeScopeID],
        expecting expected: Snapshot? = nil
    ) -> Admission {
        if let expected, expected.owner !== owner { return reject(.foreignOwner) }
        if closed { return reject(.closed) }
        if let expected {
            if expected.incarnation !== incarnation { return reject(.obsoleteIncarnation) }
            if expected.revisionIdentity !== revisionIdentity { return reject(.conflict) }
        }
        if revision == UInt64.max - 1 { return reject(.revisionExhausted) }
        let revoked = active
        let queues = recording == .everyAcceptance || !revoked.isEmpty
        if queues, queue.count + detached >= limits.commits { return reject(.capacityExceeded(.commitQueue)) }
        for index in reservations.indices { reservations[index].delivery = .settled }
        reservations.removeAll { $0.releasable }
        var examined = 0
        let fresh = Self.distinctScopeKeys(activated, examined: &examined)
            .map {
                Scope(key: $0, activation: RuntimeIdentity())
            }
        self.model = model
        scopes = fresh
        incarnation = RuntimeIdentity()
        active = []
        keys = []
        revision += 1
        revisionIdentity = RuntimeIdentity()
        edge = nil
        let accepted = snapshot
        if queues { queue.append(Batch(snapshot: accepted, commands: revoked.map { .cancel($0) }, terminal: false)) }
        return .committed(accepted)
    }

    /// Transfers whole FIFO batches, acknowledging revoked queued starts as skipped.
    ///
    /// Batches detached with `detachQueued()` come first: a drainer takes them with
    /// `drain(detached:)` before it drains again.
    public mutating func drain(limit: Int) -> [Batch] {
        guard limit > 0, detached == 0 else { return [] }
        var result: [Batch] = []
        while result.count < limit {
            let batch: Batch
            if let next = queue.popFirst() {
                batch = next
            } else if let final = terminal {
                batch = final
                terminal = nil
            } else {
                break
            }
            result.append(issue(batch))
        }
        return result
    }

    /// Moves every queued ordinary batch, oldest first, to a drainer that holds them outside this
    /// value, so a value that several versions of an owner's state share is not copied for each batch.
    ///
    /// Each batch keeps its commit-queue slot, and nothing about it is decided, until the drainer
    /// takes it with `drain(detached:)`, in order, in a later change of this value.
    package mutating func detachQueued() -> RuntimeFIFO<Batch> {
        detached += queue.count
        return exchange(&queue, with: RuntimeFIFO())
    }

    /// Transfers the oldest batch that `detachQueued()` moved, as ``drain(limit:)`` transfers a queued
    /// one, freeing its slot.
    package mutating func drain(detached batch: Batch) -> Batch {
        detached -= 1
        return issue(batch)
    }

    // Issues a transferred batch's commands, acknowledging revoked queued starts as skipped.
    //
    // Reservations are looked up by their operation's identity, in a table built once for the batch.
    private mutating func issue(_ batch: Batch) -> Batch {
        var commands: [Command] = []
        var reserved: [ObjectIdentifier: Int]?
        for command in batch.commands {
            guard case .start(let work) = command else {
                commands.append(command)
                continue
            }
            if reserved == nil {
                reserved = Dictionary(
                    reservations.indices.map { (ObjectIdentifier(reservations[$0].ticket.operation), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            let index = reserved?[ObjectIdentifier(work.ticket.operation)]
            if !isActive(work.ticket) {
                if let index {
                    reservations[index].execution = .skipped
                    reservations[index].delivery = .settled
                }
            } else {
                if let index, reservations[index].ticket == work.ticket { reservations[index].execution = .issued }
                commands.append(command)
            }
        }
        EngineWork.report(batch.commands.count + (reserved == nil ? 0 : reservations.count))
        reservations.removeAll { $0.releasable }
        return Batch(snapshot: batch.snapshot, commands: commands, terminal: batch.terminal)
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
extension RuntimeState.Emission: Sendable where Descriptor: Sendable {}
extension RuntimeState.Plan: Sendable where Descriptor: Sendable {}
extension RuntimeState.Candidate: Sendable where Model: Sendable, Descriptor: Sendable {}
extension RuntimeState.Admission: Sendable where Model: Sendable {}
extension RuntimeState.DefectivePlan: Sendable where Model: Sendable {}
extension RuntimeState.Proposal: Sendable where Model: Sendable, Descriptor: Sendable {}
extension RuntimeState.Command: Sendable where Descriptor: Sendable {}
extension RuntimeState.Batch: Sendable where Model: Sendable, Descriptor: Sendable {}
