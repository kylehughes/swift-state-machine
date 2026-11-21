import Combine
import StateMachine
import Testing
import os

// A delivery step releases the values it replaces before it decides what to deliver, and a released
// value's destructor is client code: it can hand over a newer value, finish, request demand, or
// cancel. These tests run that code from the destructor of the value the step displaces, through the
// two constructors whose owners hand values over to the main actor, and check what the step decided
// once the subscription call returns, since the step runs inside it.

/// A delivered value whose destructor runs a hook on the main actor, where the publisher releases it.
private final class Delivered: Sendable {
    let number: Int
    private let hook = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(initialState: nil)

    init(_ number: Int) { self.number = number }
    /// Runs `hook` when this value is destroyed.
    func onRelease(_ hook: @escaping @MainActor @Sendable () -> Void) { self.hook.withLock { $0 = hook } }
    deinit {
        guard let hook = hook.withLock({ $0 }) else { return }
        MainActor.assumeIsolated { hook() }
    }
}

/// What a subscriber observed, in order.
private enum Event: Equatable {
    case value(Int)
    case finished
}

/// A subscriber that records what it receives and requests `initial` when it attaches.
///
/// The publisher calls it only on the main actor, where the test creates and reads it.
private final class Subscriber: Combine.Subscriber {
    typealias Input = Delivered
    typealias Failure = Never
    private(set) var subscription: (any Subscription)?
    private(set) var events: [Event] = []
    private let initial: Subscribers.Demand

    init(requesting initial: Subscribers.Demand = .none) { self.initial = initial }

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(initial)
    }
    func receive(_ input: Delivered) -> Subscribers.Demand {
        events.append(.value(input.number))
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { events.append(.finished) }
}

/// The constructors whose owners hand their values over to the main actor.
enum HandOffConstructor: CaseIterable, CustomTestStringConvertible, Sendable {
    case shared, actor

    var testDescription: String {
        switch self {
        case .shared: "shared owner"
        case .actor: "actor owner"
        }
    }
}

/// An owner of either kind that the test drives through the callbacks its publisher registered.
@MainActor private final class HandOffOwner {
    let publisher: SnapshotPublisher<Delivered>
    let receive: @Sendable (Delivered) -> Void
    let finish: @Sendable () -> Void
    private let cancellations: OSAllocatedUnfairLock<Int>

    /// How many times the publisher cancelled its registration.
    var cancelled: Int { cancellations.withLock { $0 } }

    init(_ kind: HandOffConstructor) async throws {
        let callbacks = OSAllocatedUnfairLock<(@Sendable (Delivered) -> Void, @Sendable () -> Void)?>(initialState: nil)
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        self.cancellations = cancellations
        switch kind {
        case .shared:
            publisher = try SnapshotPublisher(
                { $0 },
                isFinal: { $0.number >= 100 },
                ownerLifetime: RuntimeRegistrationGate()
            ) { receive, finish, _ in
                callbacks.withLock { $0 = (receive, finish) }
                return SnapshotSubscription { cancellations.withLock { $0 += 1 } }
            }
        case .actor:
            publisher = try await SnapshotPublisher(
                actor: { $0 },
                isFinal: { $0.number >= 100 },
                ownerLifetime: RuntimeRegistrationGate()
            ) {
                receive,
                finish,
                _ in
                callbacks.withLock { $0 = (receive, finish) }
                return SnapshotSubscription { cancellations.withLock { $0 += 1 } }
            }
        }
        let (receive, finish) = try #require(callbacks.withLock { $0 })
        self.receive = receive
        self.finish = finish
    }

    /// Hands over value 0, which reaches the publisher on the hand-off turn that the test then lets
    /// run, and makes `onRelease` its destructor's hook; the publisher then holds its only reference.
    func stageZero(onRelease: @escaping @MainActor @Sendable () -> Void) async {
        let zero = Delivered(0)
        zero.onRelease(onRelease)
        receive(zero)
        // The main actor runs its jobs in order, so the hand-off turn that value 0 queued has run once
        // a job queued after it has.
        await Task { @MainActor in }.value
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PublisherDestructorTests {
    // Value 0 waits in the publisher and value 1 in the hand-off when a subscriber attaches without
    // demand. Taking 1 releases 0, whose destructor hands over the closed snapshot 100 and the finish
    // and then requests one value. That unit is spent on 100, the newest value, and the publisher
    // finishes.
    @Test(arguments: HandOffConstructor.allCases)
    func demandRequestedByAReleasedValueReachesTheClosedSnapshotItHandedOver(
        _ kind: HandOffConstructor
    ) async throws {
        let owner = try await HandOffOwner(kind)
        let subscriber = Subscriber()
        let (receive, finish) = (owner.receive, owner.finish)
        await owner.stageZero {
            receive(Delivered(100))
            finish()
            subscriber.subscription?.request(.max(1))
        }
        owner.receive(Delivered(1))
        owner.publisher.subscribe(subscriber)
        #expect(subscriber.events == [.value(100), .finished])
    }

    // The same release requests one value and then cancels. Cancellation returned before the step
    // decided, so nothing is delivered and nothing completes.
    @Test(arguments: HandOffConstructor.allCases)
    func aReleasedValueThatCancelsPreventsTheDeliveryItsDemandWouldHaveMade(
        _ kind: HandOffConstructor
    ) async throws {
        let owner = try await HandOffOwner(kind)
        let subscriber = Subscriber()
        await owner.stageZero {
            subscriber.subscription?.request(.max(1))
            subscriber.subscription?.cancel()
        }
        owner.receive(Delivered(1))
        owner.publisher.subscribe(subscriber)
        #expect(subscriber.events.isEmpty)
        #expect(owner.cancelled == 1)
    }

    // The subscriber attaches with demand for one value. The value the step takes from the hand-off
    // displaces the waiting one, whose destructor hands over a newer value; that newer one, handed
    // over before the step decided, is the one delivered.
    @Test(arguments: HandOffConstructor.allCases)
    func aValueHandedOverByAReleasedValueIsTheOneDelivered(_ kind: HandOffConstructor) async throws {
        let owner = try await HandOffOwner(kind)
        let subscriber = Subscriber(requesting: .max(1))
        let receive = owner.receive
        await owner.stageZero { receive(Delivered(2)) }
        owner.receive(Delivered(1))
        owner.publisher.subscribe(subscriber)
        #expect(subscriber.events == [.value(2)])
        subscriber.subscription?.cancel()
    }
}
