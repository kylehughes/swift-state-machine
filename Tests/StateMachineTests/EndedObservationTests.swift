import Combine
import Observation
import StateMachine
import StateMachineUI
import Testing
import os

// A presentation owns a sequence from the moment `observe(_:)` or `follow(_:)` receives it, so an
// observation that a callback starts while the call is still ending the one before finds that sequence
// among the registrations it lets go: `isObserving` reports the end only once its slot is free, and an
// asynchronous observation registers only then. A driving presentation shows nothing its host delivers
// once its own end has begun.

/// A host of the test's own with one slot, which a registration holds until its token is cancelled.
///
/// It keeps the callbacks of its latest registration, as a host does while it can still deliver.
private final class OneSlot: Sendable {
    private let held = OSAllocatedUnfairLock(initialState: false)
    private let cancelling = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let callbacks = OSAllocatedUnfairLock<(@Sendable (UInt64) -> Void)?>(initialState: nil)

    /// Whether a registration holds the slot.
    var isHeld: Bool { held.withLock { $0 } }
    /// Runs `action` once, inside the next cancellation of a token, before the slot is freed.
    func onNextCancel(_ action: @escaping @Sendable () -> Void) { cancelling.withLock { $0 = action } }
    /// Registers a sequence that offers `first` at once, or throws when the slot is held.
    func sequence(first: UInt64) throws(SubscriptionFailure) -> SnapshotSequence<UInt64> {
        try SnapshotSequence<UInt64> { [held, cancelling, callbacks] (receive, _) throws(SubscriptionFailure) in
            let taken = held.withLock { held -> Bool in
                guard !held else { return false }
                held = true
                return true
            }
            guard taken else { throw .capacityExceeded }
            callbacks.withLock { $0 = receive }
            receive(first)
            return SnapshotSubscription {
                cancelling.withLock { $0.take() }?()
                held.withLock { $0 = false }
            }
        }
    }
}

/// The members of both snapshot presentation classes that these tests use.
@MainActor private protocol Presented: AnyObject, Sendable {
    var snapshot: UInt64 { get }
    var isObserving: Bool { get }
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

@MainActor private func presentation(_ kind: PresentationClass) -> (any Presented)? {
    switch kind {
    case .combine: return SnapshotObservableObject(0, revision: { $0 })
    case .observation:
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
        return SnapshotPresentation(0, revision: { $0 })
    }
}

@MainActor private func untilLive(_ shown: any Presented) async {
    if let combine = shown as? SnapshotObservableObject<UInt64> { return await untilObserving(combine) }
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
        let model = shown as? SnapshotPresentation<UInt64>
    else { preconditionFailure("an unknown presentation") }
    await untilObserving(model)
}

/// Runs a hook inside the next report that an observation ended, while that report is being made.
@MainActor private final class EndReport {
    private var hook: (@MainActor () -> Void)?
    private var subscription: AnyCancellable?

