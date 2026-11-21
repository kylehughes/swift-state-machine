/// A raw sole-writer MainActor owner with actor-confined outcomes and joined execution handles.
///
/// This lower-guarantee runtime constructs its own authority. A sealed domain facade keeps
/// this instance private and performs synchronous preparation and admission in one turn.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
@MainActor public final class RuntimeMainActorHost<Model, Descriptor, Outcome, DomainFailure: Error> {
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
        let receive: @MainActor (Engine.Snapshot) -> Void
        let finish: @MainActor () -> Void
    }
    private struct PendingSubscriber {
        let identity: RuntimeIdentity
        let gate: RuntimeRegistrationGate
        let receive: @MainActor ([Ledger.Pending]) -> Void
        let finish: @MainActor () -> Void
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
    /// Everything this host holds that belongs to the main actor and can be a client value.
    ///
    /// It holds the root model, the retained outcomes, the registrations' callbacks, the values a change
    /// displaced, and the execution selections. A host can be released on another thread, so its
    /// destructor hands this to a main-actor turn, which empties it there; each value has its own
    /// property, so two accesses to different values never overlap.
    @MainActor private final class Confined {
        var engine: Engine?
        var ledger: Ledger? = Ledger()
        var subscribers: [Subscriber] = []
        var pendingSubscribers: [PendingSubscriber] = []
        // A replaced root, a disposed outcome, a skipped command, or a removed registration can run a
        // destructor that reads this host. Each change retains what it may displace before it mutates,
        // and the values are released once no mutable access is in progress and the change is complete.
        var displaced: [Displaceable] = []
        var driver: (@MainActor (RuntimeWork<Descriptor>) async -> Outcome)?
        var ticket: (@MainActor (Outcome) -> RuntimeTicket)?
        var prepare: (@MainActor (Ledger.Attempt) -> Ledger.Preparation)?
        var reconciliationRequired: (@MainActor (Ledger.Pending) -> Void)?
        var emit: (@MainActor (Descriptor) -> Void)?

        init(_ engine: Engine) { self.engine = engine }

        /// Finishes, on the main actor, the registrations of a host released without closing, unless
        /// their gates closed, then releases everything this held, before returning.
        func dispose() {
            var finishing = subscribers.map { ($0.gate, $0.finish) } + pendingSubscribers.map { ($0.gate, $0.finish) }
            subscribers = []
            pendingSubscribers = []
            for (gate, finish) in finishing where gate.isOpen { finish() }
            finishing = []
            engine = nil
            ledger = nil
            displaced = []
            driver = nil
            ticket = nil
            prepare = nil
            reconciliationRequired = nil
            emit = nil
        }
    }
    private let confined: Confined
    private var engine: Engine {
        _read { yield confined.engine! }
        _modify { yield &confined.engine! }
    }
    private var ledger: Ledger {
        _read { yield confined.ledger! }
        _modify { yield &confined.ledger! }
    }
    private var subscribers: [Subscriber] {
        _read { yield confined.subscribers }
        _modify { yield &confined.subscribers }
    }
    private var pendingSubscribers: [PendingSubscriber] {
        _read { yield confined.pendingSubscribers }
        _modify { yield &confined.pendingSubscribers }
    }
    private var displaced: [Displaceable] {
        _read { yield confined.displaced }
        _modify { yield &confined.displaced }
    }
    private var driver: @MainActor (RuntimeWork<Descriptor>) async -> Outcome { confined.driver! }
    private var ticket: @MainActor (Outcome) -> RuntimeTicket { confined.ticket! }
    private var prepare: @MainActor (Ledger.Attempt) -> Ledger.Preparation { confined.prepare! }
    private var reconciliationRequired: @MainActor (Ledger.Pending) -> Void { confined.reconciliationRequired! }
    private var emit: @MainActor (Descriptor) -> Void { confined.emit! }
    private var ready = RuntimeDeliveryReadyQueue()
    // The capacity-conflict reports captured and not yet made.
    private var owed = Ledger.OwedReports()
    private var entries: [RuntimeConfinedExecution] = []
    /// Open until this host is released without closing, which closes it first, wherever the release
    /// runs: every publisher of this host reads it, so all of them learn of the release at one instant.
    package nonisolated let ownerLifetime = RuntimeRegistrationGate()
    // Whether admission has closed, which the destructor reads: a closed owner's publishers finish
    // after its closed snapshot, so its release leaves the lifetime gate open.
    private var admissionClosed = false
    // Whether a publication of the retained completions is offering them now.
    private var publishingPending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var draining = false
    private var processedRevision: UInt64 = 0
    private let subscriberCapacity: Int
    private let policy: RuntimeCompletionPolicy
    /// The Observation tokens of this owner's snapshot, running count, subscriber count, and retained completions.
    private let observation = RuntimeObservation()
    // The values each token last reported, so a token changes only when its own value does. The
    // revision and the ledger generation only grow, so a reader saw either the reported value or a
    // newer one. A count can fall and rise again between two reports: a gate closed on another thread
    // lowers the subscriber count at once, and the admission that prunes that registration can add
    // another. Each count therefore keeps every value a reader may have seen since its last report.
    private var observedRevision: UInt64
    private var observedRunningCount = ObservedCount(0)
    private var observedSubscriberCount = ObservedCount(0)
    private var observedPendingGeneration: UInt64 = 0

    /// Creates fresh authority and retains appropriately isolated execution selections.
    ///
    /// `emit` receives each accepted emission in commit order, on this owner's isolation, from the
    /// turn that processes its batch, after that batch's cancellations and before its launch
    /// decisions and observers.
    public init(
        _ initial: Model,
        scopes: [RuntimeScopeID],
        configuration: ManagedConfiguration = .default,
        policy: RuntimeCompletionPolicy = .manual,
        driver: @escaping @MainActor (RuntimeWork<Descriptor>) async -> Outcome,
        ticket: @escaping @MainActor (Outcome) -> RuntimeTicket,
        prepare: @escaping @MainActor (Ledger.Attempt) -> Ledger.Preparation,
        reconciliationRequired: @escaping @MainActor (Ledger.Pending) -> Void = { _ in },
        emit: @escaping @MainActor (Descriptor) -> Void = { _ in }
    ) {
        let engine = Engine(initial, scopes: scopes, limits: configuration.limits)
        observedRevision = engine.snapshot.revision
        confined = Confined(engine)
        confined.driver = driver
        confined.ticket = ticket
        confined.prepare = prepare
        confined.reconciliationRequired = reconciliationRequired
        confined.emit = emit
        subscriberCapacity = configuration.subscriberCapacity
        self.policy = policy
    }
    // Every host tears down in the same order, after the batches it accepted have drained: (1) unless
    // the owner closed, its lifetime gate closes, once, before any registration is notified and before
    // any client code can run, so every publisher of the owner learns of the release at the same instant and none can begin
    // an ordinary delivery after another has finished for it; the registrations that learn of the
    // release at once are then notified; (2) the workers are cancelled, whose cancellation handlers are
    // client code that runs synchronously and can attach to a publisher, which already knows that the
    // owner promises nothing more; (3) the client callbacks and values are released, whose captures'
    // destructors are client code too, and a registration of an owner released without closing is
    // finished, without a closed snapshot, on a later task. A sequence keeps its unread element across
    // the release, so it has no gate of its own to close.
    //
    // A main-actor host can be released on another thread, when an object that stores it is released
    // there. (1) and (2) run where it is released; a publisher of this host needs no notice, because its
    // deliveries run in this host's own turns and its finish comes with (3). (3) belongs to the main
    // actor: one later main-actor turn finishes the registrations, unless their gates closed before that
    // turn, and then releases the root model, the retained outcomes, the callbacks, and the execution
    // selections, with everything they capture. `Confined` holds those values alone, so the job releases
    // them there whether it runs before or after this host's own storage is destroyed.
    deinit {
        if !admissionClosed { ownerLifetime.close() }
        for entry in entries {
            entry.worker.cancel()
            entry.watcher?.cancel()
        }
        let confined = confined
        Task { @MainActor in confined.dispose() }
        DestructorPause.reached()
    }
    /// Copies a complete historical observation, registering the read with Observation tracking.
    public func snapshot() -> Engine.Snapshot {
        observation.access(.snapshot)
        return engine.snapshot
    }
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
        _ receive: @escaping @MainActor (Engine.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {}
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        try subscribe(receive, onFinish: onFinish, gate: RuntimeRegistrationGate())
    }
    /// Registers an observer whose `gate` can end it from any thread.
    ///
    /// A closed gate stops callbacks and frees the slot at once; the registration is removed on a later
    /// main-actor turn, or when the returned token is cancelled.
    package func subscribe(
        _ receive: @escaping @MainActor (Engine.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void = {},
        gate: RuntimeRegistrationGate
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        let initial = engine.snapshot
        let identity = RuntimeIdentity()
        if !initial.isClosed {
            pruneClosedSubscribers()
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
                    finish: onFinish
                )
            )
        }
        let token = MainActorSnapshotSubscription({ [weak self] in self?.remove(identity) }, gate: gate)
        publishObservation()
        releaseDisplaced()
        receive(initial)
        if initial.isClosed { onFinish() }
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
        publishObservation()
        releaseDisplaced()
    }
    // Removes registrations whose gate closed; their callbacks are released with the change's other
    // displaced values, after the collections no longer hold them.
    private func pruneClosedSubscribers() {
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
    /// Registers an observer of the retained completions, starting with the collection current now.
    ///
    /// Each later call receives the whole collection after a change to it, in the order of those changes.
    /// The first is offered through the same publication as every later one, so a change made while
    /// it is offered is offered after it. Closing delivers a final, empty collection and then
    /// finishes; a closed owner delivers it at once.
    package func subscribePending(
        _ receive: @escaping @MainActor ([Ledger.Pending]) -> Void,
        onFinish: @escaping @MainActor () -> Void = {},
        gate: RuntimeRegistrationGate = RuntimeRegistrationGate()
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        let closed = engine.snapshot.isClosed
        let identity = RuntimeIdentity()
        if !closed {
            pruneClosedSubscribers()
            guard subscribers.count + pendingSubscribers.count < subscriberCapacity else {
                releaseDisplaced()
                throw .capacityExceeded
            }
            pendingSubscribers.append(
                PendingSubscriber(identity: identity, gate: gate, receive: receive, finish: onFinish)
            )
        }
        // The gate keeps a registration cancelled during a publication from receiving the rest of it.
        let token = MainActorSnapshotSubscription({ [weak self] in self?.remove(identity) }, gate: gate)
        publishObservation()
        releaseDisplaced()
        if closed {
            receive(ledger.pending)
            onFinish()
        } else {
            publishPending()
        }
        return token
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
    /// Historical first-outcome records, without acquiring a preparation claim, registering the read
    /// with Observation tracking.
    public func pendingCompletions() -> [Ledger.Pending] {
        observation.access(.pendingCompletions)
        return ledger.pending
    }
    /// Acquires one explicit reconciliation attempt against the current root.
    public func reconcile(id: RuntimePendingID) -> Delivery { reconcile(id: id, automatic: false) }
    private func reconcile(
        id: RuntimePendingID,
        automatic: Bool,
        retained: RuntimeDeliveryDecision? = nil,
        scheduledRetry: Bool = false
    ) -> Delivery {
        reportOwed(id)
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
            prepare: preparation,
            finish: { attempt, candidate in
                // The attempt's decision is captured before any callout. A callout, such as an
                // Observation reader, can reconcile again, and each attempt must report its own
                // decision once.
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
                    self.reconciliationRequired(pending)
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
        reportOwed(id)
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
        admissionClosed = true
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
            ready.prune(keeping: ledger.pending.map(\.id))
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
        Task { @MainActor in self.drainTurn() }
    }
    private func drainTurn() {
        pruneClosedSubscribers()
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
            // Advance each registration before callbacks so synchronous reentry cannot regress it.
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
            // A closed gate keeps a registration cancelled from another thread from receiving later callbacks.
            for observer in observers where observer.gate.isOpen {
                observer.receive(batch.snapshot)
                if batch.terminal, observer.gate.isOpen { observer.finish() }
            }
        }
        Task { @MainActor in
            await Task.yield()
            self.drainTurn()
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
        retainDisplaceable()
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
    // Reports a batch of capacity conflicts, each as captured when it was found. A handler that
    // reconciles a later entry synchronously makes that entry's report first, so each completion's
    // attempts are reported in order and once each.
    private func handleCapacityConflicts(_ conflicts: [Ledger.Pending]) {
        CapacityConflictPause.reached(conflicts, \.id)
        guard case .manual = policy else {
            for pending in conflicts { _ = scheduleRetry(pending.id, after: pending.decision) }
            return
        }
        for serial in owed.owe(conflicts) {
            for pending in owed.take(through: serial) { reconciliationRequired(pending) }
        }
    }
    // Makes the reports still owed for `id` before anything else happens to that completion.
    private func reportOwed(_ id: RuntimePendingID) {
        for pending in owed.take(id) { reconciliationRequired(pending) }
    }
    // Scheduling is bound to the decision that lost the conflict, so a newer attempt keeps its own.
    // An envelope that used its last turn parks, and that is when reconciliation is required.
    private func scheduleRetry(_ id: RuntimePendingID, after decision: RuntimeDeliveryDecision) -> Bool {
        switch ledger.scheduleRetry(id, after: decision) {
        case .scheduled: break
        case .superseded: return false
        case .exhausted:
            reportOwed(id)
            if let pending = ledger.pending.first(where: { $0.id == id }) { reconciliationRequired(pending) }
            return false
        }
        guard ready.enqueue(id) else { return true }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.retryTurn()
        }
        return true
    }
    private func retryTurn() {
        pruneClosedSubscribers()
        ready.prune(keeping: ledger.pending.map(\.id))
        let ids = ready.takeRound()
        for id in ids { _ = reconcile(id: id, automatic: true, scheduledRetry: true) }
        if ready.finishRound() {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.retryTurn()
            }
        }
        changed()
    }
    private func changed() {
        publishPending()
        let prior = waiters
        waiters = []
        for waiter in prior { waiter.resume() }
        publishObservation()
        releaseDisplaced()
    }
    /// Reports each tracked value that changed since its token last reported, after the change is complete.
    ///
    /// Observation runs tracking callbacks synchronously, so this runs only outside engine mutation.
    private func publishObservation() {
        let revision = engine.snapshot.revision
        let running = entries.count
        let subscribed = openSubscriberCount
        let generation = ledger.generation
        var changes: [RuntimeObservation.Token] = []
        if revision != observedRevision {
            observedRevision = revision
            changes.append(.snapshot)
        }
        if observedRunningCount.report(running) { changes.append(.runningCount) }
        if observedSubscriberCount.report(subscribed) { changes.append(.subscriberCount) }
        if generation != observedPendingGeneration {
            observedPendingGeneration = generation
            changes.append(.pendingCompletions)
        }
        for token in changes { observation.changed(token) }
    }
    /// Offers the retained completions to each pending-completion registration that has not yet received
    /// the current collection, its first included, and ends every registration with the final, empty
    /// collection once the owner is closed.
    ///
    /// Publications never nest. A callback that changes the collection, or registers another observer,
    /// leaves it to this publication, which stops offering the older collection and offers the newer one
    /// to every registration, so each registration receives collections in ledger order and the newest
    /// one last, even when the change happens inside the callback that receives its first collection.
    private func publishPending() {
        guard !publishingPending else { return }
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
    /// The number of physical workers whose joined termination has not yet been processed, registering
    /// the read with Observation tracking.
    public var runningCount: Int {
        observation.access(.runningCount)
        let running = entries.count
        observedRunningCount.read(running)
        return running
    }
    /// The number of live observer registrations, registering the read with Observation tracking.
    ///
    /// A registration whose token is released on another thread stops counting at once, before this
    /// host removes it on the main actor, so a read can see the count fall before the host reports the
    /// change; the host reports it once it next publishes, also when an admission in that turn brings
    /// the count back to the value it last reported.
    public var subscriberCount: Int {
        observation.access(.subscriberCount)
        let subscribed = openSubscriberCount
        observedSubscriberCount.read(subscribed)
        return subscribed
    }
    private var openSubscriberCount: Int {
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
    /// same main-actor turn that found the deadline expired; that work stays tracked and can still settle.
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

/// The values of one count that Observation readers may have seen since its token last reported a
/// change.
nonisolated private struct ObservedCount {
    private var lowest: Int
    private var highest: Int

    init(_ value: Int) {
        lowest = value
        highest = value
    }
    /// Records a value that a reader saw.
    mutating func read(_ value: Int) {
        lowest = min(lowest, value)
        highest = max(highest, value)
    }
    /// Reports whether `value` differs from any value a reader may have seen, and starts again from it.
    mutating func report(_ value: Int) -> Bool {
        defer {
            lowest = value
            highest = value
        }
        return lowest != value || highest != value
    }
}
