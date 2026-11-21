import Combine
import Dispatch
import Foundation
import StateMachine
import StateMachineUI

/// The event families an exploration enables.
struct ExplorerFamilies: OptionSet, Hashable, Sendable {
    let rawValue: Int
    /// Synchronous observation, stop, apply, host delivery, finish, and cancellation, drops, turns.
    static let core = ExplorerFamilies(rawValue: 1)
    /// Asynchronous registration closures, followers, and their cancellation.
    static let async = ExplorerFamilies(rawValue: 2)
    /// Combine subscribers of `presentedSnapshots`.
    static let combine = ExplorerFamilies(rawValue: 4)
    /// One armed callback per sequence.
    static let reentrant = ExplorerFamilies(rawValue: 8)
    /// The second host.
    static let second = ExplorerFamilies(rawValue: 16)
    /// Armed callbacks that run two events.
    static let pairs = ExplorerFamilies(rawValue: 32)
    /// An isolated host on another actor that shares host A's slot.
    static let isolated = ExplorerFamilies(rawValue: 64)
    /// Callback sources: a `MainActorStateMachineHost` (M) and an `IsolatedStateMachineHost<MainActor>` (I).
    static let callback = ExplorerFamilies(rawValue: 128)
    /// Hosts A and B free a slot from the destructor of their token action's capture.
    static let lease = ExplorerFamilies(rawValue: 256)
    /// Armed callbacks that run three events (with `pairs`).
    static let triples = ExplorerFamilies(rawValue: 512)
    /// Deliveries, Combine demand, and cancellation from worker threads.
    static let workers = ExplorerFamilies(rawValue: 1024)
    /// Restricts the alphabet to the follower hand-off slice.
    static let followers = ExplorerFamilies(rawValue: 2048)
    /// Driving: the host delivers from inside each cancellation of its subscription.
    ///
    /// The disposal path's cancellation is included. Passive hosts offer the same event in `core`.
    static let cancelDelivery = ExplorerFamilies(rawValue: 4096)
    /// Passive: hosts keep independent revision clocks and can offer an equal revision (E1).
    static let clocks = ExplorerFamilies(rawValue: 8192)
    /// The raw owner's registrations and its `subscriberCount` (E8).
    static let counts = ExplorerFamilies(rawValue: 16384)
    /// The raw owner's completions, drainer, edits, and reconciliation (E4, E13).
    static let reconcile = ExplorerFamilies(rawValue: 32768)
    /// Driving: refused, occupied, and closed creation, and `resumeObserving()` (E2).
    static let resume = ExplorerFamilies(rawValue: 65536)
    /// Combine demand shapes, older subscriptions, and a saved projected publisher (E9).
    static let demand = ExplorerFamilies(rawValue: 131_072)
    /// A selected parked closure resumed out of order, the oldest follower, a direct call's task (E5, E6).
    static let selection = ExplorerFamilies(rawValue: 262_144)
    /// The interruption matrix: every interrupting event at every armable site, in every phase.
    static let matrix = ExplorerFamilies(rawValue: 4_194_304)
    /// Two independently armed hooks, and a hook that arms another (E15).
    static let chains = ExplorerFamilies(rawValue: 2_097_152)
    /// The raw owner's copies around its release.
    static let copies = ExplorerFamilies(rawValue: 1_048_576)
    /// Armable client callback sites: host calls, the subscription before demand, the completion, and
    /// destructors (69).
    static let sites = ExplorerFamilies(rawValue: 524_288)
    /// Driving Combine: demand requested, and a subscription cancelled, off the main actor through
    /// `receive(on:)`, and a callback inside a presentation publisher's delivery decision (H10, E10).
    static let elsewhere = ExplorerFamilies(rawValue: 8_388_608)
}

/// What one run of a sequence found.
struct ExplorerOutcome: Sendable {
    var violations: [ExplorerViolation]
    /// The events enabled after the last step, before quiescence.
    var enabled: [ExplorerEvent]
    /// The abstract state after the last step, for optional state hashing.
    var fingerprint: String
    var trace: [String]
    /// An armed hook did not run during the event after its `arm`, so the sequence is equivalent to the
    /// one that arms after that event, which is run too: this one is neither extended nor reported.
    var redundant = false
}

/// Runs one sequence against a fresh passive presentation, checks the invariants after every step,
/// and brings the run to quiescence.
@MainActor final class ExplorerPassiveRun: ExplorerRunner {
    struct Factory {
        let attempt: Int
        let host: Int
        let continuation: CheckedContinuation<Bool, Never>
    }
    enum FactoryMode { case parkFirst, registerFirst, immediate, immediateFinished }
    struct Call {
        let attempt: Int
        let follower: Bool
        let task: Task<Void, Never>
        var cancelled = false
        /// A direct asynchronous observation through a parked closure, whose task E6 can cancel.
        var direct = false
    }

    let kind: ExplorerPassiveKind
    let families: ExplorerFamilies
    let world: ExplorerWorld
    let hosts: [ExplorerHost]
    private var subject: ExplorerPassiveSubject!
    private var installed: [AnyObject] = []

    private var attempts = 0
    private var current: Int?
    // The generation the presentation is in: a new one at every observation, stop, and release. An
    // applied snapshot belongs to it.
    private var epoch = 0
    // Attempts whose follower task was cancelled: their own deliveries must not be shown afterward.
    private var cancelledFollowers: Set<Int> = []
    private var parked: [Factory] = []
    private var calls: [Call] = []
    private var running = 0
    // Armed callbacks, each run once. Enumeration arms at most one per sequence; a replayed script may
    // arm several.
    private var armed: [(ExplorerHook, ExplorerEvent)] = []
    private var armUsed = false
    // E15 (`chains`): arms made so far; the family allows two per sequence.
    private var arms = 0
    private var inHook = false
    private var lastShown: (id: Int, revision: UInt64)
    private var shown: Set<Int> = []
    private var letGoAtBoundary: Set<Int> = []
    private var followersAtBoundary: Set<Int> = []
    // Values applied inside a callback, which a publication in progress defers: a follower's
    // cancellation before they are shown withdraws them. A top-level apply is shown at once.
    private var deferrable: Set<Int> = []
    private var accepted: [(revision: UInt64, attempt: Int?)] = []
    private var refused: Set<Int> = []
    private var refusedApplies: [UInt64] = []
    private var fired = 0
    private var tearingDown = false
    private var echoHost: Int?
    private var echoes = 0
    private var cancelDelivers = false
    private var turnBudget = ExplorerTurnBudget()
    private var custodyCheckDue = false
    private var dropPending = false
    private var hookLeftPending = false
    // The first value made after each follower's cancellation: a value applied before it is withdrawn.
    private var cancelMarks: [Int: Int] = [:]
    // `applyBelow` refusals that a pending newer value justified when they happened.
    private var justifiedRefusals: Set<UInt64> = []
    private var claimed: [SnapshotSequence<ExplorerShot>.AsyncIterator] = []
    // Enumeration prunes an arm whose hook stays idle for the next event; a replayed script runs as written.
    private let pruning: Bool
    private var subscribers: [ExplorerSubscriber] = []
    private var saved: ((ExplorerSubscriber) -> Void)?
    private var savedProjected: ((ExplorerSubscriber) -> Void)?
    private var events: [ExplorerEvent] = []
    private var usedSecond = false
    private var usedFirst = false
    private let island = ExplorerIsland()
    private lazy var islandHost = ExplorerIslandHost(hosts[0])
    private lazy var actorHost = ExplorerActorHost(hosts[0])
    private lazy var mainHost: ExplorerMainHost = {
        let host = ExplorerMainHost(world, index: 2)
        host.onCancel = { [weak self] in self?.fire(.onCancel) }
        return host
    }()
    private lazy var mainIsolatedHost: ExplorerMainIsolatedHost = {
        let host = ExplorerMainIsolatedHost(world)
        host.onCancel = { [weak self] in self?.fire(.onCancel) }
        if families.contains(.sites) || families.contains(.matrix) { host.site = { [weak self] in self?.fire($0) } }
        return host
    }()
    private var islandCalled = false
    private var islandDone = false
    private var turns = 0
    // A change callback ran an event: the snapshot whose publication it announced is still assigned
    // after it, as a publication in progress is, so the next newly shown snapshot is exempt from I10.
    private var assigningAnnounced: UInt64?
    // `objectWillChange` (or Observation change) callbacks so far (I48).
    private var willChanges = 0
    // I37: the harness step in progress, and the step in which each observation's first snapshot was shown.
    private var step = 0
    private var reportsThisStep = 0
    // I51: the expected invalidation trace of each tracked property.
    private let traces = ExplorerTraces()
    private var firedAtStepStart = 0
    private var firstShownStep: [Int: Int] = [:]
    private var changeDepth = 0

