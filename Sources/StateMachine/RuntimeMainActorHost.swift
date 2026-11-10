/// A raw sole-writer MainActor owner with actor-confined outcomes and joined execution handles.
///
/// This lower-guarantee runtime constructs its own authority. A sealed domain facade keeps
/// this instance private and performs synchronous preparation and admission in one turn.
@MainActor public final class RuntimeMainActorHost<Model, Descriptor, Outcome, DomainFailure: Error> {
    /// The embedded value admission algorithm.
    public typealias Engine = RuntimeState<Model, Descriptor>
    /// The embedded retained-outcome algorithm.
    public typealias Ledger = RuntimeDeliveryLedger<Model, Descriptor, Outcome, DomainFailure>
    /// Raw terminal delivery dispositions.
    public typealias Delivery = RuntimeHostDelivery<Model, Descriptor>

    private struct Subscriber {
        let identity: RuntimeIdentity
        var revision: UInt64
        let receive: @MainActor (Engine.Snapshot) -> Void
        let finish: @MainActor () -> Void
    }
    private var engine: Engine
    private var ledger = Ledger()
    private var ready = RuntimeDeliveryReadyQueue()
    private var entries: [RuntimeConfinedExecution] = []
    private var subscribers: [Subscriber] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var draining = false
    private var processedRevision: UInt64 = 0
    private let subscriberCapacity: Int
    private let policy: RuntimeCompletionPolicy
    private let driver: @MainActor (RuntimeWork<Descriptor>) async -> Outcome
    private let ticket: @MainActor (Outcome) -> RuntimeTicket
    private let prepare: @MainActor (Ledger.Attempt) -> Ledger.Preparation
    private let reconciliationRequired: @MainActor (Ledger.Pending) -> Void

