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

/// The schema, for generated code that names it where a value of its name could take the name.
internal typealias _StateMachineSchema = Editor

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Editor' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Editor'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> _TriggerPayloadMatchesDeclaration<Value> {
    _TriggerPayloadMatchesDeclaration<Value>()
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

fileprivate static func _stateMachineConformsToSwiftEquatable<Value: Swift::Equatable>(_ type: Value.Type) {
}

@available(*, unavailable, message: "The schema's inheritance clause names Equatable, which the macro reads as the standard library's Swift::Equatable that generated effects and restorations repeat, but the schema does not conform to it; write Swift::Equatable in the inheritance clause, or name the protocol through its module.")
fileprivate static func _stateMachineConformsToSwiftEquatable<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    _stateMachineConformsToSwiftEquatable(Self.self)
    do {
        typealias _StateMachineChecked = Save.Input;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()
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
    let _: _TransitionReturnsDeclaredResult<Saving> = _TransitionReturnsDeclaredResult<Saving>()
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
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Saving, Effect.Draft.Retry>> = _TransitionReturnsDeclaredResult<Change<Saving, Effect.Draft.Retry>>()
    let _: _TransitionSourceIsPhasePayload<Failed> = _TransitionSourceIsPhasePayload<Failed>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Saving, Effect.Failed.Retry>> = _TransitionReturnsDeclaredResult<Change<Saving, Effect.Failed.Retry>>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Closed, Effect.Close>> = _TransitionReturnsDeclaredResult<Change<Closed, Effect.Close>>()
    let _: _TransitionSourceIsPhasePayload<Failed> = _TransitionSourceIsPhasePayload<Failed>()
    let _: _TransitionReturnsDeclaredResult<Failed> = _TransitionReturnsDeclaredResult<Failed>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .pick(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Int> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Failed> = _TransitionSourceIsPhasePayload<Failed>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .pick(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Int> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Saving> = _TransitionSourceIsPhasePayload<Saving>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()
    let _: _TransitionSourceIsPhasePayload<Saving> = _TransitionSourceIsPhasePayload<Saving>()
    let _: _TransitionReturnsDeclaredResult<Saving> = _TransitionReturnsDeclaredResult<Saving>()
    let _: _TransitionSourceIsPhasePayload<Closed> = _TransitionSourceIsPhasePayload<Closed>()
    let _: _TransitionReturnsDeclaredResult<Closed> = _TransitionReturnsDeclaredResult<Closed>()
    let _ = _OperationFailureIsError<DraftError>()
    let _ = { (failure: Problem) throws(DraftError) in
        throw failure
    }
    let _: _RouterSourceIsPhasePayload<Failed> = _RouterSourceIsPhasePayload<Failed>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .pick(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Int> = payload;
            case _:
                break
            }
        }
    }
    let _ = _EffectIsCopyable<Effect>()
    let _ = _SharedModeRequiresSendable<Input>();
    let _ = _SharedModeRequiresSendable<Effect>()
}

/// Inert descriptions of the operations this workflow can start.
internal enum Effect: Swift::Sendable, Swift::Equatable {
    case save(Editor.Save.Input)
    case audit
    case archive
    /// The operations `close` may start.
internal enum Close: Swift::Sendable, Swift::Equatable {
    case archive
    /// The schema-wide effect this value describes.
    internal var effect: Editor.Effect {
        switch self {
        case .archive:
            return .archive
        }
    }
    }
    /// The effect vocabularies of the edges from `Draft`.
    internal enum Draft {
        /// The operations `retry` may start.
    internal enum Retry: Swift::Sendable, Swift::Equatable {
        case save(Editor.Save.Input)
        /// The schema-wide effect this value describes.
        internal var effect: Editor.Effect {
        switch self {
        case .save(let input):
            return .save(input)
        }
    }
    }
    internal typealias Close = Editor.Effect.Close
    }
    /// The effect vocabularies of the edges from `Failed`.
    internal enum Failed {
        /// The operations `retry` may start.
    internal enum Retry: Swift::Sendable, Swift::Equatable {
        case save(Editor.Save.Input)
    case audit
        /// The schema-wide effect this value describes.
        internal var effect: Editor.Effect {
        switch self {
        case .save(let input):
            return .save(input)
        case .audit:
            return .audit
        }
    }
    }
    internal typealias Close = Editor.Effect.Close
    }
}

/// What one `Save` execution was started with, as admission accepted it.
internal typealias SaveRequest = StateMachine::OperationRequest<Save, Save.Input>

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
    /// Advances through the authored edge or returns the original predecessor.
internal consuming func edit(_ input: String) -> StateMachine::Advance<Self, Owned<Draft>, Swift::Never, DraftError> where Phase == Draft {
    do {
        return .advanced(Owned<Draft>(try _StateMachineSchema.edit(phase, input)), effects: [])
    } catch {
        return .rejected(error, self)
    }
    }
    /// Advances through the authored edge or returns the original predecessor.
    internal consuming func edit(_ input: String) -> StateMachine::Advance<Self, Owned<Saving>, Swift::Never, SavingError> where Phase == Saving {
        do {
        return .advanced(Owned<Saving>(try _StateMachineSchema.edit(phase, input)), effects: [])
    } catch {
        return .rejected(error, self)
    }
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func retry() -> StateMachine::Change<Owned<Saving>, Effect.Draft.Retry> where Phase == Draft {
        let change = _StateMachineSchema.retry(phase)
        return .init(Owned<Saving>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func retry() -> StateMachine::Change<Owned<Saving>, Effect.Failed.Retry> where Phase == Failed {
        let change = _StateMachineSchema.retry(phase)
        return .init(Owned<Saving>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func close() -> StateMachine::Change<Owned<Closed>, Effect.Close> where Phase == Draft {
        let change = _StateMachineSchema.close()
        return .init(Owned<Closed>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func close() -> StateMachine::Change<Owned<Closed>, Effect.Close> where Phase == Failed {
        let change = _StateMachineSchema.close()
        return .init(Owned<Closed>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    fileprivate consuming func keep(_ input: Int) -> Owned<Failed> where Phase == Failed {
        Owned<Failed>(_StateMachineSchema.keep(phase, input))
    }
    /// Advances through the authored edge or returns the original predecessor.
    fileprivate consuming func discard(_ input: Int) -> StateMachine::Advance<Self, Owned<Draft>, Swift::Never, Problem> where Phase == Failed {
        do {
        return .advanced(Owned<Draft>(try _StateMachineSchema.discard(phase, input)), effects: [])
    } catch {
        return .rejected(error, self)
    }
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func saved() -> Owned<Draft> where Phase == Saving {
        Owned<Draft>(_StateMachineSchema.saved(phase))
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func audited() -> Owned<Saving> where Phase == Saving {
        Owned<Saving>(_StateMachineSchema.audited(phase))
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func archived() -> Owned<Closed> where Phase == Closed {
        Owned<Closed>(_StateMachineSchema.archived(phase))
    }
    /// Runs the router `pick`, then advances through the edge it selects.
internal consuming func pick(_ input: Int) -> Route.PickResult where Phase == Failed {
    let selection: Route.Pick = _StateMachineSchema.pick(phase, input)
    switch selection {
    case .keep:
        return .keep(self.keep(input))
    case .discard:
        return .discard(self.discard(input))
    }
    }
}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Draft = _StateMachineSchema.Draft()) -> Owned<Draft> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Editor, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = StateMachine::ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = StateMachine::Limits

/// A live observation registration; cancelling or releasing it stops delivery.
internal typealias Subscription = StateMachine::SnapshotSubscription

/// A live observation registration with an owner confined to the actor `Owner`; only that actor can cancel it, which removes it, and dropping it stops delivery.
internal typealias IsolatedSubscription<Owner: Swift::Actor> = StateMachine::IsolatedSnapshotSubscription<Owner>

/// A live MainActor observation registration; cancelling or releasing it stops delivery.
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
internal func edit(_ input: String) throws(DraftError) -> Prepared where Phase == Draft {
    let next: Draft = try _StateMachineSchema.edit(payload, input)
    return _stateMachinePrepare(on: record, next: .draft(next),
        effects: [],
        from: 0, to: 0, invalidates: [],
        requiring: nil, claim: claim, edge: "draft.edit")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func edit(_ input: String) throws(SavingError) -> Prepared where Phase == Saving {
        let next: Saving = try _StateMachineSchema.edit(payload, input)
        return _stateMachinePrepare(on: record, next: .saving(next),
            effects: [],
            from: 1, to: 1, invalidates: [],
            requiring: nil, claim: claim, edge: "saving.edit")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func retry() -> Prepared where Phase == Draft {
        let change: StateMachine::Change<Saving, Effect.Draft.Retry> = _StateMachineSchema.retry(payload)
        return _stateMachinePrepare(on: record, next: .saving(change.next),
            effects: change.effects.map(\.effect),
            from: 0, to: 1, invalidates: [],
            requiring: nil, claim: claim, edge: "draft.retry")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func retry() -> Prepared where Phase == Failed {
        let change: StateMachine::Change<Saving, Effect.Failed.Retry> = _StateMachineSchema.retry(payload)
        return _stateMachinePrepare(on: record, next: .saving(change.next),
            effects: change.effects.map(\.effect),
            from: 2, to: 1, invalidates: [],
            requiring: nil, claim: claim, edge: "failed.retry")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func close() -> Prepared where Phase == Draft {
        let change: StateMachine::Change<Closed, Effect.Close> = _StateMachineSchema.close()
        return _stateMachinePrepare(on: record, next: .closed(change.next),
            effects: change.effects.map(\.effect),
            from: 0, to: 3, invalidates: [],
            requiring: nil, claim: claim, edge: "draft.close")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func close() -> Prepared where Phase == Failed {
        let change: StateMachine::Change<Closed, Effect.Close> = _StateMachineSchema.close()
        return _stateMachinePrepare(on: record, next: .closed(change.next),
            effects: change.effects.map(\.effect),
            from: 2, to: 3, invalidates: [],
            requiring: nil, claim: claim, edge: "failed.close")
    }
    /// Prepares the declared edge that the router `pick` selects.
    fileprivate func keep(_ input: Int) -> Prepared where Phase == Failed {
        let next: Failed = _StateMachineSchema.keep(payload, input)
        return _stateMachinePrepare(on: record, next: .failed(next),
            effects: [],
            from: 2, to: 2, invalidates: [],
            requiring: nil, claim: claim, edge: "failed.keep")
    }
    /// Prepares the declared edge that the router `pick` selects.
    fileprivate func discard(_ input: Int) throws(Problem) -> Prepared where Phase == Failed {
        let next: Draft = try _StateMachineSchema.discard(payload, input)
        return _stateMachinePrepare(on: record, next: .draft(next),
            effects: [],
            from: 2, to: 0, invalidates: [],
            requiring: nil, claim: claim, edge: "failed.discard")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func saved(_ value: Swift::Void, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Saving {
        let next: Draft = _StateMachineSchema.saved(payload)
        return _stateMachinePrepare(on: record, next: .draft(next),
            effects: [],
            from: 1, to: 0, invalidates: [],
            requiring: authority, claim: claim, edge: "saving.saved")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func audited(_ value: Swift::Void, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Saving {
        let next: Saving = _StateMachineSchema.audited(payload)
        return _stateMachinePrepare(on: record, next: .saving(next),
            effects: [],
            from: 1, to: 1, invalidates: [],
            requiring: authority, claim: claim, edge: "saving.audited")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func archived(_ value: Swift::Void, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Closed {
        let next: Closed = _StateMachineSchema.archived(payload)
        return _stateMachinePrepare(on: record, next: .closed(next),
            effects: [],
            from: 3, to: 3, invalidates: [],
            requiring: authority, claim: claim, edge: "closed.archived")
    }
    /// Runs the router `pick`, then prepares the edge it selects.
    internal func pick(_ input: Int) throws(DraftError) -> Prepared where Phase == Failed {
        let selection: Route.Pick = _StateMachineSchema.pick(payload, input)
        switch selection {
    case .keep:
        return self.keep(input)
    case .discard:
        return try self.discard(input)
    }
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: Swift::Sendable, StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
    case draft(Observed<Draft>)
    case saving(Observed<Saving>)
    case failed(Observed<Failed>)
    case closed(Observed<Closed>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .draft(let value):
            return value.record
        case .saving(let value):
            return value.record
        case .failed(let value):
            return value.record
        case .closed(let value):
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
    /// Ordinary model data; constructing it confers no installation authority.
    internal var model: Editor {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        switch self {
        case .draft(let value):
            return "draft, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .saving(let value):
            return "saving, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .failed(let value):
            return "failed, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .closed(let value):
            return "closed, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .draft(let payload):
        return .draft(Observed(payload: payload, record: record, claim: claim))
    case .saving(let payload):
        return .saving(Observed(payload: payload, record: record, claim: claim))
    case .failed(let payload):
        return .failed(Observed(payload: payload, record: record, claim: claim))
    case .closed(let payload):
        return .closed(Observed(payload: payload, record: record, claim: claim))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .draft:
        return "draft"
    case .saving:
        return "saving"
    case .failed:
        return "failed"
    case .closed:
        return "closed"
    }
}

fileprivate static func _stateMachineRefusingRoute(_ rejection: PreparationRejection, in phase: Swift::String) -> Swift::String? {
    switch (rejection, phase) {
    case (.draftEdit, "draft"):
        return "draft.edit"
    case (.savingEdit, "saving"):
        return "saving.edit"
    case (.discard, "failed"):
        return "failed.discard"
    default:
        return nil
    }
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
    case draftEdit(DraftError)
    case savingEdit(SavingError)
    case discard(Problem)
}

/// The edges each router may choose among.
internal enum Route {
    /// The edges `pick` may choose.
internal enum Pick: Swift::Sendable, Swift::Equatable, Swift::Hashable, Swift::CaseIterable {
        case keep
        case discard
    }
    /// The result of `pick` on an owned `Failed`: one case per edge it may select.
    internal enum PickResult: ~Swift::Copyable, Swift::Sendable {
        case keep(Editor.Owned<Editor.Failed>)
    case discard(StateMachine::Advance<Editor.Owned<Editor.Failed>, Editor.Owned<Editor.Draft>, Swift::Never, Editor.Problem>)
    }
    /// The choice and owned result types of the routers from `Failed`.
    internal enum Failed {
        internal typealias Pick = Editor.Route.Pick
    internal typealias PickResult = Editor.Route.PickResult
    }
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
    /// change that takes no edge: a reset, closure, or the authority-only commit of
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
    /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`);
    /// read `snapshot()` for the current root.
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
internal typealias SaveWork = _SaveWork<Swift::Void>

/// The work of `Save`, generic over its output so that it seals an output of any type.
internal struct _SaveWork<_StateMachineOutput>: Swift::Sendable {
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
    internal func succeeded(_ value: _StateMachineOutput) -> SaveCompletion where _StateMachineOutput == Swift::Void {
        SaveCompletion(value: value, request: request, authority: authority)
    }
    /// Seals a successful terminal result that carries no value.
internal func succeeded() -> SaveCompletion where _StateMachineOutput == Swift::Void {
        succeeded(())
    }

}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct SaveCompletion: Swift::Sendable {
    /// The value the operation produced; it cannot fail.
    internal let value: Swift::Void
    /// What admission started the work with.
internal let request: SaveRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Work issued exclusively from an accepted command batch.
internal typealias AuditWork = _AuditWork<Swift::Void>

/// The work of `Audit`, generic over its output so that it seals an output of any type.
internal struct _AuditWork<_StateMachineOutput>: Swift::Sendable {



    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: _StateMachineOutput) -> AuditCompletion where _StateMachineOutput == Swift::Void {
        AuditCompletion(value: value, authority: authority)
    }
    /// Seals a successful terminal result that carries no value.
internal func succeeded() -> AuditCompletion where _StateMachineOutput == Swift::Void {
        succeeded(())
    }

}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct AuditCompletion: Swift::Sendable {
    /// The value the operation produced; it cannot fail.
    internal let value: Swift::Void

    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Work issued exclusively from an accepted command batch.
internal typealias ArchiveWork = _ArchiveWork<Swift::Void>

/// The work of `Archive`, generic over its output so that it seals an output of any type.
internal struct _ArchiveWork<_StateMachineOutput>: Swift::Sendable {



    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: _StateMachineOutput) -> ArchiveCompletion where _StateMachineOutput == Swift::Void {
        ArchiveCompletion(value: value, authority: authority)
    }
    /// Seals a successful terminal result that carries no value.
internal func succeeded() -> ArchiveCompletion where _StateMachineOutput == Swift::Void {
        succeeded(())
    }

}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct ArchiveCompletion: Swift::Sendable {
    /// The value the operation produced; it cannot fail.
    internal let value: Swift::Void

    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Closed typed terminal outcomes for this domain.
internal enum Completion: Swift::Sendable {
    case save(SaveCompletion)
    case audit(AuditCompletion)
    case archive(ArchiveCompletion)
    fileprivate var authority: StateMachine::RuntimeTicket {
        switch self {
        case .save(let value):
            return value.authority
        case .audit(let value):
            return value.authority
        case .archive(let value):
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
internal enum Command: Swift::Sendable {
    case cancel(ExecutionHandle)
    case save(SaveWork)
    case audit(AuditWork)
    case archive(ArchiveWork)
}

/// One whole FIFO batch with its historical receipt.
internal struct CommandBatch: Swift::Sendable, StateMachine::LocalCommandBatch {
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
            case .audit:
                return .audit(AuditWork(authority: work.ticket))
            case .archive:
                return .archive(ArchiveWork(authority: work.ticket))
            }
        case .emit:
            Swift::preconditionFailure("A schema without events emits nothing.")
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    [[1], [1], [3]]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Editor, effects: [Effect], from: Swift::Int, to: Swift::Int,
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
        var counts = Swift::Array(repeating: 0, count: 3)
        for effect in effects {
            switch effect {
            case .save(let input):
                let _: Save.Input = input
                counts[0] += 1
                guard counts[0] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 0, scope: _StateMachineScopeID(kind: 0),
                    dependencies: [], policy: .latest), descriptor: effect))
            case .audit:

                counts[1] += 1
                guard counts[1] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 1, scope: _StateMachineScopeID(kind: 1),
                    dependencies: [], policy: .latest), descriptor: effect))
            case .archive:

                counts[2] += 1
                guard counts[2] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 2, scope: _StateMachineScopeID(kind: 2),
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
/// A plan defect is not a routing rejection: it travels inside the result, and admission reports it.
internal static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch input {
    case .edit(let input):
        switch snapshot {
        case .draft(let source):
            do {
                return try source.edit(input)
            } catch {
                throw .draftEdit(error)
            }
        case .saving(let source):
            do {
                return try source.edit(input)
            } catch {
                throw .savingEdit(error)
            }
        default:
            throw .invalidPhase
        }
    case .retry:
        switch snapshot {
        case .draft(let source):
            return source.retry()
        case .failed(let source):
            return source.retry()
        default:
            throw .invalidPhase
        }
    case .close:
        switch snapshot {
        case .draft(let source):
            return source.close()
        case .failed(let source):
            return source.close()
        default:
            throw .invalidPhase
        }
    case .pick(let input):
        switch snapshot {
        case .failed(let source):
            let selection: Route.Pick = _StateMachineSchema.pick(source.value, input)
            switch selection {
            case .keep:
                return source.keep(input)
            case .discard:
                do {
                    return try source.discard(input)
                } catch {
                    throw .discard(error)
                }
            }
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
            let value: Swift::Void = completion.value
            return source.saved(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    case .audit(let completion):
        switch snapshot {
        case .saving(let source):
            let value: Swift::Void = completion.value
            return source.audited(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    case .archive(let completion):
        switch snapshot {
        case .closed(let source):
            let value: Swift::Void = completion.value
            return source.archived(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    }
}

/// A phase saved data can restore: one listed in `@Restoration(only:)`. A restored owner has no outstanding work.
internal enum Restoration: Swift::Sendable, Swift::Equatable {
    case draft(Draft)
    case failed(Failed)
}

fileprivate static func _stateMachineRestored(_ saved: String) -> (model: Editor, scopes: [StateMachine::RuntimeScopeID]) {
    switch _StateMachineSchema.restore(saved) {
    case .draft(let payload):
        return (.draft(payload), [])
    case .failed(let payload):
        return (.failed(payload), [])
    }
}

fileprivate typealias _StateMachineLedger = StateMachine::RuntimeDeliveryLedger<Editor, Effect, Completion, PreparationRejection>

/// A single-pass latest-value sequence of a managed owner's retained completions.
internal typealias PendingCompletionUpdates = StateMachine::SnapshotSequence<[PendingCompletion]>

/// The opaque identity of one retained terminal outcome of this schema's owners.
internal struct PendingCompletionID: Swift::Hashable, Swift::Sendable {
    fileprivate let raw: StateMachine::RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value: only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
internal struct PendingCompletion: Swift::Sendable {
    /// The retained terminal value of one operation, with the request its work was started with.
    internal enum Outcome: Swift::Sendable {
        case save(Swift::Void, request: Editor.SaveRequest)
        case audit(Swift::Void)
        case archive(Swift::Void)
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
    /// The saturating count of claimed preparations; capacity retries do not increment it.
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
        case .audit(let completion):
            outcome = .audit(completion.value)
        case .archive(let completion):
            outcome = .archive(completion.value)
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
    /// The outcome is retained; its status says what admission is waiting for.
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
    /// The outcome is still retained; its status says what admission is waiting for.
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
    /// The owner refused the authority-only commit; the outcome stays retained.
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
    /// The deadline passed first; the diagnostics describe what was still outstanding.
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
internal struct Local: ~Swift::Copyable, StateMachine::DeliveringLocalStateMachine, StateMachine::DefaultingLocalStateMachine, StateMachine::RestoringLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
internal typealias Input = Editor.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Snapshot = Editor.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Receipt = Editor.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias SendRejection = Editor.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Prepared = Editor.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommitResult = Editor.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias InitialPhase = Draft
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Command = Editor.Command
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommandBatch = Editor.CommandBatch
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Completion = Editor.Completion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ExecutionHandle = Editor.ExecutionHandle
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletionID = Editor.PendingCompletionID
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletion = Editor.PendingCompletion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DeliveryResult = Editor.DeliveryResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ReconcileResult = Editor.ReconcileResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DiscardResult = Editor.DiscardResult
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
        _StateMachineSchema.Draft()
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
    internal init(_ initial: Draft = _StateMachineSchema.Draft(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.draft(initial), scopes: [], limits: configuration, recording: .commands)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    internal init(restoring saved: String, configuration: LocalConfiguration = .default) {
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
    /// Routes, prepares and admits one input against the current root.
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
    /// Transfers whole FIFO batches, at most `limit` of them; physical execution occurs after mutating access ends.
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
    /// replaces the retained one; it reports that outcome's status instead.
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
    /// Delivers the sealed terminal result of one `Audit` execution.
    internal mutating func deliver(_ completion: AuditCompletion) -> DeliveryResult {
        deliver(.audit(completion))
    }
    /// Delivers the sealed terminal result of one `Archive` execution.
    internal mutating func deliver(_ completion: ArchiveCompletion) -> DeliveryResult {
        deliver(.archive(completion))
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
    /// Draining and acknowledging never admit a retained completion; call this after they free capacity.
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
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
    /// full, and then changes nothing; it queues a batch only to cancel the work it revokes, so it needs a slot only then.
    @discardableResult
    internal mutating func reset(to initial: Draft = _StateMachineSchema.Draft()) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.draft(initial), scopes: [])
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal mutating func reset(to initial: Draft = _StateMachineSchema.Draft(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.draft(initial), scopes: [], expecting: expected.record)
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data, in a fresh
    /// incarnation, exactly as `reset(to:)` does; the saved data never resumes work.
    @discardableResult
    internal mutating func reset(restoring saved: String) throws(CommitRejection) -> Receipt {
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
    internal mutating func reset(restoring saved: String, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
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

/// Immutable operation selections whose non-Sendable values stay within MainActor.
@Swift::MainActor internal struct MainActorDrivers {
    /// Executes this operation within the selected isolation.
internal let save: @Swift::MainActor (Save.Input) async -> Swift::Void
    /// Executes this operation within the selected isolation.
    internal let audit: @Swift::MainActor () async -> Swift::Void
    /// Executes this operation within the selected isolation.
    internal let archive: @Swift::MainActor () async -> Swift::Void
    /// Selects every driver for this owner's lifetime.
    internal init(save: @escaping @Swift::MainActor (Save.Input) async -> Swift::Void, audit: @escaping @Swift::MainActor () async -> Swift::Void, archive: @escaping @Swift::MainActor () async -> Swift::Void) {
        self.save = save
        self.audit = audit
        self.archive = archive
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
///
/// On iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, and Mac Catalyst 17 and later it is
/// `Observable`, so a SwiftUI view can read it directly. Each tracked member registers a read of
/// its own value only: `currentSnapshot` and `snapshot()`, `runningCount`, `subscriberCount`,
/// and `pendingCompletions()`.
@Swift::MainActor internal final class MainActorHost: StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeMainActorHost<Editor, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That is the same as the result arriving a moment later, when its edge would run
    /// against the newer phase anyway; work that must not survive a change is revoked by the
    /// edge's `invalidates:` instead. `.manual` never prepares a completion again on its own.
    /// Either form can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion's
    /// status becomes `reconciliationRequired`: its completion edge or router threw, its effect
    /// plan is defective, the owner refused its admission, an explicit `reconcile(id:)` did not
    /// commit, or, under `.manual`, its preparation lost a race. Settle it with
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
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own, and notifies no one: every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh authority and immutable execution selections.
    internal init(_ initial: Draft = _StateMachineSchema.Draft(), drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.draft(initial), scopes: [], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(), authority: raw.ticket))
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
    internal init(restoring saved: String, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(), authority: raw.ticket))
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
    internal convenience init(_ initial: Draft = _StateMachineSchema.Draft(),
        saveDriver: @escaping @Swift::MainActor (Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Swift::MainActor () async -> Swift::Void,
        archiveDriver: @escaping @Swift::MainActor () async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: MainActorDrivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: String,
        saveDriver: @escaping @Swift::MainActor (Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Swift::MainActor () async -> Swift::Void,
        archiveDriver: @escaping @Swift::MainActor () async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(restoring: saved, drivers: MainActorDrivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation; reading it registers a read of the snapshot with Observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// The current complete snapshot; reading it registers a read of the snapshot with Observation.
internal var currentSnapshot: Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
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
    /// Subscribes to initial, accepted and terminal complete snapshots, taking a subscriber slot when called.
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
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// The first element is the collection current at registration, and each later one the
    /// collection after a change to it, in the order of those changes; a newer collection
    /// replaces one not yet read. Closing delivers a final, empty collection, and it then ends.
    /// It also ends when this owner is released, when its `cancel()` is called, or when a
    /// read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Editor, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Editor, Effect>) -> DiscardResult {
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
    /// full, and then changes nothing; it queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [])
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data, in a fresh
    /// incarnation, exactly as `reset(to:)` does; the saved data never resumes work.
    @discardableResult
    internal func reset(restoring saved: String) throws(CommitRejection) -> Receipt {
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
    internal func reset(restoring saved: String, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
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
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    internal var runningCount: Swift::Int {
        host.runningCount
    }
    /// Live observer registrations; reading it registers a read of the count with Observation.
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
internal let save: @Sendable (Save.Input) async -> Swift::Void
    /// Executes one typed operation outside admission locks.
    internal let audit: @Sendable () async -> Swift::Void
    /// Executes one typed operation outside admission locks.
    internal let archive: @Sendable () async -> Swift::Void
    /// Selects all drivers for this owner.
    internal init(save: @escaping @Sendable (Save.Input) async -> Swift::Void, audit: @escaping @Sendable () async -> Swift::Void, archive: @escaping @Sendable () async -> Swift::Void) {
        self.save = save
        self.audit = audit
        self.archive = archive
    }
}

/// A synchronous shared owner with managed physical execution and terminal delivery.
internal final class Shared: Swift::Sendable, StateMachine::SharedStateMachineHost {
    private typealias Host = StateMachine::RuntimeSharedHost<Editor, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That is the same as the result arriving a moment later, when its edge would run
    /// against the newer phase anyway; work that must not survive a change is revoked by the
    /// edge's `invalidates:` instead. `.manual` never prepares a completion again on its own.
    /// Either form can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion's
    /// status becomes `reconciliationRequired`: its completion edge or router threw, its effect
    /// plan is defective, the owner refused its admission, an explicit `reconcile(id:)` did not
    /// commit, or, under `.manual`, its preparation lost a race. Settle it with
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
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own, and notifies no one: every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh initial authority and retains the driver selection immutably.
    internal init(_ initial: Draft = _StateMachineSchema.Draft(), drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.draft(initial), scopes: [], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Sendable () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(), authority: raw.ticket))
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
    internal init(restoring saved: String, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Sendable () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(), authority: raw.ticket))
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
    internal convenience init(_ initial: Draft = _StateMachineSchema.Draft(),
        saveDriver: @escaping @Sendable (Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Sendable () async -> Swift::Void,
        archiveDriver: @escaping @Sendable () async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: Drivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: String,
        saveDriver: @escaping @Sendable (Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Sendable () async -> Swift::Void,
        archiveDriver: @escaping @Sendable () async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(restoring: saved, drivers: Drivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
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
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// Routes, prepares and admits one input in a single attempt.
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
    /// The first element is the collection current at registration, and each later one the
    /// collection after a change to it, in the order of those changes; a newer collection
    /// replaces one not yet read. Closing delivers a final, empty collection, and it then ends.
    /// It also ends when this owner is released, when its `cancel()` is called, or when a
    /// read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeSharedHost<Editor, Effect, Completion, PreparationRejection>.Delivery, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeSharedHost<Editor, Effect, Completion, PreparationRejection>.Delivery) -> DiscardResult {
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
    /// full, and then changes nothing; it queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [])
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data, in a fresh
    /// incarnation, exactly as `reset(to:)` does; the saved data never resumes work.
    @discardableResult
    internal func reset(restoring saved: String) throws(CommitRejection) -> Receipt {
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
    internal func reset(restoring saved: String, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
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
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
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
    private typealias Host = StateMachine::RuntimeActorHost<Editor, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That is the same as the result arriving a moment later, when its edge would run
    /// against the newer phase anyway; work that must not survive a change is revoked by the
    /// edge's `invalidates:` instead. `.manual` never prepares a completion again on its own.
    /// Either form can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion's
    /// status becomes `reconciliationRequired`: its completion edge or router threw, its effect
    /// plan is defective, the owner refused its admission, an explicit `reconcile(id:)` did not
    /// commit, or, under `.manual`, its preparation lost a race. Settle it with
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
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own, and notifies no one: every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
        /// Creates fresh authority and immutable execution selections.
    ///
    /// With `isolatedTo`, the owner's actor runs on that actor's serial executor, so their turns
    /// never overlap; calls into the owner still await.
        internal init(_ initial: Draft = _StateMachineSchema.Draft(), drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry, isolatedTo: (any Swift::Actor)? = nil) {
            host = Host(.draft(initial), scopes: [], configuration: configuration,
                policy: completionPolicy.runtime, driver: { raw in
        let execution: @Sendable () async -> Completion
        switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(), authority: raw.ticket))
                }
                }
        return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired, isolatedTo: isolatedTo)
        }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    internal init(restoring saved: String, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry, isolatedTo: (any Swift::Actor)? = nil) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Sendable () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(), authority: raw.ticket))
                }
                }
    return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired, isolatedTo: isolatedTo)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    internal convenience init(_ initial: Draft = _StateMachineSchema.Draft(),
        saveDriver: @escaping @Sendable (Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Sendable () async -> Swift::Void,
        archiveDriver: @escaping @Sendable () async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry,
        isolatedTo: (any Swift::Actor)? = nil) {
        self.init(initial, drivers: Drivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy, isolatedTo: isolatedTo)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: String,
        saveDriver: @escaping @Sendable (Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Sendable () async -> Swift::Void,
        archiveDriver: @escaping @Sendable () async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry,
        isolatedTo: (any Swift::Actor)? = nil) {
        self.init(restoring: saved, drivers: Drivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy, isolatedTo: isolatedTo)
    }
    /// Captures a complete historical observation.
    internal func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }

    /// Routes, prepares and admits one input in a single isolated turn without suspension.
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
    /// Subscribes to initial, accepted and terminal complete snapshots, taking a subscriber slot when called.
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
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// The first element is the collection current at registration, and each later one the
    /// collection after a change to it, in the order of those changes; a newer collection
    /// replaces one not yet read. Closing delivers a final, empty collection, and it then ends.
    /// It also ends when this owner is released, when its `cancel()` is called, or when a
    /// read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) async -> DiscardResult {
        Self.discarded(await host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Editor, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Editor, Effect>) -> DiscardResult {
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
    /// full, and then changes nothing; it queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft()) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.draft(initial), scopes: [])
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft(), expecting expected: Snapshot) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.draft(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data, in a fresh
    /// incarnation, exactly as `reset(to:)` does; the saved data never resumes work.
    @discardableResult
    internal func reset(restoring saved: String) async throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = await host.reset(restored.model, scopes: restored.scopes)
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
    internal func reset(restoring saved: String, expecting expected: Snapshot) async throws(CommitRejection) -> Receipt {
        let restored = _stateMachineRestored(saved)
        let result = await host.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
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
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
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
    /// Live observer registrations.
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
/// the actor as a defaulted `isolated` parameter: inside the actor a call reads `host.send(input)`,
/// and a call from another actor or a nonisolated context does not compile. A method that receives
/// a different instance of the actor's type stops the program.
///
/// Drivers run on the owning actor and receive it isolated, so they can read and
/// change its state without capturing the actor.
/// Its observation callbacks and the completion policy's handler run there too.
///
/// The host holds its actor weakly, so an idle actor that stores it is released with it. A running
/// driver retains the actor, because it runs on it; `close()` or `shutdown()` requests the drivers'
/// cancellation, and the actor is released after each driver returns. A closure that captures the
/// actor keeps it alive while the host or registration holding the closure lasts, so a driver or
/// handler, which the host holds for its lifetime, should use the actor it receives instead.
internal final class IsolatedHost<Owner: Swift::Actor>: StateMachine::IsolatedStateMachineHost {
    private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, Editor, Effect, Completion, PreparationRejection>
    private let host: Host
        /// Immutable operation selections, each run on the owning actor, which it receives isolated.
    ///
    /// A driver reaches the actor's state through that parameter, so it captures nothing confined.
    internal struct Drivers: Swift::Sendable {
        /// Executes this operation on the owning actor, which it receives isolated.
    internal let save: @Sendable (isolated Owner, Save.Input) async -> Swift::Void
    /// Executes this operation on the owning actor, which it receives isolated.
    internal let audit: @Sendable (isolated Owner) async -> Swift::Void
    /// Executes this operation on the owning actor, which it receives isolated.
    internal let archive: @Sendable (isolated Owner) async -> Swift::Void
        /// Selects every driver for this owner's lifetime.
        internal init(save: @escaping @Sendable (isolated Owner, Save.Input) async -> Swift::Void, audit: @escaping @Sendable (isolated Owner) async -> Swift::Void, archive: @escaping @Sendable (isolated Owner) async -> Swift::Void) {
        self.save = save
        self.audit = audit
        self.archive = archive
    }
    }
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That is the same as the result arriving a moment later, when its edge would run
    /// against the newer phase anyway; work that must not survive a change is revoked by the
    /// edge's `invalidates:` instead. `.manual` never prepares a completion again on its own.
    /// Either form can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion's
    /// status becomes `reconciliationRequired`: its completion edge or router threw, its effect
    /// plan is defective, the owner refused its admission, an explicit `reconcile(id:)` did not
    /// commit, or, under `.manual`, its preparation lost a race. Settle it with
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
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own, and notifies no one: every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh authority confined to `isolation`, with immutable execution selections.
    internal init(_ initial: Draft = _StateMachineSchema.Draft(), isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.draft(initial), scopes: [], isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(owner, input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(owner), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(owner), authority: raw.ticket))
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
    internal init(restoring saved: String, isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .save(let input):
                    execution = {
                    .save(SaveCompletion(value: await drivers.save(owner, input), request: SaveRequest(input: input), authority: raw.ticket))
                }
                case .audit:
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(owner), authority: raw.ticket))
                }
                case .archive:
                    execution = {
                    .archive(ArchiveCompletion(value: await drivers.archive(owner), authority: raw.ticket))
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
    internal convenience init(_ initial: Draft = _StateMachineSchema.Draft(),
        isolation: isolated Owner,
        saveDriver: @escaping @Sendable (isolated Owner, Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Sendable (isolated Owner) async -> Swift::Void,
        archiveDriver: @escaping @Sendable (isolated Owner) async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, isolation: isolation, drivers: Drivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: String,
        isolation: isolated Owner,
        saveDriver: @escaping @Sendable (isolated Owner, Save.Input) async -> Swift::Void,
        auditDriver: @escaping @Sendable (isolated Owner) async -> Swift::Void,
        archiveDriver: @escaping @Sendable (isolated Owner) async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(restoring: saved, isolation: isolation, drivers: Drivers(save: saveDriver, audit: auditDriver, archive: archiveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    internal func snapshot(isolation: isolated Owner = #isolation) -> Snapshot {
        _stateMachineSnapshot(host.snapshot(isolation: isolation))
    }
    /// Routes, prepares and admits one input in a single turn of the owning actor, without suspension.
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
    /// Subscribes to initial, accepted and terminal complete snapshots, delivered on the owning actor, taking a subscriber slot when called.
    ///
    /// The registration stays in the owning actor's region, and only that actor can cancel it, which
    /// removes the registration before returning, so none of its callbacks begins afterward. Cancelling
    /// releases the callbacks before it returns, except while this owner is delivering a change, as when
    /// another observer's callback cancels: that delivery keeps the callbacks it selected until it has
    /// delivered the change to its other observers, and releases them then. Dropping the registration
    /// stops delivery and frees its slot at once; this owner releases its callbacks when it next sweeps
    /// its registrations or is destroyed.
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
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// Ending it on another actor stops delivery and frees its slot at once; this owner releases
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
    /// The first element is the collection current at registration, and each later one the
    /// collection after a change to it, in the order of those changes; a newer collection
    /// replaces one not yet read. Closing delivers a final, empty collection, and it then ends.
    /// It also ends when this owner is released, when its `cancel()` is called, or when a
    /// read finds its task cancelled. A consumer that keeps it after it stops reading
    /// calls `cancel()`, from any isolation domain, which frees its subscriber slot before it
    /// returns; a read already handed an element by then still returns it.
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID, isolation: isolated Owner = #isolation) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw, isolation: isolation))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Editor, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Editor, Effect>) -> DiscardResult {
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
    /// full, and then changes nothing; it queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft(), isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [], isolation: isolation)
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal func reset(to initial: Draft = _StateMachineSchema.Draft(), expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.draft(initial), scopes: [], expecting: expected.record, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data, in a fresh
    /// incarnation, exactly as `reset(to:)` does; the saved data never resumes work.
    @discardableResult
    internal func reset(restoring saved: String, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
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
    internal func reset(restoring saved: String, expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
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
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
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
    phases.append(_StateMachineGraph.Phase(id: "failed", payload: "Failed"))
    phases.append(_StateMachineGraph.Phase(id: "closed", payload: "Closed"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "edit", payload: "String"))
    inputs.append(_StateMachineGraph.Input(id: "retry", payload: nil))
    inputs.append(_StateMachineGraph.Input(id: "close", payload: nil))
    inputs.append(_StateMachineGraph.Input(id: "pick", payload: "Int"))
    var operations: [_StateMachineGraph.Operation] = []
    operations.append(_StateMachineGraph.Operation(id: "Save", effect: "save", scope: nil,
        requires: [], activeIn: ["saving"], admission: .latest,
        key: nil, input: "String", output: "Swift::Void",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    operations.append(_StateMachineGraph.Operation(id: "Audit", effect: "audit", scope: nil,
        requires: [], activeIn: ["saving"], admission: .latest,
        key: nil, input: "Swift::Void", output: "Swift::Void",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    operations.append(_StateMachineGraph.Operation(id: "Archive", effect: "archive", scope: nil,
        requires: [], activeIn: ["closed"], admission: .latest,
        key: nil, input: "Swift::Void", output: "Swift::Void",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "draft.edit", name: "edit",
        source: "draft", destination: "draft", trigger: .input("edit"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "saving.edit", name: "edit",
        source: "saving", destination: "saving", trigger: .input("edit"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "draft.retry", name: "retry",
        source: "draft", destination: "saving", trigger: .input("retry"),
        router: nil, starts: ["Save"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "failed.retry", name: "retry",
        source: "failed", destination: "saving", trigger: .input("retry"),
        router: nil, starts: ["Save", "Audit"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "draft.close", name: "close",
        source: "draft", destination: "closed", trigger: .input("close"),
        router: nil, starts: ["Archive"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "failed.close", name: "close",
        source: "failed", destination: "closed", trigger: .input("close"),
        router: nil, starts: ["Archive"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "failed.keep", name: "keep",
        source: "failed", destination: "failed", trigger: .input("pick"),
        router: "failed.pick", starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "failed.discard", name: "discard",
        source: "failed", destination: "draft", trigger: .input("pick"),
        router: "failed.pick", starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "saving.saved", name: "saved",
        source: "saving", destination: "draft", trigger: .success("Save"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "saving.audited", name: "audited",
        source: "saving", destination: "saving", trigger: .success("Audit"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "closed.archived", name: "archived",
        source: "closed", destination: "closed", trigger: .success("Archive"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    var routers: [_StateMachineGraph.Router] = []
    routers.append(_StateMachineGraph.Router(id: "failed.pick", name: "pick",
        source: "failed", trigger: .input("pick"),
        candidates: ["failed.keep", "failed.discard"]))
    return .init(
        name: "Editor",
        mode: .shared,
        owners: [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost],
        initial: "draft",
        terminal: [],
        restorable: ["draft", "failed"],
        phases: phases,
        inputs: inputs,
        scopes: [],
        operations: operations,
        events: [],
        edges: edges,
        routers: routers
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

/// The schema, for generated code that names it where a value of its name could take the name.
internal typealias _StateMachineSchema = Sketch

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Sketch' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Sketch'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> _TriggerPayloadMatchesDeclaration<Value> {
    _TriggerPayloadMatchesDeclaration<Value>()
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

@available(*, unavailable, message: "Operation 'Render' takes Never as its input, so no transition can start it; declare an input type that has values, or remove the operation.")
fileprivate static func _stateMachineIsNotSwiftNever(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineConformsToSwiftEquatable<Value: Swift::Equatable>(_ type: Value.Type) {
}

@available(*, unavailable, message: "The schema's inheritance clause names Equatable, which the macro reads as the standard library's Swift::Equatable that generated effects and restorations repeat, but the schema does not conform to it; write Swift::Equatable in the inheritance clause, or name the protocol through its module.")
fileprivate static func _stateMachineConformsToSwiftEquatable<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    _stateMachineConformsToSwiftEquatable(Self.self)
    do {
        typealias _StateMachineChecked = Render.Input;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    let _: _TransitionSourceIsPhasePayload<Blank> = _TransitionSourceIsPhasePayload<Blank>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Drawn, Effect.Draw>> = _TransitionReturnsDeclaredResult<Change<Drawn, Effect.Draw>>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .draw(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Int> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionReturnsDeclaredResult<Blank> = _TransitionReturnsDeclaredResult<Blank>()
    let _: _TransitionSourceIsPhasePayload<Drawn> = _TransitionSourceIsPhasePayload<Drawn>()
    let _: _TransitionReturnsDeclaredResult<Drawn> = _TransitionReturnsDeclaredResult<Drawn>()


    let _ = _EffectIsCopyable<Effect>()

}

/// Inert descriptions of the operations this workflow can start.
internal enum Effect: ~Swift::Sendable, Swift::Equatable {
    case render(Sketch.Render.Input)
    /// The operations `draw` may start.
internal enum Draw: ~Swift::Sendable, Swift::Equatable {
    case render(Sketch.Render.Input)
    /// The schema-wide effect this value describes.
    internal var effect: Sketch.Effect {
        switch self {
        case .render(let input):
            return .render(input)
        }
    }
    }
    /// The effect vocabularies of the edges from `Blank`.
    internal enum Blank {
        internal typealias Draw = Sketch.Effect.Draw
    }
}

/// What one `Render` execution was started with, as admission accepted it.
internal typealias RenderRequest = StateMachine::OperationRequest<Render, Render.Input>

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
internal consuming func draw(_ input: Int) -> StateMachine::Change<Owned<Drawn>, Effect.Draw> where Phase == Blank {
    let change = _StateMachineSchema.draw(phase, input)
    return .init(Owned<Drawn>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func erase() -> Owned<Blank> where Phase == Blank {
        Owned<Blank>(_StateMachineSchema.erase())
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func erase() -> Owned<Blank> where Phase == Drawn {
        Owned<Blank>(_StateMachineSchema.erase())
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func rendered() -> Owned<Drawn> where Phase == Drawn {
        Owned<Drawn>(_StateMachineSchema.rendered(phase))
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Blank) -> Owned<Blank> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Sketch, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = StateMachine::ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = StateMachine::Limits

/// A live observation registration with an owner confined to the actor `Owner`; only that actor can cancel it, which removes it, and dropping it stops delivery.
internal typealias IsolatedSubscription<Owner: Swift::Actor> = StateMachine::IsolatedSnapshotSubscription<Owner>

/// A live MainActor observation registration; cancelling or releasing it stops delivery.
internal typealias MainActorSubscription = StateMachine::MainActorSnapshotSubscription

/// Failure to register another live observer.
internal typealias SubscriptionFailure = StateMachine::SubscriptionFailure

/// A single-consumer latest-value stream of a MainActor owner's snapshots.
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
internal func draw(_ input: Int) -> Prepared where Phase == Blank {
    let change: StateMachine::Change<Drawn, Effect.Draw> = _StateMachineSchema.draw(payload, input)
    return _stateMachinePrepare(on: record, next: .drawn(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 1, invalidates: [],
        requiring: nil, claim: claim, edge: "blank.draw")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func erase() -> Prepared where Phase == Blank {
        let next: Blank = _StateMachineSchema.erase()
        return _stateMachinePrepare(on: record, next: .blank(next),
            effects: [],
            from: 0, to: 0, invalidates: [],
            requiring: nil, claim: claim, edge: "blank.erase")
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func erase() -> Prepared where Phase == Drawn {
        let next: Blank = _StateMachineSchema.erase()
        return _stateMachinePrepare(on: record, next: .blank(next),
            effects: [],
            from: 1, to: 0, invalidates: [],
            requiring: nil, claim: claim, edge: "drawn.erase")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func rendered(_ value: Swift::Void, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Drawn {
        let next: Drawn = _StateMachineSchema.rendered(payload)
        return _stateMachinePrepare(on: record, next: .drawn(next),
            effects: [],
            from: 1, to: 1, invalidates: [],
            requiring: authority, claim: claim, edge: "drawn.rendered")
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
    case blank(Observed<Blank>)
    case drawn(Observed<Drawn>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .blank(let value):
            return value.record
        case .drawn(let value):
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
    /// Ordinary model data; constructing it confers no installation authority.
    internal var model: Sketch {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        switch self {
        case .blank(let value):
            return "blank, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .drawn(let value):
            return "drawn, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .blank(let payload):
        return .blank(Observed(payload: payload, record: record, claim: claim))
    case .drawn(let payload):
        return .drawn(Observed(payload: payload, record: record, claim: claim))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .blank:
        return "blank"
    case .drawn:
        return "drawn"
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
    /// change that takes no edge: a reset, closure, or the authority-only commit of
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
    /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`);
    /// read `snapshot()` for the current root.
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
internal typealias RenderWork = _RenderWork<Swift::Void>

/// The work of `Render`, generic over its output so that it seals an output of any type.
internal struct _RenderWork<_StateMachineOutput> {
    /// What admission started this work with.
internal let request: RenderRequest

    /// The immutable declared input.
internal var input: Render.Input {
        request.input
    }
    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: _StateMachineOutput) -> RenderCompletion where _StateMachineOutput == Swift::Void {
        RenderCompletion(value: value, request: request, authority: authority)
    }
    /// Seals a successful terminal result that carries no value.
internal func succeeded() -> RenderCompletion where _StateMachineOutput == Swift::Void {
        succeeded(())
    }

}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct RenderCompletion {
    /// The value the operation produced; it cannot fail.
    internal let value: Swift::Void
    /// What admission started the work with.
internal let request: RenderRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Closed typed terminal outcomes for this domain.
internal enum Completion {
    case render(RenderCompletion)
    fileprivate var authority: StateMachine::RuntimeTicket {
        switch self {
        case .render(let value):
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
    case render(RenderWork)
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
            case .render(let input):
                return .render(RenderWork(request: RenderRequest(input: input), authority: work.ticket))
            }
        case .emit:
            Swift::preconditionFailure("A schema without events emits nothing.")
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    [[1]]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Sketch, effects: [Effect], from: Swift::Int, to: Swift::Int,
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
        for effect in effects {
            switch effect {
            case .render(let input):
                let _: Render.Input = input
                counts[0] += 1
                guard counts[0] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 0, scope: _StateMachineScopeID(kind: 0),
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
/// A plan defect is not a routing rejection: it travels inside the result, and admission reports it.
internal static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch input {
    case .draw(let input):
        switch snapshot {
        case .blank(let source):
            return source.draw(input)
        default:
            throw .invalidPhase
        }
    case .erase:
        switch snapshot {
        case .blank(let source):
            return source.erase()
        case .drawn(let source):
            return source.erase()
        }
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch completion {
    case .render(let completion):
        switch snapshot {
        case .drawn(let source):
            let value: Swift::Void = completion.value
            return source.rendered(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    }
}

/// A phase saved data can restore: one in which no operation is active. A restored owner has no outstanding work.
internal enum Restoration: Swift::Equatable {
    case blank(Blank)
}

fileprivate typealias _StateMachineLedger = StateMachine::RuntimeDeliveryLedger<Sketch, Effect, Completion, PreparationRejection>

/// A single-consumer latest-value stream of a MainActor owner's retained completions.
internal typealias PendingCompletionUpdates = StateMachine::MainActorSnapshotSequence<[PendingCompletion]>

/// A single-consumer latest-value stream of the retained completions of an owner confined to one actor.
internal typealias IsolatedPendingCompletionUpdates = StateMachine::IsolatedSnapshotSequence<[PendingCompletion]>

/// The opaque identity of one retained terminal outcome of this schema's owners.
internal struct PendingCompletionID: Swift::Hashable, Swift::Sendable {
    fileprivate let raw: StateMachine::RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value: only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
internal struct PendingCompletion {
    /// The retained terminal value of one operation, with the request its work was started with.
    internal enum Outcome {
        case render(Swift::Void, request: Sketch.RenderRequest)
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
    /// The saturating count of claimed preparations; capacity retries do not increment it.
    internal let attempts: Swift::UInt64
    /// Whether the preparation count has reached its representable limit.
    internal var attemptsSaturated: Swift::Bool {
        attempts == Swift::UInt64.max
    }
    fileprivate init(_ pending: _StateMachineLedger.Pending) {
        id = PendingCompletionID(raw: pending.id)
        switch pending.outcome {
        case .render(let completion):
            outcome = .render(completion.value, request: completion.request)
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
    /// The outcome is retained; its status says what admission is waiting for.
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
    /// The outcome is still retained; its status says what admission is waiting for.
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
    /// The owner refused the authority-only commit; the outcome stays retained.
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
    /// The deadline passed first; the diagnostics describe what was still outstanding.
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
internal struct Local: ~Swift::Copyable, StateMachine::DeliveringLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
internal typealias Input = Sketch.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Snapshot = Sketch.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Receipt = Sketch.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias SendRejection = Sketch.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Prepared = Sketch.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommitResult = Sketch.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias InitialPhase = Blank
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Command = Sketch.Command
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommandBatch = Sketch.CommandBatch
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Completion = Sketch.Completion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ExecutionHandle = Sketch.ExecutionHandle
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletionID = Sketch.PendingCompletionID
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias PendingCompletion = Sketch.PendingCompletion
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DeliveryResult = Sketch.DeliveryResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias ReconcileResult = Sketch.ReconcileResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias DiscardResult = Sketch.DiscardResult
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
    internal init(_ initial: Blank, configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.blank(initial), scopes: [], limits: configuration, recording: .commands)
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
    /// Routes, prepares and admits one input against the current root.
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
    /// Transfers whole FIFO batches, at most `limit` of them; physical execution occurs after mutating access ends.
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
    /// replaces the retained one; it reports that outcome's status instead.
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
    /// Delivers the sealed terminal result of one `Render` execution.
    internal mutating func deliver(_ completion: RenderCompletion) -> DeliveryResult {
        deliver(.render(completion))
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
    /// Draining and acknowledging never admit a retained completion; call this after they free capacity.
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
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
    /// full, and then changes nothing; it queues a batch only to cancel the work it revokes, so it needs a slot only then.
    @discardableResult
    internal mutating func reset(to initial: Blank) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.blank(initial), scopes: [])
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal mutating func reset(to initial: Blank, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.blank(initial), scopes: [], expecting: expected.record)
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

/// Immutable operation selections whose non-Sendable values stay within MainActor.
@Swift::MainActor internal struct MainActorDrivers {
    /// Executes this operation within the selected isolation.
internal let render: @Swift::MainActor (Render.Input) async -> Swift::Void
    /// Selects every driver for this owner's lifetime.
    internal init(render: @escaping @Swift::MainActor (Render.Input) async -> Swift::Void) {
        self.render = render
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
///
/// On iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, and Mac Catalyst 17 and later it is
/// `Observable`, so a SwiftUI view can read it directly. Each tracked member registers a read of
/// its own value only: `currentSnapshot` and `snapshot()`, `runningCount`, `subscriberCount`,
/// and `pendingCompletions()`.
@Swift::MainActor internal final class MainActorHost: StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeMainActorHost<Sketch, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That is the same as the result arriving a moment later, when its edge would run
    /// against the newer phase anyway; work that must not survive a change is revoked by the
    /// edge's `invalidates:` instead. `.manual` never prepares a completion again on its own.
    /// Either form can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion's
    /// status becomes `reconciliationRequired`: its completion edge or router threw, its effect
    /// plan is defective, the owner refused its admission, an explicit `reconcile(id:)` did not
    /// commit, or, under `.manual`, its preparation lost a race. Settle it with
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
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own, and notifies no one: every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh authority and immutable execution selections.
    internal init(_ initial: Blank, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.blank(initial), scopes: [], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .render(let input):
                    execution = {
                    .render(RenderCompletion(value: await drivers.render(input), request: RenderRequest(input: input), authority: raw.ticket))
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
    internal convenience init(_ initial: Blank,
        renderDriver: @escaping @Swift::MainActor (Render.Input) async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: MainActorDrivers(render: renderDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation; reading it registers a read of the snapshot with Observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// The current complete snapshot; reading it registers a read of the snapshot with Observation.
internal var currentSnapshot: Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
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
    /// Subscribes to initial, accepted and terminal complete snapshots, taking a subscriber slot when called.
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
    /// The first element is the collection current at registration, and each later one the
    /// collection after a change to it, in the order of those changes; a newer collection
    /// replaces one not yet read. Closing delivers a final, empty collection, and it then ends.
    /// It also ends when this owner is released, when its `cancel()` is called, or when a
    /// read finds its task cancelled. A consumer that keeps it after it stops reading
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Sketch, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Sketch, Effect>) -> DiscardResult {
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
    /// full, and then changes nothing; it queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Blank) throws(CommitRejection) -> Receipt {
        let result = host.reset(.blank(initial), scopes: [])
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal func reset(to initial: Blank, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.blank(initial), scopes: [], expecting: expected.record)
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
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    internal var runningCount: Swift::Int {
        host.runningCount
    }
    /// Live observer registrations; reading it registers a read of the count with Observation.
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
/// the actor as a defaulted `isolated` parameter: inside the actor a call reads `host.send(input)`,
/// and a call from another actor or a nonisolated context does not compile. A method that receives
/// a different instance of the actor's type stops the program.
///
/// Drivers run on the owning actor and receive it isolated, so they can read and
/// change its state without capturing the actor.
/// Its observation callbacks and the completion policy's handler run there too.
///
/// The host holds its actor weakly, so an idle actor that stores it is released with it. A running
/// driver retains the actor, because it runs on it; `close()` or `shutdown()` requests the drivers'
/// cancellation, and the actor is released after each driver returns. A closure that captures the
/// actor keeps it alive while the host or registration holding the closure lasts, so a driver or
/// handler, which the host holds for its lifetime, should use the actor it receives instead.
internal final class IsolatedHost<Owner: Swift::Actor>: StateMachine::IsolatedStateMachineHost {
    private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, Sketch, Effect, Completion, PreparationRejection>
    private let host: Host
        /// Immutable operation selections, each run on the owning actor, which it receives isolated.
    ///
    /// A driver reaches the actor's state through that parameter, so it captures nothing confined.
    internal struct Drivers: Swift::Sendable {
        /// Executes this operation on the owning actor, which it receives isolated.
    internal let render: @Sendable (isolated Owner, Render.Input) async -> Swift::Void
        /// Selects every driver for this owner's lifetime.
        internal init(render: @escaping @Sendable (isolated Owner, Render.Input) async -> Swift::Void) {
        self.render = render
    }
    }
    /// How this owner settles a retained completion that does not commit when it is delivered.
    ///
    /// `.retry` prepares a completion again against the newer state when another commit wins the
    /// race. That is the same as the result arriving a moment later, when its edge would run
    /// against the newer phase anyway; work that must not survive a change is revoked by the
    /// edge's `invalidates:` instead. `.manual` never prepares a completion again on its own.
    /// Either form can pass each completion that needs reconciliation to a handler.
    ///
    /// Initializers default to `.retry`.
    ///
    /// A handler runs outside the owner's critical section each time a retained completion's
    /// status becomes `reconciliationRequired`: its completion edge or router threw, its effect
    /// plan is defective, the owner refused its admission, an explicit `reconcile(id:)` did not
    /// commit, or, under `.manual`, its preparation lost a race. Settle it with
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
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retry(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own, and notifies no one: every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        internal static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh authority confined to `isolation`, with immutable execution selections.
    internal init(_ initial: Blank, isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.blank(initial), scopes: [], isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .render(let input):
                    execution = {
                    .render(RenderCompletion(value: await drivers.render(owner, input), request: RenderRequest(input: input), authority: raw.ticket))
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
    internal convenience init(_ initial: Blank,
        isolation: isolated Owner,
        renderDriver: @escaping @Sendable (isolated Owner, Render.Input) async -> Swift::Void,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, isolation: isolation, drivers: Drivers(render: renderDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    internal func snapshot(isolation: isolated Owner = #isolation) -> Snapshot {
        _stateMachineSnapshot(host.snapshot(isolation: isolation))
    }
    /// Routes, prepares and admits one input in a single turn of the owning actor, without suspension.
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
    /// Subscribes to initial, accepted and terminal complete snapshots, delivered on the owning actor, taking a subscriber slot when called.
    ///
    /// The registration stays in the owning actor's region, and only that actor can cancel it, which
    /// removes the registration before returning, so none of its callbacks begins afterward. Cancelling
    /// releases the callbacks before it returns, except while this owner is delivering a change, as when
    /// another observer's callback cancels: that delivery keeps the callbacks it selected until it has
    /// delivered the change to its other observers, and releases them then. Dropping the registration
    /// stops delivery and frees its slot at once; this owner releases its callbacks when it next sweeps
    /// its registrations or is destroyed.
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
    /// Ending it on another actor stops delivery and frees its slot at once; this owner releases
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
    /// The first element is the collection current at registration, and each later one the
    /// collection after a change to it, in the order of those changes; a newer collection
    /// replaces one not yet read. Closing delivers a final, empty collection, and it then ends.
    /// It also ends when this owner is released, when its `cancel(isolation:)` is called, or when a
    /// read finds its task cancelled. A consumer that keeps it after it stops reading
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
    /// cancellation for it; a reset or closure, by contrast, cancels every ticket it revokes.
    internal func discardPending(id: PendingCompletionID, isolation: isolated Owner = #isolation) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw, isolation: isolation))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Sketch, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Sketch, Effect>) -> DiscardResult {
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
    /// full, and then changes nothing; it queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Blank, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.blank(initial), scopes: [], isolation: isolation)
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
    /// Otherwise it changes nothing and throws as a commit prepared on `expected` would:
    /// `.foreignOwner` for another owner's snapshot, then `.closed`, `.obsoleteIncarnation` after
    /// another reset, or `.conflict` after any other acceptance; and then as `reset(to:)` does.
    @discardableResult
    internal func reset(to initial: Blank, expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.blank(initial), scopes: [], expecting: expected.record, isolation: isolation)
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
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
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
    phases.append(_StateMachineGraph.Phase(id: "blank", payload: "Blank"))
    phases.append(_StateMachineGraph.Phase(id: "drawn", payload: "Drawn"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "draw", payload: "Int"))
    inputs.append(_StateMachineGraph.Input(id: "erase", payload: nil))
    var operations: [_StateMachineGraph.Operation] = []
    operations.append(_StateMachineGraph.Operation(id: "Render", effect: "render", scope: nil,
        requires: [], activeIn: ["drawn"], admission: .latest,
        key: nil, input: "Int", output: "Swift::Void",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "blank.draw", name: "draw",
        source: "blank", destination: "drawn", trigger: .input("draw"),
        router: nil, starts: ["Render"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "blank.erase", name: "erase",
        source: "blank", destination: "blank", trigger: .input("erase"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "drawn.erase", name: "erase",
        source: "drawn", destination: "blank", trigger: .input("erase"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "drawn.rendered", name: "rendered",
        source: "drawn", destination: "drawn", trigger: .success("Render"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    return .init(
        name: "Sketch",
        mode: .isolated,
        owners: [.owned, .local, .mainActorHost, .isolatedHost],
        initial: "blank",
        terminal: [],
        restorable: [],
        phases: phases,
        inputs: inputs,
        scopes: [],
        operations: operations,
        events: [],
        edges: edges,
        routers: []
    )
}
