import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

// An observation that `follow(_:)` starts belongs to the calling task for as long as it lasts, and every
// wait of that task reads the task's cancellation. An observation is live once its first snapshot is
// shown and published while its registration is open, however many elements still wait in it. A
// registration ends before the values it held are released, so their destructors find the slot free.
// Each test runs for both presentation classes and waits on signals, never on scheduling.

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

/// A sequence of an owner of the test's own, which the test feeds element by element.
private final class Feed<Element: Sendable>: Sendable {
    private let callbacks = OSAllocatedUnfairLock<
        (receive: (@Sendable (Element) -> Void)?, finish: (@Sendable () -> Void)?)
    >(initialState: (nil, nil))
    private let cancellations = OSAllocatedUnfairLock(initialState: 0)

    /// How many times the sequence cancelled its token.
    var cancelled: Int { cancellations.withLock { $0 } }

    /// Registers the sequence, offering `first` before the registration returns.
    func sequence(first: Element) throws -> SnapshotSequence<Element> {
        try SnapshotSequence<Element> { receive, finish in
            callbacks.withLock { $0 = (receive, finish) }
            receive(first)
            return SnapshotSubscription { [cancellations] in cancellations.withLock { $0 += 1 } }
        }
    }
    /// Registers the sequence without offering anything.
    func empty() throws -> SnapshotSequence<Element> {
        try SnapshotSequence<Element> { receive, finish in
            callbacks.withLock { $0 = (receive, finish) }
            return SnapshotSubscription { [cancellations] in cancellations.withLock { $0 += 1 } }
        }
    }
    func offer(_ element: Element) { callbacks.withLock { $0.receive }?(element) }
    func finish() { callbacks.withLock { $0.finish }?() }
}

/// A presentation of either class, for any `Sendable` snapshot, through the members these tests use.
@MainActor private struct Subject<Shown: Sendable> {
    private let combine: SnapshotObservableObject<Shown>?
    // A `SnapshotPresentation<Shown>`, where that class is available.
    private let observation: AnyObject?