    /// Creates fresh authority and retains appropriately isolated execution selections.
    public init(
        _ initial: Model,
        scopes: [RuntimeScopeID],
        configuration: RuntimeManagedConfiguration = .default,
        policy: RuntimeCompletionPolicy = .manualOnConflict,
        driver: @escaping @MainActor (RuntimeWork<Descriptor>) async -> Outcome,
        ticket: @escaping @MainActor (Outcome) -> RuntimeTicket,
        prepare: @escaping @MainActor (Ledger.Attempt) -> Ledger.Preparation,
        reconciliationRequired: @escaping @MainActor (Ledger.Pending) -> Void = { _ in }
    ) {
        engine = Engine(initial, scopes: scopes, limits: configuration.limits)
        subscriberCapacity = configuration.subscriberCapacity
        self.policy = policy
        self.driver = driver
        self.ticket = ticket
        self.prepare = prepare
        self.reconciliationRequired = reconciliationRequired
    }
    deinit {
        for entry in entries {
            entry.worker.cancel()
            entry.watcher?.cancel()
        }
    }
    /// Copies a complete historical observation.
    public func snapshot() -> Engine.Snapshot { engine.snapshot }
    /// Evaluates preparation outside mutable access, then admits in this same isolated turn.
    public func prepareAndCommit<Failure: Error>(
        _ preparation: (Engine.Snapshot) -> Result<Engine.Candidate, Failure>
    ) -> Result<Engine.Admission, Failure> {
        let observation = engine.snapshot
        switch preparation(observation) {
        case .success(let candidate): return .success(commit(candidate))
        case .failure(let failure): return .failure(failure)
        }
    }
    /// Accepts or rejects a complete immutable candidate without suspension.
    public func commit(_ candidate: Engine.Candidate) -> Engine.Admission {
        let result = engine.commit(candidate)
        if case .committed = result {
            ledger.prune(in: engine)
            scheduleDrain()
        }
        changed()
        return result
    }
    /// Registers initial and subsequent complete snapshots; callbacks run outside mutable accesses.
    public func subscribe(
        _ receive: @escaping @MainActor (Engine.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {}
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription {
        let initial = engine.snapshot
        let identity = RuntimeIdentity()
        if !initial.isClosed {
            guard subscribers.count < subscriberCapacity else { throw .capacityExceeded }
            subscribers.append(
                Subscriber(identity: identity, revision: initial.revision, receive: receive, finish: onFinish)
            )
        }
        let token = RuntimeMainActorSubscription { [weak self] in
            self?.subscribers.removeAll { $0.identity === identity }
        }
        receive(initial)
        if initial.isClosed { onFinish() }
        return token
    }
    /// Retains exactly the first terminal outcome and attempts fresh synchronous preparation.
    public func deliver(_ outcome: Outcome) -> Delivery {
        let authority = ticket(outcome)
        let retention = ledger.retain(outcome, for: authority, in: &engine)
        switch retention {
        case .stale: return .stale
        case .foreignOwner: return .foreignOwner
        case .pending(let id):
            guard let pending = ledger.pending.first(where: { $0.id == id }) else { return .notPending }
            guard pending.status == .awaitingAdmission else { return .pending(id, pending.status) }
            return reconcile(id: id, automatic: true)
        }
    }
    /// Historical first-outcome records, without acquiring a preparation claim.
    public func pendingCompletions() -> [Ledger.Pending] { ledger.pending }
    /// Acquires one explicit reconciliation attempt against the current root.
    public func reconcile(id: RuntimePendingID) -> Delivery { reconcile(id: id, automatic: false) }
    private func reconcile(id: RuntimePendingID, automatic: Bool) -> Delivery {
        let preparation = prepare
        let result = Ledger.reconcile(
            id,
            policy: policy,
            automatic: automatic,
            claim: { self.ledger.claim(id, in: &self.engine) },
            prepare: preparation,
            finish: { attempt, candidate in
                let finish = self.ledger.finish(attempt, preparation: candidate, in: &self.engine)
                let conflicts = self.capacityConflicts()
                self.scheduleDrain()
                self.changed()
                let pending = self.ledger.pending.first { $0.id == id }
                let reason = pending?.lastRejection
                self.handleCapacityConflicts(conflicts.filter { $0.id != id })
                let retrying: Bool
                if automatic, case .retryPure = self.policy, case .admission(.conflict) = reason {
                    retrying = true
                } else {
                    retrying = false
                }
                if !retrying, let pending, pending.status == .reconciliationRequired {
                    self.reconciliationRequired(pending)
                }
                return (finish, reason)
            },
            scheduleRetry: { self.scheduleRetry($0) }
        )
        switch result {
        case .inProgress: return .inProgress
        case .notPending: return .notPending
        case .finished(let finish): return Self.project(finish)
        }
    }
    private static func project(_ result: Ledger.Finish) -> Delivery {
        switch result {
        case .committed(let snapshot): return .committed(snapshot)
        case .pending(let id, let status): return .pending(id, status)
        case .notPending: return .notPending
        }
    }
    /// Settles retained delivery by an authority-only admission.
    public func discardPending(id: RuntimePendingID) -> Delivery {
        guard let result = ledger.discard(id, in: &engine) else { return .notPending }
        changed()
        switch result {
        case .committed(let snapshot):
            scheduleDrain()
            return .discarded(snapshot)
        case .rejected(let rejection, _): return .rejected(rejection)
        }
    }
    /// Closes admission and schedules the reserved terminal FIFO batch.
    public func close() -> Engine.Snapshot {
        let snapshot = engine.close()
        ledger.prune(in: engine)
        scheduleDrain()
        changed()
        return snapshot
    }
    private func scheduleDrain() {
        guard !draining, engine.hasQueuedBatches else { return }
        draining = true
        Task { @MainActor [weak self] in self?.drainTurn() }
    }
    private func drainTurn() {
        for _ in 0 ..< 32 {
            let batch = engine.drain(limit: 1).first
            retryCapacity()
            guard let batch else {
                if engine.hasQueuedBatches { continue }
                draining = false
                changed()
                return
            }
            for command in batch.commands {
                if case .cancel(let ticket) = command {
                    entries.first { $0.ticket == ticket }?.worker.cancel()
                }
            }
            // Initial observation may already include batches awaiting FIFO processing.
            // Advance each registration before callbacks so synchronous reentry cannot regress it.
            let observers = subscribers.filter { batch.snapshot.revision > $0.revision }
            if batch.terminal {
                subscribers = []
            } else {
                for index in subscribers.indices where subscribers[index].revision < batch.snapshot.revision {
                    subscribers[index].revision = batch.snapshot.revision
                }
            }
            for observer in observers {
                observer.receive(batch.snapshot)
                if batch.terminal { observer.finish() }
            }
            for command in batch.commands {
                if case .start(let work) = command { start(work) }
            }
            processedRevision = batch.snapshot.revision
            changed()
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.drainTurn()
        }
    }
    private func start(_ work: RuntimeWork<Descriptor>) {
        guard !entries.contains(where: { $0.ticket == work.ticket }) else { return }
        guard engine.isActive(work.ticket) else {
            _ = engine.acknowledge(work.ticket, skippedBeforeStart: true)
            retryCapacity()
            return
        }
        let driver = driver
        let identity = RuntimeIdentity()
        let worker = Task { @MainActor [weak self] in
            let outcome = await driver(work)
            _ = self?.deliver(outcome)
        }
        entries.append(RuntimeConfinedExecution(ticket: work.ticket, identity: identity, worker: worker))
        let watcher = Task { @MainActor [weak self] in
            await worker.value
            self?.terminated(work.ticket, identity: identity)
        }
        entries[entries.count - 1].watcher = watcher
    }
    private func terminated(_ ticket: RuntimeTicket, identity: RuntimeIdentity) {
        guard let index = entries.firstIndex(where: { $0.ticket == ticket && $0.identity === identity }) else {
            return
        }
        entries.remove(at: index)
        _ = engine.acknowledge(ticket, skippedBeforeStart: false)
        retryCapacity()
        scheduleDrain()
        changed()
    }
    private func capacityConflicts() -> [Ledger.Pending] {
        let results = ledger.retryCapacity(in: &engine)
        return results.compactMap { result in
            guard case .pending(let id, .reconciliationRequired) = result,
                let pending = ledger.pending.first(where: { $0.id == id }),
                case .admission(.conflict) = pending.lastRejection
            else { return nil }
            return pending
        }
    }
    private func retryCapacity() {
        handleCapacityConflicts(capacityConflicts())
    }
    private func handleCapacityConflicts(_ conflicts: [Ledger.Pending]) {
        for pending in conflicts {
            switch policy {
            case .retryPure: scheduleRetry(pending.id)
            case .manualOnConflict: reconciliationRequired(pending)
            }
        }
    }
    private func scheduleRetry(_ id: RuntimePendingID) {
        ledger.scheduleRetry(id)
        guard ready.enqueue(id) else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.retryTurn()
        }
    }
    private func retryTurn() {
        ready.prune(keeping: ledger.pending.map(\.id))
        let ids = ready.takeRound()
        for id in ids { _ = reconcile(id: id, automatic: true) }
        if ready.finishRound() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.retryTurn()
            }
        }
        changed()
    }
    private func changed() {
        let prior = waiters
        waiters = []
        for waiter in prior { waiter.resume() }
    }
    private func waitForChange(deadline: ContinuousClock.Instant? = nil) async {
        let timer = deadline.map { deadline in
            Task { @MainActor [weak self] in
                try? await Task.sleep(until: deadline, clock: ContinuousClock())
                guard !Task.isCancelled else { return }
                self?.changed()
            }
        }
        defer { timer?.cancel() }
        await withCheckedContinuation { waiters.append($0) }
    }
    /// Waits for FIFO processing through this owner-bound historical receipt.
    public func flush(through snapshot: Engine.Snapshot) async -> Bool {
        guard engine.owns(snapshot) else { return false }
        while processedRevision < snapshot.revision { await waitForChange() }
        return true
    }
    /// The number of physical workers whose joined termination has not yet been processed.
    public var runningCount: Int { entries.count }
    /// The number of live observer registrations.
    public var subscriberCount: Int { subscribers.count }
    /// Whether closure, FIFO, executions, retained delivery and claims have all settled.
    public var isQuiescent: Bool { engine.isQuiescent && entries.isEmpty && !draining && ready.isIdle }
    /// Closes and waits for actual termination and settlement, optionally bounded by a deadline.
    public func shutdownAndWait(deadline: ContinuousClock.Instant? = nil) async -> Bool {
        let receipt = close()
        while !isQuiescent || processedRevision < receipt.revision {
            if let deadline, ContinuousClock.now >= deadline { return false }
            await waitForChange(deadline: deadline)
        }
        return true
    }
    /// Closes and waits for physical termination and all retained obligations.
    public func shutdown() async { _ = await shutdownAndWait() }
}
