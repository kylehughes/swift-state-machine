import Combine
import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

// The host-teardown slice of the explorer: an owner of the profile example graph, its saved
// publishers, registration callbacks whose captures attach to a publisher from their destructors, a
// driver whose cancellation handler attaches to one, a registration cancelled on a worker whose
// capture drops the owner while the worker still holds the owner's state, and the owner's release.
// Invariants: I28, a subscriber that attaches after the owner's release receives no ordinary value;
// I29, no ordinary value reaches any subscriber after the release; I30, every subscriber finishes.

/// One owner under teardown, reached through closures so the three owner kinds share the harness.
@MainActor struct ExplorerTeardownSubject {
    let gone: () -> Bool
    /// The owner's current revision, the last one it accepted.
    let revision: () async -> UInt64?
    let save: () async -> SnapshotPublisher<UInt64>?
    let capture: (ExplorerAttachOnRelease) async -> Any?
    let startDriver: () async -> Bool
    let send: () async -> Void
    /// Sends `.authenticationChanged`, a self-loop of the loading phase, `count` times.
    let changes: (Int) async -> Void
    let releaseMain: () -> Void
    let releaseElsewhere: () -> Bool
    /// Releases the owner on a worker in the schedule where its destructor's main-actor job runs first.
    let releaseAfterJob: () async -> Void
    /// Registers a callback whose capture drops the owner, cancels it on a worker, and returns once
    /// the worker has dropped the owner and parked; `nil` when the owner kind cannot.
    let workerDrop: (() async -> ExplorerOwnerPark?)?
    /// Saves a publisher with the hand-off pause (H3) bound to the given closure, which then runs on the
    /// main actor in each hand-off of that publisher, after the value is taken and before the delivery is
    /// decided; `nil` when the owner kind has no such hand-off.
    var saveHandingOff: ((@escaping @Sendable () -> Void) -> SnapshotPublisher<UInt64>?)? = nil
    /// Saves a publisher whose hand-offs run the given closure on the main actor (H3), so the harness can
    /// wait until its seed reached the main actor; `nil` when the owner kind has no such hand-off.
    var saveCounting: ((@escaping @Sendable () -> Void) async -> SnapshotPublisher<UInt64>?)? = nil
    /// Releases the owner on a worker with the release-notice pause (H4) bound to the given closure,
    /// which runs after each registration's release notice; returns at once. `nil` when the owner kind
    /// sends no notices.
    var releaseNoticing: ((@escaping @Sendable () -> Void, @escaping @Sendable () -> Void) -> Void)? = nil

    static func make(_ kind: ExplorerPassiveKind, driver: ExplorerDriverControl) -> ExplorerTeardownSubject? {
        guard let user = try? UserID("explorer") else { return nil }
        switch kind {
        case .teardownMain, .publisher:
            let box = ExplorerOwnerBox(
                GeneratedProfile.MainActorHost(
                    .init(userID: user),
                    drivers: .init(
                        fetch: { _ in
                            await driver.run()
                            return .failure(.unavailable)
                        },
                        audit: { _ in .failure(.unavailable) }
                    )
                )
            )
            return ExplorerTeardownSubject(
                gone: { box.weak == nil },
                revision: { box.current?.snapshot().revision },
                save: { try? box.current?.snapshotPublisher { $0.revision } },
                capture: { hold in try? box.current?.subscribe { _ in withExtendedLifetime(hold) {} } },
                startDriver: {
                    guard (try? box.current?.send(.load(ProfileRequest(userID: user)))) != nil else { return false }
                    return await driver.waitStarted()
                },
                send: { _ = try? box.current?.send(.load(ProfileRequest(userID: user))) },
                changes: { count in for _ in 0 ..< count { _ = try? box.current?.send(.authenticationChanged) } },
                releaseMain: { box.releaseHere() },
                releaseElsewhere: { box.releaseElsewhere() },
                releaseAfterJob: { await box.releaseAfterJob() },
                workerDrop: nil
            )
        case .teardownActor:
            let box = ExplorerOwnerBox(
                GeneratedProfile.ActorHost(
                    .init(userID: user),
                    drivers: .init(
                        fetch: { _ in
                            await driver.run()
                            return .failure(.unavailable)
                        },
                        audit: { _ in .failure(.unavailable) }
                    )
                )
            )
            return ExplorerTeardownSubject(
                gone: { box.weak == nil },
                revision: {
                    guard let owner = box.current else { return nil }
                    return await owner.snapshot().revision
                },
                save: {
                    guard let owner = box.current else { return nil }
                    return try? await owner.snapshotPublisher { $0.revision }
                },
                capture: { hold in
                    guard let owner = box.current else { return nil }
                    return try? await owner.subscribe { _ in withExtendedLifetime(hold) {} }
                },
                startDriver: {
                    guard let owner = box.current, (try? await owner.send(.load(ProfileRequest(userID: user)))) != nil
                    else { return false }
                    return await driver.waitStarted()
                },
                send: {
                    guard let owner = box.current else { return }
                    _ = try? await owner.send(.load(ProfileRequest(userID: user)))
                },
                changes: { count in
                    guard let owner = box.current else { return }
                    for _ in 0 ..< count { _ = try? await owner.send(.authenticationChanged) }
                },
                releaseMain: { box.releaseHere() },
                releaseElsewhere: { box.releaseElsewhere() },
                releaseAfterJob: { await box.releaseAfterJob() },
                workerDrop: nil,
                saveCounting: { pause in
                    guard let owner = box.current else { return nil }
                    return await explorerWithHandOffPause(pause) { try? await owner.snapshotPublisher { $0.revision } }
                },
                releaseNoticing: { pause, returned in box.releaseNoticing(pause, returned) }
            )
        case .teardownShared:
            let box = ExplorerOwnerBox(
                GeneratedProfile.Shared(
                    .init(userID: user),
                    fetchDriver: { _ in
                        await driver.run()
                        return .failure(.unavailable)
                    },
                    auditDriver: { _ in .failure(.unavailable) }
                )
            )
            return ExplorerTeardownSubject(
                gone: { box.weak == nil },
                revision: { box.current?.snapshot().revision },
                save: { try? box.current?.snapshotPublisher { $0.revision } },
                capture: { hold in try? box.current?.subscribe { _ in withExtendedLifetime(hold) {} } },
                startDriver: {
                    guard (try? box.current?.send(.load(ProfileRequest(userID: user)))) != nil else { return false }
                    return await driver.waitStarted()
                },
                send: { _ = try? box.current?.send(.load(ProfileRequest(userID: user))) },
                changes: { count in for _ in 0 ..< count { _ = try? box.current?.send(.authenticationChanged) } },
                releaseMain: { box.releaseHere() },
                releaseElsewhere: { box.releaseElsewhere() },
                releaseAfterJob: { await box.releaseAfterJob() },
                workerDrop: {
                    let park = ExplorerOwnerPark()
                    let delivered = ExplorerSignal()
                    guard
                        let token = try? box.current?
                            .subscribe({ [hold = ExplorerDropOnRelease(box, park)] _ in
                                withExtendedLifetime(hold) {}
                                delivered.raise()
                            })
                    else { return nil }
                    await delivered.wait()
                    runOnOwnThread {
                        token.cancel()
                        park.returned.signal()
                    }
                    return explorerWait(park.dropped) ? park : nil
                },
                saveHandingOff: { pause in
                    explorerWithHandOffPause(pause) { try? box.current?.snapshotPublisher { $0.revision } }
                },
                saveCounting: { pause in
                    explorerWithHandOffPause(pause) { try? box.current?.snapshotPublisher { $0.revision } }
                },
                releaseNoticing: { pause, returned in box.releaseNoticing(pause, returned) }
            )
        default:
            return nil
        }
    }
}

