import Combine
import Observation
import StateMachine
import StateMachineUI
import Testing
import os

// A value accepted while a publication is in progress waits for that publication to show it. When it
// will never be shown, because its observation ended or the task that follows that observation was
// cancelled, it holds back no later value, and the record of which task follows the observation
// belongs to the observation that is current.

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

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

/// An open sequence of the test's own whose elements the test offers.
private final class Feed: Sendable {
    private let receive = Later<@Sendable (Mark) -> Void>()

    func sequence(first: UInt64) throws -> SnapshotSequence<Mark> {
        try SnapshotSequence<Mark> { receive, finish in
            self.receive.fill(receive)
            receive(Mark(revision: first))
            return SnapshotSubscription { withExtendedLifetime((receive, finish)) {} }
        }
    }
    func offer(_ revision: UInt64) { receive.value?(Mark(revision: revision)) }
}

/// A value any thread fills and reads.
private final class Later<Value: Sendable>: Sendable {
    private let stored = OSAllocatedUnfairLock<Value?>(initialState: nil)
    var value: Value? { stored.withLock { $0 } }
    func fill(_ value: Value) { stored.withLock { $0 = value } }
}

/// One passive presentation under test.
@MainActor private struct Shown {
    let apply: @MainActor (UInt64) -> Bool
    let stop: @MainActor () -> Void
    let follow: @MainActor (SnapshotSequence<Mark>) async -> Void
    let followRegistering: @MainActor (@escaping @MainActor () async -> SnapshotSequence<Mark>) async -> Void
    let shown: @MainActor () -> UInt64
    let live: @MainActor () -> Bool
    /// Runs `hook` once, inside the next publication of a snapshot, before the snapshot is assigned.
    let onceWhileShowing: @MainActor (@escaping @MainActor () -> Void) -> AnyObject
    let object: AnyObject

    static func make(_ kind: PresentationClass) -> Shown? {
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(Mark(revision: 0))
            return Shown(
                apply: { made.apply(Mark(revision: $0)) },
                stop: { made.stopObserving() },
                follow: { await made.follow($0) },
                followRegistering: { register in await made.follow(snapshotsFrom: register) },
                shown: { made.snapshot.revision },
                live: { made.isObserving },
                onceWhileShowing: { hook in
                    var pending: (@MainActor () -> Void)? = hook
                    return made.objectWillChange.sink { _ in pending.take()?() }
                },
                object: made
            )
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let made = SnapshotPresentation(Mark(revision: 0))
            return Shown(
                apply: { made.apply(Mark(revision: $0)) },
                stop: { made.stopObserving() },
                follow: { await made.follow($0) },
                followRegistering: { register in await made.follow(snapshotsFrom: register) },
                shown: { made.snapshot.revision },
                live: { made.isObserving },
                onceWhileShowing: { hook in
                    withObservationTracking {
                        _ = made.snapshot
                    } onChange: {
                        MainActor.assumeIsolated { hook() }
                    }
                    return made
                },
                object: made
            )
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DeferredRevisionTests {
    // From the publication of 1, 10 is applied and waits for that publication; the observation then
    // stops, so 10 will never be shown, and 2, applied next in the same callback, is newer than what
    // is shown or being assigned. 2 is applied and shown.
    @Test(arguments: PresentationClass.allCases)
    func aValueAnEndedObservationDeferredHoldsBackNoLaterValue(_ kind: PresentationClass) throws {
        let presentation = try #require(Shown.make(kind))
        var results: [Bool] = []
        let hook = presentation.onceWhileShowing {
            results.append(presentation.apply(10))
            presentation.stop()
            results.append(presentation.apply(2))
        }
        #expect(presentation.apply(1))
        #expect(results == [true, true])
        #expect(presentation.shown() == 2)
        withExtendedLifetime((hook, presentation.object)) {}
    }

    // From the publication of 1, 3 is applied, then 2: 2 is older than what waits, and is refused.
    // The control for the test above: a value that will be shown still holds back an older one.
    @Test(arguments: PresentationClass.allCases)
    func aValueThatWillBeShownStillHoldsBackAnOlderOne(_ kind: PresentationClass) throws {
        let presentation = try #require(Shown.make(kind))
        var results: [Bool] = []
        let hook = presentation.onceWhileShowing {
            results.append(presentation.apply(3))
            results.append(presentation.apply(2))
        }
        #expect(presentation.apply(1))
        #expect(results == [true, false])
        #expect(presentation.shown() == 3)
        withExtendedLifetime((hook, presentation.object)) {}
    }

    // A task follows an open sequence seeded with 1; from the publication of its 2, 5 is applied and
    // the task is cancelled, then 4 is applied. 5 belongs to the cancelled task's observation and is
    // never shown; 4, applied after the cancellation, is newer than what is shown and is shown.
    @Test(arguments: PresentationClass.allCases)
    func aValueAppliedAfterItsFollowerIsCancelledIsShown(_ kind: PresentationClass) async throws {
        let presentation = try #require(Shown.make(kind))
        let feed = Feed()
        let follower = Task { @MainActor in await presentation.follow(try! feed.sequence(first: 1)) }
        await untilLive(presentation)
        var results: [Bool] = []
        let hook = presentation.onceWhileShowing {
            results.append(presentation.apply(5))
            follower.cancel()
            results.append(presentation.apply(4))
        }
        feed.offer(2)
        await follower.value
        #expect(results == [true, true])
        #expect(presentation.shown() == 4)
        withExtendedLifetime((hook, presentation.object)) {}
    }

    // Follower A waits inside its registration closure while follower B follows an open sequence
    // seeded with 1. A's closure then returns, after B replaced it. From the publication of B's 2, 3 is
    // applied and B is cancelled before the callback returns: 3 belongs to B's observation, so it is
    // not shown, and the watermark goes back to 2, so 3 can be applied afterward.
    @Test(arguments: PresentationClass.allCases)
    func anObsoleteFollowerLeavesTheCurrentFollowersCancellationInPlace(_ kind: PresentationClass) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let presentation = try #require(Shown.make(kind))
        let feedA = Feed()
        let feedB = Feed()
        let resumeA = Signal()
        let a = Task.immediate { @MainActor in
            await presentation.followRegistering {
                await resumeA.wait()
                return try! feedA.sequence(first: 7)
            }
        }
        let b = Task.immediate { @MainActor in await presentation.follow(try! feedB.sequence(first: 1)) }
        #expect(presentation.shown() == 1)
        resumeA.raise()
        await a.value
        var applied: Bool?
        let hook = presentation.onceWhileShowing {
            applied = presentation.apply(3)
            b.cancel()
        }
        feedB.offer(2)
        await b.value
        #expect(applied == true)
        #expect(presentation.shown() == 2)
        #expect(presentation.apply(3))
        #expect(presentation.shown() == 3)
        withExtendedLifetime((hook, presentation.object)) {}
    }
}

/// Returns once `presentation` reports a live observation.
@MainActor private func untilLive(_ presentation: Shown) async {
    if let combine = presentation.object as? SnapshotObservableObject<Mark> {
        await untilObserving(combine)
    } else if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *),
        let model = presentation.object as? SnapshotPresentation<Mark>
    {
        await untilObserving(model)
    }
}
