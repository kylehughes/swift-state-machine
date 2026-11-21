import Combine
import Dispatch
import Observation
import StateMachine
import StateMachineTestSupport
import StateMachineUI
import Testing
import os

// Every state transition of a registration or a presentation reads each client value once, decides
// without running client code, commits, and only then runs client code and releases client values;
// after each callout it validates the observation again before it changes anything for it. These
// tests run client code at the points where that matters: inside a host's token cancellation, inside
// the cancellation of the registration an observation replaces, inside a revision projection, inside a
// snapshot publication, and while an earlier registration is still being made.

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

/// A projection whose release a test records.
private final class Probe: Sendable {
    private let events: Events?
    init(_ events: Events?) { self.events = events }
    deinit { events?.record("released") }
}

/// A value any thread fills and reads.
private final class Later<Value: Sendable>: Sendable {
    private let stored = OSAllocatedUnfairLock<Value?>(initialState: nil)
    var value: Value? { stored.withLock { $0 } }
    func fill(_ value: Value) { stored.withLock { $0 = value } }
}

/// The task a callout cancels, filled before the task first runs.
private final class TaskSlot: Sendable {
    private let stored = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    func fill(_ task: Task<Void, Never>) { stored.withLock { $0 = task } }
    func cancel() { stored.withLock { $0 }?.cancel() }
}

/// Runs `body` on another thread and returns once it has, or once the waiting task is cancelled.
private func elsewhere(_ body: @escaping @Sendable () -> Void) { runOnOwnThreadAndWait(body) }

/// A sequence of an owner of the test's own, which the test feeds element by element.
private final class Feed: Sendable {
    private let callbacks = OSAllocatedUnfairLock<(@Sendable (UInt64) -> Void)?>(initialState: nil)
    private let cancellations = OSAllocatedUnfairLock(initialState: 0)
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void = {}) { self.onCancel = onCancel }

    /// How many times the sequence cancelled its token.
    var cancelled: Int { cancellations.withLock { $0 } }
    /// Registers the sequence, offering `first` before the registration returns, when there is one.
    func sequence(first: UInt64? = nil) throws -> SnapshotSequence<UInt64> {
        try SnapshotSequence<UInt64> { receive, _ in
            callbacks.withLock { $0 = receive }
            if let first { receive(first) }
            return SnapshotSubscription { [cancellations, onCancel] in
                cancellations.withLock { $0 += 1 }
                onCancel()
            }
        }
    }
    func offer(_ element: UInt64) { callbacks.withLock { $0 }?(element) }
}

private typealias RawHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>

