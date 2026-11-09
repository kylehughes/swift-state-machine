fileprivate struct _AtomicTypeWitness<Value: ~Copyable> {
}

fileprivate struct _AtomicSendableWitness<Value: Sendable> {
}

fileprivate struct _AtomicErrorWitness<Value: Error> {
}

fileprivate struct _AtomicCopyableWitness<Value> {
}

fileprivate static func _atomicWitnesses() {
    let _: _AtomicTypeWitness<Draft> = _AtomicTypeWitness<Draft>()
    let _: _AtomicTypeWitness<Change<Saving, Effect>> = _AtomicTypeWitness<Change<Saving, Effect>>()
    let _: _AtomicTypeWitness<Draft> = _AtomicTypeWitness<Draft>()
    let _: _AtomicTypeWitness<Change<Draft, Effect>> = _AtomicTypeWitness<Change<Draft, Effect>>()
    let _: _AtomicTypeWitness<String> = _AtomicTypeWitness<String>()
    let _: _AtomicTypeWitness<Saving> = _AtomicTypeWitness<Saving>()
    let _: _AtomicTypeWitness<Change<Draft, Effect>> = _AtomicTypeWitness<Change<Draft, Effect>>()
    let _: _AtomicTypeWitness<Save.Output> = _AtomicTypeWitness<Save.Output>()
    let _: _AtomicTypeWitness<Save.Input> = _AtomicTypeWitness<Save.Input>();
    let _ = _AtomicErrorWitness<Save.Failure>()

    let _ = _AtomicCopyableWitness<Effect>()

}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Copyable>: ~Copyable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource.
    internal borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result {
        body(phase)
    }
    /// Advances through the authored edge, preserving effect order.
internal consuming func save() -> Change<Owned<Saving>, Effect> where Phase == Draft {
    let change = Note.save(phase)
    return Change(Owned<Saving>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func edit(_ input: String) -> Change<Owned<Draft>, Effect> where Phase == Draft {
        let change = Note.edit(phase, input)
        return Change(Owned<Draft>(change.next), effects: change.effects)
    }
    /// Advances through the authored edge, preserving effect order.
    internal consuming func saved(_ input: Save.Output) -> Change<Owned<Draft>, Effect> where Phase == Saving {
        let change = Note.saved(phase, input)
        return Change(Owned<Draft>(change.next), effects: change.effects)
    }
}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Draft) -> Owned<Draft> {
    Owned(initial)
}

fileprivate typealias _AtomicEngine = RuntimeState<Note, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = RuntimeManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = RuntimeLimits

