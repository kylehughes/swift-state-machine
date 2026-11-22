import StateMachine

/// A handwritten editor whose immutable value data is deliberately non-Sendable.
nonisolated public enum IsolatedNote {
    /// Independent draft data whose strings and tags cannot mutate an owner when copied.
    public struct Draft: ~Sendable {
        /// The note text.
        public let text: String
        /// Value-semantic classification data.
        public let tags: [String]
        /// Creates ordinary editor data without granting live authority.
        public init(text: String, tags: [String] = []) {
            self.text = text
            self.tags = tags
        }
    }
    /// A historical save request, which does not itself prove work remains authorized.
    public struct Saving: ~Sendable {
        /// The submitted independent draft.
        public let draft: Draft
        fileprivate init(_ draft: Draft) { self.draft = draft }
    }
    /// Ordinary saved data returned by a confined driver.
    public struct Saved: ~Sendable {
        /// The saved text.
        public let text: String
        /// The saved value-semantic tags.
        public let tags: [String]
        /// Creates result data without granting completion authority, which committed work issues separately.
        public init(text: String, tags: [String] = []) {
            self.text = text
            self.tags = tags
        }
    }
    /// A failed save with its retryable data.
    public struct Failed: ~Sendable {
        /// The original draft.
        public let draft: Draft
        /// The typed storage failure.
        public let reason: SaveFailure
    }
    /// A typed external storage failure.
    public enum SaveFailure: Error { case unavailable }
    /// Synchronous domain or routing rejection.
    ///
    /// Any plan defect travels inside `Prepared` to admission.
    public enum PreparationRejection: Error {
        case emptyText
        case invalidPhase
    }
    /// Closed dynamic editor inputs, confined to their caller's isolation.
    public enum Input: ~Sendable {
        case edit(Draft)
        case save
        case cancel
    }
    /// The complete ordinary phase data, independent of live work authority.
    public enum Model: ~Sendable {
        case draft(Draft)
        case saving(Saving)
        case saved(Saved)
        case failed(Failed)
    }
    /// Unique authority over a workflow phase.
    public struct Owned<Phase: ~Copyable>: ~Copyable {
        fileprivate let phase: Phase
        fileprivate init(_ phase: consuming Phase) { self.phase = phase }
        /// Borrows the payload for a synchronous nonescaping read.
        public borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result { body(phase) }
    }
    /// A historical phase payload with sealed whole-root provenance.
    public struct Observed<Phase> {
        /// The independent phase payload.
        public let value: Phase
        fileprivate let stamp: Engine.Snapshot
    }
    /// Complete historical data and its sealed provenance.
    public enum Snapshot {
        case draft(Observed<Draft>)
        case saving(Observed<Saving>)
        case saved(Observed<Saved>)
        case failed(Observed<Failed>)
        fileprivate var stamp: Engine.Snapshot {
            switch self {
            case .draft(let value): value.stamp
            case .saving(let value): value.stamp
            case .saved(let value): value.stamp
            case .failed(let value): value.stamp
            }
        }
        /// The owner-lifetime accepted revision.
        public var revision: UInt64 { stamp.revision }
        /// Whether this historical owner has closed.
        public var isClosed: Bool { stamp.isClosed }
        /// The ordinary model, carrying no execution authority.
        public var model: Model { stamp.model }
        /// A detached editor projection, regardless of its historical phase.
        public var value: Draft {
            switch self {
            case .draft(let value): value.value
            case .saving(let value): value.value.draft
            case .saved(let value): Draft(text: value.value.text, tags: value.value.tags)
            case .failed(let value): value.value.draft
            }
        }
    }
    /// A sealed inert candidate that admission consumes, or the plan defect admission reports.
    public struct Prepared: ~Copyable {
        fileprivate let candidate: Engine.Proposal
    }
    /// A historical accepted observation.
    public struct Receipt {
        /// The complete accepted observation.
        public let snapshot: Snapshot
        /// The accepted revision.
        public var revision: UInt64 { snapshot.revision }
    }
    /// Atomic admission either publishes everything or preserves the current root.
    public enum CommitResult {
        case committed(Receipt)
        case rejected(Engine.Rejection, current: Snapshot)
    }
    /// Work authority issued only from an accepted command batch.
    public struct SaveWork {
        /// The independent operation input.
        public let input: Draft
        fileprivate let authority: RuntimeTicket
        /// A sealed handle used only for actual termination acknowledgments.
        public var execution: ExecutionHandle { ExecutionHandle(authority: authority) }
        /// Seals success for this committed operation.
        public func succeeded(_ value: Saved) -> Completion {
            Completion(result: .success(value), authority: authority)
        }
        /// Seals failure for this committed operation.
        public func failed(_ reason: SaveFailure) -> Completion {
            Completion(result: .failure(reason), authority: authority)
        }
    }
    /// A terminal outcome carrying privately issued operation authority.
    public struct Completion {
        /// Ordinary first-result data, independent of its privately sealed authority.
        public let result: Result<Saved, SaveFailure>
        fileprivate let authority: RuntimeTicket
    }
    /// An owner-bound execution handle, separate from terminal outcome delivery.
    public struct ExecutionHandle: Equatable, Sendable {
        fileprivate let authority: RuntimeTicket
    }
    /// Actual physical execution disposition, independent of cancellation.
    public typealias ExecutionDisposition = StateMachine.ExecutionDisposition
    /// Exact acknowledgment outcomes.
    public typealias AcknowledgmentResult = StateMachine.AcknowledgmentResult
    /// One ordered inert command.
    public enum Command {
        case save(SaveWork)
        case cancel(ExecutionHandle)
    }
    /// An indivisible FIFO command batch.
    public struct CommandBatch {
        /// The acceptance receipt.
        public let receipt: Receipt
        /// Commands in their accepted order.
        public let commands: [Command]
        /// Whether this is the reserved terminal batch.
        public let terminal: Bool
    }
    /// Immutable isolated driver selection for one managed owner's lifetime.
    @MainActor public struct MainActorDrivers {
        /// Saves independent data without receiving the live owner.
        public let save: @MainActor (Draft) async -> Result<Saved, SaveFailure>
        /// Selects the confined driver.
        public init(save: @escaping @MainActor (Draft) async -> Result<Saved, SaveFailure>) { self.save = save }
    }
    /// A unique manually driven owner with embedded engine and delivery ledger values.
    public struct Local: ~Copyable {
        private var engine: Engine
        private var ledger = Ledger()
        /// Creates fresh authority in the draft phase.
        public init(_ initial: Draft, configuration: Limits = .default) {
            engine = Engine(.draft(initial), limits: configuration, recording: .commands)
        }
        /// Copies a complete independent historical observation.
        public borrowing func snapshot() -> Snapshot { project(engine.snapshot) }
        /// Attempts a text replacement, preserving tags and reporting admission rejection.
        public mutating func replaceText(_ text: String) throws(PreparationRejection) -> CommitResult {
            try send(.edit(Draft(text: text, tags: snapshot().value.tags)))
        }
        /// Prepares and admits without suspension.
        public mutating func send(_ input: Input) throws(PreparationRejection) -> CommitResult {
            let prepared = try IsolatedNote.prepare(input, on: snapshot())
            return commit(prepared)
        }
        /// Consumes a sealed proposal and rechecks its whole-root provenance.
        public mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
            switch prepared.candidate {
            case .defective(let defect): return project(engine.reject(defect))
            case .candidate(let candidate):
                let admission = engine.commit(candidate)
                ledger.prune(in: engine)
                return project(admission)
            }
        }
        /// Transfers whole batches.
        ///
        /// Release mutable access before executing their work.
        public mutating func drainCommands(limit: Int = .max) -> [CommandBatch] {
            engine.drain(limit: limit).map { project($0) }
        }
        /// Retains the first terminal result and attempts its synchronous admission.
        public mutating func deliver(_ completion: Completion) -> DeliveryResult {
            switch ledger.retain(completion, for: completion.authority, in: &engine) {
            case .stale: return .stale
            case .foreignOwner: return .foreignOwner
            case .pending(let id):
                guard let pending = ledger.pending.first(where: { $0.id == id }) else { return .stale }
                guard pending.status == .awaitingAdmission else { return .pending(id, pending.status) }
                switch reconcile(id: id) {
                case .committed(let receipt): return .committed(receipt)
                case .pending(let id, let status): return .pending(id, status)
                case .inProgress: return .pending(id, .preparing)
                case .notPending: return .stale
                }
            }
        }
        /// Explicitly claims a new preparation attempt for a retained result.
        public mutating func reconcile(id: RuntimePendingID) -> ReconcileResult {
            switch ledger.claim(id, in: &engine) {
            case .inProgress: return .inProgress
            case .notPending: return .notPending
            case .claimed(let attempt):
                let preparation = prepareDelivery(attempt)
                return project(ledger.finish(attempt, preparation: preparation, in: &engine))
            }
        }
        /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
        public mutating func retryAdmission(id: RuntimePendingID) -> ReconcileResult {
            project(ledger.retryAdmission(id, in: &engine))
        }
        /// Historical first-outcome diagnostics.
        public borrowing func pendingCompletions() -> [Ledger.Pending] { ledger.pending }
        /// Settles retained delivery through an authority-only admission.
        public mutating func discardPending(id: RuntimePendingID) -> DiscardResult {
            guard let result = ledger.discard(id, in: &engine) else { return .notPending }
            switch result {
            case .committed(let stamp): return .discarded(Receipt(snapshot: project(stamp)))
            case .rejected(let reason, _): return .rejected(reason)
            }
        }
        /// Records actual termination or a skip, never cancellation alone.
        public mutating func acknowledgeExecution(
            _ handle: ExecutionHandle,
            disposition: ExecutionDisposition = .terminated
        ) -> AcknowledgmentResult {
            switch engine.acknowledge(handle.authority, skippedBeforeStart: disposition == .skippedBeforeStart) {
            case .recorded: .recorded
            case .duplicate: .duplicate
            case .foreignOwner: .foreignOwner
            }
        }
        /// Closes authority while keeping historical model data readable.
        @discardableResult
        public mutating func close() -> Receipt {
            let snapshot = engine.close()
            ledger.prune(in: engine)
            return Receipt(snapshot: project(snapshot))
        }
        /// Whether closure, transferred commands, execution, and delivery have settled.
        public var isQuiescent: Bool { engine.isQuiescent }
    }
    /// A sole `MainActor` writer whose private raw host directly owns the value engine and ledger.
    @MainActor public final class MainActorHost {
        private let host: RuntimeMainActorHost<Model, Draft, Completion, PreparationRejection>
        /// Creates a managed editor with fresh authority and immutable confined drivers.
        public init(_ initial: Draft, drivers: MainActorDrivers, configuration: ManagedConfiguration = .default) {
            host = RuntimeMainActorHost(
                .draft(initial),
                scopes: [],
                configuration: configuration,
                driver: { raw in
                    let work = SaveWork(input: raw.descriptor, authority: raw.ticket)
                    switch await drivers.save(work.input) {
                    case .success(let value): return work.succeeded(value)
                    case .failure(let reason): return work.failed(reason)
                    }
                },
                ticket: { $0.authority },
                prepare: { prepareDelivery($0) }
            )
        }
        /// Copies a complete historical observation.
        public func snapshot() -> Snapshot { project(host.snapshot()) }
        /// Prepares and admits synchronous input in one `MainActor` turn.
        public func send(_ input: Input) throws(PreparationRejection) -> CommitResult {
            let observation = snapshot()
            let prepared = try prepare(input, on: observation)
            return commit(prepared)
        }
        /// Consumes a historical proposal and rechecks its provenance.
        public func commit(_ prepared: consuming Prepared) -> CommitResult {
            switch prepared.candidate {
            case .candidate(let candidate): return project(host.commit(candidate))
            case .defective(let defect): return project(host.reject(defect))
            }
        }
        /// Registers an observer of complete initial, accepted, and terminal observations.
        public func subscribe(
            _ receive: @escaping @MainActor (Snapshot) -> Void,
            onFinish: @escaping @MainActor () -> Void = {}
        ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
            try host.subscribe({ receive(project($0)) }, onFinish: onFinish)
        }
        /// Registers a single-pass sequence of the latest complete observations.
        public func snapshots() throws(SubscriptionFailure) -> MainActorSnapshotSequence<Snapshot> {
            try host.snapshots { project($0) }
        }
        /// Registers a single-pass sequence of the latest `Sendable` projections of complete observations.
        public func snapshots<Projection: Sendable>(
            _ transform: @escaping @MainActor (Snapshot) -> Projection
        ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
            try host.sendableSnapshots { transform(project($0)) }
        }
        /// Reads immutable first-outcome records for work whose outcomes the owner delivers.
        public func pendingCompletions() -> [Ledger.Pending] { host.pendingCompletions() }
        /// Explicitly claims a fresh attempt for a retained result.
        public func reconcile(id: RuntimePendingID) -> ReconcileResult { reconciled(host.reconcile(id: id)) }
        /// Settles retained delivery through an authority-only admission.
        public func discardPending(id: RuntimePendingID) -> DiscardResult { discarded(host.discardPending(id: id)) }
        /// Closes admission without claiming that work has terminated.
        @discardableResult
        public func close() -> Receipt { Receipt(snapshot: project(host.close())) }
        /// Waits for FIFO processing, independently of driver termination.
        public func flush(through receipt: Receipt) async -> FlushResult {
            await host.flush(through: receipt.snapshot.stamp) ? .processed : .foreignOwner
        }
        /// Closes, then joins all physical and retained obligations or stops waiting at `deadline`.
        ///
        /// A timeout reports the obligations observed in the main-actor turn that found the deadline
        /// expired, while the owner stays closed and that work stays tracked.
        @discardableResult
        public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
            await host.shutdown(deadline: deadline).map { .timedOut($0) } ?? .quiescent
        }
        /// Physical workers still awaiting joined termination.
        public var runningCount: Int { host.runningCount }
        /// Live observers.
        public var subscriberCount: Int { host.subscriberCount }
        /// Whether all managed obligations have settled.
        public var isQuiescent: Bool { host.isQuiescent }
    }
    /// Whether `flush(through:)` waited for a receipt's batch to be processed.
    public typealias FlushResult = StateMachine.FlushResult
    /// Whether shutdown joined every obligation or stopped waiting at its deadline.
    public enum ShutdownResult: Equatable, Sendable {
        /// Every execution, delivery, and preparation obligation settled.
        case quiescent
        /// The deadline passed first, and the diagnostics describe what was still outstanding.
        case timedOut(ShutdownDiagnostics)
    }
    /// The decision `deliver` made about one terminal result.
    public enum DeliveryResult {
        case committed(Receipt)
        case pending(RuntimePendingID, PendingStatus)
        /// The operation's authority is inactive or its outcome was already settled.
        case stale
        case foreignOwner
    }
    /// The result of one more attempt to admit a retained result.
    public enum ReconcileResult {
        case committed(Receipt)
        case pending(RuntimePendingID, PendingStatus)
        case inProgress
        case notPending
    }
    /// The result of revoking a retained result's operation.
    public enum DiscardResult {
        case discarded(Receipt)
        case rejected(Engine.Rejection)
        case notPending
    }
    /// Creates owned authority only in the declared draft phase.
    public static func owned(_ initial: Draft) -> Owned<Draft> { Owned(initial) }
    /// Routes one dynamic input against a complete historical observation.
    public static func prepare(_ input: Input, on observation: Snapshot) throws(PreparationRejection) -> Prepared {
        let next: Model
        let plan: Engine.Plan
        switch input {
        case .edit(let draft):
            next = .draft(draft)
            plan = .init(scopes: [.remove(scope)], controlCount: 1)
        case .save:
            let draft: Draft
            switch observation.model {
            case .draft(let value): draft = value
            case .saving(let value): draft = value.draft
            case .failed(let value): draft = value.draft
            case .saved: throw .invalidPhase
            }
            guard !draft.text.isEmpty else { throw .emptyText }
            next = .saving(Saving(draft))
            plan = .init(scopes: [.activate(scope)], starts: [.init(operation, descriptor: draft)], controlCount: 1)
        case .cancel:
            guard case .saving(let saving) = observation.model else { throw .invalidPhase }
            next = .draft(saving.draft)
            plan = .init(scopes: [.remove(scope)], controlCount: 1)
        }
        return Prepared(candidate: Engine.propose(on: observation.stamp, next: next, plan: plan))
    }
    /// The lower-guarantee engine type.
    ///
    /// Live facade instances remain private.
    public typealias Engine = RuntimeState<Model, Draft>
    /// The lower-guarantee delivery algorithm, never a live facade handle.
    public typealias Ledger = RuntimeDeliveryLedger<Model, Draft, Completion, PreparationRejection>
    private static var scope: RuntimeScopeID { RuntimeScopeID(kind: 0) }
    private static var operation: RuntimeOperation { .init(kind: 0, scope: scope, policy: .latest) }
    private static func project(_ stamp: Engine.Snapshot) -> Snapshot {
        switch stamp.model {
        case .draft(let value): .draft(Observed(value: value, stamp: stamp))
        case .saving(let value): .saving(Observed(value: value, stamp: stamp))
        case .saved(let value): .saved(Observed(value: value, stamp: stamp))
        case .failed(let value): .failed(Observed(value: value, stamp: stamp))
        }
    }
    private static func project(_ admission: Engine.Admission) -> CommitResult {
        switch admission {
        case .committed(let stamp): .committed(Receipt(snapshot: project(stamp)))
        case .rejected(let reason, let stamp): .rejected(reason, current: project(stamp))
        }
    }
    private static func project(_ batch: Engine.Batch) -> CommandBatch {
        CommandBatch(
            receipt: Receipt(snapshot: project(batch.snapshot)),
            commands: batch.commands.map {
                switch $0 {
                case .start(let work): .save(SaveWork(input: work.descriptor, authority: work.ticket))
                case .cancel(let authority): .cancel(ExecutionHandle(authority: authority))
                // The editor's plans carry starts only.
                case .emit: preconditionFailure("The editor emits nothing.")
                }
            },
            terminal: batch.terminal
        )
    }
    private static func project(_ finish: Ledger.Finish) -> ReconcileResult {
        switch finish {
        case .committed(let stamp): .committed(Receipt(snapshot: project(stamp)))
        case .pending(let id, let status): .pending(id, status)
        case .notPending: .notPending
        }
    }
    // The raw host reports only the cases each operation can produce, so the rest cannot occur.
    private static func reconciled(_ delivery: RuntimeHostDelivery<Model, Draft>) -> ReconcileResult {
        switch delivery {
        case .committed(let stamp): .committed(Receipt(snapshot: project(stamp)))
        case .pending(let id, let status): .pending(id, status)
        case .inProgress: .inProgress
        default: .notPending
        }
    }
    private static func discarded(_ delivery: RuntimeHostDelivery<Model, Draft>) -> DiscardResult {
        switch delivery {
        case .discarded(let stamp): .discarded(Receipt(snapshot: project(stamp)))
        case .rejected(let reason): .rejected(reason)
        default: .notPending
        }
    }
    private static func prepareDelivery(_ attempt: Ledger.Attempt) -> Ledger.Preparation {
        guard case .saving(let saving) = attempt.snapshot.model else { return .failure(.preparation(.invalidPhase)) }
        let next: Model
        switch attempt.outcome.result {
        case .success(let saved): next = .saved(saved)
        case .failure(let failure): next = .failed(Failed(draft: saving.draft, reason: failure))
        }
        do {
            return .success(
                try Engine.prepare(
                    on: attempt.snapshot,
                    next: next,
                    requiring: [attempt.outcome.authority],
                    plan: .init(
                        scopes: [.remove(scope)],
                        retire: [attempt.outcome.authority],
                        controlCount: 1,
                        finishingClaims: [attempt.claim]
                    )
                )
            )
        } catch { return .failure(.admission(.plan(error))) }
    }
}

