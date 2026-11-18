/// A reusable managed shared host for generated sealed facades.
///
/// This lower-guarantee runtime accepts raw tickets and candidates. A facade keeps
/// its host private and supplies compiler-checked typed projections. User preparation
/// and drivers execute outside immutable-version installation locks.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
nonisolated public struct RuntimeSharedHost<Model: Sendable, Descriptor: Sendable, Outcome: Sendable, Failure: Error>:
    Sendable
{
    /// The associated raw value engine.
    public typealias Engine = RuntimeState<Model, Descriptor>
    /// The common first-envelope and single-claim algorithm.
    public typealias Ledger = RuntimeDeliveryLedger<Model, Descriptor, Outcome, Failure>
    /// A closed retained-outcome decision.
    @frozen public enum Delivery: Sendable {
        case committed(Engine.Snapshot)
        case pending(RuntimePendingID, PendingStatus)
        case inProgress
        case notPending
        case stale
        case foreignOwner
        case discarded(Engine.Snapshot)
        case rejected(Engine.Rejection)
    }
    fileprivate struct Subscriber: Sendable {
        let identity: RuntimeIdentity
        let mailbox: LatestMailbox<Engine.Snapshot>
    }
    private struct Processor: Sendable {
        let cancel: @Sendable ([RuntimeTicket]) async -> Void
        let start: @Sendable ([RuntimeWork<Descriptor>]) async -> Void
        let processed: @Sendable (Engine.Batch) async -> Void
    }
    fileprivate struct State: Sendable {
        var subscribers: [Subscriber] = []
        var engine: Engine
        var ledger = Ledger()
        var drainerScheduled = false
        var ready = RuntimeDeliveryReadyQueue()
        var processedRevision: UInt64 = 0
        var isQuiescent: Bool { engine.isQuiescent && !drainerScheduled && ready.isIdle }
        mutating func prune() {
            ledger.prune(in: engine)
            ready.prune(keeping: ledger.pending.map(\.id))
        }
        mutating func retryCapacity() -> [Ledger.Pending] {
            let results = ledger.retryCapacity(in: &engine)
            prune()
            return results.compactMap { result in
                guard case .pending(let id, .reconciliationRequired) = result,
                    let pending = ledger.pending.first(where: { $0.id == id }),
                    case .admission(.conflict) = pending.lastRejection
                else { return nil }
                return pending
            }
        }
    }
    private actor Progress {
        var waiters: [(RuntimeIdentity, CheckedContinuation<Void, Never>)] = []
        private func wake(_ identity: RuntimeIdentity) {
            guard let index = waiters.firstIndex(where: { $0.0 === identity }) else { return }
            waiters.remove(at: index).1.resume()
        }
        func wait(until predicate: @Sendable () -> Bool, deadline: ContinuousClock.Instant? = nil) async {
            guard !predicate() else { return }
            let identity = RuntimeIdentity()
            let timer: Task<Void, Never>?
            if let deadline {
                timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.wake(identity)
                }
            } else {
                timer = nil
            }
            await withCheckedContinuation { waiters.append((identity, $0)) }
            timer?.cancel()
        }
        func changed() {
            let previous = waiters
            waiters = []
            for waiter in previous { waiter.1.resume() }
        }
    }
    private let storage: AtomicRecordStorage<State>
    private let coordinator: RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>?
    private let processor: Processor?
    private let subscriberCapacity: Int
    private let progress: Progress
    private let policy: RuntimeCompletionPolicy
    private let ticket: @Sendable (Outcome) -> RuntimeTicket
    private let prepare: @Sendable (Ledger.Attempt) -> Ledger.Preparation
    private let reconciliationRequired: @Sendable (Ledger.Pending) -> Void

    /// Creates a raw managed history with immutable execution and preparation hooks.
    ///
    /// The reconciliation callback receives a historical typed record after installation,
    /// outside the core lock. Pure automatic conflict retries do not emit manual events.
    public init(
        _ initial: Model,
        scopes: [RuntimeScopeID],
        limits: Limits,
        subscriberCapacity: Int = 128,
        policy: RuntimeCompletionPolicy = .manualOnConflict,
        driver: @escaping @Sendable (RuntimeWork<Descriptor>) async -> Outcome,
        ticket: @escaping @Sendable (Outcome) -> RuntimeTicket,
        prepare: @escaping @Sendable (Ledger.Attempt) -> Ledger.Preparation,
        reconciliationRequired: @escaping @Sendable (Ledger.Pending) -> Void = { _ in }
    ) {
        let storage = AtomicRecordStorage(State(engine: Engine(initial, scopes: scopes, limits: limits)))
        let progress = Progress()
        let coordinator = RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>(
            driver: driver,
            authorized: { [weak storage] ticket in storage?.load().value.engine.isActive(ticket) ?? false },
            terminated: { [weak storage] execution, outcome, coordinator in
                guard let storage else { return }
                let host = Self(
                    storage: storage,
                    coordinator: coordinator,
                    progress: progress,
                    policy: policy,
                    ticket: ticket,
                    prepare: prepare,
                    subscriberCapacity: subscriberCapacity,
                    reconciliationRequired: reconciliationRequired
                )
                _ = host.acknowledge(execution, skipped: false)
                _ = host.deliver(outcome)
            },
            skipped: { [weak storage] execution in
                guard let storage else { return }
                while true {
                    let before = storage.load()
                    var after = before.value
                    let result = after.engine.acknowledge(execution, skippedBeforeStart: true)
                    if result != .recorded {
                        if storage.isCurrent(before) { break }
                    } else if storage.install(.init(after), replacing: before) {
                        break
                    }
                }
                Task { await progress.changed() }
            }
        )
        self.init(
            storage: storage,
            coordinator: coordinator,
            progress: progress,
            policy: policy,
            ticket: ticket,
            prepare: prepare,
            subscriberCapacity: subscriberCapacity,
            reconciliationRequired: reconciliationRequired
        )
    }
    private init(
        storage: AtomicRecordStorage<State>,
        coordinator: RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>,
        progress: Progress,
        policy: RuntimeCompletionPolicy,
        ticket: @escaping @Sendable (Outcome) -> RuntimeTicket,
        prepare: @escaping @Sendable (Ledger.Attempt) -> Ledger.Preparation,
        subscriberCapacity: Int,
        reconciliationRequired: @escaping @Sendable (Ledger.Pending) -> Void
    ) {
        self.storage = storage
        self.coordinator = coordinator
        processor = Processor(
            cancel: { await coordinator.cancel($0) },
            start: { await coordinator.start($0.map { .init(descriptor: $0, ticket: $0.ticket) }) },
            processed: { _ in }
        )
        self.subscriberCapacity = subscriberCapacity
        self.progress = progress
        self.policy = policy
        self.ticket = ticket
        self.prepare = prepare
        self.reconciliationRequired = reconciliationRequired
    }
    /// Creates a manually driven raw host or a host with explicit FIFO processing hooks.
    package init(
        manual initial: Model,
        scopes: [RuntimeScopeID],
        limits: Limits,
        subscriberCapacity: Int = 128,
        cancel: (@Sendable ([RuntimeTicket]) async -> Void)? = nil,
        start: (@Sendable ([RuntimeWork<Descriptor>]) async -> Void)? = nil,
        processed: (@Sendable (Engine.Batch) async -> Void)? = nil,
        ticket: @escaping @Sendable (Outcome) -> RuntimeTicket,
        prepare: @escaping @Sendable (Ledger.Attempt) -> Ledger.Preparation
    ) {
        storage = AtomicRecordStorage(State(engine: Engine(initial, scopes: scopes, limits: limits)))
        coordinator = nil
        if cancel != nil || start != nil || processed != nil {
            processor = Processor(
                cancel: cancel ?? { _ in },
                start: start ?? { _ in },
                processed: processed ?? { _ in }
            )
        } else {
            processor = nil
        }
        self.subscriberCapacity = subscriberCapacity
        progress = Progress()
        policy = .manualOnConflict
        self.ticket = ticket
        self.prepare = prepare
        reconciliationRequired = { _ in }
    }
    /// Registers a capacity-one latest-value callback; client execution occurs outside host locks.
    public func subscribe(
        _ receive: @escaping @Sendable (Engine.Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {}
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        let identity = RuntimeIdentity()
        while true {
            let before = storage.load()
            var after = before.value
            let snapshot = after.engine.snapshot
            let mailbox = LatestMailbox(
                initial: snapshot,
                revision: snapshot.revision,
                terminal: snapshot.isClosed,
                receive: receive,
                finish: onFinish
            )
            if !snapshot.isClosed {
                guard after.subscribers.count < subscriberCapacity else { throw .capacityExceeded }
                after.subscribers.append(Subscriber(identity: identity, mailbox: mailbox))
            }
            let installed =
                snapshot.isClosed ? storage.isCurrent(before) : storage.install(.init(after), replacing: before)
            guard installed else { continue }
            mailbox.activate()
            return SnapshotSubscription { [weak storage, weak mailbox] in
                mailbox?.cancel()
                guard let storage else { return }
                while true {
                    let previous = storage.load()
                    var next = previous.value
                    next.subscribers.removeAll { $0.identity === identity }
                    if next.subscribers.count == previous.value.subscribers.count { return }
                    if storage.install(.init(next), replacing: previous) { return }
                }
            }
        }
    }
    private func publish(_ snapshot: Engine.Snapshot, to subscribers: [Subscriber]) {
        for subscriber in subscribers {
            subscriber.mailbox.offer(snapshot, revision: snapshot.revision, terminal: snapshot.isClosed)
        }
    }
    /// Captures a coherent historical root.
    public func snapshot() -> Engine.Snapshot { storage.load().value.engine.snapshot }
    /// Consumes an immutable candidate into one atomic root, authority, and FIFO publication.
    public func commit(_ candidate: Engine.Candidate) -> Engine.Admission {
        while true {
            let before = storage.load()
            var after = before.value
            let result = after.engine.commit(candidate)
            if case .rejected = result {
                if storage.isCurrent(before) { return result }
                continue
            }
            after.prune()
            let wake = processor != nil && !after.drainerScheduled
            if processor != nil { after.drainerScheduled = true }
            if storage.install(.init(after), replacing: before) {
                if wake { scheduleDrain() }
                if processor == nil, case .committed(let snapshot) = result { publish(snapshot, to: after.subscribers) }
                return result
            }
        }
    }
    /// Reports a defective plan with ordinary admission precedence against the current root.
    public func reject(_ defect: Engine.DefectivePlan) -> Engine.Admission {
        storage.load().value.engine.reject(defect)
    }
    /// Ends admission and schedules the reserved terminal batch.
    public func close() -> Engine.Snapshot {
        while true {
            let before = storage.load()
            if before.value.engine.snapshot.isClosed {
                if storage.isCurrent(before) { return before.value.engine.snapshot }
                continue
            }
            var after = before.value
            let snapshot = after.engine.close()
            let subscribers = after.subscribers
            if processor == nil { after.subscribers = [] }
            after.prune()
            let wake = processor != nil && !after.drainerScheduled
            if processor != nil { after.drainerScheduled = true }
            if storage.install(.init(after), replacing: before) {
                if wake { scheduleDrain() }
                if processor == nil { publish(snapshot, to: subscribers) }
                return snapshot
            }
        }
    }
    /// The first retained typed envelopes, without acquiring preparation claims.
    public func pendingCompletions() -> [Ledger.Pending] { storage.load().value.ledger.pending }
    /// Retains the first terminal outcome; duplicate offers keep that first payload.
    public func deliver(_ outcome: Outcome) -> Delivery {
        let authority = ticket(outcome)
        while true {
            let before = storage.load()
            var after = before.value
            let retention = after.ledger.retain(outcome, for: authority, in: &after.engine)
            switch retention {
            case .foreignOwner: return .foreignOwner
            case .stale:
                if storage.isCurrent(before) { return .stale }
            case .pending(let id):
                guard let pending = after.ledger.pending.first(where: { $0.id == id }) else { continue }
                let existing = before.value.ledger.pending.contains { $0.id == id }
                if existing {
                    if storage.isCurrent(before) { return .pending(id, pending.status) }
                } else if storage.install(.init(after), replacing: before) {
                    return reconcile(id: id, automatic: true)
                }
            }
        }
    }
    /// Claims exactly one fresh preparation attempt for a retained first outcome.
    public func reconcile(id: RuntimePendingID) -> Delivery { reconcile(id: id, automatic: false) }
    private func reconcile(id: RuntimePendingID, automatic: Bool, scheduledRetry: Bool = false) -> Delivery {
        // Only the first claim of a queued turn depends on the decision that queued it.
        var scheduledClaim = scheduledRetry
        let result = Ledger.reconcile(
            id,
            policy: policy,
            automatic: automatic,
            claim: { decision in
                while true {
                    let before = storage.load()
                    var after = before.value
                    let result = after.ledger.claim(
                        id,
                        in: &after.engine,
                        continuing: decision,
                        scheduledRetry: scheduledClaim
                    )
                    if case .claimed = result {
                        if storage.install(.init(after), replacing: before) {
                            scheduledClaim = false
                            return result
                        }
                    } else if storage.isCurrent(before) {
                        scheduledClaim = false
                        return result
                    }
                }
            },
            prepare: prepare,
            finish: { attempt, preparation in
                while true {
                    let before = storage.load()
                    var after = before.value
                    let result = after.ledger.finish(attempt, preparation: preparation, in: &after.engine)
                    after.prune()
                    // Finishing a superseded claim may free the last reservation.
                    let conflicts = after.retryCapacity()
                    let wake = processor != nil && after.engine.hasQueuedBatches && !after.drainerScheduled
                    if wake { after.drainerScheduled = true }
                    let pending = after.ledger.pending.first { $0.id == id }
                    let reason = pending?.lastRejection
                    if storage.install(.init(after), replacing: before) {
                        if wake { scheduleDrain() }
                        handleCapacityConflicts(conflicts.filter { $0.id != id })
                        Task { await progress.changed() }
                        let automaticConflict: Bool
                        if automatic, case .retryPure = policy, case .admission(.conflict) = reason {
                            automaticConflict = true
                        } else {
                            automaticConflict = false
                        }
                        if !automaticConflict, let pending,
                            pending.status == .reconciliationRequired
                        {
                            reconciliationRequired(pending)
                        }
                        return (result, pending)
                    }
                }
            },
            scheduleRetry: scheduleRetry
        )
        switch result {
        case .inProgress: return .inProgress
        case .notPending: return .notPending
        case .finished(let finish):
            switch finish {
            case .committed(let snapshot): return .committed(snapshot)
            case .pending(let id, let status): return .pending(id, status)
            case .notPending: return .notPending
            }
        }
    }
    /// Discards retained delivery by an authority-only atomic admission.
    public func discardPending(id: RuntimePendingID) -> Delivery {
        while true {
            let before = storage.load()
            var after = before.value
            guard let result = after.ledger.discard(id, in: &after.engine) else {
                if storage.isCurrent(before) { return .notPending }
                continue
            }
            if case .rejected(let reason, _) = result {
                if storage.isCurrent(before) { return .rejected(reason) }
                continue
            }
            after.prune()
            let wake = processor != nil && !after.drainerScheduled
            if processor != nil { after.drainerScheduled = true }
            if storage.install(.init(after), replacing: before) {
                if wake { scheduleDrain() }
                if case .committed(let snapshot) = result { return .discarded(snapshot) }
            }
        }
    }
    /// Records actual execution termination, or a skip before the execution started.
    package func acknowledge(_ ticket: RuntimeTicket, skipped: Bool) -> Engine.Acknowledgment {
        while true {
            let before = storage.load()
            var after = before.value
            let result = after.engine.acknowledge(ticket, skippedBeforeStart: skipped)
            guard result == .recorded else {
                if storage.isCurrent(before) { return result }
                continue
            }
            let conflicts = processor != nil ? after.retryCapacity() : []
            let wake = processor != nil && after.engine.hasQueuedBatches && !after.drainerScheduled
            if wake { after.drainerScheduled = true }
            if storage.install(.init(after), replacing: before) {
                if wake { scheduleDrain() }
                handleCapacityConflicts(conflicts)
                Task { await progress.changed() }
                return result
            }
        }
    }
    /// Checks live raw authority without granting a facade ticket.
    package func isActive(_ ticket: RuntimeTicket) -> Bool { storage.load().value.engine.isActive(ticket) }
    /// Transfers complete batches only from a manually driven host.
    package func drainCommands(limit: Int) -> [Engine.Batch] {
        guard processor == nil else { return [] }
        while true {
            let before = storage.load()
            var after = before.value
            let batches = after.engine.drain(limit: limit)
            if batches.isEmpty {
                if storage.isCurrent(before) { return [] }
            } else if storage.install(.init(after), replacing: before) {
                return batches
            }
        }
    }
    private func scheduleDrain() { Task { await drainTurn() } }
    private func drainTurn() async {
        guard let processor else { return }
        var count = 0
        while count < 32 {
            let before = storage.load()
            var after = before.value
            let batches = after.engine.drain(limit: 1)
            let conflicts = after.retryCapacity()
            guard let batch = batches.first else {
                let again = after.engine.hasQueuedBatches
                after.drainerScheduled = again
                guard storage.install(.init(after), replacing: before) else { continue }
                handleCapacityConflicts(conflicts)
                if again { continue }
                await progress.changed()
                return
            }
            let subscribers = after.subscribers
            if batch.terminal { after.subscribers = [] }
            guard storage.install(.init(after), replacing: before) else { continue }
            handleCapacityConflicts(conflicts)
            let cancellations = batch.commands.compactMap { command -> RuntimeTicket? in
                if case .cancel(let ticket) = command { return ticket }
                return nil
            }
            let works = batch.commands.compactMap { command -> RuntimeWork<Descriptor>? in
                if case .start(let work) = command { return work }
                return nil
            }
            await processor.cancel(cancellations)
            publish(batch.snapshot, to: subscribers)
            await processor.start(works)
            await processor.processed(batch)
            while true {
                let previous = storage.load()
                var next = previous.value
                next.processedRevision = batch.snapshot.revision
                if storage.install(.init(next), replacing: previous) { break }
            }
            Task { await progress.changed() }
            count += 1
        }
        Task {
            await Task.yield()
            await drainTurn()
        }
    }
    private func handleCapacityConflicts(_ conflicts: [Ledger.Pending]) {
        for pending in conflicts {
            switch policy {
            case .retryPure: _ = scheduleRetry(pending.id, after: pending.decision)
            case .manualOnConflict: reconciliationRequired(pending)
            }
        }
    }
    // Scheduling is bound to the decision that lost the conflict, so a newer attempt keeps its own.
    private func scheduleRetry(_ id: RuntimePendingID, after decision: RuntimeDeliveryDecision) -> Bool {
        while true {
            let before = storage.load()
            var after = before.value
            guard after.ledger.scheduleRetry(id, after: decision) else {
                if storage.isCurrent(before) { return false }
                continue
            }
            let wake = after.ready.enqueue(id)
            if storage.install(.init(after), replacing: before) {
                if wake {
                    Task {
                        await Task.yield()
                        await retryTurn()
                    }
                }
                return true
            }
        }
    }
    private func retryTurn() async {
        let ids: [RuntimePendingID]
        while true {
            let before = storage.load()
            var after = before.value
            after.prune()
            let round = after.ready.takeRound()
            if storage.install(.init(after), replacing: before) {
                ids = round
                break
            }
        }
        for id in ids { _ = reconcile(id: id, automatic: true, scheduledRetry: true) }
        while true {
            let before = storage.load()
            var after = before.value
            let again = after.ready.finishRound()
            if storage.install(.init(after), replacing: before) {
                if again {
                    Task {
                        await Task.yield()
                        await retryTurn()
                    }
                }
                await progress.changed()
                return
            }
        }
    }
    /// Waits until managed FIFO cancellation and launch decisions through this receipt have been processed.
    ///
    /// Returns `false` without waiting when the receipt belongs to another owner. For a raw manually
    /// driven host, this checks owner identity only; its caller owns execution.
    public func flush(through snapshot: Engine.Snapshot) async -> Bool {
        guard storage.load().value.engine.owns(snapshot) else { return false }
        guard processor != nil else { return true }
        while storage.load().value.processedRevision < snapshot.revision {
            await progress.wait { storage.load().value.processedRevision >= snapshot.revision }
        }
        return true
    }
    /// Whether closure, batches, retained outcomes, preparations, and physical executions have settled.
    public var isQuiescent: Bool { storage.load().value.isQuiescent }
    /// The number of physical workers whose joined termination has not yet been processed.
    public var runningCount: Int { get async { await coordinator?.runningCount ?? 0 } }
    /// The number of live observer registrations.
    public var subscriberCount: Int { storage.load().value.subscribers.count }
    /// Outstanding raw obligations at a coherent historical observation, with execution authority.
    package struct Diagnostics: Sendable {
        /// The last accepted revision.
        package let acceptedRevision: UInt64
        /// The revision of the last fully processed FIFO batch.
        package let processedThrough: UInt64
        /// Whether FIFO batches await transfer.
        package let hasQueuedBatches: Bool
        /// Whether a drainer still owns responsibility.
        package let isDraining: Bool
        /// Whether an automatic retry of a retained completion is still scheduled.
        package let isRetrying: Bool
        /// First retained envelopes.
        package let pending: [RuntimePendingID]
        /// Physical execution, delivery, and preparation obligations.
        package let outstanding: [Engine.ReservationSnapshot]

        fileprivate init(_ state: State) {
            acceptedRevision = state.engine.snapshot.revision
            processedThrough = state.processedRevision
            hasQueuedBatches = state.engine.hasQueuedBatches
            isDraining = state.drainerScheduled
            isRetrying = !state.ready.isIdle
            pending = state.ledger.pending.map(\.id)
            outstanding = state.engine.executionReservations
        }
    }
    private static func diagnostics(of state: State) -> ShutdownDiagnostics {
        ShutdownDiagnostics(
            engine: state.engine,
            processedThrough: state.processedRevision,
            isDraining: state.drainerScheduled,
            isRetrying: !state.ready.isIdle,
            pendingCompletions: state.ledger.pending.map(\.id)
        )
    }
    /// Captures the obligations still tracked, without exposing a ticket or other authority.
    package func diagnostics() -> ShutdownDiagnostics { Self.diagnostics(of: storage.load().value) }
    /// Closes admission, then waits until every obligation settles or `deadline` passes.
    ///
    /// Returns `nil` once the owner is quiescent. Otherwise it returns the obligations observed in one
    /// atomic load taken after the deadline passed, which also decided that they were unsettled; that
    /// work stays tracked and can still settle.
    /// A manually driven host does not wait: it closes and reports what it observes at once.
    @discardableResult
    public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownDiagnostics? {
        await shutdown(deadline: deadline, now: { ContinuousClock.now })
    }
    /// Closes and waits exactly as ``shutdown(deadline:)``, reading the time from `now`.
    package func shutdown(
        deadline: ContinuousClock.Instant?,
        now: () -> ContinuousClock.Instant
    ) async -> ShutdownDiagnostics? {
        await settle(deadline: deadline, now: now).map(Self.diagnostics(of:))
    }
    /// Closes and waits exactly as ``shutdown(deadline:)``, reporting a timeout with execution authority.
    package func shutdownWithAuthority(deadline: ContinuousClock.Instant? = nil) async -> Diagnostics? {
        await settle(deadline: deadline, now: { ContinuousClock.now }).map(Diagnostics.init)
    }
    private func settle(deadline: ContinuousClock.Instant?, now: () -> ContinuousClock.Instant) async -> State? {
        let receipt = close()
        let managed = processor != nil
        let settled: @Sendable (State) -> Bool = { state in
            state.isQuiescent && (!managed || state.processedRevision >= receipt.revision)
        }
        while true {
            var state = storage.load().value
            if !settled(state), managed, let deadline, now() >= deadline {
                // Work can settle between that load and observing expiry, so the decision and its
                // diagnostics come from one load taken after the deadline passed.
                state = storage.load().value
                if !settled(state) { return state }
            }
            if settled(state) {
                // Termination is acknowledged after a worker leaves the coordinator, so this returns at once.
                await coordinator?.join()
                return nil
            }
            if !managed { return state }
            await progress.wait(until: { settled(storage.load().value) }, deadline: deadline)
        }
    }
}

/// Explicit cancellation ownership of one observer registration.
///
/// Cancelling or releasing it removes the registration.
nonisolated public final class SnapshotSubscription: Sendable {
    private let action: AtomicRecordStorage<(@Sendable () -> Void)?>
    package init(_ action: @escaping @Sendable () -> Void) { self.action = AtomicRecordStorage(action) }
    /// Removes the registration; a callback already claimed may finish.
    public func cancel() {
        while true {
            let before = action.load()
            guard let callback = before.value else { return }
            if action.install(.init(nil), replacing: before) {
                callback()
                return
            }
        }
    }
    deinit { action.load().value?() }
}
