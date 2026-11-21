import Combine
import Dispatch
import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

// An owner released without closing first processes every batch it has accepted, delivering each to
// every registration as usual, and only then tears down: it tells its publishers that it promises
// nothing more, cancels its drivers, and releases its callbacks. A driver that the owner launched and
// that has not started yet does not keep the owner beyond that.

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

/// A subscriber that requests every value, records what it receives on the main actor, and raises
/// `finished` at its completion.
private final class Recorder: Subscriber, Sendable {
    typealias Input = UInt64
    typealias Failure = Never
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    let finished = Signal()
    var events: [String] { log.withLock { $0 } }
    func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        log.withLock { $0.append("value \(input)") }
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        log.withLock { $0.append("finished") }
        finished.raise()
    }
}

/// Holds the driver task of the work that `ticket` names, before its driver runs, until `proceed()`;
/// the task of every other work passes.
///
/// A test binds ``pause`` for the admission that launches the work, so the hold applies to this test's
/// owner alone.
private final class DriverHold: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)
    private let proceeded = OSAllocatedUnfairLock(initialState: false)
    private let held = DispatchSemaphore(value: 0)
    let reached = Signal()

    /// Whether `proceed()` has let the held task go.
    var hasProceeded: Bool { proceeded.withLock { $0 } }

    /// The driver-start pause, which holds the first driver task that runs it.
    var pause: @Sendable (RuntimeTicket) -> Void {
        { [self] _ in
            let first = claimed.withLock { claimed -> Bool in
                defer { claimed = true }
                return !claimed
            }
            guard first else { return }
            reached.raise()
            held.wait()
        }
    }
    func proceed() {
        let first = proceeded.withLock { proceeded -> Bool in
            defer { proceeded = true }
            return !proceeded
        }
        guard first else { return }
        held.signal()
    }
    /// Lets the held task go after `seconds` if the test has not by then, so a failing run ends.
    func proceed(after seconds: Int) -> Task<Void, Never> {
        Task.detached { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { proceed() }
        }
    }
}