    init(_ shown: any Presented, _ hook: @escaping @MainActor () -> Void) {
        self.hook = hook
        if let combine = shown as? SnapshotObservableObject<UInt64> {
            subscription = combine.$isObserving.dropFirst()
                .sink { [weak self] live in
                    if !live { self?.fire() }
                }
        } else if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
            let model = shown as? SnapshotPresentation<UInt64>
        {
            track(model)
        }
    }
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private func track(_ model: SnapshotPresentation<UInt64>) {
        // Observation calls this before the change; a live model is about to report the end.
        let live = withObservationTracking {
            model.isObserving
        } onChange: { [weak self, weak model] in
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                let ending = model.isObserving
                self.track(model)
                if ending { self.fire() }
            }
        }
        _ = live
    }
    private func fire() {
        let taken = hook
        hook = nil
        taken?()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct HandedSequenceTests {
    // `observe(_:)` receives a sequence that holds host B's only slot and ends the observation of A. The
    // report of that end starts an asynchronous observation of B, which ends the observation that the
    // sequence was about to begin, so the presentation lets the sequence go before it registers with B
    // again, and that registration finds the slot free.
    @Test(arguments: PresentationClass.allCases)
    func anAsynchronousObservationStartedByTheEndReportFindsTheHandedSequenceReleased(
        _ kind: PresentationClass
    ) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        guard let shown = presentation(kind) else { return }
        let a = OneSlot()
        let b = OneSlot()
        shown.observe(try a.sequence(first: 1))
        await untilLive(shown)
        var started: Task<Void, any Error>?
        let report = EndReport(shown) {
            started = Task.immediate { @MainActor in
                try await shown.observe(snapshotsFrom: { try b.sequence(first: 3) })
            }
        }
        shown.observe(try b.sequence(first: 2))
        let observing = try #require(started)
        await #expect(throws: Never.self) { try await observing.value }
        #expect(!a.isHeld)
        #expect(b.isHeld)
        #expect(shown.isObserving)
        #expect(shown.snapshot == 3)
        shown.stopObserving()
        #expect(!b.isHeld)
        withExtendedLifetime(report) {}
    }

    // The cancellation of A's token, which runs inside `observe(_:)` and `follow(_:)` before the handed
    // sequence begins, stops observing. The presentation lets the sequence go there, and `isObserving`
    // reports the end only once that sequence has freed B's slot.
    @Test(arguments: PresentationClass.allCases, [false, true])
    func aStopDuringTheEndOfThePredecessorReportsOnceTheHandedSequenceFreedItsSlot(
        _ kind: PresentationClass,
        following: Bool
    ) async throws {
        guard let shown = presentation(kind) else { return }
        let a = OneSlot()
        let b = OneSlot()
        shown.observe(try a.sequence(first: 1))
        await untilLive(shown)
        var heldAtReport: Bool?
        let report = EndReport(shown) { heldAtReport = b.isHeld }
        a.onNextCancel { MainActor.assumeIsolated { shown.stopObserving() } }
        let sequence = try b.sequence(first: 2)
        if following {
            await shown.follow(sequence)
        } else {
            shown.observe(sequence)
        }
        #expect(heldAtReport == false)
        #expect(!a.isHeld)
        #expect(!b.isHeld)
        #expect(!shown.isObserving)
        #expect(shown.snapshot == 1)
        withExtendedLifetime(report) {}
    }

    // `follow(_:)` runs on a task that is already cancelled, with a sequence that holds host B's only
    // slot. It ends the observation of A and releases the sequence without showing it, and reports the
    // end only once that sequence has freed B's slot.
    @Test(arguments: PresentationClass.allCases)
    func aFollowOnACancelledTaskReportsTheEndOnceItReleasedTheSequence(_ kind: PresentationClass) async throws {
        guard let shown = presentation(kind) else { return }
        let a = OneSlot()
        let b = OneSlot()
        shown.observe(try a.sequence(first: 1))
        await untilLive(shown)
        var heldAtReport: Bool?
        let report = EndReport(shown) { heldAtReport = b.isHeld }
        let sequence = try b.sequence(first: 2)
        let follower = Task { @MainActor in await shown.follow(sequence) }
        follower.cancel()
        await follower.value
        #expect(heldAtReport == false)
        #expect(!a.isHeld)
        #expect(!b.isHeld)
        #expect(!shown.isObserving)
        #expect(shown.snapshot == 1)
        withExtendedLifetime(report) {}
    }
}

// MARK: Driving presentations

/// A snapshot of `CancellingHost`, which reports its release.
private final class Shot: StateMachineSnapshot, Sendable {
    let revision: UInt64
    private let onRelease: (@Sendable () -> Void)?

    init(revision: UInt64, onRelease: (@Sendable () -> Void)? = nil) {
        self.revision = revision
        self.onRelease = onRelease
    }
    deinit { onRelease?() }
}

/// A `MainActor` host of the test's own that delivers a newer snapshot from inside its token's
/// cancellation, before it frees its slot, and records whether that snapshot is released while the
/// slot is still held.
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

    private(set) var current = Shot(revision: 0)
    private let held = OSAllocatedUnfairLock(initialState: false)
    // For each snapshot delivered from inside a cancellation and since released, whether the slot was
    // still held then.
    private let releases = OSAllocatedUnfairLock<[Bool]>(initialState: [])

    var isHeld: Bool { held.withLock { $0 } }
    var releasedWhileHeld: [Bool] { releases.withLock { $0 } }

