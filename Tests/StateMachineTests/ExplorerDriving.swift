import Combine
import Dispatch
import Foundation
import StateMachine
import StateMachineUI

/// A one-slot `MainActor` host the explorer controls, for the driving presentations.
///
/// It keeps only a revision, never a client value: each read and each change makes a fresh value. Its
/// subscription frees the slot when its cancellation returns, runs the armed `onCancel` callback on the
/// main thread before that, and releases the subscriber's callbacks. The harness holds it weakly, so its
/// destruction shows when the presentation released it.
@MainActor final class ExplorerMainHost: MainActorStateMachineHost {
    typealias Input = Int
    typealias Snapshot = ExplorerShot
    struct Receipt: StateMachineReceipt {
        let snapshot: ExplorerShot
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    let world: ExplorerWorld
    private var revision: UInt64 = 0
    private var receive: (@MainActor (ExplorerShot) -> Void)?
    private var onFinish: (@MainActor () -> Void)?
    private(set) var token: MainActorSnapshotSubscription?
    private(set) var registration: Int?
    var onCancel: (@MainActor () -> Void)?
    /// Delivers a new value to the subscriber from inside each cancellation, before the slot is free.
    var deliversInCancellation = false

    /// The slot this host admits on: 0 for the driving slice, 2 ("M") as a passive source.
    let index: Int
    /// The next `subscribe` delivers a newer snapshot to the caller and then refuses (E2).
    var refuseNext = false
    /// Values delivered inside a `subscribe` that then refused; none may ever be shown.
    private(set) var refusedOffers: Set<Int> = []
    /// Calls of `subscribe`, admitted or not.
    private(set) var subscribeCalls = 0
    /// The snapshot of the receipt `send` or `close` returned last.
    private(set) var lastReceipt: Int?
    /// Values the host delivered for a change the presentation admitted (`send`, `close`).
    private(set) var admittedThroughPresentation: Set<Int> = []
    private var admitting = false
    /// The revision of the snapshot `subscribe` delivered last, at the moment it returned.
    private(set) var revisionAtSubscribe: UInt64 = 0
    /// The armable sites of this host (`sites` family).
    var site: (@MainActor (ExplorerHook) -> Void)?
    /// Runs with each value the host is about to hand to the presentation: a delivery, a seed, a receipt.
    var handOver: (@MainActor (ExplorerShot) -> Void)?
    /// A registration of the harness's own that holds the slot; it keeps the host alive, as another
    /// client of the owner would, until it ends.
    private var occupant: (token: MainActorSnapshotSubscription, host: ExplorerMainHost)?
    // Set while the harness registers its own occupant, which no ownership invariant counts.
    private var occupying = false

    init(_ world: ExplorerWorld, index: Int = 0) {
        self.world = world
        self.index = index
        world.state.withLock { $0.hostsAlive += 1 }
    }
    // The host is released where its last reference goes; I24 requires that to be the main thread, once
    // its registration's slot is free.
    deinit {
        let onMain = Thread.isMainThread
        world.state.withLock { state in
            state.hostsAlive -= 1
            if !onMain {
                state.violations.append(
                    .init(invariant: .hostReleaseOrder, detail: "the host was released off the main thread")
                )
            }
            let held = state.registrations.values.filter { $0.phase != .freed && !$0.withheld }.map(\.id)
            if !held.isEmpty {
                state.violations.append(
                    .init(
                        invariant: .hostReleaseOrder,
                        detail: "the host was released while registrations \(held) hold its slot"
                    )
                )
            }
        }
    }