@MainActor private func makeRawHost(subscribers: Int = 1) throws -> RawHost {
    RawHost(
        0,
        scopes: [],
        configuration: try ManagedConfiguration(subscribers: subscribers),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

// MARK: Presentations

/// The members of both snapshot presentation classes that these tests use.
@MainActor private protocol Presented: AnyObject {
    var snapshot: UInt64 { get }
    var isObserving: Bool { get }
    @discardableResult func apply(_ next: UInt64) -> Bool
    func observe(_ snapshots: SnapshotSequence<UInt64>)
    func observe<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<UInt64>
    ) async throws(Failure)
    func follow(_ snapshots: SnapshotSequence<UInt64>) async
    func stopObserving()
}

extension SnapshotObservableObject: Presented where Snapshot == UInt64 {}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
extension SnapshotPresentation: Presented where Snapshot == UInt64 {}

/// Creates a presentation of `kind`, or `nil` where that class is unavailable.
@MainActor private func presentation(
    _ kind: PresentationClass,
    revision: @escaping @MainActor (UInt64) -> UInt64 = { $0 }
) -> (any Presented)? {
    switch kind {
    case .combine: return SnapshotObservableObject(0, revision: revision)
    case .observation:
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
        return SnapshotPresentation(0, revision: revision)
    }
}

/// Runs `hook` inside each snapshot publication's callback, before the snapshot is assigned, until the
/// returned token is released.
@MainActor private func onShow(_ shown: any Presented, _ hook: @escaping @MainActor () -> Void) -> AnyObject {
    if let combine = shown as? SnapshotObservableObject<UInt64> {
        return combine.presentedSnapshots.dropFirst().sink { _ in hook() }
    }
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
        let model = shown as? SnapshotPresentation<UInt64>
    else { preconditionFailure("an unknown presentation") }
    let installed = Hook(hook)
    track(model, installed)
    return installed
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private func track(_ model: SnapshotPresentation<UInt64>, _ installed: Hook) {
    withObservationTracking {
        _ = model.snapshot
    } onChange: { [weak model, weak installed] in
        MainActor.assumeIsolated {
            guard let model, let installed else { return }
            track(model, installed)
            installed.hook()
        }
    }
}

/// Keeps a publication hook installed while it lives.
@MainActor private final class Hook {
    let hook: @MainActor () -> Void
    init(_ hook: @escaping @MainActor () -> Void) { self.hook = hook }
}

// MARK: Hosts of the test's own

/// A snapshot whose revision getter runs a hook on a chosen read.
private final class Counted: StateMachineSnapshot, Sendable {
    let value: UInt64
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    private let hookedRead: Int
    private let hook: (@MainActor @Sendable () -> Void)?

    init(_ value: UInt64, onRead hookedRead: Int = 0, _ hook: (@MainActor @Sendable () -> Void)? = nil) {
        self.value = value
        self.hookedRead = hookedRead
        self.hook = hook
    }
    var revision: UInt64 {
        let read = reads.withLock {
            $0 += 1
            return $0
        }
        if read == hookedRead, let hook { MainActor.assumeIsolated { hook() } }
        return value
    }
}

/// A `MainActor` host of the test's own with one slot, freed only when its subscription is cancelled.
///
/// Sending installs the input as the snapshot without delivering it, and closing finishes the
/// registration; a host closed before it registers finishes inside `subscribe`.
@MainActor private final class DrivenHost: MainActorStateMachineHost {
    typealias Input = Counted
    typealias Snapshot = Counted
    struct Receipt: StateMachineReceipt {
        let snapshot: Counted
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private(set) var current = Counted(0)
    private(set) var registrations = 0
    private var finishes: [@MainActor () -> Void] = []
    private var closed = false

    func snapshot() -> Counted { current }
    func send(_ input: Counted) -> Receipt {
        current = input
        return Receipt(snapshot: input)
    }
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Counted) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        registrations += 1
        receive(current)
        if closed { onFinish() } else { finishes.append(onFinish) }
        return MainActorSnapshotSubscription { [weak self] in self?.registrations -= 1 }
    }
    @discardableResult func close() -> Receipt {
        closed = true
        let finishing = finishes
        finishes = []
        for finish in finishing { finish() }
        return Receipt(snapshot: current)
    }
}

/// A snapshot of `EvictingHost`.
private struct Shot: StateMachineSnapshot, Sendable {
    let revision: UInt64
}

/// A `MainActor` host of the test's own that keeps the token it returns and cancels it itself.
@MainActor private final class EvictingHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Shot
    struct Receipt: StateMachineReceipt {
        let snapshot: Shot
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private(set) var token: MainActorSnapshotSubscription?
    private(set) var receive: (@MainActor (Shot) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    func snapshot() -> Shot { Shot(revision: 0) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Shot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        self.receive = receive
        let token = MainActorSnapshotSubscription { [weak self] in self?.onCancel?() }
        self.token = token
        return token
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Shot(revision: 0)) }
}

/// A main-actor object that keeps a confined stream that its host's token ends.
@MainActor private final class StreamKeeper {
    var stream: IsolatedSnapshotSequence<Probe>?
}

// MARK: Tests

@MainActor @Suite(.timeLimit(.minutes(1))) struct TokenCancellationTests {
    // A host of your own cancels the token it returned and, inside `onCancel`, ends the sequence before
    // it frees its slot. The sequence's end finds the cancellation in progress, never waits, and leaves
    // the unread element for the outer cancellation, which releases it once `onCancel` returns.
    @Test func aSequenceEndedInsideItsHostsCancellationReleasesItsElementOnceTheSlotIsFree() throws {
        let events = Events()
        let held = Later<SnapshotSequence<Probe>>()
        var receive: (@Sendable (Probe) -> Void)?
        var token: SnapshotSubscription?
        let sequence = try SnapshotSequence<Probe> { offer, _ in
            receive = offer
            let made = SnapshotSubscription {
                events.record("callback entered")
                held.value?.cancel(isolation: nil)
                events.record("slot freed")
            }
            token = made
            return made
        }
        held.fill(sequence)
        receive?(Probe(events))
        token?.cancel()
        #expect(events.all == ["callback entered", "slot freed", "released"])
    }

    // The same for a `MainActor` host of your own, whose sequence ends on the main actor.
    @Test func aMainActorSequenceEndedInsideItsHostsCancellationReleasesItsElementOnceTheSlotIsFree() throws {
        let events = Events()
        let host = EvictingHost()
        let sequence = try host.snapshots { _ in Probe(events) }
        host.onCancel = {
            events.record("callback entered")
            sequence.cancel()
            events.record("slot freed")
        }
        host.receive?(Shot(revision: 1))
        host.token?.cancel()
        #expect(events.all == ["callback entered", "slot freed", "released"])
    }

    // The same for a stream confined to its owner's actor, ended inside the token's `onCancel`.
    @Test func aConfinedStreamEndedInsideItsHostsCancellationReleasesItsElementOnceTheSlotIsFree() throws {
        let events = Events()
        let keeper = StreamKeeper()
        var receive: ((Int) -> Void)?
        var token: IsolatedSnapshotSubscription<MainActor>?
        keeper.stream = try IsolatedSnapshotSequence<Probe>({ (_: Int) in Probe(events) }) {
            (offer, _) throws(SubscriptionFailure) in
            receive = offer
            let made = IsolatedSnapshotSubscription(isolation: MainActor.shared) {
                events.record("callback entered")
                keeper.stream?.cancel()
                events.record("slot freed")
            }
            token = made
            return made
        }
        receive?(1)
        token?.cancel(isolation: MainActor.shared)
        #expect(events.all == ["callback entered", "slot freed", "released"])
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct FollowCalloutTests {
    // Ending the observation that `follow(_:)` replaces cancels that registration's token, whose
    // `onCancel` cancels the following task. The sequence is released without being shown.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledByThePredecessorsReleaseShowsNothing(_ kind: PresentationClass) async throws {
        guard let shown = presentation(kind) else { return }
        let follower = TaskSlot()
        let predecessor = Feed { follower.cancel() }
        shown.observe(try predecessor.sequence())
        let feed = Feed()
        let sequence = try feed.sequence(first: 1)
        let task = Task { await shown.follow(sequence) }
        follower.fill(task)
        await task.value
        #expect(predecessor.cancelled == 1)
        #expect(feed.cancelled == 1)
        #expect(shown.snapshot == 0)
        #expect(!shown.isObserving)
    }

    // The revision closure cancels the following task while it evaluates the sequence's first
    // element: the element is not shown and the observation is never live.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledByTheRevisionOfItsFirstElementShowsNothing(_ kind: PresentationClass) async throws {
        let follower = TaskSlot()
        guard
            let shown = presentation(
                kind,
                revision: { value in
                    if value == 1 { follower.cancel() }
                    return value
                }
            )
        else { return }
        var shownValues = 0
        let hook = onShow(shown) { shownValues += 1 }
        let feed = Feed()
        let sequence = try feed.sequence(first: 1)
        let task = Task { await shown.follow(sequence) }
        follower.fill(task)
        await task.value
        #expect(shownValues == 0)
        #expect(shown.snapshot == 0)
        #expect(!shown.isObserving)
        #expect(feed.cancelled == 1)
        withExtendedLifetime(hook) {}
    }

    // The revision closure cancels the following task while it evaluates a later element: that element
    // is not shown, and the observation ends.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledByTheRevisionOfALaterElementShowsNothingMore(_ kind: PresentationClass) async throws {
        let follower = TaskSlot()
        guard
            let shown = presentation(
                kind,
                revision: { value in
                    if value == 2 { follower.cancel() }
                    return value
                }
            )
        else { return }
        let feed = Feed()
        let sequence = try feed.sequence(first: 1)
        let task = Task { await shown.follow(sequence) }
        follower.fill(task)
        await untilLive(shown)
        feed.offer(2)
        await task.value
        #expect(shown.snapshot == 1)
        #expect(!shown.isObserving)
        #expect(feed.cancelled == 1)
    }
}

