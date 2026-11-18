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
    /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
    public borrowing func withValue<Result: ~Copyable, Failure: Error>(
        _ body: (borrowing Phase) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(phase)
    }
    /// Consumes this authority and returns its payload, so a unique resource can move on.
    public consuming func takeValue() -> Phase {
        phase
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
    fileprivate consuming func restart(_ input: Bool) -> Owned<Idle> where Phase == Loaded {
        Owned<Idle>(Flow.restart(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    fileprivate consuming func keep(_ input: Bool) -> Owned<Loaded> where Phase == Loaded {
        Owned<Loaded>(Flow.keep(phase, input))
    }
    /// Runs the router `choose`, then advances through the edge it selects.
public consuming func choose(_ input: Bool) -> Route.ChooseResult where Phase == Loaded {
    let selection: Route.Choose
    do {
        selection = try Flow.choose(phase, input)
    } catch {
        return .rejected(error, self)
    }
    switch selection {
    case .restart:
        return .restart(restart(input))
    case .keep:
        return .keep(keep(input))
    }
    }
}

/// Creates ownership only in the declared initial phase.
public static func owned(_ initial: consuming Idle = Flow.makeIdle()) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = RuntimeState<Flow, Effect>

/// Validated bounds for managed admission and serial subscriptions.
public typealias Configuration = StateMachine.ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
public typealias LocalConfiguration = StateMachine.Limits

/// A live observation registration; cancelling or releasing it stops delivery.
public typealias Subscription = StateMachine.SnapshotSubscription

/// A live MainActor observation registration; cancelling or releasing it stops delivery.
public typealias MainActorSubscription = StateMachine.MainActorSnapshotSubscription

/// Failure to register another live observer.
public typealias SubscriptionFailure = StateMachine.SubscriptionFailure

/// A single-pass latest-value sequence of an owner's snapshots.
public typealias Snapshots = StateMachine.SnapshotSequence<Snapshot>

/// The disposition of a retained completion.
public typealias PendingStatus = StateMachine.PendingStatus

/// Why an owner refused a prepared candidate, in precedence order.
public typealias CommitRejection = StateMachine.CommitRejection

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
    /// Prepares the declared edge with phase authority preserved.
public func begin(_ input: Int) throws(Problem) -> Prepared where Phase == Idle {
    let change: Change<Loading, Effect.Begin> = try Flow.begin(payload, input)
    return _stateMachinePrepare(on: record, next: .loading(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 1, invalidates: [0],
        requiring: nil, claim: claim)
    }
    /// Prepares the declared edge with phase authority preserved.
    public func cancel() -> Prepared where Phase == Loading {
        let next: Idle = Flow.cancel(payload)
        return _stateMachinePrepare(on: record, next: .idle(next),
            effects: [],
            from: 1, to: 0, invalidates: [0],
            requiring: nil, claim: claim)
    }
    /// Prepares the declared edge with phase authority preserved.
    public func sessionChanged() -> Prepared where Phase == Loading {
        let next: Loading = Flow.sessionChanged(payload)
        return _stateMachinePrepare(on: record, next: .loading(next),
            effects: [],
            from: 1, to: 1, invalidates: [1],
            requiring: nil, claim: claim)
    }
    /// Prepares the declared edge with phase authority preserved.
    public func note(_ input: String) -> Prepared where Phase == Loading {
        let change: Change<Loading, Effect.Note> = Flow.note(payload, input)
        return _stateMachinePrepare(on: record, next: .loading(change.next),
            effects: change.effects.map(\.effect),
            from: 1, to: 1, invalidates: [],
            requiring: nil, claim: claim)
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func received(_ value: Fetch.Output, authority: RuntimeTicket) -> Prepared where Phase == Loading {
        let next: Loaded = Flow.received(payload, value)
        return _stateMachinePrepare(on: record, next: .loaded(next),
            effects: [],
            from: 1, to: 2, invalidates: [],
            requiring: authority, claim: claim)
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func failed(_ value: Fetch.Failure, authority: RuntimeTicket) -> Prepared where Phase == Loading {
        let next: Failed = Flow.failed(payload, value)
        return _stateMachinePrepare(on: record, next: .failed(next),
            effects: [],
            from: 1, to: 3, invalidates: [],
            requiring: authority, claim: claim)
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func audited(_ value: Audit.Output, authority: RuntimeTicket) -> Prepared where Phase == Loading {
        let next: Loading = Flow.audited(payload, value)
        return _stateMachinePrepare(on: record, next: .loading(next),
            effects: [],
            from: 1, to: 1, invalidates: [],
            requiring: authority, claim: claim)
    }
    /// Prepares the declared edge that the router `choose` selects.
    fileprivate func restart(_ input: Bool) -> Prepared where Phase == Loaded {
        let next: Idle = Flow.restart(payload, input)
        return _stateMachinePrepare(on: record, next: .idle(next),
            effects: [],
            from: 2, to: 0, invalidates: [],
            requiring: nil, claim: claim)
    }
    /// Prepares the declared edge that the router `choose` selects.
    fileprivate func keep(_ input: Bool) -> Prepared where Phase == Loaded {
        let next: Loaded = Flow.keep(payload, input)
        return _stateMachinePrepare(on: record, next: .loaded(next),
            effects: [],
            from: 2, to: 2, invalidates: [],
            requiring: nil, claim: claim)
    }
    /// Runs the router `choose`, then prepares the edge it selects.
    public func choose(_ input: Bool) throws(Problem) -> Prepared where Phase == Loaded {
        let selection: Route.Choose = try Flow.choose(payload, input)
        switch selection {
    case .restart:
        return restart(input)
    case .keep:
        return keep(input)
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
///
/// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
/// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
/// another owner's or the owner is closed, which it reports first.
public struct Prepared: ~Copyable, Sendable {
    fileprivate let candidate: _StateMachineEngine.Proposal
    fileprivate init(_ candidate: _StateMachineEngine.Proposal) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
public enum PreparationRejection: Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase
    case begin(Problem)
    case choose(Problem)
}

/// The edges each router may choose among.
public enum Route { /// The edges `choose` may choose.
    public enum Choose: Sendable {
        case restart
        case keep
    }
    /// The result of `choose` on an owned `Loaded`: one case per edge it may select.
    public enum ChooseResult: ~Copyable, Sendable {
        case restart(Owned<Idle>)
        case keep(Owned<Loaded>)
        /// The router declined; the source is returned unchanged.
        case rejected(Problem, Owned<Loaded>)
    }
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
    /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`);
    /// read `snapshot()` for the current root.
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
        FetchCompletion(result: .success(value), authority: authority)
    }

    /// Seals a failed terminal result for this exact work.
public func failed(_ value: Fetch.Failure) -> FetchCompletion {
        FetchCompletion(result: .failure(value), authority: authority)
    }
}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
public struct FetchCompletion: Sendable {
    /// The typed terminal value.
    public let result: Result<Fetch.Output, Fetch.Failure>
    fileprivate let authority: RuntimeTicket
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
        AuditCompletion(value: value, authority: authority)
    }


}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
public struct AuditCompletion: Sendable {
    /// The value the operation produced; it cannot fail.
    public let value: Audit.Output
    fileprivate let authority: RuntimeTicket
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
    [[1], Array(0 ..< 4), [1]]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Flow, effects: [Effect], from: Int, to: Int,
    invalidates: [Int], requiring ticket: RuntimeTicket?, claim: RuntimeDeliveryClaim?
) -> Prepared {
    do throws(PlanRejection) {
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
                starts.append(.init(RuntimeOperation(kind: 1, scope: RuntimeScopeID(kind: 2),
                    dependencies: [RuntimeScopeID(kind: 1)], policy: .parallel(2)), descriptor: effect))
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
                        } ?? []))))
    } catch {
        return Prepared(.defective(.init(error, preparedOn: record)))
    }
}

/// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
///
/// A plan defect is not a routing rejection: it travels inside the result, and admission reports it.
public static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch (input, snapshot) {
    case (.load(let input), .idle(let source)):
        do {
            return try source.begin(input)
        } catch {
            throw .begin(error)
        }
    case (.cancel, .loading(let source)):
        return source.cancel()
    case (.sessionChanged, .loading(let source)):
        return source.sessionChanged()
    case (.note(let input), .loading(let source)):
        return source.note(input)
    case (.tick(let input), .loaded(let source)):
        let selection: Route.Choose
        do {
            selection = try Flow.choose(source.value, input)
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

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch (completion, snapshot) {
    case (.fetch(let completion), .loading(let source)):
        switch completion.result {
        case .success(let value):
        return source.received(value, authority: completion.authority)
        case .failure(let value):
        return source.failed(value, authority: completion.authority)
        }
    case (.audit(let completion), .loading(let source)):
        let value: Audit.Output = completion.value
        return source.audited(value, authority: completion.authority)
    default:
        throw .invalidPhase
    }
}

/// A phase saved data can restore: one in which no operation is active, or one the
/// `@Restoration` function lists in `allows:`. A restored owner has no outstanding work.
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

/// The opaque identity of one retained terminal outcome of this schema's owners.
public struct PendingCompletionID: Hashable, Sendable {
    fileprivate let raw: RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value: only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
public struct PendingCompletion: Sendable {
    /// The retained terminal value of one operation.
    public enum Outcome: Sendable {
        case fetch(Result<Fetch.Output, Fetch.Failure>)
        case audit(Audit.Output)
    }
    /// Why the last preparation or admission of a retained outcome did not commit.
    public enum Rejection: Sendable {
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
    /// The saturating count of claimed preparations; capacity retries do not increment it.
    public let attempts: UInt64
    /// Whether the preparation count has reached its representable limit.
    public var attemptsSaturated: Bool {
        attempts == UInt64.max
    }
    fileprivate init(_ pending: _StateMachineLedger.Pending) {
        id = PendingCompletionID(raw: pending.id)
        switch pending.outcome {
        case .fetch(let completion):
            outcome = .fetch(completion.result)
        case .audit(let completion):
            outcome = .audit(completion.value)
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
public enum DeliveryResult: Sendable {
    /// The outcome committed.
    case committed(Receipt)
    /// The outcome is retained; its status says what admission is waiting for.
    case pending(PendingCompletionID, PendingStatus)
    /// The operation's authority is inactive or its outcome was already settled.
    case stale
    /// The completion was issued by a different owner.
    case foreignOwner
}

/// The result of one more attempt to admit a retained outcome.
public enum ReconcileResult: Sendable {
    /// The retained outcome committed.
    case committed(Receipt)
    /// The outcome is still retained; its status says what admission is waiting for.
    case pending(PendingCompletionID, PendingStatus)
    /// Another attempt holds the only preparation claim.
    case inProgress
    /// No outcome with this identity is retained.
    case notPending
}

/// The result of revoking a retained outcome's operation.
public enum DiscardResult: Sendable {
    /// The authority-only commit revoked the operation and disposed of its outcome.
    case discarded(Receipt)
    /// The owner refused the authority-only commit; the outcome stays retained.
    case rejected(CommitRejection)
    /// No outcome with this identity is retained.
    case notPending
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
public struct ShutdownDiagnostics: Equatable, Sendable {
    /// An execution and delivery obligation that remained tracked.
public typealias OutstandingExecution = StateMachine.ShutdownDiagnostics.OutstandingExecution
    /// The owner's last accepted revision at the observation.
    public let acceptedRevision: UInt64
    /// The revision of the last fully processed FIFO batch.
    public let processedThrough: UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    public let hasQueuedBatches: Bool
    /// Whether a FIFO processing turn still owns responsibility.
    public let isDraining: Bool
    /// Whether an automatic retry of a retained completion is still scheduled.
public let isRetrying: Bool
    /// The identities of the retained terminal outcomes.
    public let pendingCompletions: [PendingCompletionID]
    /// The executions, deliveries, and preparations that remain tracked.
    public let outstandingExecutions: [OutstandingExecution]
    fileprivate init(_ raw: StateMachine.ShutdownDiagnostics) {
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
public enum ShutdownResult: Equatable, Sendable {
    /// Every execution, delivery, and preparation obligation settled.
    case quiescent
    /// The deadline passed first; the diagnostics describe what was still outstanding.
    case timedOut(ShutdownDiagnostics)
    fileprivate init(_ raw: StateMachine.ShutdownDiagnostics?) {
        self = raw.map {
            .timedOut(ShutdownDiagnostics($0))
        } ?? .quiescent
    }
}

/// Whether `flush(through:)` waited for a receipt's batch to be processed.
public enum FlushResult: Equatable, Sendable {
    /// Cancellation and launch decisions through the receipt have been processed.
    case processed
    /// The receipt was issued by a different owner, so there was nothing to wait for.
    case foreignOwner
}

/// A noncopyable manually driven owner with an embedded value engine.
public struct Local: ~Copyable {
    fileprivate var engine: _StateMachineEngine
    fileprivate var ledger = _StateMachineLedger()
    /// Creates fresh authority only in the declared initial phase.
    public init(_ initial: Idle = Flow.makeIdle(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], limits: configuration, recording: .commands)
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
    /// Routes, prepares and admits one input against the current root.
    @discardableResult
    public mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
        let prepared: Prepared
        do {
            prepared = try Flow.prepare(input, on: snapshot())
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
    ///
    /// This is the only way to submit a terminal outcome. A later outcome for the same work never
    /// replaces the retained one; it reports that outcome's status instead.
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
            return _stateMachineFinish(ledger.finish(attempt, preparation: preparation, in: &engine))
        }
    }
    /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
    ///
    /// Draining and acknowledging never admit a retained completion; call this after they free capacity.
    public mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult {
        _stateMachineFinish(ledger.retryAdmission(id.raw, in: &engine))
    }
    /// Queries immutable first-outcome records without claiming preparation.
    public borrowing func pendingCompletions() -> [PendingCompletion] {
        ledger.pending.map(PendingCompletion.init)
    }
    /// Revokes one retained operation using an atomic authority-only commit.
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
    public let audit: @MainActor (Audit.Input) async -> Audit.Output
    /// Selects every driver for this owner's lifetime.
    public init(fetch: @escaping @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>, audit: @escaping @MainActor (Audit.Input) async -> Audit.Output) {
        self.fetch = fetch
        self.audit = audit
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
@MainActor public final class MainActorHost: MainActorStateMachineHost {
    private typealias Host = RuntimeMainActorHost<Flow, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that cannot commit when it is delivered.
    ///
    /// The default, `.retryPure`, evaluates a completion's router and edge again after another
    /// commit wins the race, so it assumes those functions are pure. Choose
    /// `.manual(onReconciliationRequired:)` when they are not.
    ///
    /// A handler, when given, runs outside the owner's critical section each time a retained
    /// completion's status becomes `reconciliationRequired`: its completion edge or router threw,
    /// its effect plan is defective, the owner refused its admission, or an explicit
    /// `reconcile(id:)` did not commit. Settle it with `reconcile(id:)` or `discardPending(id:)`.
    public struct CompletionPolicy {
        fileprivate let runtime: RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: @MainActor (_StateMachineLedger.Pending) -> Void
        private init(_ runtime: RuntimeCompletionPolicy, handler: @escaping @MainActor (PendingCompletion) -> Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it only when every completion edge and router is deterministic and free of side
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible only through `pendingCompletions()`.
        public static var retryPure: CompletionPolicy {
        CompletionPolicy(.retryPure, handler: { _ in
            })
    }
        /// Retries lost races as `retryPure` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retryPure(onReconciliationRequired handler: @escaping @MainActor (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.retryPure, handler: handler)
        }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping @MainActor (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.manualOnConflict, handler: handler)
        }
    }
    /// Creates fresh authority and immutable execution selections.
    public init(_ initial: Idle = Flow.makeIdle(), drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) {
        host = Host(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .fetch(let input):
                    return .fetch(FetchCompletion(result: await drivers.fetch(input), authority: raw.ticket))
                case .audit(let input):
                    return .audit(AuditCompletion(value: await drivers.audit(input), authority: raw.ticket))
                }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .fetch(let input):
                    return .fetch(FetchCompletion(result: await drivers.fetch(input), authority: raw.ticket))
                case .audit(let input):
                    return .audit(AuditCompletion(value: await drivers.audit(input), authority: raw.ticket))
                }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    public convenience init(_ initial: Idle = Flow.makeIdle(),
        fetchDriver: @escaping @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @MainActor (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) {
        self.init(initial, drivers: MainActorDrivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @MainActor (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @MainActor (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) throws(Problem) {
        try self.init(restoring: saved, drivers: MainActorDrivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    public func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    @discardableResult
    public func send(_ input: Input) throws(SendRejection) -> Receipt {
        let result = host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try Flow.prepare(input, on: _stateMachineSnapshot(raw))
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
    ) throws(SubscriptionFailure) -> StateMachine.SnapshotSequence<Projection> {
        try host.sendableSnapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    /// Reads immutable retained first-outcome diagnostics.
public func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions().map(PendingCompletion.init)
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcile(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    public func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: RuntimeHostDelivery<Flow, Effect>) -> ReconcileResult {
        switch result {
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
    private static func discarded(_ result: RuntimeHostDelivery<Flow, Effect>) -> DiscardResult {
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
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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
}

/// Immutable typed execution selection for one managed owner's lifetime.
public struct Drivers: Sendable {
    /// Executes one typed operation outside admission locks.
public let fetch: @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>
    /// Executes one typed operation outside admission locks.
    public let audit: @Sendable (Audit.Input) async -> Audit.Output
    /// Selects all drivers for this owner.
    public init(fetch: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>, audit: @escaping @Sendable (Audit.Input) async -> Audit.Output) {
        self.fetch = fetch
        self.audit = audit
    }
}

/// A synchronous shared owner with managed physical execution and terminal delivery.
public final class Shared: Sendable {
    private let host: RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>
    /// How this owner settles a retained completion that cannot commit when it is delivered.
    ///
    /// The default, `.retryPure`, evaluates a completion's router and edge again after another
    /// commit wins the race, so it assumes those functions are pure. Choose
    /// `.manual(onReconciliationRequired:)` when they are not.
    ///
    /// A handler, when given, runs outside the owner's critical section each time a retained
    /// completion's status becomes `reconciliationRequired`: its completion edge or router threw,
    /// its effect plan is defective, the owner refused its admission, or an explicit
    /// `reconcile(id:)` did not commit. Settle it with `reconcile(id:)` or `discardPending(id:)`.
    public struct CompletionPolicy: Sendable {
        fileprivate let runtime: RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: @Sendable (_StateMachineLedger.Pending) -> Void
        private init(_ runtime: RuntimeCompletionPolicy, handler: @escaping @Sendable (PendingCompletion) -> Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it only when every completion edge and router is deterministic and free of side
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible only through `pendingCompletions()`.
        public static var retryPure: CompletionPolicy {
        CompletionPolicy(.retryPure, handler: { _ in
            })
    }
        /// Retries lost races as `retryPure` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retryPure(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.retryPure, handler: handler)
        }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.manualOnConflict, handler: handler)
        }
    }
    /// Creates fresh initial authority and retains the driver selection immutably.
    public init(_ initial: Idle = Flow.makeIdle(), drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) {
        host = RuntimeSharedHost(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .fetch(let input):
                    return .fetch(FetchCompletion(result: await drivers.fetch(input), authority: raw.ticket))
                case .audit(let input):
                    return .audit(AuditCompletion(value: await drivers.audit(input), authority: raw.ticket))
                }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = RuntimeSharedHost(restored.model, scopes: restored.scopes, limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .fetch(let input):
                    return .fetch(FetchCompletion(result: await drivers.fetch(input), authority: raw.ticket))
                case .audit(let input):
                    return .audit(AuditCompletion(value: await drivers.audit(input), authority: raw.ticket))
                }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    public convenience init(_ initial: Idle = Flow.makeIdle(),
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) {
        self.init(initial, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) throws(Problem) {
        try self.init(restoring: saved, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
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
        let prepared: Prepared
        do {
            prepared = try Flow.prepare(input, on: snapshot())
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
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcile(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    public func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>.Delivery) -> ReconcileResult {
        switch result {
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
    private static func discarded(_ result: RuntimeSharedHost<Flow, Effect, Completion, PreparationRejection>.Delivery) -> DiscardResult {
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
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    public var runningCount: Int {
        get async {
            await host.runningCount
        }
    }
    /// Live observer registrations.
    public var subscriberCount: Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    public var isQuiescent: Bool {
        host.isQuiescent
    }
}

/// A sealed sole-writer native actor owner with managed execution.
public final class ActorHost: Sendable {
    private typealias Host = RuntimeActorHost<Flow, Effect, Completion, PreparationRejection>
    private let host: Host
    /// How this owner settles a retained completion that cannot commit when it is delivered.
    ///
    /// The default, `.retryPure`, evaluates a completion's router and edge again after another
    /// commit wins the race, so it assumes those functions are pure. Choose
    /// `.manual(onReconciliationRequired:)` when they are not.
    ///
    /// A handler, when given, runs outside the owner's critical section each time a retained
    /// completion's status becomes `reconciliationRequired`: its completion edge or router threw,
    /// its effect plan is defective, the owner refused its admission, or an explicit
    /// `reconcile(id:)` did not commit. Settle it with `reconcile(id:)` or `discardPending(id:)`.
    public struct CompletionPolicy: Sendable {
        fileprivate let runtime: RuntimeCompletionPolicy
        fileprivate let reconciliationRequired: @Sendable (_StateMachineLedger.Pending) -> Void
        private init(_ runtime: RuntimeCompletionPolicy, handler: @escaping @Sendable (PendingCompletion) -> Void) {
            self.runtime = runtime
            reconciliationRequired = {
            handler(PendingCompletion($0))
        }
        }
        /// Prepares a completion again against the current state when another commit wins the race,
        /// at most four times per turn before yielding to other work, and notifies no one.
        ///
        /// Choose it only when every completion edge and router is deterministic and free of side
        /// effects; the compiler does not check that. A completion retained for any other reason
        /// stays visible only through `pendingCompletions()`.
        public static var retryPure: CompletionPolicy {
        CompletionPolicy(.retryPure, handler: { _ in
            })
    }
        /// Retries lost races as `retryPure` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        public static func retryPure(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.retryPure, handler: handler)
        }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        public static func manual(onReconciliationRequired handler: @escaping @Sendable (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.manualOnConflict, handler: handler)
        }
    }
    /// Creates fresh authority and immutable execution selections.
    public init(_ initial: Idle = Flow.makeIdle(), drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) {
        host = Host(.idle(initial), scopes: [RuntimeScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .fetch(let input):
                    return .fetch(FetchCompletion(result: await drivers.fetch(input), authority: raw.ticket))
                case .audit(let input):
                    return .audit(AuditCompletion(value: await drivers.audit(input), authority: raw.ticket))
                }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh authority at revision zero in the phase `restore` validates from saved data.
    public init(restoring saved: Int, drivers: Drivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) throws(Problem) {
        let restored = try _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .fetch(let input):
                    return .fetch(FetchCompletion(result: await drivers.fetch(input), authority: raw.ticket))
                case .audit(let input):
                    return .audit(AuditCompletion(value: await drivers.audit(input), authority: raw.ticket))
                }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                outcome.authority
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            },
            reconciliationRequired: completionPolicy.reconciliationRequired)
    }
    /// Creates fresh initial authority, selecting one driver closure per operation.
    public convenience init(_ initial: Idle = Flow.makeIdle(),
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) {
        self.init(initial, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    public convenience init(restoring saved: Int,
        fetchDriver: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
        auditDriver: @escaping @Sendable (Audit.Input) async -> Audit.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) throws(Problem) {
        try self.init(restoring: saved, drivers: Drivers(fetch: fetchDriver, audit: auditDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    public func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    @discardableResult
    public func send(_ input: Input) async throws(SendRejection) -> Receipt {
        let result = await host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try Flow.prepare(input, on: _stateMachineSnapshot(raw))
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

    /// Reads immutable retained first-outcome diagnostics.
public func pendingCompletions() async -> [PendingCompletion] {
        await host.pendingCompletions().map(PendingCompletion.init)
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    public func reconcile(id: PendingCompletionID) async -> ReconcileResult {
        Self.reconciled(await host.reconcile(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    public func discardPending(id: PendingCompletionID) async -> DiscardResult {
        Self.discarded(await host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: RuntimeHostDelivery<Flow, Effect>) -> ReconcileResult {
        switch result {
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
    private static func discarded(_ result: RuntimeHostDelivery<Flow, Effect>) -> DiscardResult {
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
    /// Waits until cancellation and launch decisions through this owner's receipt have been processed.
public func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles.
    ///
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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
}