/// The only strong reference the harness has to an owner, which any thread can drop.
nonisolated final class ExplorerOwnerBox<Owner: AnyObject & Sendable>: Sendable {
    private let owner: OSAllocatedUnfairLock<Owner?>
    private let reference: OSAllocatedUnfairLock<ExplorerWeak<Owner>>
    init(_ owner: Owner) {
        self.owner = OSAllocatedUnfairLock(initialState: owner)
        reference = OSAllocatedUnfairLock(initialState: ExplorerWeak(owner))
    }
    var current: Owner? { owner.withLock { $0 } }
    var weak: Owner? { reference.withLock { $0.value } }
    func releaseHere() {
        let taken = owner.withLock { $0.take() }
        _ = consume taken
    }
    func releaseAfterJob() async {
        guard let taken = owner.withLock({ $0.take() }) else { return }
        await explorerDropAfterItsJob(consume taken)
    }
    /// Releases the owner on a worker with H4 bound to `pause`, then runs `returned`; returns at once.
    func releaseNoticing(_ pause: @escaping @Sendable () -> Void, _ returned: @escaping @Sendable () -> Void) {
        runOnOwnThread {
            explorerWithReleaseNoticePause(pause) { self.releaseHere() }
            returned()
        }
    }
    func releaseElsewhere() -> Bool {
        let dropped = DispatchSemaphore(value: 0)
        runOnOwnThread {
            self.releaseHere()
            dropped.signal()
        }
        return explorerWait(dropped)
    }
}

nonisolated struct ExplorerWeak<Value: AnyObject & Sendable>: Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

/// A worker that dropped the owner from a capture's destructor and waits to return.
nonisolated final class ExplorerOwnerPark: Sendable {
    let dropped = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
    func letReturn() -> Bool {
        proceed.signal()
        return explorerWait(returned)
    }
}

/// Drops the owner from its destructor, then parks the releasing thread until the harness lets it go.
nonisolated final class ExplorerDropOnRelease<Owner: AnyObject & Sendable>: Sendable {
    let box: ExplorerOwnerBox<Owner>
    let park: ExplorerOwnerPark
    init(_ box: ExplorerOwnerBox<Owner>, _ park: ExplorerOwnerPark) {
        self.box = box
        self.park = park
    }
    deinit {
        box.releaseHere()
        park.dropped.signal()
        _ = explorerWait(park.proceed)
    }
}

