fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Copyable> {
}

fileprivate struct _RouterSourceIsPhasePayload<Value: ~Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Sendable> {
}

fileprivate struct _OperationFailureIsError<Value: Error> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

fileprivate static func _stateMachineWitnesses() {
    let _: _TransitionSourceIsPhasePayload<Idle> = _TransitionSourceIsPhasePayload<Idle>()
    let _: _TransitionReturnsDeclaredResult<Change<Loading, Effect.Begin>> = _TransitionReturnsDeclaredResult<Change<Loading, Effect.Begin>>()
    let _: _TriggerPayloadMatchesDeclaration<Int> = _TriggerPayloadMatchesDeclaration<Int>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Idle> = _TransitionReturnsDeclaredResult<Idle>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Loading> = _TransitionReturnsDeclaredResult<Loading>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Change<Loading, Effect.Note>> = _TransitionReturnsDeclaredResult<Change<Loading, Effect.Note>>()
    let _: _TriggerPayloadMatchesDeclaration<String> = _TriggerPayloadMatchesDeclaration<String>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Loaded> = _TransitionReturnsDeclaredResult<Loaded>()
    let _: _TriggerPayloadMatchesDeclaration<Fetch.Output> = _TriggerPayloadMatchesDeclaration<Fetch.Output>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Failed> = _TransitionReturnsDeclaredResult<Failed>()
    let _: _TriggerPayloadMatchesDeclaration<Fetch.Failure> = _TriggerPayloadMatchesDeclaration<Fetch.Failure>()
    let _: _TransitionSourceIsPhasePayload<Loading> = _TransitionSourceIsPhasePayload<Loading>()
    let _: _TransitionReturnsDeclaredResult<Loading> = _TransitionReturnsDeclaredResult<Loading>()
    let _: _TriggerPayloadMatchesDeclaration<Audit.Output> = _TriggerPayloadMatchesDeclaration<Audit.Output>()
    let _: _TransitionSourceIsPhasePayload<Loaded> = _TransitionSourceIsPhasePayload<Loaded>()
    let _: _TransitionReturnsDeclaredResult<Idle> = _TransitionReturnsDeclaredResult<Idle>()
    let _: _TriggerPayloadMatchesDeclaration<Bool> = _TriggerPayloadMatchesDeclaration<Bool>()
    let _: _TransitionSourceIsPhasePayload<Loaded> = _TransitionSourceIsPhasePayload<Loaded>()
    let _: _TransitionReturnsDeclaredResult<Loaded> = _TransitionReturnsDeclaredResult<Loaded>()
    let _: _TriggerPayloadMatchesDeclaration<Bool> = _TriggerPayloadMatchesDeclaration<Bool>()
    let _ = _OperationFailureIsError<Fetch.Failure>()
    let _ = _OperationFailureIsError<Audit.Failure>()
    let _: _RouterSourceIsPhasePayload<Loaded> = _RouterSourceIsPhasePayload<Loaded>()
    let _: _TriggerPayloadMatchesDeclaration<Bool> = _TriggerPayloadMatchesDeclaration<Bool>()
    let _ = _EffectIsCopyable<Effect>()
    let _ = _SharedModeRequiresSendable<Input>();
    let _ = _SharedModeRequiresSendable<Effect>()
}

