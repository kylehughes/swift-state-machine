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
public typealias _StateMachineSchema = Flow

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Flow' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Flow'.")
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

fileprivate static func _stateMachineTakesFailure<Value: ~Swift::Copyable>(_ declared: _TriggerPayloadMatchesDeclaration<Value>, _ authored: _TriggerPayloadMatchesDeclaration<Value>) {
}

@available(*, unavailable, message: "A failure edge or router takes its operation's failure in the unlabeled parameter after its source, so that parameter's type must be exactly the operation's Failure; take the request with the argument label request:, or declare the Failure this parameter takes.")
fileprivate static func _stateMachineTakesFailure<Declared: ~Swift::Copyable, Authored: ~Swift::Copyable>(_ declared: _TriggerPayloadMatchesDeclaration<Declared>, _ authored: _TriggerPayloadMatchesDeclaration<Authored>) {
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

@available(*, unavailable, message: "Operation 'Fetch' takes Never as its input, so no transition can start it; declare an input type that has values, or remove the operation.")
fileprivate static func _stateMachineIsNotSwiftNever(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever2(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Fetch' never succeeds: its Output is Never, so its onSuccess: edges and routers can never run; remove them, or declare the Output the operation produces.")
fileprivate static func _stateMachineIsNotSwiftNever2(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever3(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Fetch' cannot fail: its Failure is Never, so its onFailure: edges and routers can never run; remove them, or declare the Failure the operation reports.")
fileprivate static func _stateMachineIsNotSwiftNever3(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever4(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Audit' takes Never as its input, so no transition can start it; declare an input type that has values, or remove the operation.")
fileprivate static func _stateMachineIsNotSwiftNever4(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineIsNotSwiftNever5(_ probe: Swift::Bool) {
}

@available(*, unavailable, message: "Operation 'Audit' never succeeds: its Output is Never, so its onSuccess: edges and routers can never run; remove them, or declare the Output the operation produces.")
fileprivate static func _stateMachineIsNotSwiftNever5(_ probe: _StateMachineReadsNever.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    do {
        typealias _StateMachineChecked = Fetch.Input;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever(probe)
    }
    do {
        typealias _StateMachineChecked = Fetch.Output;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever2(probe)
    }
    do {
        typealias _StateMachineChecked = Fetch.Failure;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever3(probe)
    }
    do {
        typealias _StateMachineChecked = Audit.Input;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever4(probe)
    }
    do {
        typealias _StateMachineChecked = Audit.Output;
        let probe = _stateMachineNeverProbe(_StateMachineChecked.self);
        _stateMachineIsNotSwiftNever5(probe)
    }
    let _: _TransitionSourceIsPhasePayload<Idle> = _TransitionSourceIsPhasePayload<Idle>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Loading, Effect.Begin>> = _TransitionReturnsDeclaredResult<Change<Loading, Effect.Begin>>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .load(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Int> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Idle> = _TransitionReturnsDeclaredResult<Idle>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Loading> = _TransitionReturnsDeclaredResult<Loading>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Change<Loading, Effect.Note>> = _TransitionReturnsDeclaredResult<Change<Loading, Effect.Note>>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .note(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<String> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Loaded> = _TransitionReturnsDeclaredResult<Loaded>()
    _stateMachineTakesOutput(_TriggerPayloadMatchesDeclaration<Fetch.Output>(), _TriggerPayloadMatchesDeclaration<Fetch.Output>())
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Failed> = _TransitionReturnsDeclaredResult<Failed>()
    _stateMachineTakesFailure(_TriggerPayloadMatchesDeclaration<Fetch.Failure>(), _TriggerPayloadMatchesDeclaration<Fetch.Failure>())
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Loading> = _TransitionReturnsDeclaredResult<Loading>()
    _stateMachineTakesOutput(_TriggerPayloadMatchesDeclaration<Audit.Output>(), _TriggerPayloadMatchesDeclaration<Audit.Output>())
    let _: _TransitionSourceIsPhasePayload<Loaded> = _TransitionSourceIsPhasePayload<Loaded>()
    let _: _TransitionReturnsDeclaredResult<Idle> = _TransitionReturnsDeclaredResult<Idle>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .tick(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Bool> = payload;
            case _:
                break
            }
        }
    }
    let _: _TransitionSourceIsPhasePayload<Loaded> = _TransitionSourceIsPhasePayload<Loaded>()
    let _: _TransitionReturnsDeclaredResult<Loaded> = _TransitionReturnsDeclaredResult<Loaded>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .tick(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Bool> = payload;
            case _:
                break
            }
        }
    }
    let _ = _OperationFailureIsError<Fetch.Failure>()
    let _: _RouterSourceIsPhasePayload<Loaded> = _RouterSourceIsPhasePayload<Loaded>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .tick(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Bool> = payload;
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
public enum Effect: Swift::Sendable {
    case fetch(Flow.Fetch.Input)
    case audit(Flow.Audit.Input)
    /// The operations `begin` may start.
public enum Begin: Swift::Sendable {
    case fetch(Flow.Fetch.Input)
    /// The schema-wide effect this value describes.
    public var effect: Flow.Effect {
        switch self {
        case .fetch(let input):
            return .fetch(input)
        }
    }
    }
    /// The operations `note` may start.
    public enum Note: Swift::Sendable {
        case audit(Flow.Audit.Input)
        /// The schema-wide effect this value describes.
        public var effect: Flow.Effect {
        switch self {
        case .audit(let input):
            return .audit(input)
        }
    }
    }
    /// The effect vocabularies of the edges from `Idle`.
    public enum Idle {
        public typealias Begin = Flow.Effect.Begin
    }
    /// The effect vocabularies of the edges from `Loading`.
    public enum Loading {
        public typealias Note = Flow.Effect.Note
    }
}

/// What one `Fetch` execution was started with, as admission accepted it.
public typealias FetchRequest = StateMachine::OperationRequest<Fetch, Fetch.Input>

/// What one `Audit` execution was started with, as admission accepted it.
public typealias AuditRequest = StateMachine::OperationRequest<Audit, Audit.Input>

/// Unique authority over one declared workflow phase.
public struct Owned<Phase: ~Swift::Copyable & Swift::Sendable>: ~Swift::Copyable, Swift::Sendable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
    public borrowing func withValue<Result: ~Swift::Copyable, Failure: Swift::Error>(
        _ body: (borrowing Phase) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(phase)
    }
    /// Consumes this authority and returns its payload, so a unique resource can move on.
    public consuming func takeValue() -> Phase {
        phase
    }
    /// Advances through the authored edge or returns the original predecessor.
public consuming func begin(_ input: Int) -> StateMachine::Advance<Self, Owned<Loading>, Effect.Begin, Problem> where Phase == Idle {
    do {
        let change = try _StateMachineSchema.begin(phase, input)
        return .advanced(Owned<Loading>(change.next), effects: change.effects)
    } catch {
        return .rejected(error, self)
    }
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func cancel() -> Owned<Idle> where Phase == Loading {
        Owned<Idle>(_StateMachineSchema.cancel(phase))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func sessionChanged() -> Owned<Loading> where Phase == Loading {
        Owned<Loading>(_StateMachineSchema.sessionChanged(phase))
    }
    /// Advances through the authored edge, preserving effect order.
    public consuming func note(_ input: String) -> StateMachine::Change<Owned<Loading>, Effect.Note> where Phase == Loading {
        let change = _StateMachineSchema.note(phase, input)
        return .init(Owned<Loading>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func received(_ input: Fetch.Output) -> Owned<Loaded> where Phase == Loading {
        Owned<Loaded>(_StateMachineSchema.received(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func failed(_ input: Fetch.Failure) -> Owned<Failed> where Phase == Loading {
        Owned<Failed>(_StateMachineSchema.failed(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func audited(_ input: Audit.Output) -> Owned<Loading> where Phase == Loading {
        Owned<Loading>(_StateMachineSchema.audited(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    fileprivate consuming func restart(_ input: Bool) -> Owned<Idle> where Phase == Loaded {
        Owned<Idle>(_StateMachineSchema.restart(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    fileprivate consuming func keep(_ input: Bool) -> Owned<Loaded> where Phase == Loaded {
        Owned<Loaded>(_StateMachineSchema.keep(phase, input))
    }
    /// Runs the router `choose`, then advances through the edge it selects.
public consuming func choose(_ input: Bool) -> Route.ChooseResult where Phase == Loaded {
    let selection: Route.Choose
    do {
        selection = try _StateMachineSchema.choose(phase, input)
    } catch {
        return .rejected(error, self)
    }
    switch selection {
    case .restart:
        return .restart(self.restart(input))
    case .keep:
        return .keep(self.keep(input))
    }
    }
}

/// Creates ownership only in the declared initial phase.
public static func owned(_ initial: consuming Idle = _StateMachineSchema.makeIdle()) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Flow, Effect>

/// Validated bounds for managed admission and serial subscriptions.
public typealias Configuration = StateMachine::ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
public typealias LocalConfiguration = StateMachine::Limits

/// A live observation registration. Cancelling or releasing it stops delivery.
public typealias Subscription = StateMachine::SnapshotSubscription

/// A live observation registration for an owner confined to `Owner`. Only that actor can cancel and remove it, and releasing it stops delivery.
public typealias IsolatedSubscription<Owner: Swift::Actor> = StateMachine::IsolatedSnapshotSubscription<Owner>

/// A live `MainActor` observation registration. Cancelling or releasing it stops delivery.
public typealias MainActorSubscription = StateMachine::MainActorSnapshotSubscription

/// Failure to register another live observer.
public typealias SubscriptionFailure = StateMachine::SubscriptionFailure

/// A single-pass latest-value sequence of an owner's snapshots.
public typealias Snapshots = StateMachine::SnapshotSequence<Snapshot>

/// The disposition of a retained completion.
public typealias PendingStatus = StateMachine::PendingStatus

/// Why an owner refused a prepared candidate, in precedence order.
public typealias CommitRejection = StateMachine::CommitRejection

/// An immutable historical payload with sealed complete-root provenance.
public struct Observed<Phase: Swift::Sendable>: Swift::Sendable, Swift::CustomStringConvertible {
    fileprivate let payload: Phase
    fileprivate let record: _StateMachineEngine.Snapshot
    fileprivate let claim: StateMachine::RuntimeDeliveryClaim?
    /// The copied historical payload.
    public var value: Phase {
        payload
    }
    /// The owner-lifetime accepted revision.
    public var revision: Swift::UInt64 {
        record.revision
    }
    /// The phase, revision, and closure of this observation, without its payload.
    public var description: Swift::String {
        "\(Phase.self), revision \(record.revision)\(record.isClosed ? ", closed" : "")"
    }
    /// Prepares the declared edge with phase authority preserved.
public func begin(_ input: Int) throws(Problem) -> Prepared where Phase == Idle {
    let change: StateMachine::Change<Loading, Effect.Begin> = try _StateMachineSchema.begin(payload, input)
    return _stateMachinePrepare(on: record, next: .loading(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 1, invalidates: [0],
        requiring: nil, claim: claim, edge: "idle.begin")
    }
    /// Prepares the declared edge with phase authority preserved.
    public func cancel() -> Prepared where Phase == Loading {
        let next: Idle = _StateMachineSchema.cancel(payload)
        return _stateMachinePrepare(on: record, next: .idle(next),
            effects: [],
            from: 1, to: 0, invalidates: [0],
            requiring: nil, claim: claim, edge: "loading.cancel")
    }
    /// Prepares the declared edge with phase authority preserved.
    public func sessionChanged() -> Prepared where Phase == Loading {
        let next: Loading = _StateMachineSchema.sessionChanged(payload)
        return _stateMachinePrepare(on: record, next: .loading(next),
            effects: [],
            from: 1, to: 1, invalidates: [1],
            requiring: nil, claim: claim, edge: "loading.sessionChanged")
    }
    /// Prepares the declared edge with phase authority preserved.
    public func note(_ input: String) -> Prepared where Phase == Loading {
        let change: StateMachine::Change<Loading, Effect.Note> = _StateMachineSchema.note(payload, input)
        return _stateMachinePrepare(on: record, next: .loading(change.next),
            effects: change.effects.map(\.effect),
            from: 1, to: 1, invalidates: [],
            requiring: nil, claim: claim, edge: "loading.note")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func received(_ value: Fetch.Output, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Loading {
        let next: Loaded = _StateMachineSchema.received(payload, value)
        return _stateMachinePrepare(on: record, next: .loaded(next),
            effects: [],
            from: 1, to: 2, invalidates: [],
            requiring: authority, claim: claim, edge: "loading.received")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func failed(_ value: Fetch.Failure, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Loading {
        let next: Failed = _StateMachineSchema.failed(payload, value)
        return _stateMachinePrepare(on: record, next: .failed(next),
            effects: [],
            from: 1, to: 3, invalidates: [],
            requiring: authority, claim: claim, edge: "loading.failed")
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func audited(_ value: Audit.Output, authority: StateMachine::RuntimeTicket) -> Prepared where Phase == Loading {
        let next: Loading = _StateMachineSchema.audited(payload, value)
        return _stateMachinePrepare(on: record, next: .loading(next),
            effects: [],
            from: 1, to: 1, invalidates: [],
            requiring: authority, claim: claim, edge: "loading.audited")
    }
    /// Prepares the declared edge that the router `choose` selects.
    fileprivate func restart(_ input: Bool) -> Prepared where Phase == Loaded {
        let next: Idle = _StateMachineSchema.restart(payload, input)
        return _stateMachinePrepare(on: record, next: .idle(next),
            effects: [],
            from: 2, to: 0, invalidates: [],
            requiring: nil, claim: claim, edge: "loaded.restart")
    }
    /// Prepares the declared edge that the router `choose` selects.
    fileprivate func keep(_ input: Bool) -> Prepared where Phase == Loaded {
        let next: Loaded = _StateMachineSchema.keep(payload, input)
        return _stateMachinePrepare(on: record, next: .loaded(next),
            effects: [],
            from: 2, to: 2, invalidates: [],
            requiring: nil, claim: claim, edge: "loaded.keep")
    }
    /// Runs the router `choose`, then prepares the edge it selects.
    public func choose(_ input: Bool) throws(Problem) -> Prepared where Phase == Loaded {
        let selection: Route.Choose = try _StateMachineSchema.choose(payload, input)
        switch selection {
    case .restart:
        return self.restart(input)
    case .keep:
        return self.keep(input)
    }
    }
}

/// A complete historical root observation with sealed provenance.
public enum Snapshot: Swift::Sendable, StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
    case idle(Observed<Idle>)
    case loading(Observed<Loading>)
    case loaded(Observed<Loaded>)
    case failed(Observed<Failed>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .idle(let value):
            return value.record
        case .loading(let value):
            return value.record
        case .loaded(let value):
            return value.record
        case .failed(let value):
            return value.record
        }
    }
    /// The accepted revision of this observation.
    public var revision: Swift::UInt64 {
        record.revision
    }
    /// Whether this historical root records closure.
    public var isClosed: Swift::Bool {
        record.isClosed
    }
    /// The ordinary model data. Constructing a model value directly confers no installation authority.
    public var model: Flow {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    public var description: Swift::String {
        switch self {
        case .idle(let value):
            return "idle, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .loading(let value):
            return "loading, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .loaded(let value):
            return "loaded, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .failed(let value):
            return "failed, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .idle(let payload):
        return .idle(Observed(payload: payload, record: record, claim: claim))
    case .loading(let payload):
        return .loading(Observed(payload: payload, record: record, claim: claim))
    case .loaded(let payload):
        return .loaded(Observed(payload: payload, record: record, claim: claim))
    case .failed(let payload):
        return .failed(Observed(payload: payload, record: record, claim: claim))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .idle:
        return "idle"
    case .loading:
        return "loading"
    case .loaded:
        return "loaded"
    case .failed:
        return "failed"
    }
}

fileprivate static func _stateMachineRefusingRoute(_ rejection: PreparationRejection, in phase: Swift::String) -> Swift::String? {
    switch (rejection, phase) {
    case (.begin, "idle"):
        return "idle.begin"
    case (.choose, "loaded"):
        return "loaded.choose"
    default:
        return nil
    }
}

/// A sealed inert candidate consumed by admission.
///
/// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
/// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
/// another owner's or the owner is closed, which it reports first.
public struct Prepared: ~Swift::Copyable, Swift::Sendable {
    fileprivate let candidate: _StateMachineEngine.Proposal
    fileprivate init(_ candidate: _StateMachineEngine.Proposal) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
public enum PreparationRejection: Swift::Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase
    case begin(Problem)
    case choose(Problem)
}

/// The edges each router may choose among.
public enum Route {
    /// The edges `choose` may choose.
public enum Choose: Swift::Sendable, Swift::Equatable, Swift::Hashable, Swift::CaseIterable {
        case restart
        case keep
    }
    /// The result of calling `choose` on an owned `Loaded`, with one case per edge it may select.
    public enum ChooseResult: ~Swift::Copyable, Swift::Sendable {
        case restart(Flow.Owned<Flow.Idle>)
    case keep(Flow.Owned<Flow.Loaded>)
    /// The router declined and returned the source unchanged.
    case rejected(Flow.Problem, Flow.Owned<Flow.Loaded>)
    }
    /// The choice and owned result types of the routers from `Loaded`.
    public enum Loaded {
        public typealias Choose = Flow.Route.Choose
    public typealias ChooseResult = Flow.Route.ChooseResult
    }
}

/// A historical receipt for an atomic acceptance.
public struct Receipt: Swift::Sendable, StateMachine::StateMachineReceipt, Swift::CustomStringConvertible {
    /// The accepted historical observation.
    public let snapshot: Snapshot
    fileprivate init(_ record: _StateMachineEngine.Snapshot) {
        snapshot = _stateMachineSnapshot(record)
        edgeID = record.edge
    }
    /// The identifier of the graph edge the acceptance took, as `graph` names it, or `nil` for a
    /// change that takes no edge, such as a reset, closure, or the authority-only commit of
    /// `discardPending(id:)`.
    public let edgeID: Swift::String?
    /// The owner-lifetime accepted revision.
    public var revision: Swift::UInt64 {
        snapshot.revision
    }
    /// The accepted phase, revision, and closure, without the payload.
    public var description: Swift::String {
        snapshot.description
    }
}

/// Why `send` did not admit an input.
public enum SendRejection: Swift::Error {
    /// Routing or the authored transition declined the input before a candidate existed.
    case preparation(PreparationRejection)
    /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`).
    /// Read `snapshot()` for the current root.
    case commit(CommitRejection)
}

/// Admission either publishes the entire candidate or leaves all state unchanged.
public enum CommitResult: Swift::Sendable {
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
public typealias FetchWork = _FetchWork<Fetch.Output>

/// The work of `Fetch`, generic over its output so that it seals an output of any type.
public struct _FetchWork<_StateMachineOutput>: Swift::Sendable {
    /// What admission started this work with.
public let request: FetchRequest

    /// The immutable declared input.
public var input: Fetch.Input {
        request.input
    }
    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    public var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    public func succeeded(_ value: _StateMachineOutput) -> FetchCompletion where _StateMachineOutput == Fetch.Output {
        FetchCompletion(result: .success(value), request: request, authority: authority)
    }

    /// Seals a failed terminal result for this exact work.
public func failed(_ value: Fetch.Failure) -> FetchCompletion {
        FetchCompletion(result: .failure(value), request: request, authority: authority)
    }
}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
public struct FetchCompletion: Swift::Sendable {
    /// The typed terminal value.
    public let result: Swift::Result<Fetch.Output, Fetch.Failure>
    /// What admission started the work with.
public let request: FetchRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Work issued exclusively from an accepted command batch.
public typealias AuditWork = _AuditWork<Audit.Output>

/// The work of `Audit`, generic over its output so that it seals an output of any type.
public struct _AuditWork<_StateMachineOutput>: Swift::Sendable {
    /// What admission started this work with.
public let request: AuditRequest

    /// The immutable declared input.
public var input: Audit.Input {
        request.input
    }
    fileprivate let authority: StateMachine::RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    public var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    public func succeeded(_ value: _StateMachineOutput) -> AuditCompletion where _StateMachineOutput == Audit.Output {
        AuditCompletion(value: value, request: request, authority: authority)
    }


}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
public struct AuditCompletion: Swift::Sendable {
    /// The value the operation produced. This operation cannot fail.
    public let value: Audit.Output
    /// What admission started the work with.
public let request: AuditRequest
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// Closed typed terminal outcomes for this domain.
public enum Completion: Swift::Sendable {
    case fetch(FetchCompletion)
    case audit(AuditCompletion)
    fileprivate var authority: StateMachine::RuntimeTicket {
        switch self {
        case .fetch(let value):
            return value.authority
        case .audit(let value):
            return value.authority
        }
    }
}

/// A sealed handle to actual execution bookkeeping.
public struct ExecutionHandle: Swift::Equatable, Swift::Sendable {
    fileprivate let authority: StateMachine::RuntimeTicket
}

/// How an execution ended, independently of cancellation or completion delivery.
public typealias ExecutionDisposition = StateMachine::ExecutionDisposition

/// Whether a physical execution acknowledgment was recorded.
public typealias AcknowledgmentResult = StateMachine::AcknowledgmentResult

/// A closed accepted start or cancellation command.
public enum Command: Swift::Sendable {
    case cancel(ExecutionHandle)
    case fetch(FetchWork)
    case audit(AuditWork)
}

/// One whole FIFO batch with its historical receipt.
public struct CommandBatch: Swift::Sendable, StateMachine::LocalCommandBatch {
    /// The atomic acceptance represented by this batch.
    public let receipt: Receipt
    /// Cancellation commands followed by starts in authored effect order.
    public let commands: [Command]
    /// Whether this is the separately reserved close batch.
    public let terminal: Swift::Bool
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
            case .fetch(let input):
                return .fetch(FetchWork(request: FetchRequest(input: input), authority: work.ticket))
            case .audit(let input):
                return .audit(AuditWork(request: AuditRequest(input: input), authority: work.ticket))
            }
        case .emit:
            Swift::preconditionFailure("A schema without events emits nothing.")
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    [[1], Swift::Array(0 ..< 4), [1]]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Flow, effects: [Effect], from: Swift::Int, to: Swift::Int,
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
            case .fetch(let input):
                let _: Fetch.Input = input
                counts[0] += 1
                guard counts[0] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 0, scope: _StateMachineScopeID(kind: 0),
                    dependencies: [_StateMachineScopeID(kind: 1)], policy: .latest), descriptor: effect))
            case .audit(let input):
                let _: Audit.Input = input
                counts[1] += 1
                guard counts[1] <= 2 else {
                    throw .invalidPlan
                }
                starts.append(.init(_StateMachineOperation(kind: 1, scope: _StateMachineScopeID(kind: 2),
                    dependencies: [_StateMachineScopeID(kind: 1)], policy: .parallel(2)), descriptor: effect))
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
public static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch input {
    case .load(let input):
        switch snapshot {
        case .idle(let source):
            do {
                return try source.begin(input)
            } catch {
                throw .begin(error)
            }
        default:
            throw .invalidPhase
        }
    case .cancel:
        switch snapshot {
        case .loading(let source):
            return source.cancel()
        default:
            throw .invalidPhase
        }
    case .sessionChanged:
        switch snapshot {
        case .loading(let source):
            return source.sessionChanged()
        default:
            throw .invalidPhase
        }
    case .note(let input):
        switch snapshot {
        case .loading(let source):
            return source.note(input)
        default:
            throw .invalidPhase
        }
    case .tick(let input):
        switch snapshot {
        case .loaded(let source):
            let selection: Route.Choose
            do {
                selection = try _StateMachineSchema.choose(source.value, input)
            } catch {
                throw .choose(error)
            }
            switch selection {
            case .restart:
                return source.restart(input)
            case .keep:
                return source.keep(input)
            }
        default:
            throw .invalidPhase
        }
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch completion {
    case .fetch(let completion):
        switch snapshot {
        case .loading(let source):
            switch completion.result {
            case .success(let value):
                return source.received(value, authority: completion.authority)
            case .failure(let value):
                return source.failed(value, authority: completion.authority)
            }
        default:
            throw .invalidPhase
        }
    case .audit(let completion):
        switch snapshot {
        case .loading(let source):
            let value: Audit.Output = completion.value
            return source.audited(value, authority: completion.authority)
        default:
            throw .invalidPhase
        }
    }
}

/// A phase that saved data can restore, covering phases with no active operations. A restored owner has no outstanding work.
public enum Restoration: Swift::Sendable {
    case idle(Idle)
    case loaded(Loaded)
    case failed(Failed)
}

/// Why `reset(restoring:)` did not replace an owner's model.
public enum ResetRejection: Swift::Error {
    /// The `@Restoration` function rejected the saved data.
    case restoration(Problem)
    /// The owner refused the reset because it is closed, its revisions are exhausted, or it had no queue slot for the reset's batch.
    case commit(CommitRejection)
}

fileprivate static func _stateMachineRestored(_ saved: Int) throws(Problem) -> (model: Flow, scopes: [StateMachine::RuntimeScopeID]) {
    switch try _StateMachineSchema.restore(saved) {
    case .idle(let payload):
        return (.idle(payload), [_StateMachineScopeID(kind: 1)])
    case .loaded(let payload):
        return (.loaded(payload), [_StateMachineScopeID(kind: 1)])
    case .failed(let payload):
        return (.failed(payload), [_StateMachineScopeID(kind: 1)])
    }
}

fileprivate typealias _StateMachineLedger = StateMachine::RuntimeDeliveryLedger<Flow, Effect, Completion, PreparationRejection>

/// A single-pass latest-value sequence of a managed owner's retained completions.
public typealias PendingCompletionUpdates = StateMachine::SnapshotSequence<[PendingCompletion]>

/// The opaque identity of one retained terminal outcome of this schema's owners.
public struct PendingCompletionID: Swift::Hashable, Swift::Sendable {
    fileprivate let raw: StateMachine::RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value. Only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
public struct PendingCompletion: Swift::Sendable {
    /// The retained terminal value of one operation, with the request its work was started with.
    public enum Outcome: Swift::Sendable {
        case fetch(Swift::Result<Flow.Fetch.Output, Flow.Fetch.Failure>, request: Flow.FetchRequest)
        case audit(Flow.Audit.Output, request: Flow.AuditRequest)
    }
    /// Why the last preparation or admission of a retained outcome did not commit.
    public enum Rejection: Swift::Sendable {
        /// The router or completion edge rejected the outcome.
        case preparation(PreparationRejection)
        /// The owner refused the prepared candidate, or its effect plan is defective.
        case admission(CommitRejection)
    }
    /// The opaque identity of this retained outcome.
    public let id: PendingCompletionID
    /// The first retained terminal outcome.
    public let outcome: Outcome
    /// The delivery state when this record was captured.
    public let status: PendingStatus
    /// The last failed preparation or admission, when present.
    public let lastRejection: Rejection?
    /// The saturating count of claimed preparations. Capacity retries do not increment it.
    public let attempts: Swift::UInt64
    /// Whether the preparation count has reached its representable limit.
    public var attemptsSaturated: Swift::Bool {
        attempts == Swift::UInt64.max
    }
    fileprivate init(_ pending: _StateMachineLedger.Pending) {
        id = PendingCompletionID(raw: pending.id)
        switch pending.outcome {
        case .fetch(let completion):
            outcome = .fetch(completion.result, request: completion.request)
        case .audit(let completion):
            outcome = .audit(completion.value, request: completion.request)
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
public enum DeliveryResult: Swift::Sendable {
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
public enum ReconcileResult: Swift::Sendable {
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
public enum DiscardResult: Swift::Sendable {
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
public struct ShutdownDiagnostics: Swift::Equatable, Swift::Sendable {
    /// An execution and delivery obligation that remained tracked.
public typealias OutstandingExecution = StateMachine::ShutdownDiagnostics.OutstandingExecution
    /// The owner's last accepted revision at the observation.
    public let acceptedRevision: Swift::UInt64
    /// The revision of the last fully processed FIFO batch.
    public let processedThrough: Swift::UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    public let hasQueuedBatches: Swift::Bool
    /// Whether a FIFO processing turn still owns responsibility.
    public let isDraining: Swift::Bool
    /// Whether an automatic retry of a retained completion is still scheduled.
public let isRetrying: Swift::Bool
    /// The identities of the retained terminal outcomes.
    public let pendingCompletions: [PendingCompletionID]
    /// The executions, deliveries, and preparations that remain tracked.
    public let outstandingExecutions: [OutstandingExecution]
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
public enum ShutdownResult: Swift::Equatable, Swift::Sendable {
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
public typealias FlushResult = StateMachine::FlushResult

/// A noncopyable manually driven owner with an embedded value engine.
public struct Local: ~Swift::Copyable, StateMachine::DeliveringLocalStateMachine, StateMachine::DefaultingLocalStateMachine, StateMachine::RestoringLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
public typealias Input = Flow.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias Snapshot = Flow.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias Receipt = Flow.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias SendRejection = Flow.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias Prepared = Flow.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias CommitResult = Flow.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias InitialPhase = Idle
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias Command = Flow.Command
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias CommandBatch = Flow.CommandBatch
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias Completion = Flow.Completion
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias ExecutionHandle = Flow.ExecutionHandle
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias PendingCompletionID = Flow.PendingCompletionID
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias PendingCompletion = Flow.PendingCompletion
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias DeliveryResult = Flow.DeliveryResult
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias ReconcileResult = Flow.ReconcileResult
    /// A type of this owner's `LocalStateMachine` conformance.
    public typealias DiscardResult = Flow.DiscardResult
    /// The declared structure of this owner's graph.
    public static var graph: StateMachine::StateMachineGraph {
        _StateMachineSchema.graph
    }
    /// The identifier of the phase a snapshot holds, as the graph names it.
    public static func phase(of snapshot: Snapshot) -> Swift::String {
        _stateMachinePhase(of: snapshot.record)
    }
    /// The receipt of an admitted proposal, or `nil` when admission rejected it.
    public static func receipt(of result: CommitResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The identifier of the router or edge, as the graph names it, whose authored function refused an
    /// input that `send` rejected from a snapshot in `phase`, or `nil` when no authored function refused it.
    public static func rejectingRoute(of rejection: SendRejection, in phase: Swift::String) -> Swift::String? {
        guard case .preparation(let preparation) = rejection else {
        return nil
    }
        return _stateMachineRefusingRoute(preparation, in: phase)
    }
    /// A fresh initial payload, constructed as the schema's declared default constructs it.
    public static func defaultInitialPhase() -> InitialPhase {
        _StateMachineSchema.makeIdle()
    }
    /// The receipt of a delivery that committed, or `nil` when the outcome was retained or not taken.
    public static func receipt(of result: DeliveryResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The receipt of a retained outcome's admission, or `nil` when it did not commit.
    public static func receipt(of result: ReconcileResult) -> Receipt? {
        if case .committed(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The receipt of a discard's authority-only commit, or `nil` when nothing was discarded.
    public static func receipt(of result: DiscardResult) -> Receipt? {
        if case .discarded(let receipt) = result {
        receipt
    } else {
        nil
    }
    }
    /// The identifier of the router or completion edge, as the graph names it, whose authored function
    /// refused the outcome in the call that returned `result`, or `nil` when that call's preparation
    /// did not refuse it.
    public static func rejectingRoute(of result: DeliveryResult) -> Swift::String? {
        if case .refused(_, _, let routeID) = result {
        routeID
    } else {
        nil
    }
    }
    /// The identifier of the router or completion edge, as the graph names it, whose authored function
    /// refused the outcome in the call that returned `result`, or `nil` when that call's preparation
    /// did not refuse it.
    public static func rejectingRoute(of result: ReconcileResult) -> Swift::String? {
        if case .refused(_, _, let routeID) = result {
        routeID
    } else {
        nil
    }
    }
    fileprivate var engine: _StateMachineEngine
    fileprivate var ledger = _StateMachineLedger()
    /// Creates fresh authority only in the declared initial phase.
    public init(_ initial: Idle = _StateMachineSchema.makeIdle(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], limits: configuration, recording: .commands)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, configuration: LocalConfiguration = .default) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        engine = _StateMachineEngine(restored.model, scopes: restored.scopes, limits: configuration, recording: .commands)
    }
    /// Returns an immutable historical observation.
    public borrowing func snapshot() -> Snapshot {
        _stateMachineSnapshot(engine.snapshot)
    }
    /// Whether `snapshot` was taken from this owner, in any incarnation.
    ///
    /// A reset keeps the owner, and another owner never matches, even one that holds an equal
    /// model at the same revision. The answer grants no authority.
    public borrowing func owns(_ snapshot: Snapshot) -> Swift::Bool {
        engine.owns(snapshot.record)
    }
    /// Consumes and atomically accepts or rejects a complete candidate.
    public mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
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
    public mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
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
public mutating func drainCommands(limit: Swift::Int = .max) -> [CommandBatch] {
    engine.drain(limit: limit).map {
        _stateMachineBatch($0)
    }
    }
    /// How many whole batches a drain would transfer, including the terminal batch, without
    /// transferring any.
    public var queuedBatchCount: Swift::Int {
        engine.queuedBatchCount
    }
    /// Records actual termination independently of cancellation and completion delivery.
    ///
    /// Pass `.skippedBeforeStart` for work the caller never began.
    public mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition = .terminated) -> AcknowledgmentResult {
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
    public mutating func deliver(_ completion: Completion) -> DeliveryResult {
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
    /// Delivers the sealed terminal result of one `Fetch` execution.
    public mutating func deliver(_ completion: FetchCompletion) -> DeliveryResult {
        deliver(.fetch(completion))
    }
    /// Delivers the sealed terminal result of one `Audit` execution.
    public mutating func deliver(_ completion: AuditCompletion) -> DeliveryResult {
        deliver(.audit(completion))
    }
    /// Claims one retained outcome before evaluating domain code.
    public mutating func reconcile(id: PendingCompletionID) -> ReconcileResult {
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
    public mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult {
        _stateMachineFinish(ledger.retryAdmission(id.raw, in: &engine))
    }
    /// Queries immutable first-outcome records without claiming preparation.
    public borrowing func pendingCompletions() -> [PendingCompletion] {
        ledger.pending.map(PendingCompletion.init)
    }
    /// Revokes one retained operation using an atomic authority-only commit.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    public mutating func discardPending(id: PendingCompletionID) -> DiscardResult {
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
    public mutating func close() -> Receipt {
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
    public mutating func reset(to initial: Idle = _StateMachineSchema.makeIdle()) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)])
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
    public mutating func reset(to initial: Idle = _StateMachineSchema.makeIdle(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
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
    public mutating func reset(restoring saved: Int) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = engine.reset(restored.model, scopes: restored.scopes)
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    public mutating func reset(restoring saved: Int, expecting expected: Snapshot) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = engine.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
    ledger.prune(in: engine)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
public var isQuiescent: Swift::Bool {
        engine.isQuiescent
    }
}

/// Immutable operation selections whose non-`Sendable` values stay on `MainActor`.
@Swift::MainActor public struct MainActorDrivers {
    /// Executes this operation within the selected isolation.
public let fetch: @Swift::MainActor (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>
    /// Executes this operation within the selected isolation.
    public let audit: @Swift::MainActor (Audit.Input) async -> Audit.Output
    /// Selects every driver for this owner's lifetime.
    public init(fetch: @escaping @Swift::MainActor (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>, audit: @escaping @Swift::MainActor (Audit.Input) async -> Audit.Output) {
        self.fetch = fetch
        self.audit = audit
    }
}

/// A sealed sole-writer `MainActor` owner with managed execution.
///
/// On iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, and Mac Catalyst 17.0 and
/// later, this owner conforms to `Observable` so a SwiftUI view can read it directly. Each
/// tracked member registers a read of its own value only, covering `currentSnapshot` and `snapshot()`, `runningCount`,
/// `subscriberCount`, and `pendingCompletions()`.
@Swift::MainActor public final class MainActorHost: StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeMainActorHost<Flow, Effect, Completion, PreparationRejection>
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
    public struct CompletionPolicy {
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
        public static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retry(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        public static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping @Swift::MainActor (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh authority and immutable execution selections.
    public init(_ initial: Idle = _StateMachineSchema.makeIdle(), drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public init(restoring saved: Int, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Swift::MainActor () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public convenience init(_ initial: Idle = _StateMachineSchema.makeIdle(),
        fetchDriver: @escaping @Swift::MainActor (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Swift::MainActor (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: MainActorDrivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Swift::MainActor (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Swift::MainActor (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) throws(Problem) {
        try self.init(restoring: saved, drivers: MainActorDrivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation. Reading it registers a snapshot read with Observation.
    public func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// The current complete snapshot. Reading it registers a snapshot read with Observation.
public var currentSnapshot: Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares, and admits one input in a single isolated turn without suspension.
    @discardableResult
    public func send(_ input: Input) throws(SendRejection) -> Receipt {
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
    public func commit(_ prepared: consuming Prepared) -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(host.commit(candidate))
        case .defective(let defect):
            return _stateMachineAdmission(host.reject(defect))
        }
    }
    /// Subscribes to initial, accepted, and terminal complete snapshots, taking a subscriber slot when called.
    public func subscribe(_ receive: @escaping @Swift::MainActor (Snapshot) -> Swift::Void,
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
    public func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.sendableSnapshots {
            _stateMachineSnapshot($0)
        }
    }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered, and the sequence offers each
    /// projection, equal to the one before it or not. It supports every `AsyncSequence` operator on
    /// every supported OS version. `distinctSnapshots(_:)` omits repeated values instead.
    public func snapshots<Projection: Swift::Sendable>(
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
    public func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
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
    @Swift::MainActor public func snapshotPublisher() throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
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
    @Swift::MainActor public func snapshotPublisher<Projection: Swift::Sendable>(
        _ transform: @escaping @Swift::MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Projection> {
        try host.snapshotPublisher {
        transform(_stateMachineSnapshot($0))
    }
    }
    #endif
    /// Reads immutable retained first-outcome diagnostics.
public func pendingCompletions() -> [PendingCompletion] {
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
    public func pendingCompletionUpdates() throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.sendablePendingCompletionUpdates {
        $0.map(PendingCompletion.init)
    }
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs on the main actor with the whole collection after each change, starting with
    /// the collection current at registration. The sequence supports every `AsyncSequence` operator
    /// on every supported OS version, and ends after the projection of the final, empty collection.
    public func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping @Swift::MainActor ([PendingCompletion]) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.sendablePendingCompletionUpdates {
        transform($0.map(PendingCompletion.init))
    }
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcileReportingRefusal(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    public func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Flow, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Flow, Effect>) -> DiscardResult {
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
    public func close() -> Receipt {
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)])
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
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
    public func reset(restoring saved: Int) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = host.reset(restored.model, scopes: restored.scopes)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    public func reset(restoring saved: Int, expecting expected: Snapshot) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = host.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    public var runningCount: Swift::Int {
        host.runningCount
    }
    /// The count of live observer registrations. Reading it registers a count read with Observation.
    public var subscriberCount: Swift::Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Swift::Bool {
        host.isQuiescent
    }
}

/// Immutable typed execution selection for one managed owner's lifetime.
public struct Drivers: Swift::Sendable {
    /// Executes one typed operation outside admission locks.
public let fetch: @Sendable (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>
    /// Executes one typed operation outside admission locks.
    public let audit: @Sendable (Audit.Input) async -> Audit.Output
    /// Selects all drivers for this owner.
    public init(fetch: @escaping @Sendable (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>, audit: @escaping @Sendable (Audit.Input) async -> Audit.Output) {
        self.fetch = fetch
        self.audit = audit
    }
}

/// A synchronous shared owner with managed physical execution and terminal delivery.
public final class Shared: Swift::Sendable, StateMachine::SharedStateMachineHost {
    private typealias Host = StateMachine::RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>
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
    public struct CompletionPolicy: Swift::Sendable {
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
        public static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retry(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        public static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh initial authority and retains the driver selection immutably.
    public init(_ initial: Idle = _StateMachineSchema.makeIdle(), drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Sendable () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public init(restoring saved: Int, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Sendable () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public convenience init(_ initial: Idle = _StateMachineSchema.makeIdle(),
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) throws(Problem) {
        try self.init(restoring: saved, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a coherent historical observation.
    public func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Registers a serial capacity-one latest-value observation callback, taking a subscriber slot when called.
    public func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Swift::Void,
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
    public func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
    /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs on the registration's serial delivery path, outside every lock, and the
    /// sequence offers each projection, equal to the one before it or not. `distinctSnapshots(_:)`
    /// omits repeated values instead.
    public func snapshots<Projection: Swift::Sendable>(
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
    public func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
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
    @Swift::MainActor public func snapshotPublisher() throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
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
    @Swift::MainActor public func snapshotPublisher<Projection: Swift::Sendable>(
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
    public func send(_ input: Input) throws(SendRejection) -> Receipt {
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
    public func commit(_ prepared: consuming Prepared) -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(host.commit(candidate))
        case .defective(let defect):
            return _stateMachineAdmission(host.reject(defect))
        }
    }
    /// Reads immutable retained first-outcome diagnostics.
public func pendingCompletions() -> [PendingCompletion] {
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
    public func pendingCompletionUpdates() throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.pendingCompletionUpdates {
        $0.map(PendingCompletion.init)
    }
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs on the registration's serial delivery path, outside every lock, with the whole collection after each change, starting with
    /// the collection current at registration. The sequence supports every `AsyncSequence` operator
    /// on every supported OS version, and ends after the projection of the final, empty collection.
    public func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable ([PendingCompletion]) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.pendingCompletionUpdates {
        transform($0.map(PendingCompletion.init))
    }
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcileReportingRefusal(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    public func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>.Delivery, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>.Delivery) -> DiscardResult {
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
    public func close() -> Receipt {
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)])
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
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
    public func reset(restoring saved: Int) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = host.reset(restored.model, scopes: restored.scopes)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    public func reset(restoring saved: Int, expecting expected: Snapshot) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = host.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    public var runningCount: Swift::Int {
        host.runningCount
    }
    /// Live observer registrations.
    public var subscriberCount: Swift::Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Swift::Bool {
        host.isQuiescent
    }
}

/// A sealed sole-writer native actor owner with managed execution.
public final class ActorHost: Swift::Sendable, StateMachine::ActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeActorHost<Flow, Effect, Completion, PreparationRejection>
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
    public struct CompletionPolicy: Swift::Sendable {
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
        public static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retry(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        public static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
        /// Creates fresh authority and immutable execution selections.
    ///
    /// With `isolatedTo`, the owner's actor runs on that actor's serial executor so their turns
    /// never overlap, though calls into the owner still await.
        public init(_ initial: Idle = _StateMachineSchema.makeIdle(), drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry, isolatedTo: (any Swift::Actor)? = nil) {
            host = Host(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], configuration: configuration,
                policy: completionPolicy.runtime, driver: { raw in
        let execution: @Sendable () async -> Completion
        switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public init(restoring saved: Int, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry, isolatedTo: (any Swift::Actor)? = nil) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    let execution: @Sendable () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public convenience init(_ initial: Idle = _StateMachineSchema.makeIdle(),
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry,
        isolatedTo: (any Swift::Actor)? = nil) {
        self.init(initial, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy, isolatedTo: isolatedTo)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry,
        isolatedTo: (any Swift::Actor)? = nil) throws(Problem) {
        try self.init(restoring: saved, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy, isolatedTo: isolatedTo)
    }
    /// Captures a complete historical observation.
    public func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }

    /// Routes, prepares, and admits one input in a single isolated turn without suspension.
    @discardableResult
    public func send(_ input: Input) async throws(SendRejection) -> Receipt {
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
    public func commit(_ prepared: consuming Prepared) async -> CommitResult {
        switch prepared.candidate {
        case .candidate(let candidate):
            return _stateMachineAdmission(await host.commit(candidate))
        case .defective(let defect):
            return _stateMachineAdmission(await host.reject(defect))
        }
    }
    /// Subscribes to initial, accepted, and terminal complete snapshots, taking a subscriber slot when called.
    public func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Swift::Void,
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
    public func snapshots() async throws(SubscriptionFailure) -> Snapshots {
        try await host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
    ///
    /// `transform` runs in this owner's actor turn when a snapshot is delivered, and the sequence offers each
    /// projection, equal to the one before it or not. It supports every `AsyncSequence` operator on
    /// every supported OS version. `distinctSnapshots(_:)` omits repeated values instead.
    public func snapshots<Projection: Swift::Sendable>(
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
    public func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
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
    @Swift::MainActor public func snapshotPublisher() async throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
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
    @Swift::MainActor public func snapshotPublisher<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) async throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Projection> {
        try await host.snapshotPublisher {
        transform(_stateMachineSnapshot($0))
    }
    }
    #endif
    /// Reads immutable retained first-outcome diagnostics.
public func pendingCompletions() async -> [PendingCompletion] {
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
    public func pendingCompletionUpdates() async throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try await host.pendingCompletionUpdates {
        $0.map(PendingCompletion.init)
    }
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs in this owner's actor turn with the whole collection after each change, starting with
    /// the collection current at registration. The sequence supports every `AsyncSequence` operator
    /// on every supported OS version, and ends after the projection of the final, empty collection.
    public func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping @Sendable ([PendingCompletion]) -> Projection
    ) async throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try await host.pendingCompletionUpdates {
        transform($0.map(PendingCompletion.init))
    }
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) async -> ReconcileResult {
        Self.reconciled(await host.reconcileReportingRefusal(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    public func discardPending(id: PendingCompletionID) async -> DiscardResult {
        Self.discarded(await host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Flow, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Flow, Effect>) -> DiscardResult {
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
    public func close() async -> Receipt {
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle()) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)])
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle(), expecting expected: Snapshot) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record)
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
    public func reset(restoring saved: Int) async throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = await host.reset(restored.model, scopes: restored.scopes)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    public func reset(restoring saved: Int, expecting expected: Snapshot) async throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = await host.reset(restored.model, scopes: restored.scopes, expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    public var runningCount: Swift::Int {
        get async {
            await host.runningCount
        }
    }
    /// The count of live observer registrations.
    public var subscriberCount: Swift::Int {
        get async {
            await host.subscriberCount
        }
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Swift::Bool {
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
public final class IsolatedHost<Owner: Swift::Actor>: StateMachine::IsolatedStateMachineHost {
    private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, Flow, Effect, Completion, PreparationRejection>
    private let host: Host
        /// Immutable operation selections, each run on the owning actor, which it receives isolated.
    ///
    /// A driver reaches the actor's state through that parameter, so it captures nothing confined.
    public struct Drivers: Swift::Sendable {
        /// Executes this operation on the owning actor, which it receives isolated.
    public let fetch: @Sendable (isolated Owner, Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>
    /// Executes this operation on the owning actor, which it receives isolated.
    public let audit: @Sendable (isolated Owner, Audit.Input) async -> Audit.Output
        /// Selects every driver for this owner's lifetime.
        public init(fetch: @escaping @Sendable (isolated Owner, Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>, audit: @escaping @Sendable (isolated Owner, Audit.Input) async -> Audit.Output) {
        self.fetch = fetch
        self.audit = audit
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
    public struct CompletionPolicy {
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
        public static var retry: CompletionPolicy {
        CompletionPolicy(.retry, handler: { _ in
            })
    }
        /// Retries lost races as `retry` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retry(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.retry, handler: handler)
        }
        /// Never prepares a completion again on its own and notifies no one. Every completion that
        /// needs reconciliation, including one whose preparation lost a race with another commit,
        /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
        public static var manual: CompletionPolicy {
        CompletionPolicy(.manual, handler: { _ in
            })
    }
        /// Never prepares a completion again on its own. Every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, is passed to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping (PendingCompletion) -> Swift::Void) -> CompletionPolicy {
            CompletionPolicy(.manual, handler: handler)
        }
    }
    /// Creates fresh authority confined to `isolation`, with immutable execution selections.
    public init(_ initial: Idle = _StateMachineSchema.makeIdle(), isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) {
        host = Host(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(owner, input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(owner, input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public init(restoring saved: Int, isolation: isolated Owner, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retry) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, isolation: isolation, configuration: configuration,
            policy: completionPolicy.runtime, driver: { owner, raw in
    let execution: () async -> Completion
    switch raw.descriptor {
                case .fetch(let input):
                    execution = {
                    .fetch(FetchCompletion(result: await drivers.fetch(owner, input), request: FetchRequest(input: input), authority: raw.ticket))
                }
                case .audit(let input):
                    execution = {
                    .audit(AuditCompletion(value: await drivers.audit(owner, input), request: AuditRequest(input: input), authority: raw.ticket))
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
    public convenience init(_ initial: Idle = _StateMachineSchema.makeIdle(),
        isolation: isolated Owner,
        fetchDriver: @escaping @Sendable (isolated Owner, Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (isolated Owner, Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) {
        self.init(initial, isolation: isolation, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        isolation: isolated Owner,
        fetchDriver: @escaping @Sendable (isolated Owner, Fetch.Input) async -> Swift::Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (isolated Owner, Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retry) throws(Problem) {
        try self.init(restoring: saved, isolation: isolation, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    public func snapshot(isolation: isolated Owner = #isolation) -> Snapshot {
        _stateMachineSnapshot(host.snapshot(isolation: isolation))
    }
    /// Routes, prepares, and admits one input in a single turn of the owning actor, without suspension.
    @discardableResult
    public func send(_ input: Input, isolation: isolated Owner = #isolation) throws(SendRejection) -> Receipt {
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
    public func commit(_ prepared: consuming Prepared, isolation: isolated Owner = #isolation) -> CommitResult {
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
    public func subscribe(_ receive: @escaping (Snapshot) -> Swift::Void,
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
    public func snapshots(isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> Snapshots {
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
    public func snapshots<Projection: Swift::Sendable>(
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
    public func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
        _ transform: @escaping (Snapshot) -> Projection, isolation: isolated Owner = #isolation
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.distinctSendableSnapshots({
                transform(_stateMachineSnapshot($0))
            }, isolation: isolation)
    }
    /// Reads immutable retained first-outcome diagnostics.
public func pendingCompletions(isolation: isolated Owner = #isolation) -> [PendingCompletion] {
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
    public func pendingCompletionUpdates(isolation: isolated Owner = #isolation) throws(SubscriptionFailure) -> PendingCompletionUpdates {
        try host.sendablePendingCompletionUpdates({
            $0.map(PendingCompletion.init)
        }, isolation: isolation)
    }
    /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
    ///
    /// `transform` runs on the owning actor with the whole collection after each change, starting
    /// with the collection current at registration. The sequence supports every `AsyncSequence`
    /// operator, may be consumed anywhere, and ends after the projection of the final, empty collection.
    public func pendingCompletionUpdates<Projection: Swift::Sendable>(
        _ transform: @escaping ([PendingCompletion]) -> Projection, isolation: isolated Owner = #isolation
    ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
        try host.sendablePendingCompletionUpdates({
            transform($0.map(PendingCompletion.init))
        }, isolation: isolation)
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID, isolation: isolated Owner = #isolation) -> ReconcileResult {
        Self.reconciled(host.reconcileReportingRefusal(id: id.raw, isolation: isolation))
    }
    /// Revokes retained delivery with an authority-only admission.
    ///
    /// The operation's work already returned the outcome it settles, so the commit issues no
    /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
    public func discardPending(id: PendingCompletionID, isolation: isolated Owner = #isolation) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw, isolation: isolation))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<Flow, Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
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
    private static func discarded(_ result: StateMachine::RuntimeHostDelivery<Flow, Effect>) -> DiscardResult {
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
    public func close(isolation: isolated Owner = #isolation) -> Receipt {
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle(), isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], isolation: isolation)
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
    public func reset(to initial: Idle = _StateMachineSchema.makeIdle(), expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [_StateMachineScopeID(kind: 1)], expecting: expected.record, isolation: isolation)
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
    public func reset(restoring saved: Int, isolation: isolated Owner = #isolation) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = host.reset(restored.model, scopes: restored.scopes, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Replaces the model with the phase `restore` validates from saved data exactly as
    /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
    /// observed, refusing otherwise as `reset(to:expecting:)` does.
    @discardableResult
    public func reset(restoring saved: Int, expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(ResetRejection) -> Receipt {
        let restored: (model: Flow, scopes: [StateMachine::RuntimeScopeID])
    do throws(Problem) {
        restored = try _stateMachineRestored(saved)
    } catch {
        throw .restoration(error)
    }
        let result = host.reset(restored.model, scopes: restored.scopes, expecting: expected.record, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw .commit(reason)
        }
    }
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt, isolation: isolated Owner = #isolation) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record, isolation: isolation) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: Swift::ContinuousClock.Instant? = nil, isolation: isolated Owner = #isolation) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline, isolation: isolation))
    }
    /// Actual workers whose joined termination has not yet been processed, read on the owning actor.
    public func runningCount(isolation: isolated Owner = #isolation) -> Swift::Int {
        host.runningCount(isolation: isolation)
    }
    /// Live observer registrations, read on the owning actor.
    public func subscriberCount(isolation: isolated Owner = #isolation) -> Swift::Int {
        host.subscriberCount(isolation: isolation)
    }
    /// Whether closure and all managed obligations have settled, read on the owning actor.
    public func isQuiescent(isolation: isolated Owner = #isolation) -> Swift::Bool {
        host.isQuiescent(isolation: isolation)
    }
}

fileprivate typealias _StateMachineGraph = StateMachine::StateMachineGraph

/// The declared phases, inputs, scopes, operations, events, edges, and routers of this graph,
/// without payloads or authority.
public nonisolated static let graph: StateMachine::StateMachineGraph = _stateMachineGraph()

nonisolated private static func _stateMachineGraph() -> StateMachine::StateMachineGraph {
    var phases: [_StateMachineGraph.Phase] = []
    phases.append(_StateMachineGraph.Phase(id: "idle", payload: "Idle"))
    phases.append(_StateMachineGraph.Phase(id: "loading", payload: "Loading"))
    phases.append(_StateMachineGraph.Phase(id: "loaded", payload: "Loaded"))
    phases.append(_StateMachineGraph.Phase(id: "failed", payload: "Failed"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "load", payload: "Int"))
    inputs.append(_StateMachineGraph.Input(id: "cancel", payload: nil))
    inputs.append(_StateMachineGraph.Input(id: "sessionChanged", payload: nil))
    inputs.append(_StateMachineGraph.Input(id: "note", payload: "String"))
    inputs.append(_StateMachineGraph.Input(id: "tick", payload: "Bool"))
    var scopes: [_StateMachineGraph.Scope] = []
    scopes.append(_StateMachineGraph.Scope(id: "load", activeIn: ["loading"]))
    scopes.append(_StateMachineGraph.Scope(id: "session", activeIn: ["idle", "loading", "loaded", "failed"]))
    var operations: [_StateMachineGraph.Operation] = []
    operations.append(_StateMachineGraph.Operation(id: "Fetch", effect: "fetch", scope: "load",
        requires: ["session"], activeIn: ["loading"], admission: .latest,
        key: nil, input: "Int", output: "String",
        failure: "Problem", canFail: true, canSucceed: true))
    operations.append(_StateMachineGraph.Operation(id: "Audit", effect: "audit", scope: nil,
        requires: ["session"], activeIn: ["loading"], admission: .parallel(limit: 2),
        key: nil, input: "String", output: "Int",
        failure: "Swift::Never", canFail: false, canSucceed: true))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "idle.begin", name: "begin",
        source: "idle", destination: "loading", trigger: .input("load"),
        router: nil, starts: ["Fetch"],
        cancels: [],
        emits: [], invalidates: ["load"]))
    edges.append(_StateMachineGraph.Edge(id: "loading.cancel", name: "cancel",
        source: "loading", destination: "idle", trigger: .input("cancel"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: ["load"]))
    edges.append(_StateMachineGraph.Edge(id: "loading.sessionChanged", name: "sessionChanged",
        source: "loading", destination: "loading", trigger: .input("sessionChanged"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: ["session"]))
    edges.append(_StateMachineGraph.Edge(id: "loading.note", name: "note",
        source: "loading", destination: "loading", trigger: .input("note"),
        router: nil, starts: ["Audit"],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "loading.received", name: "received",
        source: "loading", destination: "loaded", trigger: .success("Fetch"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "loading.failed", name: "failed",
        source: "loading", destination: "failed", trigger: .failure("Fetch"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "loading.audited", name: "audited",
        source: "loading", destination: "loading", trigger: .success("Audit"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "loaded.restart", name: "restart",
        source: "loaded", destination: "idle", trigger: .input("tick"),
        router: "loaded.choose", starts: [],
        cancels: [],
        emits: [], invalidates: []))
    edges.append(_StateMachineGraph.Edge(id: "loaded.keep", name: "keep",
        source: "loaded", destination: "loaded", trigger: .input("tick"),
        router: "loaded.choose", starts: [],
        cancels: [],
        emits: [], invalidates: []))
    var routers: [_StateMachineGraph.Router] = []
    routers.append(_StateMachineGraph.Router(id: "loaded.choose", name: "choose",
        source: "loaded", trigger: .input("tick"),
        candidates: ["loaded.restart", "loaded.keep"]))
    return .init(
        name: "Flow",
        mode: .shared,
        owners: [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost],
        initial: "idle",
        terminal: ["failed"],
        restorable: ["idle", "loaded", "failed"],
        phases: phases,
        inputs: inputs,
        scopes: scopes,
        operations: operations,
        events: [],
        edges: edges,
        routers: routers
    )
}