/// Attaches a subscriber to a saved publisher from its destructor, when that runs on the main thread.
///
/// For a `MainActorHost`, whose registration callbacks are client values it releases on the main
/// actor, a destructor elsewhere violates I1.
nonisolated final class ExplorerAttachOnRelease: Sendable {
    /// Tracks whether this hook is still armed for genuine owner teardown and whether its destructor
    /// has finished running, without retaining the hook itself.
    nonisolated final class State: Sendable {
        private let flags = OSAllocatedUnfairLock(initialState: (armed: true, released: false))
        var isReleased: Bool { flags.withLock { $0.released } }
        /// Disarms this hook so explicit fixture cleanup cannot impersonate genuine owner teardown.
        func disarm() { flags.withLock { $0.armed = false } }
        fileprivate func beginDeinit() -> Bool { flags.withLock { $0.armed } }
        fileprivate func finishDeinit() { flags.withLock { $0.released = true } }
    }

    let state = State()
    let attach: @Sendable () -> Void
    let world: ExplorerWorld?
    let teardown: ExplorerWorld?
    init(_ world: ExplorerWorld?, teardown: ExplorerWorld? = nil, _ attach: @escaping @Sendable () -> Void) {
        self.world = world
        self.teardown = teardown
        self.attach = attach
    }
    deinit {
        defer { state.finishDeinit() }
        if let world, !Thread.isMainThread {
            world.violate(.offMain, "a MainActorHost registration callback's capture was destroyed off the main thread")
        }
        guard state.beginDeinit() else { return }
        // Only genuine owner teardown reaches here; explicit harness cleanup disarms first.
        teardown?.state.withLock { $0.ownerTeardown = true }
        attach()
    }
}

/// A one-shot event awaited instead of inferring progress from scheduling.
nonisolated struct ExplorerSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// The driver of the profile graph's fetch operation: it waits for cancellation, and its
/// cancellation handler runs the action the harness set.
nonisolated final class ExplorerDriverControl: Sendable {
    private let started = ExplorerSignal()
    private let onCancel = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    func set(_ action: @escaping @Sendable () -> Void) { onCancel.withLock { $0 = action } }
    func run() async {
        await withTaskCancellationHandler {
            started.raise()
            // Held until the owner's release cancels it; the harness never waits for this sleep.
            try? await Task.sleep(for: .seconds(3600))
        } onCancel: {
            onCancel.withLock { $0 }?()
        }
    }
    func waitStarted() async -> Bool {
        await started.wait()
        return true
    }
}

/// A subscriber of an owner's publisher that requests everything and checks I28.
@MainActor final class ExplorerTeardownRecorder {
    let index: Int
    let publisher: Int
    let gone: () -> Bool
    let world: ExplorerWorld
    /// Whether the owner was already released when the subscriber attached, so all its demand came after.
    let attachedAfterRelease: Bool
    var values: [UInt64] = []
    var finished = false
    /// A delivery already decided when a forced release ran (H7) may still arrive, once.
    var decidedAllowance = 0
    /// I47: subscriptions and completions received, counted.
    var subscriptions = 0
    var completions = 0
    /// Runs on every value; an echoing subscriber changes the owner from inside it.
    var onValue: (@MainActor () -> Void)?
    /// E9 on an owner publisher: the demand the subscriber asks for when it subscribes, the demand it returns
    /// from each value, the units granted so far (`nil` for unlimited), and whether it cancelled.
    var initialDemand: Subscribers.Demand = .unlimited
    var returnedDemand: Subscribers.Demand = .none
    private(set) var granted: Int?
    private(set) var cancelled = false
    private var subscription: (any Subscription)?
    var limited: Bool { granted != nil }
    /// Requests `count` more values (`requestOldest`).
    func request(_ count: Int) {
        guard let subscription, !cancelled else { return }
        granted = granted.map { $0 + count }
        subscription.request(.max(count))
    }
    /// Cancels this subscription (`cancelFirstSubscriber`), which is owed no completion.
    func cancel() {
        cancelled = true
        let held = subscription
        subscription = nil
        held?.cancel()
    }
    // Values received since the first value of the current batch; a main-actor job enqueued at that
    // first value closes the batch when it runs (I32's measure of a turn).
    private var batch = 0
    private var batchOpen = false
    private var batchTask: Int?
    /// The last revision the owner accepted before its release: an owner released without closing
    /// first processes and delivers every batch it accepted (I28, OBS-005), so only a newer value violates.
    let acceptedBound: () -> UInt64?
    init(
        index: Int,
        publisher: Int,
        world: ExplorerWorld,
        gone: @escaping () -> Bool,
        acceptedBound: @escaping () -> UInt64?
    ) {
        self.acceptedBound = acceptedBound
        self.index = index
        self.publisher = publisher
        self.world = world
        self.gone = gone
        attachedAfterRelease = gone()
    }
}

