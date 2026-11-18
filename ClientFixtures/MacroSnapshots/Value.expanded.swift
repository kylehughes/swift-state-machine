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
    let _: _TransitionReturnsDeclaredResult<Done> = _TransitionReturnsDeclaredResult<Done>()
    let _: _TriggerPayloadMatchesDeclaration<Int> = _TriggerPayloadMatchesDeclaration<Int>()


    let _ = _EffectIsCopyable<Effect>()
    let _ = _SharedModeRequiresSendable<Input>();
    let _ = _SharedModeRequiresSendable<Effect>()
}

/// Inert descriptions of the operations this workflow can start.
internal enum Effect: Sendable {


}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Copyable & Sendable>: ~Copyable, Sendable {
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
    /// Advances through the authored edge, which starts no operation.
internal consuming func finish(_ input: Int) -> Owned<Done> where Phase == Idle {
    Owned<Done>(Counter.finish(phase, input))
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Idle = Counter.Idle()) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = RuntimeState<Counter, Effect>

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

/// A single-pass latest-value sequence of an owner's snapshots.
internal typealias Snapshots = StateMachine.SnapshotSequence<Snapshot>

/// Why an owner refused a prepared candidate, in precedence order.
internal typealias CommitRejection = StateMachine.CommitRejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase: Sendable>: Sendable, CustomStringConvertible {
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
internal func finish(_ input: Int) -> Prepared where Phase == Idle {
    let next: Done = Counter.finish(payload, input)
    return _stateMachinePrepare(on: record, next: .done(next),
        effects: [],
        from: 0, to: 1, invalidates: [],
        requiring: nil, claim: claim)
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: Sendable, StateMachineSnapshot, CustomStringConvertible {
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
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: String {
        switch self {
        case .idle(let value):
            return "idle, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .done(let value):
            return "done, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
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
///
/// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
/// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
/// another owner's or the owner is closed, which it reports first.
internal struct Prepared: ~Copyable, Sendable {
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
internal struct Receipt: Sendable, StateMachineReceipt, CustomStringConvertible {
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

fileprivate static var _stateMachineEligibility: [[Int]] {
    []
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Counter, effects: [Effect], from: Int, to: Int,
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
        let starts: [_StateMachineEngine.Start] = []

        for effect in effects {
            switch effect {
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
    case (.finish(let input), .idle(let source)):
        return source.finish(input)
    default:
        throw .invalidPhase
    }
}

/// A phase saved data can restore: one in which no operation is active, or one the
/// `@Restoration` function lists in `allows:`. A restored owner has no outstanding work.
internal enum Restoration: Sendable {
    case idle(Idle)
    case done(Done)
}

/// The obligations a managed owner still tracked when its shutdown deadline expired.
///
/// It is captured in the same observation that found the deadline expired, so it always names
/// at least one unsettled obligation. It holds no model data and no authority over the owner.
internal struct ShutdownDiagnostics: Equatable, Sendable {

    /// The owner's last accepted revision at the observation.
    internal let acceptedRevision: UInt64
    /// The revision of the last fully processed FIFO batch.
    internal let processedThrough: UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    internal let hasQueuedBatches: Bool
    /// Whether a FIFO processing turn still owns responsibility.
    internal let isDraining: Bool

    fileprivate init(_ raw: StateMachine.ShutdownDiagnostics) {
        acceptedRevision = raw.acceptedRevision
        processedThrough = raw.processedThrough
        hasQueuedBatches = raw.hasQueuedBatches
        isDraining = raw.isDraining

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
    /// The owner offered every snapshot through the receipt to its subscriptions.
    case processed
    /// The receipt was issued by a different owner, so there was nothing to wait for.
    case foreignOwner
}

/// A noncopyable manually driven owner with an embedded value engine.
internal struct Local: ~Copyable {
    fileprivate var engine: _StateMachineEngine

    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Idle = Counter.Idle(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.idle(initial), scopes: [], limits: configuration, recording: .commands)
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

            return _stateMachineAdmission(result)
        }
    }
    /// Routes, prepares and admits one input against the current root.
    @discardableResult
    internal mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
        let prepared: Prepared
        do {
            prepared = try Counter.prepare(input, on: snapshot())
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

    /// Ends admission while retaining historical read access.
    @discardableResult
    internal mutating func close() -> Receipt {
        let result = engine.close()

        return Receipt(result)
    }

}

/// A sealed sole-writer MainActor owner with managed execution.
@MainActor internal final class MainActorHost: MainActorStateMachineHost {
    private typealias Host = RuntimeMainActorHost<Counter, Effect, Never, PreparationRejection>
    private let host: Host
    /// Creates fresh authority.
    internal init(_ initial: Idle = Counter.Idle(), configuration: Configuration = .default) {
        host = Host(.idle(initial), scopes: [], configuration: configuration,
            driver: { raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Never) -> RuntimeTicket in
            },
            prepare: { attempt in
                switch attempt.outcome {
                }
            })
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
                prepared = try Counter.prepare(input, on: _stateMachineSnapshot(raw))
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
    internal func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.sendableSnapshots {
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

    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close() -> Receipt {
        Receipt(host.close())
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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

/// A synchronous shared owner with managed physical execution and terminal delivery.
internal final class Shared: Sendable {
    private let host: RuntimeSharedHost<Counter, Effect, Never, PreparationRejection>
    /// Creates fresh initial authority.
    internal init(_ initial: Idle = Counter.Idle(), configuration: Configuration = .default) {
        host = RuntimeSharedHost(.idle(initial), scopes: [], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            driver: { raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Never) -> RuntimeTicket in
            },
            prepare: { attempt in
                switch attempt.outcome {
                }
            })
    }
    /// Captures a coherent historical observation.
    internal func snapshot() -> Snapshot {
        _stateMachineSnapshot(host.snapshot())
    }
    /// Registers a serial capacity-one latest-value observation callback.
    internal func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {
        }) throws(SubscriptionFailure) -> Subscription {
        try host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots.
    ///
    /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
    internal func snapshots() throws(SubscriptionFailure) -> Snapshots {
        try host.snapshots {
            _stateMachineSnapshot($0)
        }
    }
    /// Routes, prepares and admits one input in a single attempt.
    ///
    /// Preparation runs outside the lock against one snapshot and is never repeated, so
    /// a concurrent commit surfaces as `.commit(.conflict)` for the caller to resolve.
    @discardableResult
    internal func send(_ input: Input) throws(SendRejection) -> Receipt {
        let prepared: Prepared
        do {
            prepared = try Counter.prepare(input, on: snapshot())
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

    /// Ends admission and schedules cancellation in FIFO order.
    @discardableResult
    internal func close() -> Receipt {
        Receipt(host.close())
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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

/// A sealed sole-writer native actor owner with managed execution.
internal final class ActorHost: Sendable {
    private typealias Host = RuntimeActorHost<Counter, Effect, Never, PreparationRejection>
    private let host: Host
    /// Creates fresh authority.
    internal init(_ initial: Idle = Counter.Idle(), configuration: Configuration = .default) {
        host = Host(.idle(initial), scopes: [], configuration: configuration,
            driver: { raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Never) -> RuntimeTicket in
            },
            prepare: { attempt in
                switch attempt.outcome {
                }
            })
    }
    /// Captures a complete historical observation.
    internal func snapshot() async -> Snapshot {
        _stateMachineSnapshot(await host.snapshot())
    }
    /// Routes, prepares and admits one input in a single isolated turn without suspension.
    @discardableResult
    internal func send(_ input: Input) async throws(SendRejection) -> Receipt {
        let result = await host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, SendRejection> in
            let prepared: Prepared
            do throws(PreparationRejection) {
                prepared = try Counter.prepare(input, on: _stateMachineSnapshot(raw))
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
    /// Subscribes to initial, accepted and terminal complete snapshots.
    internal func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {
        }) async throws(SubscriptionFailure) -> Subscription {
        try await host.subscribe({
                receive(_stateMachineSnapshot($0))
            }, onFinish: onFinish)
    }
    /// Registers a single-pass sequence of the latest complete snapshots.
    ///
    /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
    internal func snapshots() async throws(SubscriptionFailure) -> Snapshots {
        try await host.snapshots {
            _stateMachineSnapshot($0)
        }
    }


    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close() async -> Receipt {
        Receipt(await host.close())
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
    /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
    /// it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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
}
