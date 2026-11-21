import Combine
import StateMachine
import Testing
import os

// A publisher delivers at most 32 values in one main-actor turn. A subscriber that makes the owner hand
// over another value from each one it receives cannot hold the main actor: a later turn continues with
// the outstanding demand and the pending value, and a cancellation between turns ends delivery.

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

/// What a subscriber received, which outlives the subscriber.
private final class Log {
    var received: [Int] = []
    var finished = false
}

/// A subscriber with unlimited demand that hands the owner the next value from each one it receives,
/// up to `last`, and raises a signal when it is released.
///
/// The publisher calls it only on the main actor, where the test creates and reads it.
private final class Feeding: Subscriber {
    typealias Input = Int
    typealias Failure = Never
    let log = Log()
    var received: [Int] { log.received }
    private(set) var subscription: (any Subscription)?
    private let feed: @Sendable (Int) -> Void
    private let last: Int
    private let reachedLast: Signal
    private let released: Signal

    init(feed: @escaping @Sendable (Int) -> Void, last: Int, reachedLast: Signal, released: Signal) {
        self.feed = feed
        self.last = last
        self.reachedLast = reachedLast
        self.released = released
    }
    deinit { released.raise() }

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(.unlimited)
    }
    func receive(_ input: Int) -> Subscribers.Demand {
        log.received.append(input)
        if input < last { feed(input + 1) } else { reachedLast.raise() }
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { log.finished = true }
}

/// A shared owner's publisher, and the receive callback it registered.
@MainActor private func sharedPublisher() throws -> (SnapshotPublisher<Int>, @Sendable (Int) -> Void) {
    let callback = OSAllocatedUnfairLock<(@Sendable (Int) -> Void)?>(initialState: nil)
    let publisher = try SnapshotPublisher<Int>(
        { $0 },
        isFinal: { _ in false },
        ownerLifetime: RuntimeRegistrationGate()
    ) { receive, _, _ in
        callback.withLock { $0 = receive }
        return SnapshotSubscription(onCancel: {})
    }
    guard let receive = callback.withLock({ $0 }) else { preconditionFailure("not registered") }
    return (publisher, receive)
}

private typealias MainHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>

