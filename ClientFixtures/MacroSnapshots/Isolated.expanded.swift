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
internal typealias _StateMachineSchema = Note

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Note' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Note'.")
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

fileprivate static func _stateMachineIsSwiftVoid(_ type: Swift::Void.Type) {
}

@available(*, unavailable, message: "Operation 'Autosave' succeeds without output, as its onSuccess: edges and routers take none, but its Output resolves to a type other than Void; take the output after the source, or declare its Output as Void.")
fileprivate static func _stateMachineIsSwiftVoid<Value: ~Swift::Copyable>(_ type: Value.Type) {
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

@available(*, unavailable, message: "Operation 'Save' takes Never as its input, so no transition can start it; declare an input type that has values, or remove the operation.")
fileprivate static func _stateMachineIsNotSwiftNever(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever2(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Save' never succeeds: its Output is Never, so its onSuccess: edges and routers can never run; remove them, or declare the Output the operation produces.")
fileprivate static func _stateMachineIsNotSwiftNever2(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever3(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Autosave' takes Never as its input, so no transition can start it; declare an input type that has values, or remove the operation.")
fileprivate static func _stateMachineIsNotSwiftNever3(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    do {
        typealias _StateMachineChecked = Save.Input;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    do {
        typealias _StateMachineChecked = Save.Output;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever2(probe)
    }
    do {
        typealias _StateMachineChecked = Autosave.Input;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever3(probe)
    }
    do {
        typealias _StateMachineChecked = Autosave.Output;
        _stateMachineIsSwiftVoid(_StateMachineChecked.self)
    }
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Saving, Effect.Save>> = _TransitionReturnsDeclaredResult<Change<Saving, Effect.Save>>()
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Draft, Effect.Edit>> = _TransitionReturnsDeclaredResult<Change<Draft, Effect.Edit>>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .edit(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<String> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Saving> = _TransitionSourceIsPhasePayload<Saving>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()
    _stateMachineTakesOutput(_TriggerPayloadMatchesDeclaration<Save.Output>(), _TriggerPayloadMatchesDeclaration<Save.Output>())
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()


    let _ = _EffectIsCopyable<Effect>()

}

/// Inert descriptions of the operations this workflow can start.
internal enum Effect: ~Swift::Sendable {
    case save(Note.Save.Input)
    case autosave(Note.Autosave.Input)
    /// The operations `save` may start.
internal enum Save: ~Swift::Sendable {
    case save(Note.Save.Input)
    /// The schema-wide effect this value describes.
    internal var effect: Note.Effect {
        switch self {
        case .save(let input):
            return .save(input)
        }
    }
    }
    /// The operations `edit` may start.
    internal enum Edit: ~Swift::Sendable {
        case autosave(Note.Autosave.Input)
        /// The schema-wide effect this value describes.
        internal var effect: Note.Effect {
        switch self {
        case .autosave(let input):
            return .autosave(input)
        }
    }
    }
    /// The effect vocabularies of the edges from `Draft`.
    internal enum Draft {
        internal typealias Save = Note.Effect.Save
    internal typealias Edit = Note.Effect.Edit
    }
}

/// What one `Save` execution was started with, as admission accepted it.
internal typealias SaveRequest = StateMachine::OperationRequest<Save, Save.Input>

/// What one `Autosave` execution was started with, as admission accepted it.
internal typealias AutosaveRequest = StateMachine::OperationRequest<Autosave, Autosave.Input>

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
internal consuming func save() -> StateMachine::Change<Owned<Saving>, Effect.Save> where Phase == Draft {
    let change = _StateMachineSchema.save(phase)
    return .init(Owned<Saving>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func edit(_ input: String) -> StateMachine::Change<Owned<Draft>, Effect.Edit> where Phase == Draft {
        let change = _StateMachineSchema.edit(phase, input)
        return .init(Owned<Draft>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func saved(_ input: Save.Output) -> Owned<Draft> where Phase == Saving {
        Owned<Draft>(_StateMachineSchema.saved(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func autosaved() -> Owned<Draft> where Phase == Draft {
        Owned<Draft>(_StateMachineSchema.autosaved(phase))
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Draft) -> Owned<Draft> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Note, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = StateMachine::ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = StateMachine::Limits

/// A live observation registration for an owner confined to `Owner`. Only that actor can cancel and remove it, and releasing it stops delivery.
internal typealias IsolatedSubscription<Owner: Swift::Actor> = StateMachine::IsolatedSnapshotSubscription<Owner>

/// A live `MainActor` observation registration. Cancelling or releasing it stops delivery.
internal typealias MainActorSubscription = StateMachine::MainActorSnapshotSubscription

/// Failure to register another live observer.
internal typealias SubscriptionFailure = StateMachine::SubscriptionFailure

/// A single-consumer latest-value stream of a `MainActor` owner's snapshots.
internal typealias MainActorSnapshots = StateMachine::MainActorSnapshotSequence<Snapshot>

/// A single-consumer latest-value stream of the snapshots of an owner confined to one actor.
internal typealias IsolatedSnapshots = StateMachine::IsolatedSnapshotSequence<Snapshot>

/// The disposition of a retained completion.
internal typealias PendingStatus = StateMachine::PendingStatus

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
internal func save() -> Prepared where Phase == Draft {
    let change: StateMachine::Change<Saving, Effect.Save> = _StateMachineSchema.save(payload)
    return _stateMachinePrepare(on: record, next: .saving(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 1, invalidates: [],
        requiring: nil, claim: claim, edge: "draft.save")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func edit(_ input: String) -> Prepared where Phase == Draft {
        let change: StateMachine::Change<Draft, Effect.Edit> = _StateMachineSchema.edit(payload, input)
        return _stateMachinePrepare(on: record, next: .draft(change.next),
            effects: change.effects.map(\.effect),
            from: 0, to: 0, invalidates: [],
            requiring: nil, claim: claim, edge: "draft.edit")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func saved(_ value: Save.Output, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Saving {
        let next: Draft = _StateMachineSchema.saved(payload, value)
        return _stateMachinePrepare(on: record, next: .draft(next),
            effects: [],
            from: 1, to: 0, invalidates: [],
            requiring: authority, claim: claim, edge: "saving.saved")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func autosaved(_ value: Autosave.Output, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Draft {
        let next: Draft = _StateMachineSchema.autosaved(payload)
        return _stateMachinePrepare(on: record, next: .draft(next),
            effects: [],
            from: 0, to: 0, invalidates: [],
            requiring: authority, claim: claim, edge: "draft.autosaved")
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
    case draft(Observed<Draft>)
    case saving(Observed<Saving>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .draft(let value):
            return value.record
        case .saving(let value):
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
    internal var model: Note {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        switch self {
        case .draft(let value):
            return "draft, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .saving(let value):
            return "saving, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .draft(let payload):
        return .draft(Observed(payload: payload, record: record, claim: claim))
    case .saving(let payload):
        return .saving(Observed(payload: payload, record: record, claim: claim))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .draft:
        return "draft"
    case .saving:
        return "saving"
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

/// Work issued exclusively from an accepted command batch.
internal typealias SaveWork = _SaveWork<Save.Output>

/// The work of `Save`, generic over its output so that it seals an output of any type.
internal struct _SaveWork<_StateMachineOutput> {
    /// What admission started this work with.
internal let request: SaveRequest

    /// The immutable declared input.
internal var input: Save.Input {
        request.input
    }
    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: _StateMachineOutput) -> SaveCompletion where _StateMachineOutput == Save.Output {
        SaveCompletion(value: value, request: request, authority: authority)
    }


}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct SaveCompletion {
    /// The value the operation produced. This operation cannot fail.
    internal let value: Save.Output
    /// What admission started the work with.
internal let request: SaveRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Work issued exclusively from an accepted command batch.
internal typealias AutosaveWork = _AutosaveWork<Autosave.Output>

/// The work of `Autosave`, generic over its output so that it seals an output of any type.
internal struct _AutosaveWork<_StateMachineOutput> {
    /// What admission started this work with.
internal let request: AutosaveRequest

    /// The immutable declared input.
internal var input: Autosave.Input {
        request.input
    }
    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: _StateMachineOutput) -> AutosaveCompletion where _StateMachineOutput == Autosave.Output {
        AutosaveCompletion(value: value, request: request, authority: authority)
    }
    /// Seals a successful terminal result that carries no value.
internal func succeeded() -> AutosaveCompletion where _StateMachineOutput == Autosave.Output {
        succeeded(())
    }

}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct AutosaveCompletion {
    /// The value the operation produced. This operation cannot fail.
    internal let value: Autosave.Output
    /// What admission started the work with.
internal let request: AutosaveRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Closed typed terminal outcomes for this domain.
internal enum Completion {
    case save(SaveCompletion)
    case autosave(AutosaveCompletion)
    fileprivate var authority: StateMachine::RuntimeTicket {
        switch self {
        case .save(let value):
            return value.authority
        case .autosave(let value):
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

/// A closed accepted start or cancellation command.
internal enum Command {
    case cancel(ExecutionHandle)
    case save(SaveWork)
    case autosave(AutosaveWork)
}

/// One whole FIFO batch with its historical receipt.
internal struct CommandBatch: StateMachine::LocalCommandBatch {
    /// The atomic acceptance represented by this batch.
    internal let receipt: Receipt
    /// Cancellation commands followed by starts in authored effect order.
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
            case .save(let input):
                return .save(SaveWork(request: SaveRequest(input: input), authority: work.ticket))
            case .autosave(let input):
                return .autosave(AutosaveWork(request: AutosaveRequest(input: input), authority: work.ticket))
            }
        case .emit:
            Swift::preconditionFailure("A schema without events emits nothing.")
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    [[1], [0]]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Note, effects: [Effect], from: Swift::Int, to: Swift::Int,
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
        var counts = Swift::Array(repeating: 0, count: 2)
        for effect in effects {
            switch effect {
            case .save(let input):
                let _: Save.Input = input
                counts[0] += 1
                guard counts[0] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 0, scope: _StateMachineScopeID(kind: 0),
                    dependencies: [], policy: .rejectWhenActive), descriptor: effect))
            case .autosave(let input):
                let _: Autosave.Input = input
                counts[1] += 1
                guard counts[1] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 1, scope: _StateMachineScopeID(kind: 1),
                    dependencies: [], policy: .latest), descriptor: effect))
            }
        }
        return Prepared(.candidate(try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map {
                        [$0]
                    } ?? [],
            plan: .init(scopes: edits, retire: ticket.map {
                            [$0]
                        } ?? [], starts: starts,
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
    case .save:
        switch snapshot {
        case .draft(let source):
            return source.save()
        default:
            throw .invalidPhase
        }
    case .edit(let input):
        switch snapshot {
        case .draft(let source):
            return source.edit(input)
        default:
            throw .invalidPhase
        }
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch completion {
    case .save(let completion):
        switch snapshot {
        case .saving(let source):
            let value: Save.Output = completion.value
            return source.saved(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    case .autosave(let completion):
        switch snapshot {
        case .draft(let source):
            let value: Autosave.Output = completion.value
            return source.autosaved(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    }
}

/// A phase that saved data can restore, covering phases with no active operations and those
/// listed in `@Restoration(allows:)`. A restored owner has no outstanding work.
internal enum Restoration {
    case draft(Draft)
}

fileprivate static func _stateMachineRestored(_ saved: Box) -> (model: Note, scopes: [StateMachine::RuntimeScopeID]) {
    switch _StateMachineSchema.restore(saved) {
    case .draft(let payload):
        return (.draft(payload), [_StateMachineScopeID(kind: 1)])
    }
}

fileprivate typealias _StateMachineLedger = StateMachine::RuntimeDeliveryLedger<Note, Effect, Completion, PreparationRejection>

/// A single-consumer latest-value stream of a `MainActor` owner's retained completions.
internal typealias PendingCompletionUpdates = StateMachine::MainActorSnapshotSequence<[PendingCompletion]>

/// A single-consumer latest-value stream of the retained completions of an owner confined to one actor.
internal typealias IsolatedPendingCompletionUpdates = StateMachine::IsolatedSnapshotSequence<[PendingCompletion]>

/// The opaque identity of one retained terminal outcome of this schema's owners.
internal struct PendingCompletionID: Swift::Hashable, Swift::Sendable {
    fileprivate let raw: StateMachine::RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value. Only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
internal struct PendingCompletion {
    /// The retained terminal value of one operation, with the request its work was started with.
    internal enum Outcome {
        case save(Note.Save.Output, request: Note.SaveRequest)
        case autosave(Note.Autosave.Output, request: Note.AutosaveRequest)
    }
    /// Why the last preparation or admission of a retained outcome did not commit.
    internal enum Rejection {
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
        case .save(let completion):
            outcome = .save(completion.value, request: completion.request)
        case .autosave(let completion):
            outcome = .autosave(completion.value, request: completion.request)
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
internal enum DeliveryResult {
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
internal enum ReconcileResult {
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
internal enum DiscardResult {
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
internal struct Local: ~Swift::Copyable, StateMachine::DeliveringLocalStateMachine, StateMachine::RestoringLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
internal typealias Input = Note.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Snapshot = Note.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Receipt = Note.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias SendRejection = Note.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Prepared = Note.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommitResult = Note.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias InitialPhase = Draft
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Command = Note.Command
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommandBatch = Note.CommandBatch
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Completion = Note.Completion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ExecutionHandle = Note.ExecutionHandle
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletionID = Note.PendingCompletionID
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletion = Note.PendingCompletion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DeliveryResult = Note.DeliveryResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ReconcileResult = Note.ReconcileResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DiscardResult = Note.DiscardResult
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
    internal init(_ initial: Draft, configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], limits: configuration, recording: .commands)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    internal init(restoring saved: Box, configuration: LocalConfiguration = .default) {
        let restored = _stateMachineRestored(saved)
        engine = _StateMachineEngine(restored.model, scopes: restored.scopes, limits: configuration, recording: .commands)
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
    /// Delivers the sealed terminal result of one `Save` execution.
    internal mutating func deliver(_ completion: SaveCompletion) -> DeliveryResult {
        deliver(.save(completion))
    }
    /// Delivers the sealed terminal result of one `Autosave` execution.
    internal mutating func deliver(_ completion: AutosaveCompletion) -> DeliveryResult {
        deliver(.autosave(completion))
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
    internal mutating func reset(to initial: Draft) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)])
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
    internal mutating func reset(to initial: Draft, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data in a fresh
    /// incarnation, as `reset(to:)` does. Restoring saved data never resumes prior work.
    @discardableResult
    internal mutating func reset(restoring saved: Box) throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = engine.reset(restored.model, scopes: restored.scopes)
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    internal mutating func reset(restoring saved: Box, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = engine.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
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
internal let save: @Swift::MainActor (Save.Input) async -> Save.Output
    /// Executes this operation within the selected isolation.
    internal let autosave: @Swift::MainActor (Autosave.Input) async -> Autosave.Output
    /// Selects every driver for this owner's lifetime.
    internal init(save: @escaping @Swift::MainActor (Save.Input) async -> Save.Output, autosave: @escaping @Swift::MainActor (Autosave.Input) async -> Autosave.Output) {
        self.save = save
        self.autosave = autosave
    }
}

/// A sealed sole-writer `MainActor` owner with managed execution.
///
/// On iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, and Mac Catalyst 17.0 and
/// later, this owner conforms to `Observable` so a SwiftUI view can read it directly. Each
/// tracked member registers a read of its own value only, covering `currentSnapshot` and `snapshot()`, `runningCount`,
/// `subscriberCount`, and `pendingCompletions()`.
@Swift::MainActor internal final class MainActorHost: StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeMainActorHost<Note, Effect, Completion, PreparationRejection>
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
    internal init(_ initial: Draft, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .autosave(let input):
                    execution = {
                    .autosave(AutosaveCompletion(value: await drivers.autosave(input), request: AutosaveRequest(input: input), authority: raw.ticket))
                }
                }
    return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    internal init(restoring saved: Box, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .autosave(let input):
                    execution = {
                    .autosave(AutosaveCompletion(value: await drivers.autosave(input), request: AutosaveRequest(input: input), authority: raw.ticket))
                }
                }
    return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Draft,
        saveDriver: @escaping @Swift::MainActor (Save.Input) async -> Save.Output,
        autosaveDriver: @escaping @Swift::MainActor (Autosave.Input) async -> Autosave.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: MainActorDrivers(save: saveDriver, autosave: autosaveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: Box,
        saveDriver: @escaping @Swift::MainActor (Save.Input) async -> Save.Output,
        autosaveDriver: @escaping @Swift::MainActor (Autosave.Input) async -> Autosave.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(restoring: saved, drivers: MainActorDrivers(save: saveDriver, autosave: autosaveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
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
    /// Registers a single-consumer stream of the latest complete snapshots, taking a subscriber slot when called.
    ///
    /// It ends after the closed snapshot, when this owner is released, when its `cancel()` is
    /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` on the main actor, which removes its registration before it
    /// returns.
    internal func snapshots() throws(SubscriptionFailure) -> MainActorSnapshots {
        try host.snapshots {
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
    /// Registers a single-consumer stream of the retained completions, each element the whole collection, taking a subscriber slot when called.
    ///
    /// The first element is the collection current at registration, and each later element is the
    /// collection after a change, in the order of those changes. A newer collection replaces one
    /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
    /// when this owner is released, when its `cancel()` is called, or when a read finds its
    /// task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()` on the main actor, which removes its registration before it
    /// returns.
    internal func pendingCompletionUpdates() throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.pendingCompletionUpdates {
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
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Note, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Note, Effect>) -> DiscardResult {
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
    internal func reset(to initial: Draft) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)])
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
    internal func reset(to initial: Draft, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data in a fresh
    /// incarnation, as `reset(to:)` does. Restoring saved data never resumes prior work.
    @discardableResult
    internal func reset(restoring saved: Box) throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = host.reset(restored.model, scopes: restored.scopes)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    internal func reset(restoring saved: Box, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = host.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
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

/// A sealed sole-writer owner confined to one actor instance, with managed execution.
///
/// Create it on the actor that owns it, as `IsolatedHost(isolation: self, …)`, and keep it there.
/// It is not `Sendable`, so the compiler keeps it in that actor's region, and every method takes
/// the actor as a defaulted `isolated` parameter. Inside the actor, calls read `host.send(input)`,
/// while calls from another actor or a nonisolated context do not compile. A method that receives
/// a different instance of the actor's type stops the program.
///
/// Drivers run on the owning actor and receive it isolated, so they can read and
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
    private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, Note, Effect, Completion, PreparationRejection>
    private let host: Host
        /// Immutable operation selections, each run on the owning actor, which it receives isolated.
    ///
    /// A driver reaches the actor's state through that parameter, so it captures nothing confined.
    internal struct Drivers: Swift::Sendable {
        /// Executes this operation on the owning actor, which it receives isolated.
    internal let save: @Sendable (isolated Owner, Save.Input) async -> Save.Output
    /// Executes this operation on the owning actor, which it receives isolated.
    internal let autosave: @Sendable (isolated Owner, Autosave.Input) async -> Autosave.Output
        /// Selects every driver for this owner's lifetime.
        internal init(save: @escaping @Sendable (isolated Owner, Save.Input) async -> Save.Output, autosave: @escaping @Sendable (isolated Owner, Autosave.Input) async -> Autosave.Output) {
        self.save = save
        self.autosave = autosave
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
    internal init(_ initial: Draft, isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(owner, input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .autosave(let input):
                    execution = {
                    .autosave(AutosaveCompletion(value: await drivers.autosave(owner, input), request: AutosaveRequest(input: input), authority: raw.ticket))
                }
                }
    return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    internal init(restoring saved: Box, isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(owner, input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .autosave(let input):
                    execution = {
                    .autosave(AutosaveCompletion(value: await drivers.autosave(owner, input), request: AutosaveRequest(input: input), authority: raw.ticket))
                }
                }
    return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Draft,
        isolation: isolated Owner,
        saveDriver: @escaping @Sendable (isolated Owner, Save.Input) async -> Save.Output,
        autosaveDriver: @escaping @Sendable (isolated Owner, Autosave.Input) async -> Autosave.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, isolation: isolation, drivers: Drivers(save: saveDriver, autosave: autosaveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: Box,
        isolation: isolated Owner,
        saveDriver: @escaping @Sendable (isolated Owner, Save.Input) async -> Save.Output,
        autosaveDriver: @escaping @Sendable (isolated Owner, Autosave.Input) async -> Autosave.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(restoring: saved, isolation: isolation, drivers: Drivers(save: saveDriver, autosave: autosaveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
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
    /// Registers a single-consumer stream, read with `next()` on the owning actor, of the latest complete snapshots, taking a subscriber slot when called.
    ///
    /// It ends after the closed snapshot, when this owner is released, when its `cancel(isolation:)` is
    /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel(isolation:)` on the owning actor, which removes its registration
    /// before it returns.
    internal func snapshots(isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> IsolatedSnapshots {
        try host.snapshots({
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
    /// Registers a single-consumer stream, read with `next()` on the owning actor, of the retained completions, each element the whole collection, taking a subscriber slot when called.
    ///
    /// The first element is the collection current at registration, and each later element is the
    /// collection after a change, in the order of those changes. A newer collection replaces one
    /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
    /// when this owner is released, when its `cancel(isolation:)` is called, or when a read finds its
    /// task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel(isolation:)` on the owning actor, which removes its registration
    /// before it returns.
    internal func pendingCompletionUpdates(isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> IsolatedPendingCompletionUpdates {
        try host.pendingCompletionUpdates({
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
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Note, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Note, Effect>) -> DiscardResult {
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
    internal func reset(to initial: Draft, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], isolation: isolation)
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
    internal func reset(to initial: Draft, expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data in a fresh
    /// incarnation, as `reset(to:)` does. Restoring saved data never resumes prior work.
    @discardableResult
    internal func reset(restoring saved: Box, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = host.reset(restored.model, scopes: restored.scopes, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    internal func reset(restoring saved: Box, expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = host.reset(restored.model, scopes: restored.scopes, expecting: expected.record, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
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
    phases.append(_StateMachineGraph.Phase(id: "draft", payload: "Draft"))
    phases.append(_StateMachineGraph.Phase(id: "saving", payload: "Saving"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "save", payload: nil))
    inputs.append(_StateMachineGraph.Input(id: "edit", payload: "String"))
    var operations: [_StateMachineGraph.Operation] = []
    operations.append(_StateMachineGraph.Operation(id: "Save", effect: "save", scope: nil,
        requires: [], activeIn: ["saving"], admission: .rejectWhenActive,
        key: nil, input: "Box", output: "Box",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    operations.append(_StateMachineGraph.Operation(id: "Autosave", effect: "autosave", scope: nil,
        requires: [], activeIn: ["draft"], admission: .latest,
        key: nil, input: "String", output: "Void",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "draft.save", name: "save",
        source: "draft", destination: "saving", trigger: .input("save"),
        router: nil, starts: ["Save"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "draft.edit", name: "edit",
        source: "draft", destination: "draft", trigger: .input("edit"),
        router: nil, starts: ["Autosave"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "saving.saved", name: "saved",
        source: "saving", destination: "draft", trigger: .success("Save"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "draft.autosaved", name: "autosaved",
        source: "draft", destination: "draft", trigger: .success("Autosave"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    return .init(
        name: "Note",
        mode: .isolated,
        owners: [.owned, .local, .mainActorHost, .isolatedHost],
        initial: "draft",
        terminal: [],
        restorable: ["draft"],
        phases: phases,
        inputs: inputs,
        scopes: [],
        operations: operations,
        events: [],
        edges: edges,
        routers: []
    )
}