    /// Creates a presentation of `kind`, or `nil` where that class is unavailable.
    init?(_ kind: PresentationClass, _ initial: Shown, revision: @escaping @MainActor (Shown) -> UInt64) {
        switch kind {
        case .combine:
            combine = SnapshotObservableObject(initial, revision: revision)
            observation = nil
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            combine = nil
            observation = SnapshotPresentation(initial, revision: revision)
        }
    }

    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private var model: SnapshotPresentation<Shown> {
        guard let model = observation as? SnapshotPresentation<Shown> else { preconditionFailure("no model") }
        return model
    }
    /// Runs `combined` on the Combine class or `observed` on the Observation class.
    var snapshot: Shown {
        if let combine { return combine.snapshot }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        return model.snapshot
    }
    var isObserving: Bool {
        if let combine { return combine.isObserving }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        return model.isObserving
    }
    @discardableResult func apply(_ next: Shown) -> Bool {
        if let combine { return combine.apply(next) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        return model.apply(next)
    }
    func observe(_ snapshots: SnapshotSequence<Shown>) {
        if let combine { return combine.observe(snapshots) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        model.observe(snapshots)
    }
    func observe<Host: MainActorStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Shown {
        if let combine { return try combine.observe(host) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        try model.observe(host)
    }
    func observe<Host: IsolatedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Owner == MainActor, Host.Snapshot == Shown {
        if let combine { return try combine.observe(host) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        try model.observe(host)
    }
    func follow(_ snapshots: SnapshotSequence<Shown>) async {
        if let combine { return await combine.follow(snapshots) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        await model.follow(snapshots)
    }
    func follow(snapshotsFrom register: @MainActor () async throws -> SnapshotSequence<Shown>) async throws {
        if let combine { return try await combine.follow(snapshotsFrom: register) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        try await model.follow(snapshotsFrom: register)
    }
    func stopObserving() {
        if let combine { return combine.stopObserving() }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        model.stopObserving()
    }
    /// Runs `hook` inside each snapshot publication's callback until the returned token is released.
    func onShow(_ hook: @escaping @MainActor () -> Void) -> AnyObject {
        if let combine { return combine.presentedSnapshots.dropFirst().sink { _ in hook() } }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        let installed = ShowHook()
        installed.hook = hook
        track(model, installed)
        return installed
    }
    /// Runs `hook` with each new value of `isObserving` as it is assigned, until the returned token is
    /// released.
    func onLive(_ hook: @escaping @MainActor (Bool) -> Void) -> AnyObject {
        if let combine { return combine.$isObserving.dropFirst().sink { live in hook(live) } }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        let installed = LiveHook()
        installed.hook = hook
        track(model, installed)
        return installed
    }
    // Observation reports a change before it is made, and `isObserving` changes only when it toggles.
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private func track(_ model: SnapshotPresentation<Shown>, _ installed: LiveHook) {
        withObservationTracking {
            _ = model.isObserving
        } onChange: { [weak model, weak installed] in
            MainActor.assumeIsolated {
                guard let model, let installed else { return }
                let live = !model.isObserving
                installed.hook?(live)
                track(model, installed)
            }
        }
    }
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private func track(_ model: SnapshotPresentation<Shown>, _ installed: ShowHook) {
        withObservationTracking {
            _ = model.snapshot
        } onChange: { [weak model, weak installed] in
            MainActor.assumeIsolated {
                guard let model, let installed else { return }
                track(model, installed)
                installed.hook?()
            }
        }
    }
    /// Returns once the presentation reports a live observation.
    func untilLive() async {
        if let combine { return await untilObserving(combine) }
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { preconditionFailure() }
        await untilObserving(model)
    }
}

/// Keeps an Observation hook installed while it lives.
@MainActor private final class ShowHook {
    var hook: (@MainActor () -> Void)?
}

/// Keeps an Observation hook of `isObserving` installed while it lives.
@MainActor private final class LiveHook {
    var hook: (@MainActor (Bool) -> Void)?
}

/// Names the task a snapshot callback runs on.
private enum Role {
    @TaskLocal static var name = "caller"
}

/// Runs `body` with a presentation of `kind`, where that class is available.
@MainActor private func with<Shown: Sendable>(
    _ kind: PresentationClass,
    _ initial: Shown,
    revision: @escaping @MainActor (Shown) -> UInt64,
    _ body: (Subject<Shown>) async throws -> Void
) async rethrows {
    guard let subject = Subject(kind, initial, revision: revision) else { return }
    try await body(subject)
}

/// A box a closure created before its value fills.
@MainActor private final class Later<Value> {
    var value: Value?
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationTaskOwnershipTests {
    // While `follow(snapshotsFrom:)` is still registering, cancelling the follower inside a
    // publication callback withdraws a deferred `apply` queued before the cancellation, while the
    // already-announced value finishes and an `apply` accepted after cancellation remains eligible.
    @Test(arguments: PresentationClass.allCases, [false, true])
    func cancellingDuringRegistrationWithdrawsOnlyEarlierDeferredApplies(
        _ kind: PresentationClass,
        applyAfterCancellation: Bool
    ) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let registering = Signal()
            let resume = Signal()
            let feed = Feed<Int>()
            let follower = Task { @MainActor in
                try await presentation.follow(snapshotsFrom: {
                    registering.raise()
                    await resume.wait()
                    return try feed.sequence(first: 30)
                })
            }
            await registering.wait()
            var publications = 0
            let hook = presentation.onShow {
                publications += 1
                guard publications == 1 else { return }
                #expect(presentation.apply(20))
                follower.cancel()
                if applyAfterCancellation { #expect(presentation.apply(15)) }
            }
            #expect(presentation.apply(10))
            #expect(presentation.snapshot == (applyAfterCancellation ? 15 : 10))
            #expect(publications == (applyAfterCancellation ? 2 : 1))
            resume.raise()
            try await follower.value
            #expect(feed.cancelled == 1)
            #expect(!presentation.isObserving)
            #expect(presentation.apply(16))
            withExtendedLifetime(hook) {}
        }
    }

    // When a newer `follow(snapshotsFrom:)` replaces an earlier one that is still registering, the
    // replaced follower's exit does not clear the replacement follower's cancellation record.
    @Test(arguments: PresentationClass.allCases)
    func aReplacedFollowReturningKeepsTheNewFollowersCancellation(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let oldFeed = Feed<Int>()
            let newFeed = Feed<Int>()
            let oldRegistering = Signal()
            let newRegistering = Signal()
            let finishOld = Signal()
            let finishNew = Signal()
            let old = Task { @MainActor in
                try await presentation.follow(snapshotsFrom: {
                    oldRegistering.raise()
                    await finishOld.wait()
                    return try oldFeed.sequence(first: 30)
                })
            }
            await oldRegistering.wait()
            let replacement = Task.immediate { @MainActor in
                try await presentation.follow(snapshotsFrom: {
                    newRegistering.raise()
                    await finishNew.wait()
                    return try newFeed.sequence(first: 40)
                })
            }
            finishOld.raise()
            try await old.value
            #expect(oldFeed.cancelled == 1)
            await newRegistering.wait()
            var first = true
            let hook = presentation.onShow {
                guard first else { return }
                first = false
                #expect(presentation.apply(20))
                replacement.cancel()
            }
            #expect(presentation.apply(10))
            #expect(presentation.snapshot == 10)
            finishNew.raise()
            try await replacement.value
            #expect(newFeed.cancelled == 1)
            withExtendedLifetime(hook) {}
        }
    }

    // When `follow(snapshotsFrom:)` throws during registration, its exit clears its cancellation
    // record so cancelling that caller later does not withdraw subsequent deferred applies.
    @Test(arguments: PresentationClass.allCases)
    func aRefusedFollowReleasesItsClaimOnSubsequentApplies(_ kind: PresentationClass) async {
        await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let refused = Signal()
            let resume = Signal()
            let caller = Task { @MainActor in
                await #expect(throws: SubscriptionFailure.capacityExceeded) {
                    try await presentation.follow(snapshotsFrom: { throw SubscriptionFailure.capacityExceeded })
                }
                refused.raise()
                await resume.wait()
            }
            await refused.wait()
            var first = true
            let hook = presentation.onShow {
                guard first else { return }
                first = false
                #expect(presentation.apply(20))
                caller.cancel()
            }
            #expect(presentation.apply(10))
            #expect(presentation.snapshot == 20)
            resume.raise()
            await caller.value
            withExtendedLifetime(hook) {}
        }
    }

    // A snapshot callback starts `follow(_:)` on a task that runs at once, inside the publication.
    // The followed sequence's first snapshot is published only after that callback returns, so the
    // observation decides liveness then; `follow` keeps running on the calling task until the task is
    // cancelled, and its cancellation ends the observation and releases the registration.
    @Test(arguments: PresentationClass.allCases)
    func aFollowStartedInsideASnapshotCallbackBelongsToItsTask(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var returned = false
            let ended = Signal()
            let sequence = try feed.sequence(first: 2)
            let hook = presentation.onShow {
                guard follower.value == nil else { return }
                follower.value = Task.immediate { @MainActor in
                    await presentation.follow(sequence)
                    returned = true
                    ended.raise()
                }
            }
            presentation.apply(1)
            #expect(!returned)
            #expect(presentation.snapshot == 2)
            #expect(presentation.isObserving)
            follower.value?.cancel()
            await ended.wait()
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime(hook) {}
        }
    }

    // Task A shows snapshot 1, and its callback starts task B, which follows a sequence holding 2. B
    // shows 2 inside A's publication and waits for it to end; showing 2 offers 3. The end of A's
    // publication decides B's liveness, with no callout between the cancellation check and the report,
    // and leaves the rest to B: B applies 3, whose callback cancels B and offers 4, and B then ends the
    // observation without showing 4.
    @Test(arguments: PresentationClass.allCases)
    func aDeferredFollowDecidesItsLivenessBeforeItsTaskAppliesMore(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var log: [String] = []
            let sequence = try feed.sequence(first: 2)
            let live = presentation.onLive { log.append("live \($0)") }
            // A callback runs before its snapshot is assigned, and these snapshots are consecutive.
            let hook = presentation.onShow {
                let shown = presentation.snapshot + 1
                log.append("show \(shown) on \(Role.name)")
                switch shown {
                case 1:
                    follower.value = Task.immediate { @MainActor in
                        await Role.$name.withValue("follower") { await presentation.follow(sequence) }
                    }
                case 2: feed.offer(3)
                case 3:
                    follower.value?.cancel()
                    feed.offer(4)
                default: break
                }
            }
            presentation.apply(1)
            await follower.value?.value
            #expect(
                log == [
                    "show 1 on caller", "show 2 on caller", "live true", "show 3 on follower", "live false",
                ]
            )
            #expect(feed.cancelled == 1)
            withExtendedLifetime((hook, live)) {}
        }
    }

