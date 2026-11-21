import Dispatch
import Foundation
import StateMachine
import StateMachineTestSupport
import StateMachineUI
import Testing
import os

// A host of your own can be cancelling a registration's token on another thread when a presentation
// ends that registration, by being released, by stopping, or by observing something else. The end
// then returns before the slot is free, and everything that the presentation promises after the
// removal waits for the cancellation to return: the release of the snapshot it showed and of an
// element still unread, both on the main actor, a replacement registration that needs the slot, and
// the report that an observation ended.

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// The order of the events a test records, and which of them happened off the main thread.
private final class Ledger: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (events: [String](), offMain: [String](), released: 0))
    private let signal = Signal()

    var events: [String] { state.withLock { $0.events } }
    var offMain: [String] { state.withLock { $0.offMain } }
    var released: Int { state.withLock { $0.released } }
    func note(_ event: String) { state.withLock { $0.events.append(event) } }
    func release(_ name: String) {
        let onMain = Thread.isMainThread
        state.withLock {
            $0.events.append(name)
            if !onMain { $0.offMain.append(name) }
            $0.released += 1
        }
        signal.raise()
    }
    /// Returns once `count` releases have been recorded, or once the waiting task is cancelled, when
    /// every wait for the signal returns at once.
    func wait(forReleases count: Int) async {
        while released < count, !Task.isCancelled { await signal.wait() }
    }
}

/// A `Sendable` snapshot whose release a test records.
private final class Shot: StateMachineSnapshot, Sendable {
    let revision: UInt64
    private let name: String
    private let ledger: Ledger?
    init(_ revision: UInt64, _ name: String, _ ledger: Ledger?) {
        self.revision = revision
        self.name = name
        self.ledger = ledger
    }
    deinit { ledger?.release(name) }
}

/// A one-slot host of the test's own whose sequences keep their tokens, which the host can cancel
/// itself on a worker thread: the worker then waits inside the token's `onCancel`, before it frees the
/// slot, until the test lets it go on.
private final class WorkerSlotHost: Sendable {
    private struct State: Sendable {
        var registrations = 0
        var refusals = 0
        var token: SnapshotSubscription?
        var receive: (@Sendable (Shot) -> Void)?
        var waits = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = ThreadGate()
    private let returned = DispatchSemaphore(value: 0)
    private let ledger: Ledger

    init(_ ledger: Ledger) { self.ledger = ledger }

    var registrations: Int { state.withLock { $0.registrations } }
    var refusals: Int { state.withLock { $0.refusals } }

    func sequence(first: Shot?) throws(SubscriptionFailure) -> SnapshotSequence<Shot> {
        try SnapshotSequence<Shot> { (receive, finish) throws(SubscriptionFailure) in
            let admitted = state.withLock { state in
                guard state.registrations == 0 else {
                    state.refusals += 1
                    return false
                }
                state.registrations += 1
                return true
            }
            guard admitted else { throw .capacityExceeded }
            if let first { receive(first) }
            let token = SnapshotSubscription { [self, finish] in
                withExtendedLifetime(finish) {}
                if state.withLock({ $0.waits }) {
                    entered.signal()
                    proceed.wait()
                }
                state.withLock { $0.registrations -= 1 }
                ledger.note("slot freed")
            }
            state.withLock {
                $0.token = token
                $0.receive = receive
            }
            return token
        }
    }
    func offer(_ shot: Shot) { state.withLock { $0.receive }?(shot) }
    /// Starts cancelling the last token on a worker and returns, blocking the caller briefly, once the
    /// worker is inside its `onCancel`, before the slot is free.
    func beginCancellingOnWorker() {
        let token = state.withLock { state in
            state.waits = true
            return state.token
        }
        runOnOwnThread { [returned] in
            token?.cancel()
            returned.signal()
        }
        entered.waitUnlessCancelled()
    }
    /// Lets the cancellation in progress free the slot and return, and returns once it has.
    func finishCancelling() {
        state.withLock { $0.waits = false }
        proceed.open()
        returned.waitUnlessCancelled()
    }
    /// Lets a cancellation in progress free the slot without waiting for it, on a test's way out.
    func releaseWorker() { proceed.open() }
    /// Cancels the last token on a worker and returns once that cancellation has returned.
    func cancelOnWorker() {
        let token = state.withLock { $0.token }
        runOnOwnThread { [returned] in
            token?.cancel()
            returned.signal()
        }
        returned.waitUnlessCancelled()
    }
}

/// Hands one reference to another thread, which drops it while the main actor waits.
private func drop<Kept: Sendable>(_ kept: consuming Kept) {
    let slot = OSAllocatedUnfairLock<Kept?>(initialState: kept)
    runOnOwnThreadAndWait { slot.withLock { $0 = nil } }
}

/// Where the token's cancellation stands when the presentation ends the registration.
enum TokenCancellation: CaseIterable, CustomTestStringConvertible, Sendable {
    case notBegun, running, returned

