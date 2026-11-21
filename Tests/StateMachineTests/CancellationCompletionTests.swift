import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

// A registration's end is complete only once its token's cancellation has returned, which is the
// moment a host of your own frees its slot. These tests end registrations from inside that
// cancellation, where every call that cancels again returns at once, and check that nothing which
// promises a free slot, a report that an observation ended, a refusal retried after an earlier
// attempt, or the release of a discarded value, comes before that moment. They also cover the
// teardown of a main-actor host, a finished or cancelled observation's deferred first snapshot, and
// the admission of an isolated host's pending-completion registration.

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

/// The order of the events a test records.
private final class Events: Sendable {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    var all: [String] { log.withLock { $0 } }
    func record(_ event: String) { log.withLock { $0.append(event) } }
}

/// A value whose release a test records under `name`.
private final class Released: Sendable {
    private let events: Events
    private let name: String
    init(_ events: Events, _ name: String) {
        self.events = events
        self.name = name
    }
    deinit { events.record(name) }
}

/// A value any thread fills and reads.
private final class Later<Value: Sendable>: Sendable {
    private let stored = OSAllocatedUnfairLock<Value?>(initialState: nil)
    var value: Value? { stored.withLock { $0 } }
    func fill(_ value: Value) { stored.withLock { $0 = value } }
}

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// A `MainActor` host of the test's own with one slot, which it frees when its subscription's
/// cancellation returns, and which can cancel that subscription itself and run code inside it.
@MainActor private final class SlotHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Mark
    struct Receipt: StateMachineReceipt {
        let snapshot: Mark
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private(set) var registrations = 0
    private(set) var refusals = 0
    private var finish: (@MainActor () -> Void)?
    private var token: MainActorSnapshotSubscription?
    /// Runs once inside the next cancellation of a subscription, before the slot is freed.
    var inCancellation: (@MainActor () -> Void)?

    func snapshot() -> Mark { Mark(revision: 1) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Mark) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else {
            refusals += 1
            throw .capacityExceeded
        }
        registrations += 1
        finish = onFinish
        receive(Mark(revision: 1))
        let token = MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            let hook = inCancellation
            inCancellation = nil
            hook?()
            registrations -= 1
        }
        self.token = token
        return token
    }
    /// Cancels the subscription it handed out last, as a host that removes an observer does.
    func cancelSubscription() { token?.cancel() }
    /// Finishes the registration it made last, as a closing host does.
    func finishRegistration() { finish?() }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Mark(revision: 1)) }
}

/// What a host's code does inside its own cancellation of a presentation's subscription.
enum EndInsideCancellation: CaseIterable, CustomTestStringConvertible, Sendable {
    case finish, stop

    var testDescription: String {
        switch self {
        case .finish: "the host finishes the registration"
        case .stop: "the presentation stops observing"
        }
    }
}

/// How a passive presentation observes the host.
enum PassiveSource: CaseIterable, CustomTestStringConvertible, Sendable {
    case callbacks, projectedSequence

    var testDescription: String {
        switch self {
        case .callbacks: "observe(host)"
        case .projectedSequence: "observe(snapshotsFrom:) of a projection"
        }
    }
}

/// One way a passive presentation observes the host, and what ends its registration.
struct PassiveCase: CustomTestStringConvertible, Sendable {
    let source: PassiveSource
    let end: EndInsideCancellation

    static var all: [PassiveCase] {
        PassiveSource.allCases.flatMap { source in
            EndInsideCancellation.allCases.map { PassiveCase(source: source, end: $0) }
        }
    }
    var testDescription: String { "\(source.testDescription), \(end.testDescription)" }
}

/// Runs `hook` each time `isObserving` of `presentation` is assigned `false`, until the returned
/// value is released.
@MainActor private func onEnd(_ presentation: AnyObject, _ hook: @escaping @MainActor () -> Void) -> AnyObject {
    if let combine = presentation as? SnapshotObservableObject<Mark> {
        return combine.$isObserving.dropFirst().sink { if !$0 { hook() } }
    }
    if let combine = presentation as? StateMachineObservableObject<SlotHost> {
        return combine.$isObserving.dropFirst().sink { if !$0 { hook() } }
    }
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else {
        preconditionFailure("an unavailable presentation")
    }
    let installed = EndHook(hook)
    if let model = presentation as? SnapshotPresentation<Mark> {
        track({ [weak model] in model?.isObserving }, installed)
    } else if let model = presentation as? StateMachinePresentation<SlotHost> {
        track({ [weak model] in model?.isObserving }, installed)
    } else {
        preconditionFailure("an unknown presentation")
    }
    return installed
}