/// Returns once `shown` reports a live observation.
@MainActor private func untilLive(_ shown: any Presented) async {
    if let combine = shown as? SnapshotObservableObject<UInt64> { return await untilObserving(combine) }
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
        let model = shown as? SnapshotPresentation<UInt64>
    else { preconditionFailure("an unknown presentation") }
    await untilObserving(model)
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct AsynchronousRegistrationTests {
    // Registration A takes the only slot and suspends before it returns its sequence. Registration B
    // replaces it, and waits for A to return and be released before it registers, so it gets the slot.
    @Test(arguments: PresentationClass.allCases)
    func aRegistrationWaitsForAnEarlierOneToReleaseTheSlot(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        guard let shown = presentation(kind) else { return }
        let host = try makeRawHost()
        let resume = Signal()
        var asked: [String] = []
        let first = Task.immediate { @MainActor in
            try await shown.observe(snapshotsFrom: {
                asked.append("A")
                let snapshots = try host.sendableSnapshots { UInt64($0.revision) }
                await resume.wait()
                return snapshots
            })
        }
        #expect(host.subscriberCount == 1)
        let second = Task.immediate { @MainActor in
            try await shown.observe(snapshotsFrom: {
                asked.append("B")
                return try host.sendableSnapshots { UInt64($0.revision) }
            })
        }
        #expect(asked == ["A"])
        resume.raise()
        try await first.value
        try await second.value
        #expect(asked == ["A", "B"])
        #expect(host.subscriberCount == 1)
        #expect(shown.isObserving)
        shown.stopObserving()
        #expect(host.subscriberCount == 0)
    }

    // A registration that waits for an earlier one and is replaced meanwhile runs nothing.
    @Test(arguments: PresentationClass.allCases)
    func aWaitingRegistrationThatIsReplacedRunsNothing(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        guard let shown = presentation(kind) else { return }
        let host = try makeRawHost()
        let resume = Signal()
        var asked: [String] = []
        let first = Task.immediate { @MainActor in
            try await shown.observe(snapshotsFrom: {
                asked.append("A")
                let snapshots = try host.sendableSnapshots { UInt64($0.revision) }
                await resume.wait()
                return snapshots
            })
        }
        let second = Task.immediate { @MainActor in
            try await shown.observe(snapshotsFrom: {
                asked.append("B")
                return try host.sendableSnapshots { UInt64($0.revision) }
            })
        }
        shown.stopObserving()
        resume.raise()
        try await first.value
        try await second.value
        #expect(asked == ["A"])
        #expect(host.subscriberCount == 0)
        #expect(!shown.isObserving)
    }

    // An asynchronous registration started inside a snapshot publication returns only once the
    // publication has shown its first snapshot and reported it live.
    @Test(arguments: PresentationClass.allCases)
    func anAsynchronousRegistrationInsideAPublicationReturnsOnceItsFirstSnapshotIsShown(
        _ kind: PresentationClass
    ) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        guard let shown = presentation(kind) else { return }
        let feed = Feed()
        var registration: Task<(UInt64, Bool), any Error>?
        let hook = onShow(shown) {
            guard registration == nil else { return }
            registration = Task.immediate { @MainActor in
                try await shown.observe(snapshotsFrom: { try feed.sequence(first: 2) })
                return (shown.snapshot, shown.isObserving)
            }
        }
        shown.apply(1)
        let (snapshot, live) = try await #require(registration).value
        #expect(snapshot == 2)
        #expect(live)
        shown.stopObserving()
        withExtendedLifetime(hook) {}
    }
}