    // Task A shows snapshot 1, and its callback starts task B, which follows a sequence holding 2 and
    // waits for A's publication to end. The callback that shows 2, still inside A's publication,
    // cancels B. The cancellation is recorded where it happens, so the end of the publication reports
    // nothing, and B ends the observation.
    @Test(arguments: PresentationClass.allCases)
    func aDeferredFollowCancelledDuringThePublicationIsNeverLive(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var log: [String] = []
            let sequence = try feed.sequence(first: 2)
            let live = presentation.onLive { log.append("live \($0)") }
            // A callback runs before its snapshot is assigned, and these snapshots are consecutive.
            let hook = presentation.onShow {
                let shown = presentation.snapshot + 1
                log.append("show \(shown)")
                if shown == 1 {
                    follower.value = Task.immediate { @MainActor in await presentation.follow(sequence) }
                }
                if shown == 2 { follower.value?.cancel() }
            }
            presentation.apply(1)
            await follower.value?.value
            #expect(log == ["show 1", "show 2"])
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime((hook, live)) {}
        }
    }

    // The report that the follow is live runs a callback that cancels the task. The decision came first,
    // so the observation was live, and the task ends it at its next wait without showing more.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledByItsLivenessReportEndsAtItsNextWait(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var log: [String] = []
            let live = presentation.onLive { now in
                log.append("live \(now)")
                if now {
                    follower.value?.cancel()
                    feed.offer(2)
                }
            }
            let hook = presentation.onShow { log.append("show \(presentation.snapshot + 1)") }
            let sequence = try feed.sequence(first: 1)
            let start = Signal()
            follower.value = Task { @MainActor in
                await start.wait()
                await presentation.follow(sequence)
            }
            start.raise()
            await follower.value?.value
            #expect(log == ["show 1", "live true", "live false"])
            #expect(feed.cancelled == 1)
            withExtendedLifetime((hook, live)) {}
        }
    }

    // A follow whose sequence has delivered nothing yet reads its first element on its task. That
    // element's callback cancels the task, which then ends the observation without reporting it live.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledByALaterFirstSnapshotIsNeverLive(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var log: [String] = []
            let live = presentation.onLive { log.append("live \($0)") }
            let hook = presentation.onShow {
                log.append("show \(presentation.snapshot + 1)")
                follower.value?.cancel()
            }
            let sequence = try feed.empty()
            let waiting = Signal()
            follower.value = Task { @MainActor in
                waiting.raise()
                await presentation.follow(sequence)
            }
            await waiting.wait()
            feed.offer(1)
            await follower.value?.value
            #expect(log == ["show 1"])
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime((hook, live)) {}
        }
    }

    // A follow whose first snapshot's callback cancels its task decides nothing: the task ends the
    // observation without reporting it live.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledByItsFirstSnapshotIsNeverLive(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var log: [String] = []
            let live = presentation.onLive { log.append("live \($0)") }
            // A callback runs before its snapshot is assigned.
            let hook = presentation.onShow {
                log.append("show \(presentation.snapshot + 1)")
                follower.value?.cancel()
            }
            let sequence = try feed.sequence(first: 1)
            let start = Signal()
            follower.value = Task { @MainActor in
                await start.wait()
                await presentation.follow(sequence)
            }
            start.raise()
            await follower.value?.value
            #expect(log == ["show 1"])
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime((hook, live)) {}
        }
    }

    // A follow applies the elements that wait in its sequence before it decides. The callback of the
    // second cancels the task and offers a third, which the observation never shows, and it is never
    // reported live.
    @Test(arguments: PresentationClass.allCases)
    func aFollowCancelledWhileApplyingWaitingElementsShowsNoMore(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var log: [String] = []
            let live = presentation.onLive { log.append("live \($0)") }
            // A callback runs before its snapshot is assigned, and these snapshots are consecutive.
            let hook = presentation.onShow {
                let shown = presentation.snapshot + 1
                log.append("show \(shown)")
                if shown == 1 { feed.offer(2) }
                if shown == 2 {
                    follower.value?.cancel()
                    feed.offer(3)
                }
            }
            let sequence = try feed.sequence(first: 1)
            let start = Signal()
            follower.value = Task { @MainActor in
                await start.wait()
                await presentation.follow(sequence)
            }
            start.raise()
            await follower.value?.value
            #expect(log == ["show 1", "show 2"])
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime((hook, live)) {}
        }
    }

    // Each snapshot shown makes the followed sequence deliver the next one, without end. Cancelling the
    // task at the fiftieth ends the observation at its next wait, so nothing more is shown.
    @Test(arguments: PresentationClass.allCases)
    func cancellingAFollowEndsItWhileItsSequenceDeliversWithoutPause(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            let follower = Later<Task<Void, Never>>()
            var shown = 0
            let hook = presentation.onShow {
                shown += 1
                if shown == 50 { follower.value?.cancel() }
                if shown < 100_000 { feed.offer(shown + 1) }
            }
            let sequence = try feed.sequence(first: 1)
            follower.value = Task { @MainActor in await presentation.follow(sequence) }
            await follower.value?.value
            #expect(shown == 50)
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime(hook) {}
        }
    }

    // A sequence that delivers again from each snapshot shown always holds an element. Its observation
    // shows at most 32 elements, the first among them, before `observe` returns, and is live from then
    // on, while later turns keep applying the rest.
    @Test(arguments: PresentationClass.allCases)
    func aSequenceThatAlwaysHoldsAnElementIsLiveAfterItsFirstTurn(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            var shown = 0
            let reached = Signal()
            let hook = presentation.onShow {
                shown += 1
                if shown == 200 { reached.raise() }
                feed.offer(shown + 1)
            }
            presentation.observe(try feed.sequence(first: 1))
            #expect(shown <= 32)
            #expect(presentation.isObserving)
            await reached.wait()
            #expect(presentation.isObserving)
            presentation.stopObserving()
            #expect(!presentation.isObserving)
            #expect(feed.cancelled == 1)
            withExtendedLifetime(hook) {}
        }
    }

    // The owner finishes while its final element waits behind a full turn's elements. A registration that
    // has finished is not open, so the observation is not live; the next turn applies the final element
    // and ends it without reporting an observation.
    @Test(arguments: PresentationClass.allCases)
    func aSequenceThatFinishesBehindAFullTurnIsNeverLive(_ kind: PresentationClass) async throws {
        try await with(kind, 0, revision: { UInt64($0) }) { presentation in
            let feed = Feed<Int>()
            var shown = 0
            let last = Signal()
            let hook = presentation.onShow {
                shown += 1
                if shown < 32 { feed.offer(shown + 1) }
                if shown == 32 {
                    feed.offer(33)
                    feed.finish()
                }
                if shown == 33 { last.raise() }
            }
            presentation.observe(try feed.sequence(first: 1))
            #expect(shown == 32)
            #expect(!presentation.isObserving)
            await last.wait()
            #expect(presentation.snapshot == 33)
            #expect(!presentation.isObserving)
            withExtendedLifetime(hook) {}
        }
    }

    // A one-slot `MainActor` host of the test's own frees its slot when its subscription is cancelled. The
    // owner delivers two snapshots in one turn while the presentation's reader waits: the first is handed to
    // the reader, the second waits unread, and the owner's delivery of it stops the presentation. The unread
    // projection is released only once the registration is removed, so its destructor registers again.
    @Test(arguments: PresentationClass.allCases)
    func stoppingReleasesAnUnreadProjectionOnceTheSlotIsFree(_ kind: PresentationClass) async throws {
        try await with(kind, Projection(0), revision: { $0.revision }) { presentation in
            let host = try OneSlotHost()
            let outcome = OutcomeBox()
            try presentation.observe(
                host.snapshots { snapshot in
                    let projection = Projection(snapshot.revision)
                    if snapshot.revision == 2 { projection.onRelease { outcome.registerAgain(with: host) } }
                    return projection
                }
            )
            await presentation.untilLive()
            let stopped = Signal()
            host.afterReceive = { revision in
                guard revision == 2 else { return }
                presentation.stopObserving()
                stopped.raise()
            }
            try host.send(.goOffline)
            try host.send(.goOnline)
            await stopped.wait()
            #expect(outcome.result == .registered)
            #expect(host.registrations == 0)
        }
    }

    // A `MainActor` host of the test's own frees its only slot when its subscription is cancelled. The
    // owner closes, and the observation that its finish ends cancels that subscription before it
    // reports that it stopped, so the slot is free once the finish has returned.
    @Test(arguments: PresentationClass.allCases)
    func aFinishedObservationFreesTheOnlySlotOfAHostOfYourOwn(_ kind: PresentationClass) async throws {
        let host = try OneSlotHost()
        try await with(kind, host.snapshot(), revision: { $0.revision }) { presentation in
            try presentation.observe(host)
            #expect(presentation.isObserving)
            #expect(host.registrations == 1)
            let finished = Signal()
            var observedAtFinish: (live: Bool, registrations: Int)?
            host.afterFinish = {
                observedAtFinish = (presentation.isObserving, host.registrations)
                finished.raise()
            }
            _ = host.close()
            await finished.wait()
            #expect(observedAtFinish?.live == false)
            #expect(observedAtFinish?.registrations == 0)
            try host.subscribe({ _ in }, onFinish: {}).cancel()
        }
    }

    // The same for a host of the test's own confined to the main actor, whose token removes the
    // registration in its `onCancel` and does nothing when it is only released.
    @Test(arguments: PresentationClass.allCases)
    func aFinishedObservationFreesTheOnlySlotOfAnIsolatedHostOfYourOwn(_ kind: PresentationClass) async throws {
        let host = try OneSlotIsolatedHost(isolation: MainActor.shared)
        try await with(kind, host.snapshot(isolation: MainActor.shared), revision: { $0.revision }) { presentation in
            try presentation.observe(host)
            #expect(presentation.isObserving)
            #expect(host.registrations == 1)
            let finished = Signal()
            var observedAtFinish: (live: Bool, registrations: Int)?
            host.afterFinish = {
                observedAtFinish = (presentation.isObserving, host.registrations)
                finished.raise()
            }
            host.close(isolation: MainActor.shared)
            await finished.wait()
            #expect(observedAtFinish?.live == false)
            #expect(observedAtFinish?.registrations == 0)
        }
    }

    // A host of the test's own that has already closed delivers its closed snapshot and finish inside
    // its registration call. The presentation cancels that registration as soon as it installs it, so
    // the slot is free when `observe` returns, and the observation is never live.
    @Test(arguments: PresentationClass.allCases)
    func observingAClosedHostOfYourOwnLeavesItsOnlySlotFree(_ kind: PresentationClass) async throws {
        let host = try OneSlotHost()
        _ = host.close()
        try await with(kind, host.snapshot(), revision: { $0.revision }) { presentation in
            try presentation.observe(host)
            #expect(host.registrations == 0)
            #expect(!presentation.isObserving)
            try host.subscribe({ _ in }, onFinish: {}).cancel()
        }
    }

    // The report that the finished observation stopped runs a callback that observes the same one-slot
    // host again, which finds the slot free.
    @Test(arguments: PresentationClass.allCases)
    func aCallbackOfTheFinishsReportObservesTheSameHostAgain(_ kind: PresentationClass) async throws {
        let host = try OneSlotHost()
        try await with(kind, host.snapshot(), revision: { $0.revision }) { presentation in
            try presentation.observe(host)
            var outcome: Result<Void, SubscriptionFailure>?
            let live = presentation.onLive { now in
                guard !now, outcome == nil else { return }
                do throws(SubscriptionFailure) {
                    try presentation.observe(host)
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
            }
            let finished = Signal()
            host.afterFinish = { finished.raise() }
            _ = host.close()
            await finished.wait()
            #expect(outcome.map { (try? $0.get()) != nil } == true)
            #expect(host.registrations == 0)
            withExtendedLifetime(live) {}
        }
    }

    // The observation's finish cancels the ended subscription, and that cancellation starts another
    // observation. The newer observation owns the presentation, so the finish reports nothing more.
    @Test(arguments: PresentationClass.allCases)
    func aFinishWhoseCancellationStartsAnotherObservationLeavesItLive(_ kind: PresentationClass) async throws {
        let host = try OneSlotHost()
        let other = try OneSlotHost()
        try await with(kind, host.snapshot(), revision: { $0.revision }) { presentation in
            try presentation.observe(host)
            let finished = Signal()
            host.onCancel = {
                host.onCancel = nil
                try? presentation.observe(other)
            }
            host.afterFinish = { finished.raise() }
            _ = host.close()
            await finished.wait()
            #expect(host.registrations == 0)
            #expect(other.registrations == 1)
            #expect(presentation.isObserving)
            presentation.stopObserving()
            #expect(other.registrations == 0)
        }
    }

    // A stop inside the owner's registration call replaces the observation whose attempt holds the seed
    // the owner already delivered. The attempt's registration is cancelled before that seed is released,
    // so the seed's destructor registers again.
    @Test(arguments: PresentationClass.allCases)
    func aReplacedAttemptReleasesItsSeedOnceItsSlotIsFree(_ kind: PresentationClass) async throws {
        try await with(kind, Reference(0), revision: { $0.revision }) { presentation in
            let host = ReferenceHost()
            let outcome = OutcomeBox()
            host.seed = {
                let seed = Reference(1)
                seed.onRelease { outcome.subscribeAgain(to: host) }
                return seed
            }
            host.duringRegistration = { presentation.stopObserving() }
            try presentation.observe(host)
            #expect(outcome.result == .registered)
            #expect(host.registrations == 0)
            #expect(!presentation.isObserving)
        }
    }
}