extension ExplorerTeardownRecorder: @MainActor Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    func receive(subscription: any Subscription) {
        subscriptions += 1
        if subscriptions > 1 {
            world.violate(.subscriptionProtocol, "subscriber \(index) received a second subscription")
        }
        self.subscription = subscription
        granted = initialDemand.max
        if initialDemand != .none { subscription.request(initialDemand) }
    }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        // I18 and I20 on an owner publisher: never more values than requested, none after a cancellation.
        if cancelled { world.violate(.combineAfterCancel, "subscriber \(index) received r\(input) after it cancelled") }
        if let granted, values.count + 1 > granted {
            world.violate(
                .combineDemand,
                "subscriber \(index) received \(values.count + 1) values for \(granted) requested"
            )
        }
        if let returned = returnedDemand.max, returned > 0 { granted = granted.map { $0 + returned } }
        // Before the owner's teardown, which a driver's cancellation or the release of a registration's
        // callbacks marks, a value it accepted before its last reference went is still delivered (I28).
        let accepted = !world.state.withLock { $0.ownerTeardown } && (acceptedBound().map { input <= $0 } ?? false)
        if decidedAllowance > 0 {
            // Decided before the release; quiescence checks that no second value follows.
            decidedAllowance -= 1
        } else if accepted {
            // Accepted before the release: delivered during the owner's final processing.
        } else if attachedAfterRelease {
            world.violate(
                .ownerReleasedDelivery,
                "subscriber \(index) of publisher \(publisher), attached after the owner was released, received ordinary revision \(input)"
            )
        } else if gone() {
            world.violate(
                .ownerReleasedPending,
                "subscriber \(index) of publisher \(publisher), attached before the release, received ordinary revision \(input) after the owner was released"
            )
        }
        values.append(input)
        world.note("subscriber \(index) received r\(input)")
        // A turn is one main-actor job: the batch ends when a job enqueued at its first value runs, or
        // when a value arrives on another task, whose job is a later one.
        let task = withUnsafeCurrentTask { $0?.hashValue }
        if !batchOpen || task != batchTask {
            batchOpen = true
            batch = 0
            batchTask = task
            Task { @MainActor [weak self] in self?.batchOpen = false }
        }
        batch += 1
        if batch == 33 {
            world.violate(.publisherTurnBound, "subscriber \(index) received 33 values in one main-actor turn")
        }
        onValue?()
        return returnedDemand
    }
    func receive(completion: Subscribers.Completion<Never>) {
        completions += 1
        if completions > 1 {
            world.violate(.subscriptionProtocol, "subscriber \(index) received \(completions) completions")
        }
        if subscriptions == 0 {
            world.violate(.subscriptionProtocol, "subscriber \(index) finished before its subscription")
        }
        finished = true
        world.note("subscriber \(index) finished")
    }
}

/// Runs one teardown sequence from a fresh owner.
@MainActor final class ExplorerTeardownRun: ExplorerRunner {
    let kind: ExplorerPassiveKind
    let world: ExplorerWorld
    private let driver = ExplorerDriverControl()
    private var subject: ExplorerTeardownSubject!
    private var publishers: [SnapshotPublisher<UInt64>?] = [nil, nil]
    private var recorders: [ExplorerTeardownRecorder] = []
    private var tokens: [Any] = []
    private var captureHooks: [ExplorerAttachOnRelease.State] = []
    private var driverStarted = false
    private var driverHookArmed = false
    private let driverHookCancelled = OSAllocatedUnfairLock(initialState: false)
    private var park: ExplorerOwnerPark?
    private var released = false
    private var turns = 0
    private var echoAttached = false
    private var driverPark: DispatchSemaphore?
    private var echoes = 0
    // The forced orders of a `Shared` release against a delivery: the publisher whose first hand-off
    // releases the owner, whether that hand-off ran, and the subscriber of the forced release with the
    // number of ordinary values it may receive (none before the decision, the decided one after it).
    private var handOffArmed: Int?
    private var handOffRan = false
    private var forced: (recorder: Int, allowed: Int, order: String)?
    // The owner's registrations in the order it made them, which is the order of its release notices.
    private var registrationOrder: [String] = []
    // Hand-offs each saved publisher has made to the main actor (H3), so a release can wait for the seeds.
    private var handOffs: [Int] = [0, 0]
    // A release held after a release notice (E11). The worker continues when this is signaled.
    private var noticeHold: ExplorerNoticeHold?