/// Keeps a report hook installed while it lives.
@MainActor private final class EndHook {
    let hook: @MainActor () -> Void
    init(_ hook: @escaping @MainActor () -> Void) { self.hook = hook }
}

// Observation reports a change before it is made, so a change that finds the model live is the one
// to `false`; the hook runs then, inside the report.
@MainActor private func track(_ read: @escaping @MainActor () -> Bool?, _ installed: EndHook) {
    withObservationTracking {
        _ = read()
    } onChange: { [weak installed] in
        MainActor.assumeIsolated {
            guard let installed, let live = read() else { return }
            if live {
                installed.hook()
            } else {
                track(read, installed)
            }
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct CancellationCompletionReportTests {
    // A host cancels a driving presentation's subscription and, inside that cancellation, the
    // registration ends. The presentation reports `false` only once the cancellation has returned and
    // the slot is free, so a presentation created from that report registers.
    @Test(arguments: PresentationClass.allCases, EndInsideCancellation.allCases)
    func aDrivingPresentationReportsTheEndOnceItsHostsCancellationHasReturned(
        _ kind: PresentationClass,
        _ end: EndInsideCancellation
    ) async throws {
        let host = SlotHost()
        let reported = Signal()
        var freeAtReport: Bool?
        var replacement: AnyObject?
        let presentation: AnyObject
        let stop: @MainActor () -> Void
        let makeReplacement: @MainActor () -> (AnyObject, Bool)
        switch kind {
        case .combine:
            let made = StateMachineObservableObject(host)
            presentation = made
            stop = { made.stopObserving() }
            makeReplacement = {
                let next = StateMachineObservableObject(host)
                return (next, next.isObserving)
            }
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            let made = StateMachinePresentation(host)
            presentation = made
            stop = { made.stopObserving() }
            makeReplacement = {
                let next = StateMachinePresentation(host)
                return (next, next.isObserving)
            }
        }
        var replacementLive = false
        let watch = onEnd(presentation) {
            guard freeAtReport == nil else { return }
            freeAtReport = host.registrations == 0
            (replacement, replacementLive) = makeReplacement()
            reported.raise()
        }
        host.inCancellation = {
            switch end {
            case .finish: host.finishRegistration()
            case .stop: stop()
            }
        }
        host.cancelSubscription()
        await reported.wait()
        #expect(freeAtReport == true)
        #expect(replacementLive)
        #expect(host.refusals == 0)
        withExtendedLifetime((watch, replacement, presentation)) {}
    }

    // The same for a passive presentation, observing the host through its callbacks or through a
    // projected sequence: the report waits for the cancellation, and an observation started from the
    // report registers.
    @Test(arguments: PresentationClass.allCases, PassiveCase.all)
    func aPassivePresentationReportsTheEndOnceItsHostsCancellationHasReturned(
        _ kind: PresentationClass,
        _ passive: PassiveCase
    ) async throws {
        let (source, end) = (passive.source, passive.end)
        let host = SlotHost()
        let reported = Signal()
        var freeAtReport: Bool?
        var replaced: Result<Void, SubscriptionFailure>?
        let presentation: AnyObject
        let observe: @MainActor () throws(SubscriptionFailure) -> Void
        let stop: @MainActor () -> Void
        let live: @MainActor () -> Bool
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            presentation = made
            observe = { () throws(SubscriptionFailure) in
                switch source {
                case .callbacks: try made.observe(host)
                case .projectedSequence:
                    try made.observe(snapshotsFrom: { () throws(SubscriptionFailure) in try host.snapshots { $0 } })
                }
            }
            stop = { made.stopObserving() }
            live = { made.isObserving }
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            let made = SnapshotPresentation(Mark(revision: 0))
            presentation = made
            observe = { () throws(SubscriptionFailure) in
                switch source {
                case .callbacks: try made.observe(host)
                case .projectedSequence:
                    try made.observe(snapshotsFrom: { () throws(SubscriptionFailure) in try host.snapshots { $0 } })
                }
            }
            stop = { made.stopObserving() }
            live = { made.isObserving }
        }
        try observe()
        while !live() { await Task.yield() }
        let watch = onEnd(presentation) {
            guard freeAtReport == nil else { return }
            freeAtReport = host.registrations == 0
            do throws(SubscriptionFailure) {
                try observe()
                replaced = .success(())
            } catch {
                replaced = .failure(error)
            }
            reported.raise()
        }
        host.inCancellation = {
            switch end {
            case .finish: host.finishRegistration()
            case .stop: stop()
            }
        }
        host.cancelSubscription()
        await reported.wait()
        #expect(freeAtReport == true)
        #expect(replaced.map { (try? $0.get()) != nil } == true)
        #expect(host.refusals == 0)
        withExtendedLifetime((watch, presentation)) {}
    }
}

/// A one-slot host of the test's own whose sequences hand over `first` when they register, and
/// whose tokens run a hook inside their cancellation before they free the slot.
private final class SequenceSlotHost: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (registrations: 0, refusals: 0))
    private let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let registered = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    var registrations: Int { state.withLock { $0.registrations } }
    var refusals: Int { state.withLock { $0.refusals } }
    /// Runs `body` once inside the next cancellation of a token, before the slot is freed.
    func inCancellation(_ body: @escaping @Sendable () -> Void) { hook.withLock { $0 = body } }
    /// Runs `body` once after the next registration takes the slot.
    func onRegistration(_ body: @escaping @Sendable () -> Void) { registered.withLock { $0 = body } }

    func sequence(first: UInt64) throws(SubscriptionFailure) -> SnapshotSequence<Mark> {
        try SnapshotSequence<Mark> { (receive, finish) throws(SubscriptionFailure) in
            let admitted = state.withLock { state in
                guard state.registrations == 0 else {
                    state.refusals += 1
                    return false
                }
                state.registrations += 1
                return true
            }
            guard admitted else { throw .capacityExceeded }
            receive(Mark(revision: first))
            registered.withLock { $0.take() }?()
            // The host keeps the callbacks until the registration is cancelled.
            return SnapshotSubscription { [self, receive, finish] in
                withExtendedLifetime((receive, finish)) {}
                hook.withLock { $0.take() }?()
                state.withLock { $0.registrations -= 1 }
            }
        }
    }
}

