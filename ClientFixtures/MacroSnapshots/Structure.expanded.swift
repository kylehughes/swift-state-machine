fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Swift::Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Swift::Copyable> {
}

fileprivate struct _RouterSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Swift::Sendable & ~Swift::Copyable> {
}

fileprivate struct _OperationFailureIsError<Value: Swift::Error> {
}

fileprivate struct _OperationKeyIsHashable<Value: Swift::Hashable & Swift::Sendable> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

/// The schema type, used by generated code where a local value could shadow its name.
internal typealias _StateMachineSchema = Checkout

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Checkout' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Checkout'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> _TriggerPayloadMatchesDeclaration<Value> {
    _TriggerPayloadMatchesDeclaration<Value>()
}

fileprivate static func _stateMachineTakesOutput<Value: ~Swift::Copyable>(_ declared: _TriggerPayloadMatchesDeclaration<Value>, _ authored: _TriggerPayloadMatchesDeclaration<Value>) {
}

@available(*, unavailable, message: "A success edge or router takes its operation's output in the unlabeled parameter after its source, so that parameter's type must be exactly the operation's Output; take the request with the argument label request:, or declare the Output this parameter takes.")
fileprivate static func _stateMachineTakesOutput<Declared: ~Swift::Copyable, Authored: ~Swift::Copyable>(_ declared: _TriggerPayloadMatchesDeclaration<Declared>, _ authored: _TriggerPayloadMatchesDeclaration<Authored>) {
}

fileprivate enum _StateMachineReadsNever {
}

fileprivate static func _stateMachineNeverProbe<Value: ~Swift::Copyable>(_ type: Value.Type) -> Swift::Bool {
    true
}

fileprivate static func _stateMachineNeverProbe(_ type: Swift::Never.Type) -> _StateMachineReadsNever.Type {
    _StateMachineReadsNever.self
}