    init?(_ kind: ExplorerPassiveKind, verbose: Bool = false) {
        self.kind = kind
        world = ExplorerWorld(verbose: verbose)
        guard let subject = ExplorerTeardownSubject.make(kind, driver: driver) else { return nil }
        self.subject = subject
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if !released {
            for index in 0 ..< 2 where publishers[index] == nil && (index == 0 || publishers[0] != nil) {
                result.append(.save(index))
            }
            // A capture or a driver can name a publisher saved only later, as a registration made
            // before that publisher does.
            for index in 0 ..< 2 where index == 0 || publishers[0] != nil {
                result.append(.capture(index))
                if !driverStarted { result.append(.driver(index)) }
                // H2 runs on the owner's executor: off the main actor for these two owners only.
                if explorerHasDriverPause, !driverStarted, kind == .teardownActor || kind == .teardownShared {
                    result.append(.driverParked(index))
                }
            }
            result += [.releaseOwner(elsewhere: false), .releaseOwner(elsewhere: true), .dropAfterJob]
            // A send that launches the driver without waiting for it to start is deterministic only where
            // the driver runs on the main actor; elsewhere `driver(k)` waits for the start.
            if kind == .teardownMain, !driverStarted { result.append(.apply) }
            // The burst needs the loading phase, which `driver(k)` reaches with its driver started.
            if kind == .publisher, driverStarted { result.append(.request) }
            if kind == .publisher, publishers[0] != nil, !echoAttached { result.append(.subscribeProjected) }
            // E9 on a saved owner publisher: zero and finite initial demand, demand returned from each value, a
            // later request, and the cancellation of one particular subscription.
            if kind == .publisher, publishers[0] != nil, recorders.count < 3 {
                result += [.subscribeZero, .subscribeReturning]
            }
            if subject.workerDrop != nil, park == nil, publishers[0] != nil { result.append(.workerDrop) }
            // The two orders of a release against a delivery the main actor is making, each forced.
            if explorerHasHandOffPause, subject.saveHandingOff != nil, forced == nil {
                for index in 0 ..< 2 where publishers[index] == nil && (index == 0 || publishers[0] != nil) {
                    result.append(.releaseInHandOff(index))
                }
                for index in 0 ..< 2
                where publishers[index] != nil && !recorders.contains(where: { $0.publisher == index }) {
                    result.append(.releaseInDelivery(index))
                }
            }
            // H7: the release inside the decided-delivery window, after the last source check.
            // Only owners whose teardown runs on the releasing thread: a `MainActorHost` tears down on the
            // main actor, which the forced release waits on.
            if explorerHasDecidedDeliveryPause, forced == nil, !sendsIssued,
                kind == .teardownShared || kind == .teardownActor
            {
                for index in 0 ..< 2
                where publishers[index] != nil && !recorders.contains(where: { $0.publisher == index }) {
                    result.append(.releaseDecided(index))
                }
            }
        }
        // E11: the release is held right after the first saved publisher's notice, once a subscriber of
        // that publisher is attached, so the harness can wait for that subscriber's completion. Only an
        // owner with nothing to process: one that accepted a change tears down after its drain, on the
        // drainer's thread, where the pause bound for the releasing task does not run.
        if !released, !sendsIssued, explorerHasReleaseNoticePause, subject.releaseNoticing != nil, publishers[0] != nil,
            recorders.contains(where: { $0.publisher == 0 && !$0.finished })
        {
            result.append(.releaseNotice)
        }
        for index in 0 ..< 2 where publishers[index] != nil { result.append(.attach(index)) }
        if noticeHold != nil { result.append(.noticeGo) }
        if park != nil { result.append(.workerReturn) }
        if driverPark != nil { result.append(.driverGo) }
        if turns < 2 { result.append(.turn) }
        // A later request, before or after the release (demand first made after it receives only the completion,
        // I28), and the cancellation of the oldest open subscription.
        if recorders.contains(where: { $0.limited && !$0.cancelled && !$0.finished }) { result.append(.requestOldest) }
        if kind == .publisher, recorders.contains(where: { !$0.cancelled && !$0.finished }) {
            result.append(.cancelFirstSubscriber)
        }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            await perform(event)
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .save(let index):
            if let saveCounting = subject.saveCounting {
                publishers[index] = await saveCounting { [weak self] in
                    MainActor.assumeIsolated { self?.handOffs[index] += 1 }
                }
            } else {
                publishers[index] = await subject.save()
            }
            if publishers[index] != nil { registrationOrder.append("publisher \(index)") }
        case .attach(let index):
            attach(index)
        case .subscribeZero:
            attach(0) { $0.initialDemand = .none }
        case .subscribeReturning:
            attach(0) { recorder in
                recorder.initialDemand = .max(1)
                recorder.returnedDemand = .max(1)
            }
        case .requestOldest:
            recorders.first { $0.limited && !$0.cancelled && !$0.finished }?.request(1)
        case .cancelFirstSubscriber:
            recorders.first { !$0.cancelled && !$0.finished }?.cancel()
        case .capture(let index):
            let hold = ExplorerAttachOnRelease(kind == .teardownMain ? world : nil, teardown: world) { [weak self] in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.attach(index) }
            }
            if let token = await subject.capture(hold) {
                tokens.append(token)
                captureHooks.append(hold.state)
                registrationOrder.append("capture \(index)")
            }
        case .driver(let index):
            // The publisher slice's burst cancels and relaunches the fetch, so its handler does nothing.
            let teardownSlice = kind != .publisher
            let driverCancelled = driverHookCancelled
            driver.set { [weak self, world] in
                defer { driverCancelled.withLock { $0 = true } }
                guard teardownSlice else { return }
                // In the teardown slices an owner cancels its driver only in its teardown.
                world.state.withLock { $0.ownerTeardown = true }
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.attach(index) }
            }
            sendsIssued = true
            driverStarted = await subject.startDriver()
            if teardownSlice, driverStarted { driverHookArmed = true }
        case .driverParked(let index):
            // The publisher slice's burst cancels and relaunches the fetch, so its handler does nothing.
            let teardownSlice = kind != .publisher
            let driverCancelled = driverHookCancelled
            driver.set { [weak self, world] in
                defer { driverCancelled.withLock { $0 = true } }
                guard teardownSlice else { return }
                // In the teardown slices an owner cancels its driver only in its teardown.
                world.state.withLock { $0.ownerTeardown = true }
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.attach(index) }
            }
            let reached = DispatchSemaphore(value: 0)
            let proceed = DispatchSemaphore(value: 0)
            sendsIssued = true
            // H6 is task-local: the batch's processing inherits it from the send that scheduled it.
            await explorerWithDriverPause({
                reached.signal()
                _ = explorerWait(proceed)
            }) { await subject.send() }
            let parked = explorerWait(reached)
            driverStarted = true
            if parked {
                driverPark = proceed
                if teardownSlice { driverHookArmed = true }
            } else {
                world.violate(.stuck, "the launched driver never reached its start")
            }
        case .driverGo:
            driverPark?.signal()
            driverPark = nil
            _ = await driver.waitStarted()
        case .apply:
            driverStarted = true
            sendsIssued = true
            await subject.send()
        case .request:
            // A burst: 40 changes of the loading phase in one step.
            sendsIssued = true
            await subject.changes(40)
        case .subscribeProjected:
            // An echoing subscriber of publisher 0: every value it receives changes the owner again,
            // up to 100 times, a recursive delivery that I32's allowance bounds.
            echoAttached = true
            attach(0)
            let changes = subject.changes
            recorders.last?.onValue = { [weak self] in
                guard let self, echoes < 100 else { return }
                echoes += 1
                sendsIssued = true
                Task { @MainActor [weak self] in
                    // A change scheduled before the release reads its bound is dropped.
                    guard let self, !echoStopped else { return }
                    await changes(1)
                }
            }
        case .releaseOwner(let elsewhere):
            await settleDeliveries()
            await recordAccepted()
            released = true
            if elsewhere {
                if !subject.releaseElsewhere() {
                    world.violate(.stuck, "the owner's release on a worker never returned")
                }
            } else {
                subject.releaseMain()
            }
        case .dropAfterJob:
            await settleDeliveries()
            await recordAccepted()
            released = true
            await subject.releaseAfterJob()
        case .workerDrop:
            await settleDeliveries()
            await recordAccepted()
            park = await subject.workerDrop?()
            released = true
            if park == nil { world.violate(.stuck, "the worker never dropped the owner") }
        case .workerReturn:
            if let park, !park.letReturn() { world.violate(.stuck, "the worker never returned") }
            park = nil
        case .releaseInHandOff(let index):
            guard let tornDown = await prepareForcedRelease(), let saveHandingOff = subject.saveHandingOff else {
                return
            }
            handOffArmed = index
            handOffRan = false
            publishers[index] = saveHandingOff { [weak self] in
                MainActor.assumeIsolated { self?.handedOff(index, tornDown) }
            }
            // The hand-off is a main-actor job of the owner's delivery task; the pause marks that it ran.
            if !(await hop(until: { self.handOffRan }, limit: 2000)) {
                world.violate(.stuck, "the first hand-off of publisher \(index) never ran")
            }
        case .releaseInDelivery(let index):
            guard let tornDown = await prepareForcedRelease() else { return }
            // Its first value can arrive inside the attach, so the release is in place before it.
            attach(index) { [weak self] recorder in
                self?.forced = (recorder.index, 1, "from inside its first value, after the delivery was decided")
                recorder.onValue = { [weak self, weak recorder] in
                    guard let self, let recorder, recorder.values.count == 1 else { return }
                    releaseForced(tornDown)
                }
            }
            guard let recorder = recorders.last else { return }
            if !(await hop(until: { recorder.values.count > 0 || recorder.finished }, limit: 2000)) {
                world.violate(.stuck, "subscriber \(recorder.index) never received its first value")
            }
        case .releaseNotice:
            await releaseNotice()
        case .releaseDecided(let index):
            guard let tornDown = await prepareForcedRelease() else { return }
            let seeded = await hop(
                until: { self.publishers[index] == nil || self.handOffs[index] > 0 },
                limit: 2000
            )
            if !seeded { world.violate(.stuck, "publisher \(index)'s seed never reached the main actor") }
            let ran = OSAllocatedUnfairLock(initialState: false)
            explorerWithDecidedDeliveryPause({ [weak self] in
                let first = ran.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                MainActor.assumeIsolated {
                    guard let self, let recorder = self.recorders.last else { return }
                    self.forced = (recorder.index, 1, "inside its first delivery, after the last source check")
                    self.releaseForced(tornDown)
                }
            }) { attach(index) { $0.decidedAllowance = 1 } }
            if !ran.withLock({ $0 }) { world.note("no delivery was decided at the attach") }
        case .noticeGo:
            if let hold = noticeHold, !hold.proceed() { world.violate(.stuck, "the held release never returned") }
            noticeHold = nil
        case .turn:
            await Task { @MainActor in }.value
        default:
            break
        }
    }

    // E11: the main actor runs between two of the owner's release notices. Every saved publisher's seed
    // has reached the main actor and every subscriber has the current revision; the owner is released on
    // a worker that H4 holds right after it notified publisher 0; the step returns once every subscriber
    // of publisher 0 has finished, with the worker still held before the next notice.
    private func releaseNotice() async {
        guard let releaseNoticing = subject.releaseNoticing else { return }
        await settleDeliveries()
        let seeded = await hop(
            until: { (0 ..< 2).allSatisfy { self.publishers[$0] == nil || self.handOffs[$0] > 0 } },
            limit: 2000
        )
        if !seeded { world.violate(.stuck, "a saved publisher's seed never reached the main actor") }
        await recordAccepted()
        guard let position = registrationOrder.firstIndex(of: "publisher 0") else { return }
        let hold = ExplorerNoticeHold(after: position + 1)
        released = true
        world.note("release held after notice \(position + 1)")
        releaseNoticing(hold.pause, hold.returnedAction)
        guard hold.waitProgress() else {
            world.violate(.stuck, "the owner's release never reached its notice to publisher 0")
            return
        }
        guard hold.isHeld else {
            world.violate(.stuck, "the owner's release returned before its notice to publisher 0")
            return
        }
        noticeHold = hold
        let finished = await hop(
            until: { self.recorders.filter { $0.publisher == 0 }.allSatisfy(\.finished) },
            limit: 2000
        )
        if !finished { world.violate(.stuck, "publisher 0's subscribers never finished after its release notice") }
    }

    // `Shared` hands each snapshot to the main actor on a task of its delivery path, which nothing the
    // harness does orders. Before a release, the harness waits until every attached subscriber has
    // received the owner's current revision, so no hand-off is in flight when the owner goes; the two
    // orders of a release against a delivery are the forced events.
    private func settleDeliveries() async {
        guard kind == .teardownShared, !released, let revision = await subject.revision() else { return }
        let settled = await hop(
            until: { self.recorders.allSatisfy { $0.finished || $0.values.last == revision } },
            limit: 2000
        )
        if !settled {
            world.violate(.stuck, "the publishers never delivered revision \(revision) before the release")
        }
    }
    private func hop(until condition: () -> Bool, limit: Int) async -> Bool {
        for _ in 0 ..< limit {
            if condition() { return true }
            await Task { @MainActor in }.value
        }
        return condition()
    }
    // Settles the deliveries, records the accepted bound, and registers a callback whose capture signals
    // when the owner releases it: the third step of its teardown, after every publisher's source closed.
    private func prepareForcedRelease() async -> DispatchSemaphore? {
        await settleDeliveries()
        await recordAccepted()
        let tornDown = DispatchSemaphore(value: 0)
        let sentinel = ExplorerAttachOnRelease(nil, teardown: world) { tornDown.signal() }
        guard let token = await subject.capture(sentinel) else {
            world.violate(.stuck, "the owner refused the teardown sentinel's registration")
            return nil
        }
        tokens.append(token)
        registrationOrder.append("sentinel")
        return tornDown
    }
    // The pause of the first hand-off of an armed publisher: a subscriber attaches, and the owner is
    // released before the delivery is decided.
    private func handedOff(_ index: Int, _ tornDown: DispatchSemaphore) {
        guard handOffArmed == index else { return }
        handOffArmed = nil
        handOffRan = true
        attach(index)
        if let recorder = recorders.last {
            forced = (recorder.index, 0, "inside its publisher's hand-off, before the delivery was decided")
        }
        releaseForced(tornDown)
    }
    // Releases the owner on a worker while the main actor waits, then waits until its teardown released
    // the sentinel's callbacks, which it does only after every publisher's source closed.
    private func releaseForced(_ tornDown: DispatchSemaphore) {
        released = true
        world.note("forced release")
        if !subject.releaseElsewhere() {
            world.violate(.stuck, "the owner's release on a worker never returned")
        } else if !explorerWait(tornDown) {
            world.violate(.stuck, "the released owner never began its teardown")
        }
    }

    private var acceptedAtRelease: UInt64?
    // I28's exception covers batches still being processed at the release: only once the owner has
    // accepted a change in this sequence. An owner with nothing to process tears down at its release, so a
    // value delivered after it, such as its initial revision 0, is still a violation.
    private var sendsIssued = false
    private var echoStopped = false
    private func recordAccepted() async {
        // An echoing subscriber stops changing the owner first, so the revision read here is the last
        // one accepted before the release.
        echoes = 100
        echoStopped = true
        guard sendsIssued, acceptedAtRelease == nil else { return }
        acceptedAtRelease = await subject.revision()
    }

    private func attach(_ index: Int, configure: ((ExplorerTeardownRecorder) -> Void)? = nil) {
        guard let publisher = publishers[index] else { return }
        let recorder = ExplorerTeardownRecorder(
            index: recorders.count,
            publisher: index,
            world: world,
            gone: subject.gone,
            acceptedBound: { [weak self] in self?.acceptedAtRelease }
        )
        recorders.append(recorder)
        configure?(recorder)
        world.note("attach subscriber \(recorder.index) to publisher \(index)")
        publisher.subscribe(recorder)
    }

    private func quiesce() async {
        world.note("quiesce")
        if let parked = driverPark {
            // The parked driver goes on and starts before the owner is released.
            parked.signal()
            driverPark = nil
            _ = await driver.waitStarted()
        }
        if let park, !park.letReturn() { world.violate(.stuck, "the worker never returned") }
        park = nil
        if let hold = noticeHold, !hold.proceed() { world.violate(.stuck, "the held release never returned") }
        noticeHold = nil
        if !released {
            await recordAccepted()
            subject.releaseMain()
        }
        let hooksSettled = {
            self.captureHooks.allSatisfy(\.isReleased)
                && (!self.driverHookArmed || self.driverHookCancelled.withLock { $0 })
        }
        let finished = await hop(
            until: {
                self.subject.gone() && hooksSettled() && self.recorders.allSatisfy { $0.finished || $0.cancelled }
            },
            limit: 2000
        )
        if !finished {
            world.violate(
                .ownerReleasedUnfinished,
                "at quiescence: owner gone \(subject.gone()), hooks settled \(hooksSettled()), unfinished subscribers \(recorders.filter { !$0.finished && !$0.cancelled }.map(\.index))"
            )
        }
        // A release before the delivery's decision discards the value; one after it lets at most that
        // decided value through. Either way the subscriber then finishes, as I30 checks.
        if let forced, let recorder = recorders.first(where: { $0.index == forced.recorder }),
            recorder.values.count > forced.allowed
        {
            world.violate(
                .ownerReleasedPending,
                "subscriber \(recorder.index), whose owner was released \(forced.order), received ordinary revisions \(recorder.values)"
            )
        }
        // Disarm capture hooks before explicit fixture cleanup so dropping `tokens` cannot
        // impersonate genuine owner teardown if an owner leaked a registration.
        for hook in captureHooks { hook.disarm() }
        captureHooks = []
        tokens = []
        publishers = [nil, nil]
        recorders = []
    }
}