// MARK: Owners and values whose release a test observes

/// A projected snapshot whose destructor runs a hook on the main actor, where the presentation and the
/// sequence release it.
private final class Projection: Sendable {
    let revision: UInt64
    private let hook = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(initialState: nil)

    init(_ revision: UInt64) { self.revision = revision }
    func onRelease(_ hook: @escaping @MainActor @Sendable () -> Void) { self.hook.withLock { $0 = hook } }
    deinit {
        guard let hook = hook.withLock({ $0 }) else { return }
        MainActor.assumeIsolated { hook() }
    }
}

/// What a destructor's second registration did.
private enum Outcome: Equatable {
    case none, registered, refused
}

@MainActor private final class OutcomeBox {
    private(set) var result = Outcome.none

    func registerAgain(with host: OneSlotHost) {
        do {
            try host.snapshots { $0.revision }.cancel()
            result = .registered
        } catch {
            result = .refused
        }
    }
    func subscribeAgain(to host: ReferenceHost) {
        do {
            try host.subscribe({ _ in }, onFinish: {}).cancel()
            result = .registered
        } catch {
            result = .refused
        }
    }
}

/// A `MainActor` host of the test's own with one subscriber slot.
///
/// It frees the slot when the subscription it returned is cancelled. Its snapshot sequences are the
/// protocol's default projection. A hook runs after each delivery.
@MainActor private final class OneSlotHost: MainActorStateMachineHost {
    typealias Inner = GeneratedTransfers.MainActorHost
    private let inner: Inner
    private(set) var registrations = 0
    var afterReceive: ((UInt64) -> Void)?
    /// Runs after each registration's finish callback has returned.
    var afterFinish: (() -> Void)?
    /// Runs inside the cancellation of a subscription, once its slot is free.
    var onCancel: (() -> Void)?