/// A registration through a closure that may await its owner.
private typealias Registering = @MainActor () async throws(SubscriptionFailure) -> SnapshotSequence<Mark>

@MainActor @Suite(.timeLimit(.minutes(1))) struct ReleasingAttemptTests {
    // Registration A holds the only slot inside its closure when the presentation stops observing.
    // When A returns, the presentation releases its sequence, and inside that release's cancellation a
    // new asynchronous registration C begins. A still holds the slot then, so C waits for A's release
    // to return, and then registers.
    @Test(arguments: PresentationClass.allCases)
    func aRegistrationThatBeginsInsideAnObsoleteAttemptsReleaseWaitsForIt(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let host = SequenceSlotHost()
        let resumeA = Signal()
        let aRegistered = Signal()
        let cFinished = Signal()
        let outcome = Later<String>()
        host.onRegistration { aRegistered.raise() }
        let observe: @MainActor (@escaping Registering) async throws(SubscriptionFailure) -> Void
        let stop: @MainActor () -> Void
        let shown: @MainActor () -> UInt64
        let presentation: AnyObject
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            presentation = made
            observe = { (register) async throws(SubscriptionFailure) in
                try await made.observe(snapshotsFrom: register)
            }
            stop = { made.stopObserving() }
            shown = { made.snapshot.revision }
        case .observation:
            let made = SnapshotPresentation(Mark(revision: 0))
            presentation = made
            observe = { (register) async throws(SubscriptionFailure) in
                try await made.observe(snapshotsFrom: register)
            }
            stop = { made.stopObserving() }
            shown = { made.snapshot.revision }
        }
        let a = Task { @MainActor in
            try? await observe { () async throws(SubscriptionFailure) in
                let sequence = try host.sequence(first: 1)
                await resumeA.wait()
                return sequence
            }
        }
        await aRegistered.wait()
        stop()
        host.inCancellation {
            // The presentation releases A's sequence on the main actor, so this runs there.
            MainActor.assumeIsolated {
                _ = Task.immediate { @MainActor in
                    do throws(SubscriptionFailure) {
                        try await observe { () async throws(SubscriptionFailure) in try host.sequence(first: 2) }
                        outcome.fill("registered, showing \(shown())")
                    } catch {
                        outcome.fill("refused")
                    }
                    cFinished.raise()
                }
            }
        }
        resumeA.raise()
        await a.value
        await cFinished.wait()
        #expect(outcome.value == "registered, showing 2")
        #expect(host.refusals == 0)
        #expect(host.registrations == 1)
        withExtendedLifetime(presentation) {}
    }
}

