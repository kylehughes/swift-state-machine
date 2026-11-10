fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Copyable> {
}

fileprivate struct _EffectPayloadIsOperationInput<Value: ~Copyable> {
}

fileprivate struct _RouterSourceIsObservedPhase<Value: ~Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Sendable> {
}

fileprivate struct _OperationFailureIsError<Value: Error> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

fileprivate static func _stateMachineWitnesses() {
    let _: _TransitionSourceIsPhasePayload<Idle> = _TransitionSourceIsPhasePayload<Idle>()
    let _: _TransitionReturnsDeclaredResult<Change<Done, Effect>> = _TransitionReturnsDeclaredResult<Change<Done, Effect>>()
    let _: _TriggerPayloadMatchesDeclaration<Int> = _TriggerPayloadMatchesDeclaration<Int>()


    let _ = _EffectIsCopyable<Effect>()
    let _ = _SharedModeRequiresSendable<Input>();
    let _ = _SharedModeRequiresSendable<Effect>()
}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Copyable & Sendable>: ~Copyable, Sendable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource.
    internal borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result {
        body(phase)
    }
    /// Advances through the authored edge, preserving effect order.
internal consuming func finish(_ input: Int) -> Change<Owned<Done>, Effect> where Phase == Idle {
    let change = Counter.finish(phase, input)
    return Change(Owned<Done>(change.next), effects: change.effects)
    }
}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Idle) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = RuntimeState<Counter, Effect>

/// Validated bounds for managed admission and serial subscriptions.
internal typealias Configuration = RuntimeManagedConfiguration

/// Admission bounds for a manual local owner, with no subscriptions or runner policy.
internal typealias LocalConfiguration = RuntimeLimits