/// Holds an owner's releasing thread right after its `after`-th release notice (H4) until `proceed()`.
nonisolated final class ExplorerNoticeHold: Sendable {
    private let notices = OSAllocatedUnfairLock(initialState: 0)
    private let held = OSAllocatedUnfairLock(initialState: false)
    private let progressed = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let returned = DispatchSemaphore(value: 0)
    let after: Int

    init(after: Int) { self.after = after }

    var pause: @Sendable () -> Void {
        { [self] in
            let count = notices.withLock { count -> Int in
                count += 1
                return count
            }
            guard count == after else { return }
            held.withLock { $0 = true }
            progressed.signal()
            _ = explorerWait(release, seconds: 60)
        }
    }
    var returnedAction: @Sendable () -> Void {
        { [self] in
            returned.signal()
            progressed.signal()
        }
    }
    var isHeld: Bool { held.withLock { $0 } }
    /// Waits until the worker is held or has returned; `false` means stuck.
    func waitProgress() -> Bool { explorerWait(progressed) }
    /// Lets the held worker go on and waits until its release returned; `false` means stuck.
    func proceed() -> Bool {
        release.signal()
        return explorerWait(returned)
    }
}

@MainActor @Suite struct ExplorerTeardownHarnessTests {
    @Test func teardownRecorderStillFlagsDeliveryAfterOwnerTeardown() {
        // Planted I28: once genuine owner teardown has begun, even a revision <= acceptedBound
        // delivered to a subscriber attached after release must still violate I28.
        let postTeardown = ExplorerWorld()
        postTeardown.state.withLock { $0.ownerTeardown = true }
        let afterTeardown = ExplorerTeardownRecorder(
            index: 0,
            publisher: 0,
            world: postTeardown,
            gone: { true },
            acceptedBound: { 1 }
        )
        afterTeardown.receive(subscription: ExplorerNullSubscription())
        _ = afterTeardown.receive(1)
        #expect(postTeardown.violations.contains { $0.invariant == .ownerReleasedDelivery })

        // Control + planted post-bound I28: before teardown begins, accepted revision 1 is allowed
        // under OBS-005 while any newer revision 2 still violates I28.
        let preTeardown = ExplorerWorld()
        let beforeTeardown = ExplorerTeardownRecorder(
            index: 0,
            publisher: 0,
            world: preTeardown,
            gone: { true },
            acceptedBound: { 1 }
        )
        beforeTeardown.receive(subscription: ExplorerNullSubscription())
        _ = beforeTeardown.receive(1)
        #expect(preTeardown.violations.isEmpty)
        _ = beforeTeardown.receive(2)
        #expect(preTeardown.violations.contains { $0.invariant == .ownerReleasedDelivery })

        // Planted I29: a subscriber attached before release still flags ordinary delivery after
        // teardown begins.
        let pendingWorld = ExplorerWorld()
        var released = false
        let attachedEarlier = ExplorerTeardownRecorder(
            index: 0,
            publisher: 0,
            world: pendingWorld,
            gone: { released },
            acceptedBound: { 1 }
        )
        attachedEarlier.receive(subscription: ExplorerNullSubscription())
        released = true
        pendingWorld.state.withLock { $0.ownerTeardown = true }
        _ = attachedEarlier.receive(1)
        #expect(pendingWorld.violations.contains { $0.invariant == .ownerReleasedPending })
    }