    private func value() -> ExplorerShot {
        world.makeValue(.hostRead(host: index), attempt: world.state.withLock { $0.latestAttempt }, revision: revision)
    }
    // A value delivered to the subscriber, which belongs to the registration's attempt.
    private func delivered() -> ExplorerShot {
        guard let registration else { return world.makeValue(.hostRead(host: index), attempt: nil) }
        let shot = world.makeValue(
            .delivered(registration: registration),
            attempt: world.registration(registration)?.attempt
        )
        if admitting { admittedThroughPresentation.insert(shot.id) }
        world.offered(shot.id, into: registration)
        return shot
    }
    /// The revision of the owner's current state.
    var current: UInt64 { revision }
    func snapshot() -> ExplorerShot {
        let read = value()
        site?(.hostRead)
        return read
    }
    func send(_ input: Int) -> Receipt {
        admitting = true
        advance()
        admitting = false
        let receipt = Receipt(snapshot: value())
        lastReceipt = receipt.snapshot.id
        site?(.hostSend)
        handOver?(receipt.snapshot)
        return receipt
    }
    func commit(_ prepared: consuming Never) {}
    private func closedSeed(_ registration: Int) -> ExplorerShot {
        let shot = world.makeValue(
            .delivered(registration: registration),
            attempt: world.registration(registration)?.attempt,
            revision: revision
        )
        world.offered(shot.id, into: registration)
        return shot
    }
    /// The owner admits a change of its own and delivers it to its subscriber.
    ///
    /// Returns the revision it delivered, or `nil` when no subscriber took it.
    @discardableResult func advance() -> UInt64? {
        // A host delivers nothing to a registration it has finished, and a closed one nothing at all.
        if let registration, world.registration(registration)?.finished == true { return nil }
        if closed { return nil }
        let next = delivered()
        let delivered = next.stamp
        revision = delivered
        guard let receive else { return nil }
        handOver?(next)
        receive(next)
        return delivered
    }
    func subscribe(
        _ receive: @escaping @MainActor (ExplorerShot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        subscribeCalls += 1
        if refuseNext {
            // A newer change reaches the caller from inside the call, which then refuses.
            refuseNext = false
            let early = world.makeValue(.hostRead(host: index), attempt: world.state.withLock { $0.latestAttempt })
            refusedOffers.insert(early.id)
            world.note("r\(early.stamp) delivered inside a refused subscribe")
            receive(early)
            site?(.hostSubscribe)
            throw .capacityExceeded
        }
        guard let id = world.admit(host: index) else { throw .capacityExceeded }
        if occupying { world.withhold(id, true) }
        defer { revisionAtSubscribe = revision }
        registration = id
        self.receive = receive
        self.onFinish = onFinish
        // A closed owner's state is final: a later registration's seed is its closed snapshot, at its revision.
        let seed = closed ? closedSeed(id) : delivered()
        revision = seed.stamp
        handOver?(seed)
        receive(seed)
        if closed {
            world.hostEnded(id, finished: true)
            self.onFinish = nil
            onFinish()
        }
        defer { site?(.hostSubscribe) }
        let made = MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            // A host that removes its subscriber itself tells it the registration ended, from inside
            // the cancellation, before the slot is free.
            if cancellingItself, let onFinish = self.onFinish {
                cancellingItself = false
                self.onFinish = nil
                onFinish()
            }
            onCancel?()
            if deliversInCancellation { deliverInCancellation() }
            world.freed(id)
            self.receive = nil
            self.onFinish = nil
        }
        token = made
        return made
    }
    // A change the owner delivers from inside the cancellation; the host's own reference goes right after,
    // before the slot is free. A driving presentation takes such a snapshot and releases it on a later
    // main-actor turn, once the slot is free, so there the host's release is not exempt (the I2 slot
    // rule). A passive presentation of this host as source M promises nothing of the kind.
    private func deliverInCancellation() {
        guard let receive else { return }
        var value: ExplorerShot? = delivered()
        guard let shot = value else { return }
        let valueID = shot.id
        revision = shot.stamp
        world.deliveredInCancellation(valueID)
        receive(shot)
        _ = consume shot
        let exempt = index != 0
        if exempt { world.hostReleasing(valueID, true) }
        value = nil
        if exempt { world.hostReleasing(valueID, false) }
    }
    @discardableResult func close() -> Receipt {
        // Closing is a change of its own, delivered with the finish; later registrations finish at once.
        admitting = true
        let closed = delivered()
        admitting = false
        revision = closed.stamp
        // The owner is closed before any callback of its closing runs, as a real owner installs its closed state
        // before it notifies: a registration made from inside one receives the closed snapshot and finishes.
        self.closed = true
        receive?(closed)
        finish()
        let receipt = Receipt(snapshot: value())
        lastReceipt = receipt.snapshot.id
        site?(.hostClose)
        return receipt
    }
    /// Whether a registration of the harness's own holds the slot.
    var isOccupied: Bool { occupant != nil }
    /// A registration of the harness's own takes the slot, which the presentation then cannot register in.
    func occupy() {
        guard occupant == nil else { return }
        world.setContext(.call(attempt: -2))
        occupying = true
        defer {
            occupying = false
            world.setContext(.spontaneous)
        }
        // The harness's registration replaces nothing the presentation holds: the slot is free.
        guard let token = try? subscribe({ _ in }, onFinish: {}) else { return }
        occupant = (token, self)
    }
    /// The harness's own registration ends and frees the slot.
    func vacate() {
        let held = occupant
        occupant = nil
        held?.token.cancel()
        _ = consume held
    }
    /// Whether the owner has closed: a later registration receives the closed snapshot and finishes
    /// inside `subscribe`.
    private(set) var closed = false
    /// Closes the owner as a passive source: it finishes the current subscriber.
    func closeNow() {
        closed = true
        finish()
    }
    /// The owner finishes its subscriber, as a closing owner does.
    func finish() {
        guard let onFinish else { return }
        if let registration { world.hostEnded(registration, finished: true) }
        self.onFinish = nil
        onFinish()
    }
    /// The owner cancels the subscription it handed out, on the main thread.
    func cancelSubscription() {
        if let registration { world.hostEnded(registration, finished: true) }
        cancellingItself = true
        token?.cancel()
        cancellingItself = false
    }
    private var cancellingItself = false
}

/// One driving presentation under test, reached through closures so both classes share the harness.
@MainActor struct ExplorerDrivingSubject {
    let alive: () -> Bool
    let held: () -> Bool
    /// The presentation, while it is alive, for a client value that captures it.
    let object: () -> (any AnyObject & Sendable)?
    let snapshot: () -> ExplorerShot?
    let isObserving: () -> Bool?
    let failure: () -> SubscriptionFailure?
    let resume: () throws(SubscriptionFailure) -> Void
    let send: () -> ExplorerShot?
    let close: () -> ExplorerShot?
    let stop: () -> Void
    let dropMain: () -> Void
    let dropElsewhere: () -> Bool
    let dropAfterJob: () async -> Void
    let subscribe: ((ExplorerSubscriber) -> Void)?
    let save: (() -> (ExplorerSubscriber) -> Void)?
    let subscribeProjected: ((ExplorerSubscriber, @escaping @MainActor (ExplorerShot) -> ExplorerShot) -> Void)?
    var saveProjected: ((@escaping @MainActor (ExplorerShot) -> ExplorerShot) -> (ExplorerSubscriber) -> Void)? = nil
    var subscribeElsewhere: ((ExplorerElsewhereSubscriber, DispatchQueue, Bool) -> Void)? = nil
    let watch: (ExplorerWorld) -> Void
    let install:
        (_ report: @escaping @MainActor (Bool) -> Void, _ change: @escaping @MainActor (Int?) -> Void) -> [AnyObject]

    static func make(_ kind: ExplorerPassiveKind, host: ExplorerMainHost) -> ExplorerDrivingSubject? {
        switch kind {
        case .drivingCombine:
            let holder = ExplorerHolder(StateMachineObservableObject(host))
            return ExplorerDrivingSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                object: { holder.weak },
                snapshot: { holder.weak?.snapshot },
                isObserving: { holder.weak?.isObserving },
                failure: { holder.weak?.observationFailure },
                resume: { () throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try explorerResume(presentation)
                },
                send: { holder.weak?.send(0).snapshot },
                close: { holder.weak?.close().snapshot },
                stop: { holder.weak?.stopObserving() },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() },
                subscribe: { subscriber in holder.weak.map { explorerSubscribe($0, subscriber) } },
                save: {
                    guard let presentation = holder.weak else { return { _ in } }
                    return explorerSave(presentation)
                },
                subscribeProjected: explorerHasProjection
                    ? { subscriber, transform in
                        holder.weak.map { explorerSubscribeProjected($0, subscriber, transform) }
                    }
                    : nil,
                saveProjected: { transform in
                    guard let presentation = holder.weak else { return { _ in } }
                    return explorerSaveProjected(presentation, transform)
                },
                subscribeElsewhere: { subscriber, queue, once in
                    holder.weak.map { explorerSubscribeElsewhere($0, subscriber, on: queue, once: once) }
                },
                watch: { world in holder.weak.map { explorerAssociate($0, ExplorerReleaseSentinel(world)) } },
                install: { report, change in
                    guard let presentation = holder.weak else { return [] }
                    let reports = presentation.$isObserving.dropFirst().sink { report($0) }
                    let changes = presentation.objectWillChange.sink { _ in change(nil) }
                    return [ExplorerKeep((reports, changes))]
                }
            )
        case .drivingObservation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let holder = ExplorerHolder(StateMachinePresentation(host))
            return ExplorerDrivingSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                object: { holder.weak },
                snapshot: { holder.weak?.snapshot },
                isObserving: { holder.weak?.isObserving },
                failure: { holder.weak?.observationFailure },
                resume: { () throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try explorerResume(presentation)
                },
                send: { holder.weak?.send(0).snapshot },
                close: { holder.weak?.close().snapshot },
                stop: { holder.weak?.stopObserving() },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() },
                subscribe: nil,
                save: nil,
                subscribeProjected: nil,
                watch: { world in holder.weak.map { explorerAssociate($0, ExplorerReleaseSentinel(world)) } },
                install: { report, change in
                    let installed = ExplorerKeep(())
                    explorerTrack({ [weak presentation = holder.weak] in presentation?.isObserving }, installed) {
                        report(!$0)
                    }
                    explorerTrack({ [weak presentation = holder.weak] in presentation?.snapshot.id }, installed) {
                        change($0)
                    }
                    return [installed]
                }
            )
        default:
            return nil
        }
    }
}