    var testDescription: String {
        switch self {
        case .notBegun: "not begun"
        case .running: "running on a worker"
        case .returned: "returned on a worker"
        }
    }
}

/// How the presentation ends the registration.
enum RegistrationEnd: CaseIterable, CustomTestStringConvertible, Sendable {
    case dropOnMain, dropElsewhere, stop, replace

    var testDescription: String {
        switch self {
        case .dropOnMain: "released on the main actor"
        case .dropElsewhere: "released on another thread"
        case .stop: "stopObserving()"
        case .replace: "observing another sequence"
        }
    }
    var drops: Bool { self == .dropOnMain || self == .dropElsewhere }
}

/// How a registration ends, and where its token's cancellation stands then.
struct RemovalCase: CustomTestStringConvertible, Sendable {
    let end: RegistrationEnd
    let cancellation: TokenCancellation

    static var all: [RemovalCase] {
        RegistrationEnd.allCases.flatMap { end in
            TokenCancellation.allCases.map { RemovalCase(end: end, cancellation: $0) }
        }
    }
    var testDescription: String { "\(end.testDescription), token cancellation \(cancellation.testDescription)" }
}

/// One passive presentation under test, held through closures so both classes share a scenario.
@MainActor private struct Passive {
    let observe: @MainActor (SnapshotSequence<Shot>) -> Void
    let stop: @MainActor () -> Void
    let release: @MainActor (_ elsewhere: Bool) -> Void

