/// A raw native actor owning the sole value engine, ledger, and physical execution registry.
///
/// This lower-guarantee runtime constructs its own authority. A sealed domain facade keeps
/// this instance private and performs synchronous preparation and admission in one turn.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
public actor RuntimeActorHost<Model: Sendable, Descriptor: Sendable, Outcome: Sendable, DomainFailure: Error> {
    /// The embedded value admission algorithm.
    public typealias Engine = RuntimeState<Model, Descriptor>
    /// The embedded retained-outcome algorithm.
    public typealias Ledger = RuntimeDeliveryLedger<Model, Descriptor, Outcome, DomainFailure>
    /// Raw terminal delivery dispositions.
    public typealias Delivery = RuntimeHostDelivery<Model, Descriptor>

    private struct Subscriber {
        let identity: RuntimeIdentity
        let gate: RuntimeRegistrationGate
        var revision: UInt64
        let receive: @Sendable (Engine.Snapshot) -> Void
        let finish: @Sendable () -> Void
        // Run once by the destructor when this host is released without closing, after it closes its
        // lifetime gate, as a publisher learns of the release.
        var onRelease: (@Sendable () -> Void)? = nil
    }
    private struct PendingSubscriber {
        let identity: RuntimeIdentity
        let gate: RuntimeRegistrationGate
        let receive: @Sendable ([Ledger.Pending]) -> Void
        let finish: @Sendable () -> Void
        /// The ledger generation of the collection last offered to this registration, or `nil` before its first.
        var offered: UInt64?
    }
    /// The values one change may replace or remove, retained until the change is complete.
    private struct Displaceable {
        let engine: Engine
        let ledger: Ledger
        let subscribers: [Subscriber]
        let pendingSubscribers: [PendingSubscriber]
    }
    private var engine: Engine
    private var ledger = Ledger()
    private var ready = RuntimeDeliveryReadyQueue()
    // The reports this owner decided and has not yet delivered, oldest first. Each is queued in the
    // change that decides it, and one delivery at a time delivers them, so a handler that reconciles
    // synchronously queues its attempt's report behind every report decided before it.
    private var reports = RuntimeReportQueue<Ledger.Pending>()
    private var entries: [RuntimeConfinedExecution] = []
    private var subscribers: [Subscriber] = []
    private var pendingSubscribers: [PendingSubscriber] = []
    // A replaced root, a disposed outcome, a skipped command, or a removed registration can run a
    // destructor on this actor's executor that reads this host through `assumeIsolated`. Each change
    // retains what it may displace before it mutates, and the values are released once no mutable
    // access is in progress and the change is complete.
    private var displaced: [Displaceable] = []
    // Whether a publication of the retained completions is offering them now.
    private var publishingPending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var draining = false
    private var processedRevision: UInt64 = 0
    private let subscriberCapacity: Int
    private let policy: RuntimeCompletionPolicy
    private let driver: @Sendable (RuntimeWork<Descriptor>) async -> Outcome
    private let ticket: @Sendable (Outcome) -> RuntimeTicket
    private let prepare: @Sendable (Ledger.Attempt) -> Ledger.Preparation
    private let reconciliationRequired: @Sendable (Ledger.Pending) -> Void
    private let emit: @Sendable (Descriptor) -> Void
    // The actor whose serial executor runs this one: the caller's choice, or a private actor of its own.
    private let executorOwner: any Actor
    /// Open until this host is released without closing, which closes it first, on the releasing
    /// thread: every publisher of this host reads it, so all of them learn of the release at one instant.
    package nonisolated let ownerLifetime = RuntimeRegistrationGate()

    /// Creates fresh authority and retains appropriately isolated execution selections.
    ///
    /// `emit` receives each accepted emission in commit order, on this owner's isolation, from the
    /// turn that processes its batch, after that batch's cancellations and before its launch
    /// decisions and observers.
    ///
    /// With `isolatedTo`, this actor runs on that actor's serial executor, so their turns never run
    /// at the same time; it stays a distinct actor, and calling it from there still awaits.
    public init(
        _ initial: Model,
        scopes: [RuntimeScopeID],
        configuration: ManagedConfiguration = .default,
        policy: RuntimeCompletionPolicy = .manual,
        driver: @escaping @Sendable (RuntimeWork<Descriptor>) async -> Outcome,
        ticket: @escaping @Sendable (Outcome) -> RuntimeTicket,
        prepare: @escaping @Sendable (Ledger.Attempt) -> Ledger.Preparation,
        reconciliationRequired: @escaping @Sendable (Ledger.Pending) -> Void = { _ in },
        emit: @escaping @Sendable (Descriptor) -> Void = { _ in },
        isolatedTo executor: (any Actor)? = nil
    ) {
        executorOwner = executor ?? RuntimeExecutorAnchor()
        engine = Engine(initial, scopes: scopes, limits: configuration.limits)
        subscriberCapacity = configuration.subscriberCapacity
        self.policy = policy
        self.driver = driver
        self.ticket = ticket
        self.prepare = prepare
        self.reconciliationRequired = reconciliationRequired
        self.emit = emit
    }
    /// The serial executor of the actor chosen at creation, or of a private actor of its own.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorOwner.unownedExecutor }
    // Every host tears down in the same order, after the batches it accepted have drained: the drain
    // retains this host until then. (1) Unless the owner closed, its lifetime gate closes, once, before
    // any registration is notified and before any client code can run, so every publisher of the owner learns of the release
    // at the same instant and none can begin an ordinary delivery after another has finished for it;
    // the registrations that learn of the release at once are then notified, which wakes each publisher
    // on the main actor. (2) The workers are cancelled, whose cancellation handlers are client code that
    // runs synchronously and can attach to a publisher, which already knows that the owner promises
    // nothing more. (3) The client callbacks and values are released, whose captures' destructors are
    // client code too, and a registration of an owner released without closing is finished, without a
    // closed snapshot, on a later task. A sequence keeps its unread element across the release, so it has
    // no gate of its own to close.
    deinit {
        // A closed owner's publishers finish after its closed snapshot, which may still be on its way.
        if !engine.snapshot.isClosed { ownerLifetime.close() }
        for subscriber in subscribers {
            subscriber.onRelease?()
            ReleaseNoticePause.reached()
        }
        for entry in entries {
            entry.worker.cancel()
            entry.watcher?.cancel()
        }
        let finishing = subscribers.map { (gate: $0.gate, finish: $0.finish) }
        let pendingFinishing = pendingSubscribers.map { (gate: $0.gate, finish: $0.finish) }
        subscribers = []
        pendingSubscribers = []
        displaced = []
        if !finishing.isEmpty || !pendingFinishing.isEmpty {
            Task.detached {
                for subscriber in finishing where subscriber.gate.isOpen { subscriber.finish() }
                for subscriber in pendingFinishing where subscriber.gate.isOpen { subscriber.finish() }
            }
        }
    }
    /// Copies a complete historical observation.
    public func snapshot() -> Engine.Snapshot { engine.snapshot }
    /// Evaluates preparation outside mutable access, then admits in this same isolated turn.
    public func prepareAndCommit<Failure: Error>(
        _ preparation: @Sendable (Engine.Snapshot) -> Result<Engine.Candidate, Failure>
    ) -> Result<Engine.Admission, Failure> {
        let observation = engine.snapshot
        switch preparation(observation) {
        case .success(let candidate): return .success(commit(candidate))
        case .failure(let failure): return .failure(failure)
        }
    }
    /// Accepts or rejects a complete immutable candidate without suspension.
    public func commit(_ candidate: Engine.Candidate) -> Engine.Admission {
        retainDisplaceable()
        let result = engine.commit(candidate)
        if case .committed = result {
            ledger.prune(in: engine)
            scheduleDrain()
        }
        changed()
        return result
    }
    /// Reports a defective plan with ordinary admission precedence against the current root.
    public func reject(_ defect: Engine.DefectivePlan) -> Engine.Admission { engine.reject(defect) }
    /// Registers an observer of the initial and subsequent complete snapshots; callbacks run outside mutable accesses.
    public func subscribe(
        _ receive: @escaping @Sendable (Engine.Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {}
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        try subscribe(receive, onFinish: onFinish, onRelease: nil)
    }
    /// Registers an observer as ``subscribe(_:onFinish:)`` does, and runs `onRelease` once, on the
    /// thread that releases this host, when the host is released without closing, after it closes its
    /// lifetime gate and before it cancels any worker or releases any callback.
    package func subscribe(
        _ receive: @escaping @Sendable (Engine.Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {},
        onRelease: (@Sendable () -> Void)?
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        let initial = engine.snapshot
        let identity = RuntimeIdentity()
        let gate = RuntimeRegistrationGate()
        if !initial.isClosed {
            // A cancelled registration no longer holds its slot, though its removal may still be queued.
            pruneClosedRegistrations()
            guard subscribers.count + pendingSubscribers.count < subscriberCapacity else {
                releaseDisplaced()
                throw .capacityExceeded
            }
            subscribers.append(
                Subscriber(
                    identity: identity,
                    gate: gate,
                    revision: initial.revision,
                    receive: receive,
                    finish: onFinish,
                    onRelease: onRelease
                )
            )
        }
        let token = SnapshotSubscription(gate: gate) { [weak self] in
            gate.close()
            Task { await self?.remove(identity) }
        }
        releaseDisplaced()
        receive(initial)
        if initial.isClosed { onFinish() }
        return token
    }
    /// Registers an observer of the retained completions, starting with the collection current now.
    ///
    /// Each later call receives the whole collection after a change to it, in the order of those changes.
    /// The first is offered through the same publication as every later one, so a change made while
    /// it is offered is offered after it. Closing delivers a final, empty collection and then
    /// finishes; a closed owner delivers it at once.
    package func subscribePending(
        _ receive: @escaping @Sendable ([Ledger.Pending]) -> Void,
        onFinish: @escaping @Sendable () -> Void = {}
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        let closed = engine.snapshot.isClosed
        let identity = RuntimeIdentity()
        let gate = RuntimeRegistrationGate()
        if !closed {
            pruneClosedRegistrations()
            guard subscribers.count + pendingSubscribers.count < subscriberCapacity else {
                releaseDisplaced()
                throw .capacityExceeded
            }
            pendingSubscribers.append(
                PendingSubscriber(identity: identity, gate: gate, receive: receive, finish: onFinish)
            )
        }
        let token = SnapshotSubscription(gate: gate) { [weak self] in
            gate.close()
            Task { await self?.remove(identity) }
        }
        releaseDisplaced()
        if closed {
            receive(ledger.pending)
            onFinish()
        } else {
            publishPending()
        }
        return token
    }
    // Removes one registration, releasing its callbacks after the collections no longer hold them.
    private func remove(_ identity: RuntimeIdentity) {
        guard
            subscribers.contains(where: { $0.identity === identity })
                || pendingSubscribers.contains(where: { $0.identity === identity })
        else { return }
        retainDisplaceable()
        subscribers.removeAll { $0.identity === identity }
        pendingSubscribers.removeAll { $0.identity === identity }
        releaseDisplaced()
    }
    // Removes registrations whose gate closed; their callbacks are released with the change's other
    // displaced values, after the collections no longer hold them.
    private func pruneClosedRegistrations() {
        guard
            subscribers.contains(where: { !$0.gate.isOpen }) || pendingSubscribers.contains(where: { !$0.gate.isOpen })
        else { return }
        retainDisplaceable()
        subscribers.removeAll { !$0.gate.isOpen }
        pendingSubscribers.removeAll { !$0.gate.isOpen }
    }
    // Retains every value the next mutation can displace until `releaseDisplaced()`.
    private func retainDisplaceable() { displaced.append(displaceable()) }
    // Copies every value the next mutation can displace, for a caller that keeps the copy until that
    // mutation is complete and then releases it itself, on every path.
    private func displaceable() -> Displaceable {
        Displaceable(engine: engine, ledger: ledger, subscribers: subscribers, pendingSubscribers: pendingSubscribers)
    }
    // Releases the values earlier mutations displaced. Their destructors may read or change this host,
    // so this runs only between mutations, once the change that displaced them is complete.
    private func releaseDisplaced() {
        guard !displaced.isEmpty else { return }
        let released = displaced
        displaced = []
        withExtendedLifetime(released) {}
    }
    /// Retains exactly the first terminal outcome and attempts fresh synchronous preparation.
    public func deliver(_ outcome: Outcome) -> Delivery {
        let authority = ticket(outcome)
        retainDisplaceable()
        let retention = ledger.retain(outcome, for: authority, in: &engine)
        switch retention {
        case .stale:
            releaseDisplaced()
            return .stale
        case .foreignOwner:
            releaseDisplaced()
            return .foreignOwner
        case .pending(let id):
            defer { changed() }
            guard let pending = ledger.pending.first(where: { $0.id == id }) else { return .notPending }
            guard pending.status == .awaitingAdmission else { return .pending(id, pending.status) }
            return reconcile(id: id, automatic: true, retained: pending.decision)
        }
    }
    /// Historical first-outcome records, without acquiring a preparation claim.
    public func pendingCompletions() -> [Ledger.Pending] { ledger.pending }
    /// Acquires one explicit reconciliation attempt against the current root.
    public func reconcile(id: RuntimePendingID) -> Delivery { reconcile(id: id, automatic: false) }
    /// The root a refused preparation ran on, and the typed failure it threw.
    public typealias Refusal = (snapshot: Engine.Snapshot, failure: DomainFailure)
    /// Acquires one explicit reconciliation attempt as `reconcile(id:)` does, and returns with its result
    /// the refusal its own preparation produced, when that refusal left the outcome
    /// `reconciliationRequired`.
    public func reconcileReportingRefusal(id: RuntimePendingID) -> (delivery: Delivery, refusal: Refusal?) {
        var refusal: Refusal?
        let delivery = reconcile(id: id, automatic: false, refused: { refusal = ($0, $1) })
        guard case .pending(_, .reconciliationRequired) = delivery else { return (delivery, nil) }
        return (delivery, refusal)
    }
    private func reconcile(
        id: RuntimePendingID,
        automatic: Bool,
        retained: RuntimeDeliveryDecision? = nil,
        scheduledRetry: Bool = false,
        refused: ((Engine.Snapshot, DomainFailure) -> Void)? = nil
    ) -> Delivery {
        // Only the first claim of a queued turn depends on the decision that queued it.
        var scheduledClaim = scheduledRetry
        let preparation = prepare
        let result = Ledger.reconcile(
            id,
            policy: policy,
            automatic: automatic,
            retained: retained,
            claim: { decision in
                defer { scheduledClaim = false }
                // The claim keeps what it may displace until the claim is complete and releases it on every
                // result, so a claim of a settled or claimed record leaves nothing retained behind it.
                let retained = self.displaceable()
                let claim = self.ledger.claim(
                    id,
                    in: &self.engine,
                    continuing: decision,
                    scheduledRetry: scheduledClaim
                )
                withExtendedLifetime(retained) {}
                return claim
            },
            prepare: { attempt in
                let prepared = preparation(attempt)
                if case .failure(.preparation(let failure)) = prepared { refused?(attempt.snapshot, failure) }
                return prepared
            },
            finish: { attempt, candidate in
                // The attempt's decision is captured before any callout, so it reports its own decision.
                self.retainDisplaceable()
                let finish = self.ledger.finish(attempt, preparation: candidate, in: &self.engine)
                let conflicts = self.capacityConflicts()
                let pending = self.ledger.pending.first { $0.id == id }
                let retrying: Bool
                if automatic, case .retry = self.policy, case .admission(.conflict) = pending?.lastRejection {
                    retrying = true
                } else {
                    retrying = false
                }
                self.scheduleDrain()
                if !retrying, let pending, pending.status == .reconciliationRequired {
                    self.reports.append(pending)
                }
                self.handleCapacityConflicts(conflicts.filter { $0.id != id })
                self.changed()
                return (finish, pending)
            },
            scheduleRetry: { self.scheduleRetry($0, after: $1) }
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
        retainDisplaceable()
        guard let result = ledger.discard(id, in: &engine) else {
            releaseDisplaced()
            return .notPending
        }
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
        let wasClosed = engine.snapshot.isClosed
        retainDisplaceable()
        let snapshot = engine.close()
        ledger.prune(in: engine)
        if !wasClosed { ledger.close() }
        scheduleDrain()
        changed()
        return snapshot
    }
    /// Replaces the model in a fresh incarnation, revoking all work and disposing every retained completion.
    ///
    /// Without `expected`, it expects no revision, and rejects only on closure, revision exhaustion, or a
    /// full commit queue, because this host queues every reset to publish it. With `expected`, it also
    /// rejects unless the owner still holds that root, as the engine's `reset` describes. A rejection
    /// changes nothing.
    public func reset(
        _ model: Model,
        scopes: [RuntimeScopeID],
        expecting expected: Engine.Snapshot? = nil
    )
        -> Engine.Admission
    {
        retainDisplaceable()
        let result = engine.reset(model, scopes: scopes, expecting: expected)
        if case .committed = result {
            ledger.prune(in: engine)
            ready.prune(keeping: ledger.pendingIDs)
            scheduleDrain()
        }
        changed()
        return result
    }
    // The drain retains this host until it has processed every accepted batch, so releasing the host
    // after an accepted change still runs that change's emissions, launches, and observer deliveries.
    // It is finite: it holds nothing while no batch is queued, and never waits on a driver.
    private func scheduleDrain() {
        guard !draining, engine.hasQueuedBatches else { return }
        draining = true
        // The drain runs on a detached task, which carries the driver-start pause of the admission.
        let pause = DriverStartPause.beforeStarting
        Task.detached { await DriverStartPause.$beforeStarting.withValue(pause) { await self.drainTurn() } }
    }
    private func drainTurn() {
        pruneClosedRegistrations()
        for _ in 0 ..< 32 {
            retainDisplaceable()
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
            // Advance each registration before its callback runs so its revision never regresses.
            let observers = subscribers.filter { batch.snapshot.revision > $0.revision }
            if batch.terminal {
                subscribers = []
            } else {
                for index in subscribers.indices where subscribers[index].revision < batch.snapshot.revision {
                    subscribers[index].revision = batch.snapshot.revision
                }
            }
            // Emissions, launch decisions, and flush accounting come first, so an observer that waits on
            // this batch's work, or is merely slow, cannot hold them back. The drain flag keeps an event
            // handler's own commit from processing a batch inside this one.
            for command in batch.commands {
                if case .emit(let descriptor) = command { emit(descriptor) }
            }
            for command in batch.commands {
                if case .start(let work) = command { start(work) }
            }
            processedRevision = batch.snapshot.revision
            changed()
            // A callback can cancel a registration, its own included, whose removal runs on a later
            // turn; the gate keeps any later callback from beginning.
            for observer in observers where observer.gate.isOpen {
                observer.receive(batch.snapshot)
                if batch.terminal, observer.gate.isOpen { observer.finish() }
            }
        }
        let pause = DriverStartPause.beforeStarting
        Task.detached {
            await DriverStartPause.$beforeStarting.withValue(pause) {
                await Task.yield()
                await self.drainTurn()
            }
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
        let pause = DriverStartPause.beforeStarting
        let worker = Task.detached { [weak self] in
            pause?(work.ticket)
            let outcome = await driver(work)
            _ = await self?.deliver(outcome)
        }
        entries.append(RuntimeConfinedExecution(ticket: work.ticket, identity: identity, worker: worker))
        let watcher = Task.detached { [weak self] in
            await worker.value
            await self?.terminated(work.ticket, identity: identity)
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
        retainDisplaceable()
        return ledger.retryCapacityConflicts(in: &engine)
    }
    private func retryCapacity() {
        handleCapacityConflicts(capacityConflicts())
        deliverReports()
    }
    // Queues a report of each capacity conflict of a batch, as captured when it was found, in the
    // change that found them, or under the retry policy schedules each for another turn.
    private func handleCapacityConflicts(_ conflicts: [Ledger.Pending]) {
        CapacityConflictPause.reached(conflicts, \.id)
        guard case .manual = policy else {
            for pending in conflicts { _ = scheduleRetry(pending.id, after: pending.decision) }
            return
        }
        for pending in conflicts { reports.append(pending) }
    }
    /// Delivers the queued reports from the oldest, one at a time, unless a delivery is already in
    /// progress, and reports whether none is now.
    ///
    /// A call from inside a handler finds the delivery that runs it in progress, which delivers the
    /// reports this call would have, after every report queued before them, and finishes the change.
    @discardableResult
    private func deliverReports() -> Bool {
        var delivering = false
        while var taken = reports.takeAll(continuing: delivering) {
            delivering = true
            while let pending = taken.popFirst() { reconciliationRequired(pending) }
        }
        return !reports.isDelivering
    }
    // Scheduling is bound to the decision that lost the conflict, so a newer attempt keeps its own.
    // An envelope that used its last turn parks, and that is when reconciliation is required.
    private func scheduleRetry(_ id: RuntimePendingID, after decision: RuntimeDeliveryDecision) -> Bool {
        switch ledger.scheduleRetry(id, after: decision) {
        case .scheduled: break
        case .superseded: return false
        case .exhausted:
            // The caller's change delivers the report.
            if let pending = ledger.pending.first(where: { $0.id == id }) { reports.append(pending) }
            return false
        }
        guard ready.enqueue(id) else { return true }
        Task.detached { [weak self] in
            await Task.yield()
            await self?.retryTurn()
        }
        return true
    }
    private func retryTurn() {
        ready.prune(keeping: ledger.pendingIDs)
        let ids = ready.takeRound()
        for id in ids { _ = reconcile(id: id, automatic: true, scheduledRetry: true) }
        if ready.finishRound() {
            Task.detached { [weak self] in
                await Task.yield()
                await self?.retryTurn()
            }
        }
        changed()
    }
    // Finishes a change: delivers the reports it queued, then publishes it. A change made inside a
    // handler leaves its publication to the delivery that runs the handler, so nothing a change
    // publishes precedes a report queued before it.
    private func changed() {
        guard deliverReports() else { return }
        publishPending()
        let prior = waiters
        waiters = []
        for waiter in prior { waiter.resume() }
        releaseDisplaced()
    }
    /// Offers the retained completions to each pending-completion registration that has not yet received
    /// the current collection, its first included, and ends every registration with the final, empty
    /// collection once the owner is closed.
    ///
    /// Publications never nest. A callback that changes the collection through `assumeIsolated` leaves
    /// it to this publication, which stops offering the older collection and offers the newer one to
    /// every registration, so each registration receives collections in ledger order and the newest one last.
    private func publishPending() {
        // A delivery of reports in progress publishes once it ends.
        guard !publishingPending, !reports.isDelivering else { return }
        publishingPending = true
        defer { publishingPending = false }
        var image: (generation: UInt64, pending: [Ledger.Pending])?
        while true {
            let generation = ledger.generation
            guard
                let index = pendingSubscribers.firstIndex(where: { $0.gate.isOpen && $0.offered != generation })
            else {
                // The last collection offered is released while publications still cannot nest. Its
                // destructors can change the collection or end a registration, so the registrations are
                // checked again after it.
                if let retired = image {
                    image = nil
                    withExtendedLifetime(retired) {}
                    continue
                }
                // Closing ends every registration once each has received the final collection. The
                // copy keeps the callbacks until the stored collection no longer holds them.
                guard engine.snapshot.isClosed, !pendingSubscribers.isEmpty else { return }
                let finishing = pendingSubscribers
                pendingSubscribers = []
                for observer in finishing where observer.gate.isOpen { observer.finish() }
                continue
            }
            // An older collection is released before a recipient is chosen, because its destructors can
            // change the collection or end the registration that would be chosen.
            guard let current = image, current.generation == generation else {
                let retired = image
                image = (generation, ledger.pending)
                withExtendedLifetime(retired) {}
                continue
            }
            pendingSubscribers[index].offered = generation
            let observer = pendingSubscribers[index]
            observer.receive(current.pending)
        }
    }
    private func waitForChange(deadline: ContinuousClock.Instant? = nil) async {
        let timer = deadline.map { deadline in
            Task.detached { [weak self] in
                try? await Task.sleep(until: deadline, clock: ContinuousClock())
                guard !Task.isCancelled else { return }
                await self?.changed()
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
    public var subscriberCount: Int {
        subscribers.filter(\.gate.isOpen).count + pendingSubscribers.filter(\.gate.isOpen).count
    }
    /// Whether closure, FIFO, executions, retained delivery, and claims have all settled.
    public var isQuiescent: Bool { engine.isQuiescent && entries.isEmpty && !draining && ready.isIdle }
    /// Captures the obligations still tracked, without exposing a ticket or other authority.
    package func diagnostics() -> ShutdownDiagnostics {
        ShutdownDiagnostics(
            engine: engine,
            processedThrough: processedRevision,
            isDraining: draining,
            isRetrying: !ready.isIdle,
            pendingCompletions: ledger.pending.map(\.id)
        )
    }
    /// Closes admission, then waits until every execution, delivery, and preparation obligation settles
    /// or `deadline` passes.
    ///
    /// Returns `nil` once the owner is quiescent. Otherwise it returns the obligations observed in the
    /// same actor turn that found the deadline expired; that work stays tracked and can still settle.
    @discardableResult
    public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownDiagnostics? {
        let receipt = close()
        while !isQuiescent || processedRevision < receipt.revision {
            if let deadline, ContinuousClock.now >= deadline { return diagnostics() }
            await waitForChange(deadline: deadline)
        }
        return nil
    }
}

/// A private actor whose default serial executor runs a `RuntimeActorHost` that shares no other actor's.
private actor RuntimeExecutorAnchor {}