    init?(_ kind: ExplorerPassiveKind, families: ExplorerFamilies, verbose: Bool = false, pruning: Bool = false) {
        self.pruning = pruning
        self.kind = kind
        self.families = families
        world = ExplorerWorld(verbose: verbose)
        let lease = families.contains(.lease)
        hosts = [ExplorerHost(0, world, leaseMode: lease), ExplorerHost(1, world, leaseMode: lease)]
        let initial = world.initialValue()
        lastShown = (initial.id, 0)
        shown.insert(initial.id)
        let capture = ExplorerCapture(world)
        guard
            let subject = ExplorerPassiveSubject.make(
                kind,
                initial: initial,
                revision: { [weak self] shot in
                    let revision = capture.read(shot)
                    self?.elementRead(shot)
                    self?.fire(.revision)
                    return revision
                }
            )
        else { return nil }
        self.subject = subject
        traces.tracksSnapshot = kind == .observation
        installed = subject.install({ [weak self] in self?.reported($0) }, { [weak self] in self?.changed($0) })
        subject.watch(world)
        if families.contains(.clocks) { world.useIndependentClocks() }
        if families.contains(.sites) || families.contains(.matrix) {
            mainHost.site = { [weak self] in self?.fire($0) }
            for host in hosts { host.armSites { [weak self] hook in MainActor.assumeIsolated { self?.fire(hook) } } }
            world.setDestroyHook { [weak self] in MainActor.assumeIsolated { self?.fire(.destroy) } }
        }
        for host in hosts {
            host.armOnCancel { [weak self] in MainActor.assumeIsolated { self?.fire(.onCancel) } }
        }
    }

    // MARK: Enabled events

    func enabled() -> [ExplorerEvent] {
        if families.contains(.matrix) { return matrixEnabled() }
        var result: [ExplorerEvent] = []
        let held = subject.held()
        // Symmetry: host B is offered only once an event has named host A.
        let hostRange = families.contains(.second) && usedSecond ? 0 ..< 2 : 0 ..< 1
        let secondOffer = families.contains(.second) && !usedSecond && usedFirst ? [1] : []
        let offered = Array(hostRange) + secondOffer
        if families.contains(.core) {
            if held {
                for host in offered { result.append(.observe(host)) }
                if current != nil { result.append(.stop) }
                // `applyBelow` places a value between two of one clock's revisions, which independent
                // clocks do not order.
                result += families.contains(.clocks) ? [.apply] : [.apply, .applyBelow]
                result += [.dropMain, .dropElsewhere, .dropAfterJob]
            }
            for host in hostRange {
                if let id = world.slot(of: host), let record = world.registration(id) {
                    if record.phase == .active, !record.parked {
                        result += [.deliver(host), .finish(host), .hostCancel(host), .hostCancelMain(host)]
                        if families.contains(.clocks) { result.append(.deliverEqual(host)) }
                    }
                }
                if !hosts[host].parked.isEmpty { result.append(.hostCancelReturn(host)) }
            }
            if turns < 2 { result.append(.turn) }
            // A host of the client's own that delivers from inside each cancellation of its token. The
            // mode holds for the whole sequence, so it is offered only as the first event.
            if events.isEmpty { result.append(.deliverInCancel(0)) }
        }
        if families.contains(.callback) {
            for host in 2 ..< 4 {
                if held { result.append(.observe(host)) }
                if let id = world.slot(of: host), world.registration(id)?.phase == .active {
                    result += [.deliver(host), .finish(host), .hostCancelMain(host)]
                }
            }
            if !mainHost.closed { result.append(.close) }
            // M and I deliver from inside each cancellation, offered as the first event as for host A.
            if events.isEmpty { result += [.deliverInCancel(2), .deliverInCancel(3)] }
        }
        if families.contains(.async) {
            if held {
                for host in offered {
                    result += [
                        .observeFrom(host), .observeAsync(host), .followAsync(host), .observeAsyncHeld(host),
                        .observeSeq(host), .followSeq(host), .observeAsyncNow(host), .observeAsyncFinished(host),
                        .observeClaimed(host), .followCancelled(host), .followUnseeded(host),
                    ]
                }
            }
            if !parked.isEmpty { result += [.factoryReturn, .factoryThrow] }
            if families.contains(.isolated) {
                if held, !islandCalled { result.append(.observeIsolated) }
                if islandHost.registered { result.append(.isolatedReturn) }
                if held { result.append(.observeActor) }
                if actorHost.waiting > 0 { result.append(.actorReturn) }
            }
            if calls.contains(where: { $0.follower && !$0.cancelled }) { result.append(.cancelFollower) }
            if families.contains(.selection) {
                if parked.count > 1 { result += [.factoryReturnNewest, .factoryThrowNewest] }
                if calls.filter({ $0.follower && !$0.cancelled }).count > 1 { result.append(.cancelFollowerOldest) }
                if calls.contains(where: { !$0.follower && !$0.cancelled && $0.direct }) { result.append(.cancelCall) }
            }
        }
        if families.contains(.workers), echoHost == nil { result.append(.echo(0)) }
        if families.contains(.workers) {
            for host in hostRange {
                if let id = world.slot(of: host), world.registration(id)?.phase == .active {
                    result.append(.deliverElsewhere(host))
                }
            }
        }
        if explorerHasRemovalPause, families.contains(.core), current != nil, !hosts[0].parked.isEmpty {
            result.append(.stopRacingRemoval)
        }
        // H8: a stop whose removal checks custody inside the window before its completion.
        if explorerHasRemovalCompletionPause, families.contains(.core), current != nil { result.append(.stopCustody) }
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
        if families.contains(.reentrant), arms < (families.contains(.chains) ? 2 : 1), held {
            var hooks: [ExplorerHook] = [.report, .change, .onCancel, .revision]
            if families.contains(.async) { hooks.append(.factory) }
            if families.contains(.combine), subject.subscribe != nil {
                hooks += [.subscription, .value]
                if subject.subscribeProjected != nil { hooks.append(.projection) }
            }
            if families.contains(.sites) {
                hooks += [.hostRead, .hostSubscribe, .destroy]
                if families.contains(.combine), subject.subscribe != nil {
                    hooks += [.subscriptionBefore, .completion]
                }
            }
            var inner: [ExplorerEvent] = [.stop, .apply, .observe(0), .dropMain, .finish(0)]
            if families.contains(.second) { inner.append(.observe(1)) }
            if families.contains(.async) {
                inner += [
                    .observeAsync(0), .followSeq(0), .cancelFollower, .observeAsyncNow(0), .observeAsyncFinished(0),
                ]
            }
            if families.contains(.combine), subject.subscribe != nil {
                inner += [.subscribe(saved: false, unlimited: true), .cancelSubscription, .request]
            }
            if families.contains(.pairs) {
                var pairs: [ExplorerEvent] = []
                let parts: [ExplorerEvent] =
                    [.stop, .apply, .applyBelow, .observe(0)]
                    + (families.contains(.async) ? [.followSeq(0), .cancelFollower] : [])
                for first in parts { for second in parts where second != first { pairs.append(.then(first, second)) } }
                inner += pairs
                if families.contains(.triples) {
                    for first in parts {
                        for second in parts where second != first {
                            for third in parts where third != first && third != second {
                                inner.append(.then(first, .then(second, third)))
                            }
                        }
                    }
                }
            }
            // E15: a hook that arms a second hook, which then fires on its own later run.
            if families.contains(.chains) {
                for second in [ExplorerHook.report, .change, .onCancel] {
                    for event in [ExplorerEvent.stop, .apply, .observe(0)] { inner.append(.arm(second, event)) }
                }
            }
            for hook in hooks { for event in inner { result.append(.arm(hook, event)) } }
        }
        return families.contains(.followers) ? followerFilter(result) : result
    }

