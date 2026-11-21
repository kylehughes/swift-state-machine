import Combine
import Dispatch
import StateMachine
import StateMachineTestSupport
import Testing

// A shared owner delivers to a publisher on a task of the registration's own, which can still be
// projecting a snapshot when the owner is released. These tests hold that projection on a semaphore,
// so they park a cooperative thread until their own body releases it.

private typealias Engine = RuntimeState<Int, Int>
private typealias SharedHost = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>

private func makeSharedHost() throws -> SharedHost {
    SharedHost(
        manual: 0,
        scopes: [],
        limits: try Limits(),
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

extension RuntimeSharedHost where Model == Int, Descriptor == Int {
    fileprivate func advance() throws { _ = commit(try Engine.prepare(on: snapshot(), next: snapshot().model + 1)) }
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

/// A subscriber that requests every value at once and records what it receives.
@MainActor private final class Unlimited: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var received: [UInt64] = []
    private(set) var completions = 0
    private let completed: Signal
    init(_ completed: Signal) { self.completed = completed }
    nonisolated func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    nonisolated func receive(_ input: UInt64) -> Subscribers.Demand {
        MainActor.assumeIsolated { received.append(input) }
        return .none
    }
    nonisolated func receive(completion: Subscribers.Completion<Never>) {
        MainActor.assumeIsolated {
            completions += 1
            completed.raise()
        }
    }
}

@MainActor @Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct PublisherInFlightReleaseTests {
    // Revision 0 waits in the publisher for demand while revision 1 is being projected. The owner is
    // then released. Demand first made afterward finds nothing promised: the subscriber finishes
    // without a value, before the projection returns.
    @Test func demandAfterReleaseDuringADeliveryFinishesWithoutAValue() async throws {
        var owner: SharedHost? = try makeSharedHost()
        let projectedFirst = Signal()
        let reachedSecond = Signal()
        let hold = ThreadGate()
        // A thrown error returns before the step that lets the held callback go.
        defer { hold.open() }
        let publisher = try #require(owner)
            .snapshotPublisher { snapshot -> UInt64 in
                if snapshot.revision == 0 { projectedFirst.raise() }
                if snapshot.revision == 1 {
                    reachedSecond.raise()
                    hold.wait()
                }
                return snapshot.revision
            }
        let controlFinished = Signal()
        let control = try #require(owner).subscribe({ _ in }, onFinish: { controlFinished.raise() })
        await projectedFirst.wait()
        try #require(owner).advance()
        // Revision 0's hand-off to the main actor was queued before the projection of revision 1 began,
        // and the main actor runs its jobs in order, so revision 0 is pending in the publisher now.
        await reachedSecond.wait()
        owner = nil
        // The other registration's finish follows the release of the owner's state, which held both.
        await controlFinished.wait()
        let completed = Signal()
        let subscriber = Unlimited(completed)
        publisher.subscribe(subscriber)
        let deliveredAtOnce = subscriber.received
        #expect(deliveredAtOnce.isEmpty)
        // A failing run delivered the stale value; releasing the projection lets it end.
        if !deliveredAtOnce.isEmpty { hold.open() }
        await completed.wait()
        #expect(subscriber.received.isEmpty)
        #expect(subscriber.completions == 1)
        if deliveredAtOnce.isEmpty { hold.open() }
        withExtendedLifetime(control) {}
    }

    // Closing promised the closed snapshot while it was being projected, so releasing the owner then
    // keeps it for demand.
    @Test func releaseDuringTheClosedSnapshotsProjectionKeepsIt() async throws {
        var owner: SharedHost? = try makeSharedHost()
        let reachedClosed = Signal()
        let hold = ThreadGate()
        // A thrown error returns before the step that lets the held callback go.
        defer { hold.open() }
        let publisher = try #require(owner)
            .snapshotPublisher { snapshot -> UInt64 in
                if snapshot.isClosed {
                    reachedClosed.raise()
                    hold.wait()
                }
                return snapshot.revision
            }
        let closed = try #require(owner).close()
        await reachedClosed.wait()
        owner = nil
        let completed = Signal()
        let subscriber = Unlimited(completed)
        publisher.subscribe(subscriber)
        #expect(subscriber.completions == 0)
        hold.open()
        await completed.wait()
        #expect(subscriber.received.last == closed.revision)
        #expect(subscriber.completions == 1)
    }

    // The closed snapshot is still waiting behind a delivery in progress when the owner is released;
    // closing promised it, so it is delivered, and then the publisher finishes.
    @Test func releaseWithTheClosedSnapshotPendingKeepsIt() async throws {
        var owner: SharedHost? = try makeSharedHost()
        let reachedFirst = Signal()
        let hold = ThreadGate()
        // A thrown error returns before the step that lets the held callback go.
        defer { hold.open() }
        let publisher = try #require(owner)
            .snapshotPublisher { snapshot -> UInt64 in
                if snapshot.revision == 0 {
                    reachedFirst.raise()
                    hold.wait()
                }
                return snapshot.revision
            }
        await reachedFirst.wait()
        let closed = try #require(owner).close()
        owner = nil
        let completed = Signal()
        let subscriber = Unlimited(completed)
        publisher.subscribe(subscriber)
        #expect(subscriber.completions == 0)
        hold.open()
        await completed.wait()
        #expect(subscriber.received.last == closed.revision)
        #expect(subscriber.completions == 1)
    }

    // A callback registration of an owner released during a delivery finishes once, after that
    // delivery returns.
    @Test func aCallbackRegistrationFinishesAfterTheDeliveryInProgress() async throws {
        var owner: SharedHost? = try makeSharedHost()
        let reachedFirst = Signal()
        let finished = Signal()
        let hold = ThreadGate()
        // A thrown error returns before the step that lets the held callback go.
        defer { hold.open() }
        let order = OrderLog()
        let token = try #require(owner)
            .subscribe(
                { snapshot in
                    reachedFirst.raise()
                    hold.wait()
                    order.append("receive \(snapshot.revision)")
                },
                onFinish: {
                    order.append("finish")
                    finished.raise()
                }
            )
        await reachedFirst.wait()
        owner = nil
        hold.open()
        await finished.wait()
        #expect(order.entries == ["receive 0", "finish"])
        withExtendedLifetime(token) {}
    }
}

/// Records events from any thread, in order.
private final class OrderLog: Sendable {
    private let storage = AtomicRecordStorage<[String]>([])
    var entries: [String] { storage.load().value }
    func append(_ entry: String) {
        while true {
            let before = storage.load()
            if storage.install(.init(before.value + [entry]), replacing: before) { return }
        }
    }
}