    func snapshot() -> Shot { current }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Shot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        held.withLock { $0 = true }
        receive(current)
        return MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            let revision = self.current.revision + 10
            self.current = Shot(revision: revision)
            receive(
                Shot(revision: revision) { [held, releases] in
                    let still = held.withLock { $0 }
                    releases.withLock { $0.append(still) }
                }
            )
            self.held.withLock { $0 = false }
        }
    }
    @discardableResult func close() -> Receipt {
        current = Shot(revision: current.revision + 1)
        return Receipt(snapshot: current)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DrivingEndTests {
    // The host delivers revision 10 from inside the cancellation that `stopObserving()` makes. The
    // presentation has ended its observation by then and keeps showing revision 0, and it releases the
    // snapshot it did not show only once the slot is free.
    @Test func aCombineDrivingPresentationShowsNothingItsHostDeliversWhileItStops() async {
        let host = CancellingHost()
        let shown = StateMachineObservableObject(host)
        #expect(shown.isObserving)
        shown.stopObserving()
        #expect(!host.isHeld)
        #expect(shown.snapshot.revision == 0)
        #expect(!shown.isObserving)
        await Task.yield()
        #expect(host.releasedWhileHeld == [false])
    }

    // `close()` ends the observation first, so the delivery from inside that cancellation is not shown
    // either; the closed snapshot from the receipt is.
    @Test func aCombineDrivingPresentationShowsOnlyTheClosedSnapshotWhenItsHostDeliversWhileItCloses() {
        let host = CancellingHost()
        let shown = StateMachineObservableObject(host)
        var published: [UInt64] = []
        let subscription = shown.presentedSnapshots.sink { published.append($0.revision) }
        shown.close()
        #expect(published == [0, 11])
        #expect(shown.snapshot.revision == 11)
        #expect(!shown.isObserving)
        subscription.cancel()
    }

    @Test func anObservationDrivingPresentationShowsNothingItsHostDeliversWhileItStops() async {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = CancellingHost()
        let shown = StateMachinePresentation(host)
        #expect(shown.isObserving)
        shown.stopObserving()
        #expect(!host.isHeld)
        #expect(shown.snapshot.revision == 0)
        #expect(!shown.isObserving)
        await Task.yield()
        #expect(host.releasedWhileHeld == [false])
    }
}

// MARK: Publishers of released presentations

/// A subscriber that asks for one value at a time and records what it receives.
private final class OneAtATime: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var events: [String] = []
    private var subscription: (any Subscription)?
    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(.max(1))
    }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        events.append("value \(input)")
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        events.append("finished")
        subscription = nil
    }
    func request() { subscription?.request(.max(1)) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ReleasedPresentationPublisherTests {
    // A subscriber with demand for one value receives the seed; a newer snapshot shown then waits for
    // demand. The presentation is released, and the subscriber asks for another value before the turn
    // that disposes of the presentation: the release has discarded the waiting snapshot, so the
    // subscriber receives only the completion.
    @Test func demandMadeAfterAPassivePresentationsReleaseReceivesOnlyTheCompletion() async {
        var shown: SnapshotObservableObject<UInt64>? = SnapshotObservableObject(0, revision: { $0 })
        let subscriber = OneAtATime()
        shown?.presentedSnapshots.subscribe(subscriber)
        shown?.apply(1)
        #expect(subscriber.events == ["value 0"])
        shown = nil
        subscriber.request()
        for _ in 0 ..< 3 { await Task.yield() }
        #expect(subscriber.events == ["value 0", "finished"])
    }

    @Test func demandMadeAfterADrivingPresentationsReleaseReceivesOnlyTheCompletion() async {
        let host = CancellingHost()
        var shown: StateMachineObservableObject<CancellingHost>? = StateMachineObservableObject(host)
        let subscriber = OneAtATime()
        shown?.presentedSnapshots(projecting: \.revision).subscribe(subscriber)
        shown?.close()
        #expect(subscriber.events == ["value 0"])
        shown = nil
        subscriber.request()
        for _ in 0 ..< 3 { await Task.yield() }
        #expect(subscriber.events == ["value 0", "finished"])
    }
}

// MARK: Elements per turn

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable {
    let revision: UInt64
}

/// A shared host of the test's own whose snapshot advances on every read, as an owner that changes
/// between a registration and the read that follows it does, and that can deliver a newer snapshot to
/// its registration from every snapshot the presentation shows.
private final class EchoingHost: SharedStateMachineHost, Sendable {
    typealias Snapshot = Mark
    private let state = OSAllocatedUnfairLock(
        initialState: (revision: UInt64(0), receive: (@Sendable (Mark) -> Void)?.none)
    )

    func snapshot() -> Mark {
        state.withLock { state in
            state.revision += 1
            return Mark(revision: state.revision)
        }
    }
    /// Delivers the next revision to the registration.
    func echo() {
        let (next, receive) = state.withLock { state in
            state.revision += 1
            return (Mark(revision: state.revision), state.receive)
        }
        receive?(next)
    }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Mark> {
        try SnapshotSequence<Mark> { [state] receive, _ in
            let seed = state.withLock { state in
                state.receive = receive
                state.revision += 1
                return Mark(revision: state.revision)
            }
            receive(seed)
            return SnapshotSubscription {}
        }
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Mark) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { throw .capacityExceeded }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Mark) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { throw .capacityExceeded }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ElementsPerTurnTests {
    // The presentation observes a shared host of its own whose registration delivers a newer snapshot
    // from every snapshot shown. The registration's seed is older than the host read that follows it,
    // so the host read is shown as the baseline. In the turn that registers, the presentation reads at
    // most 32 of the registration's elements, the seed among them, before it gives up the turn.
    @Test func aRegistrationThatDeliversFromEveryShownSnapshotReadsAtMost32ElementsInOneTurn() async throws {
        let host = EchoingHost()
        let shown = SnapshotObservableObject(Mark(revision: 0))
        let subscription = shown.presentedSnapshots.dropFirst().sink { _ in host.echo() }
        let before = host.snapshot().revision
        try shown.observe(host)
        // The seed, the host read shown as the baseline, and then the echoed elements.
        let read = Int(shown.snapshot.revision - before) - 1
        #expect(read <= 32, "\(read) of the registration's elements read in one turn")
        #expect(read == 32)
        shown.stopObserving()
        subscription.cancel()
    }
}