    init() throws {
        inner = GeneratedTransfers.MainActorHost(
            downloadDriver: { _, _ in .success("") },
            onLogged: { _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 8)
        )
    }

    func snapshot() -> Inner.Snapshot { inner.snapshot() }
    @discardableResult func send(_ input: Inner.Input) throws(Inner.SendRejection) -> Inner.Receipt {
        try inner.send(input)
    }
    func commit(_ prepared: consuming Inner.Prepared) -> Inner.CommitResult { inner.commit(prepared) }
    func subscribe(
        _ receive: @escaping @MainActor (Inner.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        let token = try inner.subscribe(
            { [weak self] snapshot in
                receive(snapshot)
                self?.afterReceive?(snapshot.revision)
            },
            onFinish: { [weak self] in
                onFinish()
                self?.afterFinish?()
            }
        )
        registrations += 1
        return MainActorSnapshotSubscription { [weak self] in
            self?.registrations -= 1
            token.cancel()
            self?.onCancel?()
        }
    }
    func close() -> Inner.Receipt { inner.close() }
}

/// A host of the test's own confined to `Owner`, with one subscriber slot that its token frees in
/// `onCancel`; releasing the token without cancelling it frees nothing.
private final class OneSlotIsolatedHost<Owner: Actor>: IsolatedStateMachineHost {
    typealias Inner = GeneratedTransfers.IsolatedHost<Owner>
    private let inner: Inner
    private var held: IsolatedSnapshotSubscription<Owner>?
    private(set) var registrations = 0
    /// Runs after each registration's finish callback has returned.
    var afterFinish: (() -> Void)?