    static func make(_ kind: PresentationClass) -> Passive? {
        switch kind {
        case .combine:
            var presentation: SnapshotObservableObject<Shot>? = SnapshotObservableObject(
                Shot(0, "initial", nil),
                revision: { $0.revision }
            )
            return Passive(
                observe: { presentation?.observe($0) },
                stop: { presentation?.stopObserving() },
                release: { elsewhere in
                    guard let held = presentation.take() else { return }
                    if elsewhere { drop(consume held) } else { _ = consume held }
                }
            )
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            var presentation: SnapshotPresentation<Shot>? = SnapshotPresentation(
                Shot(0, "initial", nil),
                revision: { $0.revision }
            )
            return Passive(
                observe: { presentation?.observe($0) },
                stop: { presentation?.stopObserving() },
                release: { elsewhere in
                    guard let held = presentation.take() else { return }
                    if elsewhere { drop(consume held) } else { _ = consume held }
                }
            )
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct RemovalCompletionTests {
    // A presentation shows 31 from a host of the test's own and its task waits for the next element.
    // The host's token cancellation has not begun, is running on a worker, or has returned there. The
    // presentation then ends the registration; it hands 33 to the waiting read and leaves 34 unread in
    // the sequence. The unread element, and the shown snapshot when the presentation is released, are
    // released on the main actor, and only once the slot is free.
    @Test(arguments: PresentationClass.allCases, RemovalCase.all)
    func aPassivePresentationReleasesWhatItHeldOnTheMainActorOnceTheRemovalCompletes(
        _ kind: PresentationClass,
        _ removal: RemovalCase
    ) async throws {
        let (end, cancellation) = (removal.end, removal.cancellation)
        let ledger = Ledger()
        let host = WorkerSlotHost(ledger)
        // A thrown error returns before the step that lets the worker's cancellation go.
        defer { host.releaseWorker() }
        guard let presentation = Passive.make(kind) else { return }
        presentation.observe(try host.sequence(first: Shot(31, "shown", ledger)))
        // The observation's task was enqueued first, so it waits for the next element by now.
        await Task { @MainActor in }.value
        switch cancellation {
        case .notBegun: break
        case .running: host.beginCancellingOnWorker()
        case .returned: host.cancelOnWorker()
        }
        var expected = ["handed", "unread"]
        switch end {
        case .dropOnMain, .dropElsewhere:
            // The disposal turn is enqueued before the read that 33 resumes, so 34 stays unread.
            presentation.release(end == .dropElsewhere)
            host.offer(Shot(33, "handed", ledger))
            host.offer(Shot(34, "unread", ledger))
            expected.append("shown")
        case .stop:
            host.offer(Shot(33, "handed", ledger))
            host.offer(Shot(34, "unread", ledger))
            presentation.stop()
        case .replace:
            host.offer(Shot(33, "handed", ledger))
            host.offer(Shot(34, "unread", ledger))
            presentation.observe(try sequence(holding: Shot(40, "replacement", nil)))
            expected.append("shown")
        }
        // The disposal turn, and the read that the end cancelled, run before this.
        await Task { @MainActor in }.value
        if cancellation == .running {
            let early = ledger.events.filter { $0 == "unread" || ($0 == "shown" && end.drops) }
            #expect(early.isEmpty, "released before the slot was free: \(ledger.events)")
            host.finishCancelling()
        }
        await ledger.wait(forReleases: expected.count)
        let events = ledger.events
        #expect(ledger.offMain.isEmpty, "released off the main actor: \(events)")
        let freed = try #require(events.firstIndex(of: "slot freed"), "\(events)")
        let unreadIndex = try #require(events.firstIndex(of: "unread"), "\(events)")
        #expect(freed < unreadIndex, "\(events)")
        if end.drops {
            let shownIndex = try #require(events.firstIndex(of: "shown"), "\(events)")
            #expect(freed < shownIndex, "\(events)")
        }
    }

    // A driving presentation released while a host of your own cancels its subscription itself
    // releases its snapshot and its owner only once that cancellation has returned.
    @Test(arguments: PresentationClass.allCases)
    func aDrivingPresentationReleasedDuringItsHostsCancellationReleasesWhatItHeldAfterIt(
        _ kind: PresentationClass
    ) async {
        let ledger = Ledger()
        let host = CancellingHost(ledger)
        switch kind {
        case .combine:
            var presentation: StateMachineObservableObject<CancellingHost>? = StateMachineObservableObject(host)
            host.inCancellation = { presentation = nil }
            host.cancelSubscription()
            withExtendedLifetime(presentation) {}
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            var presentation: StateMachinePresentation<CancellingHost>? = StateMachinePresentation(host)
            host.inCancellation = { presentation = nil }
            host.cancelSubscription()
            withExtendedLifetime(presentation) {}
        }
        await ledger.wait(forReleases: 1)
        #expect(ledger.offMain.isEmpty, "\(ledger.events)")
        #expect(ledger.events == ["slot freed", "shown"], "\(ledger.events)")
    }
}

/// A sequence of the test's own that holds `element`; the host keeps its callbacks until the
/// registration is cancelled.
private func sequence(holding element: Shot) throws -> SnapshotSequence<Shot> {
    try SnapshotSequence<Shot> { receive, finish in
        receive(element)
        return SnapshotSubscription { withExtendedLifetime((receive, finish)) {} }
    }
}

/// A `MainActor` host of the test's own with one slot, freed when its subscription's cancellation
/// returns, which can cancel that subscription itself and run code inside the cancellation.
@MainActor private final class CancellingHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Shot
    struct Receipt: StateMachineReceipt {
        let snapshot: Shot
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private let ledger: Ledger
    private var token: MainActorSnapshotSubscription?
    private(set) var registrations = 0
    private(set) var refusals = 0
    /// Runs once inside the next cancellation of a subscription, before the slot is freed.
    var inCancellation: (@MainActor () -> Void)?

    init(_ ledger: Ledger) { self.ledger = ledger }

    func snapshot() -> Shot { Shot(1, "shown", ledger) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Shot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else {
            refusals += 1
            throw .capacityExceeded
        }
        registrations += 1
        receive(Shot(1, "seed", nil))
        let made = MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            let hook = inCancellation
            inCancellation = nil
            hook?()
            registrations -= 1
            ledger.note("slot freed")
        }
        token = made
        return made
    }
    /// Cancels the subscription it handed out last, as a host that removes an observer does.
    func cancelSubscription() { token?.cancel() }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Shot(1, "closed", nil)) }
}

/// A `Sendable` snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// An actor that owns observations of an isolated host of the test's own.
private actor Island {
    func observe(_ presentation: SnapshotObservableObject<Mark>, _ host: IslandHost) async {
        try? await presentation.observe(host)
    }
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func observe(_ presentation: SnapshotPresentation<Mark>, _ host: IslandHost) async {
        try? await presentation.observe(host)
    }
}

/// A one-slot host of the test's own confined to `Island`.
///
/// Inside its first registration call, after taking the slot, it starts cancelling that registration's
/// token on a worker, which waits inside `onCancel` until the test lets it free the slot, and it returns
/// the sequence only once the test lets it.
private final class IslandHost: IsolatedStateMachineHost, Sendable {
    typealias Owner = Island
    typealias Snapshot = Mark