@MainActor @Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct ReleaseAfterAcceptanceTests {
    // The main actor runs the drain of the accepted `.load` after the turn that releases the owner's last
    // reference, so the owner is still processing it when a subscriber attaches to a publisher saved
    // before the release. The subscriber receives the publisher's pending snapshot and the accepted
    // change, as it would have with the reference kept, and then the completion of the teardown.
    @Test func aMainActorHostReleasedBeforeItProcessesAnAcceptedChangeDeliversItAndThenFinishes() async throws {
        let user = try UserID("kyle")
        var host: GeneratedProfile.MainActorHost? = GeneratedProfile.MainActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    try? await Task.sleep(for: .seconds(3600))
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        let publisher = try #require(host).snapshotPublisher { $0.revision }
        let accepted = try #require(host).send(.load(ProfileRequest(userID: user))).revision
        weak let released = host
        host = nil
        #expect(released == nil)
        let subscriber = Recorder()
        publisher.subscribe(subscriber)
        #expect(subscriber.events == ["value 0"])
        await subscriber.finished.wait()
        #expect(subscriber.events == ["value 0", "value \(accepted)", "finished"])
    }

    // An actor host launches the fetch driver and is released once it has processed the batch, while
    // the driver's task is held before the driver runs. The owner tears down then: its publisher
    // finishes while that task is still held.
    @Test func anActorHostWithALaunchedDriverNotYetStartedTearsDownOnceItHasProcessedItsBatches() async throws {
        let user = try UserID("kyle")
        let hold = DriverHold()
        // A thrown error returns before the steps that let the held task go.
        defer { hold.proceed() }
        var host: GeneratedProfile.ActorHost?
        let subscriber = Recorder()
        // Every batch of this owner, and so the launch of its one driver, is processed under the pause.
        let receipt = try await DriverStartPause.$beforeStarting.withValue(hold.pause) {
            host = GeneratedProfile.ActorHost(
                .init(userID: user),
                drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
            )
            try await #require(host).snapshotPublisher { $0.revision }.subscribe(subscriber)
            return try await #require(host).send(.load(ProfileRequest(userID: user)))
        }
        await hold.reached.wait()
        _ = try await #require(host).flush(through: receipt)
        let safety = hold.proceed(after: 30)
        host = nil
        await subscriber.finished.wait()
        #expect(!hold.hasProceeded)
        hold.proceed()
        safety.cancel()
        #expect(subscriber.events.last == "finished")
        #expect(subscriber.events.filter { $0 == "finished" }.count == 1)
    }

    // The same for a shared owner, whose coordinator launches the driver on a detached task.
    @Test func aSharedOwnerWithALaunchedDriverNotYetStartedTearsDownOnceItHasProcessedItsBatches() async throws {
        let user = try UserID("kyle")
        let hold = DriverHold()
        // A thrown error returns before the steps that let the held task go.
        defer { hold.proceed() }
        var host: GeneratedProfile.Shared?
        let subscriber = Recorder()
        // Every batch of this owner, and so the launch of its one driver, is processed under the pause.
        let receipt = try DriverStartPause.$beforeStarting.withValue(hold.pause) {
            host = GeneratedProfile.Shared(
                .init(userID: user),
                fetchDriver: { _ in .failure(.unavailable) },
                auditDriver: { _ in .failure(.unavailable) }
            )
            try #require(host).snapshotPublisher { $0.revision }.subscribe(subscriber)
            return try #require(host).send(.load(ProfileRequest(userID: user)))
        }
        await hold.reached.wait()
        _ = try await #require(host).flush(through: receipt)
        let safety = hold.proceed(after: 30)
        host = nil
        await subscriber.finished.wait()
        #expect(!hold.hasProceeded)
        hold.proceed()
        safety.cancel()
        #expect(subscriber.events.last == "finished")
        #expect(subscriber.events.filter { $0 == "finished" }.count == 1)
    }

    // A shared owner hands its first snapshot to the publisher on a main-actor hand-off. The hand-off has
    // taken the value when a subscriber attaches and the owner, which accepted nothing, is released on
    // another thread. The value has not been delivered by then, so the publisher discards it and the
    // subscriber receives only the completion.
    @Test func aSharedOwnersPublisherDiscardsTheValueItsHandOffTookBeforeTheRelease() async throws {
        let user = try UserID("kyle")
        let owner = OSAllocatedUnfairLock<GeneratedProfile.Shared?>(
            initialState: GeneratedProfile.Shared(
                .init(userID: user),
                fetchDriver: { _ in .failure(.unavailable) },
                auditDriver: { _ in .failure(.unavailable) }
            )
        )
        let holder = PublisherHolder()
        let subscriber = Recorder()
        let paused = OSAllocatedUnfairLock(initialState: false)
        let pause: @Sendable () -> Void = {
            guard !paused.withLock({ $0 }) else { return }
            paused.withLock { $0 = true }
            MainActor.assumeIsolated { holder.publisher?.subscribe(subscriber) }
            let dropped = DispatchSemaphore(value: 0)
            runOnOwnThread {
                owner.withLock { $0 = nil }
                dropped.signal()
            }
            dropped.wait()
        }
        try HandOffPause.$afterTaking.withValue(pause) {
            let host = try #require(owner.withLock { $0 })
            holder.publisher = try host.snapshotPublisher { $0.revision }
        }
        await subscriber.finished.wait()
        #expect(paused.withLock { $0 })
        #expect(owner.withLock { $0 == nil })
        #expect(subscriber.events == ["finished"])
    }
}

/// Keeps a publisher on the main actor for a pause to attach to.
@MainActor private final class PublisherHolder: Sendable {
    var publisher: SnapshotPublisher<UInt64>?
}
