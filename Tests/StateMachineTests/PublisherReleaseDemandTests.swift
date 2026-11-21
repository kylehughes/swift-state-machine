import Combine
import StateMachine
import StateMachineUI
import Testing

// A presentation publisher delivers a buffered value only when there was an instant at which the
// subscriber had demand and the presentation could still deliver: demand requested after the
// presentation's release reaches no value, even when the request and the release both happen inside
// the delivery's decision.

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// A `MainActor` host of the test's own.
@MainActor private final class CountingHost: MainActorStateMachineHost {
    typealias Input = Void
    typealias Snapshot = Mark
    struct Receipt: StateMachineReceipt {
        let snapshot: Mark
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    private var current = Mark(revision: 0)

    func snapshot() -> Mark { current }
    func send(_ input: Void) throws(SendRejection) -> Receipt {
        current = Mark(revision: current.revision + 1)
        return Receipt(snapshot: current)
    }
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (Mark) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        receive(current)
        return MainActorSnapshotSubscription {}
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: current) }
}

/// A subscriber that requests one value when it subscribes and none after a delivery.
///
/// The publisher calls it only on the main actor, where the test creates and reads it.
private final class OneAtATime: Subscriber {
    typealias Input = Mark
    typealias Failure = Never
    private(set) var subscription: (any Subscription)?
    private(set) var received: [UInt64] = []
    private(set) var finished = false
    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(.max(1))
    }
    func receive(_ input: Mark) -> Subscribers.Demand {
        received.append(input.revision)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { finished = true }
}

/// The presentation the test releases and its subscriber, and whether the pause already acted.
@MainActor private final class Holder {
    var presentation: StateMachineObservableObject<CountingHost>?
    var subscriber: OneAtATime?
    /// Whether revision 1 is buffered, so the next decision is the one the pause interrupts.
    var armed = false
    var acted = false
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PublisherReleaseDemandTests {
    // The subscriber consumes the seed with its one unit, whose request left a demand wake scheduled.
    // Revision 1 is then buffered without demand. Inside the decision of the scheduled delivery, the
    // presentation is released and the subscriber requests one more value, so the demand exists only
    // after the release. Revision 1 is never delivered, and the subscriber is finished.
    @Test func demandRequestedAfterTheReleaseReachesNoBufferedValue() async throws {
        let host = CountingHost()
        let holder = Holder()
        holder.presentation = StateMachineObservableObject(host)
        let subscriber = OneAtATime()
        holder.subscriber = subscriber
        let act: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                guard holder.armed, !holder.acted else { return }
                holder.acted = true
                holder.presentation = nil
                holder.subscriber?.subscription?.request(.max(1))
            }
        }
        PresentationDeliveryPause.$betweenReads.withValue(act) {
            holder.presentation?.presentedSnapshots.subscribe(subscriber)
        }
        #expect(subscriber.received == [0])
        _ = try holder.presentation?.send(())
        #expect(subscriber.received == [0])
        holder.armed = true
        // Let the scheduled delivery run; if its decision did not reach the pause, release and
        // request now, which the next delivery's decision then sees.
        try await Task.sleep(for: .milliseconds(20))
        PresentationDeliveryPause.$betweenReads.withValue(act) { act() }
        while !subscriber.finished { try await Task.sleep(for: .milliseconds(1)) }
        #expect(subscriber.received == [0])
    }
}