    private struct State: Sendable {
        var registrations = 0
        var refusals = 0
        var calls = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let returning = DispatchSemaphore(value: 0)
    let registered = Signal()

    var registrations: Int { state.withLock { $0.registrations } }
    var refusals: Int { state.withLock { $0.refusals } }

    /// Lets the first registration call return its sequence.
    func letRegistrationReturn() { returning.signal() }
    /// Lets the worker's cancellation free the slot.
    func letCancellationFinish() { proceed.signal() }

    /// A sequence of this host's slot from the main actor, as a replacement's closure registers it.
    func sequence() throws(SubscriptionFailure) -> SnapshotSequence<Mark> { try register(waiting: false) }

    private func register(waiting: Bool) throws(SubscriptionFailure) -> SnapshotSequence<Mark> {
        var kept: SnapshotSubscription?
        let sequence = try SnapshotSequence<Mark> { (receive, finish) throws(SubscriptionFailure) in
            let admitted = state.withLock { state in
                guard state.registrations == 0 else {
                    state.refusals += 1
                    return false
                }
                state.registrations += 1
                return true
            }
            guard admitted else { throw .capacityExceeded }
            receive(Mark(revision: 1))
            let token = SnapshotSubscription { [self, receive, finish] in
                withExtendedLifetime((receive, finish)) {}
                if waiting {
                    entered.signal()
                    proceed.wait()
                }
                state.withLock { $0.registrations -= 1 }
            }
            kept = token
            return token
        }
        if waiting, let kept {
            runOnOwnThread { kept.cancel() }
            entered.wait()
            registered.raise()
            returning.wait()
        }
        return sequence
    }