fileprivate static func _stateMachineIsNotSwiftNever(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Charge' never succeeds: its Output is Never, so its onSuccess: edges and routers can never run; remove them, or declare the Output the operation produces.")
fileprivate static func _stateMachineIsNotSwiftNever(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever2(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Event 'Tracked' carries Never, so no transition can emit it; declare a payload type that has values, or remove the event.")
fileprivate static func _stateMachineIsNotSwiftNever2(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    do {
        typealias _StateMachineChecked = Charge.Output;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    do {
        typealias _StateMachineChecked = Tracked.Payload;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever2(probe)
    }
    let _: _TransitionSourceIsPhasePayload<Cart> = _TransitionSourceIsPhasePayload<Cart>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Cart, Effect.Add>> = _TransitionReturnsDeclaredResult<Change<Cart, Effect.Add>>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .add(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<String> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Cart> = _TransitionSourceIsPhasePayload<Cart>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Paying, Effect.Pay>> = _TransitionReturnsDeclaredResult<Change<Paying, Effect.Pay>>()
    let _: _TransitionSourceIsPhasePayload<Paying> = _TransitionSourceIsPhasePayload<Paying>()
    let _: _TransitionReturnsDeclaredResult<Confirming> = _TransitionReturnsDeclaredResult<Confirming>()
    let _: _TransitionSourceIsPhasePayload<Paying> = _TransitionSourceIsPhasePayload<Paying>()
    let _: _TransitionReturnsDeclaredResult<Paid> = _TransitionReturnsDeclaredResult<Paid>()
    _stateMachineTakesOutput(_TriggerPayloadMatchesDeclaration<Charge.Output>(), _TriggerPayloadMatchesDeclaration<Charge.Output>())
    let _: _TransitionSourceIsPhasePayload<Confirming> = _TransitionSourceIsPhasePayload<Confirming>()
    let _: _TransitionReturnsDeclaredResult<Paid> = _TransitionReturnsDeclaredResult<Paid>()
    _stateMachineTakesOutput(_TriggerPayloadMatchesDeclaration<Charge.Output>(), _TriggerPayloadMatchesDeclaration<Charge.Output>())


    let _ = _EffectIsCopyable<Effect>()
    let _ = _SharedModeRequiresSendable<Input>();
    let _ = _SharedModeRequiresSendable<Effect>()
}

/// Inert descriptions of the operations this workflow can start and the events it can emit.
internal enum Effect: Swift::Sendable {
    case charge(Checkout.Charge.Input)
    case tracked(Checkout.Tracked.Payload)
    case pinged
    /// The events `add` may emit.
internal enum Add: Swift::Sendable {
    case tracked(Checkout.Tracked.Payload)
    /// The schema-wide effect this value describes.
    internal var effect: Checkout.Effect {
        switch self {
        case .tracked(let payload):
            return .tracked(payload)
        }
    }
    }
    /// The operations `pay` may start and the events it may emit.
    internal enum Pay: Swift::Sendable {
        case charge(Checkout.Charge.Input)
    case tracked(Checkout.Tracked.Payload)
    case pinged
        /// The schema-wide effect this value describes.
        internal var effect: Checkout.Effect {
        switch self {
        case .charge(let input):
            return .charge(input)
        case .tracked(let payload):
            return .tracked(payload)
        case .pinged:
            return .pinged
        }
    }
    }
    /// The effect vocabularies of the edges from `Cart`.
    internal enum Cart {
        internal typealias Add = Checkout.Effect.Add
    internal typealias Pay = Checkout.Effect.Pay
    }
}

/// What one `Charge` execution was started with, as admission accepted it.
internal typealias ChargeRequest = StateMachine::OperationRequest<Charge, Charge.Input>

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Swift::Copyable & Swift::Sendable>: ~Swift::Copyable, Swift::Sendable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
    internal borrowing func withValue<Result: ~Swift::Copyable, Failure: Swift::Error>(
        _ body: (borrowing Phase) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(phase)
    }
    /// Consumes this authority and returns its payload, so a unique resource can move on.
    internal consuming func takeValue() -> Phase {
        phase
    }
    /// Advances through the authored edge, preserving effect order.
internal consuming func add(_ input: String) -> StateMachine::Change<Owned<Cart>, Effect.Add> where Phase == Cart {
    let change = _StateMachineSchema.add(phase, input)
    return .init(Owned<Cart>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func pay() -> StateMachine::Change<Owned<Paying>, Effect.Pay> where Phase == Cart {
        let change = _StateMachineSchema.pay(phase)
        return .init(Owned<Paying>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func confirm() -> Owned<Confirming> where Phase == Paying {
        Owned<Confirming>(_StateMachineSchema.confirm(phase))
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func charged(_ input: Charge.Output) -> Owned<Paid> where Phase == Paying {
        Owned<Paid>(_StateMachineSchema.charged(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func charged(_ input: Charge.Output) -> Owned<Paid> where Phase == Confirming {
        Owned<Paid>(_StateMachineSchema.charged(phase, input))
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Cart = _StateMachineSchema.Cart()) -> Owned<Cart> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Checkout, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = StateMachine::ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = StateMachine::Limits

/// A live observation registration. Cancelling or releasing it stops delivery.
internal typealias Subscription = StateMachine::SnapshotSubscription

/// A live observation registration for an owner confined to `Owner`. Only that actor can cancel and remove it, and releasing it stops delivery.
internal typealias IsolatedSubscription<Owner: Swift::Actor> = StateMachine::IsolatedSnapshotSubscription<Owner>

/// A live `MainActor` observation registration. Cancelling or releasing it stops delivery.
internal typealias MainActorSubscription = StateMachine::MainActorSnapshotSubscription

/// Failure to register another live observer.
internal typealias SubscriptionFailure = StateMachine::SubscriptionFailure

/// A single-pass latest-value sequence of an owner's snapshots.
internal typealias Snapshots = StateMachine::SnapshotSequence<Snapshot>

/// The disposition of a retained completion.
internal typealias PendingStatus = StateMachine::PendingStatus

/// Why an owner refused a prepared candidate, in precedence order.
internal typealias CommitRejection = StateMachine::CommitRejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase: Swift::Sendable>: Swift::Sendable, Swift::CustomStringConvertible {
    fileprivate let payload: Phase
    fileprivate let record: _StateMachineEngine.Snapshot
    fileprivate let claim: StateMachine::RuntimeDeliveryClaim?
    /// The copied historical payload.
    internal var value: Phase {
        payload
    }
    /// The owner-lifetime accepted revision.
    internal var revision: Swift::UInt64 {
        record.revision
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        "\(Phase.self), revision \(record.revision)\(record.isClosed ? ", closed" : "")"
    }
    /// Prepares the declared edge with phase authority preserved.
internal func add(_ input: String) -> Prepared where Phase == Cart {
    let change: StateMachine::Change<Cart, Effect.Add> = _StateMachineSchema.add(payload, input)
    return _stateMachinePrepare(on: record, next: .cart(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 0, invalidates: [],
        requiring: nil, claim: claim, edge: "cart.add")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func pay() -> Prepared where Phase == Cart {
        let change: StateMachine::Change<Paying, Effect.Pay> = _StateMachineSchema.pay(payload)
        return _stateMachinePrepare(on: record, next: .paying(change.next),
            effects: change.effects.map(\.effect),
            from: 0, to: 1, invalidates: [],
            requiring: nil, claim: claim, edge: "cart.pay")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func confirm() -> Prepared where Phase == Paying {
        let next: Confirming = _StateMachineSchema.confirm(payload)
        return _stateMachinePrepare(on: record, next: .confirming(next),
            effects: [],
            from: 1, to: 2, invalidates: [],
            requiring: nil, claim: claim, edge: "paying.confirm")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func charged(_ value: Charge.Output, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Paying {
        let next: Paid = _StateMachineSchema.charged(payload, value)
        return _stateMachinePrepare(on: record, next: .paid(next),
            effects: [],
            from: 1, to: 3, invalidates: [],
            requiring: authority, claim: claim, edge: "paying.charged")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func charged(_ value: Charge.Output, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Confirming {
        let next: Paid = _StateMachineSchema.charged(payload, value)
        return _stateMachinePrepare(on: record, next: .paid(next),
            effects: [],
            from: 2, to: 3, invalidates: [],
            requiring: authority, claim: claim, edge: "confirming.charged")
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: Swift::Sendable, StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
    case cart(Observed<Cart>)
    case paying(Observed<Paying>)
    case confirming(Observed<Confirming>)
    case paid(Observed<Paid>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .cart(let value):
            return value.record
        case .paying(let value):
            return value.record
        case .confirming(let value):
            return value.record
        case .paid(let value):
            return value.record
        }
    }
    /// The accepted revision of this observation.
    internal var revision: Swift::UInt64 {
        record.revision
    }
    /// Whether this historical root records closure.
    internal var isClosed: Swift::Bool {
        record.isClosed
    }
    /// The ordinary model data. Constructing a model value directly confers no installation authority.
    internal var model: Checkout {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        switch self {
        case .cart(let value):
            return "cart, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .paying(let value):
            return "paying, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .confirming(let value):
            return "confirming, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .paid(let value):
            return "paid, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .cart(let payload):
        return .cart(Observed(payload: payload, record: record, claim: claim))
    case .paying(let payload):
        return .paying(Observed(payload: payload, record: record, claim: claim))
    case .confirming(let payload):
        return .confirming(Observed(payload: payload, record: record, claim: claim))
    case .paid(let payload):
        return .paid(Observed(payload: payload, record: record, claim: claim))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .cart:
        return "cart"
    case .paying:
        return "paying"
    case .confirming:
        return "confirming"
    case .paid:
        return "paid"
    }
}

fileprivate static func _stateMachineRefusingRoute(_ rejection: PreparationRejection, in phase: Swift::String) -> Swift::String? {
    nil
}

/// A sealed inert candidate consumed by admission.
///
/// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
/// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
/// another owner's or the owner is closed, which it reports first.
internal struct Prepared: ~Swift::Copyable, Swift::Sendable {
    fileprivate let candidate: _StateMachineEngine.Proposal
    fileprivate init(_ candidate: _StateMachineEngine.Proposal) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
internal enum PreparationRejection: Swift::Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase

}

/// A historical receipt for an atomic acceptance.
internal struct Receipt: Swift::Sendable, StateMachine::StateMachineReceipt, Swift::CustomStringConvertible {
    /// The accepted historical observation.
    internal let snapshot: Snapshot
    fileprivate init(_ record: _StateMachineEngine.Snapshot) {
        snapshot = _stateMachineSnapshot(record)
        edgeID = record.edge
    }
    /// The identifier of the graph edge the acceptance took, as `graph` names it, or `nil` for a
    /// change that takes no edge, such as a reset, closure, or the authority-only commit of
    /// `discardPending(id:)`.
    internal let edgeID: Swift::String?
    /// The owner-lifetime accepted revision.
    internal var revision: Swift::UInt64 {
        snapshot.revision
    }
    /// The accepted phase, revision, and closure, without the payload.
    internal var description: Swift::String {
        snapshot.description
    }
}

/// Why `send` did not admit an input.
internal enum SendRejection: Swift::Error {
    /// Routing or the authored transition declined the input before a candidate existed.
    case preparation(PreparationRejection)
    /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`).
    /// Read `snapshot()` for the current root.
    case commit(CommitRejection)
}

/// Admission either publishes the entire candidate or leaves all state unchanged.
internal enum CommitResult: Swift::Sendable {
    case committed(Receipt)
    case rejected(CommitRejection, current: Snapshot)
}

fileprivate static func _stateMachineAdmission(_ result: _StateMachineEngine.Admission) -> CommitResult {
    switch result {
    case .committed(let record):
        return .committed(Receipt(record))
    case .rejected(let reason, let current):
        return .rejected(reason, current: _stateMachineSnapshot(current))
    }
}

/// Work issued exclusively from an accepted command batch.
internal typealias ChargeWork = _ChargeWork<Charge.Output>

/// The work of `Charge`, generic over its output so that it seals an output of any type.
internal struct _ChargeWork<_StateMachineOutput>: Swift::Sendable {
    /// What admission started this work with.
internal let request: ChargeRequest

    /// The immutable declared input.
internal var input: Charge.Input {
        request.input
    }
    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: _StateMachineOutput) -> ChargeCompletion where _StateMachineOutput == Charge.Output {
        ChargeCompletion(value: value, request: request, authority: authority)
    }


}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct ChargeCompletion: Swift::Sendable {
    /// The value the operation produced. This operation cannot fail.
    internal let value: Charge.Output
    /// What admission started the work with.
internal let request: ChargeRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Closed typed terminal outcomes for this domain.
internal enum Completion: Swift::Sendable {
    case charge(ChargeCompletion)
    fileprivate var authority: StateMachine::RuntimeTicket {
        switch self {
        case .charge(let value):
            return value.authority
        }
    }
}

/// A sealed handle to actual execution bookkeeping.
internal struct ExecutionHandle: Swift::Equatable, Swift::Sendable {
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// How an execution ended, independently of cancellation or completion delivery.
internal typealias ExecutionDisposition = StateMachine::ExecutionDisposition

/// Whether a physical execution acknowledgment was recorded.
internal typealias AcknowledgmentResult = StateMachine::AcknowledgmentResult

/// A closed accepted start or cancellation command, or an emitted event.
internal enum Command: Swift::Sendable {
    case cancel(ExecutionHandle)
    case charge(ChargeWork)
    case tracked(Checkout.Tracked.Payload)
    case pinged
}

/// One whole FIFO batch with its historical receipt.
internal struct CommandBatch: Swift::Sendable, StateMachine::LocalCommandBatch {
    /// The atomic acceptance represented by this batch.
    internal let receipt: Receipt
    /// Cancellation commands, then starts and events in authored effect order.
    internal let commands: [Command]
    /// Whether this is the separately reserved close batch.
    internal let terminal: Swift::Bool
    fileprivate init(receipt: Receipt, commands: [Command], terminal: Swift::Bool) {
        self.receipt = receipt
        self.commands = commands
        self.terminal = terminal
    }
}

fileprivate static func _stateMachineBatch(_ batch: _StateMachineEngine.Batch) -> CommandBatch {
    let commands = batch.commands.map { command -> Command in
        switch command {
        case .cancel(let ticket):
            return .cancel(ExecutionHandle(authority: ticket))
        case .start(let work):
            switch work.descriptor {
            case .charge(let input):
                return .charge(ChargeWork(request: ChargeRequest(input: input), authority: work.ticket))
            case .tracked:
                Swift::preconditionFailure("An emission is never started.")
            case .pinged:
                Swift::preconditionFailure("An emission is never started.")
            }
        case .emit(let effect):
            switch effect {
            case .charge:
                Swift::preconditionFailure("A start is never emitted.")
            case .tracked(let payload):
                return .tracked(payload)
            case .pinged:
                return .pinged
            }
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    [[1, 2], Swift::Array(0 ..< 4)]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Checkout, effects: [Effect], from: Swift::Int, to: Swift::Int,
    invalidates: [Swift::Int], requiring ticket: StateMachine::RuntimeTicket?, claim: StateMachine::RuntimeDeliveryClaim?, edge: Swift::String
) -> Prepared {
    do throws(StateMachine::PlanRejection) {
        var edits: [_StateMachineEngine.ScopeEdit] = []
        for (scope, phases) in _stateMachineEligibility.enumerated() {
            let before = phases.contains(from)
            let after = phases.contains(to)
            if after && (!before || invalidates.contains(scope)) {
                edits.append(.activate(_StateMachineScopeID(kind: Swift::UInt32(scope))))
            }
            else if before && !after {
                edits.append(.remove(_StateMachineScopeID(kind: Swift::UInt32(scope))))
            }
        }
        var starts: [_StateMachineEngine.Start] = []
        var counts = Swift::Array(repeating: 0, count: 1)
        var emissions: [_StateMachineEngine.Emission] = []
        for effect in effects {
            switch effect {
            case .charge(let input):
                let _: Charge.Input = input
                counts[0] += 1
                guard counts[0] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 0, scope: _StateMachineScopeID(kind: 0),
                    dependencies: [_StateMachineScopeID(kind: 1)], policy: .latest), descriptor: effect))
            case .tracked:
                emissions.append(.init(effect, position: starts.count))
            case .pinged:
                emissions.append(.init(effect, position: starts.count))
            }
        }
        return Prepared(.candidate(try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map {
                        [$0]
                    } ?? [],
            plan: .init(scopes: edits, retire: ticket.map {
                            [$0]
                        } ?? [], starts: starts, emissions: emissions,
                controlCount: invalidates.count, finishingClaims: claim.map {
                            [$0]
                        } ?? [], edge: edge))))
    } catch {
        return Prepared(.defective(.init(error, preparedOn: record)))
    }
}

/// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
///
/// A plan defect travels inside the returned `Prepared` value rather than throwing here, so
/// admission reports it.
internal static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch input {
    case .add(let input):
        switch snapshot {
        case .cart(let source):
            return source.add(input)
        default:
            throw .invalidPhase
        }
    case .pay:
        switch snapshot {
        case .cart(let source):
            return source.pay()
        default:
            throw .invalidPhase
        }
    case .confirm:
        switch snapshot {
        case .paying(let source):
            return source.confirm()
        default:
            throw .invalidPhase
        }
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch completion {
    case .charge(let completion):
        switch snapshot {
        case .paying(let source):
            let value: Charge.Output = completion.value
            return source.charged(value, authority: completion.authority)
        case .confirming(let source):
            let value: Charge.Output = completion.value
            return source.charged(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    }
}

/// A phase that saved data can restore, covering phases with no active operations. A restored owner has no outstanding work.
internal enum Restoration: Swift::Sendable {
    case cart(Cart)
    case paid(Paid)
}

fileprivate typealias _StateMachineLedger = StateMachine::RuntimeDeliveryLedger<Checkout, Effect, Completion, PreparationRejection>

/// A single-pass latest-value sequence of a managed owner's retained completions.
internal typealias PendingCompletionUpdates = StateMachine::SnapshotSequence<[PendingCompletion]>

/// The opaque identity of one retained terminal outcome of this schema's owners.
internal struct PendingCompletionID: Swift::Hashable, Swift::Sendable {
    fileprivate let raw: StateMachine::RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value. Only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
internal struct PendingCompletion: Swift::Sendable {
    /// The retained terminal value of one operation, with the request its work was started with.
    internal enum Outcome: Swift::Sendable {
        case charge(Checkout.Charge.Output, request: Checkout.ChargeRequest)
    }
    /// Why the last preparation or admission of a retained outcome did not commit.
    internal enum Rejection: Swift::Sendable {
        /// The router or completion edge rejected the outcome.
        case preparation(PreparationRejection)
        /// The owner refused the prepared candidate, or its effect plan is defective.
        case admission(CommitRejection)
    }
    /// The opaque identity of this retained outcome.
    internal let id: PendingCompletionID
    /// The first retained terminal outcome.
    internal let outcome: Outcome
    /// The delivery state when this record was captured.
    internal let status: PendingStatus
    /// The last failed preparation or admission, when present.
    internal let lastRejection: Rejection?
    /// The saturating count of claimed preparations. Capacity retries do not increment it.
    internal let attempts: Swift::UInt64
    /// Whether the preparation count has reached its representable limit.
    internal var attemptsSaturated: Swift::Bool {
        attempts == Swift::UInt64.max
    }
    fileprivate init(_ pending: _StateMachineLedger.Pending) {
        id = PendingCompletionID(raw: pending.id)
        switch pending.outcome {
        case .charge(let completion):
            outcome = .charge(completion.value, request: completion.request)
        }
        status = pending.status
        lastRejection = pending.lastRejection.map { reason in
            switch reason {
            case .preparation(let rejection):
                .preparation(rejection)
            case .admission(let rejection):
                .admission(rejection)
            }
        }
        attempts = pending.attempts
    }
}

/// The decision `deliver` made about one terminal outcome.
internal enum DeliveryResult: Swift::Sendable {
    /// The outcome committed.
    case committed(Receipt)
    /// The outcome is retained, and its status describes what admission is waiting for.
    case pending(PendingCompletionID, PendingStatus)
        /// This call prepared the outcome, and its routing or an authored function refused it, so the outcome
    /// is retained with status `reconciliationRequired`.
    ///
    /// `routeID` is the identifier of the router or completion edge whose authored function refused it,
    /// as `graph` names it, or `nil` when no authored function refused it.
    case refused(PendingCompletionID, PreparationRejection, routeID: Swift::String?)
    /// The operation's authority is inactive or its outcome was already settled.
    case stale
    /// The completion was issued by a different owner.
    case foreignOwner
}

/// The result of one more attempt to admit a retained outcome.
internal enum ReconcileResult: Swift::Sendable {
    /// The retained outcome committed.
    case committed(Receipt)
    /// The outcome is still retained, and its status describes what admission is waiting for.
    case pending(PendingCompletionID, PendingStatus)
        /// This call prepared the outcome, and its routing or an authored function refused it, so the outcome
    /// is retained with status `reconciliationRequired`.
    ///
    /// `routeID` is the identifier of the router or completion edge whose authored function refused it,
    /// as `graph` names it, or `nil` when no authored function refused it.
    case refused(PendingCompletionID, PreparationRejection, routeID: Swift::String?)
    /// Another attempt holds the only preparation claim.
    case inProgress
    /// No outcome with this identity is retained.
    case notPending
}

/// The result of revoking a retained outcome's operation.
internal enum DiscardResult: Swift::Sendable {
    /// The authority-only commit revoked the operation and disposed of its outcome.
    case discarded(Receipt)
    /// The owner refused the authority-only commit, leaving the outcome retained.
    case rejected(CommitRejection)
    /// No outcome with this identity is retained.
    case notPending
}

/// The refusal of the outcome retained as `id`, whose preparation from `record` threw `rejection`.
fileprivate static func _stateMachineRefused(_ id: StateMachine::RuntimePendingID, _ rejection: PreparationRejection, on record: _StateMachineEngine.Snapshot) -> ReconcileResult {
    .refused(PendingCompletionID(raw: id), rejection, routeID: _stateMachineRefusingRoute(rejection, in: _stateMachinePhase(of: record)))
}

fileprivate static func _stateMachineFinish(_ result: _StateMachineLedger.Finish) -> ReconcileResult {
    switch result {
    case .committed(let record):
        return .committed(Receipt(record))
    case .pending(let id, let status):
        return .pending(PendingCompletionID(raw: id), status)
    case .notPending:
        return .notPending
    }
}

fileprivate static func _stateMachineDeliveryPreparation(_ attempt: _StateMachineLedger.Attempt) -> _StateMachineLedger.Preparation {
    let prepared: Prepared
    do {
        prepared = try _stateMachineCompletion(attempt.outcome, on: _stateMachineSnapshot(attempt.snapshot, claim: attempt.claim))
    } catch {
        return .failure(.preparation(error))
    }
    switch prepared.candidate {
    case .candidate(let candidate):
        return .success(candidate)
    case .defective(let defect):
        return .failure(.admission(defect.rejection(against: attempt.snapshot)))
    }
}

/// The obligations a managed owner still tracked when its shutdown deadline expired.
///
/// It is captured in the same observation that found the deadline expired, so it always names
/// at least one unsettled obligation. It holds no model data and no authority over the owner.
internal struct ShutdownDiagnostics: Swift::Equatable, Swift::Sendable {
    /// An execution and delivery obligation that remained tracked.
internal typealias OutstandingExecution = StateMachine::ShutdownDiagnostics.OutstandingExecution
    /// The owner's last accepted revision at the observation.
    internal let acceptedRevision: Swift::UInt64
    /// The revision of the last fully processed FIFO batch.
    internal let processedThrough: Swift::UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    internal let hasQueuedBatches: Swift::Bool
    /// Whether a FIFO processing turn still owns responsibility.
    internal let isDraining: Swift::Bool
    /// Whether an automatic retry of a retained completion is still scheduled.
internal let isRetrying: Swift::Bool
    /// The identities of the retained terminal outcomes.
    internal let pendingCompletions: [PendingCompletionID]
    /// The executions, deliveries, and preparations that remain tracked.
    internal let outstandingExecutions: [OutstandingExecution]
    fileprivate init(_ raw: StateMachine::ShutdownDiagnostics) {
        acceptedRevision = raw.acceptedRevision
        processedThrough = raw.processedThrough
        hasQueuedBatches = raw.hasQueuedBatches
        isDraining = raw.isDraining
        isRetrying = raw.isRetrying
        pendingCompletions = raw.pendingCompletions.map {
            PendingCompletionID(raw: $0)
        }
        outstandingExecutions = raw.outstandingExecutions
    }
}

/// Whether shutdown joined every obligation or stopped waiting at its deadline.
///
/// A timeout leaves the owner closed and its outstanding work tracked.
internal enum ShutdownResult: Swift::Equatable, Swift::Sendable {
    /// Every execution, delivery, and preparation obligation settled.
    case quiescent
    /// The deadline passed first, and the diagnostics describe what remained outstanding.
    case timedOut(ShutdownDiagnostics)
    fileprivate init(_ raw: StateMachine::ShutdownDiagnostics?) {
        self = raw.map {
            .timedOut(ShutdownDiagnostics($0))
        } ?? .quiescent
    }
}

/// Whether `flush(through:)` waited for a receipt's batch to be processed.
internal typealias FlushResult = StateMachine::FlushResult

/// A noncopyable manually driven owner with an embedded value engine.
internal struct Local: ~Swift::Copyable, StateMachine::DeliveringLocalStateMachine, StateMachine::DefaultingLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
internal typealias Input = Checkout.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Snapshot = Checkout.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Receipt = Checkout.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias SendRejection = Checkout.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Prepared = Checkout.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommitResult = Checkout.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias InitialPhase = Cart
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Command = Checkout.Command
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommandBatch = Checkout.CommandBatch
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Completion = Checkout.Completion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ExecutionHandle = Checkout.ExecutionHandle
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletionID = Checkout.PendingCompletionID
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletion = Checkout.PendingCompletion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DeliveryResult = Checkout.DeliveryResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ReconcileResult = Checkout.ReconcileResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DiscardResult = Checkout.DiscardResult
    /// The declared structure of this owner's graph.
    internal static var graph: StateMachine::StateMachineGraph {
        _StateMachineSchema.graph
    }
    /// The identifier of the phase a snapshot holds, as the graph names it.
    internal static func phase(of snapshot: Snapshot) -> Swift::String {
        _stateMachinePhase(of: snapshot.record)
    }
    /// The receipt of an admitted proposal, or `nil` when admission rejected it.
    internal static func receipt(of result: CommitResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The identifier of the router or edge, as the graph names it, whose authored function refused an
    /// input that `send` rejected from a snapshot in `phase`, or `nil` when no authored function refused it.
    internal static func rejectingRoute(of rejection: SendRejection, in phase: Swift::String) -> Swift::String? {
        guard case .preparation(let preparation) = rejection else {
        return nil
    }
        return _stateMachineRefusingRoute(preparation, in: phase)
    }
    /// A fresh initial payload, constructed as the schema's declared default constructs it.
    internal static func defaultInitialPhase() -> InitialPhase {
        _StateMachineSchema.Cart()
    }
    /// The receipt of a delivery that committed, or `nil` when the outcome was retained or not taken.
    internal static func receipt(of result: DeliveryResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The receipt of a retained outcome's admission, or `nil` when it did not commit.
    internal static func receipt(of result: ReconcileResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The receipt of a discard's authority-only commit, or `nil` when nothing was discarded.
    internal static func receipt(of result: DiscardResult) -> Receipt? {
        if case .discarded(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The identifier of the router or completion edge, as the graph names it, whose authored function
    /// refused the outcome in the call that returned `result`, or `nil` when that call's preparation
    /// did not refuse it.
    internal static func rejectingRoute(of result: DeliveryResult) -> Swift::String? {
        if case .refused(_, _, let routeID) = result {
        routeID
    } else {
        nil
    }
    }
    /// The identifier of the router or completion edge, as the graph names it, whose authored function
    /// refused the outcome in the call that returned `result`, or `nil` when that call's preparation
    /// did not refuse it.
    internal static func rejectingRoute(of result: ReconcileResult) -> Swift::String? {
        if case .refused(_, _, let routeID) = result {
        routeID
    } else {
        nil
    }
    }
    fileprivate var engine: _StateMachineEngine
    fileprivate var ledger = _StateMachineLedger()
    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Cart = _StateMachineSchema.Cart(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], limits: configuration, recording: .commands)
    }
    /// Returns an immutable historical observation.
    internal borrowing func snapshot() -> Snapshot {
        _stateMachineSnapshot(engine.snapshot)
    }
    /// Whether `snapshot` was taken from this owner, in any incarnation.
    ///
    /// A reset keeps the owner, and another owner never matches, even one that holds an equal
    /// model at the same revision. The answer grants no authority.
    internal borrowing func owns(_ snapshot: Snapshot) -> Swift::Bool {
        engine.owns(snapshot.record)
    }
    /// Consumes and atomically accepts or rejects a complete candidate.
    internal mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
        switch prepared.candidate {
        case .defective(let defect):
            return _stateMachineAdmission(engine.reject(defect))
        case .candidate(let candidate):
            let result = engine.commit(candidate)
            ledger.prune(in: engine)
            return _stateMachineAdmission(result)
        }
    }
    /// Routes, prepares, and admits one input against the current root.
    @discardableResult
    internal mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
        let prepared: Prepared
        do {
            prepared = try _StateMachineSchema.prepare(input, on: snapshot())
        } catch {
            throw .preparation(error)
        }
        switch commit(prepared) {
        case .committed(let receipt):
            return receipt
        case .rejected(let reason, _):
            throw .commit(reason)
        }
    }
    /// Transfers at most `limit` whole FIFO batches. Physical execution occurs after mutating access ends.
internal mutating func drainCommands(limit: Swift::Int = .max) -> [CommandBatch] {
    engine.drain(limit: limit).map {
        _stateMachineBatch($0)
    }
    }
    /// How many whole batches a drain would transfer, including the terminal batch, without
    /// transferring any.
    internal var queuedBatchCount: Swift::Int {
        engine.queuedBatchCount
    }
    /// Records actual termination independently of cancellation and completion delivery.
    ///
    /// Pass `.skippedBeforeStart` for work the caller never began.
    internal mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition = .terminated) -> AcknowledgmentResult {
        switch engine.acknowledge(execution.authority, skippedBeforeStart: disposition == .skippedBeforeStart) {
        case .recorded:
        return .recorded
        case .duplicate:
        return .duplicate
        case .foreignOwner:
        return .foreignOwner
        }
    }
    /// Retains the first outcome and attempts one typed preparation against the current root.
    ///
    /// This is the only way to submit a terminal outcome. A later outcome for the same work never
    /// replaces the retained one and reports the retained outcome's status instead.
    internal mutating func deliver(_ completion: Completion) -> DeliveryResult {
        switch ledger.retain(completion, for: completion.authority, in: &engine) {
        case .stale:
        return .stale
        case .foreignOwner:
        return .foreignOwner
        case .pending(let raw):
            let id = PendingCompletionID(raw: raw)
            guard let pending = ledger.pending.first(where: { $0.id == raw
            }) else {
            return .stale
        }
            if pending.status != .awaitingAdmission {
            return .pending(id, pending.status)
        }
            switch reconcile(id: id) {
            case .committed(let receipt):
            return .committed(receipt)
            case .pending(let id, let status):
            return .pending(id, status)
            case .refused(let id, let rejection, let routeID):
            return .refused(id, rejection, routeID: routeID)
            case .inProgress:
            return .pending(id, .preparing)
            case .notPending:
            return .stale
            }
        }
    }
    /// Delivers the sealed terminal result of one `Charge` execution.
    internal mutating func deliver(_ completion: ChargeCompletion) -> DeliveryResult {
        deliver(.charge(completion))
    }
    /// Claims one retained outcome before evaluating domain code.
    internal mutating func reconcile(id: PendingCompletionID) -> ReconcileResult {
        switch ledger.claim(id.raw, in: &engine) {
        case .inProgress:
        return .inProgress
        case .notPending:
        return .notPending
        case .claimed(let attempt):
            let preparation = _stateMachineDeliveryPreparation(attempt)
            let finish = ledger.finish(attempt, preparation: preparation, in: &engine)
            if case .failure(.preparation(let rejection)) = preparation, case .pending(let raw, .reconciliationRequired) = finish {
                return _stateMachineRefused(raw, rejection, on: attempt.snapshot)
            }
            return _stateMachineFinish(finish)
        }
    }
    /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
    ///
    /// Draining and acknowledging never admit a retained completion. Call this after they free capacity.
    internal mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult {
        _stateMachineFinish(ledger.retryAdmission(id.raw, in: &engine))
    }
    /// Queries immutable first-outcome records without claiming preparation.
    internal borrowing func pendingCompletions() -> [PendingCompletion] {
        ledger.pending.map(PendingCompletion.init)
    }
    /// Revokes one retained operation using an atomic authority-only commit.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    internal mutating func discardPending(id: PendingCompletionID) -> DiscardResult {
        guard let result = ledger.discard(id.raw, in: &engine) else {
        return .notPending
    }
        switch result {
        case .committed(let record):
        return .discarded(Receipt(record))
        case .rejected(let reason, _):
        return .rejected(reason)
        }
    }
    /// Ends admission while retaining historical read access.
    @discardableResult
    internal mutating func close() -> Receipt {
        let result = engine.close()
        ledger.prune(in: engine)
        return Receipt(result)
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// Every outstanding operation is revoked, with its cancellation published in the reset's
    /// batch, and every retained completion is disposed of, so a late result is stale. The owner
    /// keeps its identity and subscribers, and its revision advances. Work that is still running
    /// keeps its execution reservation until it terminates.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues a batch only to cancel the work it revokes, so it needs a slot only then.
    @discardableResult
    internal mutating func reset(to initial: Cart = _StateMachineSchema.Cart()) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)])
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
    /// still holds the root `expected` observed, so a decision made on that snapshot cannot
    /// discard a change accepted since.
    ///
    /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
    /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
    /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
    /// other acceptance, and then the same errors as `reset(to:)`.
    @discardableResult
    internal mutating func reset(to initial: Cart = _StateMachineSchema.Cart(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
internal var isQuiescent: Swift::Bool {
        engine.isQuiescent
    }
}

/// Immutable operation selections whose non-`Sendable` values stay on `MainActor`.
@Swift::MainActor internal struct MainActorDrivers {
    /// Executes this operation within the selected isolation.
internal let charge: @Swift::MainActor (Charge.Input) async -> Charge.Output
    /// Selects every driver for this owner's lifetime.
    internal init(charge: @escaping @Swift::MainActor (Charge.Input) async -> Charge.Output) {
        self.charge = charge
    }
}

/// A sealed sole-writer `MainActor` owner with managed execution.
///
/// On iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, and Mac Catalyst 17.0 and
/// later, this owner conforms to `Observable` so a SwiftUI view can read it directly. Each
/// tracked member registers a read of its own value only, covering `currentSnapshot` and `snapshot()`, `runningCount`,
/// `subscriberCount`, and `pendingCompletions()`.
@Swift::MainActor internal final class MainActorHost: StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeMainActorHost<Checkout, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That behaves like the result arriving a moment later, when its edge would run against
    /// the newer phase anyway. Work that must not survive a change is revoked by the edge's
    /// `invalidates:` instead. `.manual` never prepares a completion again on its own. Either form
    /// can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion enters
    /// `reconciliationRequired`. This happens when its completion edge or router throws, its
    /// effect plan is defective, the owner refuses its admission, an explicit `reconcile(id:)`
    /// does not commit, or, under `.manual`, its preparation loses a race. Settle it with
    /// `reconcile(id:)` or `discardPending(id:)`.
    internal struct CompletionPolicy {
        fileprivate let runtime: StateMachine::RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: @Swift::MainActor (_StateMachineLedger.Pending) -> Swift::Void
        private init(_ runtime: StateMachine::RuntimeCompletionPolicy, handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it when every completion edge and router is deterministic and free of side
        /// effects, since the compiler does not enforce that. A completion retained for any other
        /// reason stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
        /// Creates fresh authority and immutable execution selections.
    ///
    /// Each event's handler runs once per emission, in commit order, on the main actor, after the commit and
    /// outside every lock, and before this batch offers its snapshot to existing registrations.
        internal init(_ initial: Cart = _StateMachineSchema.Cart(), drivers: MainActorDrivers, onTracked: @escaping @Swift::MainActor (Tracked.Payload) -> Swift::Void, onPinged: @escaping @Swift::MainActor () -> Swift::Void, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
            host = Host(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], configuration: configuration,
                policy: completionPolicy.runtime, driver: { raw in
        let execution: @Swift::MainActor () async -> Completion
        switch raw.descriptor {
                case .charge(let input):
                    execution = {
                    .charge(ChargeCompletion(value: await drivers.charge(input), request: ChargeRequest(input: input), authority: raw.ticket))
                }
                case .tracked, .pinged:
                    Swift::preconditionFailure("Only an operation is started.")
                }
        return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired, emit: { effect in
                switch effect {
                case .tracked(let payload):
                    onTracked(payload)
                case .pinged:
                    onPinged()
                case .charge:
                    break
                }
            })
        }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Cart = _StateMachineSchema.Cart(),
        chargeDriver: @escaping @Swift::MainActor (Charge.Input) async -> Charge.Output,
        onTracked: @escaping @Swift::MainActor (Tracked.Payload) -> Swift::Void, onPinged: @escaping @Swift::MainActor () -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: MainActorDrivers(charge: chargeDriver),
            onTracked: onTracked, onPinged: onPinged, configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation. Reading it registers a snapshot read with Observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// The current complete snapshot. Reading it registers a snapshot read with Observation.
internal var currentSnapshot: Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares, and admits one input in a single isolated turn without suspension.
    @discardableResult
    internal func send(_ input: Input) throws(SendRejection) -> Receipt {
        let result = host.prepareAndCommit { raw -> Swift::Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try _StateMachineSchema.prepare(input, on: _stateMachineSnapshot(raw))
            } catch {
                return .failure(.preparation(error))
            }
            switch prepared.candidate {
            case .candidate(let candidate):
                return .success(candidate)
            case .defective(let defect):
                return .failure(.commit(defect.rejection(against: raw)))
            }
        }
        switch result {
        case .success(.committed(let record)):
            return Receipt(record)
        case .success(.rejected(let reason, _)):
            throw .commit(reason)
        case .failure(let reason):
            throw reason
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    internal func commit(_ prepared: consuming Prepared) -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(host.commit(candidate))
        case .defective(let defect):
            return _stateMachineAdmission(host.reject(defect))
        }
    }
    /// Subscribes to initial, accepted, and terminal complete snapshots, taking a subscriber slot when called.
    internal func subscribe(_ receive: @escaping @Swift::MainActor (Snapshot) -> Swift::Void,
        onFinish: @escaping @Swift::MainActor () -> Swift::Void = {
        }) throws(SubscriptionFailure) -> MainActorSubscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots, taking a subscriber slot when called.
    ///
    /// It ends after the closed snapshot, when this owner is released, when its `cancel()` is
    /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.sendableSnapshots {
            _stateMachineSnapshot($0)
        }
    }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered, and the sequence offers each
    /// projection, equal to the one before it or not. It supports every `AsyncSequence` operator on
    /// every supported OS version. `distinctSnapshots(_:)` omits repeated values instead.
    internal func snapshots<Projection: Swift::Sendable>(
        _ transform: @escaping @Swift::MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.sendableSnapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
    /// omitting each projection equal to the one before it, taking a subscriber slot when called.
    ///
    /// `transform` and the comparison run on the main actor, outside every lock. A closed snapshot
    /// whose projection is unchanged is omitted too, and the sequence then ends.
    internal func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
        _ transform: @escaping @Swift::MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.distinctSendableSnapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    #if canImport(Combine)
    /// Registers a Combine publisher of complete snapshots, delivered on the main actor, taking a subscriber
    /// slot when called, before anything subscribes.
    ///
    /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
    /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
    /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
    /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
    /// one. When this owner is released without closing, it finishes at once and discards every
    /// ordinary value it has not yet delivered, so demand made after the release receives only the
    /// completion.
    @Swift::MainActor internal func snapshotPublisher() throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
        try host.snapshotPublisher {
        _stateMachineSnapshot($0)
    }
    }
    /// Registers a Combine publisher of `Sendable` projections of complete snapshots, delivered on
    /// the main actor, taking a subscriber slot when called, before anything subscribes.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered.
    /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
    /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
    /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
    /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
    /// one. When this owner is released without closing, it finishes at once and discards every
    /// ordinary value it has not yet delivered, so demand made after the release receives only the
    /// completion.
    @Swift::MainActor internal func snapshotPublisher<Projection: Swift::Sendable>(
        _ transform: @escaping @Swift::MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Projection> {
        try host.snapshotPublisher {
        transform(_stateMachineSnapshot($0))
    }
    }
    #endif
    /// Reads immutable retained first-outcome diagnostics.
internal func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions().map(PendingCompletion.init)
    }
    /// Registers a single-pass sequence of the retained completions, each element the whole collection, taking a subscriber slot when called.
    ///
    /// The first element is the collection current at registration, and each later element is the
    /// collection after a change, in the order of those changes. A newer collection replaces one
    /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
    /// when this owner is released, when its `cancel()` is called, or when a read finds its
    /// task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func pendingCompletionUpdates() throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.sendablePendingCompletionUpdates {
        $0.map(PendingCompletion.init)
    }
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs on the main actor with the whole collection after each change, starting with
    /// the collection current at registration. The sequence supports every `AsyncSequence` operator
    /// on every supported OS version, and ends after the projection of the final, empty collection.
    internal func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping @Swift::MainActor ([PendingCompletion]) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.sendablePendingCompletionUpdates {
        transform($0.map(PendingCompletion.init))
    }
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcileReportingRefusal(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Checkout, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
        if let refusal = result.refusal, case .pending(let id, .reconciliationRequired) = result.delivery {
            return _stateMachineRefused(id, refusal.failure, on: refusal.snapshot)
        }
        switch result.delivery {
        case .committed(let record):
        return .committed(Receipt(record))
        case .pending(let id, let status):
        return .pending(PendingCompletionID(raw: id), status)
        case .inProgress:
        return .inProgress
        default:
        return .notPending
        }
    }
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Checkout, Effect>) -> DiscardResult {
        switch result {
        case .discarded(let record):
        return .discarded(Receipt(record))
        case .rejected(let reason):
        return .rejected(reason)
        default:
        return .notPending
        }
    }
    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close() -> Receipt {
        Receipt(host.close())
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// Every outstanding operation is revoked, with its cancellation published in the reset's
    /// batch, and every retained completion is disposed of, so a late result is stale. The owner
    /// keeps its identity and subscribers, and its revision advances. Work that is still running
    /// keeps its execution reservation until it terminates.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)])
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
    /// still holds the root `expected` observed, so a decision made on that snapshot cannot
    /// discard a change accepted since.
    ///
    /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
    /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
    /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
    /// other acceptance, and then the same errors as `reset(to:)`.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed, and every event handler they call has returned.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    internal var runningCount: Swift::Int {
        host.runningCount
    }
    /// The count of live observer registrations. Reading it registers a count read with Observation.
    internal var subscriberCount: Swift::Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    internal var isQuiescent: Swift::Bool {
        host.isQuiescent
    }
}

/// Immutable typed execution selection for one managed owner's lifetime.
internal struct Drivers: Swift::Sendable {
    /// Executes one typed operation outside admission locks.
internal let charge: @Sendable (Charge.Input) async -> Charge.Output
    /// Selects all drivers for this owner.
    internal init(charge: @escaping @Sendable (Charge.Input) async -> Charge.Output) {
        self.charge = charge
    }
}

/// A synchronous shared owner with managed physical execution and terminal delivery.
internal final class Shared: Swift::Sendable, StateMachine::SharedStateMachineHost {
    private typealias Host = StateMachine::RuntimeSharedHost<Checkout, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That behaves like the result arriving a moment later, when its edge would run against
    /// the newer phase anyway. Work that must not survive a change is revoked by the edge's
    /// `invalidates:` instead. `.manual` never prepares a completion again on its own. Either form
    /// can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion enters
    /// `reconciliationRequired`. This happens when its completion edge or router throws, its
    /// effect plan is defective, the owner refuses its admission, an explicit `reconcile(id:)`
    /// does not commit, or, under `.manual`, its preparation loses a race. Settle it with
    /// `reconcile(id:)` or `discardPending(id:)`.
    internal struct CompletionPolicy: Swift::Sendable {
        fileprivate let runtime: StateMachine::RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: @Sendable (_StateMachineLedger.Pending) -> Swift::Void
        private init(_ runtime: StateMachine::RuntimeCompletionPolicy, handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it when every completion edge and router is deterministic and free of side
        /// effects, since the compiler does not enforce that. A completion retained for any other
        /// reason stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
        /// Creates fresh initial authority and retains the driver selection immutably.
    ///
    /// Each event's handler runs once per emission, in commit order, from the serial turn that processes its batch, after the commit and
    /// outside every lock, and before this batch offers its snapshot to existing registrations.
        internal init(_ initial: Cart = _StateMachineSchema.Cart(), drivers: Drivers, onTracked: @escaping @Sendable (Tracked.Payload) -> Swift::Void, onPinged: @escaping @Sendable () -> Swift::Void, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
            host = Host(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
                policy: completionPolicy.runtime, driver: { raw in
        let execution: @Sendable () async -> Completion
        switch raw.descriptor {
                case .charge(let input):
                    execution = {
                    .charge(ChargeCompletion(value: await drivers.charge(input), request: ChargeRequest(input: input), authority: raw.ticket))
                }
                case .tracked, .pinged:
                    Swift::preconditionFailure("Only an operation is started.")
                }
        return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired, emit: { effect in
                switch effect {
                case .tracked(let payload):
                    onTracked(payload)
                case .pinged:
                    onPinged()
                case .charge:
                    break
                }
            })
        }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Cart = _StateMachineSchema.Cart(),
        chargeDriver: @escaping @Sendable (Charge.Input) async -> Charge.Output,
        onTracked: @escaping @Sendable (Tracked.Payload) -> Swift::Void, onPinged: @escaping @Sendable () -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: Drivers(charge: chargeDriver),
            onTracked: onTracked, onPinged: onPinged, configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a coherent historical observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Registers a serial capacity-one latest-value observation callback, taking a subscriber slot when called.
    internal func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Swift::Void,
        onFinish: @escaping @Sendable () -> Swift::Void = {
        }) throws(SubscriptionFailure) -> Subscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots, taking a subscriber slot when called.
    ///
    /// It ends after the closed snapshot, when this owner is released, when its `cancel()` is
    /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
    /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs on the registration's serial delivery path, outside every lock, and the
    /// sequence offers each projection, equal to the one before it or not. `distinctSnapshots(_:)`
    /// omits repeated values instead.
    internal func snapshots<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.snapshots {
            transform(_stateMachineSnapshot($0))
        }
    }
    /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
    /// omitting each projection equal to the one before it, taking a subscriber slot when called.
    ///
    /// `transform` and the comparison run on the registration's serial delivery path, outside every
    /// lock. A closed snapshot whose projection is unchanged is omitted too, and the sequence then ends.
    internal func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.distinctSnapshots {
            transform(_stateMachineSnapshot($0))
        }
    }
    #if canImport(Combine)
    /// Registers a Combine publisher of complete snapshots, delivered on the main actor, taking a subscriber
    /// slot when called, before anything subscribes.
    ///
    /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
    /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
    /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
    /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
    /// one. When this owner is released without closing, it finishes at once and discards every
    /// ordinary value it has not yet delivered, so demand made after the release receives only the
    /// completion.
    @Swift::MainActor internal func snapshotPublisher() throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
        try host.snapshotPublisher {
        _stateMachineSnapshot($0)
    }
    }
    /// Registers a Combine publisher of `Sendable` projections of complete snapshots, delivered on
    /// the main actor, taking a subscriber slot when called, before anything subscribes.
    ///
    /// `transform` runs on the registration's serial delivery path, outside every lock, when a snapshot is delivered.
    /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
    /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
    /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
    /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
    /// one. When this owner is released without closing, it finishes at once and discards every
    /// ordinary value it has not yet delivered, so demand made after the release receives only the
    /// completion.
    @Swift::MainActor internal func snapshotPublisher<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Projection> {
        try host.snapshotPublisher {
        transform(_stateMachineSnapshot($0))
    }
    }
    #endif
    /// Routes, prepares, and admits one input in a single attempt.
    ///
    /// Preparation runs outside the lock against one snapshot and is never repeated, so
    /// a concurrent commit surfaces as `.commit(.conflict)` for the caller to resolve.
    @discardableResult
    internal func send(_ input: Input) throws(SendRejection) -> Receipt {
        let prepared: Prepared
        do {
            prepared = try _StateMachineSchema.prepare(input, on: snapshot())
        } catch {
            throw .preparation(error)
        }
        switch commit(prepared) {
        case .committed(let receipt):
            return receipt
        case .rejected(let reason, _):
            throw .commit(reason)
        }
    }
    /// Consumes one candidate into an atomic admission attempt.
    internal func commit(_ prepared: consuming Prepared) -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(host.commit(candidate))
        case .defective(let defect):
            return _stateMachineAdmission(host.reject(defect))
        }
    }
    /// Reads immutable retained first-outcome diagnostics.
internal func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions().map(PendingCompletion.init)
    }
    /// Registers a single-pass sequence of the retained completions, each element the whole collection, taking a subscriber slot when called.
    ///
    /// The first element is the collection current at registration, and each later element is the
    /// collection after a change, in the order of those changes. A newer collection replaces one
    /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
    /// when this owner is released, when its `cancel()` is called, or when a read finds its
    /// task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func pendingCompletionUpdates() throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.pendingCompletionUpdates {
        $0.map(PendingCompletion.init)
    }
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs on the registration's serial delivery path, outside every lock, with the whole collection after each change, starting with
    /// the collection current at registration. The sequence supports every `AsyncSequence` operator
    /// on every supported OS version, and ends after the projection of the final, empty collection.
    internal func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable ([PendingCompletion]) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.pendingCompletionUpdates {
        transform($0.map(PendingCompletion.init))
    }
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcileReportingRefusal(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeSharedHost<Checkout, Effect, Completion, PreparationRejection>.Delivery, refusal: Host.Refusal?)) -> ReconcileResult {
        if let refusal = result.refusal, case .pending(let id, .reconciliationRequired) = result.delivery {
            return _stateMachineRefused(id, refusal.failure, on: refusal.snapshot)
        }
        switch result.delivery {
        case .committed(let record):
        return .committed(Receipt(record))
        case .pending(let id, let status):
        return .pending(PendingCompletionID(raw: id), status)
        case .inProgress:
        return .inProgress
        default:
        return .notPending
        }
    }
    private static func discarded(_ result: StateMachine::RuntimeSharedHost<Checkout, Effect, Completion, PreparationRejection>.Delivery) -> DiscardResult {
        switch result {
        case .discarded(let record):
        return .discarded(Receipt(record))
        case .rejected(let reason):
        return .rejected(reason)
        default:
        return .notPending
        }
    }
    /// Ends admission and schedules cancellation in FIFO order.
    @discardableResult
    internal func close() -> Receipt {
        Receipt(host.close())
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// Every outstanding operation is revoked, with its cancellation published in the reset's
    /// batch, and every retained completion is disposed of, so a late result is stale. The owner
    /// keeps its identity and subscribers, and its revision advances. Work that is still running
    /// keeps its execution reservation until it terminates.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)])
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
    /// still holds the root `expected` observed, so a decision made on that snapshot cannot
    /// discard a change accepted since.
    ///
    /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
    /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
    /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
    /// other acceptance, and then the same errors as `reset(to:)`.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed, and every event handler they call has returned.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    internal var runningCount: Swift::Int {
        host.runningCount
    }
    /// Live observer registrations.
    internal var subscriberCount: Swift::Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    internal var isQuiescent: Swift::Bool {
        host.isQuiescent
    }
}

/// A sealed sole-writer native actor owner with managed execution.
internal final class ActorHost: Swift::Sendable, StateMachine::ActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeActorHost<Checkout, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That behaves like the result arriving a moment later, when its edge would run against
    /// the newer phase anyway. Work that must not survive a change is revoked by the edge's
    /// `invalidates:` instead. `.manual` never prepares a completion again on its own. Either form
    /// can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion enters
    /// `reconciliationRequired`. This happens when its completion edge or router throws, its
    /// effect plan is defective, the owner refuses its admission, an explicit `reconcile(id:)`
    /// does not commit, or, under `.manual`, its preparation loses a race. Settle it with
    /// `reconcile(id:)` or `discardPending(id:)`.
    internal struct CompletionPolicy: Swift::Sendable {
        fileprivate let runtime: StateMachine::RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: @Sendable (_StateMachineLedger.Pending) -> Swift::Void
        private init(_ runtime: StateMachine::RuntimeCompletionPolicy, handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it when every completion edge and router is deterministic and free of side
        /// effects, since the compiler does not enforce that. A completion retained for any other
        /// reason stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
        /// Creates fresh authority and immutable execution selections.
    ///
    /// Each event's handler runs once per emission, in commit order, on this owner's actor, after the commit and
    /// outside every lock, and before this batch offers its snapshot to existing registrations.
    ///
    /// With `isolatedTo`, the owner's actor runs on that actor's serial executor so their turns
    /// never overlap, though calls into the owner still await.
        internal init(_ initial: Cart = _StateMachineSchema.Cart(), drivers: Drivers, onTracked: @escaping @Sendable (Tracked.Payload) -> Swift::Void, onPinged: @escaping @Sendable () -> Swift::Void, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry, isolatedTo: (any Swift::Actor)? = nil) {
            host = Host(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], configuration: configuration,
                policy: completionPolicy.runtime, driver: { raw in
        let execution: @Sendable () async -> Completion
        switch raw.descriptor {
                case .charge(let input):
                    execution = {
                    .charge(ChargeCompletion(value: await drivers.charge(input), request: ChargeRequest(input: input), authority: raw.ticket))
                }
                case .tracked, .pinged:
                    Swift::preconditionFailure("Only an operation is started.")
                }
        return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired, emit: { effect in
                switch effect {
                case .tracked(let payload):
                    onTracked(payload)
                case .pinged:
                    onPinged()
                case .charge:
                    break
                }
            }, isolatedTo: isolatedTo)
        }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Cart = _StateMachineSchema.Cart(),
        chargeDriver: @escaping @Sendable (Charge.Input) async -> Charge.Output,
        onTracked: @escaping @Sendable (Tracked.Payload) -> Swift::Void, onPinged: @escaping @Sendable () -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry,
        isolatedTo: (any Swift::Actor)? = nil) {
        self.init(initial, drivers: Drivers(charge: chargeDriver),
            onTracked: onTracked, onPinged: onPinged, configuration: configuration, completionPolicy: completionPolicy, isolatedTo: isolatedTo)
    }
    /// Captures a complete historical observation.
    internal func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }

    /// Routes, prepares, and admits one input in a single isolated turn without suspension.
    @discardableResult
    internal func send(_ input: Input) async throws(SendRejection) -> Receipt {
        let result = await host.prepareAndCommit { raw -> Swift::Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try _StateMachineSchema.prepare(input, on: _stateMachineSnapshot(raw))
            } catch {
                return .failure(.preparation(error))
            }
            switch prepared.candidate {
            case .candidate(let candidate):
                return .success(candidate)
            case .defective(let defect):
                return .failure(.commit(defect.rejection(against: raw)))
            }
        }
        switch result {
        case .success(.committed(let record)):
            return Receipt(record)
        case .success(.rejected(let reason, _)):
            throw .commit(reason)
        case .failure(let reason):
            throw reason
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    internal func commit(_ prepared: consuming Prepared) async -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(await host.commit(candidate))
        case .defective(let defect):
            return _stateMachineAdmission(await host.reject(defect))
        }
    }
    /// Subscribes to initial, accepted, and terminal complete snapshots, taking a subscriber slot when called.
    internal func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Swift::Void,
        onFinish: @escaping @Sendable () -> Swift::Void = {
        }) async throws(SubscriptionFailure) -> Subscription {
        try await host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots, taking a subscriber slot when called.
    ///
    /// It ends after the closed snapshot, when this owner is released, when its `cancel()` is
    /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func snapshots() async throws(SubscriptionFailure) -> Snapshots {
        try await host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs in this owner's actor turn when a snapshot is delivered, and the sequence offers each
    /// projection, equal to the one before it or not. It supports every `AsyncSequence` operator on
    /// every supported OS version. `distinctSnapshots(_:)` omits repeated values instead.
    internal func snapshots<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try await host.snapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
    /// omitting each projection equal to the one before it, taking a subscriber slot when called.
    ///
    /// `transform` and the comparison run in this owner's actor turn, outside every lock. A closed snapshot
    /// whose projection is unchanged is omitted too, and the sequence then ends.
    internal func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try await host.distinctSnapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    #if canImport(Combine)
    /// Registers a Combine publisher of complete snapshots, delivered on the main actor, taking a subscriber
    /// slot when called, before anything subscribes.
    ///
    /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
    /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
    /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
    /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
    /// one. When this owner is released without closing, it finishes at once and discards every
    /// ordinary value it has not yet delivered, so demand made after the release receives only the
    /// completion.
    @Swift::MainActor internal func snapshotPublisher() async throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
        try await host.snapshotPublisher {
        _stateMachineSnapshot($0)
    }
    }
    /// Registers a Combine publisher of `Sendable` projections of complete snapshots, delivered on
    /// the main actor, taking a subscriber slot when called, before anything subscribes.
    ///
    /// `transform` runs in this owner's actor turn when a snapshot is delivered.
    /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
    /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
    /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
    /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
    /// one. When this owner is released without closing, it finishes at once and discards every
    /// ordinary value it has not yet delivered, so demand made after the release receives only the
    /// completion.
    @Swift::MainActor internal func snapshotPublisher<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Projection> {
        try await host.snapshotPublisher {
        transform(_stateMachineSnapshot($0))
    }
    }
    #endif
    /// Reads immutable retained first-outcome diagnostics.
internal func pendingCompletions() async -> [PendingCompletion] {
        await host.pendingCompletions().map(PendingCompletion.init)
    }
    /// Registers a single-pass sequence of the retained completions, each element the whole collection, taking a subscriber slot when called.
    ///
    /// The first element is the collection current at registration, and each later element is the
    /// collection after a change, in the order of those changes. A newer collection replaces one
    /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
    /// when this owner is released, when its `cancel()` is called, or when a read finds its
    /// task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func pendingCompletionUpdates() async throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try await host.pendingCompletionUpdates {
        $0.map(PendingCompletion.init)
    }
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs in this owner's actor turn with the whole collection after each change, starting with
    /// the collection current at registration. The sequence supports every `AsyncSequence` operator
    /// on every supported OS version, and ends after the projection of the final, empty collection.
    internal func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable ([PendingCompletion]) -> Projection
    ) async throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try await host.pendingCompletionUpdates {
        transform($0.map(PendingCompletion.init))
    }
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID) async -> ReconcileResult {
        Self.reconciled(await host.reconcileReportingRefusal(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) async -> DiscardResult {
        Self.discarded(await host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Checkout, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
        if let refusal = result.refusal, case .pending(let id, .reconciliationRequired) = result.delivery {
            return _stateMachineRefused(id, refusal.failure, on: refusal.snapshot)
        }
        switch result.delivery {
        case .committed(let record):
        return .committed(Receipt(record))
        case .pending(let id, let status):
        return .pending(PendingCompletionID(raw: id), status)
        case .inProgress:
        return .inProgress
        default:
        return .notPending
        }
    }
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Checkout, Effect>) -> DiscardResult {
        switch result {
        case .discarded(let record):
        return .discarded(Receipt(record))
        case .rejected(let reason):
        return .rejected(reason)
        default:
        return .notPending
        }
    }
    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close() async -> Receipt {
        Receipt(await host.close())
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// Every outstanding operation is revoked, with its cancellation published in the reset's
    /// batch, and every retained completion is disposed of, so a late result is stale. The owner
    /// keeps its identity and subscribers, and its revision advances. Work that is still running
    /// keeps its execution reservation until it terminates.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart()) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)])
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
    /// still holds the root `expected` observed, so a decision made on that snapshot cannot
    /// discard a change accepted since.
    ///
    /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
    /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
    /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
    /// other acceptance, and then the same errors as `reset(to:)`.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart(), expecting expected: Snapshot) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed, and every event handler they call has returned.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    internal var runningCount: Swift::Int {
        get async {
            await host.runningCount
        }
    }
    /// The count of live observer registrations.
    internal var subscriberCount: Swift::Int {
        get async {
            await host.subscriberCount
        }
    }
    /// Whether closure and all managed obligations have settled.
    internal var isQuiescent: Swift::Bool {
        get async {
            await host.isQuiescent
        }
    }
}

/// A sealed sole-writer owner confined to one actor instance, with managed execution.
///
/// Create it on the actor that owns it, as `IsolatedHost(isolation: self, …)`, and keep it there.
/// It is not `Sendable`, so the compiler keeps it in that actor's region, and every method takes
/// the actor as a defaulted `isolated` parameter. Inside the actor, calls read `host.send(input)`,
/// while calls from another actor or a nonisolated context do not compile. A method that receives
/// a different instance of the actor's type stops the program.
///
/// Drivers and event handlers run on the owning actor and receive it isolated, so they can read and
/// change its state without capturing the actor.
/// Its observation callbacks and the completion policy's handler run there too.
///
/// The host holds its actor weakly, so an idle actor that stores it is released with it. A running
/// driver retains the actor while it runs on it. Calling `close()` or `shutdown()` requests
/// cancellation of running drivers, and the actor is released after each driver returns. A closure
/// that captures the actor keeps it alive while the host or registration holding the closure lasts,
/// so a driver or handler, which the host holds for its lifetime, should use the actor it receives
/// instead.
internal final class IsolatedHost<Owner: Swift::Actor>: StateMachine::IsolatedStateMachineHost {
    private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, Checkout, Effect, Completion, PreparationRejection>
    private let host: Host
        /// Immutable operation selections, each run on the owning actor, which it receives isolated.
    ///
    /// A driver reaches the actor's state through that parameter, so it captures nothing confined.
    internal struct Drivers: Swift::Sendable {
        /// Executes this operation on the owning actor, which it receives isolated.
    internal let charge: @Sendable (isolated Owner, Charge.Input) async -> Charge.Output
        /// Selects every driver for this owner's lifetime.
        internal init(charge: @escaping @Sendable (isolated Owner, Charge.Input) async -> Charge.Output) {
        self.charge = charge
    }
    }
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That behaves like the result arriving a moment later, when its edge would run against
    /// the newer phase anyway. Work that must not survive a change is revoked by the edge's
    /// `invalidates:` instead. `.manual` never prepares a completion again on its own. Either form
    /// can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion enters
    /// `reconciliationRequired`. This happens when its completion edge or router throws, its
    /// effect plan is defective, the owner refuses its admission, an explicit `reconcile(id:)`
    /// does not commit, or, under `.manual`, its preparation loses a race. Settle it with
    /// `reconcile(id:)` or `discardPending(id:)`.
    internal struct CompletionPolicy {
        fileprivate let runtime: StateMachine::RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: (_StateMachineLedger.Pending) -> Swift::Void
        private init(_ runtime: StateMachine::RuntimeCompletionPolicy, handler: @escaping (PendingCompletion) -> Swift::Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it when every completion edge and router is deterministic and free of side
        /// effects, since the compiler does not enforce that. A completion retained for any other
        /// reason stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
        /// Creates fresh authority confined to `isolation`, with immutable execution selections.
    ///
    /// Each event's handler runs once per emission, in commit order, on the owning actor, which it receives isolated, after the commit and
    /// outside every lock, and before this batch offers its snapshot to existing registrations.
        internal init(_ initial: Cart = _StateMachineSchema.Cart(), isolation: isolated Owner, drivers: Drivers, onTracked: @escaping @Sendable (isolated Owner, Tracked.Payload) -> Swift::Void, onPinged: @escaping @Sendable (isolated Owner) -> Swift::Void, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
            host = Host(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], isolation: isolation, configuration: configuration,
                policy: completionPolicy.runtime, driver: { owner, raw in
        let execution: () async -> Completion
        switch raw.descriptor {
                case .charge(let input):
                    execution = {
                    .charge(ChargeCompletion(value: await drivers.charge(owner, input), request: ChargeRequest(input: input), authority: raw.ticket))
                }
                case .tracked, .pinged:
                    Swift::preconditionFailure("Only an operation is started.")
                }
        return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired, emit: { owner, effect in
                switch effect {
                case .tracked(let payload):
                    onTracked(owner, payload)
                case .pinged:
                    onPinged(owner)
                case .charge:
                    break
                }
            })
        }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Cart = _StateMachineSchema.Cart(),
        isolation: isolated Owner,
        chargeDriver: @escaping @Sendable (isolated Owner, Charge.Input) async -> Charge.Output,
        onTracked: @escaping @Sendable (isolated Owner, Tracked.Payload) -> Swift::Void, onPinged: @escaping @Sendable (isolated Owner) -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, isolation: isolation, drivers: Drivers(charge: chargeDriver),
            onTracked: onTracked, onPinged: onPinged, configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    internal func snapshot(isolation: isolated Owner = #isolation) -> Snapshot {
        _stateMachineSnapshot(host.snapshot(isolation: isolation))
    }
    /// Routes, prepares, and admits one input in a single turn of the owning actor, without suspension.
    @discardableResult
    internal func send(_ input: Input, isolation: isolated Owner = #isolation) throws(SendRejection) -> Receipt {
        let result = host.prepareAndCommit(isolation: isolation) { raw -> Swift::Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try _StateMachineSchema.prepare(input, on: _stateMachineSnapshot(raw))
            } catch {
                return .failure(.preparation(error))
            }
            switch prepared.candidate {
            case .candidate(let candidate):
                return .success(candidate)
            case .defective(let defect):
                return .failure(.commit(defect.rejection(against: raw)))
            }
        }
        switch result {
        case .success(.committed(let record)):
            return Receipt(record)
        case .success(.rejected(let reason, _)):
            throw .commit(reason)
        case .failure(let reason):
            throw reason
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    internal func commit(_ prepared: consuming Prepared, isolation: isolated Owner = #isolation) -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(host.commit(candidate, isolation: isolation))
        case .defective(let defect):
            return _stateMachineAdmission(host.reject(defect, isolation: isolation))
        }
    }
    /// Subscribes to initial, accepted, and terminal complete snapshots, delivered on the owning actor, taking a subscriber slot when called.
    ///
    /// The registration stays in the owning actor's region, and only that actor can cancel it, which
    /// removes the registration before returning, so none of its callbacks begins afterward. Cancelling
    /// releases the callbacks before it returns, except while this owner is delivering a change, such
    /// as when another observer's callback cancels. That delivery keeps the callbacks it selected until
    /// it finishes delivering the change to its other observers, and releases them then. Dropping the
    /// registration stops delivery and frees its slot at once, and this owner releases its callbacks
    /// when it next sweeps its registrations or is destroyed.
    internal func subscribe(_ receive: @escaping (Snapshot) -> Swift::Void,
        onFinish: @escaping () -> Swift::Void = {
        }, isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> IsolatedSubscription<Owner> {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish, isolation: isolation)
    }
    /// Registers a single-pass sequence of the latest complete snapshots, taking a subscriber slot when called.
    ///
    /// It ends after the closed snapshot, when this owner is released, when its `cancel()` is
    /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func snapshots(isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> Snapshots {
        try host.sendableSnapshots({
                _stateMachineSnapshot($0)
            }, isolation: isolation)
    }
    /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs on the owning actor when a snapshot is delivered, and the sequence offers
    /// each projection, equal to the one before it or not. It supports every `AsyncSequence`
    /// operator and may be consumed anywhere. `distinctSnapshots(_:)` omits repeated values instead.
    /// Ending it on another actor stops delivery and frees its slot at once, and this owner releases
    /// `transform` when it next sweeps its registrations or is destroyed.
    internal func snapshots<Projection: Swift::Sendable>(
        _ transform: @escaping (Snapshot) -> Projection, isolation: isolated Owner = #isolation
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.sendableSnapshots({
                transform(_stateMachineSnapshot($0))
            }, isolation: isolation)
    }
    /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
    /// omitting each projection equal to the one before it, taking a subscriber slot when called.
    ///
    /// `transform` and the comparison run on the owning actor. A closed snapshot whose projection
    /// is unchanged is omitted too, and the sequence then ends.
    internal func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
        _ transform: @escaping (Snapshot) -> Projection, isolation: isolated Owner = #isolation
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.distinctSendableSnapshots({
                transform(_stateMachineSnapshot($0))
            }, isolation: isolation)
    }
    /// Reads immutable retained first-outcome diagnostics.
internal func pendingCompletions(isolation: isolated Owner = #isolation) -> [PendingCompletion] {
    host.pendingCompletions(isolation: isolation).map(PendingCompletion.init)
    }
    /// Registers a single-pass sequence of the retained completions, each element the whole collection, taking a subscriber slot when called.
    ///
    /// The first element is the collection current at registration, and each later element is the
    /// collection after a change, in the order of those changes. A newer collection replaces one
    /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
    /// when this owner is released, when its `cancel()` is called, or when a read finds its
    /// task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` from any isolation domain, which frees its subscriber slot before it
    /// returns. A read that already received an element still returns it.
    internal func pendingCompletionUpdates(isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.sendablePendingCompletionUpdates({
            $0.map(PendingCompletion.init)
        }, isolation: isolation)
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs on the owning actor with the whole collection after each change, starting
    /// with the collection current at registration. The sequence supports every `AsyncSequence`
    /// operator, may be consumed anywhere, and ends after the projection of the final, empty collection.
    internal func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping ([PendingCompletion]) -> Projection, isolation: isolated Owner = #isolation
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.sendablePendingCompletionUpdates({
            transform($0.map(PendingCompletion.init))
        }, isolation: isolation)
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID, isolation: isolated Owner = #isolation) -> ReconcileResult {
        Self.reconciled(host.reconcileReportingRefusal(id: id.raw, isolation: isolation))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID, isolation: isolated Owner = #isolation) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw, isolation: isolation))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Checkout, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
        if let refusal = result.refusal, case .pending(let id, .reconciliationRequired) = result.delivery {
            return _stateMachineRefused(id, refusal.failure, on: refusal.snapshot)
        }
        switch result.delivery {
        case .committed(let record):
        return .committed(Receipt(record))
        case .pending(let id, let status):
        return .pending(PendingCompletionID(raw: id), status)
        case .inProgress:
        return .inProgress
        default:
        return .notPending
        }
    }
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Checkout, Effect>) -> DiscardResult {
        switch result {
        case .discarded(let record):
        return .discarded(Receipt(record))
        case .rejected(let reason):
        return .rejected(reason)
        default:
        return .notPending
        }
    }
    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close(isolation: isolated Owner = #isolation) -> Receipt {
        Receipt(host.close(isolation: isolation))
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// Every outstanding operation is revoked, with its cancellation published in the reset's
    /// batch, and every retained completion is disposed of, so a late result is stale. The owner
    /// keeps its identity and subscribers, and its revision advances. Work that is still running
    /// keeps its execution reservation until it terminates.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart(), isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
    /// still holds the root `expected` observed, so a decision made on that snapshot cannot
    /// discard a change accepted since.
    ///
    /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
    /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
    /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
    /// other acceptance, and then the same errors as `reset(to:)`.
    @discardableResult
    internal func reset(to initial: Cart = _StateMachineSchema.Cart(), expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.cart(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed, and every event handler they call has returned.
internal func flush(through receipt: Receipt, isolation: isolated Owner = #isolation) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record, isolation: isolation) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil, isolation: isolated Owner = #isolation) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline, isolation: isolation))
    }
    /// Actual workers whose joined termination has not yet been processed, read on the owning actor.
    internal func runningCount(isolation: isolated Owner = #isolation) -> Swift::Int {
        host.runningCount(isolation: isolation)
    }
    /// Live observer registrations, read on the owning actor.
    internal func subscriberCount(isolation: isolated Owner = #isolation) -> Swift::Int {
        host.subscriberCount(isolation: isolation)
    }
    /// Whether closure and all managed obligations have settled, read on the owning actor.
    internal func isQuiescent(isolation: isolated Owner = #isolation) -> Swift::Bool {
        host.isQuiescent(isolation: isolation)
    }
}

fileprivate typealias _StateMachineGraph = StateMachine::StateMachineGraph

/// The declared phases, inputs, scopes, operations, events, edges, and routers of this graph,
/// without payloads or authority.
internal nonisolated static let graph: StateMachine::StateMachineGraph = _stateMachineGraph()

nonisolated private static func _stateMachineGraph() -> StateMachine::StateMachineGraph {
    var phases: [_StateMachineGraph.Phase] = []
    phases.append(_StateMachineGraph.Phase(id: "cart", payload: "Cart"))
    phases.append(_StateMachineGraph.Phase(id: "paying", payload: "Paying"))
    phases.append(_StateMachineGraph.Phase(id: "confirming", payload: "Confirming"))
    phases.append(_StateMachineGraph.Phase(id: "paid", payload: "Paid"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "add", payload: "String"))
    inputs.append(_StateMachineGraph.Input(id: "pay", payload: nil))
    inputs.append(_StateMachineGraph.Input(id: "confirm", payload: nil))
    var scopes: [_StateMachineGraph.Scope] = []
    scopes.append(_StateMachineGraph.Scope(id: "payment", activeIn: ["paying", "confirming"]))
    scopes.append(_StateMachineGraph.Scope(id: "session", activeIn: ["cart", "paying", "confirming", "paid"]))
    var operations: [_StateMachineGraph.Operation] = []
    operations.append(_StateMachineGraph.Operation(id: "Charge", effect: "charge", scope: "payment",
        requires: ["session"], activeIn: ["paying", "confirming"], admission: .latest,
        key: nil, input: "[String]", output: "String",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    var events: [_StateMachineGraph.Event] = []
    events.append(_StateMachineGraph.Event(id: "Tracked", effect: "tracked", payload: "String"))
    events.append(_StateMachineGraph.Event(id: "Pinged", effect: "pinged", payload: "Swift::Void"))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "cart.add", name: "add",
        source: "cart", destination: "cart", trigger: .input("add"),
        router: nil, starts: [],
        cancels: [],
        emits: ["Tracked"], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "cart.pay", name: "pay",
        source: "cart", destination: "paying", trigger: .input("pay"),
        router: nil, starts: ["Charge"],
        cancels: [],
        emits: ["Tracked", "Pinged"], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "paying.confirm", name: "confirm",
        source: "paying", destination: "confirming", trigger: .input("confirm"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "paying.charged", name: "charged",
        source: "paying", destination: "paid", trigger: .success("Charge"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "confirming.charged", name: "charged",
        source: "confirming", destination: "paid", trigger: .success("Charge"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    return .init(
        name: "Checkout",
        mode: .shared,
        owners: [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost],
        initial: "cart",
        terminal: ["paid"],
        restorable: [],
        phases: phases,
        inputs: inputs,
        scopes: scopes,
        operations: operations,
        events: events,
        edges: edges,
        routers: []
    )
}
fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Swift::Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Swift::Copyable> {
}

fileprivate struct _RouterSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Swift::Sendable & ~Swift::Copyable> {
}

fileprivate struct _OperationFailureIsError<Value: Swift::Error> {
}

fileprivate struct _OperationKeyIsHashable<Value: Swift::Hashable & Swift::Sendable> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

/// The schema type, used by generated code where a local value could shadow its name.
internal typealias _StateMachineSchema = Tally

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Tally' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Tally'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate enum _StateMachineReadsNever {
}

fileprivate static func _stateMachineNeverProbe<Value: ~Swift::Copyable>(_ type: Value.Type) -> Swift::Bool {
    true
}

fileprivate static func _stateMachineNeverProbe(_ type: Swift::Never.Type) -> _StateMachineReadsNever.Type {
    _StateMachineReadsNever.self
}

fileprivate static func _stateMachineIsNotSwiftNever(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Event 'Counted' carries Never, so no transition can emit it; declare a payload type that has values, or remove the event.")
fileprivate static func _stateMachineIsNotSwiftNever(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    do {
        typealias _StateMachineChecked = Counted.Payload;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    let _: _TransitionSourceIsPhasePayload<Counting> = _TransitionSourceIsPhasePayload<Counting>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Counting, Effect.Add>> = _TransitionReturnsDeclaredResult<Change<Counting, Effect.Add>>()


    let _ = _EffectIsCopyable<Effect>()

}

/// Inert descriptions of the operations this workflow can start and the events it can emit.
internal enum Effect: ~Swift::Sendable {
    case counted(Tally.Counted.Payload)
    /// The events `add` may emit.
internal enum Add: ~Swift::Sendable {
    case counted(Tally.Counted.Payload)
    /// The schema-wide effect this value describes.
    internal var effect: Tally.Effect {
        switch self {
        case .counted(let payload):
            return .counted(payload)
        }
    }
    }
    /// The effect vocabularies of the edges from `Counting`.
    internal enum Counting {
        internal typealias Add = Tally.Effect.Add
    }
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Tally, Effect>

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = StateMachine::Limits

/// Why an owner refused a prepared candidate, in precedence order.
internal typealias CommitRejection = StateMachine::CommitRejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase>: Swift::CustomStringConvertible {
    fileprivate let payload: Phase
    fileprivate let record: _StateMachineEngine.Snapshot
    fileprivate let claim: StateMachine::RuntimeDeliveryClaim?
    /// The copied historical payload.
    internal var value: Phase {
        payload
    }
    /// The owner-lifetime accepted revision.
    internal var revision: Swift::UInt64 {
        record.revision
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        "\(Phase.self), revision \(record.revision)\(record.isClosed ? ", closed" : "")"
    }
    /// Prepares the declared edge with phase authority preserved.
internal func add() -> Prepared where Phase == Counting {
    let change: StateMachine::Change<Counting, Effect.Add> = _StateMachineSchema.add(payload)
    return _stateMachinePrepare(on: record, next: .counting(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 0, invalidates: [],
        requiring: nil, claim: claim, edge: "counting.add")
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
    case counting(Observed<Counting>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .counting(let value):
            return value.record
        }
    }
    /// The accepted revision of this observation.
    internal var revision: Swift::UInt64 {
        record.revision
    }
    /// Whether this historical root records closure.
    internal var isClosed: Swift::Bool {
        record.isClosed
    }
    /// The ordinary model data. Constructing a model value directly confers no installation authority.
    internal var model: Tally {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        switch self {
        case .counting(let value):
            return "counting, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .counting(let payload):
        return .counting(Observed(payload: payload, record: record, claim: claim))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .counting:
        return "counting"
    }
}

fileprivate static func _stateMachineRefusingRoute(_ rejection: PreparationRejection, in phase: Swift::String) -> Swift::String? {
    nil
}

/// A sealed inert candidate consumed by admission.
///
/// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
/// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
/// another owner's or the owner is closed, which it reports first.
internal struct Prepared: ~Swift::Copyable {
    fileprivate let candidate: _StateMachineEngine.Proposal
    fileprivate init(_ candidate: _StateMachineEngine.Proposal) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
internal enum PreparationRejection: Swift::Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase

}

/// A historical receipt for an atomic acceptance.
internal struct Receipt: StateMachine::StateMachineReceipt, Swift::CustomStringConvertible {
    /// The accepted historical observation.
    internal let snapshot: Snapshot
    fileprivate init(_ record: _StateMachineEngine.Snapshot) {
        snapshot = _stateMachineSnapshot(record)
        edgeID = record.edge
    }
    /// The identifier of the graph edge the acceptance took, as `graph` names it, or `nil` for a
    /// change that takes no edge, such as a reset, closure, or the authority-only commit of
    /// `discardPending(id:)`.
    internal let edgeID: Swift::String?
    /// The owner-lifetime accepted revision.
    internal var revision: Swift::UInt64 {
        snapshot.revision
    }
    /// The accepted phase, revision, and closure, without the payload.
    internal var description: Swift::String {
        snapshot.description
    }
}

/// Why `send` did not admit an input.
internal enum SendRejection: Swift::Error {
    /// Routing or the authored transition declined the input before a candidate existed.
    case preparation(PreparationRejection)
    /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`).
    /// Read `snapshot()` for the current root.
    case commit(CommitRejection)
}

/// Admission either publishes the entire candidate or leaves all state unchanged.
internal enum CommitResult {
    case committed(Receipt)
    case rejected(CommitRejection, current: Snapshot)
}

fileprivate static func _stateMachineAdmission(_ result: _StateMachineEngine.Admission) -> CommitResult {
    switch result {
    case .committed(let record):
        return .committed(Receipt(record))
    case .rejected(let reason, let current):
        return .rejected(reason, current: _stateMachineSnapshot(current))
    }
}

/// A closed accepted emitted event.
internal enum Command {

    case counted(Tally.Counted.Payload)
}

/// One whole FIFO batch with its historical receipt.
internal struct CommandBatch: StateMachine::LocalCommandBatch {
    /// The atomic acceptance represented by this batch.
    internal let receipt: Receipt
    /// Cancellation commands, then starts and events in authored effect order.
    internal let commands: [Command]
    /// Whether this is the separately reserved close batch.
    internal let terminal: Swift::Bool
    fileprivate init(receipt: Receipt, commands: [Command], terminal: Swift::Bool) {
        self.receipt = receipt
        self.commands = commands
        self.terminal = terminal
    }
}

fileprivate static func _stateMachineBatch(_ batch: _StateMachineEngine.Batch) -> CommandBatch {
    let commands = batch.commands.map { command -> Command in
        switch command {
        case .cancel, .start:
            Swift::preconditionFailure("A schema without operations issues no work.")
        case .emit(let effect):
            switch effect {
            case .counted(let payload):
                return .counted(payload)
            }
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    []
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Tally, effects: [Effect], from: Swift::Int, to: Swift::Int,
    invalidates: [Swift::Int], requiring ticket: StateMachine::RuntimeTicket?, claim: StateMachine::RuntimeDeliveryClaim?, edge: Swift::String
) -> Prepared {
    do throws(StateMachine::PlanRejection) {
        var edits: [_StateMachineEngine.ScopeEdit] = []
        for (scope, phases) in _stateMachineEligibility.enumerated() {
            let before = phases.contains(from)
            let after = phases.contains(to)
            if after && (!before || invalidates.contains(scope)) {
                edits.append(.activate(_StateMachineScopeID(kind: Swift::UInt32(scope))))
            }
            else if before && !after {
                edits.append(.remove(_StateMachineScopeID(kind: Swift::UInt32(scope))))
            }
        }
        let starts: [_StateMachineEngine.Start] = []
        var emissions: [_StateMachineEngine.Emission] = []
        for effect in effects {
            switch effect {
            case .counted:
                emissions.append(.init(effect, position: starts.count))
            }
        }
        return Prepared(.candidate(try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map {
                        [$0]
                    } ?? [],
            plan: .init(scopes: edits, retire: ticket.map {
                            [$0]
                        } ?? [], starts: starts, emissions: emissions,
                controlCount: invalidates.count, finishingClaims: claim.map {
                            [$0]
                        } ?? [], edge: edge))))
    } catch {
        return Prepared(.defective(.init(error, preparedOn: record)))
    }
}

/// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
///
/// A plan defect travels inside the returned `Prepared` value rather than throwing here, so
/// admission reports it.
internal static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch input {
    case .add:
        switch snapshot {
        case .counting(let source):
            return source.add()
        }
    }
}

/// A phase that saved data can restore, covering phases with no active operations. A restored owner has no outstanding work.
internal enum Restoration {
    case counting(Counting)
}

/// A noncopyable manually driven owner with an embedded value engine.
internal struct Local: ~Swift::Copyable, StateMachine::DrainingLocalStateMachine, StateMachine::DefaultingLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
internal typealias Input = Tally.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Snapshot = Tally.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Receipt = Tally.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias SendRejection = Tally.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Prepared = Tally.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommitResult = Tally.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias InitialPhase = Counting
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Command = Tally.Command
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommandBatch = Tally.CommandBatch
    /// The declared structure of this owner's graph.
    internal static var graph: StateMachine::StateMachineGraph {
        _StateMachineSchema.graph
    }
    /// The identifier of the phase a snapshot holds, as the graph names it.
    internal static func phase(of snapshot: Snapshot) -> Swift::String {
        _stateMachinePhase(of: snapshot.record)
    }
    /// The receipt of an admitted proposal, or `nil` when admission rejected it.
    internal static func receipt(of result: CommitResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The identifier of the router or edge, as the graph names it, whose authored function refused an
    /// input that `send` rejected from a snapshot in `phase`, or `nil` when no authored function refused it.
    internal static func rejectingRoute(of rejection: SendRejection, in phase: Swift::String) -> Swift::String? {
        guard case .preparation(let preparation) = rejection else {
        return nil
    }
        return _stateMachineRefusingRoute(preparation, in: phase)
    }
    /// A fresh initial payload, constructed as the schema's declared default constructs it.
    internal static func defaultInitialPhase() -> InitialPhase {
        _StateMachineSchema.Counting()
    }

    fileprivate var engine: _StateMachineEngine

    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Counting = _StateMachineSchema.Counting(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.counting(initial), scopes: [], limits: configuration, recording: .commands)
    }
    /// Returns an immutable historical observation.
    internal borrowing func snapshot() -> Snapshot {
        _stateMachineSnapshot(engine.snapshot)
    }
    /// Whether `snapshot` was taken from this owner, in any incarnation.
    ///
    /// A reset keeps the owner, and another owner never matches, even one that holds an equal
    /// model at the same revision. The answer grants no authority.
    internal borrowing func owns(_ snapshot: Snapshot) -> Swift::Bool {
        engine.owns(snapshot.record)
    }
    /// Consumes and atomically accepts or rejects a complete candidate.
    internal mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
        switch prepared.candidate {
        case .defective(let defect):
            return _stateMachineAdmission(engine.reject(defect))
        case .candidate(let candidate):
            let result = engine.commit(candidate)

            return _stateMachineAdmission(result)
        }
    }
    /// Routes, prepares, and admits one input against the current root.
    @discardableResult
    internal mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
        let prepared: Prepared
        do {
            prepared = try _StateMachineSchema.prepare(input, on: snapshot())
        } catch {
            throw .preparation(error)
        }
        switch commit(prepared) {
        case .committed(let receipt):
            return receipt
        case .rejected(let reason, _):
            throw .commit(reason)
        }
    }
    /// Transfers at most `limit` whole FIFO batches. Handle their events after mutating access ends.
internal mutating func drainCommands(limit: Swift::Int = .max) -> [CommandBatch] {
    engine.drain(limit: limit).map {
        _stateMachineBatch($0)
    }
    }
    /// How many whole batches a drain would transfer, including the terminal batch, without
    /// transferring any.
    internal var queuedBatchCount: Swift::Int {
        engine.queuedBatchCount
    }
    /// Ends admission while retaining historical read access.
    @discardableResult
    internal mutating func close() -> Receipt {
        let result = engine.close()

        return Receipt(result)
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// The owner keeps its identity and subscribers, and its revision advances.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues no batch, so it needs no slot.
    @discardableResult
    internal mutating func reset(to initial: Counting = _StateMachineSchema.Counting()) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.counting(initial), scopes: [])
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
    /// still holds the root `expected` observed, so a decision made on that snapshot cannot
    /// discard a change accepted since.
    ///
    /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
    /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
    /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
    /// other acceptance, and then the same errors as `reset(to:)`.
    @discardableResult
    internal mutating func reset(to initial: Counting = _StateMachineSchema.Counting(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.counting(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Closure and FIFO transfer of every batch have settled.
internal var isQuiescent: Swift::Bool {
        engine.isQuiescent
    }
}

fileprivate typealias _StateMachineGraph = StateMachine::StateMachineGraph

/// The declared phases, inputs, scopes, operations, events, edges, and routers of this graph,
/// without payloads or authority.
internal nonisolated static let graph: StateMachine::StateMachineGraph = _stateMachineGraph()

nonisolated private static func _stateMachineGraph() -> StateMachine::StateMachineGraph {
    var phases: [_StateMachineGraph.Phase] = []
    phases.append(_StateMachineGraph.Phase(id: "counting", payload: "Counting"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "add", payload: nil))
    var events: [_StateMachineGraph.Event] = []
    events.append(_StateMachineGraph.Event(id: "Counted", effect: "counted", payload: "Int"))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "counting.add", name: "add",
        source: "counting", destination: "counting", trigger: .input("add"),
        router: nil, starts: [],
        cancels: [],
        emits: ["Counted"], invalidates: []))
    return .init(
        name: "Tally",
        mode: .isolated,
        owners: [.local],
        initial: "counting",
        terminal: [],
        restorable: [],
        phases: phases,
        inputs: inputs,
        scopes: [],
        operations: [],
        events: events,
        edges: edges,
        routers: []
    )
}
fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Swift::Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Swift::Copyable> {
}

fileprivate struct _RouterSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Swift::Sendable & ~Swift::Copyable> {
}

fileprivate struct _OperationFailureIsError<Value: Swift::Error> {
}

fileprivate struct _OperationKeyIsHashable<Value: Swift::Hashable & Swift::Sendable> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

/// The schema type, used by generated code where a local value could shadow its name.
internal typealias _StateMachineSchema = Ticket

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Ticket' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Ticket'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate enum _StateMachineReadsNever {
}

fileprivate static func _stateMachineNeverProbe<Value: ~Swift::Copyable>(_ type: Value.Type) -> Swift::Bool {
    true
}

fileprivate static func _stateMachineNeverProbe(_ type: Swift::Never.Type) -> _StateMachineReadsNever.Type {
    _StateMachineReadsNever.self
}

fileprivate static func _stateMachineIsNotSwiftNever(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Event 'Scanned' carries Never, so no transition can emit it; declare a payload type that has values, or remove the event.")
fileprivate static func _stateMachineIsNotSwiftNever(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    do {
        typealias _StateMachineChecked = Scanned.Payload;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    let _: _TransitionSourceIsPhasePayload<Valid> = _TransitionSourceIsPhasePayload<Valid>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Used, Effect.Scan>> = _TransitionReturnsDeclaredResult<Change<Used, Effect.Scan>>()


    let _ = _EffectIsCopyable<Effect>()

}

/// Inert descriptions of the operations this workflow can start and the events it can emit.
internal enum Effect {
    case scanned(Ticket.Scanned.Payload)
    /// The events `scan` may emit.
internal enum Scan {
    case scanned(Ticket.Scanned.Payload)
    /// The schema-wide effect this value describes.
    internal var effect: Ticket.Effect {
        switch self {
        case .scanned(let payload):
            return .scanned(payload)
        }
    }
    }
    /// The effect vocabularies of the edges from `Valid`.
    internal enum Valid {
        internal typealias Scan = Ticket.Effect.Scan
    }
}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Swift::Copyable>: ~Swift::Copyable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
    internal borrowing func withValue<Result: ~Swift::Copyable, Failure: Swift::Error>(
        _ body: (borrowing Phase) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(phase)
    }
    /// Consumes this authority and returns its payload, so a unique resource can move on.
    internal consuming func takeValue() -> Phase {
        phase
    }
    /// Advances through the authored edge, preserving effect order.
internal consuming func scan() -> StateMachine::Change<Owned<Used>, Effect.Scan> where Phase == Valid {
    let change = _StateMachineSchema.scan(phase)
    return .init(Owned<Used>(change.next), effects: change.effects)
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Valid) -> Owned<Valid> {
    Owned(initial)
}

fileprivate typealias _StateMachineGraph = StateMachine::StateMachineGraph

/// The declared phases, inputs, scopes, operations, events, edges, and routers of this graph,
/// without payloads or authority.
internal nonisolated static let graph: StateMachine::StateMachineGraph = _stateMachineGraph()

nonisolated private static func _stateMachineGraph() -> StateMachine::StateMachineGraph {
    var phases: [_StateMachineGraph.Phase] = []
    phases.append(_StateMachineGraph.Phase(id: "valid", payload: "Valid"))
    phases.append(_StateMachineGraph.Phase(id: "used", payload: "Used"))
    var events: [_StateMachineGraph.Event] = []
    events.append(_StateMachineGraph.Event(id: "Scanned", effect: "scanned", payload: "Int"))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "valid.scan", name: "scan",
        source: "valid", destination: "used", trigger: .direct,
        router: nil, starts: [],
        cancels: [],
        emits: ["Scanned"], invalidates: []))
    return .init(
        name: "Ticket",
        mode: .ownedOnly,
        owners: [.owned],
        initial: "valid",
        terminal: ["used"],
        restorable: [],
        phases: phases,
        inputs: [],
        scopes: [],
        operations: [],
        events: events,
        edges: edges,
        routers: []
    )
}