/// Admission rejection reasons in exact evaluation precedence.
internal typealias CommitRejection = RuntimeState<Note, Effect>.Rejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase> {
    fileprivate let payload: Phase
    fileprivate let record: _AtomicEngine.Snapshot
    fileprivate let claim: RuntimeDeliveryClaim?
    /// The copied historical payload.
    internal var value: Phase {
        payload
    }
    /// The owner-lifetime accepted ordinal.
    internal var ordinal: UInt64 {
        record.ordinal
    }
    /// Prepares the declared edge with phase and operation authority preserved.
internal func save() throws(PreparationFailure<Never>) -> Prepared where Phase == Draft {
    let change: Change<Saving, Effect>
    change = Note.save(payload)
    do {
    let candidate = try _atomicPrepare(on: record, next: .saving(change.next), effects: change.effects,
        from: 0, to: 1, invalidates: [],
        allowed: [0], requiring: nil, claim: claim)
    return Prepared(candidate)
    } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    internal func edit(_ input: String) throws(PreparationFailure<Never>) -> Prepared where Phase == Draft {
        let change: Change<Draft, Effect>
        change = Note.edit(payload, input)
        do {
        let candidate = try _atomicPrepare(on: record, next: .draft(change.next), effects: change.effects,
            from: 0, to: 0, invalidates: [],
            allowed: [], requiring: nil, claim: claim)
        return Prepared(candidate)
    } catch {
        throw .plan(error)
    }
    }
    /// Prepares the declared edge with phase and operation authority preserved.
    internal func saved(_ completion: SaveSuccessCompletion) throws(PreparationFailure<Never>) -> Prepared where Phase == Saving {
        let change: Change<Draft, Effect>
        change = Note.saved(payload, completion.value)
        do {
        let candidate = try _atomicPrepare(on: record, next: .draft(change.next), effects: change.effects,
            from: 1, to: 0, invalidates: [],
            allowed: [], requiring: completion.authority, claim: claim)
        return Prepared(candidate)
    } catch {
        throw .plan(error)
    }
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot {
    case draft(Observed<Draft>)
    case saving(Observed<Saving>)
    fileprivate var record: _AtomicEngine.Snapshot {
        switch self {
        case .draft(let value):
            return value.record
        case .saving(let value):
            return value.record
        }
    }
    /// The accepted ordinal of this observation.
    internal var ordinal: UInt64 {
        record.ordinal
    }
    /// Whether this historical root records closure.
    internal var isClosed: Bool {
        record.isClosed
    }
    /// Ordinary model data; constructing it confers no installation authority.
    internal var model: Note {
        record.model
    }
}

fileprivate static func _atomicSnapshot(_ record: _AtomicEngine.Snapshot, claim: RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .draft(let payload):
        return .draft(Observed(payload: payload, record: record, claim: claim))
    case .saving(let payload):
        return .saving(Observed(payload: payload, record: record, claim: claim))
    }
}

/// A sealed inert candidate consumed by admission.
internal struct Prepared: ~Copyable {
    fileprivate let candidate: _AtomicEngine.Candidate
    fileprivate init(_ candidate: _AtomicEngine.Candidate) {
        self.candidate = candidate
    }
}

/// A closed typed dynamic routing rejection.
internal enum PreparationRejection: Error {
    /// The input or outcome has no edge from the observed phase.
    case invalidPhase
    /// Actual emitted effects violate metadata or immutable limits.
    case plan(PlanRejection)

}

/// A prepared candidate or typed routing rejection.
internal enum PreparationResult: ~Copyable {
    case prepared(Prepared)
    case rejected(PreparationRejection)
}

/// A historical receipt for an atomic acceptance.
internal struct Receipt {
    /// The accepted historical observation.
    internal let snapshot: Snapshot
    fileprivate init(_ record: _AtomicEngine.Snapshot) {
        snapshot = _atomicSnapshot(record)
    }
    /// The owner-lifetime accepted ordinal.
    internal var ordinal: UInt64 {
        snapshot.ordinal
    }
}

/// Admission either publishes the entire candidate or leaves all state unchanged.
internal enum CommitResult {
    case committed(Receipt)
    case rejected(CommitRejection, current: Snapshot)
}

fileprivate static func _atomicAdmission(_ result: _AtomicEngine.Admission) -> CommitResult {
    switch result {
    case .committed(let record):
        return .committed(Receipt(record))
    case .rejected(let reason, let current):
        return .rejected(reason, current: _atomicSnapshot(current))
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
        .success(SaveSuccessCompletion(value: value, authority: authority))
    }
    /// Seals a failed terminal result for this exact work.
    internal func failed(_ value: Save.Failure) -> SaveCompletion {

    }
}

/// A sealed successful terminal result for one declared operation.
internal struct SaveSuccessCompletion {
    /// The typed successful value.
    internal let value: Save.Output
    fileprivate let authority: RuntimeTicket
}

/// A sealed failed terminal result for one declared operation.
internal struct SaveFailureCompletion {
    /// The typed failure value.
    internal let value: Save.Failure
    fileprivate let authority: RuntimeTicket
}

/// The closed terminal vocabulary for this operation.
internal enum SaveCompletion {
    case success(SaveSuccessCompletion)
    case failure(SaveFailureCompletion)
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
internal enum Completion {
    case save(SaveCompletion)
    fileprivate var authority: RuntimeTicket {
        switch self {
        case .save(let value):
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
    case unknownExecution
}

/// A closed accepted start or cancellation command.
internal enum Command {
    case cancel(ExecutionHandle)
    case save(SaveWork)
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

fileprivate static func _atomicBatch(_ batch: _AtomicEngine.Batch) -> CommandBatch {
    let commands = batch.commands.map { command -> Command in
        switch command {
        case .cancel(let ticket):
            return .cancel(ExecutionHandle(authority: ticket))
        case .start(let work):
            switch work.descriptor {
            case .save(let input):
                return .save(SaveWork(input: input, authority: work.ticket))
            }
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _atomicEligibility: [[Int]] {
    [[1]]
}

fileprivate static func _atomicPrepare(
    on record: _AtomicEngine.Snapshot, next: Note, effects: [Effect], from: Int, to: Int,
    invalidates: [Int], allowed: [Int], requiring ticket: RuntimeTicket?, claim: RuntimeDeliveryClaim?
) throws(PlanRejection) -> _AtomicEngine.Candidate {
    var edits: [_AtomicEngine.ScopeEdit] = []
    for (scope, phases) in _atomicEligibility.enumerated() {
        let before = phases.contains(from)
        let after = phases.contains(to)
        if after && (!before || invalidates.contains(scope)) {
            edits.append(.activate(RuntimeScopeID(kind: UInt32(scope))))
        }
        else if before && !after {
            edits.append(.remove(RuntimeScopeID(kind: UInt32(scope))))
        }
    }
    var starts: [_AtomicEngine.Start] = []
    var counts = Array(repeating: 0, count: 1)
    for effect in effects {
        switch effect {
        case .save(let input):
            let _: Save.Input = input
            guard allowed.contains(0) else {
                throw .invalidPlan
            }
            counts[0] += 1
            guard counts[0] <= 1 else {
                throw .invalidPlan
            }
            starts.append(.init(RuntimeOperation(kind: 0, scope: RuntimeScopeID(kind: 0),
                dependencies: [], policy: .rejectWhenActive), descriptor: effect))
        }
    }
    return try _AtomicEngine.prepare(on: record, next: next, requiring: ticket.map {
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
internal static func prepare(_ input: Input, on snapshot: Snapshot) -> PreparationResult {
    switch (input, snapshot) {
    case (.save, .draft(let source)):
        do {
            return .prepared(try source.save())
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
    case (.edit(let input), .draft(let source)):
        do {
            return .prepared(try source.edit(input))
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
    case (.save, .saving):
        return .rejected(.invalidPhase)
    case (.edit, .saving):
        return .rejected(.invalidPhase)
    }
}

fileprivate static func _atomicCompletion(_ completion: Completion, on snapshot: Snapshot) -> PreparationResult {
    switch (completion, snapshot) {
    case (.save(.success), .draft):
        return .rejected(.invalidPhase)
    case (.save(.failure), .draft):
        return .rejected(.invalidPhase)
    case (.save(.success(let completion)), .saving(let source)):
        do {
            return .prepared(try source.saved(completion))
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
    case (.save(.failure), .saving):
        return .rejected(.invalidPhase)
    }
}

fileprivate typealias _AtomicLedger = RuntimeDeliveryLedger<Note, Effect, Completion, PreparationRejection>

/// The opaque identity of a first retained terminal envelope.
internal typealias PendingCompletionID = RuntimePendingID

/// Typed historical diagnostics for a retained completion.
internal typealias PendingCompletion = RuntimeDeliveryLedger<Note, Effect, Completion, PreparationRejection>.Pending

/// A closed completion delivery decision.
internal enum DeliveryResult {
    case committed(Receipt)
    case pending(PendingCompletionID, RuntimePendingStatus)
    case inProgress
    case notPending
    case stale
    case discarded(Receipt)
    case rejected(CommitRejection)
}

fileprivate static func _atomicFinish(_ result: _AtomicLedger.Finish) -> DeliveryResult {
    switch result {
    case .committed(let record):
        return .committed(Receipt(record))
    case .pending(let id, let status):
        return .pending(id, status)
    case .notPending:
        return .notPending
    }
}

fileprivate static func _atomicDeliveryPreparation(_ attempt: _AtomicLedger.Attempt) -> _AtomicLedger.Preparation {
    switch _atomicCompletion(attempt.outcome, on: _atomicSnapshot(attempt.snapshot, claim: attempt.claim)) {
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
internal struct Local: ~Copyable {
    fileprivate var engine: _AtomicEngine
    fileprivate var ledger = _AtomicLedger()
    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Draft, configuration: LocalConfiguration = .default) {
        engine = _AtomicEngine(.draft(initial), scopes: [], limits: configuration)
    }
    /// Returns an immutable historical observation.
    internal borrowing func snapshot() -> Snapshot {
        _atomicSnapshot(engine.snapshot)
    }
    /// Consumes and atomically accepts or rejects a complete candidate.
    internal mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
        let result = engine.commit(prepared.candidate)
        ledger.prune(in: engine)
        return _atomicAdmission(result)
    }
    /// Transfers whole FIFO batches; physical execution occurs after mutating access ends.
    internal mutating func drainCommands(limit: Int) -> [CommandBatch] {
        let batches = engine.drain(limit: limit).map {
            _atomicBatch($0)
        }
        _ = ledger.retryCapacity(in: &engine)
        return batches
    }
    /// Records actual termination independently of cancellation and completion delivery.
    internal mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition) -> AcknowledgmentResult {
        let result = engine.acknowledge(execution.authority, skippedBeforeStart: disposition == .skippedBeforeStart)
        _ = ledger.retryCapacity(in: &engine)
        switch result {
        case .recorded:
            return .recorded
        case .duplicate:
            return .duplicate
        case .foreignOwner:
            return .foreignOwner
        @unknown default:
            return .unknownExecution
        }
    }
    /// Retains the first outcome and attempts one typed preparation against the current root.
    internal mutating func deliver(_ completion: Completion) -> DeliveryResult {
        switch ledger.retain(completion, for: completion.authority, in: &engine) {
        case .stale:
            return .stale
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
    /// Claims one retained outcome before evaluating domain code.
    internal mutating func reconcile(id: PendingCompletionID) -> DeliveryResult {
        switch ledger.claim(id, in: &engine) {
        case .inProgress:
            return .inProgress
        case .notPending:
            return .notPending
        case .claimed(let attempt):
            let preparation = _atomicDeliveryPreparation(attempt)
            return _atomicFinish(ledger.finish(attempt, preparation: preparation, in: &engine))
        }
    }
    /// Queries immutable first-outcome records without claiming preparation.
    internal borrowing func pendingCompletions() -> [PendingCompletion] {
        ledger.pending
    }
    /// Revokes one retained operation using an atomic authority-only commit.
    internal mutating func discardPending(id: PendingCompletionID) -> DeliveryResult {
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
internal let save: @MainActor (Save.Input) async -> Result<Save.Output, Save.Failure>
    /// Selects every driver for this owner's lifetime.
    internal init(save: @escaping @MainActor (Save.Input) async -> Result<Save.Output, Save.Failure>) {
        self.save = save
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
@MainActor internal final class MainActorHost {
    private typealias Host = RuntimeMainActorHost<Note, Effect, Completion, PreparationRejection>
    private let host: Host
    /// Creates fresh authority and immutable execution selections.
    internal init(_ initial: Draft, drivers: MainActorDrivers, configuration: Configuration = .default,
        completionPolicy: RuntimeCompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @MainActor (PendingCompletion) -> Void = { _ in
        }) {
        host = Host(.draft(initial), scopes: [], configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            case .save(let input):
                                let work = SaveWork(input: input, authority: raw.ticket)
                                switch await drivers.save(input) {
                                case .success(let value):
                    return .save(work.succeeded(value))
                                case .failure(let value):
                    switch value {
                    }
                                }
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
                return outcome.authority
            },
            prepare: {
                _atomicDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Captures a complete historical observation.
    internal func snapshot() -> Snapshot {
        _atomicSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    internal func send(_ input: Input) throws(PreparationRejection) -> CommitResult {
        let result = host.prepareAndCommit { raw -> Result<_AtomicEngine.Candidate, PreparationRejection> in
            switch Note.prepare(input, on: _atomicSnapshot(raw)) {
            case .prepared(let prepared):
                return .success(prepared.candidate)
            case .rejected(let reason):
                return .failure(reason)
            }
        }
        switch result {
        case .success(let admission):
            return _atomicAdmission(admission)
        case .failure(let reason):
            throw reason
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    internal func commit(_ prepared: consuming Prepared) -> CommitResult {
        let candidate = prepared.candidate
        return _atomicAdmission(host.commit(candidate))
    }
    /// Subscribes to initial, accepted and terminal complete snapshots.
    internal func subscribe(_ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {
        }) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription {
        try host.subscribe({
                receive(_atomicSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Retains the first terminal outcome and validates current authority.
    internal func deliver(_ completion: Completion) -> DeliveryResult {
        return Self.project(host.deliver(completion))
    }
    /// Reads immutable retained first-outcome diagnostics.
    internal func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions()
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.reconcile(id: id))
    }
    /// Revokes retained delivery with an authority-only admission.
    internal func discardPending(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.discardPending(id: id))
    }
    /// Closes admission while preserving historical model data.
    internal func close() -> Receipt {
        Receipt(host.close())
    }
    /// Waits for cancellation and launch decisions through this owner-bound receipt.
    internal func flush(through receipt: Receipt) async -> Bool {
        await host.flush(through: receipt.snapshot.record)
    }
    /// Closes and joins actual execution and retained delivery obligations.
    internal func shutdown() async {
        await host.shutdown()
    }
    /// Closes and waits for settlement through an optional deadline.
    internal func shutdownAndWait(deadline: ContinuousClock.Instant? = nil) async -> Bool {
        await host.shutdownAndWait(deadline: deadline)
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
    private static func project(_ result: RuntimeHostDelivery<Note, Effect>) -> DeliveryResult {
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
        case .discarded(let record):
            return .discarded(Receipt(record))
        case .rejected(let reason):
            return .rejected(reason)
        }
    }
}
