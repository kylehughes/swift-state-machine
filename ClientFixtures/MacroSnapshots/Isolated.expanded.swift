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
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<Change<Saving, Effect.Save>> = _TransitionReturnsDeclaredResult<Change<Saving, Effect.Save>>()
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<Change<Draft, Effect.Edit>> = _TransitionReturnsDeclaredResult<Change<Draft, Effect.Edit>>()
    let _: _TriggerPayloadMatchesDeclaration<String> = _TriggerPayloadMatchesDeclaration<String>()
    let _: _TransitionSourceIsPhasePayload<Saving> = _TransitionSourceIsPhasePayload<Saving>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()
    let _: _TriggerPayloadMatchesDeclaration<Save.Output> = _TriggerPayloadMatchesDeclaration<Save.Output>()
    let _: _TransitionSourceIsPhasePayload<Draft> = _TransitionSourceIsPhasePayload<Draft>()
    let _: _TransitionReturnsDeclaredResult<Draft> = _TransitionReturnsDeclaredResult<Draft>()
    let _: _TriggerPayloadMatchesDeclaration<Autosave.Output> = _TriggerPayloadMatchesDeclaration<Autosave.Output>()


    let _ = _EffectIsCopyable<Effect>()

}

/// Inert descriptions of the operations this workflow can start.
internal enum Effect: ~Sendable {
    case save(Note.Save.Input)
    case autosave(Note.Autosave.Input)
    /// The operations `save` may start.
internal enum Save: ~Sendable {
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
    internal enum Edit: ~Sendable {
        case autosave(Note.Autosave.Input)
        /// The schema-wide effect this value describes.
        internal var effect: Note.Effect {
        switch self {
        case .autosave(let input):
            return .autosave(input)
        }
    }
    }
}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Copyable>: ~Copyable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
    internal borrowing func withValue<Result: ~Copyable, Failure: Error>(
        _ body: (borrowing Phase) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(phase)
    }
    /// Consumes this authority and returns its payload, so a unique resource can move on.
    internal consuming func takeValue() -> Phase {
        phase
    }
    /// Advances through the authored edge, preserving effect order.
internal consuming func save() -> Change<Owned<Saving>, Effect.Save> where Phase == Draft {
    let change = Note.save(phase)
    return Change(Owned<Saving>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func edit(_ input: String) -> Change<Owned<Draft>, Effect.Edit> where Phase == Draft {
        let change = Note.edit(phase, input)
        return Change(Owned<Draft>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func saved(_ input: Save.Output) -> Owned<Draft> where Phase == Saving {
        Owned<Draft>(Note.saved(phase, input))
    }
    /// Advances through the authored edge, which starts no operation.
    internal consuming func autosaved(_ input: Autosave.Output) -> Owned<Draft> where Phase == Draft {
        Owned<Draft>(Note.autosaved(phase, input))
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Draft) -> Owned<Draft> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = RuntimeState<Note, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = StateMachine.ManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = StateMachine.Limits

/// A live observation registration; cancelling or releasing it stops delivery.
internal typealias Subscription = StateMachine.SnapshotSubscription

/// A live MainActor observation registration; cancelling or releasing it stops delivery.
internal typealias MainActorSubscription = StateMachine.MainActorSnapshotSubscription

/// Failure to register another live observer.
internal typealias SubscriptionFailure = StateMachine.SubscriptionFailure

/// A single-pass latest-value sequence of a MainActor owner's snapshots.
internal typealias MainActorSnapshots = StateMachine.MainActorSnapshotSequence<Snapshot>

/// The disposition of a retained completion.
internal typealias PendingStatus = StateMachine.PendingStatus

/// Why an owner refused a prepared candidate, in precedence order.
internal typealias CommitRejection = StateMachine.CommitRejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase>: CustomStringConvertible {
    fileprivate let payload: Phase
    fileprivate let record: _StateMachineEngine.Snapshot
    fileprivate let claim: RuntimeDeliveryClaim?
    /// The copied historical payload.
    internal var value: Phase {
        payload
    }
    /// The owner-lifetime accepted revision.
    internal var revision: UInt64 {
        record.revision
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: String {
        "\(Phase.self), revision \(record.revision)\(record.isClosed ? ", closed" : "")"
    }
    /// Prepares the declared edge with phase authority preserved.
internal func save() -> Prepared where Phase == Draft {
    let change: Change<Saving, Effect.Save> = Note.save(payload)
    return _stateMachinePrepare(on: record, next: .saving(change.next),
        effects: change.effects.map(\.effect),
        from: 0, to: 1, invalidates: [],
        requiring: nil, claim: claim)
    }
    /// Prepares the declared edge with phase authority preserved.
    internal func edit(_ input: String) -> Prepared where Phase == Draft {
        let change: Change<Draft, Effect.Edit> = Note.edit(payload, input)
        return _stateMachinePrepare(on: record, next: .draft(change.next),
            effects: change.effects.map(\.effect),
            from: 0, to: 0, invalidates: [],
            requiring: nil, claim: claim)
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func saved(_ value: Save.Output, authority: RuntimeTicket) -> Prepared where Phase == Saving {
        let next: Draft = Note.saved(payload, value)
        return _stateMachinePrepare(on: record, next: .draft(next),
            effects: [],
            from: 1, to: 0, invalidates: [],
            requiring: authority, claim: claim)
    }
    /// Prepares the completion edge that delivery selects, with operation authority preserved.
    fileprivate func autosaved(_ value: Autosave.Output, authority: RuntimeTicket) -> Prepared where Phase == Draft {
        let next: Draft = Note.autosaved(payload, value)
        return _stateMachinePrepare(on: record, next: .draft(next),
            effects: [],
            from: 0, to: 0, invalidates: [],
            requiring: authority, claim: claim)
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: StateMachineSnapshot, CustomStringConvertible {
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
    internal var revision: UInt64 {
        record.revision
    }
    /// Whether this historical root records closure.
    internal var isClosed: Bool {
        record.isClosed
    }
    /// Ordinary model data; constructing it confers no installation authority.
    internal var model: Note {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: String {
        switch self {
        case .draft(let value):
            return "draft, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .saving(let value):
            return "saving, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .draft(let payload):
        return .draft(Observed(payload: payload, record: record, claim: claim))
    case .saving(let payload):
        return .saving(Observed(payload: payload, record: record, claim: claim))
    }
}

/// A sealed inert candidate consumed by admission.
///
/// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
/// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
/// another owner's or the owner is closed, which it reports first.
internal struct Prepared: ~Copyable {
    fileprivate let candidate: _StateMachineEngine.Proposal
    fileprivate init(_ candidate: _StateMachineEngine.Proposal) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
internal enum PreparationRejection: Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase

}

/// A historical receipt for an atomic acceptance.
internal struct Receipt: StateMachineReceipt, CustomStringConvertible {
    /// The accepted historical observation.
    internal let snapshot: Snapshot
    fileprivate init(_ record: _StateMachineEngine.Snapshot) {
        snapshot = _stateMachineSnapshot(record)
    }
    /// The owner-lifetime accepted revision.
    internal var revision: UInt64 {
        snapshot.revision
    }
    /// The accepted phase, revision, and closure, without the payload.
    internal var description: String {
        snapshot.description
    }
}

/// Why `send` did not admit an input.
internal enum SendRejection: Error {
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
internal struct SaveWork {
    /// The immutable declared input.
    internal let input: Save.Input
    fileprivate let authority: RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: Save.Output) -> SaveCompletion {
        SaveCompletion(value: value, authority: authority)
    }


}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct SaveCompletion {
    /// The value the operation produced; it cannot fail.
    internal let value: Save.Output
    fileprivate let authority: RuntimeTicket
}

/// Work issued exclusively from an accepted command batch.
internal struct AutosaveWork {
    /// The immutable declared input.
    internal let input: Autosave.Input
    fileprivate let authority: RuntimeTicket
    /// The sealed identity for acknowledging physical execution termination.
    internal var execution: ExecutionHandle {
        ExecutionHandle(authority: authority)
    }
    /// Seals a successful terminal result for this exact work.
    internal func succeeded(_ value: Autosave.Output) -> AutosaveCompletion {
        AutosaveCompletion(value: value, authority: authority)
    }
    /// Seals a successful terminal result that carries no value.
internal func succeeded() -> AutosaveCompletion {
        succeeded(())
    }

}

/// The sealed terminal result of one execution, which only its owner's `deliver` admits.
internal struct AutosaveCompletion {
    /// The value the operation produced; it cannot fail.
    internal let value: Autosave.Output
    fileprivate let authority: RuntimeTicket
}

/// Closed typed terminal outcomes for this domain.
internal enum Completion {
    case save(SaveCompletion)
    case autosave(AutosaveCompletion)
    fileprivate var authority: RuntimeTicket {
        switch self {
        case .save(let value):
            return value.authority
        case .autosave(let value):
            return value.authority
        }
    }
}

/// A sealed handle to actual execution bookkeeping.
internal struct ExecutionHandle: Equatable, Sendable {
    fileprivate let authority: RuntimeTicket
}

/// Physical termination is independent of cancellation or completion delivery.
internal enum ExecutionDisposition: Equatable, Sendable {
    case terminated, skippedBeforeStart
}

/// Whether a physical execution acknowledgment was recorded.
internal enum AcknowledgmentResult: Equatable, Sendable {
    case recorded
    case duplicate
    case foreignOwner
}

/// A closed accepted start or cancellation command.
internal enum Command {
    case cancel(ExecutionHandle)
    case save(SaveWork)
    case autosave(AutosaveWork)
}

/// One whole FIFO batch with its historical receipt.
internal struct CommandBatch {
    /// The atomic acceptance represented by this batch.
    internal let receipt: Receipt
    /// Cancellation commands followed by starts in authored effect order.
    internal let commands: [Command]
    /// Whether this is the separately reserved close batch.
    internal let terminal: Bool
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
            case .save(let input):
                return .save(SaveWork(input: input, authority: work.ticket))
            case .autosave(let input):
                return .autosave(AutosaveWork(input: input, authority: work.ticket))
            }
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Int]] {
    [[1], [0]]
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Note, effects: [Effect], from: Int, to: Int,
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
            case .save(let input):
                let _: Save.Input = input
                counts[0] += 1
                guard counts[0] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(RuntimeOperation(kind: 0, scope: RuntimeScopeID(kind: 0),
                    dependencies: [], policy: .rejectWhenActive), descriptor: effect))
            case .autosave(let input):
                let _: Autosave.Input = input
                counts[1] += 1
                guard counts[1] <= 1 else {
                    throw .invalidPlan
                }
                starts.append(.init(RuntimeOperation(kind: 1, scope: RuntimeScopeID(kind: 1),
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
                        } ?? []))))
    } catch {
        return Prepared(.defective(.init(error, preparedOn: record)))
    }
}

/// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
///
/// A plan defect is not a routing rejection: it travels inside the result, and admission reports it.
internal static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch (input, snapshot) {
    case (.save, .draft(let source)):
        return source.save()
    case (.edit(let input), .draft(let source)):
        return source.edit(input)
    default:
        throw .invalidPhase
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
    switch (completion, snapshot) {
    case (.save(let completion), .saving(let source)):
        let value: Save.Output = completion.value
        return source.saved(value, authority: completion.authority)
    case (.autosave(let completion), .draft(let source)):
        let value: Autosave.Output = completion.value
        return source.autosaved(value, authority: completion.authority)
    default:
        throw .invalidPhase
    }
}

/// A phase saved data can restore: one in which no operation is active, or one the
/// `@Restoration` function lists in `allows:`. A restored owner has no outstanding work.
internal enum Restoration {
    case draft(Draft)
}

fileprivate static func _stateMachineRestored(_ saved: Box) -> (model: Note, scopes: [RuntimeScopeID]) {
    switch Note.restore(saved) {
    case .draft(let payload):
        return (.draft(payload), [RuntimeScopeID(kind: 1)])
    }
}

fileprivate typealias _StateMachineLedger = RuntimeDeliveryLedger<Note, Effect, Completion, PreparationRejection>

/// The opaque identity of one retained terminal outcome of this schema's owners.
internal struct PendingCompletionID: Hashable, Sendable {
    fileprivate let raw: RuntimePendingID
}

/// A retained terminal outcome and its delivery diagnostics.
///
/// The outcome is an inert value: only `reconcile(id:)`, `retryAdmission(id:)`, or
/// `discardPending(id:)` can settle the retained completion it describes.
internal struct PendingCompletion {
    /// The retained terminal value of one operation.
    internal enum Outcome {
        case save(Save.Output)
        case autosave(Autosave.Output)
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
    internal let attempts: UInt64
    /// Whether the preparation count has reached its representable limit.
    internal var attemptsSaturated: Bool {
        attempts == UInt64.max
    }
    fileprivate init(_ pending: _StateMachineLedger.Pending) {
        id = PendingCompletionID(raw: pending.id)
        switch pending.outcome {
        case .save(let completion):
            outcome = .save(completion.value)
        case .autosave(let completion):
            outcome = .autosave(completion.value)
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
internal struct ShutdownDiagnostics: Equatable, Sendable {
    /// An execution and delivery obligation that remained tracked.
internal typealias OutstandingExecution = StateMachine.ShutdownDiagnostics.OutstandingExecution
    /// The owner's last accepted revision at the observation.
    internal let acceptedRevision: UInt64
    /// The revision of the last fully processed FIFO batch.
    internal let processedThrough: UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    internal let hasQueuedBatches: Bool
    /// Whether a FIFO processing turn still owns responsibility.
    internal let isDraining: Bool
    /// Whether an automatic retry of a retained completion is still scheduled.
internal let isRetrying: Bool
    /// The identities of the retained terminal outcomes.
    internal let pendingCompletions: [PendingCompletionID]
    /// The executions, deliveries, and preparations that remain tracked.
    internal let outstandingExecutions: [OutstandingExecution]
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
internal enum ShutdownResult: Equatable, Sendable {
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
internal enum FlushResult: Equatable, Sendable {
    /// Cancellation and launch decisions through the receipt have been processed.
    case processed
    /// The receipt was issued by a different owner, so there was nothing to wait for.
    case foreignOwner
}

/// A noncopyable manually driven owner with an embedded value engine.
internal struct Local: ~Copyable {
    fileprivate var engine: _StateMachineEngine
    fileprivate var ledger = _StateMachineLedger()
    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Draft, configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.draft(initial), scopes: [RuntimeScopeID(kind: 1)], limits: configuration, recording: .commands)
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
            prepared = try Note.prepare(input, on: snapshot())
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
internal mutating func drainCommands(limit: Int) -> [CommandBatch] {
    engine.drain(limit: limit).map {
        _stateMachineBatch($0)
    }
    }
    /// Records actual termination independently of cancellation and completion delivery.
    internal mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition) -> AcknowledgmentResult {
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
            return _stateMachineFinish(ledger.finish(attempt, preparation: preparation, in: &engine))
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
    /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
internal var isQuiescent: Bool {
        engine.isQuiescent
    }
}

/// Immutable operation selections whose non-Sendable values stay within MainActor.
@MainActor internal struct MainActorDrivers {
    /// Executes this operation within the selected isolation.
internal let save: @MainActor (Save.Input) async -> Save.Output
    /// Executes this operation within the selected isolation.
    internal let autosave: @MainActor (Autosave.Input) async -> Autosave.Output
    /// Selects every driver for this owner's lifetime.
    internal init(save: @escaping @MainActor (Save.Input) async -> Save.Output, autosave: @escaping @MainActor (Autosave.Input) async -> Autosave.Output) {
        self.save = save
        self.autosave = autosave
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
@MainActor internal final class MainActorHost: MainActorStateMachineHost {
    private typealias Host = RuntimeMainActorHost<Note, Effect, Completion, PreparationRejection>
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
    internal struct CompletionPolicy {
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
        internal static var retryPure: CompletionPolicy {
        CompletionPolicy(.retryPure, handler: { _ in
            })
    }
        /// Retries lost races as `retryPure` does, and passes every completion that still needs
        /// reconciliation to `handler`.
        internal static func retryPure(onReconciliationRequired handler: @escaping @MainActor (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.retryPure, handler: handler)
        }
        /// Never prepares a completion again on its own: every completion that needs reconciliation,
        /// including one whose preparation lost a race with another commit, goes to `handler`.
        internal static func manual(onReconciliationRequired handler: @escaping @MainActor (PendingCompletion) -> Void) -> CompletionPolicy {
            CompletionPolicy(.manualOnConflict, handler: handler)
        }
    }
    /// Creates fresh authority and immutable execution selections.
    internal init(_ initial: Draft, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) {
        host = Host(.draft(initial), scopes: [RuntimeScopeID(kind: 1)], configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .save(let input):
                    return .save(SaveCompletion(value: await drivers.save(input), authority: raw.ticket))
                case .autosave(let input):
                    return .autosave(AutosaveCompletion(value: await drivers.autosave(input), authority: raw.ticket))
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
    internal init(restoring saved: Box, drivers: MainActorDrivers, configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure) {
        let restored = _stateMachineRestored(saved)
        host = Host(restored.model, scopes: restored.scopes, configuration: configuration,
            policy: completionPolicy.runtime, driver: { raw in
    switch raw.descriptor {
                case .save(let input):
                    return .save(SaveCompletion(value: await drivers.save(input), authority: raw.ticket))
                case .autosave(let input):
                    return .autosave(AutosaveCompletion(value: await drivers.autosave(input), authority: raw.ticket))
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
    internal convenience init(_ initial: Draft,
        saveDriver: @escaping @MainActor (Save.Input) async -> Save.Output,
        autosaveDriver: @escaping @MainActor (Autosave.Input) async -> Autosave.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) {
        self.init(initial, drivers: MainActorDrivers(save: saveDriver, autosave: autosaveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Creates fresh authority in the phase `restore` validates from saved data, selecting one driver closure per operation.
    internal convenience init(restoring saved: Box,
        saveDriver: @escaping @MainActor (Save.Input) async -> Save.Output,
        autosaveDriver: @escaping @MainActor (Autosave.Input) async -> Autosave.Output,
        configuration: Configuration = .default,
        completionPolicy: CompletionPolicy = .retryPure) {
        self.init(restoring: saved, drivers: MainActorDrivers(save: saveDriver, autosave: autosaveDriver),
            configuration: configuration, completionPolicy: completionPolicy)
    }
    /// Captures a complete historical observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    @discardableResult
    internal func send(_ input: Input) throws(SendRejection) -> Receipt {
        let result = host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try Note.prepare(input, on: _stateMachineSnapshot(raw))
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
    /// Subscribes to initial, accepted and terminal complete snapshots.
    internal func subscribe(_ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {
        }) throws(SubscriptionFailure) -> MainActorSubscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots.
    ///
    /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
    internal func snapshots() throws(SubscriptionFailure) -> MainActorSnapshots {
        try host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered. The sequence supports every
    /// `AsyncSequence` operator on every supported OS version.
    internal func snapshots<Projection: Sendable>(
        _ transform: @escaping @MainActor (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> StateMachine.SnapshotSequence<Projection> {
        try host.sendableSnapshots {
        transform(_stateMachineSnapshot($0))
    }
    }
    /// Reads immutable retained first-outcome diagnostics.
internal func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions().map(PendingCompletion.init)
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID) -> ReconcileResult {
        Self.reconciled(host.reconcile(id: id.raw))
    }
    /// Revokes retained delivery with an authority-only admission.
    internal func discardPending(id: PendingCompletionID) -> DiscardResult {
        Self.discarded(host.discardPending(id: id.raw))
    }
    // The raw host reports only the cases each operation can produce; the rest cannot occur.
    private static func reconciled(_ result: RuntimeHostDelivery<Note, Effect>) -> ReconcileResult {
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
    private static func discarded(_ result: RuntimeHostDelivery<Note, Effect>) -> DiscardResult {
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
    internal func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
    }
    /// Actual workers whose joined termination has not yet been processed.
    internal var runningCount: Int {
        host.runningCount
    }
    /// Live observer registrations.
    internal var subscriberCount: Int {
        host.subscriberCount
    }
    /// Whether closure and all managed obligations have settled.
    internal var isQuiescent: Bool {
        host.isQuiescent
    }
}