/// A sequence of the test's own that holds `element` and has finished, or is open; the host keeps
/// its callbacks until the registration is cancelled.
private func sequence(holding element: UInt64, finished: Bool) throws -> SnapshotSequence<Mark> {
    try SnapshotSequence<Mark> { receive, finish in
        receive(Mark(revision: element))
        if finished { finish() }
        return SnapshotSubscription { withExtendedLifetime((receive, finish)) {} }
    }
}

/// Runs `hook` once, inside the first publication of a snapshot after this call, before the
/// presentation shows it; the returned value keeps it installed.
@MainActor private func onceWhileShowing(
    _ presentation: AnyObject,
    _ hook: @escaping @MainActor () -> Void
) -> AnyObject {
    var pending: (@MainActor () -> Void)? = hook
    if let combine = presentation as? SnapshotObservableObject<Mark> {
        return combine.objectWillChange.sink { _ in pending.take()?() }
    }
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
        let model = presentation as? SnapshotPresentation<Mark>
    else { preconditionFailure("an unknown presentation") }
    withObservationTracking {
        _ = model.snapshot
    } onChange: {
        MainActor.assumeIsolated { pending.take()?() }
    }
    return model
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DeferredFirstSnapshotTests {
    // From inside the publication of snapshot 1, an asynchronous observation begins with a sequence
    // that holds 2 and has finished. The publication shows 2 once its callback returns, and the
    // observation returns only then, although the sequence cannot deliver again.
    @Test(arguments: PresentationClass.allCases)
    func anObservationOfAFinishedSequenceReturnsOnceItsDeferredFirstSnapshotIsShown(
        _ kind: PresentationClass
    ) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let finishedTwo = try sequence(holding: 2, finished: true)
        let returned = Later<UInt64>()
        let done = Signal()
        let presentation: AnyObject
        let apply: @MainActor (UInt64) -> Void
        let observe: @MainActor () async -> Void
        let shown: @MainActor () -> UInt64
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            presentation = made
            apply = { made.apply(Mark(revision: $0)) }
            observe = { await made.observe(snapshotsFrom: { @MainActor () async in finishedTwo }) }
            shown = { made.snapshot.revision }
        case .observation:
            let made = SnapshotPresentation(Mark(revision: 0))
            presentation = made
            apply = { made.apply(Mark(revision: $0)) }
            observe = { await made.observe(snapshotsFrom: { @MainActor () async in finishedTwo }) }
            shown = { made.snapshot.revision }
        }
        let hook = onceWhileShowing(presentation) {
            Task.immediate { @MainActor in
                await observe()
                returned.fill(shown())
                done.raise()
            }
        }
        apply(1)
        await done.wait()
        #expect(returned.value == 2)
        withExtendedLifetime((hook, presentation)) {}
    }

    // The same for `follow(snapshotsFrom:)`, which returns once the finished observation has ended:
    // its deferred first snapshot is shown by then.
    @Test(arguments: PresentationClass.allCases)
    func aFollowOfAFinishedSequenceReturnsOnceItsDeferredFirstSnapshotIsShown(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let finishedTwo = try sequence(holding: 2, finished: true)
        let returned = Later<UInt64>()
        let done = Signal()
        let presentation: AnyObject
        let apply: @MainActor (UInt64) -> Void
        let follow: @MainActor () async -> Void
        let shown: @MainActor () -> UInt64
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            presentation = made
            apply = { made.apply(Mark(revision: $0)) }
            follow = { await made.follow(snapshotsFrom: { @MainActor () async in finishedTwo }) }
            shown = { made.snapshot.revision }
        case .observation:
            let made = SnapshotPresentation(Mark(revision: 0))
            presentation = made
            apply = { made.apply(Mark(revision: $0)) }
            follow = { await made.follow(snapshotsFrom: { @MainActor () async in finishedTwo }) }
            shown = { made.snapshot.revision }
        }
        let hook = onceWhileShowing(presentation) {
            Task.immediate { @MainActor in
                await follow()
                returned.fill(shown())
                done.raise()
            }
        }
        apply(1)
        await done.wait()
        #expect(returned.value == 2)
        withExtendedLifetime((hook, presentation)) {}
    }

    // From inside the publication of snapshot 1, a task follows an open sequence seeded with 2, and is
    // cancelled before that publication's callback returns. The publication has not shown 2 yet, and
    // it never does; the watermark stays at what is shown, so 2 can still be applied.
    @Test(arguments: PresentationClass.allCases)
    func aFollowerCancelledBeforeItsDeferredFirstSnapshotIsShownShowsNothing(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let openTwo = try sequence(holding: 2, finished: false)
        var follower: Task<Void, Never>?
        var shownValues: [UInt64] = []
        let presentation: AnyObject
        let apply: @MainActor (UInt64) -> Bool
        let follow: @MainActor () async -> Void
        let live: @MainActor () -> Bool
        let watch: AnyObject
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            presentation = made
            apply = { made.apply(Mark(revision: $0)) }
            follow = { await made.follow(openTwo) }
            live = { made.isObserving }
            watch = made.presentedSnapshots.dropFirst().sink { shownValues.append($0.revision) }
        case .observation:
            let made = SnapshotPresentation(Mark(revision: 0))
            presentation = made
            apply = { made.apply(Mark(revision: $0)) }
            follow = { await made.follow(openTwo) }
            live = { made.isObserving }
            watch = made
        }
        let hook = onceWhileShowing(presentation) {
            follower = Task.immediate { @MainActor in await follow() }
            follower?.cancel()
        }
        _ = apply(1)
        await follower?.value
        if kind == .combine { #expect(shownValues == [1]) }
        #expect(!live())
        #expect(apply(2))
        withExtendedLifetime((hook, watch, presentation)) {}
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ReleaseOrderTests {
    // A host of your own cancels the token it kept, whose action holds the last reference to a lease
    // that frees the slot when it is released, and the action ends the sequence and returns. The token
    // releases its action, and so the lease, before it records that the cancellation has returned, so
    // the unread element is released only once the slot is free.
    @Test func aSharedTokenReleasesItsActionBeforeItsCancellationReturns() throws {
        let events = Events()
        let held = Later<SnapshotSequence<Released>>()
        var receive: (@Sendable (Released) -> Void)?
        var token: SnapshotSubscription?
        let sequence = try SnapshotSequence<Released> { offer, _ in
            receive = offer
            let made = SnapshotSubscription { [lease = Released(events, "lease freed")] in
                withExtendedLifetime(lease) {}
                held.value?.cancel(isolation: nil)
                events.record("action returning")
            }
            token = made
            return made
        }
        held.fill(sequence)
        receive?(Released(events, "unread released"))
        token?.cancel()
        #expect(events.all == ["action returning", "lease freed", "unread released"])
    }

    // An isolated token ended where its action cannot run runs its release closure instead, and a call
    // that ends it from inside that closure waits for it like a call inside the action does: its
    // completion runs once the release has returned.
    @Test func anIsolatedTokenEndedElsewhereRunsACallMadeDuringItsReleaseAfterIt() {
        let events = Events()
        let box = TokenBox()
        let token = IsolatedSnapshotSubscription<MainActor>(
            owner: MainActor.shared,
            cancel: { events.record("action") },
            release: { [weak box] in
                // The test ends the token on the main actor, which runs the release there.
                MainActor.assumeIsolated {
                    events.record("release entered")
                    box?.token?.end(on: nil) { events.record("inner done") }
                    events.record("release returning")
                }
            }
        )
        box.token = token
        token.end(on: nil) { events.record("outer done") }
        #expect(events.all == ["release entered", "release returning", "outer done", "inner done"])
    }
}

/// Holds a confined token for a closure that reaches it on the main actor.
@MainActor private final class TokenBox {
    var token: IsolatedSnapshotSubscription<MainActor>?
}

/// Attaches a subscriber to a publisher when asked, as a driver's cancellation handler does here.
@MainActor private final class LateAttachment {
    var publisher: SnapshotPublisher<UInt64>?
    let subscriber = Recorder()
    func attach() { publisher?.subscribe(subscriber) }
}

/// A subscriber that requests every value and records what it receives.
private final class Recorder: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var events: [String] = []
    func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        events.append("value \(input)")
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { events.append("finished") }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorHostTeardownTests {
    // The last reference to a main-actor host is released on the main actor while a driver waits. The
    // host's destructor cancels that driver, whose cancellation handler runs synchronously and attaches
    // a subscriber to a publisher of the host. The publisher already knows that its owner promises
    // nothing more, so the subscriber receives only the completion.
    @Test func aPublisherAttachedFromADriversCancellationDuringItsHostsReleaseOnlyFinishes() async throws {
        let user = try UserID("kyle")
        let late = LateAttachment()
        let started = Signal()
        var host: GeneratedProfile.MainActorHost? = GeneratedProfile.MainActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    await withTaskCancellationHandler {
                        started.raise()
                        try? await Task.sleep(for: .seconds(3600))
                    } onCancel: {
                        // The host is released on the main actor, which cancels the driver there.
                        MainActor.assumeIsolated { late.attach() }
                    }
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        late.publisher = try #require(host).snapshotPublisher { $0.revision }
        try #require(host).send(.load(ProfileRequest(userID: user)))
        await started.wait()
        weak let released = host
        host = nil
        #expect(released == nil)
        #expect(late.subscriber.events == ["finished"])
    }
}

private typealias IsolatedRaw = RuntimeIsolatedHost<MainActor, Int, Int, RuntimeTicket, Never>

/// Refers to an isolated host without keeping it.
@MainActor private final class HostReference {
    weak var host: IsolatedRaw?
    init(_ host: IsolatedRaw) { self.host = host }
}

/// Closes its host when it is released, which the host does on the main actor.
private final class Closer: Sendable {
    private let reference: HostReference
    init(_ reference: HostReference) { self.reference = reference }
    deinit {
        let reference = reference
        MainActor.assumeIsolated { _ = reference.host?.close(isolation: MainActor.shared) }
    }
}

/// A projection of the retained completions whose release closes `host`.
@MainActor private func closing(_ host: IsolatedRaw) -> ([IsolatedRaw.Ledger.Pending]) -> Int {
    let closer = Closer(HostReference(host))
    return { _ in withExtendedLifetime(closer) { 0 } }
}

/// Keeps a confined stream, and drops it when it is released.
@MainActor private final class StreamKeeper {
    var stream: IsolatedSnapshotSequence<Int>?
    init(_ stream: consuming IsolatedSnapshotSequence<Int>) { self.stream = consume stream }
}

/// Counts the projections of a pending-completion registration.
@MainActor private final class Projections {
    var count = 0
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct IsolatedPendingAdmissionTests {
    // An isolated host admits a pending-completion registration C. Sweeping the earlier registration A
    // releases its callbacks, which drop B's stream; admitting C then sweeps B, and releasing B's
    // callbacks closes the host, whose publication delivers the final collection to C and finishes it.
    // C was admitted before that release, so the host delivers the final collection to it once.
    @Test func aPendingRegistrationAdmittedBeforeItsHostClosesReceivesTheFinalCollectionOnce() async throws {
        let host = IsolatedRaw(
            0,
            scopes: [],
            isolation: MainActor.shared,
            configuration: try ManagedConfiguration(subscribers: 2),
            driver: { _, work in work.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        var b: IsolatedSnapshotSequence<Int>? = try host.pendingCompletionUpdates(
            closing(host),
            isolation: MainActor.shared
        )
        // A's projection holds the only reference to B's stream.
        var keeper: StreamKeeper? = StreamKeeper(b.take()!)
        // Dropping A's stream unread closes its gate; the host releases its callbacks at its next sweep.
        _ = try host.pendingCompletionUpdates(
            { [keeper] _ in withExtendedLifetime(keeper) { 0 } },
            isolation: MainActor.shared
        )
        keeper = nil
        let projections = Projections()
        var c = try host.pendingCompletionUpdates(
            { _ in
                projections.count += 1
                return projections.count
            },
            isolation: MainActor.shared
        )
        #expect(await c.next() == 1)
        #expect(await c.next() == nil)
        #expect(projections.count == 1)
    }
}