    @Test func disarmedCaptureHookDoesNotImpersonateOwnerTeardown() {
        let disarmedWorld = ExplorerWorld()
        let disarmedAttached = OSAllocatedUnfairLock(initialState: false)
        let disarmedState: ExplorerAttachOnRelease.State
        do {
            let hook = ExplorerAttachOnRelease(nil, teardown: disarmedWorld) {
                disarmedAttached.withLock { $0 = true }
            }
            disarmedState = hook.state
            #expect(!disarmedState.isReleased)
            disarmedState.disarm()
        }
        #expect(disarmedState.isReleased)
        #expect(!disarmedAttached.withLock { $0 })
        #expect(!disarmedWorld.state.withLock { $0.ownerTeardown })

        let armedWorld = ExplorerWorld()
        let armedAttached = OSAllocatedUnfairLock(initialState: false)
        let armedState: ExplorerAttachOnRelease.State
        do {
            let hook = ExplorerAttachOnRelease(nil, teardown: armedWorld) {
                armedAttached.withLock { $0 = true }
            }
            armedState = hook.state
        }
        #expect(armedState.isReleased)
        #expect(armedAttached.withLock { $0 })
        #expect(armedWorld.state.withLock { $0.ownerTeardown })
    }

    @Test(.parksCooperativeThread) func sharedTeardownWaitsForGenuineTeardownBeforeClearingTokens() async throws {
        let scripts: [[ExplorerEvent]] = [
            [.driverParked(0), .driverGo, .capture(0), .save(0)],
            [.driver(0), .capture(0), .save(0)],
            [.capture(0), .save(0), .driverParked(1), .releaseOwner(elsewhere: false)],
            [.driver(0), .save(0), .capture(1), .capture(0)],
        ]
        let configuration = ExplorerConfiguration(kind: .teardownShared, families: [.core], depth: 4)
        for script in scripts {
            let outcome = try #require(await explorerRun(configuration, script))
            #expect(outcome.violations.isEmpty, "\(explorerScript(script)): \(outcome.violations)")
        }
    }
}