/// A driving presentation of either class, through the members these tests use.
@MainActor private struct Driving {
    let snapshot: () -> UInt64
    let isObserving: () -> Bool
    let send: (Counted) -> Void
    let onLive: (@escaping @MainActor (Bool) -> Void) -> AnyObject
    /// Every snapshot revision the presentation has published, in order, starting with its first.
    let history: () -> [UInt64]
    let stop: () -> Void

    init?(_ kind: PresentationClass, _ host: DrivenHost) {
        let published = History()
        switch kind {
        case .combine:
            let driven = StateMachineObservableObject(host)
            published.values = [driven.snapshot.value]
            published.token = driven.presentedSnapshots.dropFirst().sink { published.values.append($0.value) }
            snapshot = { driven.snapshot.value }
            isObserving = { driven.isObserving }
            send = { driven.send($0) }
            onLive = { hook in driven.$isObserving.dropFirst().sink { hook($0) } }
            history = { published.values }
            stop = { driven.stopObserving() }
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let driven = StateMachinePresentation(host)
            // Observation reports a change before it is made, so each report records the value it
            // replaces, and the history ends with the value in place.
            trackSnapshots(driven, published)
            snapshot = { driven.snapshot.value }
            isObserving = { driven.isObserving }
            send = { driven.send($0) }
            onLive = { hook in
                let installed = LiveHook(hook)
                trackLive(driven, installed)
                return installed
            }
            history = { published.values + [driven.snapshot.value] }
            stop = { driven.stopObserving() }
        }
    }
}