extension IsolatedNote.Owned where Phase == IsolatedNote.Draft {
    /// Consumes the draft and preserves its complete saved successor.
    public consuming func save() -> Change<IsolatedNote.Owned<IsolatedNote.Saved>, Never> {
        Change(IsolatedNote.Owned(IsolatedNote.Saved(text: phase.text, tags: phase.tags)))
    }
}

extension IsolatedNote.Observed where Phase == IsolatedNote.Draft {
    /// Prepares the save edge from an observed draft, retaining complete-root freshness.
    public func beginSave() throws(IsolatedNote.PreparationRejection) -> IsolatedNote.Prepared {
        try IsolatedNote.prepare(.save, on: .draft(self))
    }
}

extension IsolatedNote.Observed where Phase == IsolatedNote.Saving {
    /// Prepares cancellation only from the saving phase.
    public func cancel() throws(IsolatedNote.PreparationRejection) -> IsolatedNote.Prepared {
        try IsolatedNote.prepare(.cancel, on: .saving(self))
    }
}

extension IsolatedNote.Observed where Phase == IsolatedNote.Failed {
    /// Prepares a retry from retained failed data.
    public func retry() throws(IsolatedNote.PreparationRejection) -> IsolatedNote.Prepared {
        try IsolatedNote.prepare(.save, on: .failed(self))
    }
}