/// Runs one sequence against a fresh driving presentation of a fake one-slot `MainActor` host.
@MainActor final class ExplorerDrivingRun: ExplorerRunner {
    let kind: ExplorerPassiveKind
    let families: ExplorerFamilies
    let world: ExplorerWorld
    private weak var host: ExplorerMainHost?
    private var subject: ExplorerDrivingSubject!
    private var installed: [AnyObject] = []
    // Armed callbacks: the hook, its event, and whether a callback armed it, so it may run inside that callback's
    // own run (`chains`: a hook inside a hook, or the same hook revisited).
    private var armed: [(hook: ExplorerHook, event: ExplorerEvent, nested: Bool)] = []
    private var arms = 0
    private var armUsed: Bool { arms >= (families.contains(.chains) ? 2 : 1) }
    private var hookDepth = 0
    private var inHook: Bool { hookDepth > 0 }
    private var assigningAnnounced: UInt64?
    private var lastShown: (id: Int, revision: UInt64) = (0, 0)
    private var shown: Set<Int> = []
    // Whether the presentation still observes: a host delivery shown after this turned false violates I10.
    private var observing = true
    private var endedAtBoundary = false
    private var subscribers: [ExplorerSubscriber] = []
    private var saved: ((ExplorerSubscriber) -> Void)?
    private var savedProjected: ((ExplorerSubscriber) -> Void)?
    private var turns = 0
    private var tokenDropped = false
    // Revisions of the host's own deliveries (`deliver`), as opposed to seeds and a change's delivery.
    private var hostOrigin: Set<UInt64> = []
    private var steps = 0
    private var cancelDelivers = false
    private var fired = 0
    // The `elsewhere` family's subscribers and the queue their values and demand cross to, suspended
    // between steps so that a step decides when it runs.
    private var elsewhere: [ExplorerElsewhereSubscriber] = []
    private let elsewhereQueue = DispatchQueue(label: "explorer.elsewhere")
    private var elsewhereSuspended = false
    // Whether `resumeObserving()` is in the alphabet, which changes what a report may say (I5, I6, I37).
    private var resumes: Bool { !families.isDisjoint(with: [.resume, .matrix, .chains]) }
    private var topEvent: ExplorerEvent?
    private var reportsThisStep = 0
    private var firedAtStepStart = 0
    // I51: the expected invalidation trace of each tracked property.
    private let traces = ExplorerTraces()
    // `objectWillChange` (or Observation change) callbacks so far (I48).
    private var willChanges = 0
    private var changeDepth = 0
    // Registrations the presentation ended: live when it stopped, closed, or was released.
    private var endedByPresentation: Set<Int> = []
    private func presentationEnds() { endedByPresentation.formUnion(world.unfreed.map(\.id)) }

    // The host until the presentation that owns it is created.
    private var unownedHost: ExplorerMainHost?
    // How the presentation was created, and what it read then.
    private var creation: ExplorerEvent?
    private var creationRead: Int?

    init?(_ kind: ExplorerPassiveKind, families: ExplorerFamilies, verbose: Bool = false) {
        self.kind = kind
        self.families = families
        world = ExplorerWorld(verbose: verbose)
        world.setLatestAttempt(1)
        let host = ExplorerMainHost(world)
        self.host = host
        unownedHost = host
        if kind == .drivingObservation {
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
        }
    }

    /// Creates the presentation: as the slice's first event, or plainly before any other (E2).
    private func create(_ mode: ExplorerEvent?) -> Bool {
        guard let host = unownedHost else { return subject != nil }
        creation = mode
        switch mode {
        case .createRefusing: host.refuseNext = true
        case .createOccupied: host.occupy()
        case .createClosed: host.close()
        default: break
        }
        world.setContext(.call(attempt: 1))
        creationRead = world.state.withLock { $0.nextValue }
        guard let subject = ExplorerDrivingSubject.make(kind, host: host) else { return false }
        world.setContext(.spontaneous)
        unownedHost = nil
        self.subject = subject
        host.onCancel = { [weak self] in self?.fire(.onCancel) }
        // The snapshot's `revision` witness runs an armed event at the presentation's first read of the
        // next value handed over. In `chains`, a value a callback's event makes the host hand over holds
        // the presentation strongly until the harness sees it shown: a presentation that keeps a value it
        // never shows then can never be released (I15), beside I54's check while it is alive.
        world.setRevisionHook { [weak self] in MainActor.assumeIsolated { self?.fire(.revision) } }
        host.handOver = { [weak self] shot in
            guard let self else { return }
            if armed.contains(where: { $0.hook == .revision }) { world.setRevisionTarget(shot.id) }
            if families.contains(.chains), inHook, let presentation = subject.object() { shot.capture(presentation) }
        }
        if families.contains(.sites) || families.contains(.matrix) {
            host.site = { [weak self] in self?.fire($0) }
            world.setDestroyHook { [weak self] in MainActor.assumeIsolated { self?.fire(.destroy) } }
        }
        if let shot = subject.snapshot() {
            lastShown = (shot.id, shot.stamp)
            world.readDisplay(shot.id, at: .settled)
        }
        shown.insert(lastShown.id)
        traces.tracksSnapshot = kind == .drivingObservation
        installed = subject.install({ [weak self] in self?.reported($0) }, { [weak self] in self?.changed($0) })
        subject.watch(world)
        let initialReports: [Bool] = subject.isObserving() == true ? [true] : []
        world.state.withLock { $0.reports = initialReports }
        observing = subject.isObserving() == true
        checkCreation(mode)
        return true
    }

    // I45: a refused creation shows the snapshot read at creation, is not observing, and records the
    // failure; a creation against a closed owner observes nothing and records no failure.
    private func checkCreation(_ mode: ExplorerEvent?) {
        guard let mode, let shot = subject.snapshot() else { return }
        let observingNow = subject.isObserving() ?? false
        switch mode {
        case .createRefusing, .createOccupied:
            if shot.id != creationRead {
                world.violate(
                    .drivingResult,
                    "a refused creation (\(mode)) shows r\(shot.stamp), not the snapshot it read at creation"
                )
            }
            if observingNow { world.violate(.drivingResult, "a refused creation (\(mode)) is observing") }
            if subject.failure() == nil {
                world.violate(.drivingResult, "a refused creation (\(mode)) recorded no observation failure")
            }
        case .createClosed:
            if observingNow { world.violate(.drivingResult, "a creation against a closed owner is observing") }
            if subject.failure() != nil {
                world.violate(.drivingResult, "a creation against a closed owner recorded a failure")
            }
        default:
            break
        }
    }