/// Inert descriptions of the operations this workflow can start.
public enum Effect: Sendable {
    case fetch(Flow.Fetch.Input)
    case audit(Flow.Audit.Input)
    /// The operations `begin` may start.
public enum Begin: Sendable {
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
    public enum Note: Sendable {
        case audit(Flow.Audit.Input)
        /// The schema-wide effect this value describes.
        public var effect: Flow.Effect {
        switch self {
        case .audit(let input):
            return .audit(input)
        }
    }
    }
}

/// Unique authority over one declared workflow phase.
public struct Owned<Phase: ~Copyable & Sendable>: ~Copyable, Sendable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource.
    public borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result {
        body(phase)
    }
    /// Advances through the authored edge or returns the original predecessor.
public consuming func begin(_ input: Int) -> Advance<Self, Owned<Loading>, Effect.Begin, Problem> where Phase == Idle {
    do {
        let change = try Flow.begin(phase, input)
        return .advanced(Owned<Loading>(change.next), effects: change.effects)
    } catch {
        return .rejected(error, self)
    }
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func cancel() -> Owned<Idle> where Phase == Loading {
        Owned<Idle>(Flow.cancel(phase))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func sessionChanged() -> Owned<Loading> where Phase == Loading {
        Owned<Loading>(Flow.sessionChanged(phase))
    }
    /// Advances through the authored edge, preserving effect order.
    public consuming func note(_ input: String) -> Change<Owned<Loading>, Effect.Note> where Phase == Loading {
        let change = Flow.note(phase, input)
        return Change(Owned<Loading>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func received(_ input: Fetch.Output) -> Owned<Loaded> where Phase == Loading {
        Owned<Loaded>(Flow.received(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func failed(_ input: Fetch.Failure) -> Owned<Failed> where Phase == Loading {
        Owned<Failed>(Flow.failed(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func audited(_ input: Audit.Output) -> Owned<Loading> where Phase == Loading {
        Owned<Loading>(Flow.audited(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func restart(_ input: Bool) -> Owned<Idle> where Phase == Loaded {
        Owned<Idle>(Flow.restart(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    public consuming func keep(_ input: Bool) -> Owned<Loaded> where Phase == Loaded {
        Owned<Loaded>(Flow.keep(phase, input))
    }
}

/// Creates ownership only in the declared initial phase.
public static func owned(_ initial: consuming Idle = Flow.makeIdle()) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = RuntimeState<Flow, Effect>

/// Validated bounds for managed admission and serial subscriptions.
public typealias Configuration = RuntimeManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
public typealias LocalConfiguration = RuntimeLimits

/// A live observation registration; cancelling or releasing it stops delivery.
public typealias Subscription = RuntimeSubscription

/// A live MainActor observation registration; cancelling or releasing it stops delivery.
public typealias MainActorSubscription = RuntimeMainActorSubscription

/// Failure to register another live observer.
public typealias SubscriptionFailure = RuntimeHostSubscriptionFailure

/// A single-pass latest-value sequence of an owner's snapshots.
public typealias Snapshots = RuntimeSnapshots<Snapshot>

/// Whether a managed owner retries a conflicting completion or waits for reconciliation.
public typealias CompletionPolicy = RuntimeCompletionPolicy

/// The disposition of a retained completion.
public typealias PendingStatus = RuntimePendingStatus

/// Admission rejection reasons in exact evaluation precedence.
public typealias CommitRejection = RuntimeState<Flow, Effect>.Rejection

/// An immutable historical payload with sealed complete-root provenance.
public struct Observed<Phase: Sendable>: Sendable, CustomStringConvertible {
    fileprivate let payload: Phase
    fileprivate let record: _StateMachineEngine.Snapshot
    fileprivate let claim: RuntimeDeliveryClaim?
    /// The copied historical payload.
    public var value: Phase {
        payload
    }
    /// The owner-lifetime accepted revision.
    public var revision: UInt64 {
        record.revision
    }
    /// The phase, revision, and closure of this observation, without its payload.
    public var description: String {
        "\(Phase.self), revision \(record.revision)\(record.isClosed ? ", closed" : "")"
    }
    /// Prepares the declared edge with phase and operation authority preserved.
public func begin(_ input: Int) throws(PreparationFailure<Problem>) -> Prepared where Phase == Idle {
    let change: Change<Loading, Effect.Begin>
    do {
        change = try Flow.begin(payload, input)
    } catch {
        throw .domain(error)
    }
    do {
        let candidate = try _stateMachinePrepare(on: record, next: .loading(change.next),
            effects: change.effects.map(\.effect),
            from: 0, to: 1, invalidates: [0],
            requiring: nil, claim: claim)
        return Prepared(candidate)
    } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func cancel() throws(PreparationFailure<Never>) -> Prepared where Phase == Loading {
        let next: Idle
        next = Flow.cancel(payload)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .idle(next),
                effects: [],
                from: 1, to: 0, invalidates: [0],
                requiring: nil, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func sessionChanged() throws(PreparationFailure<Never>) -> Prepared where Phase == Loading {
        let next: Loading
        next = Flow.sessionChanged(payload)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .loading(next),
                effects: [],
                from: 1, to: 1, invalidates: [1],
                requiring: nil, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func note(_ input: String) throws(PreparationFailure<Never>) -> Prepared where Phase == Loading {
        let change: Change<Loading, Effect.Note>
        change = Flow.note(payload, input)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .loading(change.next),
                effects: change.effects.map(\.effect),
                from: 1, to: 1, invalidates: [],
                requiring: nil, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func received(_ completion: FetchSuccessCompletion) throws(PreparationFailure<Never>) -> Prepared where Phase == Loading {
        let next: Loaded
        next = Flow.received(payload, completion.value)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .loaded(next),
                effects: [],
                from: 1, to: 2, invalidates: [],
                requiring: completion.authority, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func failed(_ completion: FetchFailureCompletion) throws(PreparationFailure<Never>) -> Prepared where Phase == Loading {
        let next: Failed
        next = Flow.failed(payload, completion.value)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .failed(next),
                effects: [],
                from: 1, to: 3, invalidates: [],
                requiring: completion.authority, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func audited(_ completion: AuditSuccessCompletion) throws(PreparationFailure<Never>) -> Prepared where Phase == Loading {
        let next: Loading
        next = Flow.audited(payload, completion.value)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .loading(next),
                effects: [],
                from: 1, to: 1, invalidates: [],
                requiring: completion.authority, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func restart(_ input: Bool) throws(PreparationFailure<Never>) -> Prepared where Phase == Loaded {
        let next: Idle
        next = Flow.restart(payload, input)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .idle(next),
                effects: [],
                from: 2, to: 0, invalidates: [],
                requiring: nil, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    public func keep(_ input: Bool) throws(PreparationFailure<Never>) -> Prepared where Phase == Loaded {
        let next: Loaded
        next = Flow.keep(payload, input)
        do {
            let candidate = try _stateMachinePrepare(on: record, next: .loaded(next),
                effects: [],
                from: 2, to: 2, invalidates: [],
                requiring: nil, claim: claim)
            return Prepared(candidate)
        } catch {
        throw .plan(error)
    }
    }
}

/// A complete historical root observation with sealed provenance.
public enum Snapshot: Sendable, StateMachineSnapshot, CustomStringConvertible {
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
    public var revision: UInt64 {
        record.revision
    }
    /// Whether this historical root records closure.
    public var isClosed: Bool {
        record.isClosed
    }
    /// Ordinary model data; constructing it confers no installation authority.
    public var model: Flow {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    public var description: String {
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

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: RuntimeDeliveryClaim? = nil) -> Snapshot {
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

/// A sealed inert candidate consumed by admission.
public struct Prepared: ~Copyable, Sendable {
    fileprivate let candidate: _StateMachineEngine.Candidate
    fileprivate init(_ candidate: _StateMachineEngine.Candidate) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
public enum PreparationRejection: Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase
    /// Actual emitted effects violate metadata or immutable limits.
    case plan(PlanRejection)
    case begin(Problem)
    case choose(Problem)
}

/// The edges each router may choose among.
public enum Route { /// The edges `choose` may choose.
    public enum Choose: Sendable {
        case restart
        case keep
    }
}

/// A prepared candidate or typed routing rejection.
public enum PreparationResult: ~Copyable, Sendable {
    case prepared(Prepared)
    case rejected(PreparationRejection)
}

/// A historical receipt for an atomic acceptance.
public struct Receipt: Sendable, StateMachineReceipt, CustomStringConvertible {
    /// The accepted historical observation.
    public let snapshot: Snapshot
    fileprivate init(_ record: _StateMachineEngine.Snapshot) {
        snapshot = _stateMachineSnapshot(record)
    }
    /// The owner-lifetime accepted revision.
    public var revision: UInt64 {
        snapshot.revision
    }
    /// The accepted phase, revision, and closure, without the payload.
    public var description: String {
        snapshot.description
    }
}

/// Why `send` did not admit an input.
public enum SendRejection: Error {
    /// Routing or the authored transition declined the input before a candidate existed.
    case preparation(PreparationRejection)
    /// The owner refused the prepared candidate; read `snapshot()` for the current root.
    case commit(CommitRejection)
}

/// Admission either publishes the entire candidate or leaves all state unchanged.
public enum CommitResult: Sendable {
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
public struct FetchWork: Sendable {
    /// The immutable declared input.
    public let input: Fetch.Input
    fileprivate let authority: RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    public var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    public func succeeded(_ value: Fetch.Output) -> FetchCompletion {
        .success(FetchSuccessCompletion(value: value, authority: authority))
    }

    /// Seals a failed terminal result for this exact work.
    public func failed(_ value: Fetch.Failure) -> FetchCompletion {
        .failure(FetchFailureCompletion(value: value, authority: authority))
    }
}

/// A sealed successful terminal result for one declared operation.
public struct FetchSuccessCompletion: Sendable {
    /// The typed successful value.
    public let value: Fetch.Output
    fileprivate let authority: RuntimeTicket
}

/// A sealed failed terminal result for one declared operation.
public struct FetchFailureCompletion: Sendable {
    /// The typed failure value.
    public let value: Fetch.Failure
    fileprivate let authority: RuntimeTicket
}

/// The closed terminal vocabulary for this operation.
public enum FetchCompletion: Sendable {
    case success(FetchSuccessCompletion)
    case failure(FetchFailureCompletion)
    fileprivate var authority: RuntimeTicket {
        switch self {
                case .success(let value):
            return value.authority
                case .failure(let value):
            return value.authority
            }
    }
}

/// Work issued exclusively from an accepted command batch.
public struct AuditWork: Sendable {
    /// The immutable declared input.
    public let input: Audit.Input
    fileprivate let authority: RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    public var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    public func succeeded(_ value: Audit.Output) -> AuditCompletion {
        .success(AuditSuccessCompletion(value: value, authority: authority))
    }

    /// Seals a failed terminal result for this exact work.
    public func failed(_ value: Audit.Failure) -> AuditCompletion {

    }
}

/// A sealed successful terminal result for one declared operation.
public struct AuditSuccessCompletion: Sendable {
    /// The typed successful value.
    public let value: Audit.Output
    fileprivate let authority: RuntimeTicket
}

/// A sealed failed terminal result for one declared operation.
public struct AuditFailureCompletion: Sendable {
    /// The typed failure value.
    public let value: Audit.Failure
    fileprivate let authority: RuntimeTicket
}

/// The closed terminal vocabulary for this operation.
public enum AuditCompletion: Sendable {
    case success(AuditSuccessCompletion)
    case failure(AuditFailureCompletion)
    fileprivate var authority: RuntimeTicket {
        switch self {
                case .success(let value):
            return value.authority
                case .failure(let value):
            return value.authority
            }
    }
}

/// Closed typed terminal outcomes for this domain.
public enum Completion: Sendable {
    case fetch(FetchCompletion)
    case audit(AuditCompletion)
    fileprivate var authority: RuntimeTicket {
        switch self {
        case .fetch(let value):
            return value.authority
        case .audit(let value):
            return value.authority
        }
    }
}

/// A sealed handle to actual execution bookkeeping.
public struct ExecutionHandle: Equatable, Sendable {
    fileprivate let authority: RuntimeTicket
}

/// Physical termination is independent of cancellation or completion delivery.
public enum ExecutionDisposition: Equatable, Sendable {
    case terminated, skippedBeforeStart
}

/// Whether a physical execution acknowledgment was recorded.
public enum AcknowledgmentResult: Equatable, Sendable {
    case recorded
    case duplicate
    case foreignOwner
}

/// A closed accepted start or cancellation command.
public enum Command: Sendable {
    case cancel(ExecutionHandle)
    case fetch(FetchWork)
    case audit(AuditWork)
}

/// One whole FIFO batch with its historical receipt.
public struct CommandBatch: Sendable {
    /// The atomic acceptance represented by this batch.
    public let receipt: Receipt
    /// Cancellation commands followed by starts in authored effect order.
    public let commands: [Command]
    /// Whether this is the separately reserved close batch.
    public let terminal: Bool
    fileprivate init(receipt: Receipt, commands: [Command], terminal: Bool) {
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
                return .fetch(FetchWork(input: input, authority: work.ticket))
            case .audit(let input):
                return .audit(AuditWork(input: input, authority: work.ticket))
            }
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Int]] {
    [[1], Array(0 ..< 4)]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Flow, effects: [Effect], from: Int, to: Int,
    invalidates: [Int], requiring ticket: RuntimeTicket?, claim: RuntimeDeliveryClaim?
) throws(PlanRejection) -> _StateMachineEngine.Candidate {
    var edits: [_StateMachineEngine.ScopeEdit] = []
    for (scope, phases) in _stateMachineEligibility.enumerated() {
        let before = phases.contains(from)
        let after = phases.contains(to)
        if after && (!before || invalidates.contains(scope)) {
            edits.append(.activate(RuntimeScopeID(kind: UInt32(scope))))
        }
        else if before && !after {
            edits.append(.remove(RuntimeScopeID(kind: UInt32(scope))))
        }
    }
    var starts: [_StateMachineEngine.Start] = []
    var counts = Array(repeating: 0, count: 2)
    for effect in effects {
        switch effect {
        case .fetch(let input):
            let _: Fetch.Input = input
            counts[0] += 1
            guard counts[0] <= 1 else {
                throw .invalidPlan
            }
            starts.append(.init(RuntimeOperation(kind: 0, scope: RuntimeScopeID(kind: 0),
                dependencies: [RuntimeScopeID(kind: 1)], policy: .latest), descriptor: effect))
        case .audit(let input):
            let _: Audit.Input = input
            counts[1] += 1
            guard counts[1] <= 2 else {
                throw .invalidPlan
            }
            starts.append(.init(RuntimeOperation(kind: 1, scope: RuntimeScopeID(kind: 0),
                dependencies: [RuntimeScopeID(kind: 1)], policy: .parallel(2)), descriptor: effect))
        }
    }
    return try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map {
            [$0]
        } ?? [],
        plan: .init(scopes: edits, retire: ticket.map {
                [$0]
            } ?? [], starts: starts,
            controlCount: invalidates.count, finishingClaims: claim.map {
                [$0]
            } ?? []))
}

/// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
public static func prepare(_ input: Input, on snapshot: Snapshot) -> PreparationResult {
    switch (input, snapshot) {
    case (.load(let input), .idle(let source)):
        do {
            return .prepared(try source.begin(input))
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let error):
                return .rejected(.begin(error))
            }
        }
    case (.cancel, .loading(let source)):
        do {
            return .prepared(try source.cancel())
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let never):
                switch never {
                }
            }
        }
    case (.sessionChanged, .loading(let source)):
        do {
            return .prepared(try source.sessionChanged())
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let never):
                switch never {
                }
            }
        }
    case (.note(let input), .loading(let source)):
        do {
            return .prepared(try source.note(input))
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let never):
                switch never {
                }
            }
        }
    case (.tick(let input), .loaded(let source)):
        let selection: Route.Choose
        do {
            selection = try Flow.choose(source.value, input)
        } catch {
            return .rejected(.choose(error))
        }
        switch selection {
        case .restart:
            do {
                return .prepared(try source.restart(input))
            }
            catch {
                switch error {
                case .plan(let reason):
                    return .rejected(.plan(reason))
                case .domain(let never):
                    switch never {
                    }
                }
            }
        case .keep:
            do {
                return .prepared(try source.keep(input))
            }
            catch {
                switch error {
                case .plan(let reason):
                    return .rejected(.plan(reason))
                case .domain(let never):
                    switch never {
                    }
                }
            }
        }
    default:
        return .rejected(.invalidPhase)
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) -> PreparationResult {
    switch (completion, snapshot) {
    case (.fetch(.success(let completion)), .loading(let source)):
        do {
            return .prepared(try source.received(completion))
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let never):
                switch never {
                }
            }
        }
    case (.fetch(.failure(let completion)), .loading(let source)):
        do {
            return .prepared(try source.failed(completion))
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let never):
                switch never {
                }
            }
        }
    case (.audit(.success(let completion)), .loading(let source)):
        do {
            return .prepared(try source.audited(completion))
        }
        catch {
            switch error {
            case .plan(let reason):
                return .rejected(.plan(reason))
            case .domain(let never):
                switch never {
                }
            }
        }
    default:
        return .rejected(.invalidPhase)
    }
}

/// A phase saved data can restore: one in which no operation is active, so no work resumes.
public enum Restoration: Sendable {
    case idle(Idle)
    case loaded(Loaded)
    case failed(Failed)
}

fileprivate static func _stateMachineRestored(_ saved: Int) throws(Problem) -> (model: Flow, scopes: [RuntimeScopeID]) {
    switch try Flow.restore(saved) {
    case .idle(let payload):
        return (.idle(payload), [RuntimeScopeID(kind: 1)])
    case .loaded(let payload):
        return (.loaded(payload), [RuntimeScopeID(kind: 1)])
    case .failed(let payload):
        return (.failed(payload), [RuntimeScopeID(kind: 1)])
    }
}

fileprivate typealias _StateMachineLedger = RuntimeDeliveryLedger<Flow, Effect, Completion, PreparationRejection>

/// The opaque identity of a first retained terminal envelope.
public typealias PendingCompletionID = RuntimePendingID

/// Typed historical diagnostics for a retained completion.
public typealias PendingCompletion = RuntimeDeliveryLedger<Flow, Effect, Completion, PreparationRejection>.Pending

/// The obligations a managed owner still tracked when its shutdown deadline expired.
public typealias ShutdownDiagnostics = RuntimeShutdownDiagnostics

/// Whether shutdown joined every obligation or stopped waiting at its deadline.
///
/// A timeout leaves the owner closed and its outstanding work tracked.
public enum ShutdownResult: Sendable {
    case quiescent
    case timedOut(ShutdownDiagnostics)
}

/// A closed completion delivery decision.
public enum DeliveryResult: Sendable {
    case committed(Receipt)
    case pending(PendingCompletionID, PendingStatus)
    case inProgress
    case notPending
    /// The operation's authority is inactive or its outcome was already settled.
    case stale
    /// The completion was issued by a different owner.
    case foreignOwner
    case discarded(Receipt)
    case rejected(CommitRejection)
}

fileprivate static func _stateMachineFinish(_ result: _StateMachineLedger.Finish) -> DeliveryResult {
    switch result {
    case .committed(let record):
        return .committed(Receipt(record))
    case .pending(let id, let status):
        return .pending(id, status)
    case .notPending:
        return .notPending
    }
}

fileprivate static func _stateMachineDeliveryPreparation(_ attempt: _StateMachineLedger.Attempt) -> _StateMachineLedger.Preparation {
    switch _stateMachineCompletion(attempt.outcome, on: _stateMachineSnapshot(attempt.snapshot, claim: attempt.claim)) {
    case .prepared(let prepared):
        return .success(prepared.candidate)
    case .rejected(let reason):
        if case .plan(let plan) = reason {
        return .failure(.plan(plan))
    }
        return .failure(.domain(reason))
    }
}

/// A noncopyable manually driven owner with an embedded value engine.
public struct Local: ~Copyable {
    fileprivate var engine: _StateMachineEngine
    fileprivate var ledger = _StateMachineLedger()
    /// Creates fresh authority only in the declared initial phase.
    public init(_ initial: Idle = Flow.makeIdle(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], limits: configuration)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, configuration: LocalConfiguration = .default) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        engine = _StateMachineEngine(restored.model, scopes: restored.scopes, limits: configuration)
    }
    /// Returns an immutable historical observation.
    public borrowing func snapshot() -> Snapshot {
        _stateMachineSnapshot(engine.snapshot)
    }
    /// Consumes and atomically accepts or rejects a complete candidate.
    public mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
        let result = engine.commit(prepared.candidate)
        ledger.prune(in: engine)
        return _stateMachineAdmission(result)
    }
    /// Routes, prepares and admits one input against the current root.
    @discardableResult
    public mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
        switch Flow.prepare(input, on: snapshot()) {
        case .prepared(let prepared):
            switch commit(prepared) {
            case .committed(let receipt):
                return receipt
            case .rejected(let reason, _):
                throw .commit(reason)
            }
        case .rejected(let reason):
            throw .preparation(reason)
        }
    }
    /// Transfers whole FIFO batches; physical execution occurs after mutating access ends.
    public mutating func drainCommands(limit: Int) -> [CommandBatch] {
        engine.drain(limit: limit).map {
            _stateMachineBatch($0)
        }
    }
    /// Records actual termination independently of cancellation and completion delivery.
    public mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition) -> AcknowledgmentResult {
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
    public mutating func deliver(_ completion: Completion) -> DeliveryResult {
        switch ledger.retain(completion, for: completion.authority, in: &engine) {
        case .stale:
            return .stale
        case .foreignOwner:
            return .foreignOwner
        case .pending(let id):
            guard let pending = ledger.pending.first(where: { $0.id == id
        }) else {
        return .notPending
    }
            if pending.status != .awaitingAdmission {
        return .pending(id, pending.status)
    }
            return reconcile(id: id)
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
    public mutating func reconcile(id: PendingCompletionID) -> DeliveryResult {
        switch ledger.claim(id, in: &engine) {
        case .inProgress:
            return .inProgress
        case .notPending:
            return .notPending
        case .claimed(let attempt):
            let preparation = _stateMachineDeliveryPreparation(attempt)
            return _stateMachineFinish(ledger.finish(attempt, preparation: preparation, in: &engine))
        }
    }
    /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
    ///
    /// Draining and acknowledging never admit a retained completion; call this after they free capacity.
    public mutating func retryAdmission(id: PendingCompletionID) -> DeliveryResult {
        _stateMachineFinish(ledger.retryAdmission(id, in: &engine))
    }
    /// Queries immutable first-outcome records without claiming preparation.
    public borrowing func pendingCompletions() -> [PendingCompletion] {
        ledger.pending
    }
    /// Revokes one retained operation using an atomic authority-only commit.
    public mutating func discardPending(id: PendingCompletionID) -> DeliveryResult {
        guard let result = ledger.discard(id, in: &engine) else {
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
    public mutating func close() -> Receipt {
        let result = engine.close()
        ledger.prune(in: engine)
        return Receipt(result)
    }
    /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
    public var isQuiescent: Bool {
        engine.isQuiescent
    }
}

/// Immutable operation selections whose non-Sendable values stay within MainActor.
@MainActor public struct MainActorDrivers {
    /// Executes this operation within the selected isolation.
public let fetch: @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>
    /// Executes this operation within the selected isolation.
    public let audit: @MainActor (Audit.Input) async -> Result<Audit.Output, Audit.Failure>
    /// Selects every driver for this owner's lifetime.
    public init(fetch: @escaping @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>, audit: @escaping @MainActor (Audit.Input) async -> Result<Audit.Output, Audit.Failure>) {
        self.fetch = fetch
        self.audit = audit
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
@MainActor public final class MainActorHost: MainActorStateMachineHost {
    private typealias Host = RuntimeMainActorHost<Flow, Effect, Completion, PreparationRejection>
    private let host: Host
    /// Creates fresh authority and immutable execution selections.
    public init(_ initial: Idle = Flow.makeIdle(), drivers: MainActorDrivers, configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @MainActor (PendingCompletion) -> Void = { _ in
        }) {
        host = Host(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .fetch(let input):
                                let work = FetchWork(input: input, authority: raw.ticket)
                                switch await drivers.fetch(input) {
                                case .success(let value):
                    return .fetch(work.succeeded(value))
                                case .failure(let value):
                    return .fetch(work.failed(value))
                                }
                            case .audit(let input):
                                let work = AuditWork(input: input, authority: raw.ticket)
                                switch await drivers.audit(input) {
                                case .success(let value):
                    return .audit(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, drivers: MainActorDrivers, configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @MainActor (PendingCompletion) -> Void = { _ in
        }) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .fetch(let input):
                                let work = FetchWork(input: input, authority: raw.ticket)
                                switch await drivers.fetch(input) {
                                case .success(let value):
                    return .fetch(work.succeeded(value))
                                case .failure(let value):
                    return .fetch(work.failed(value))
                                }
                            case .audit(let input):
                                let work = AuditWork(input: input, authority: raw.ticket)
                                switch await drivers.audit(input) {
                                case .success(let value):
                    return .audit(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    public convenience init(_ initial: Idle = Flow.makeIdle(),
        fetchDriver: @escaping @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @MainActor (Audit.Input) async -> Result<Audit.Output, Audit.Failure>,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @MainActor (PendingCompletion) -> Void = { _ in
        }) {
        self.init(initial, drivers: MainActorDrivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy,
            onReconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @MainActor (Audit.Input) async -> Result<Audit.Output, Audit.Failure>,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @MainActor (PendingCompletion) -> Void = { _ in
        }) throws(Problem) {
        try self.init(restoring: saved, drivers: MainActorDrivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy,
            onReconciliationRequired: onReconciliationRequired)
    }
    /// Captures a complete historical observation.
    public func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    @discardableResult
    public func send(_ input: Input) throws(SendRejection) -> Receipt {
        let result = host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, PreparationRejection> in
            switch Flow.prepare(input, on: _stateMachineSnapshot(raw)) {
            case .prepared(let prepared):
                return .success(prepared.candidate)
            case .rejected(let reason):
                return .failure(reason)
            }
        }
        switch result {
        case .success(.committed(let record)):
            return Receipt(record)
        case .success(.rejected(let reason, _)):
            throw .commit(reason)
        case .failure(let reason):
            throw .preparation(reason)
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    public func commit(_ prepared: consuming Prepared) -> CommitResult {
        let candidate = prepared.candidate
        return _stateMachineAdmission(host.commit(candidate))
    }
    /// Subscribes to initial, accepted and terminal complete snapshots.
    public func subscribe(_ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {
        }) throws(SubscriptionFailure) -> MainActorSubscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots.
    ///
    /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
    public func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.sendableSnapshots {
            _stateMachineSnapshot($0)
        }
    }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered. The sequence supports every
    /// `AsyncSequence` operator on every supported OS version.
    public func snapshots<Projection: Sendable>(
        _ transform: @escaping @MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> RuntimeSnapshots<Projection> {
        try host.sendableSnapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    /// Retains the first terminal outcome and validates current authority.
    public func deliver(_ completion: Completion) -> DeliveryResult {
        return Self.project(host.deliver(completion))
    }
    /// Delivers the sealed terminal result of one `Fetch` execution.
public func deliver(_ completion: FetchCompletion) -> DeliveryResult {
    deliver(.fetch(completion))
    }
    /// Delivers the sealed terminal result of one `Audit` execution.
    public func deliver(_ completion: AuditCompletion) -> DeliveryResult {
        deliver(.audit(completion))
    }
    /// Reads immutable retained first-outcome diagnostics.
    public func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions()
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.reconcile(id: id))
    }
    /// Revokes retained delivery with an authority-only admission.
    public func discardPending(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.discardPending(id: id))
    }
    /// Closes admission while preserving historical model data.
    public func close() -> Receipt {
        Receipt(host.close())
    }
    /// Waits for cancellation and launch decisions through this owner-bound receipt.
    public func flush(through receipt: Receipt) async -> Bool {
        await host.flush(through: receipt.snapshot.record)
    }
    /// Closes and joins actual execution and retained delivery obligations.
    public func shutdown() async {
        await host.shutdown()
    }
    /// Closes and waits for settlement through an optional deadline; outstanding work stays tracked after a timeout.
    public func shutdownAndWait(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        if await host.shutdownAndWait(deadline: deadline) {
            return .quiescent
        }
        return .timedOut(host.diagnostics())
    }
    /// Actual workers whose joined termination has not yet been processed.
    public var runningCount: Int {
        host.runningCount
    }
    /// Live observer registrations.
    public var subscriberCount: Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Bool {
        host.isQuiescent
    }
    private static func project(_ result: RuntimeHostDelivery<Flow, Effect>) -> DeliveryResult {
        switch result {
        case .committed(let record):
            return .committed(Receipt(record))
        case .pending(let id, let status):
            return .pending(id, status)
        case .inProgress:
            return .inProgress
        case .notPending:
            return .notPending
        case .stale:
            return .stale
        case .foreignOwner:
            return .foreignOwner
        case .discarded(let record):
            return .discarded(Receipt(record))
        case .rejected(let reason):
            return .rejected(reason)
        }
    }
}

/// Immutable typed execution selection for one managed owner's lifetime.
public struct Drivers: Sendable {
    /// Executes one typed operation outside admission locks.
public let fetch: @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>
    /// Executes one typed operation outside admission locks.
    public let audit: @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>
    /// Selects all drivers for this owner.
    public init(fetch: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>, audit: @escaping @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>) {
        self.fetch = fetch
        self.audit = audit
    }
}

/// A synchronous shared owner with managed physical execution and terminal delivery.
public final class Shared: Sendable {
    private let host: RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>
    /// Creates fresh initial authority and retains the driver selection immutably.
    public init(_ initial: Idle = Flow.makeIdle(), drivers: Drivers, configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) {
        host = RuntimeSharedHost(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .fetch(let input):
                                let work = FetchWork(input: input, authority: raw.ticket)
                                switch await drivers.fetch(input) {
                                case .success(let value):
                    return .fetch(work.succeeded(value))
                                case .failure(let value):
                    return .fetch(work.failed(value))
                                }
                            case .audit(let input):
                                let work = AuditWork(input: input, authority: raw.ticket)
                                switch await drivers.audit(input) {
                                case .success(let value):
                    return .audit(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            }, prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, drivers: Drivers, configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = RuntimeSharedHost(restored.model, scopes: restored.scopes, limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .fetch(let input):
                                let work = FetchWork(input: input, authority: raw.ticket)
                                switch await drivers.fetch(input) {
                                case .success(let value):
                    return .fetch(work.succeeded(value))
                                case .failure(let value):
                    return .fetch(work.failed(value))
                                }
                            case .audit(let input):
                                let work = AuditWork(input: input, authority: raw.ticket)
                                switch await drivers.audit(input) {
                                case .success(let value):
                    return .audit(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            }, prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    public convenience init(_ initial: Idle = Flow.makeIdle(),
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) {
        self.init(initial, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy,
            onReconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) throws(Problem) {
        try self.init(restoring: saved, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy,
            onReconciliationRequired: onReconciliationRequired)
    }
    /// Captures a coherent historical observation.
    public func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Registers a serial capacity-one latest-value observation callback.
    public func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {
        }) throws(SubscriptionFailure) -> Subscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots.
    ///
    /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
    public func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
    /// Routes, prepares and admits one input in a single attempt.
    ///
    /// Preparation runs outside the lock against one snapshot and is never repeated, so
    /// a concurrent commit surfaces as `.commit(.conflict)` for the caller to resolve.
    @discardableResult
    public func send(_ input: Input) throws(SendRejection) -> Receipt {
        switch Flow.prepare(input, on: snapshot()) {
        case .prepared(let prepared):
            switch commit(prepared) {
            case .committed(let receipt):
                return receipt
            case .rejected(let reason, _):
                throw .commit(reason)
            }
        case .rejected(let reason):
            throw .preparation(reason)
        }
    }
    /// Consumes one candidate into an atomic admission attempt.
    public func commit(_ prepared: consuming Prepared) -> CommitResult {
        _stateMachineAdmission(host.commit(prepared.candidate))
    }
    /// Retains and attempts delivery of the first typed terminal outcome.
    public func deliver(_ completion: Completion) -> DeliveryResult {
        return Self.project(host.deliver(completion))
    }
    /// Delivers the sealed terminal result of one `Fetch` execution.
public func deliver(_ completion: FetchCompletion) -> DeliveryResult {
    deliver(.fetch(completion))
    }
    /// Delivers the sealed terminal result of one `Audit` execution.
    public func deliver(_ completion: AuditCompletion) -> DeliveryResult {
        deliver(.audit(completion))
    }
    /// Returns immutable first-outcome diagnostics.
    public func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions()
    }
    /// Claims one fresh preparation for a retained outcome.
    public func reconcile(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.reconcile(id: id))
    }
    /// Revokes one retained operation by an authority-only commit.
    public func discardPending(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.discardPending(id: id))
    }
    /// Ends admission and schedules cancellation in FIFO order.
    public func close() -> Receipt {
        Receipt(host.close())
    }
    /// Waits until cancellation and launch decisions through this receipt have been processed.
    public func flush(through receipt: Receipt) async -> Bool {
        await host.flush(through: receipt.snapshot.record)
    }
    /// Closes and waits for actual execution termination and retained obligation settlement.
    public func shutdown() async {
        await host.shutdown()
    }
    /// Closes and waits for settlement through an optional deadline; outstanding work stays tracked.
    public func shutdownAndWait(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        if await host.shutdownAndWait(deadline: deadline) {
            return .quiescent
        }
        return .timedOut(host.diagnostics())
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Bool {
        host.isQuiescent
    }
    private static func project(_ result: RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>.Delivery) -> DeliveryResult {
        switch result {
        case .committed(let record):
            return .committed(Receipt(record))
        case .pending(let id, let status):
            return .pending(id, status)
        case .inProgress:
            return .inProgress
        case .notPending:
            return .notPending
        case .stale:
            return .stale
        case .foreignOwner:
            return .foreignOwner
        case .discarded(let record):
            return .discarded(Receipt(record))
        case .rejected(let reason):
            return .rejected(reason)
        }
    }
}

/// A sealed sole-writer native actor owner with managed execution.
public final class ActorHost: Sendable {
    private typealias Host = RuntimeActorHost<Flow, Effect, Completion, PreparationRejection>
    private let host: Host
    /// Creates fresh authority and immutable execution selections.
    public init(_ initial: Idle = Flow.makeIdle(), drivers: Drivers, configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) {
        host = Host(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .fetch(let input):
                                let work = FetchWork(input: input, authority: raw.ticket)
                                switch await drivers.fetch(input) {
                                case .success(let value):
                    return .fetch(work.succeeded(value))
                                case .failure(let value):
                    return .fetch(work.failed(value))
                                }
                            case .audit(let input):
                                let work = AuditWork(input: input, authority: raw.ticket)
                                switch await drivers.audit(input) {
                                case .success(let value):
                    return .audit(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, drivers: Drivers, configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .fetch(let input):
                                let work = FetchWork(input: input, authority: raw.ticket)
                                switch await drivers.fetch(input) {
                                case .success(let value):
                    return .fetch(work.succeeded(value))
                                case .failure(let value):
                    return .fetch(work.failed(value))
                                }
                            case .audit(let input):
                                let work = AuditWork(input: input, authority: raw.ticket)
                                switch await drivers.audit(input) {
                                case .success(let value):
                    return .audit(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    public convenience init(_ initial: Idle = Flow.makeIdle(),
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) {
        self.init(initial, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy,
            onReconciliationRequired: onReconciliationRequired)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) throws(Problem) {
        try self.init(restoring: saved, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy,
            onReconciliationRequired: onReconciliationRequired)
    }
    /// Captures a complete historical observation.
    public func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    @discardableResult
    public func send(_ input: Input) async throws(SendRejection) -> Receipt {
        let result = await host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, PreparationRejection> in
            switch Flow.prepare(input, on: _stateMachineSnapshot(raw)) {
            case .prepared(let prepared):
                return .success(prepared.candidate)
            case .rejected(let reason):
                return .failure(reason)
            }
        }
        switch result {
        case .success(.committed(let record)):
            return Receipt(record)
        case .success(.rejected(let reason, _)):
            throw .commit(reason)
        case .failure(let reason):
            throw .preparation(reason)
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    public func commit(_ prepared: consuming Prepared) async -> CommitResult {
        let candidate = prepared.candidate
        return _stateMachineAdmission(await host.commit(candidate))
    }
    /// Subscribes to initial, accepted and terminal complete snapshots.
    public func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {
        }) async throws(SubscriptionFailure) -> Subscription {
        try await host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots.
    ///
    /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
    public func snapshots() async throws(SubscriptionFailure) -> Snapshots {
        try await host.snapshots {
            _stateMachineSnapshot($0)
        }
    }

    /// Retains the first terminal outcome and validates current authority.
    public func deliver(_ completion: Completion) async -> DeliveryResult {
        return Self.project(await host.deliver(completion))
    }
    /// Delivers the sealed terminal result of one `Fetch` execution.
public func deliver(_ completion: FetchCompletion) async -> DeliveryResult {
    await deliver(.fetch(completion))
    }
    /// Delivers the sealed terminal result of one `Audit` execution.
    public func deliver(_ completion: AuditCompletion) async -> DeliveryResult {
        await deliver(.audit(completion))
    }
    /// Reads immutable retained first-outcome diagnostics.
    public func pendingCompletions() async -> [PendingCompletion] {
        await host.pendingCompletions()
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) async -> DeliveryResult {
        Self.project(await host.reconcile(id: id))
    }
    /// Revokes retained delivery with an authority-only admission.
    public func discardPending(id: PendingCompletionID) async -> DeliveryResult {
        Self.project(await host.discardPending(id: id))
    }
    /// Closes admission while preserving historical model data.
    public func close() async -> Receipt {
        Receipt(await host.close())
    }
    /// Waits for cancellation and launch decisions through this owner-bound receipt.
    public func flush(through receipt: Receipt) async -> Bool {
        await host.flush(through: receipt.snapshot.record)
    }
    /// Closes and joins actual execution and retained delivery obligations.
    public func shutdown() async {
        await host.shutdown()
    }
    /// Closes and waits for settlement through an optional deadline; outstanding work stays tracked after a timeout.
    public func shutdownAndWait(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        if await host.shutdownAndWait(deadline: deadline) {
            return .quiescent
        }
        return .timedOut(await host.diagnostics())
    }
    /// Actual workers whose joined termination has not yet been processed.
    public var runningCount: Int {
        get async {
            await host.runningCount
        }
    }
    /// Live observer registrations.
    public var subscriberCount: Int {
        get async {
            await host.subscriberCount
        }
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Bool {
        get async {
            await host.isQuiescent
        }
    }
    private static func project(_ result: RuntimeHostDelivery<Flow, Effect>) -> DeliveryResult {
        switch result {
        case .committed(let record):
            return .committed(Receipt(record))
        case .pending(let id, let status):
            return .pending(id, status)
        case .inProgress:
            return .inProgress
        case .notPending:
            return .notPending
        case .stale:
            return .stale
        case .foreignOwner:
            return .foreignOwner
        case .discarded(let record):
            return .discarded(Receipt(record))
        case .rejected(let reason):
            return .rejected(reason)
        }
    }
}
