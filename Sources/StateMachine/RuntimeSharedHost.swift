import os

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
    fileprivate struct PendingSubscriber: Sendable {
        let identity: RuntimeIdentity
        let mailbox: LatestMailbox<[Ledger.Pending]>
    }
    // The owner's lifetime: every copy of the host shares it, and nothing else retains it. A
    // cancellation, a delivery, or a worker's termination can keep `storage` and one of its versions
    // for as long as it runs, but never this, so its destructor is the owner's release.
    //
    // Every host tears down in the same order, after the batches it accepted have drained: the drain
    // retains a copy of the host until then. (1) Unless the owner closed, the lifetime gate closes, once,
    // before any registration is notified, so every publisher of the owner learns of the release at the same instant and none
    // can begin an ordinary delivery after another has finished for it; then every registration learns
    // that the owner is released, which wakes a publisher on the main actor and lets a sequence finish
    // after its unread element; (2) the workers are cancelled; (3) client callbacks and values are
    // released. Here the destructor does (1), then releases the coordinator, whose destructor does (2);
    // the registrations' callbacks and the host's own closures, (3), go after it, with the last version
    // of `storage` and the host's stored properties, on whichever thread drops them.
    private final class Lifetime: Sendable {
        let storage: AtomicRecordStorage<State>
        /// Open until the owner is released without closing; every publisher of the owner reads it.
        let ownerLifetime = RuntimeRegistrationGate()
        // The coordinator's only strong reference, set once at creation.
        private let workers = OSAllocatedUnfairLock<RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>?>(
            initialState: nil
        )

        init(_ storage: AtomicRecordStorage<State>) { self.storage = storage }

        var coordinator: RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>? { workers.withLock { $0 } }
        func adopt(_ coordinator: RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>) {
            workers.withLock { $0 = coordinator }
        }
        deinit {
            let state = storage.load().value
            // A closed owner's publishers finish after its closed snapshot, which may still be on its way.
            if !state.engine.snapshot.isClosed { ownerLifetime.close() }
            for subscriber in state.subscribers {
                subscriber.mailbox.release()
                ReleaseNoticePause.reached()
            }
            for subscriber in state.pendingSubscribers { subscriber.mailbox.release() }
            // Taken and released here, which is its last reference.
            _ = workers.withLock { $0.take() }
        }
    }
    private struct Processor: Sendable {
        let cancel: @Sendable ([RuntimeTicket]) async -> Void
        let start: @Sendable ([RuntimeWork<Descriptor>]) async -> Void
        let processed: @Sendable (Engine.Batch) async -> Void
    }
    fileprivate struct State: Sendable {
        var subscribers: [Subscriber] = []
        var pendingSubscribers: [PendingSubscriber] = []
        var engine: Engine
        var ledger = Ledger()
        var drainerScheduled = false
        var ready = RuntimeDeliveryReadyQueue()
        var processedRevision: UInt64 = 0
        var isQuiescent: Bool { engine.isQuiescent && !drainerScheduled && ready.isIdle }
        /// Live snapshot and pending-completion registrations, which share one capacity.
        ///
        /// A registration whose gate has closed is ending and holds no slot, though its token may still
        /// be removing it.
        var registrations: Int {
            subscribers.filter(\.mailbox.gate.isOpen).count + pendingSubscribers.filter(\.mailbox.gate.isOpen).count
        }
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
    private let lifetime: Lifetime
    private var coordinator: RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>? { lifetime.coordinator }
    /// Open until the owner is released without closing, which closes it before it notifies any
    /// registration: every publisher of the owner reads it, so all of them learn of the release at one
    /// instant.
    package var ownerLifetime: RuntimeRegistrationGate { lifetime.ownerLifetime }
    private let processor: Processor?
    private let subscriberCapacity: Int
    private let progress: Progress
    private let policy: RuntimeCompletionPolicy
    private let ticket: @Sendable (Outcome) -> RuntimeTicket
    private let prepare: @Sendable (Ledger.Attempt) -> Ledger.Preparation
    private let reconciliationRequired: @Sendable (Ledger.Pending) -> Void
    // The capacity-conflict reports captured and not yet made, which every copy of the host shares.
    private let owed = OSAllocatedUnfairLock(initialState: Ledger.OwedReports())
    private let emit: @Sendable (Descriptor) -> Void

    /// Creates a raw managed history with immutable execution and preparation hooks.
    ///
    /// The reconciliation callback receives a historical typed record after installation,
    /// outside the core lock. Pure automatic conflict retries do not emit manual events.
    /// `emit` receives each accepted emission in commit order from the serial FIFO turn that
    /// processes its batch, after that batch's cancellations and before its observers and launch
    /// decisions, outside every lock.
    public init(
        _ initial: Model,
        scopes: [RuntimeScopeID],
        limits: Limits,
        subscriberCapacity: Int = 128,
        policy: RuntimeCompletionPolicy = .manual,
        driver: @escaping @Sendable (RuntimeWork<Descriptor>) async -> Outcome,
        ticket: @escaping @Sendable (Outcome) -> RuntimeTicket,
        prepare: @escaping @Sendable (Ledger.Attempt) -> Ledger.Preparation,
        reconciliationRequired: @escaping @Sendable (Ledger.Pending) -> Void = { _ in },
        emit: @escaping @Sendable (Descriptor) -> Void = { _ in }
    ) {
        let storage = AtomicRecordStorage(State(engine: Engine(initial, scopes: scopes, limits: limits)))
        let lifetime = Lifetime(storage)
        let progress = Progress()
        let coordinator = RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>(
            driver: driver,
            authorized: { [weak storage] ticket in storage?.load().value.engine.isActive(ticket) ?? false },
            // A worker that ends after its owner was released has no owner to report to.
            terminated: { [weak lifetime] execution, outcome, coordinator in
                guard let lifetime else { return }
                let host = Self(
                    lifetime: lifetime,
                    coordinator: coordinator,
                    progress: progress,
                    policy: policy,
                    ticket: ticket,
                    prepare: prepare,
                    subscriberCapacity: subscriberCapacity,
                    reconciliationRequired: reconciliationRequired,
                    emit: emit
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
        lifetime.adopt(coordinator)
        self.init(
            lifetime: lifetime,
            coordinator: coordinator,
            progress: progress,
            policy: policy,
            ticket: ticket,
            prepare: prepare,
            subscriberCapacity: subscriberCapacity,
            reconciliationRequired: reconciliationRequired,
            emit: emit
        )
    }
    private init(
        lifetime: Lifetime,
        coordinator: RuntimeCoordinator<RuntimeWork<Descriptor>, Outcome>,
        progress: Progress,
        policy: RuntimeCompletionPolicy,
        ticket: @escaping @Sendable (Outcome) -> RuntimeTicket,
        prepare: @escaping @Sendable (Ledger.Attempt) -> Ledger.Preparation,
        subscriberCapacity: Int,
        reconciliationRequired: @escaping @Sendable (Ledger.Pending) -> Void,
        emit: @escaping @Sendable (Descriptor) -> Void
    ) {
        storage = lifetime.storage
        self.lifetime = lifetime
        processor = Processor(
            cancel: { [weak coordinator] in await coordinator?.cancel($0) },
            start: { [weak coordinator] in await coordinator?.start($0.map { .init(descriptor: $0, ticket: $0.ticket) })
            },
            processed: { _ in }
        )
        self.subscriberCapacity = subscriberCapacity
        self.progress = progress
        self.policy = policy
        self.ticket = ticket
        self.prepare = prepare
        self.reconciliationRequired = reconciliationRequired
        self.emit = emit
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
        lifetime = Lifetime(storage)
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
        policy = .manual
        self.ticket = ticket
        self.prepare = prepare
        reconciliationRequired = { _ in }
        emit = { _ in }
    }
    /// Registers a capacity-one latest-value callback; client execution occurs outside host locks.
    public func subscribe(
        _ receive: @escaping @Sendable (Engine.Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {}
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        try subscribe(receive, onFinish: onFinish, onRelease: nil)
    }
    /// Registers a callback as ``subscribe(_:onFinish:)`` does, and runs `onRelease` once, at once,
    /// if this owner is released without closing, after the owner's lifetime gate has closed, even
    /// while a delivery is in progress; `onFinish` still follows that delivery.
    package func subscribe(
        _ receive: @escaping @Sendable (Engine.Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {},
        onRelease: (@Sendable () -> Void)?
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        switch try register(receive, onFinish: onFinish, onRelease: onRelease) {
        case .registered(let token): return token
        case .closed(let snapshot):
            // A closed owner registers nothing; its closed snapshot and finish arrive on a later task.
            let mailbox = LatestMailbox(
                initial: snapshot,
                revision: snapshot.revision,
                terminal: true,
                receive: receive,
                finish: onFinish
            )
            mailbox.activate()
            let gate = mailbox.gate
            return SnapshotSubscription(gate: gate) { [weak mailbox] in
                gate.close()
                mailbox?.cancel()
            }
        }
    }
    /// Registers a callback, or reports this owner's closed snapshot without registering or calling
    /// either callback when the owner is closed.
    package func register(
        _ receive: @escaping @Sendable (Engine.Snapshot) -> Void,
        onFinish: @escaping @Sendable () -> Void = {},
        onRelease: (@Sendable () -> Void)? = nil
    ) throws(SubscriptionFailure) -> SnapshotRegistration<Engine.Snapshot> {
        let identity = RuntimeIdentity()
        while true {
            let before = storage.load()
            var after = before.value
            let snapshot = after.engine.snapshot
            if snapshot.isClosed {
                if storage.isCurrent(before) { return .closed(snapshot) }
                continue
            }
            guard after.registrations < subscriberCapacity else { throw .capacityExceeded }
            let mailbox = LatestMailbox(
                initial: snapshot,
                revision: snapshot.revision,
                terminal: false,
                receive: receive,
                finish: onFinish,
                onRelease: onRelease
            )
            after.subscribers.append(Subscriber(identity: identity, mailbox: mailbox))
            guard install(after, replacing: before) else { continue }
            mailbox.activate()
            let gate = mailbox.gate
            return .registered(
                SnapshotSubscription(gate: gate) { [weak storage, weak mailbox] in
                    gate.close()
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
            )
        }
    }
    /// Registers a capacity-one latest-value callback of the retained completions, starting with the
    /// collection current at registration.
    ///
    /// Each later value is the whole collection after a change to it, in the order of those changes,
    /// and a newer one may replace one not yet delivered. Closing delivers a final, empty collection
    /// and then finishes; a closed owner delivers that collection at once. Callbacks run outside every lock.
    package func subscribePending(
        _ receive: @escaping @Sendable ([Ledger.Pending]) -> Void,
        onFinish: @escaping @Sendable () -> Void = {}
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        let identity = RuntimeIdentity()
        while true {
            let before = storage.load()
            var after = before.value
            let closed = after.engine.snapshot.isClosed
            let mailbox = LatestMailbox(
                initial: after.ledger.pending,
                revision: after.ledger.generation,
                terminal: closed,
                order: .generation,
                receive: receive,
                finish: onFinish
            )
            if !closed {
                guard after.registrations < subscriberCapacity else { throw .capacityExceeded }
                after.pendingSubscribers.append(
                    PendingSubscriber(identity: identity, mailbox: mailbox)
                )
            }
            let installed = closed ? storage.isCurrent(before) : storage.install(.init(after), replacing: before)
            guard installed else { continue }
            mailbox.activate()
            let gate = mailbox.gate
            return SnapshotSubscription(gate: gate) { [weak storage, weak mailbox] in
                gate.close()
                mailbox?.cancel()
                guard let storage else { return }
                while true {
                    let previous = storage.load()
                    var next = previous.value
                    next.pendingSubscribers.removeAll { $0.identity === identity }
                    if next.pendingSubscribers.count == previous.value.pendingSubscribers.count { return }
                    if storage.install(.init(next), replacing: previous) { return }
                }
            }
        }
    }
    /// Installs `next` in place of `previous` and, when that changed the retained completions, offers
    /// the new collection to pending-completion registrations, outside the lock.
    ///
    /// An installation whose caller then reports reconciliation installs through `storage` and offers
    /// the collection itself, after those reports, as every host orders them.
    private func install(_ next: State, replacing previous: AtomicRecordStorage<State>.Version) -> Bool {
        guard storage.install(.init(next), replacing: previous) else { return false }
        offerPending(next, after: previous.value)
        return true
    }
    /// Offers the retained completions of installed state `next` to its pending-completion
    /// registrations, when the installation that replaced `previous` changed them.
    ///
    /// The ledger's generation orders the offers, so concurrent installers never deliver an older
    /// collection after a newer one.
    private func offerPending(_ next: State, after previous: State) {
        guard next.ledger.generation != previous.ledger.generation, !next.pendingSubscribers.isEmpty else { return }
        let image = next.ledger.pending
        for subscriber in next.pendingSubscribers {
            subscriber.mailbox.offer(image, revision: next.ledger.generation, terminal: false)
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
            if install(after, replacing: before) {
                if wake { scheduleDrain() }
                if processor == nil, case .committed(let snapshot) = result { publish(snapshot, to: after.subscribers) }
                return result
            }
        }
    }
    /// Replaces the model in a fresh incarnation, revoking all work and disposing every retained completion.
    ///
    /// Without `expected`, it expects no revision, so a concurrent commit cannot make it conflict, and it
    /// rejects only on closure, revision exhaustion, or a full commit queue. With `expected`, it also
    /// rejects unless the owner still holds that root, as the engine's `reset` describes. A rejection
    /// changes nothing.
    public func reset(
        _ model: Model,
        scopes: [RuntimeScopeID],
        expecting expected: Engine.Snapshot? = nil
    )
        -> Engine.Admission
    {
        while true {
            let before = storage.load()
            var after = before.value
            let result = after.engine.reset(model, scopes: scopes, expecting: expected)
            if case .rejected = result {
                if storage.isCurrent(before) { return result }
                continue
            }
            after.prune()
            let wake = processor != nil && !after.drainerScheduled
            if processor != nil { after.drainerScheduled = true }
            if install(after, replacing: before) {
                if wake { scheduleDrain() }
                if processor == nil, case .committed(let snapshot) = result { publish(snapshot, to: after.subscribers) }
                Task { await progress.changed() }
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
            after.ledger.close()
            // Closing ends every pending-completion registration with the final, empty collection.
            let pendingSubscribers = after.pendingSubscribers
            after.pendingSubscribers = []
            let wake = processor != nil && !after.drainerScheduled
            if processor != nil { after.drainerScheduled = true }
            if storage.install(.init(after), replacing: before) {
                if wake { scheduleDrain() }
                if processor == nil { publish(snapshot, to: subscribers) }
                for subscriber in pendingSubscribers {
                    subscriber.mailbox.offer([], revision: after.ledger.generation, terminal: true)
                }
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
                } else if install(after, replacing: before) {
                    // Retention and the first claim are separate installations. An explicit
                    // attempt that finishes in between replaces the retained decision, and this
                    // delivery then reports that attempt's result instead of preparing again.
                    let delivery = reconcile(id: id, automatic: true, retained: pending.decision)
                    guard case .notPending = delivery,
                        let current = storage.load().value.ledger.pending.first(where: { $0.id == id })
                    else { return delivery }
                    return .pending(id, current.status)
                }
            }
        }
    }
    /// Claims exactly one fresh preparation attempt for a retained first outcome.
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
        let result = Ledger.reconcile(
            id,
            policy: policy,
            automatic: automatic,
            retained: retained,
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
                        if install(after, replacing: before) {
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
                        // The attempt reports its own decision, captured above, before any other callout,
                        // then the conflicts its admission found, then the collection it changed.
                        let automaticConflict: Bool
                        if automatic, case .retry = policy, case .admission(.conflict) = reason {
                            automaticConflict = true
                        } else {
                            automaticConflict = false
                        }
                        if !automaticConflict, let pending,
                            pending.status == .reconciliationRequired
                        {
                            reconciliationRequired(pending)
                        }
                        handleCapacityConflicts(conflicts.filter { $0.id != id })
                        offerPending(after, after: before.value)
                        Task { await progress.changed() }
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
        reportOwed(id)
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
            if install(after, replacing: before) {
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
                offerPending(after, after: before.value)
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
            } else if install(after, replacing: before) {
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
                offerPending(after, after: before.value)
                if again { continue }
                await progress.changed()
                return
            }
            let subscribers = after.subscribers
            if batch.terminal { after.subscribers = [] }
            guard storage.install(.init(after), replacing: before) else { continue }
            handleCapacityConflicts(conflicts)
            offerPending(after, after: before.value)
            let cancellations = batch.commands.compactMap { command -> RuntimeTicket? in
                if case .cancel(let ticket) = command { return ticket }
                return nil
            }
            let works = batch.commands.compactMap { command -> RuntimeWork<Descriptor>? in
                if case .start(let work) = command { return work }
                return nil
            }
            await processor.cancel(cancellations)
            // Only this turn processes batches, so emissions reach `emit` once each, in commit order,
            // and before any observer is offered the commit that authored them.
            for command in batch.commands {
                if case .emit(let descriptor) = command { emit(descriptor) }
            }
            publish(batch.snapshot, to: subscribers)
            await processor.start(works)
            await processor.processed(batch)
            while true {
                let previous = storage.load()
                var next = previous.value
                next.processedRevision = batch.snapshot.revision
                if install(next, replacing: previous) { break }
            }
            Task { await progress.changed() }
            count += 1
        }
        Task {
            await Task.yield()
            await drainTurn()
        }
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
        for serial in owed.withLock({ $0.owe(conflicts) }) {
            for pending in owed.withLock({ $0.take(through: serial) }) { reconciliationRequired(pending) }
        }
    }
    // Makes the reports still owed for `id` before anything else happens to that completion.
    private func reportOwed(_ id: RuntimePendingID) {
        for pending in owed.withLock({ $0.take(id) }) { reconciliationRequired(pending) }
    }
    // Scheduling is bound to the decision that lost the conflict, so a newer attempt keeps its own.
    // An envelope that used its last turn parks, and that is when reconciliation is required.
    private func scheduleRetry(_ id: RuntimePendingID, after decision: RuntimeDeliveryDecision) -> Bool {
        while true {
            let before = storage.load()
            var after = before.value
            switch after.ledger.scheduleRetry(id, after: decision) {
            case .scheduled: break
            case .superseded:
                if storage.isCurrent(before) { return false }
                continue
            case .exhausted:
                guard storage.isCurrent(before) else { continue }
                reportOwed(id)
                if let pending = before.value.ledger.pending.first(where: { $0.id == id }) {
                    reconciliationRequired(pending)
                }
                return false
            }
            let wake = after.ready.enqueue(id)
            if install(after, replacing: before) {
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
            if install(after, replacing: before) {
                ids = round
                break
            }
        }
        for id in ids { _ = reconcile(id: id, automatic: true, scheduledRetry: true) }
        while true {
            let before = storage.load()
            var after = before.value
            let again = after.ready.finishRound()
            if install(after, replacing: before) {
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
    /// Waits until managed FIFO cancellation and launch decisions, and emissions, through this receipt
    /// have been processed.
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
    ///
    /// Reading it neither suspends nor takes the host lock, so a synchronous callback can sample
    /// it beside a snapshot. The count is a separate observation from that snapshot.
    public var runningCount: Int { coordinator?.currentRunningCount ?? 0 }
    /// The number of live observer registrations.
    ///
    /// The count is one that held while it was read. Within one version of the state the registrations
    /// are fixed and their gates only close, so counting the open gates gives a value the count passed
    /// through while it read them, provided the version is still current afterward; a registration
    /// added or removed meanwhile makes it count again.
    public var subscriberCount: Int {
        while true {
            let version = storage.load()
            CountReadPause.reached()
            let count = version.value.registrations
            if storage.isCurrent(version) { return count }
        }
    }
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
    // Whether the cancellation has not begun, is running its action now, or has returned, with the
    // continuations of calls that arrived while the action ran. It holds no client value: a call that
    // reads it, from any thread, can never hold the last reference to the action or its captures.
    private enum Stage: Sendable {
        case pending
        case cancelling(then: [@Sendable () -> Void])
        case cancelled
    }
    private struct State: Sendable {
        var stage = Stage.pending
        // The action, until the call that starts the cancellation takes it. Taking it leaves this
        // token without a reference, so that call holds the action's only one and releases it, with
        // everything it captures, before it records that the cancellation has returned.
        var action: (@Sendable () -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>
    /// The gate of the registration a managed owner made, which its admission stops counting once
    /// closed; a holder of the token closes it from any thread before the token's cancellation is
    /// complete.
    package let gate: RuntimeRegistrationGate?
    package init(gate: RuntimeRegistrationGate? = nil, _ action: @escaping @Sendable () -> Void) {
        state = OSAllocatedUnfairLock(initialState: State(action: action))
        self.gate = gate
    }
    /// Creates a registration token for a host of your own, such as a test double or a preview.
    ///
    /// `onCancel` runs exactly once, on whichever thread cancels or releases the token, so a host whose
    /// registrations belong to an actor hops to that actor to remove the registration. The token
    /// releases `onCancel`, and everything it captures, before any call learns that the cancellation
    /// has returned.
    public convenience init(onCancel: @escaping @Sendable () -> Void) { self.init(onCancel) }
    /// Removes the registration; a callback already claimed may finish.
    ///
    /// The registration's gate closes first, so a managed owner stops counting the registration, and
    /// stops beginning its callbacks, before any call returns, including a concurrent call that finds
    /// the cancellation already taken. A call made while another call runs `onCancel`, including one
    /// from inside `onCancel`, returns at once without waiting for it.
    public func cancel() { cancel(then: nil) }
    /// Cancels the token and runs `completion` once its cancellation has returned.
    ///
    /// `completion` runs right after the action when this call runs it, after the action that another
    /// call is running now returns, on that call's thread, or at once when the cancellation has already
    /// returned. The action and everything it captures are released before any completion runs.
    ///
    /// A call made from inside the action, as a host's `onCancel` that ends the sequence does, never
    /// waits: its completion runs once the outer action returns.
    package func cancel(then completion: (@Sendable () -> Void)?) {
        gate?.close()
        var decision = state.withLock { state -> (action: (@Sendable () -> Void)?, now: Bool) in
            switch state.stage {
            case .cancelled:
                return (nil, true)
            case .cancelling(let waiting):
                if let completion { state.stage = .cancelling(then: waiting + [completion]) }
                return (nil, false)
            case .pending:
                state.stage = .cancelling(then: [])
                return (state.action.take(), false)
            }
        }
        // The action leaves the decision, so the call's own reference is its only one once the
        // state no longer holds it, and replacing it releases the captures before the completion.
        guard var action = decision.action.take() else {
            if decision.now { completion?() }
            return
        }
        action()
        action = {}
        let waiting = complete()
        completion?()
        for next in waiting { next() }
    }
    // Records that the action returned and takes the continuations that calls made meanwhile left.
    private func complete() -> [@Sendable () -> Void] {
        state.withLock { state in
            guard case .cancelling(let waiting) = state.stage else { return [] }
            state.stage = .cancelled
            return waiting
        }
    }
    deinit {
        gate?.close()
        let action = state.withLock { $0.action.take() }
        action?()
    }
}