    // The matrix family: the four passive forms (a shared host, a `MainActor` host, a main-confined
    // isolated host, an asynchronous closure, and a sequence), what puts a registration in each phase,
    // and every interrupting event armed at every armable site. The isolated host has no armable
    // registration site of its own.
    private func matrixEnabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        let held = subject.held()
        if held {
            result += [.observe(0), .observe(1), .observe(2), .observe(3), .observeAsyncNow(0), .observeSeq(0), .apply]
            result += [.dropMain, .dropElsewhere]
            if current != nil { result.append(.stop) }
            if subject.subscribe != nil, subscribers.isEmpty {
                result.append(.subscribe(saved: false, unlimited: true))
            }
        }
        for host in 0 ..< 4 {
            if let id = world.slot(of: host), let record = world.registration(id), record.phase == .active,
                !record.parked
            {
                result += [.deliver(host), .finish(host), .hostCancelMain(host)]
            }
        }
        if turns < 2 { result.append(.turn) }
        if !armUsed, held {
            var hooks: [ExplorerHook] = [.change, .report, .hostSubscribe, .hostRead, .onCancel, .destroy]
            if subject.subscribe != nil { hooks += [.subscriptionBefore, .value, .completion] }
            let inner: [ExplorerEvent] = [
                .stop, .dropMain, .dropElsewhere, .observe(0), .observe(1), .observe(2), .observe(3),
            ]
            for hook in hooks { for event in inner { result.append(.arm(hook, event)) } }
        }
        return result
    }

    // The follower hand-off slice: the `followers` family's events and nothing else.
    private func followerFilter(_ events: [ExplorerEvent]) -> [ExplorerEvent] {
        events.filter { event in
            switch event {
            case .followAsync, .followSeq, .factoryReturn, .factoryThrow, .cancelFollower, .deliver, .turn: true
            case .arm(.change, let inner):
                switch inner {
                case .apply, .cancelFollower, .then(.apply, .cancelFollower), .then(.cancelFollower, .apply): true
                default: false
                }
            default: false
            }
        }
    }

    var fingerprint: String {
        let registrations = world.state.withLock { state in
            state.registrations.values.sorted { $0.id < $1.id }
                .map { "\($0.host):\($0.phase):\($0.hostEnded):\($0.parked):\(state.letGo.contains($0.attempt ?? -1))" }
        }
        let reports = world.state.withLock { $0.reports }
        return [
            "held=\(subject.held())", "current=\(current != nil)", "parked=\(parked.map(\.host))",
            "calls=\(calls.map { "\($0.follower):\($0.cancelled)" })", "regs=\(registrations)",
            "shownOrigin=\(world.attempt(of: lastShown.id).map { world.isLetGo($0) } ?? false)",
            "observing=\(subject.isObserving() ?? false)", "reports=\(reports.count % 2):\(reports.last ?? false)",
            "armed=\(armed.map { "\($0.0)\($0.1)" }):\(armUsed)",
            "subs=\(subscribers.map { "\($0.cancelled)\($0.finished)\($0.wantsMore)" })", "saved=\(saved != nil)",
            "turns=\(turns)", "cancelDelivers=\(cancelDelivers)",
        ]
        .joined(separator: " ")
    }

    // MARK: Running

    /// Runs `events` and the quiescence step, stopping at the first step that finds a violation.
    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        var enabledAfter: [ExplorerEvent] = []
        var fingerprintAfter = ""
        var redundant = false
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            let firedBefore = fired
            traces.begin(
                observing: subject.held() ? subject.isObserving() : nil,
                shown: subject.held() ? subject.snapshot()?.id : nil
            )
            await perform(event)
            boundary(topLevel: true)
            traces.end(
                observing: subject.held() ? subject.isObserving() : nil,
                shown: subject.held() ? subject.snapshot()?.id : nil,
                world
            )
            if index > 0, case .arm = sequence[index - 1], fired == firedBefore, subject.held(), pruning {
                redundant = true
                break
            }
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 {
                enabledAfter = enabled()
                fingerprintAfter = fingerprint
            }
        }
        if sequence.isEmpty {
            enabledAfter = enabled()
            fingerprintAfter = fingerprint
        }
        if redundant {
            return ExplorerOutcome(violations: [], enabled: [], fingerprint: "", trace: [], redundant: true)
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: fingerprintAfter,
            trace: world.state.withLock { $0.trace }
        )
    }

    // The matrix's coordinates: the top-level event in progress and the form of the observation it
    // concerns.
    private var topEvent: ExplorerEvent?
    private var form = "none"
    private var formHost = -1
    // The form and host each attempt observed, so a callback of an ending observation keeps its own form.
    private var attemptForms: [Int: (String, Int)] = [:]
    private var clientRegistering = false

    private func perform(_ event: ExplorerEvent) async {
        topEvent = event
        switch event {
        case .observe(let host):
            form = explorerForm(host: host)
            formHost = host
        case .observeAsync(let host), .observeAsyncNow(let host), .observeAsyncHeld(let host),
            .observeAsyncFinished(let host), .followAsync(let host):
            form = "async closure"
            formHost = host
        case .observeSeq(let host), .followSeq(let host), .observeFrom(let host), .observeClaimed(let host),
            .followCancelled(let host), .followUnseeded(let host):
            form = "sequence"
            formHost = host
        default: break
        }
        step += 1
        reportsThisStep = 0
        firedAtStepStart = fired
        events.append(event)
        if event.hosts.contains(1) { usedSecond = true }
        if event.hosts.contains(0) { usedFirst = true }
        turns = event == .turn ? turns + 1 : 0
        switch event {
        case .turn:
            await hop()
        case .dropAfterJob:
            // The main-actor jobs enqueued before the release run first, so the release is the next
            // thing the presentation sees; the destructor's own job then runs before its storage goes.
            await hop()
            markDrop()
            await subject.dropAfterJob()
        case .factoryReturn, .factoryThrow:
            resumeFactory(event == .factoryReturn)
            await hop()
        case .factoryReturnNewest, .factoryThrowNewest:
            resumeFactory(event == .factoryReturnNewest, newest: true)
            await hop()
        case .observeIsolated:
            // The call reaches the presentation only after the main-actor jobs enqueued so far, so they
            // run first and the observation it replaces ends at that call, not before them.
            await hop()
            let attempt = begin()
            islandCalled = true
            running += 1
            world.setContext(.call(attempt: attempt))
            let call: ExplorerPassiveSubject = subject
            let (island, host) = (island, islandHost)
            let task = Task { [weak self] in
                await call.observeIsolated(island, host)
                self?.islandDone = true
                self?.running -= 1
            }
            calls.append(Call(attempt: attempt, follower: false, task: task))
            // The call reaches the island and registers, or waits on the main actor for a predecessor.
            _ = await hop(until: { host.registered || self.islandDone }, limit: 2000)
            world.setContext(.spontaneous)
        case .observeActor:
            let reached = actorHost.reached.withLock { $0 }
            let runningBefore = running + 1
            let attempt = begin()
            let call: ExplorerPassiveSubject = subject
            let host = actorHost
            running += 1
            world.setContext(.call(attempt: attempt))
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
            let task = Task.immediate { @MainActor [weak self] in
                do throws(SubscriptionFailure) {
                    try await call.observeActor(host)
                } catch {
                    self?.threw(attempt, error)
                }
                self?.running -= 1
            }
            calls.append(Call(attempt: attempt, follower: false, task: task))
            // The registration call may run on the cooperative pool: wait until it has registered and
            // suspended, or thrown, or until the observation finished without calling.
            let reachedBefore = reached
            _ = await hop(
                until: { self.actorHost.reached.withLock { $0 } > reachedBefore || self.running < runningBefore },
                limit: 2000
            )
            world.setContext(.spontaneous)
        case .actorReturn:
            let returnedBefore = actorHost.returned.withLock { $0 }
            let reachedBefore = actorHost.reached.withLock { $0 }
            let callsBefore = running
            actorHost.letOldestReturn()
            // The call returns where the requirement runs, then reaches the presentation on the main
            // actor; wait until it has returned and the observation call finished or called again.
            _ = await hop(
                until: {
                    self.actorHost.returned.withLock { $0 } > returnedBefore
                        && (self.running < callsBefore || self.actorHost.reached.withLock { $0 } > reachedBefore + 1)
                },
                limit: 2000
            )
        case .isolatedReturn:
            islandHost.letReturn()
            // The hand-off reaches the main actor; the call returns or waits there for main-actor work.
            _ = await hop(until: { self.islandDone }, limit: 2000)
        default:
            performNow(event)
        }
    }

    /// Performs an event synchronously, as a callback does.
    private func performNow(_ event: ExplorerEvent) {
        switch event {
        case .observe(let host):
            let attempt = begin()
            let before = lastShownNow()
            world.setContext(.call(attempt: attempt))
            do throws(SubscriptionFailure) {
                switch host {
                case 2: try subject.observeMain(mainHost)
                case 3: try subject.observeMainIsolated(mainIsolatedHost)
                default: try subject.observe(hosts[host])
                }
            } catch {
                refusal(attempt, before: before)
            }
            world.setContext(.spontaneous)
        case .observeFrom(let host):
            let attempt = begin()
            let before = lastShownNow()
            world.setContext(.call(attempt: attempt))
            do throws(SubscriptionFailure) {
                try subject.observeFrom { () throws(SubscriptionFailure) in try self.hosts[host].sequence() }
            } catch {
                refusal(attempt, before: before)
            }
            world.setContext(.spontaneous)
        case .observeAsync(let host):
            startAsync(host: host, follower: false, mode: .parkFirst)
        case .followAsync(let host):
            startAsync(host: host, follower: true, mode: .parkFirst)
        case .observeAsyncHeld(let host):
            startAsync(host: host, follower: false, mode: .registerFirst)
        case .observeAsyncNow(let host):
            startAsync(host: host, follower: false, mode: .immediate)
        case .observeAsyncFinished(let host):
            startAsync(host: host, follower: false, mode: .immediateFinished)
        case .observeSeq(let host), .followSeq(let host), .followUnseeded(let host):
            // `begin` below allocates this number: the epoch of the stop, then the attempt.
            let attempt = attempts + 2
            world.setLatestAttempt(attempt)
            world.setContext(.call(attempt: attempt))
            clientRegistering = true
            let seeded = if case .followUnseeded = event { false } else { true }
            let sequence = try? hosts[host].sequence(seeded: seeded)
            clientRegistering = false
            world.setContext(.spontaneous)
            guard let sequence else {
                world.setLatestAttempt(attempts)
                return
            }
            attempts += 1
            _ = begin()
            if case .observeSeq = event {
                subject.observeSeq(sequence)
                return
            }
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
            running += 1
            let call: ExplorerPassiveSubject = subject
            let task = Task.immediate { @MainActor [weak self] in
                await call.followSeq(sequence)
                self?.running -= 1
            }
            world.readersMayWait()
            calls.append(Call(attempt: attempt, follower: true, task: task))
        case .hostCancelMain(let host):
            if host == 2 {
                mainHost.cancelSubscription()
            } else if host == 3 {
                mainIsolatedHost.cancelSubscription()
            } else {
                guard let id = world.slot(of: host) else { return }
                hosts[host].cancelHere(id)
            }
        case .applyBelow:
            guard subject.held() else { return }
            // Just below the newest value made so far, above every older one.
            let newest = world.state.withLock { $0.revision }
            let below = newest >= 5 ? newest - 5 : 0
            let value = world.makeValue(.applied(attempt: epoch), attempt: epoch, revision: below)
            if inHook { deferrable.insert(value.id) }
            let armedBefore = armed.count
            if !subject.apply(value), armed.count == armedBefore {
                refusedApplies.append(below)
                // Justified when a newer value accepted in a generation still current was pending then.
                let pending = accepted.contains { entry in
                    entry.revision >= below
                        && !(entry.attempt.map { world.isLetGo($0) || cancelledFollowers.contains($0) } ?? false)
                }
                // Or when an earlier event of the same callback left a newer value pending (an apply, or a
                // new observation's baseline) that no stop had withdrawn yet.
                if pending || (inHook && hookLeftPending) { justifiedRefusals.insert(below) }
            }
        case .then(let first, let second):
            performNow(first)
            notePending(first)
            performNow(second)
            notePending(second)
        case .factoryReturn, .factoryThrow:
            resumeFactory(event == .factoryReturn)
        case .factoryReturnNewest, .factoryThrowNewest:
            resumeFactory(event == .factoryReturnNewest, newest: true)
        case .cancelCall:
            // The observation belongs to the presentation once it registers; its task's cancellation is
            // a client event the contract leaves to the closure, which here does not observe it.
            guard let index = calls.lastIndex(where: { !$0.follower && !$0.cancelled && $0.direct }) else { return }
            calls[index].cancelled = true
            calls[index].task.cancel()
        case .cancelFollower, .cancelFollowerOldest:
            let selected =
                event == .cancelFollower
                ? calls.lastIndex(where: { $0.follower && !$0.cancelled })
                : calls.firstIndex(where: { $0.follower && !$0.cancelled })
            guard let index = selected else { return }
            calls[index].cancelled = true
            cancelledFollowers.insert(calls[index].attempt)
            cancelMarks[calls[index].attempt] = world.state.withLock { $0.nextValue }
            if current == calls[index].attempt { current = nil }
            calls[index].task.cancel()
        case .stop:
            letGoAll()
            subject.stop()
            if !inHook { checkReleased("stopObserving()") }
        case .echo(let host):
            echoHost = host
        case .deliverInCancel(let host):
            cancelDelivers = true
            switch host {
            case 2: mainHost.deliversInCancellation = true
            case 3: mainIsolatedHost.deliversInCancellation = true
            default: hosts[host].deliverInCancellations()
            }
        case .observeClaimed(let host):
            let attempt = attempts + 2
            world.setLatestAttempt(attempt)
            world.setContext(.call(attempt: attempt))
            clientRegistering = true
            let sequence = try? hosts[host].sequence()
            clientRegistering = false
            world.setContext(.spontaneous)
            guard let sequence else {
                world.setLatestAttempt(attempts)
                return
            }
            attempts += 1
            _ = begin()
            // Another consumer owns it: not the presentation's registration.
            if let id = world.registration(of: attempt) { world.withhold(id, true) }
            claimed.append(sequence.makeAsyncIterator())
            subject.observeSeq(sequence)
            // A callback of the call may apply a value of its own; only a value of the claimed sequence
            // counts.
            let shownNow = lastShownNow().id
            let fromClaimed = world.state.withLock { state -> Bool in
                guard case .delivered(let registration) = state.values[shownNow]?.origin else { return false }
                return state.registrations[registration]?.attempt == attempt
            }
            if fromClaimed {
                world.violate(
                    .claimedTouched,
                    "the presentation showed a snapshot of a sequence another consumer iterates"
                )
            }
            if let id = world.registration(of: attempt), world.registration(id)?.phase != .active {
                world.violate(.claimedTouched, "the presentation ended a sequence another consumer iterates")
            }
        case .followCancelled(let host):
            let attempt = attempts + 2
            world.setLatestAttempt(attempt)
            world.setContext(.call(attempt: attempt))
            clientRegistering = true
            let sequence = try? hosts[host].sequence()
            clientRegistering = false
            world.setContext(.spontaneous)
            guard let sequence else {
                world.setLatestAttempt(attempts)
                return
            }
            attempts += 1
            _ = begin()
            cancelledFollowers.insert(attempt)
            // The call ends the observation it began before releasing the sequence, so a callback inside
            // that release runs in a generation of its own ("let go" in `Tests/ScheduleExplorer.md`).
            letGoAll()
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
            running += 1
            let call: ExplorerPassiveSubject = subject
            let task = Task.immediate { @MainActor [weak self] in
                withUnsafeCurrentTask { $0?.cancel() }
                await call.followSeq(sequence)
                self?.running -= 1
            }
            calls.append(Call(attempt: attempt, follower: true, task: task, cancelled: true))
            if !inHook { checkReleased("follow(_:) on a cancelled task") }
        case .stopCustody:
            letGoAll()
            explorerWithRemovalCompletionPause({ [weak self] in
                MainActor.assumeIsolated { self?.checkCustodyInWindow() }
            }) { subject.stop() }
            if !inHook { checkReleased("stopObserving()") }
        case .stopRacingRemoval:
            letGoAll()
            let host = hosts[0]
            let parkedIDs = host.parked
            explorerWithRemovalPause({ for id in parkedIDs { _ = host.finishCancelling(id) } }) { subject.stop() }
        case .deliverElsewhere(let host):
            guard let id = world.slot(of: host) else { return }
            if !hosts[host].deliverElsewhere(to: id) { world.violate(.stuck, "a worker's offer never returned") }
        case .close:
            // The callback host M closes: it finishes its subscriber, and later registrations receive
            // the closed snapshot and finish inside `subscribe`.
            mainHost.closeNow()
        case .requestElsewhere, .cancelElsewhere:
            // Not expressible: Combine's `Subscription` is not `Sendable`, so moving one to another
            // thread needs an unchecked construct, which the package's rules exclude.
            break
        case .apply:
            let value = world.makeValue(.applied(attempt: epoch), attempt: epoch)
            let revision = value.revision
            if inHook { deferrable.insert(value.id) }
            let accepted = subject.apply(value)
            if accepted {
                if inHook {
                    self.accepted.append((revision, epoch))
                } else if subject.held(), lastShownNow().revision < revision {
                    world.violate(
                        .applyLost,
                        "a top-level apply of r\(revision) returned true but r\(lastShownNow().revision) is shown"
                    )
                }
            }
        case .deliver(let host):
            if host == 2 {
                _ = mainHost.advance()
            } else if host == 3 {
                mainIsolatedHost.advance()
            } else {
                guard let id = world.slot(of: host) else { return }
                hosts[host].deliver(to: id)
            }
        case .finish(let host):
            if host == 2 {
                mainHost.finish()
            } else if host == 3 {
                mainIsolatedHost.finish()
            } else {
                guard let id = world.slot(of: host) else { return }
                hosts[host].finish(id)
            }
        case .hostCancel(let host):
            guard let id = world.slot(of: host) else { return }
            if !hosts[host].beginCancelling(id) {
                world.violate(.stuck, "host \(host)'s worker never entered onCancel")
            }
        case .hostCancelReturn(let host):
            for id in hosts[host].parked where !hosts[host].finishCancelling(id) {
                world.violate(.stuck, "host \(host)'s cancellation of #\(id) never returned")
            }
        case .dropMain:
            markDrop()
            subject.dropMain()
        case .dropElsewhere:
            markDrop()
            if !subject.dropElsewhere() { world.violate(.stuck, "release on a worker never returned") }
        case .dropAfterJob, .turn, .save, .attach, .capture, .driver, .releaseOwner, .workerDrop, .workerReturn,
            .observeIsolated, .isolatedReturn, .observeActor, .actorReturn, .tokenDropAfterJob, .driverParked,
            .driverGo, .releaseInHandOff, .releaseInDelivery, .releaseNotice, .noticeGo, .register, .registerPending,
            .cancelOldest, .cancelNewest, .count, .countDuring, .refuse, .accept, .holdDrainer, .releaseDrainer, .edit,
            .reconcile, .discard, .returnWork, .onReport, .stage, .subscribeElsewhere, .flushHeld, .createRefusing,
            .createOccupied, .createClosed, .resume, .refuseNext, .occupy,
            .vacate, .observeUnseeded, .claim, .read, .cancelReader, .sendCancel, .ownerSend, .commitCurrent,
            .saveProposal, .commitSaved, .commitForeign, .copyOwner, .dropCopy, .releaseDrivers, .present, .stopP,
            .dropP,
            .pending, .readSeq, .resetOwner, .emit, .releaseDecided:
            break
        case .deliverEqual(let host):
            deliverEqual(host)
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
            armed.append((hook, inner))
            armUsed = true
            arms += 1
        }
    }

    // Starts an asynchronous observation through a closure the harness parks.
    private func startAsync(host: Int, follower: Bool, mode: FactoryMode) {
        let attempt = begin()
        let call: ExplorerPassiveSubject = subject
        running += 1
        let register: ExplorerPassiveSubject.Register = { [weak self] () async throws(SubscriptionFailure) in
            guard let self else { throw .capacityExceeded }
            return try await self.factory(attempt: attempt, host: host, mode: mode)
        }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let task = Task.immediate { @MainActor [weak self] in
            do throws(SubscriptionFailure) {
                if follower { try await call.followAsync(register) } else { try await call.observeAsync(register) }
                if !follower { self?.returned(attempt) }
            } catch {
                self?.threw(attempt, error)
            }
            self?.running -= 1
        }
        calls.append(Call(attempt: attempt, follower: follower, task: task, direct: !follower))
    }
    // An asynchronous observation returned without throwing: unless something replaced it, its first
    // snapshot, or a newer one, is shown.
    private func returned(_ attempt: Int) {
        guard current == attempt, subject.held() else { return }
        let first = world.state.withLock { state in
            state.registrations.values.filter { $0.attempt == attempt }.compactMap(\.firstOffer).min()
        }
        guard let first else { return }
        let shownNow = lastShownNow()
        if shownNow.revision < first {
            world.violate(
                .returnedBeforeShown,
                "observeAsync of attempt \(attempt) returned showing r\(shownNow.revision), before its first snapshot r\(first)"
            )
        }
    }

    // H8's window, after the removal released the discarded element and before its completion: no unread
    // element of a removed, let-go registration is alive any more (I34, forced).
    private func checkCustodyInWindow() {
        let unread = world.state.withLock { state in
            state.values
                .filter { entry in
                    guard case .delivered(let registration) = entry.value.origin, !entry.value.destroyed,
                        !entry.value.considered, !entry.value.handed, !entry.value.offeredAfterEnd,
                        let record = state.registrations[registration], record.latestOffer == entry.key,
                        !record.withheld, record.phase == .freed, state.letGo.contains(record.attempt ?? -1)
                    else { return false }
                    return true
                }
                .map { "r\($0.value.revision)" }
        }
        world.note("custody window")
        if !unread.isEmpty {
            world.violate(
                .completionBeforeCustody,
                "inside the removal's completion window, unread elements \(unread) of removed registrations are alive"
            )
        }
    }

    // E1: the host offers a value with its latest revision and different data.
    private func deliverEqual(_ host: Int) {
        guard host < 2, let id = world.slot(of: host) else { return }
        hosts[host].deliverEqual(to: id)
    }

    // Tracks, inside one callback, whether an event left a newer value pending.
    private func notePending(_ event: ExplorerEvent) {
        switch event {
        case .apply, .observe, .observeFrom, .observeSeq, .followSeq, .observeAsyncNow, .observeAsyncFinished:
            hookLeftPending = true
        case .stop:
            hookLeftPending = false
        default:
            break
        }
    }
    // I35: once a stop or a follow on a cancelled task returns, every registration the presentation holds
    // is released: none is still active, apart from one a registration closure still withholds.
    private func checkReleased(_ what: String) {
        // Only registrations of observations the call ended; one a callback started during the call is
        // current and stays (I35).
        let active = world.state.withLock { state in
            state.registrations.values
                .filter { $0.phase == .active && !$0.withheld && state.letGo.contains($0.attempt ?? -1) }
                .map(\.id).sorted()
        }
        if !active.isEmpty {
            world.violate(.stopLeftRegistration, "\(what) returned with registrations \(active) still active")
        }
    }
    // I38: an observation that another observation, a stop, or its task's cancellation replaced returns
    // without throwing.
    private func threw(_ attempt: Int, _ error: SubscriptionFailure) {
        world.note("attempt \(attempt) threw \(error)")
        if !tearingDown, world.isLetGo(attempt) || cancelledFollowers.contains(attempt) {
            world.violate(.replacedAttemptActed, "attempt \(attempt) threw \(error) after it was replaced")
        }
    }
    // A source that delivers again from each snapshot shown.
    private func echoed() {
        guard let host = echoHost, host < 2, echoes < 100, let id = world.slot(of: host) else { return }
        echoes += 1
        hosts[host].deliver(to: id)
    }
    // I36: the presentation applies at most 32 of a registration's elements in one main-actor turn, the
    // first among them. An element is applied when the revision check reads it; a turn ends when a job
    // enqueued at its first element runs, or when an element is read on another task.
    // The allowance is per registration, whatever an earlier observation applied in the same turn (UI-004).
    private func elementRead(_ shot: ExplorerShot) {
        let registration = world.state.withLock { state -> Int? in
            if case .delivered(let registration) = state.values[shot.id]?.origin { registration } else { nil }
        }
        guard let registration else { return }
        world.note("element r\(shot.revision) of #\(registration) read")
        let task = withUnsafeCurrentTask { $0?.hashValue }
        let (opened, exceeded) = turnBudget.read(registration: registration, task: task)
        if let opened {
            Task { @MainActor [weak self] in self?.turnBudget.endTurn(registration: registration, batch: opened) }
        }
        if exceeded {
            world.violate(
                .presentationTurnBound,
                "\(ExplorerTurnBudget.allowance + 1) elements of registration #\(registration) applied in one main-actor turn"
            )
        }
    }

    /// Starts a new observation attempt, which lets every earlier one go.
    private func begin() -> Int {
        letGoAll()
        current = attempts
        world.setLatestAttempt(attempts)
        attemptForms[attempts] = (form, formHost)
        return attempts
    }
    // The matrix's record of what a callback's event changed: the presentation, its registrations, its
    // reports, and its attempts.
    private func matrixState() -> String {
        let held = subject.held()
        let observing = held ? subject.isObserving() : nil
        let world = world.state.withLock { state in
            "\(state.registrations.values.filter { $0.phase != .freed }.map(\.id).sorted()) \(state.letGo.count) \(state.reports.count) \(state.presentationGone)"
        }
        return "\(held) \(String(describing: observing)) \(world) \(attempts) \(parked.count)"
    }
    private func letGoAll() {
        // Epoch 0 is the generation the presentation starts in.
        world.letGo(Array(0 ... attempts))
        current = nil
        attempts += 1
        epoch = attempts
    }
    // Releasing the harness's reference ends the observation only when the presentation goes: an async
    // call still running keeps it, and the observation stays current until then ("let go" in
    // `Tests/ScheduleExplorer.md`).
    private func markDrop() { dropPending = true }
    private func settleDrop() {
        guard dropPending, !subject.alive() else { return }
        dropPending = false
        letGoAll()
    }
    private func refusal(_ attempt: Int, before: (id: Int, revision: UInt64)) {
        // The refusal ends no generation: the observation before it ended when the call began, and a
        // value applied afterward belongs to the generation the refused call started.
        refused.insert(attempt)
        if current == attempt { current = nil }
        world.note("attempt \(attempt) refused")
        let after = lastShownNow()
        if after.id != before.id {
            world.violate(
                .refusalChangedState,
                "a refused observation changed the shown snapshot from r\(before.revision) to r\(after.revision)"
            )
        }
        let admitted = world.state.withLock { $0.registrations.values.contains { $0.attempt == attempt } }
        if admitted {
            world.violate(.refusalChangedState, "a refused observation's attempt \(attempt) holds a registration")
        }
    }

    // An asynchronous registration closure: checks that the presentation invoked it with no earlier
    // registration still holding a slot or still being made, then parks until the harness resumes it.
    private func factory(
        attempt: Int,
        host: Int,
        mode: FactoryMode
    ) async throws(SubscriptionFailure) -> SnapshotSequence<ExplorerShot> {
        world.note("factory of attempt \(attempt) invoked")
        if !tearingDown, world.isLetGo(attempt) || cancelledFollowers.contains(attempt) {
            world.violate(
                .replacedAttemptActed,
                "the closure of attempt \(attempt) ran after another observation, a stop, or its task's cancellation replaced it"
            )
        }
        let occupied = world.unfreedEnded.map(\.id).sorted()
        if !occupied.isEmpty {
            world.violate(
                .factoryWhileOccupied,
                "the closure of attempt \(attempt) ran while let-go registrations \(occupied) hold slots"
            )
        }
        if !parked.isEmpty {
            world.violate(
                .factoryWhileOccupied,
                "the closure of attempt \(attempt) ran while attempts \(parked.map(\.attempt)) are still registering"
            )
        }
        fire(.factory)
        if mode == .immediate || mode == .immediateFinished {
            world.setContext(.call(attempt: attempt))
            defer { world.setContext(.spontaneous) }
            let sequence = try hosts[host].sequence()
            if mode == .immediateFinished, let id = world.registration(of: attempt) { hosts[host].finish(id) }
            return sequence
        }
        var early: SnapshotSequence<ExplorerShot>?
        if mode == .registerFirst {
            world.setContext(.call(attempt: attempt))
            early = try? hosts[host].sequence()
            world.setContext(.spontaneous)
            if early != nil, let id = world.registration(of: attempt) { world.withhold(id, true) }
        }
        let proceed = await withCheckedContinuation { continuation in
            parked.append(Factory(attempt: attempt, host: host, continuation: continuation))
        }
        if mode == .registerFirst {
            guard let early else { throw .capacityExceeded }
            guard proceed else {
                // A closure that gives up a sequence it registered ends it, on the main actor.
                early.cancel()
                throw .capacityExceeded
            }
            if let id = world.registration(of: attempt) { world.withhold(id, false) }
            return early
        }
        guard proceed else { throw .capacityExceeded }
        world.setContext(.call(attempt: attempt))
        defer { world.setContext(.spontaneous) }
        return try hosts[host].sequence()
    }
    private func resumeFactory(_ proceed: Bool, newest: Bool = false) {
        guard !parked.isEmpty else { return }
        let factory = newest ? parked.removeLast() : parked.removeFirst()
        factory.continuation.resume(returning: proceed)
    }

    // MARK: Callbacks

    private func reported(_ value: Bool) {
        traces.report(value, world, observation: kind == .observation)
        boundary(topLevel: false)
        let (previous, count) = world.state.withLock { state -> (Bool?, Int) in
            defer { state.reports.append(value) }
            return (state.reports.last, state.reports.count)
        }
        world.note("report \(value)")
        if kind == .combine {
            if count == 0, !value { world.violate(.reportsAlternate, "the first report is false") }
            if previous == value { world.violate(.reportsAlternate, "\(value) reported twice in a row") }
        }
        reportsThisStep += 1
        if value { checkLiveAtTrue() }
        if !value {
            // I34 is checked at the next top-level boundary: a frame still running may hold a value it
            // polled; once every frame has returned, an unread value of a removed registration must be gone.
            custodyCheckDue = true
            let occupied = world.unfreedEnded.map(\.id).sorted()
            if !occupied.isEmpty {
                world.violate(.falseWhileOccupied, "false reported while let-go registrations \(occupied) hold slots")
            }
        }
        fire(.report)
    }
    // I37, at the report itself: when `true` is reported, a registration of the current observation is
    // live and the presentation already shows a snapshot of that observation, its seed or a newer one.
    // Publication is serialized (UI-004): a `true` held behind an earlier `false` is published in a later
    // step and reports a past state, so only a `true` published in the step that first showed its
    // observation's snapshot is checked here; I7 and I14 check the settled value.
    private func checkLiveAtTrue() {
        // A change made by a callback of an `isObserving` assignment is queued behind it (UI-004), so only
        // the step's first report is unqueued.
        // So is one whose own assignment's `objectWillChange` ran client code first: a callback in the
        // step makes the report a decided change it may have undone.
        guard reportsThisStep == 1, fired == firedAtStepStart else { return }
        // The newest observation with a live registration. A `true` published before any snapshot of it is
        // shown reports a registration whose seed is not yet visible.
        let current = world.state.withLock { state in
            state.registrations.values
                .filter {
                    $0.phase != .freed && !$0.withheld && !$0.finished && !state.letGo.contains($0.attempt ?? -1)
                }
                .compactMap(\.attempt).max()
        }
        // The boundary samples what is shown only while the harness holds the presentation.
        if let current, current > 0, firstShownStep[current] == nil,
            firstShownStep.keys.allSatisfy({ $0 < current }), subject.held(), let shot = subject.snapshot()
        {
            world.violate(
                .trueBeforeLive,
                "true reported for observation \(current) before its seed was shown (r\(shot.revision) of observation \(world.observation(of: shot.id)) is shown)"
            )
            return
        }
        // The observation the `true` reports: the newest one whose first snapshot has been shown.
        // The boundary samples what is shown, so one shown and replaced inside a call may go unrecorded;
        // such a report is left to I7 and I14.
        guard let (observation, shownStep) = firstShownStep.filter({ $0.key > 0 }).max(by: { $0.key < $1.key })
        else { return }
        // A `true` published in a later step than the one that first showed its observation's snapshot
        // is a queued report of a past change.
        guard shownStep == step else { return }
        let live = world.state.withLock { state in
            state.registrations.values.filter {
                // A host's cancellation parked elsewhere is unknown to the presentation until it returns.
                $0.attempt == observation && $0.phase != .freed && !$0.withheld && !$0.finished
                    && !state.letGo.contains(observation)
            }
        }
        guard let registration = live.max(by: { $0.id < $1.id }) else {
            world.violate(
                .trueBeforeLive,
                "true reported for observation \(observation) while none of its registrations is live"
            )
            return
        }
        guard subject.held(), let shot = subject.snapshot() else { return }
        let showing = world.observation(of: shot.id)
        if showing != observation {
            world.violate(
                .trueBeforeLive,
                "true reported for registration #\(registration.id) of observation \(observation) while r\(shot.revision) of observation \(showing) is shown"
            )
        }
    }
    private func changed(_ old: Int?) {
        if let old { traces.snapshot.invalidated(old, world) }
        willChanges += 1
        changeDepth += 1
        defer { changeDepth -= 1 }
        boundary(topLevel: false)
        echoed()
        fire(.change)
    }
    private func fire(_ hook: ExplorerHook) {
        // The client's own registration of a sequence, before it hands the sequence to the presentation,
        // runs no presentation code: the host's sites there are outside the presentation's calls.
        if clientRegistering, hook == .hostSubscribe || hook == .hostRead { return }
        guard !inHook, let index = armed.firstIndex(where: { $0.0 == hook }) else { return }
        let event = armed.remove(at: index).1
        fired += 1
        let cell = ExplorerMatrixCell.read(world, site: hook, top: topEvent) { attempt in
            attempt.flatMap { attemptForms[$0] } ?? (form, formHost)
        }
        let before = matrixState()
        defer { explorerCover(kind: kind, cell: cell, site: hook, event: event, changed: matrixState() != before) }
        hookLeftPending = false
        let announcedBefore = world.state.withLock { $0.revision }
        inHook = true
        world.note("hook \(hook.rawValue) runs \(event)")
        performNow(event)
        boundary(topLevel: false)
        // The value whose publication the callback announced was made before the callback ran.
        if [.change, .value, .projection].contains(hook) { assigningAnnounced = announcedBefore }
        inHook = false
    }

    // MARK: Combine

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
        subscriber.onValue = { [weak self] subscriber, value in self?.received(subscriber, value) }
        subscriber.onFinish = { [weak self] subscriber in
            guard let self else { return }
            if subject.alive() {
                world.violate(.combineFinish, "subscriber \(subscriber.index) finished while the presentation is alive")
            }
        }
        subscribers.append(subscriber)
        return subscriber
    }
    private func attached(_ subscriber: ExplorerSubscriber) {
        // A subscriber that cancelled inside its subscription is owed no completion.
        if subscriber.attachedAfterRelease, !subscriber.cancelled {
            if !subscriber.finished {
                world.violate(
                    .combineFinish,
                    "subscriber \(subscriber.index) attached after the release did not finish at once"
                )
            }
            if !subscriber.received.isEmpty {
                world.violate(
                    .combineFinish,
                    "subscriber \(subscriber.index) attached after the release received \(subscriber.received.map(\.revision))"
                )
            }
        }
    }
    private func received(_ subscriber: ExplorerSubscriber, _ value: ExplorerShot) {
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

    // MARK: Checks

    private func lastShownNow() -> (id: Int, revision: UInt64) {
        guard subject.held(), let shot = subject.snapshot() else { return lastShown }
        return (shot.id, shot.revision)
    }
    // Reads what the presentation shows at a boundary between harness actions and checks it.
    private func boundary(topLevel: Bool) {
        if subject.held(), let shot = subject.snapshot() {
            let (id, revision) = (shot.id, shot.revision)
            if id != lastShown.id {
                // Revision order belongs to one observation; a newer observation's first snapshot is a new
                // baseline (I11).
                if let problem = world.publicationProblem(next: id, previous: lastShown.id, strict: false) {
                    world.violate(.revisionRegressed, "\(problem) shown")
                }
                let announced = assigningAnnounced.map { revision <= $0 } ?? false
                if !shown.contains(id), !announced, let attempt = world.attempt(of: id),
                    letGoAtBoundary.contains(attempt)
                        || (followersAtBoundary.contains(attempt)
                            && (isDelivered(id) || (deferrable.contains(id) && id < (cancelMarks[attempt] ?? .max))))
                {
                    world.violate(
                        .shownAfterEnd,
                        "r\(revision) of attempt \(attempt) shown after that observation ended"
                    )
                }
                // A value the host delivered inside the cancellation of a registration that had already
                // ended, by the presentation letting it go or by the host's finish, is never shown.
                if !shown.contains(id),
                    world.state.withLock({ state in
                        state.values[id].map { $0.inCancellation && $0.offeredAfterEnd } ?? false
                    })
                {
                    world.violate(
                        .shownAfterEnd,
                        "r\(revision), delivered inside the cancellation of an ended registration, shown"
                    )
                }
                assigningAnnounced = nil
                let observation = world.observation(of: id)
                if observation != world.observation(of: lastShown.id), firstShownStep[observation] == nil {
                    firstShownStep[observation] = step
                }
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
        if topLevel, custodyCheckDue {
            custodyCheckDue = false
            let unread = world.state.withLock { state in
                state.values
                    .filter { entry in
                        guard case .delivered(let registration) = entry.value.origin, !entry.value.destroyed,
                            !entry.value.considered, !entry.value.handed, !entry.value.offeredAfterEnd,
                            let record = state.registrations[registration], record.latestOffer == entry.key,
                            !record.withheld, record.phase == .freed, state.letGo.contains(record.attempt ?? -1)
                        else { return false }
                        return true
                    }
                    .map { "r\($0.value.revision)" }
            }
            if !unread.isEmpty {
                world.violate(
                    .completionBeforeCustody,
                    "false was reported and the step returned while unread elements \(unread) of removed registrations are alive"
                )
            }
        }
        settleDrop()
        letGoAtBoundary = world.state.withLock { $0.letGo }
        followersAtBoundary = cancelledFollowers
    }
    private func isDelivered(_ id: Int) -> Bool {
        world.state.withLock { state in
            if case .delivered = state.values[id]?.origin { true } else { false }
        }
    }

    // MARK: Quiescence

    private func hop() async {
        await Task { @MainActor in }.value
        world.readersMayWait()
    }
    private func hops(_ count: Int) async { for _ in 0 ..< count { await hop() } }
    /// Hops until `condition` holds, at most `limit` times, the safety net that fails a stuck run.
    private func hop(until condition: () -> Bool, limit: Int) async -> Bool {
        for _ in 0 ..< limit {
            if condition() { return true }
            await hop()
        }
        return condition()
    }

    private func quiesce() async {
        armed = []
        step += 1
        world.note("quiesce")
        await hops(3)
        // Every parked cancellation returns, in admission order.
        for host in hosts {
            for id in host.parked {
                if !host.finishCancelling(id) { world.violate(.stuck, "cancellation of #\(id) never returned") }
                await hops(3)
            }
        }
        boundary(topLevel: true)
        if subject.held(), world.violations.isEmpty {
            let settled = await hop(until: { self.finalStateHolds() == nil }, limit: 30)
            if !settled, let problem = finalStateHolds() { world.violate(problem.0, problem.1) }
            boundary(topLevel: true)
            for (revision, attempt) in accepted where lastShown.revision < revision {
                // Withdrawn: its generation ended, or the follower it was applied for was cancelled.
                if let attempt, world.isLetGo(attempt) || cancelledFollowers.contains(attempt) { continue }
                world.violate(.applyLost, "r\(revision) was accepted by apply but r\(lastShown.revision) is shown")
            }
            for revision in refusedApplies where lastShown.revision < revision && !justifiedRefusals.contains(revision)
            {
                world.violate(
                    .refusedApplyLost,
                    "apply of r\(revision) was refused but only r\(lastShown.revision) is shown at quiescence"
                )
            }
            for subscriber in subscribers where subscriber.wantsMore {
                if subscriber.received.last?.id != lastShown.id {
                    world.violate(
                        .combineLatest,
                        "subscriber \(subscriber.index) with demand last received \(subscriber.received.last.map { "r\($0.revision)" } ?? "nothing") while r\(lastShown.revision) is shown"
                    )
                }
            }
            for subscriber in subscribers {
                for value in subscriber.received where !shown.contains(value.id) {
                    world.violate(
                        .combineUnshown,
                        "subscriber \(subscriber.index) received r\(value.revision), which was never shown"
                    )
                }
            }
        }
        islandHost.letReturn()
        while actorHost.waiting > 0 { actorHost.letOldestReturn() }
        tearingDown = true
        // Teardown: every closure throws, every call is cancelled, the presentation is released.
        let leaksBefore = world.violations.count
        for call in calls { call.task.cancel() }
        while !parked.isEmpty { resumeFactory(false) }
        if subject.held() {
            markDrop()
            subject.dropMain()
        }
        // The harness's own consumer of a claimed sequence goes too.
        claimed = []
        let released = await hop(
            until: {
                while !self.parked.isEmpty { self.resumeFactory(false) }
                self.islandHost.letReturn()
                while self.actorHost.waiting > 0 { self.actorHost.letOldestReturn() }
                for host in self.hosts { for id in host.parked { _ = host.finishCancelling(id) } }
                return self.running == 0 && !self.subject.alive() && self.world.allUnfreed.isEmpty
            },
            limit: 2000
        )
        // Once the presentation is gone, its subscribers finish on a later turn; what the harness keeps
        // goes next.
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
        installed = []
        subscribers = []
        saved = nil
        savedProjected = nil
        let done = await hop(
            until: { released && self.world.liveValues().isEmpty && self.world.state.withLock { $0.captures } == 0 },
            limit: 2000
        )
        if !done {
            let state = world.state.withLock {
                ($0.values.filter { !$0.value.destroyed }.map { "r\($0.value.revision)" }, $0.captures)
            }
            world.violate(
                .leak,
                "at quiescence: calls running \(running), presentation alive \(subject.alive()), registrations holding slots \(world.allUnfreed.map(\.id).sorted()), live values \(state.0), captures \(state.1)"
            )
        }
        _ = leaksBefore
        for host in hosts { host.forget() }
        await hops(2)
    }

    // The settled state's invariant: the presentation reports live exactly when one registration holds a slot.
    private func finalStateHolds() -> (ExplorerInvariant, String)? {
        // A registration that a parked closure made is still in its registration call, not observed yet.
        let inFlight = Set(parked.map(\.attempt))
        let unfreed = world.unfreed.filter { !inFlight.contains($0.attempt ?? -1) }.map(\.id).sorted()
        let observing = subject.isObserving() ?? false
        if unfreed.count > 1 { return (.twoRegistrations, "registrations \(unfreed) hold slots at once") }
        if observing, unfreed.isEmpty { return (.finalState, "isObserving is true but no registration holds a slot") }
        // A registration that has delivered nothing yet, an unseeded one, has no snapshot to report live with.
        let delivering = world.unfreed.filter { !inFlight.contains($0.attempt ?? -1) && $0.firstOffer != nil }
        if !observing, !delivering.isEmpty {
            return (.finalState, "isObserving is false but registration \(unfreed) holds a slot")
        }
        return nil
    }
}

/// I36's count: the elements of each registration applied in the main-actor turn in progress.
///
/// A registration's count starts at its first element in a turn and ends when a main-actor
/// job enqueued then runs, or when one of its elements is read on another task, whose job is a later one.
/// Each registration has its own allowance, so an earlier observation's elements in the same turn do not
/// count toward a later registration's (UI-004).
struct ExplorerTurnBudget {
    static let allowance = 32
    private struct Batch {
        let id: Int
        let task: Int?
        var count: Int
    }
    private var batches: [Int: Batch] = [:]
    private var nextBatch = 0

    /// Counts one element of `registration` read on `task`.
    ///
    /// Returns the batch it opened, which the caller ends with ``endTurn(registration:batch:)`` from a
    /// main-actor job enqueued now, and whether this element is the first past the allowance.
    mutating func read(registration: Int, task: Int?) -> (opened: Int?, exceeded: Bool) {
        var opened: Int?
        if batches[registration].map({ $0.task != task }) ?? true {
            nextBatch += 1
            batches[registration] = Batch(id: nextBatch, task: task, count: 0)
            opened = nextBatch
        }
        batches[registration]?.count += 1
        return (opened, batches[registration]?.count == Self.allowance + 1)
    }
    /// Ends the count of `registration` when `batch` is still the one in progress.
    mutating func endTurn(registration: Int, batch: Int) {
        if batches[registration]?.id == batch { batches[registration] = nil }
    }
}