/// The revisions a driving presentation published.
@MainActor private final class History {
    var values: [UInt64] = []
    var token: AnyObject?
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private func trackSnapshots(_ model: StateMachinePresentation<DrivenHost>, _ history: History) {
    withObservationTracking {
        _ = model.snapshot
    } onChange: { [weak model, weak history] in
        MainActor.assumeIsolated {
            guard let model, let history else { return }
            history.values.append(model.snapshot.value)
            trackSnapshots(model, history)
        }
    }
}

/// Keeps an `isObserving` hook installed while it lives.
@MainActor private final class LiveHook {
    let hook: @MainActor (Bool) -> Void
    init(_ hook: @escaping @MainActor (Bool) -> Void) { self.hook = hook }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private func trackLive(_ model: StateMachinePresentation<DrivenHost>, _ installed: LiveHook) {
    withObservationTracking {
        _ = model.isObserving
    } onChange: { [weak model, weak installed] in
        MainActor.assumeIsolated {
            guard let model, let installed else { return }
            installed.hook(!model.isObserving)
            trackLive(model, installed)
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DrivingPresentationTests {
    // The owner finishes the registration by closing. The presentation cancels its subscription before
    // it reports the end, so the host's only slot is free by then and a new registration succeeds.
    @Test(arguments: PresentationClass.allCases)
    func aFinishedRegistrationFreesItsSlotBeforeTheEndIsReported(_ kind: PresentationClass) throws {
        let host = DrivenHost()
        guard let driven = Driving(kind, host) else { return }
        #expect(driven.isObserving())
        var slotsAtReport: [Int] = []
        let hook = driven.onLive { live in if !live { slotsAtReport.append(host.registrations) } }
        host.close()
        #expect(!driven.isObserving())
        #expect(slotsAtReport == [0])
        #expect(host.registrations == 0)
        let again = Driving(kind, host)
        #expect(again?.isObserving() == false)
        withExtendedLifetime((hook, again)) {}
    }

    // A host that has already closed finishes inside `subscribe`; the presentation cancels the token
    // the host then returns before it reports the end.
    @Test(arguments: PresentationClass.allCases)
    func aRegistrationFinishedInsideTheRegistrationCallFreesItsSlot(_ kind: PresentationClass) throws {
        let host = DrivenHost()
        host.close()
        guard let driven = Driving(kind, host) else { return }
        #expect(!driven.isObserving())
        #expect(host.registrations == 0)
    }

    // A snapshot whose revision getter sends a newer input, on the first or the second read, never
    // replaces the newer snapshot it caused: the published revisions only grow, and the presentation
    // ends at the host's snapshot.
    @Test(arguments: PresentationClass.allCases, [1, 2])
    func aRevisionGetterThatSendsInputCannotRegressTheSnapshot(_ kind: PresentationClass, read: Int) throws {
        let host = DrivenHost()
        guard let driven = Driving(kind, host) else { return }
        let sender = Later<@MainActor @Sendable (Counted) -> Void>()
        sender.fill { driven.send($0) }
        driven.send(Counted(1, onRead: read) { sender.value?(Counted(2)) })
        let published = driven.history()
        #expect(published == published.sorted())
        #expect(Set(published).count == published.count)
        #expect(driven.snapshot() == host.current.value)
        driven.stop()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SubscriberCountObservationTests {
    // A registration released on another thread stops counting at once. A reader sees the count fall
    // to zero; the next admission prunes the released registration and adds another in the same turn,
    // which brings the count back to the value last reported, and still invalidates the reader.
    @Test func aCountThatFallsAndRisesInOneTurnInvalidatesItsReader() throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = try makeRawHost()
        let first = try host.sendableSnapshots { $0.revision }
        #expect(host.subscriberCount == 1)
        elsewhere { first.cancel(isolation: nil) }
        let invalidated = Later<Bool>()
        let read = withObservationTracking {
            host.subscriberCount
        } onChange: {
            invalidated.fill(true)
        }
        #expect(read == 0)
        let second = try host.sendableSnapshots { $0.revision }
        #expect(host.subscriberCount == 1)
        #expect(invalidated.value == true)
        second.cancel()
    }
}
