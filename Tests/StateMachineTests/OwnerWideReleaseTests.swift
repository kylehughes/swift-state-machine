import Combine
import Dispatch
import StateMachine
import StateMachineExamples
import Testing
import os

// An owner released without closing ends every one of its publishers at one instant: its lifetime
// gate, which they all read, closes before it notifies any of them. Once one publisher of the owner
// has finished for the release, no other publisher of it begins an ordinary delivery, even when the
// releasing thread has not yet notified that publisher.

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

/// A subscriber that requests every value, records what it receives, and raises a signal at its
/// first value and at its completion.
private final class Recorder: Subscriber, Sendable {
    typealias Input = UInt64
    typealias Failure = Never
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    let received = Signal()
    let finished = Signal()
    var events: [String] { log.withLock { $0 } }
    func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        log.withLock { $0.append("value \(input)") }
        received.raise()
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        log.withLock { $0.append("finished") }
        finished.raise()
    }
}

/// Holds the releasing thread after the owner's first release notice until `proceed()`.
private final class FirstNoticeHold: Sendable {
    private let notices = OSAllocatedUnfairLock(initialState: 0)
    private let held = DispatchSemaphore(value: 0)
    let reached = Signal()

    var pause: @Sendable () -> Void {
        { [self] in
            let first = notices.withLock { count -> Bool in
                defer { count += 1 }
                return count == 0
            }
            guard first else { return }
            reached.raise()
            held.wait()
        }
    }
    func proceed() { held.signal() }
}

@MainActor @Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct OwnerWideReleaseTests {
    // Publishers A and B of an idle shared owner each hold their seed, revision 0; A's subscriber has
    // received it, and B's seed has reached B on the main actor. The owner's last reference goes on a
    // worker, which is held after the owner notified A and before it notified B. A finishes on the main
    // actor; a subscriber that attaches to B after that receives only the completion.
    @Test func aSharedOwnersReleaseEndsEveryPublisherAtOnce() async throws {
        let owner = OSAllocatedUnfairLock<GeneratedProfile.Shared?>(
            initialState: GeneratedProfile.Shared(
                .init(userID: try UserID("kyle")),
                fetchDriver: { _ in .failure(.unavailable) },
                auditDriver: { _ in .failure(.unavailable) }
            )
        )
        let handedOff = Signal()
        let (first, second) = try {
            let host = try #require(owner.withLock { $0 })
            let first = try host.snapshotPublisher { $0.revision }
            let second = try HandOffPause.$afterTaking.withValue({ handedOff.raise() }) {
                try host.snapshotPublisher { $0.revision }
            }
            return (first, second)
        }()
        try await expectBothEndTogether(first, second, handedOff: handedOff) {
            withExtendedLifetime(owner.withLock { $0.take() }) {}
        }
    }

    // The same for an actor owner, whose seeds reach the main actor from its own turns.
    @Test func anActorOwnersReleaseEndsEveryPublisherAtOnce() async throws {
        let owner = OSAllocatedUnfairLock<GeneratedProfile.ActorHost?>(
            initialState: GeneratedProfile.ActorHost(
                .init(userID: try UserID("kyle")),
                drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
            )
        )
        let handedOff = Signal()
        let (first, second) = try await publishers(of: owner, handedOff: handedOff)
        try await expectBothEndTogether(first, second, handedOff: handedOff) {
            withExtendedLifetime(owner.withLock { $0.take() }) {}
        }
    }

    /// Registers two publishers with the actor owner, the second of which raises `handedOff` when its
    /// seed reaches the main actor; the owner's only reference stays in `owner`.
    private func publishers(
        of owner: OSAllocatedUnfairLock<GeneratedProfile.ActorHost?>,
        handedOff: Signal
    ) async throws -> (SnapshotPublisher<UInt64>, SnapshotPublisher<UInt64>) {
        let host = try #require(owner.withLock { $0 })
        let first = try await host.snapshotPublisher { $0.revision }
        let second = try await HandOffPause.$afterTaking.withValue({ handedOff.raise() }) {
            try await host.snapshotPublisher { $0.revision }
        }
        return (first, second)
    }

    /// Consumes A's seed, waits for B's seed to reach B, runs `release` on a worker held after the
    /// first notice, lets A finish, and then attaches to B.
    private func expectBothEndTogether(
        _ first: SnapshotPublisher<UInt64>,
        _ second: SnapshotPublisher<UInt64>,
        handedOff: Signal,
        release: @escaping @Sendable () -> Void
    ) async throws {
        let early = Recorder()
        first.subscribe(early)
        await early.received.wait()
        await handedOff.wait()
        #expect(early.events == ["value 0"])
        let hold = FirstNoticeHold()
        let pause = hold.pause
        let worker = Task.detached { ReleaseNoticePause.$afterNotice.withValue(pause) { release() } }
        await hold.reached.wait()
        await early.finished.wait()
        #expect(early.events == ["value 0", "finished"])
        let late = Recorder()
        second.subscribe(late)
        #expect(late.events == ["finished"])
        hold.proceed()
        await worker.value
        await late.finished.wait()
        #expect(late.events == ["finished"])
    }
}