    func enabled() -> [ExplorerEvent] {
        if families.contains(.matrix) { return matrixEnabled() }
        if families.contains(.elsewhere) { return elsewhereEnabled() }
        var result: [ExplorerEvent] = []
        let held = subject.held()
        if families.contains(.core) {
            if held { result += [.apply, .close, .stop, .dropMain, .dropElsewhere, .dropAfterJob] }
            if let host, host.token != nil, world.unfreed.contains(where: { !$0.hostEnded }) {
                result += [.deliver(0), .finish(0), .hostCancelMain(0)]
            }
            if turns < 2 { result.append(.turn) }
            if !tokenDropped { result.append(.tokenDropAfterJob) }
            // The host delivers from inside each cancellation of its subscription, the disposal path
            // included. The mode holds for the whole sequence, so it is offered only as the first event.
            if steps == 0, host != nil, families.contains(.cancelDelivery) { result.append(.deliverInCancel(0)) }
        }
        if families.contains(.combine), subject.subscribe != nil {
            if held {
                result += [.subscribe(saved: false, unlimited: true), .subscribe(saved: false, unlimited: false)]
                if saved == nil { result.append(.savePublisher) }
                if subject.subscribeProjected != nil { result.append(.subscribeProjected) }
            }
            if saved != nil {
                result += [.subscribe(saved: true, unlimited: true), .subscribe(saved: true, unlimited: false)]
            }
            if let last = subscribers.last(where: { !$0.cancelled && !$0.finished }) {
                if !last.unlimited { result.append(.request) }
                result.append(.cancelSubscription)
            }
        }
        if families.contains(.demand), subject.subscribe != nil {
            if held {
                result += [.subscribeZero, .subscribeReturning]
                if savedProjected == nil, subject.saveProjected != nil { result.append(.saveProjected) }
            }
            if savedProjected != nil { result.append(.subscribeSavedProjected) }
            let open = subscribers.filter { !$0.cancelled && !$0.finished }
            if open.count > 1 {
                if open.contains(where: { !$0.unlimited }) { result.append(.requestOldest) }
                result.append(.cancelFirstSubscriber)
            }
        }
        if families.contains(.chains), !armUsed, held {
            // Two arms, each of which may arm a hook from inside its callback, the same one included.
            let hooks: [ExplorerHook] = [.report, .change, .onCancel]
            var inner: [ExplorerEvent] = [
                .stop, .apply, .deliver(0), .then(.deliver(0), .then(.resume, .stop)), .then(.deliver(0), .stop),
                .then(.apply, .stop),
            ]
            if explorerHasResume { inner.append(.resume) }
            for hook in hooks {
                for event in [ExplorerEvent.stop, .resume, .apply] { inner.append(.arm(hook, event)) }
                // A callback that arms a second callback and then stops before it returns.
                for event in [ExplorerEvent.resume, .apply] { inner.append(.then(.arm(hook, event), .stop)) }
            }
            for hook in hooks { for event in inner { result.append(.arm(hook, event)) } }
        }
        if families.contains(.reentrant), !families.contains(.chains), !armUsed, held {
            var hooks: [ExplorerHook] = [.report, .change, .onCancel, .revision]
            var inner: [ExplorerEvent] = [.stop, .apply, .close, .dropMain, .deliver(0), .finish(0)]
            if families.contains(.combine), subject.subscribe != nil {
                hooks += [.subscription, .value]
                if subject.subscribeProjected != nil { hooks.append(.projection) }
                inner += [.subscribe(saved: false, unlimited: true), .cancelSubscription, .request]
            }
            if families.contains(.sites) {
                hooks += [.hostRead, .hostSend, .hostSubscribe, .hostClose, .destroy]
                if families.contains(.combine), subject.subscribe != nil {
                    hooks += [.subscriptionBefore, .completion]
                }
            }
            if families.contains(.resume), explorerHasResume { inner.append(.resume) }
            for hook in hooks { for event in inner { result.append(.arm(hook, event)) } }
        }
        if families.contains(.resume), let host {
            if steps == 0 { result += [.createRefusing, .createOccupied, .createClosed] }
            if held, explorerHasResume { result.append(.resume) }
            if !host.refuseNext { result.append(.refuseNext) }
            if host.isOccupied {
                result.append(.vacate)
            } else if world.slot(of: 0) == nil {
                result.append(.occupy)
            }
        }
        return result
    }