    func snapshot(isolation: isolated Island) -> Mark { Mark(revision: 1) }
    func subscribe(
        _ receive: @escaping (Mark) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated Island
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Island> {
        throw .capacityExceeded
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (Mark) -> Projection,
        isolation: isolated Island
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        // The presentation registers the snapshots themselves.
        let first = state.withLock { state in
            defer { state.calls += 1 }
            return state.calls == 0
        }
        guard let sequence = try register(waiting: first) as? SnapshotSequence<Projection> else {
            throw .capacityExceeded
        }
        return sequence
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (Mark) -> Projection,
        isolation: isolated Island
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try snapshots(transform, isolation: isolation)
    }
}

@MainActor @Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct ReplacementAfterRemovalTests {
    // An isolated host takes its only slot for an observation and starts cancelling that registration's
    // token on a worker. Before the host hands its sequence back, an asynchronous observation through a
    // closure replaces the first one and waits for it. The presentation let the first registration go
    // before the host returned it, so the host's hand-off keeps nothing; the replacement still runs its
    // closure only once the worker has freed the slot, and registers.
    @Test(arguments: PresentationClass.allCases)
    func aReplacementWaitsForTheRemovalOfARegistrationItsHostReturnedLate(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let island = Island()
        let host = IslandHost()
        var factoryRuns = 0
        var occupiedAtFactory: Bool?
        var outcome: String?
        let replace:
            @MainActor (@escaping @MainActor () async throws(SubscriptionFailure) -> SnapshotSequence<Mark>)
                async throws(SubscriptionFailure) -> Void
        let first: Task<Void, Never>
        let presentation: AnyObject
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            presentation = made
            first = Task { await island.observe(made, host) }
            replace = { (register) async throws(SubscriptionFailure) in try await made.observe(snapshotsFrom: register)
            }
        case .observation:
            let made = SnapshotPresentation(Mark(revision: 0))
            presentation = made
            first = Task { await island.observe(made, host) }
            replace = { (register) async throws(SubscriptionFailure) in try await made.observe(snapshotsFrom: register)
            }
        }
        await host.registered.wait()
        let replacement = Task.immediate { @MainActor in
            do throws(SubscriptionFailure) {
                try await replace { () async throws(SubscriptionFailure) in
                    factoryRuns += 1
                    occupiedAtFactory = host.registrations > 0
                    return try host.sequence()
                }
                outcome = "registered"
            } catch {
                outcome = "refused"
            }
        }
        host.letRegistrationReturn()
        // The first observation settles on the main actor, and anything it lets go on runs there
        // before this resumes.
        await first.value
        #expect(factoryRuns == 0, "the replacement ran its closure while the slot was occupied")
        host.letCancellationFinish()
        await replacement.value
        #expect(outcome == "registered")
        #expect(factoryRuns == 1)
        #expect(occupiedAtFactory == false)
        #expect(host.refusals == 0)
        #expect(host.registrations == 1)
        withExtendedLifetime(presentation) {}
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct RefusalAfterReportTests {
    // A host cancels a live presentation's subscription and, inside that cancellation, the presentation
    // observes the host again, which the host refuses while it still holds the slot; the refusal is
    // thrown at once. Once the cancellation returns, `isObserving` reports `false` with the slot free,
    // and an observation started from that report registers.
    @Test(arguments: PresentationClass.allCases)
    func aRefusalInsideTheCancellationThrowsAndTheEndIsReportedWithTheSlotFree(_ kind: PresentationClass) async throws {
        let ledger = Ledger()
        let host = CancellingHost(ledger)
        let reported = Signal()
        var freeAtReport: Bool?
        var fromReport: Bool?
        let presentation: AnyObject
        let observe: @MainActor () throws(SubscriptionFailure) -> Void
        let live: @MainActor () -> Bool
        let watch: AnyObject
        var onFalse: (@MainActor () -> Void)?
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Shot(0, "initial", nil))
            presentation = made
            observe = { () throws(SubscriptionFailure) in try made.observe(host) }
            live = { made.isObserving }
            watch = made.$isObserving.dropFirst().sink { if !$0 { onFalse?() } }
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            let made = SnapshotPresentation(Shot(0, "initial", nil))
            presentation = made
            observe = { () throws(SubscriptionFailure) in try made.observe(host) }
            live = { made.isObserving }
            let hook = ReportHook { onFalse?() }
            trackEnd({ [weak made] in made?.isObserving }, hook)
            watch = hook
        }
        try observe()
        #expect(live())
        onFalse = {
            guard freeAtReport == nil else { return }
            freeAtReport = host.registrations == 0
            fromReport = (try? observe()) != nil
            reported.raise()
        }
        var thrown: SubscriptionFailure?
        host.inCancellation = {
            do throws(SubscriptionFailure) { try observe() } catch { thrown = error }
        }
        host.cancelSubscription()
        #expect(thrown == .capacityExceeded)
        await reported.wait()
        #expect(freeAtReport == true)
        #expect(fromReport == true)
        #expect(live())
        #expect(host.registrations == 1)
        // Only the observation started inside the cancellation was refused.
        #expect(host.refusals == 1)
        withExtendedLifetime((watch, presentation)) {}
    }
}

/// A shared owner of the test's own over one `WorkerSlotHost`, whose sequences start with no element.
private final class WorkerSharedHost: SharedStateMachineHost {
    typealias Snapshot = Shot
    let slot: WorkerSlotHost