@MainActor private func makeMainHost() throws -> MainHost {
    MainHost(
        0,
        scopes: [],
        configuration: try ManagedConfiguration(subscribers: 8),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

/// The publisher a test's observers reach, and what its subscriber had received at the end of a turn.
@MainActor private final class Turn {
    var publisher: SnapshotPublisher<Int>?
    var receivedInTurn: [Int]?
}

/// A subscriber that records what it receives, on the main actor, and asks for `initialDemand` when it
/// subscribes.
private final class Recording: Subscriber {
    typealias Input = Int
    typealias Failure = Never
    private let initialDemand: Subscribers.Demand
    private(set) var received: [Int] = []
    private(set) var subscription: (any Subscription)?
    var onReceive: ((Int) -> Void)?
    var onFinish: (() -> Void)?

    init(initialDemand: Subscribers.Demand = .unlimited) { self.initialDemand = initialDemand }

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(initialDemand)
    }
    func receive(_ input: Int) -> Subscribers.Demand {
        received.append(input)
        onReceive?(input)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { onFinish?() }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PublisherTurnTests {
    // The owner's one delivery turn carries 32 changes. An observer registered before the publisher
    // attaches the subscriber from its callback for the first change, which delivers the publisher's
    // pending value inside the attachment, and the owner then offers the publisher each change of the
    // same turn. An observer registered after the publisher records what the subscriber had received
    // when the turn's last change reached it: 32 values in all, the attachment's among them, and the
    // newest of the rest follows on a later turn.
    @Test func successiveOffersInOneTurnShareTheTurnsDeliveries() async throws {
        let host = try makeMainHost()
        let subscriber = Recording()
        let turn = Turn()
        let before = try host.subscribe { snapshot in
            guard snapshot.revision == 1, let publisher = turn.publisher else { return }
            publisher.receive(subscriber: subscriber)
        }
        turn.publisher = try host.snapshotPublisher { Int($0.revision) }
        let after = try host.subscribe { snapshot in
            if snapshot.revision == 32 { turn.receivedInTurn = subscriber.received }
        }
        let newest = Signal()
        subscriber.onReceive = { if $0 == 32 { newest.raise() } }
        for model in 1 ... 32 {
            guard case .committed = host.reset(model, scopes: []) else { preconditionFailure("rejected") }
        }
        await newest.wait()
        #expect(turn.receivedInTurn == Array(0 ..< 32))
        #expect(subscriber.received == Array(0 ... 32))
        subscriber.subscription?.cancel()
        before.cancel()
        after.cancel()
    }

    // The owner's one delivery turn carries 31 changes and then its close. The subscriber, attached from
    // the first change, receives 32 values in that turn, the attachment's among them, which spends the
    // turn's deliveries before the closed snapshot arrives with the finish; both reach it on a later
    // turn.
    @Test func aFinishThatArrivesWithTheTurnsDeliveriesSpentFollowsOnALaterTurn() async throws {
        let host = try makeMainHost()
        let subscriber = Recording()
        let turn = Turn()
        let before = try host.subscribe { snapshot in
            guard snapshot.revision == 1, let publisher = turn.publisher else { return }
            publisher.receive(subscriber: subscriber)
        }
        turn.publisher = try host.snapshotPublisher { Int($0.revision) }
        let after = try host.subscribe { snapshot in
            if snapshot.isClosed { turn.receivedInTurn = subscriber.received }
        }
        let finished = Signal()
        subscriber.onFinish = { finished.raise() }
        for model in 1 ... 31 {
            guard case .committed = host.reset(model, scopes: []) else { preconditionFailure("rejected") }
        }
        #expect(host.close().revision == 32)
        await finished.wait()
        #expect(turn.receivedInTurn == Array(0 ..< 32))
        #expect(subscriber.received == Array(0 ... 32))
        before.cancel()
        after.cancel()
    }

    // A subscriber asks for 40 values, and the owner hands over the next value from each one delivered.
    // The subscription call delivers 32, the refill the 8 still demanded, and nothing more until the
    // subscriber asks again, when exactly one more arrives: no unit of demand is lost or spent twice
    // across the turn's end.
    @Test func demandCarriesAcrossTheTurnsEndExactly() async throws {
        let (publisher, receive) = try sharedPublisher()
        receive(0)
        let subscriber = Recording(initialDemand: .max(40))
        let fortieth = Signal()
        let fortyFirst = Signal()
        subscriber.onReceive = { value in
            receive(value + 1)
            if value == 39 { fortieth.raise() }
            if value == 40 { fortyFirst.raise() }
        }
        publisher.receive(subscriber: subscriber)
        #expect(subscriber.received == Array(0 ..< 32))
        await fortieth.wait()
        #expect(subscriber.received == Array(0 ..< 40))
        subscriber.subscription?.request(.max(1))
        await fortyFirst.wait()
        #expect(subscriber.received == Array(0 ... 40))
        subscriber.subscription?.cancel()
    }

    // The subscriber hands over the next value from each of 500. The subscription call delivers 32
    // inside itself and later turns deliver the rest, in order.
    @Test func aSubscriberThatFeedsEachValueReceivesAtMost32InOneTurn() async throws {
        let (publisher, receive) = try sharedPublisher()
        receive(0)
        let reachedLast = Signal()
        let subscriber = Feeding(feed: receive, last: 499, reachedLast: reachedLast, released: Signal())
        publisher.receive(subscriber: subscriber)
        #expect(subscriber.received == Array(0 ..< 32))
        await reachedLast.wait()
        #expect(subscriber.received == Array(0 ..< 500))
        subscriber.subscription?.cancel()
    }

    // Cancelling between turns ends delivery: the publisher releases the subscriber on the next turn
    // without delivering the value still pending, or a completion.
    @Test func cancellingBetweenTurnsDeliversNothingMore() async throws {
        let (publisher, receive) = try sharedPublisher()
        receive(0)
        let released = Signal()
        var subscriber: Feeding? = Feeding(feed: receive, last: 499, reachedLast: Signal(), released: released)
        let log = subscriber?.log
        publisher.receive(subscriber: subscriber!)
        let subscription = subscriber?.subscription
        #expect(log?.received == Array(0 ..< 32))
        subscription?.cancel()
        subscriber = nil
        await released.wait()
        #expect(log?.received == Array(0 ..< 32))
        #expect(log?.finished == false)
        withExtendedLifetime(subscription) {}
    }
}