    // The matrix family for a driving presentation: what puts its registration in each phase, and every
    // interrupting event armed at every armable site. Its creation is outside the matrix: no client code
    // can reach a presentation before its initializer returns.
    private func matrixEnabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        let held = subject.held()
        if held {
            result += [.apply, .close, .stop, .dropMain, .dropElsewhere]
            if explorerHasResume { result.append(.resume) }
            if subject.subscribe != nil, subscribers.isEmpty {
                result.append(.subscribe(saved: false, unlimited: true))
            }
        }
        if let host, host.token != nil, world.unfreed.contains(where: { !$0.hostEnded }) {
            result += [.deliver(0), .finish(0), .hostCancelMain(0)]
        }
        if turns < 2 { result.append(.turn) }
        if !armUsed, held {
            var hooks: [ExplorerHook] = [
                .change, .report, .hostSubscribe, .hostRead, .hostSend, .hostClose, .onCancel, .destroy,
            ]
            if subject.subscribe != nil { hooks += [.subscriptionBefore, .value, .completion] }
            var inner: [ExplorerEvent] = [.stop, .close, .dropMain, .dropElsewhere]
            if explorerHasResume { inner.append(.resume) }
            for hook in hooks { for event in inner { result.append(.arm(hook, event)) } }
        }
        return result
    }

    // The `elsewhere` family: subscribers whose demand and cancellation cross to a queue, and callbacks inside a
    // presentation publisher's delivery decision.
    private func elsewhereEnabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        let held = subject.held()
        if held { result += [.apply, .stop, .dropMain, .dropElsewhere] }
        if let host, host.token != nil, world.unfreed.contains(where: { !$0.hostEnded }) { result.append(.deliver(0)) }
        if turns < 2 { result.append(.turn) }
        if subject.subscribeElsewhere != nil {
            if held, elsewhere.count < 2 {
                result += [.subscribeElsewhere(once: false), .subscribeElsewhere(once: true)]
            }
            if !elsewhere.isEmpty { result.append(.requestElsewhere) }
        }
        if !armUsed, held, !elsewhere.isEmpty {
            let inner: [ExplorerEvent] = [
                .dropElsewhere, .requestElsewhere, .then(.dropElsewhere, .requestElsewhere),
                .then(.dropMain, .requestElsewhere), .then(.requestElsewhere, .dropElsewhere),
            ]
            for event in inner { result.append(.arm(.decision, event)) }
        }
        return result
    }

    var fingerprint: String {
        "\(subject.held()) \(observing) \(world.unfreed.count) \(subject.isObserving() ?? false) \(armed.map { "\($0.hook)\($0.event)" }) \(armUsed) \(subscribers.map { "\($0.cancelled)\($0.finished)\($0.wantsMore)" }) \(saved != nil) \(turns) \(cancelDelivers)"
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        guard families.contains(.elsewhere) else { return await runSteps(sequence) }
        // H10 runs in every delivery the sequence's steps schedule.
        return await explorerWithPresentationDeliveryPause({ [weak self] in
            MainActor.assumeIsolated { self?.fire(.decision) }
        }) { await runSteps(sequence) }
    }

    private func runSteps(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        let mode: ExplorerEvent? =
            switch sequence.first {
            case .createRefusing, .createOccupied, .createClosed: sequence.first
            default: nil
            }
        guard create(mode) else {
            return ExplorerOutcome(violations: [], enabled: [], fingerprint: "", trace: [])
        }
        var enabledAfter = sequence.isEmpty ? enabled() : []
        var fingerprintAfter = sequence.isEmpty ? fingerprint : ""
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            steps += 1
            topEvent = event
            traces.begin(
                observing: subject.held() ? subject.isObserving() : nil,
                shown: subject.held() ? subject.snapshot()?.id : nil
            )
            reportsThisStep = 0
            firedAtStepStart = fired
            switch event {
            case .createRefusing, .createOccupied, .createClosed: break
            case .turn: await hop()
            case .dropAfterJob:
                observing = false
                presentationEnds()
                await subject.dropAfterJob()
            case .tokenDropAfterJob:
                tokenDropped = true
                // The action holds the only reference to the capture.
                let token = MainActorSnapshotSubscription(onCancel: {
                    [capture = ExplorerMainThreadCheck(world, "a MainActorSnapshotSubscription's action capture")] in
                    withExtendedLifetime(capture) {}
                })
                await explorerDropAfterItsJob(consume token)
            default: performNow(event)
            }
            boundary(topLevel: true)
            traces.end(
                observing: subject.held() ? subject.isObserving() : nil,
                shown: subject.held() ? subject.snapshot()?.id : nil,
                world
            )
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 {
                enabledAfter = enabled()
                fingerprintAfter = fingerprint
            }
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: fingerprintAfter,
            trace: world.state.withLock { $0.trace }
        )
    }

    private func performNow(_ event: ExplorerEvent) {
        switch event {
        case .apply:
            let firedBefore = fired
            guard let receipt = subject.send() else { return }
            let revision = receipt.stamp
            // I45: the call returns the receipt the host returned.
            if !inHook, fired == firedBefore, receipt.id != host?.lastReceipt {
                world.violate(.drivingResult, "send returned r\(revision), not the receipt the host returned")
            }
            _ = consume receipt
            if !inHook, subject.held(), lastShownNow().revision < revision {
                world.violate(
                    .applyLost,
                    "a top-level send returned r\(revision) but r\(lastShownNow().revision) is shown"
                )
            }
        case .close:
            observing = false
            presentationEnds()
            let firedBefore = fired
            let receipt = subject.close()
            // A receipt check only where no callback made a call of its own meanwhile.
            if !inHook, fired == firedBefore, let receipt, receipt.id != host?.lastReceipt {
                world.violate(.drivingResult, "close returned r\(receipt.stamp), not the receipt the host returned")
            }
        case .resume:
            resume()
        case .refuseNext:
            host?.refuseNext = true
        case .occupy:
            host?.occupy()
        case .vacate:
            host?.vacate()
        case .stop:
            observing = false
            presentationEnds()
            subject.stop()
        case .deliver:
            guard let host else { return }
            if let delivered = host.advance() { hostOrigin.insert(delivered) }
        case .finish:
            host?.finish()
        case .hostCancelMain:
            host?.cancelSubscription()
        case .deliverInCancel:
            cancelDelivers = true
            host?.deliversInCancellation = true
        case .dropMain:
            observing = false
            presentationEnds()
            subject.dropMain()
        case .dropElsewhere:
            observing = false
            presentationEnds()
            if !subject.dropElsewhere() { world.violate(.stuck, "release on a worker never returned") }
        case .subscribeElsewhere(let once):
            guard subject.alive() else { return }
            // A publication can hold the presentation after a reentrant drop. Check its actual
            // lifetime on the subscriber's queue when that subscriber supplies demand.
            let subscriber = ExplorerElsewhereSubscriber(
                index: elsewhere.count,
                world: world,
                presentation: subject.object()
            )
            elsewhere.append(subscriber)
            // Suspended from the first such subscriber on, until quiescence lets it run.
            if !elsewhereSuspended {
                elsewhereQueue.suspend()
                elsewhereSuspended = true
            }
            subject.subscribeElsewhere?(subscriber, elsewhereQueue, once)
        case .requestElsewhere:
            drainElsewhere(keepRunning: false)
        case .savePublisher:
            saved = subject.save?()
        case .subscribe(let fromSaved, let unlimited):
            // Only a saved publisher outlives the presentation.
            guard fromSaved || subject.alive() else { return }
            let subscriber = makeSubscriber(unlimited: unlimited)
            if fromSaved { saved?(subscriber) } else { subject.subscribe?(subscriber) }
            attached(subscriber)
        case .subscribeProjected:
            guard subject.alive() else { return }
            let subscriber = makeSubscriber(unlimited: true)
            subject.subscribeProjected?(subscriber) { [weak self] shot in
                self?.fire(.projection)
                return shot
            }
            attached(subscriber)
        case .subscribeZero, .subscribeReturning:
            guard subject.alive() else { return }
            let subscriber = makeSubscriber(unlimited: false)
            subscriber.initialDemand = event == .subscribeZero ? 0 : 1
            subscriber.returnsDemand = event == .subscribeReturning
            subject.subscribe?(subscriber)
            attached(subscriber)
        case .requestOldest:
            subscribers.first(where: { !$0.cancelled && !$0.finished && !$0.unlimited })?.request()
        case .cancelFirstSubscriber:
            subscribers.first(where: { !$0.cancelled && !$0.finished })?.cancel()
        case .saveProjected:
            savedProjected = subject.saveProjected? { [weak self] shot in
                self?.fire(.projection)
                return shot
            }
        case .subscribeSavedProjected:
            let subscriber = makeSubscriber(unlimited: true)
            savedProjected?(subscriber)
            attached(subscriber)
        case .request:
            subscribers.last(where: { !$0.cancelled && !$0.finished && !$0.unlimited })?.request()
        case .cancelSubscription:
            subscribers.last(where: { !$0.cancelled && !$0.finished })?.cancel()
        case .arm(let hook, let inner):
            armed.append((hook, inner, inHook))
            if !inHook { arms += 1 }
        case .then(let first, let second):
            performNow(first)
            // What the first event showed was shown before the second runs.
            boundary(topLevel: false)
            performNow(second)
        default:
            break
        }
    }

    // `resumeObserving()` (I46; the `resumeObserving()` reference). At top level: a refusal throws and
    // changes nothing; a call made with no live registration registers exactly once and one made while
    // observing not at all; one that returns to an open owner leaves the presentation observing with no
    // failure, showing at least what the registration delivered; one against a closed owner returns
    // without observing.
    private func resume() {
        guard let host else { return }
        let before = (
            id: subject.snapshot()?.id, observing: subject.isObserving() ?? false, failure: subject.failure()
        )
        let calls = host.subscribeCalls
        let firedBefore = fired
        let refusing = host.refuseNext || host.isOccupied || world.slot(of: 0) != nil
        world.setContext(.call(attempt: 1))
        // A resumption begins an observation: deliveries inside it, from its own callbacks, are current.
        let observingBefore = observing
        if !before.observing { observing = true }
        var threw: SubscriptionFailure?
        do throws(SubscriptionFailure) { try subject.resume() } catch { threw = error }
        world.setContext(.spontaneous)
        let observingNow = subject.isObserving() ?? false
        // A resumption made inside a change still being assigned registers at once and reports later: its
        // registration is live before `isObserving` says so.
        let registered = world.unfreed.contains { !$0.hostEnded && !endedByPresentation.contains($0.id) }
        if threw != nil {
            observing = observingBefore
        } else if observingNow || registered {
            observing = true
        } else if !before.observing {
            observing = false
        }
        guard !inHook, fired == firedBefore, subject.held() else { return }
        let made = host.subscribeCalls - calls
        if before.observing, made != 0 {
            world.violate(.resumeContract, "resumeObserving() while observing made \(made) registration calls")
        }
        if !before.observing, made != 1 {
            world.violate(
                .resumeContract,
                "resumeObserving() with no live registration made \(made) registration calls"
            )
        }
        if let threw {
            if subject.snapshot()?.id != before.id || observingNow != before.observing
                || subject.failure() != before.failure
            {
                world.violate(.resumeContract, "a refused resumeObserving() (\(threw)) changed the presentation")
            }
            return
        }
        guard !before.observing else { return }
        if host.closed {
            if observingNow { world.violate(.resumeContract, "resumeObserving() against a closed owner is observing") }
        } else if !refusing {
            if !observingNow || subject.failure() != nil {
                world.violate(
                    .resumeContract,
                    "resumeObserving() returned to an open owner with isObserving \(observingNow) and failure \(subject.failure().map { "\($0)" } ?? "nil")"
                )
            }
            if let shot = subject.snapshot(), shot.stamp < host.revisionAtSubscribe {
                world.violate(
                    .resumeContract,
                    "resumeObserving() returned showing r\(shot.stamp), older than r\(host.revisionAtSubscribe) it registered at"
                )
            }
        }
    }

    private func reported(_ value: Bool) {
        if let id = subject.snapshot()?.id {
            world.readDisplay(id, at: kind == .drivingCombine ? .combineReport : .boundary)
        }
        traces.report(value, world, observation: kind == .drivingObservation)
        reportsThisStep += 1
        boundary(topLevel: false)
        let (previous, count) = world.state.withLock { state -> (Bool?, Int) in
            defer { state.reports.append(value) }
            return (state.reports.last, state.reports.count)
        }
        world.note("report \(value)")
        if kind == .drivingCombine {
            if count == 0, !value { world.violate(.reportsAlternate, "the first report is false") }
            if previous == value { world.violate(.reportsAlternate, "\(value) reported twice in a row") }
        }
        if value, !resumes {
            world.violate(.reportsAlternate, "a driving presentation reported true after creation")
        }
        // I37: `true` reports a live registration whose seed, or a newer snapshot, is already shown, in
        // every call, a reentrant `resumeObserving()` included.
        if value, resumes { checkLiveAtTrue() }
        // I5. With `resumeObserving()` a new registration can be live while an earlier one's end is
        // reported, so only a registration that has ended, by the presentation or its host, counts.
        let holding =
            resumes
            ? world.unfreed.filter { endedByPresentation.contains($0.id) || $0.hostEnded } : world.unfreed
        if !value, !holding.isEmpty {
            world.violate(
                .falseWhileOccupied,
                "false reported while registrations \(holding.map(\.id)) hold the slot"
            )
        }
        fire(.report)
    }
    // I37 at a driving `true`: the newest registration its host has not ended holds the slot, and the
    // presentation already shows that registration's seed or a snapshot at least as new.
    private func checkLiveAtTrue() {
        guard let live = world.unfreed.filter({ !$0.hostEnded }).max(by: { $0.id < $1.id }) else {
            // A `true` queued behind a callback that already ended its registration reports a past change.
            if fired == firedAtStepStart {
                world.violate(.trueBeforeLive, "true reported while no registration of the presentation is live")
            }
            return
        }
        guard let shown = subject.snapshot() else { return }
        if let problem = explorerSeedVisibleProblem(registration: live.id, seed: live.firstOffer, shown: shown.stamp) {
            world.violate(.trueBeforeLive, problem)
        }
    }
    private func changed(_ old: Int?) {
        if let id = old ?? subject.snapshot()?.id {
            world.readDisplay(id, at: .willChange)
        }
        if let old { traces.snapshot.invalidated(old, world) }
        willChanges += 1
        changeDepth += 1
        defer { changeDepth -= 1 }
        boundary(topLevel: false)
        fire(.change)
    }
    private func fire(_ hook: ExplorerHook) {
        // A hook runs inside another's run only when that run armed it, and never more than two deep.
        guard hookDepth < 2, let index = armed.firstIndex(where: { $0.hook == hook && (!inHook || $0.nested) }) else {
            return
        }
        let event = armed.remove(at: index).event
        fired += 1
        let cell = ExplorerMatrixCell.read(world, site: hook, top: topEvent, ended: endedByPresentation) { _ in
            ("driving", 0)
        }
        let before = matrixState()
        defer { explorerCover(kind: kind, cell: cell, site: hook, event: event, changed: matrixState() != before) }
        // What the presentation shows when the callback starts was shown before the event it runs.
        boundary(topLevel: false)
        let announcedBefore = world.state.withLock { $0.revision }
        hookDepth += 1
        world.note("hook \(hook.rawValue) runs \(event)")
        performNow(event)
        boundary(topLevel: false)
        // The value whose publication the callback announced was made before the callback ran.
        if [.change, .value, .projection].contains(hook) { assigningAnnounced = announcedBefore }
        hookDepth -= 1
    }

    // The matrix's record of what a callback's event changed.
    private func matrixState() -> String {
        let held = subject.held()
        let observing = held ? subject.isObserving() : nil
        let world = world.state.withLock { state in
            "\(state.registrations.values.filter { $0.phase != .freed }.map(\.id).sorted()) \(state.reports.count) \(state.presentationGone)"
        }
        return "\(held) \(String(describing: observing)) \(world) \(endedByPresentation.count) \(host?.closed ?? true)"
    }
    private func makeSubscriber(unlimited: Bool) -> ExplorerSubscriber {
        let subscriber = ExplorerSubscriber(
            index: subscribers.count,
            unlimited: unlimited,
            shownAtAttach: lastShownNow().revision,
            attachedAfterRelease: !subject.alive()
        )
        subscriber.shownAtAttachID = lastShownNow().id
        subscriber.world = world
        // One attached inside an `objectWillChange` callback counts that announcement as made after it.
        // So does one attached inside any callback of a publication in progress.
        subscriber.willChangeAtLastNew = willChanges - (changeDepth > 0 || inHook ? 1 : 0)
        subscriber.onSubscription = { [weak self] _ in self?.fire(.subscription) }
        subscriber.onSubscriptionBefore = { [weak self] _ in self?.fire(.subscriptionBefore) }
        subscriber.onCompletion = { [weak self] _ in self?.fire(.completion) }
        subscriber.onValue = { [weak self] subscriber, value in
            guard let self else { return }
            explorerCheckOrder(
                world,
                subscriber,
                value,
                willChange: willChanges,
                shownNow: subject.held() ? subject.snapshot()?.id : nil,
                shownBefore: shown.contains(value.id)
            )
            explorerCheckReceived(world, subscriber, value)
            fire(.value)
        }
        subscriber.onFinish = { [weak self] subscriber in
            guard let self, subject.alive() else { return }
            world.violate(.combineFinish, "subscriber \(subscriber.index) finished while the presentation is alive")
        }
        subscribers.append(subscriber)
        return subscriber
    }
    private func attached(_ subscriber: ExplorerSubscriber) {
        // A subscriber that cancelled inside its subscription is owed no completion.
        guard subscriber.attachedAfterRelease, !subscriber.cancelled else { return }
        if !subscriber.finished {
            world.violate(
                .combineFinish,
                "subscriber \(subscriber.index) attached after the release did not finish at once"
            )
        }
    }

    private func lastShownNow() -> (id: Int, revision: UInt64) {
        guard subject.held(), let shot = subject.snapshot() else { return lastShown }
        return (shot.id, shot.stamp)
    }
    private func boundary(topLevel: Bool) {
        // A value shown no longer holds the presentation.
        subject.snapshot()?.releaseCapture()
        if subject.held(), let shot = subject.snapshot() {
            let (id, revision) = (shot.id, shot.stamp)
            world.readDisplay(id, at: topLevel ? .settled : .boundary)
            if id != lastShown.id {
                if revision < lastShown.revision {
                    world.violate(.revisionRegressed, "r\(revision) shown after r\(lastShown.revision)")
                }
                let announced = assigningAnnounced.map { revision <= $0 } ?? false
                if revision > lastShown.revision, !announced, let ended = endedObservationValue(id, revision) {
                    world.violate(.shownAfterEnd, "r\(revision), \(ended), shown after the observation ended")
                }
                // The presentation claims the end before it cancels the subscription, and a host's own
                // cancellation tells it first, so nothing delivered inside a cancellation is shown.
                if world.isInCancellation(id) {
                    world.violate(
                        .shownAfterEnd,
                        "r\(revision), delivered inside the subscription's cancellation, shown"
                    )
                }
                // I45: nothing the host delivered inside a registration call that refused is ever shown.
                if host?.refusedOffers.contains(id) == true {
                    world.violate(.drivingResult, "r\(revision), delivered inside a refused registration call, shown")
                }
                assigningAnnounced = nil
                lastShown = (id, revision)
                shown.insert(id)
                world.state.withLock { $0.values[id]?.shownAt = 1 }
            }
            if topLevel {
                let last = world.state.withLock { $0.reports.last } ?? false
                if subject.isObserving() != last {
                    world.violate(
                        .reportMismatch,
                        "isObserving reads \(subject.isObserving() ?? false) but the last report is \(last)"
                    )
                }
            }
        }
        // The presentation's newest registration, which `resumeObserving()` can replace after an end.
        endedAtBoundary =
            !observing
            || world.state.withLock { state in
                state.registrations.values.filter { !$0.withheld }.max { $0.id < $1.id }?.finished ?? false
            }
    }
    // Why a newly shown, unannounced value belongs to an observation that ended before it was shown, or
    // `nil`. Stopping discards an observation value (a registration's seed or a delivery) whose
    // publication was not announced: one of a registration the presentation ended by `stop`, `close` or a
    // release is never shown afterward, and neither is a delivery the host made on its own after it
    // finished the registration. A change admitted through the presentation (`send`, `close`) still
    // publishes its receipt, and the host's delivery of that change carries the receipt, so neither is
    // an observation value.
    private func endedObservationValue(_ id: Int, _ revision: UInt64) -> String? {
        let registration = world.state.withLock { state -> Int? in
            if case .delivered(let registration) = state.values[id]?.origin { registration } else { nil }
        }
        return explorerEndedObservationProblem(
            registration: registration,
            admittedThroughPresentation: host?.admittedThroughPresentation.contains(id) == true,
            endedByPresentation: endedByPresentation,
            hostDeliveryAfterFinish: endedAtBoundary && hostOrigin.contains(revision)
        )
    }

    // Runs what the subscribers' queue holds while the main actor waits, then suspends it again, unless
    // `keepRunning`.
    private func drainElsewhere(keepRunning: Bool) {
        guard elsewhereSuspended else { return }
        elsewhereQueue.resume()
        let done = DispatchSemaphore(value: 0)
        elsewhereQueue.async { done.signal() }
        if !explorerWait(done) { world.violate(.stuck, "the subscribers' queue never ran") }
        if keepRunning { elsewhereSuspended = false } else { elsewhereQueue.suspend() }
    }

    private func hop() async { await Task { @MainActor in }.value }
    private func hop(until condition: () -> Bool, limit: Int) async -> Bool {
        for _ in 0 ..< limit {
            if condition() { return true }
            await hop()
        }
        return condition()
    }

    private func quiesce() async {
        armed = []
        world.note("quiesce")
        host?.refuseNext = false
        host?.vacate()
        for _ in 0 ..< 3 { await hop() }
        boundary(topLevel: true)
        if subject.held(), world.violations.isEmpty {
            // I54: a value delivered to a registration whose cancellation has settled, and never shown, is
            // released by then, while the presentation is still alive.
            let current = subject.snapshot()?.id
            let values = world.state.withLock { state in
                state.values.compactMap { id, value -> ExplorerSettledValue? in
                    guard case .delivered(let registration) = value.origin,
                        let record = state.registrations[registration]
                    else { return nil }
                    return ExplorerSettledValue(
                        id: id,
                        revision: value.revision,
                        registration: registration,
                        settled: record.phase == .freed && !record.withheld,
                        shown: value.shownAt != nil || id == current,
                        alive: !value.destroyed
                    )
                }
            }
            if let problem = explorerSettledCustodyProblem(values) { world.violate(.custodyAfterSettlement, problem) }
        }
        if subject.held(), world.violations.isEmpty {
            let settled = await hop(until: { self.finalProblem() == nil }, limit: 30)
            if !settled, let problem = finalProblem() { world.violate(problem.0, problem.1) }
            boundary(topLevel: true)
            for subscriber in subscribers
            where subscriber.wantsMore && subscriber.received.last?.revision != lastShown.revision {
                world.violate(
                    .combineLatest,
                    "subscriber \(subscriber.index) with demand last received \(subscriber.received.last.map { "r\($0.revision)" } ?? "nothing") while r\(lastShown.revision) is shown"
                )
            }
            for subscriber in subscribers {
                if let problem = explorerUnshownProblem(subscriber.index, subscriber.received, shown: shown) {
                    world.violate(.combineUnshown, problem)
                }
            }
        }
        // The subscribers' queue runs freely from here on, so their values and completions arrive.
        drainElsewhere(keepRunning: true)
        if subject.held() {
            observing = false
            // With a host that delivers inside its cancellations, the release at quiescence stops first,
            // so only the drop events reach the disposal path, and a defect on that path does not end
            // every sequence at its root.
            if cancelDelivers { subject.stop() }
            subject.dropMain()
        }
        let released = await hop(until: { !self.subject.alive() && self.world.unfreed.isEmpty }, limit: 2000)
        let open = { self.subscribers.filter { !$0.cancelled && !$0.finished } }
        if released, await !hop(until: { open().isEmpty }, limit: 30) {
            for subscriber in open() {
                world.violate(
                    .combineFinish,
                    "subscriber \(subscriber.index) did not finish once the presentation was gone"
                )
            }
        }
        for subscriber in subscribers { subscriber.checkHandshake() }
        if released, await !hop(until: { self.elsewhere.allSatisfy(\.finished) }, limit: 2000) {
            world.violate(
                .combineFinish,
                "a subscriber through receive(on:) did not finish once the presentation was gone"
            )
        }
        drainElsewhere(keepRunning: true)
        elsewhere = []
        installed = []
        subscribers = []
        saved = nil
        savedProjected = nil
        let done = await hop(
            until: { released && self.host == nil && self.world.liveValues().isEmpty },
            limit: 2000
        )
        if !done {
            let live = world.state.withLock { $0.values.filter { !$0.value.destroyed }.map { "r\($0.value.revision)" } }
            world.violate(
                .leak,
                "at quiescence: presentation alive \(subject.alive()), host alive \(host != nil), registrations holding the slot \(world.unfreed.map(\.id)), live values \(live)"
            )
        }
    }

    private func finalProblem() -> (ExplorerInvariant, String)? {
        let unfreed = world.unfreed.map(\.id)
        let observingNow = subject.isObserving() ?? false
        if unfreed.count > 1 { return (.twoRegistrations, "registrations \(unfreed) hold the slot") }
        if observingNow, unfreed.isEmpty {
            return (.finalState, "isObserving is true but no registration holds the slot")
        }
        if !observingNow, !unfreed.isEmpty {
            return (.finalState, "isObserving is false but registration \(unfreed) holds the slot")
        }
        return nil
    }
}