    init(_ ledger: Ledger) { slot = WorkerSlotHost(ledger) }

    func snapshot() -> Shot { Shot(1, "shown", nil) }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Shot> { try slot.sequence(first: nil) }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Shot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { throw .capacityExceeded }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Shot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { throw .capacityExceeded }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RefusalDuringTwoCancellationsTests {
    // Two one-slot hosts, A and B. The presentation observes A; a worker starts cancelling A's token;
    // the presentation observes B; another worker starts cancelling B's token; the presentation
    // observes A again, which A refuses because its cancellation still holds the slot. The refusal is
    // thrown at once, and nothing registers with A when its cancellation returns while B's is still
    // running. Once both have returned, `isObserving` reports each change once, in order, and every
    // `false` finds both slots free.
    @Test(arguments: PresentationClass.allCases)
    func aRefusalWhileTwoCancellationsRunThrowsAndReportsStayOrdered(_ kind: PresentationClass) async throws {
        let ledger = Ledger()
        let a = WorkerSharedHost(ledger)
        let b = WorkerSharedHost(ledger)
        // A thrown error returns before the steps that let the workers' cancellations go.
        defer {
            a.slot.releaseWorker()
            b.slot.releaseWorker()
        }
        var reports: [String] = []
        let record: @MainActor (Bool) -> Void = { live in
            reports.append(live ? "true" : "false, occupied \(a.slot.registrations + b.slot.registrations)")
        }
        let observe: @MainActor (WorkerSharedHost) throws(SubscriptionFailure) -> Void
        let presentation: AnyObject
        let watch: AnyObject
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Shot(0, "initial", nil))
            presentation = made
            observe = { (host) throws(SubscriptionFailure) in try made.observe(host) }
            watch = made.$isObserving.dropFirst().sink { record($0) }
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            let made = SnapshotPresentation(Shot(0, "initial", nil))
            presentation = made
            observe = { (host) throws(SubscriptionFailure) in try made.observe(host) }
            let hook = ReportHook {}
            trackChanges({ [weak made] in made?.isObserving }, hook, record)
            watch = hook
        }
        try observe(a)
        a.slot.beginCancellingOnWorker()
        try observe(b)
        b.slot.beginCancellingOnWorker()
        var thrown: SubscriptionFailure?
        do throws(SubscriptionFailure) { try observe(a) } catch { thrown = error }
        #expect(thrown == .capacityExceeded)
        a.slot.finishCancelling()
        await Task { @MainActor in }.value
        #expect(a.slot.registrations == 0)
        #expect(reports == ["true"])
        b.slot.finishCancelling()
        await Task { @MainActor in }.value
        #expect(a.slot.registrations == 0 && b.slot.registrations == 0)
        #expect(reports == ["true", "false, occupied 0", "true", "false, occupied 0"])
        #expect(a.slot.refusals == 1)
        withExtendedLifetime((watch, presentation)) {}
    }
}

// Observation reports a change before it is made, so each change records the negation of the value
// read then.
@MainActor private func trackChanges(
    _ read: @escaping @MainActor () -> Bool?,
    _ installed: ReportHook,
    _ record: @escaping @MainActor (Bool) -> Void
) {
    withObservationTracking {
        _ = read()
    } onChange: { [weak installed] in
        MainActor.assumeIsolated {
            guard let installed, let live = read() else { return }
            record(!live)
            trackChanges(read, installed, record)
        }
    }
}

/// Keeps a report hook installed while it lives.
@MainActor private final class ReportHook {
    let hook: @MainActor () -> Void
    init(_ hook: @escaping @MainActor () -> Void) { self.hook = hook }
}

// Observation reports a change before it is made, so a change that finds the model live is the one
// to `false`; the hook runs then, inside the report.
@MainActor private func trackEnd(_ read: @escaping @MainActor () -> Bool?, _ installed: ReportHook) {
    withObservationTracking {
        _ = read()
    } onChange: { [weak installed] in
        MainActor.assumeIsolated {
            guard let installed, let live = read() else { return }
            if live { installed.hook() }
            trackEnd(read, installed)
        }
    }
}
