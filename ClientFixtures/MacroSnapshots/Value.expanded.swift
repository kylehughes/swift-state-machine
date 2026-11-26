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
internal typealias _StateMachineSchema = Counter

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'Counter' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'Counter'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> _TriggerPayloadMatchesDeclaration<Value> {
    _TriggerPayloadMatchesDeclaration<Value>()
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    let _: _TransitionSourceIsPhasePayload<Idle> = _TransitionSourceIsPhasePayload<Idle>()
    let _: _TransitionReturnsDeclaredResult<Done> = _TransitionReturnsDeclaredResult<Done>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .finish(let bound):
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
internal enum Effect: Swift::Sendable {


}

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
    /// Advances through the authored edge, which starts no operation.
internal consuming func finish(_ input: Int) -> Owned<Done> where Phase == Idle {
    Owned<Done>(_StateMachineSchema.finish(phase, input))
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Idle = _StateMachineSchema.Idle()) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineEngine = StateMachine::RuntimeState<Counter, Effect>

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

/// Why an owner refused a prepared candidate, in precedence order.
internal typealias CommitRejection = StateMachine::CommitRejection

/// An immutable historical payload with sealed complete-root provenance.
internal struct Observed<Phase: Swift::Sendable>: Swift::Sendable, Swift::CustomStringConvertible {
    fileprivate let record: _StateMachineEngine.Snapshot
    fileprivate let claim: StateMachine::RuntimeDeliveryClaim?
    fileprivate let _stateMachineProject: @Sendable (borrowing _StateMachineEngine.Snapshot) -> Phase
    /// The copied historical payload.
    internal var value: Phase {
        _stateMachineProject(record)
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
internal func finish(_ input: Int) -> Prepared where Phase == Idle {
    guard case .idle(let payload) = record.model else {
        Swift::preconditionFailure("Observed phase payload did not match its snapshot.")
    }
    let next: Done = _StateMachineSchema.finish(payload, input)
    return _stateMachinePrepare(on: record, next: .done(next),
        effects: [],
        from: 0, to: 1, invalidates: [],
        requiring: nil, claim: claim, edge: "idle.finish")
    }
}

/// A complete historical root observation with sealed provenance.
internal enum Snapshot: Swift::Sendable, StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
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
    internal var revision: Swift::UInt64 {
        record.revision
    }
    /// Whether this historical root records closure.
    internal var isClosed: Swift::Bool {
        record.isClosed
    }
    /// The ordinary model data. Constructing a model value directly confers no installation authority.
    internal var model: Counter {
        record.model
    }
    /// The phase, revision, and closure of this observation, without its payload.
    internal var description: Swift::String {
        switch self {
        case .idle(let value):
            return "idle, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        case .done(let value):
            return "done, revision \(value.record.revision)\(value.record.isClosed ? ", closed" : "")"
        }
    }
}

fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
    switch record.model {
    case .idle:
        return .idle(Observed(record: record, claim: claim, _stateMachineProject: { record in
            guard case .idle(let payload) = record.model else {
                Swift::preconditionFailure("Observed phase payload did not match its snapshot.")
            }
            return payload
        }))
    case .done:
        return .done(Observed(record: record, claim: claim, _stateMachineProject: { record in
            guard case .done(let payload) = record.model else {
                Swift::preconditionFailure("Observed phase payload did not match its snapshot.")
            }
            return payload
        }))
    }
}

fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
    switch record.model {
    case .idle:
        return "idle"
    case .done:
        return "done"
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
    }
    /// The identifier of the graph edge the acceptance took, as `graph` names it, or `nil` for a
    /// change that takes no edge, such as a reset, closure, or the authority-only commit of
    /// `discardPending(id:)`.
    internal var edgeID: Swift::String? {
        snapshot.record.edge
    }
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

fileprivate static var _stateMachineEligibility: [[Swift::Int]] {
    []
}

fileprivate static func _stateMachinePrepare(
    on record: _StateMachineEngine.Snapshot, next: Counter, effects: [Effect], from: Swift::Int, to: Swift::Int,
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
    case .finish(let input):
        switch snapshot {
        case .idle(let source):
            return source.finish(input)
        default:
            throw .invalidPhase
        }
    }
}

/// A phase that saved data can restore, covering phases with no active operations. A restored owner has no outstanding work.
internal enum Restoration: Swift::Sendable {
    case idle(Idle)
    case done(Done)
}