    init(isolation: isolated Owner) throws {
        inner = GeneratedTransfers.IsolatedHost(
            isolation: isolation,
            downloadDriver: { _, _, _ in .success("") },
            onLogged: { _, _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 8)
        )
    }

    func snapshot(isolation: isolated Owner) -> Inner.Snapshot { inner.snapshot(isolation: isolation) }
    func subscribe(
        _ receive: @escaping (Inner.Snapshot) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Owner> {
        guard registrations == 0 else { throw .capacityExceeded }
        held = try inner.subscribe(
            receive,
            onFinish: { [weak self] in
                onFinish()
                self?.afterFinish?()
            },
            isolation: isolation
        )
        registrations += 1
        return IsolatedSnapshotSubscription(isolation: isolation) { [weak self] in
            self?.registrations -= 1
            // Releasing the inner token ends the inner registration.
            self?.held = nil
        }
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (Inner.Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.snapshots(transform, isolation: isolation)
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (Inner.Snapshot) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try inner.distinctSnapshots(transform, isolation: isolation)
    }
    func close(isolation: isolated Owner) { _ = inner.close(isolation: isolation) }
}

/// A snapshot whose destructor runs a hook on the main actor.
private final class Reference: StateMachineSnapshot, Sendable {
    let revision: UInt64
    private let hook = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(initialState: nil)

    init(_ revision: UInt64) { self.revision = revision }
    func onRelease(_ hook: @escaping @MainActor @Sendable () -> Void) { self.hook.withLock { $0 = hook } }
    deinit {
        guard let hook = hook.withLock({ $0 }) else { return }
        MainActor.assumeIsolated { hook() }
    }
}

/// A `MainActor` host of the test's own with one subscriber slot, whose registration delivers a seed
/// before it returns and then runs a hook, once.
@MainActor private final class ReferenceHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Reference
    struct Receipt: StateMachineReceipt {
        let snapshot: Reference
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private(set) var registrations = 0
    var seed: () -> Reference = { Reference(1) }
    var duringRegistration: (() -> Void)?

    func snapshot() -> Reference { Reference(0) }
    func send(_ input: Never) throws(Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Reference) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        registrations += 1
        receive(seed())
        let hook = duringRegistration
        duringRegistration = nil
        hook?()
        return MainActorSnapshotSubscription { [weak self] in self?.registrations -= 1 }
    }
    func close() -> Receipt { Receipt(snapshot: Reference(0)) }
}