/// Admission rejection reasons in exact evaluation precedence.
internal typealias CommitRejection = RuntimeState<Counter, Effect>.Rejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase: Sendable>: Sendable {
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
    /// Prepares the declared edge with phase and operation authority preserved.
internal func finish(_ input: Int) throws(PreparationFailure<Never>) -> Prepared where Phase == Idle {
    let change: Change<Done, Effect>
    change = Counter.finish(payload, input)
    do {
    let candidate = try _stateMachinePrepare(on: record, next: .done(change.next), effects: change.effects,
        from: 0, to: 1, invalidates: [],
        allowed: [], requiring: nil, claim: claim)
    return Prepared(candidate)
    } catch {
        throw .plan(error)
    }
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: Sendable {
    case idle(Observed<Idle>)
    case done(Observed<Done>)
    fileprivate var record: _StateMachineEngine.Snapshot {
        switch self {
        case .idle(let value):
            return value.record
        case .done(let value):
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
    internal var model: Counter {
        record.model
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .idle(let payload):
        return .idle(Observed(payload: payload, record: record, claim: claim))
    case .done(let payload):
        return .done(Observed(payload: payload, record: record, claim: claim))
    }
}

/// A sealed inert candidate consumed by admission.
internal struct Prepared: ~Copyable, Sendable {
    fileprivate let candidate: _StateMachineEngine.Candidate
    fileprivate init(_ candidate: _StateMachineEngine.Candidate) {
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
internal enum PreparationResult: ~Copyable, Sendable {
    case prepared(Prepared)
    case rejected(PreparationRejection)
}

/// A historical receipt for an atomic acceptance.
internal struct Receipt: Sendable {
    /// The accepted historical observation.
    internal let snapshot: Snapshot
    fileprivate init(_ record: _StateMachineEngine.Snapshot) {
        snapshot = _stateMachineSnapshot(record)
    }
    /// The owner-lifetime accepted revision.
    internal var revision: UInt64 {
        snapshot.revision
    }
}

/// Admission either publishes the entire candidate or leaves all state unchanged.
internal enum CommitResult: Sendable {
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

/// Closed typed terminal outcomes for this domain.
internal enum Completion: Sendable {

    fileprivate var authority: RuntimeTicket {
        switch self {
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
internal enum Command: Sendable {
    case cancel(ExecutionHandle)

}

/// One whole FIFO batch with its historical receipt.
internal struct CommandBatch: Sendable {
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
            }
        }
    }
    return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
}

fileprivate static var _stateMachineEligibility: [[Int]] {
    []
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Counter, effects: [Effect], from: Int, to: Int,
    invalidates: [Int], allowed: [Int], requiring ticket: RuntimeTicket?, claim: RuntimeDeliveryClaim?
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
    let starts: [_StateMachineEngine.Start] = []

    for effect in effects {
        switch effect {
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
internal static func prepare(_ input: Input, on snapshot: Snapshot) -> PreparationResult {
    switch (input, snapshot) {
    case (.finish(let input), .idle(let source)):
        do {
            return .prepared(try source.finish(input))
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
    case (.finish, .done):
        return .rejected(.invalidPhase)
    }
}

fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) -> PreparationResult {

}

fileprivate typealias _StateMachineLedger = RuntimeDeliveryLedger<Counter, Effect, Completion, PreparationRejection>

/// The opaque identity of a first retained terminal envelope.
internal typealias PendingCompletionID = RuntimePendingID

/// Typed historical diagnostics for a retained completion.
internal typealias PendingCompletion = RuntimeDeliveryLedger<Counter, Effect, Completion, PreparationRejection>.Pending

/// A closed completion delivery decision.
internal enum DeliveryResult: Sendable {
    case committed(Receipt)
    case pending(PendingCompletionID, RuntimePendingStatus)
    case inProgress
    case notPending
    case stale
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
    return .failure(.domain(.invalidPhase))
}

/// A noncopyable manually driven owner with an embedded value engine.
internal struct Local: ~Copyable {
    fileprivate var engine: _StateMachineEngine
    fileprivate var ledger = _StateMachineLedger()
    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Idle, configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.idle(initial), scopes: [], limits: configuration)
    }
    /// Returns an immutable historical observation.
    internal borrowing func snapshot() -> Snapshot {
        _stateMachineSnapshot(engine.snapshot)
    }
    /// Consumes and atomically accepts or rejects a complete candidate.
    internal mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
        let result = engine.commit(prepared.candidate)
        ledger.prune(in: engine)
        return _stateMachineAdmission(result)
    }
    /// Transfers whole FIFO batches; physical execution occurs after mutating access ends.
    internal mutating func drainCommands(limit: Int) -> [CommandBatch] {
        let batches = engine.drain(limit: limit).map {
            _stateMachineBatch($0)
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

    }
    /// Claims one retained outcome before evaluating domain code.
    internal mutating func reconcile(id: PendingCompletionID) -> DeliveryResult {
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

    /// Selects every driver for this owner's lifetime.
    internal init() {
    }
}

/// A sealed sole-writer MainActor owner with managed execution.
@MainActor internal final class MainActorHost {
    private typealias Host = RuntimeMainActorHost<Counter, Effect, Completion, PreparationRejection>
    private let host: Host
    /// Creates fresh authority and immutable execution selections.
    internal init(_ initial: Idle, drivers: MainActorDrivers, configuration: Configuration = .default,
        completionPolicy: RuntimeCompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @MainActor (PendingCompletion) -> Void = { _ in
        }) {
        host = Host(.idle(initial), scopes: [], configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Captures a complete historical observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    internal func send(_ input: Input) throws(PreparationRejection) -> CommitResult {
        let result = host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, PreparationRejection> in
            switch Counter.prepare(input, on: _stateMachineSnapshot(raw)) {
            case .prepared(let prepared):
                return .success(prepared.candidate)
            case .rejected(let reason):
                return .failure(reason)
            }
        }
        switch result {
        case .success(let admission):
            return _stateMachineAdmission(admission)
        case .failure(let reason):
            throw reason
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    internal func commit(_ prepared: consuming Prepared) -> CommitResult {
        let candidate = prepared.candidate
        return _stateMachineAdmission(host.commit(candidate))
    }
    /// Subscribes to initial, accepted and terminal complete snapshots.
    internal func subscribe(_ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {
        }) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Retains the first terminal outcome and validates current authority.
    internal func deliver(_ completion: Completion) -> DeliveryResult {
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
    private static func project(_ result: RuntimeHostDelivery<Counter, Effect>) -> DeliveryResult {
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

/// Immutable typed execution selection for one managed owner's lifetime.
internal struct Drivers: Sendable {

    /// Selects all drivers for this owner.
    internal init() {
    }
}

/// A synchronous shared owner with managed physical execution and terminal delivery.
internal final class Shared: Sendable {
    private let host: RuntimeSharedHost<Counter, Effect, Completion, PreparationRejection>
    /// Creates fresh initial authority and retains the driver selection immutably.
    internal init(_ initial: Idle, drivers: Drivers, configuration: Configuration = .default,
        completionPolicy: RuntimeCompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) {
        host = RuntimeSharedHost(.idle(initial), scopes: [], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
            }, prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Captures a coherent historical observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Registers a serial capacity-one latest-value observation callback.
    internal func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {
        }) throws(RuntimeSharedHost<Counter, Effect, Completion, PreparationRejection>.SubscriptionFailure) -> RuntimeSubscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Consumes one candidate into an atomic admission attempt.
    internal func commit(_ prepared: consuming Prepared) -> CommitResult {
        _stateMachineAdmission(host.commit(prepared.candidate))
    }
    /// Retains and attempts delivery of the first typed terminal outcome.
    internal func deliver(_ completion: Completion) -> DeliveryResult {
    }
    /// Returns immutable first-outcome diagnostics.
    internal func pendingCompletions() -> [PendingCompletion] {
        host.pendingCompletions()
    }
    /// Claims one fresh preparation for a retained outcome.
    internal func reconcile(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.reconcile(id: id))
    }
    /// Revokes one retained operation by an authority-only commit.
    internal func discardPending(id: PendingCompletionID) -> DeliveryResult {
        Self.project(host.discardPending(id: id))
    }
    /// Ends admission and schedules cancellation in FIFO order.
    internal func close() -> Receipt {
        Receipt(host.close())
    }
    /// Waits until cancellation and launch decisions through this receipt have been processed.
    internal func flush(through receipt: Receipt) async -> Bool {
        await host.flush(through: receipt.snapshot.record)
    }
    /// Closes and waits for actual execution termination and retained obligation settlement.
    internal func shutdown() async {
        await host.shutdown()
    }
    /// Whether closure and all managed obligations have settled.
    internal var isQuiescent: Bool {
        host.isQuiescent
    }
    private static func project(_ result: RuntimeSharedHost<Counter, Effect, Completion, PreparationRejection>.Delivery) -> DeliveryResult {
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

/// A sealed sole-writer native actor owner with managed execution.
internal final class ActorHost: Sendable {
    private typealias Host = RuntimeActorHost<Counter, Effect, Completion, PreparationRejection>
    private let host: Host
    /// Creates fresh authority and immutable execution selections.
    internal init(_ initial: Idle, drivers: Drivers, configuration: Configuration = .default,
        completionPolicy: RuntimeCompletionPolicy = .manualOnConflict,
        onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in
        }) {
        host = Host(.idle(initial), scopes: [], configuration: configuration,
            policy: completionPolicy, driver: { raw in
                switch raw.descriptor {
                            }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in
            },
            prepare: {
                _stateMachineDeliveryPreparation($0)
            }, reconciliationRequired: onReconciliationRequired)
    }
    /// Captures a complete historical observation.
    internal func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    internal func send(_ input: Input) async throws(PreparationRejection) -> CommitResult {
        let result = await host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, PreparationRejection> in
            switch Counter.prepare(input, on: _stateMachineSnapshot(raw)) {
            case .prepared(let prepared):
                return .success(prepared.candidate)
            case .rejected(let reason):
                return .failure(reason)
            }
        }
        switch result {
        case .success(let admission):
            return _stateMachineAdmission(admission)
        case .failure(let reason):
            throw reason
        }
    }
    /// Consumes an explicitly prepared historical candidate, rechecking freshness.
    internal func commit(_ prepared: consuming Prepared) async -> CommitResult {
        let candidate = prepared.candidate
        return _stateMachineAdmission(await host.commit(candidate))
    }
    /// Subscribes to initial, accepted and terminal complete snapshots.
    internal func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {
        }) async throws(RuntimeHostSubscriptionFailure) -> RuntimeSubscription {
        try await host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Retains the first terminal outcome and validates current authority.
    internal func deliver(_ completion: Completion) async -> DeliveryResult {
    }
    /// Reads immutable retained first-outcome diagnostics.
    internal func pendingCompletions() async -> [PendingCompletion] {
        await host.pendingCompletions()
    }
    /// Explicitly claims a fresh preparation attempt for a retained outcome.
    internal func reconcile(id: PendingCompletionID) async -> DeliveryResult {
        Self.project(await host.reconcile(id: id))
    }
    /// Revokes retained delivery with an authority-only admission.
    internal func discardPending(id: PendingCompletionID) async -> DeliveryResult {
        Self.project(await host.discardPending(id: id))
    }
    /// Closes admission while preserving historical model data.
    internal func close() async -> Receipt {
        Receipt(await host.close())
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
        get async {
            await host.runningCount
        }
    }
    /// Live observer registrations.
    internal var subscriberCount: Int {
        get async {
            await host.subscriberCount
        }
    }
    /// Whether closure and all managed obligations have settled.
    internal var isQuiescent: Bool {
        get async {
            await host.isQuiescent
        }
    }
    private static func project(_ result: RuntimeHostDelivery<Counter, Effect>) -> DeliveryResult {
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