/// The obligations a managed owner still tracked when its shutdown deadline expired.
///
/// It is captured in the same observation that found the deadline expired, so it always names
/// at least one unsettled obligation. It holds no model data and no authority over the owner.
internal struct ShutdownDiagnostics: Swift::Equatable, Swift::Sendable {

    /// The owner's last accepted revision at the observation.
    internal let acceptedRevision: Swift::UInt64
    /// The revision of the last fully processed FIFO batch.
    internal let processedThrough: Swift::UInt64
    /// Whether accepted ordinary or terminal batches still await processing.
    internal let hasQueuedBatches: Swift::Bool
    /// Whether a FIFO processing turn still owns responsibility.
    internal let isDraining: Swift::Bool

    fileprivate init(_ raw: StateMachine::ShutdownDiagnostics) {
        acceptedRevision = raw.acceptedRevision
        processedThrough = raw.processedThrough
        hasQueuedBatches = raw.hasQueuedBatches
        isDraining = raw.isDraining

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
internal struct Local: ~Swift::Copyable, StateMachine::LocalStateMachine, StateMachine::DefaultingLocalStateMachine {
    /// A type of this owner's `LocalStateMachine` conformance.
internal typealias Input = Counter.Input
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Snapshot = Counter.Snapshot
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Receipt = Counter.Receipt
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias SendRejection = Counter.SendRejection
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias Prepared = Counter.Prepared
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias CommitResult = Counter.CommitResult
    /// A type of this owner's `LocalStateMachine` conformance.
    internal typealias InitialPhase = Idle
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
        _StateMachineSchema.Idle()
    }

    fileprivate var engine: _StateMachineEngine

    /// Creates fresh authority only in the declared initial phase.
    internal init(_ initial: Idle = _StateMachineSchema.Idle(), configuration: LocalConfiguration = .default) {
        engine = _StateMachineEngine(.idle(initial), scopes: [], limits: configuration, recording: .commands)
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
    internal mutating func reset(to initial: Idle = _StateMachineSchema.Idle()) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.idle(initial), scopes: [])
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
    internal mutating func reset(to initial: Idle = _StateMachineSchema.Idle(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = engine.reset(.idle(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }

}

/// A sealed sole-writer `MainActor` owner with managed execution.
///
/// On iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, and Mac Catalyst 17.0 and
/// later, this owner conforms to `Observable` so a SwiftUI view can read it directly. Each
/// tracked member registers a read of its own value only, covering `currentSnapshot` and `snapshot()`, and `subscriberCount`.
@Swift::MainActor internal final class MainActorHost: StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost {
    private typealias Host = StateMachine::RuntimeMainActorHost<Counter, Effect, Swift::Never, PreparationRejection>
    private let host: Host
    /// Creates fresh authority.
    internal init(_ initial: Idle = _StateMachineSchema.Idle(), configuration: Configuration = .default) {
        host = Host(.idle(initial), scopes: [], configuration: configuration,
            driver: { raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Swift::Never) -> StateMachine::RuntimeTicket in
            },
            prepare: { attempt in
                switch attempt.outcome {
                }
            })
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

    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close() -> Receipt {
        Receipt(host.close())
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// The owner keeps its identity and subscribers, and its revision advances.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Idle = _StateMachineSchema.Idle()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [])
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
    internal func reset(to initial: Idle = _StateMachineSchema.Idle(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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

/// A synchronous shared owner with managed physical execution and terminal delivery.
internal final class Shared: Swift::Sendable, StateMachine::SharedStateMachineHost {
    private typealias Host = StateMachine::RuntimeSharedHost<Counter, Effect, Swift::Never, PreparationRejection>
    private let host: Host
    /// Creates fresh initial authority.
    internal init(_ initial: Idle = _StateMachineSchema.Idle(), configuration: Configuration = .default) {
        host = Host(.idle(initial), scopes: [], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
            driver: { raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Swift::Never) -> StateMachine::RuntimeTicket in
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

    /// Ends admission and schedules cancellation in FIFO order.
    @discardableResult
    internal func close() -> Receipt {
        Receipt(host.close())
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// The owner keeps its identity and subscribers, and its revision advances.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Idle = _StateMachineSchema.Idle()) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [])
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
    internal func reset(to initial: Idle = _StateMachineSchema.Idle(), expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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
    private typealias Host = StateMachine::RuntimeActorHost<Counter, Effect, Swift::Never, PreparationRejection>
    private let host: Host
        /// Creates fresh authority.
    ///
    /// With `isolatedTo`, the owner's actor runs on that actor's serial executor so their turns
    /// never overlap, though calls into the owner still await.
        internal init(_ initial: Idle = _StateMachineSchema.Idle(), configuration: Configuration = .default, isolatedTo: (any Swift::Actor)? = nil) {
            host = Host(.idle(initial), scopes: [], configuration: configuration,
                driver: { raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Swift::Never) -> StateMachine::RuntimeTicket in
            },
            prepare: { attempt in
                switch attempt.outcome {
                }
            }, isolatedTo: isolatedTo)
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

    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close() async -> Receipt {
        Receipt(await host.close())
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// The owner keeps its identity and subscribers, and its revision advances.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Idle = _StateMachineSchema.Idle()) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.idle(initial), scopes: [])
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
    internal func reset(to initial: Idle = _StateMachineSchema.Idle(), expecting expected: Snapshot) async throws(CommitRejection) -> Receipt {
        let result = await host.reset(.idle(initial), scopes: [], expecting: expected.record)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline))
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
/// Its observation callbacks run on the owning actor.
///
/// The host holds its actor weakly, so an idle actor that stores it is released with it. A closure
/// that captures the actor keeps it alive while the host or registration holding the closure lasts,
/// so a handler, which the host holds for its lifetime, should use the actor it receives instead.
internal final class IsolatedHost<Owner: Swift::Actor>: StateMachine::IsolatedStateMachineHost {
    private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, Counter, Effect, Swift::Never, PreparationRejection>
    private let host: Host

    /// Creates fresh authority confined to `isolation`.
    internal init(_ initial: Idle = _StateMachineSchema.Idle(), isolation: isolated Owner, configuration: Configuration = .default) {
        host = Host(.idle(initial), scopes: [], isolation: isolation, configuration: configuration,
            driver: { _, raw in
                switch raw.descriptor {
                }
            },
            ticket: { (outcome: Swift::Never) -> StateMachine::RuntimeTicket in
            },
            prepare: { attempt in
                switch attempt.outcome {
                }
            })
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

    /// Closes admission while preserving historical model data.
    @discardableResult
    internal func close(isolation: isolated Owner = #isolation) -> Receipt {
        Receipt(host.close(isolation: isolation))
    }
        /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
    ///
    /// The owner keeps its identity and subscribers, and its revision advances.
    ///
    /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
    /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
    /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
    /// full, leaving state unchanged. It queues every reset to publish it, so it always needs a slot.
    @discardableResult
    internal func reset(to initial: Idle = _StateMachineSchema.Idle(), isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [], isolation: isolation)
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
    internal func reset(to initial: Idle = _StateMachineSchema.Idle(), expecting expected: Snapshot, isolation: isolated Owner = #isolation) throws(CommitRejection) -> Receipt {
        let result = host.reset(.idle(initial), scopes: [], expecting: expected.record, isolation: isolation)
        switch result {
        case .committed(let record):
        return Receipt(record)
        case .rejected(let reason, _):
        throw reason
        }
    }
    /// Waits until this owner has offered every snapshot through its receipt to its subscriptions.
internal func flush(through receipt: Receipt, isolation: isolated Owner = #isolation) async -> FlushResult {
    await host.flush(through: receipt.snapshot.record, isolation: isolation) ? .processed : .foreignOwner
    }
    /// Closes admission, then waits until every accepted batch is processed.
    ///
    /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
    /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
    /// deadline, it always returns `.quiescent`.
    @discardableResult
    internal func shutdown(deadline: Swift::ContinuousClock.Instant? = nil, isolation: isolated Owner = #isolation) async -> ShutdownResult {
        ShutdownResult(await host.shutdown(deadline: deadline, isolation: isolation))
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
    phases.append(_StateMachineGraph.Phase(id: "idle", payload: "Idle"))
    phases.append(_StateMachineGraph.Phase(id: "done", payload: "Done"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "finish", payload: "Int"))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "idle.finish", name: "finish",
        source: "idle", destination: "done", trigger: .input("finish"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    return .init(
        name: "Counter",
        mode: .shared,
        owners: [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost],
        initial: "idle",
        terminal: ["done"],
        restorable: [],
        phases: phases,
        inputs: inputs,
        scopes: [],
        operations: [],
        events: [],
        edges: edges,
        routers: []
    )
}