/// A one-slot `IsolatedStateMachineHost` confined to the main actor ("I", slot 3), as a passive source
/// through the synchronous `observe(_:)` overload.
///
/// It mirrors `ExplorerMainHost`: a seed at
/// registration, a host-side cancellation that tells the subscriber from inside `onCancel`, and a
/// slot freed when the cancellation returns.
nonisolated final class ExplorerMainIsolatedHost: IsolatedStateMachineHost {
    typealias Owner = MainActor
    typealias Snapshot = ExplorerShot

    let world: ExplorerWorld
    let index = 3
    private var receive: ((ExplorerShot) -> Void)?
    private var onFinish: (() -> Void)?
    private var token: IsolatedSnapshotSubscription<MainActor>?
    private(set) var registration: Int?
    private var cancellingItself = false
    private var revision: UInt64 = 0
    var onCancel: (() -> Void)?
    /// The armable sites of this host (`sites`, `matrix`): `snapshot`, and a registration after its seed.
    var site: ((ExplorerHook) -> Void)?
    /// Delivers a new value to the subscriber from inside each cancellation, before the slot is free.
    var deliversInCancellation = false

    init(_ world: ExplorerWorld) { self.world = world }

    var hasSubscriber: Bool { receive != nil }

    func snapshot(isolation: isolated MainActor) -> ExplorerShot {
        let read = world.makeValue(
            .hostRead(host: index),
            attempt: world.state.withLock { $0.latestAttempt },
            revision: revision
        )
        site?(.hostRead)
        return read
    }
    private func delivered() -> ExplorerShot {
        guard let registration else { return world.makeValue(.hostRead(host: index), attempt: nil) }
        let shot = world.makeValue(
            .delivered(registration: registration),
            attempt: world.registration(registration)?.attempt
        )
        world.offered(shot.id, into: registration)
        revision = shot.revision
        return shot
    }
    func subscribe(
        _ receive: @escaping (ExplorerShot) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated MainActor
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<MainActor> {
        guard let id = world.admit(host: index) else { throw .capacityExceeded }
        registration = id
        self.receive = receive
        self.onFinish = onFinish
        receive(delivered())
        defer { site?(.hostSubscribe) }
        let world = world
        let made = IsolatedSnapshotSubscription<MainActor>(
            isolation: isolation,
            onCancel: { [weak self] in
                guard let self else { return }
                if cancellingItself, let onFinish = self.onFinish {
                    cancellingItself = false
                    self.onFinish = nil
                    onFinish()
                }
                onCancel?()
                if deliversInCancellation, let receive = self.receive {
                    // The host's own reference goes right after the delivery, before the slot is free.
                    var value: ExplorerShot? = delivered()
                    if let shot = value {
                        let valueID = shot.id
                        world.deliveredInCancellation(valueID)
                        receive(shot)
                        _ = consume shot
                        world.hostReleasing(valueID, true)
                        value = nil
                        world.hostReleasing(valueID, false)
                    }
                }
                world.freed(id)
                self.receive = nil
                self.onFinish = nil
            },
            // A token dropped without being cancelled runs this where it is dropped: the slot is free
            // at once, and the callbacks wait for the host's next sweep.
            onRelease: { world.freed(id) }
        )
        token = made
        return made
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (ExplorerShot) -> Projection,
        isolation: isolated MainActor
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { throw .capacityExceeded }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (ExplorerShot) -> Projection,
        isolation: isolated MainActor
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { throw .capacityExceeded }

    /// Releases the callbacks of a registration whose token was dropped without running, as a host
    /// does when it next sweeps its registrations, and frees the slot.
    @MainActor func sweep() {
        guard let registration else { return }
        // The slot was freed by `onRelease`, or is freed now, before the callbacks go.
        if world.registration(registration)?.phase != .freed { world.freed(registration) }
        receive = nil
        onFinish = nil
        token = nil
    }
    /// The owner admits a change and delivers it to its subscriber.
    @MainActor func advance() {
        guard let receive else { return }
        receive(delivered())
    }
    @MainActor func finish() {
        guard let onFinish else { return }
        if let registration { world.hostEnded(registration, finished: true) }
        self.onFinish = nil
        onFinish()
    }
    @MainActor func cancelSubscription() {
        if let registration { world.hostEnded(registration, finished: true) }
        cancellingItself = true
        token?.cancel(isolation: MainActor.shared)
        cancellingItself = false
    }
}

/// A client value whose destructor must run on the main thread (I1).
nonisolated final class ExplorerMainThreadCheck: Sendable {
    let world: ExplorerWorld
    let name: String
    init(_ world: ExplorerWorld, _ name: String) {
        self.world = world
        self.name = name
    }
    deinit {
        if !Thread.isMainThread { world.violate(.offMain, "\(name) was destroyed off the main thread") }
    }
}
