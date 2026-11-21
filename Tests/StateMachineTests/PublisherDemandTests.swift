import Combine
import StateMachine
import Testing

// A publisher's delivery loop decides, in one step, which value a unit of demand reaches and whether
// the owner is still open. These tests drive each constructor through callbacks they hold, so each
// value, finish, and release happens at a chosen point relative to the subscriber's demand. The
// channel takes what a `Sendable` owner handed over at the start of every step, so no test waits for
// a hand-off turn: each waits only for the subscriber's own values and completion.

/// A value of 100 or more stands for the owner's closed snapshot.
private func isClosed(_ value: Int) -> Bool { value >= 100 }

/// What a recorded subscriber observed, in order.
private enum Observed: Equatable {
    case value(Int)
    case finished
}

/// A subscriber that records what it receives and requests the demand the test chooses.
///
/// The publisher calls it only on the main actor, where the test creates and reads it.
private final class Recorder: Subscriber {
    typealias Input = Int
    typealias Failure = Never
    private(set) var subscription: (any Subscription)?
    private(set) var received: [Int] = []
    /// Runs for each value before the subscriber returns its demand.
    var onReceive: ((Int) -> Subscribers.Demand)?
    private let initial: Subscribers.Demand
    private let events: AsyncStream<Observed>
    private let continuation: AsyncStream<Observed>.Continuation

    init(requesting initial: Subscribers.Demand) {
        self.initial = initial
        (events, continuation) = AsyncStream<Observed>.makeStream()
    }

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(initial)
    }
    func receive(_ input: Int) -> Subscribers.Demand {
        received.append(input)
        continuation.yield(.value(input))
        return onReceive?(input) ?? .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        continuation.yield(.finished)
    }

    /// Waits for the completion, and returns everything observed up to it.
    nonisolated(nonsending) func untilFinished() async -> [Observed] {
        var observed: [Observed] = []
        var iterator = events.makeAsyncIterator()
        while let next = await iterator.next() {
            observed.append(next)
            if next == .finished { break }
        }
        return observed
    }
}

/// The three ways an owner feeds a publisher, each driven through the callbacks its constructor
/// registers.
enum PublisherConstructor: CaseIterable, CustomTestStringConvertible, Sendable {
    case mainActor, shared, actor

    var testDescription: String {
        switch self {
        case .mainActor: "main-actor owner"
        case .shared: "shared owner"
        case .actor: "actor owner"
        }
    }
}

/// An owner of each kind that the test drives by hand.
@MainActor private final class Owner {
    let publisher: SnapshotPublisher<Int>
    private let kind: PublisherConstructor
    private let callbacks: Callbacks
    // The owner's lifetime gate, which its release without closing closes before any notice.
    private let lifetime = RuntimeRegistrationGate()
    private var closed = false

    /// The callbacks a constructor registered, which the owner holds as a host's registry would.
    ///
    /// Every constructor runs its registration on the main actor.
    @MainActor final class Callbacks {
        var mainReceive: (@MainActor (Int) -> Void)?
        var mainFinish: (@MainActor () -> Void)?
        var receive: (@Sendable (Int) -> Void)?
        var finish: (@Sendable () -> Void)?
        var released: (@Sendable () -> Void)?
    }

    init(_ kind: PublisherConstructor) async throws {
        self.kind = kind
        let callbacks = Callbacks()
        self.callbacks = callbacks
        let lifetime = lifetime
        switch kind {
        case .mainActor:
            publisher = try SnapshotPublisher(mainActor: { $0 }, isFinal: isClosed, ownerLifetime: lifetime) {
                receive,
                finish,
                _ in
                callbacks.mainReceive = receive
                callbacks.mainFinish = finish
                return MainActorSnapshotSubscription(onCancel: {})
            }
        case .shared:
            publisher = try SnapshotPublisher({ $0 }, isFinal: isClosed, ownerLifetime: lifetime) {
                receive,
                finish,
                released in
                callbacks.receive = receive
                callbacks.finish = finish
                callbacks.released = released
                return SnapshotSubscription(onCancel: {})
            }
        case .actor:
            publisher = try await SnapshotPublisher(actor: { $0 }, isFinal: isClosed, ownerLifetime: lifetime) {
                receive,
                finish,
                released in
                callbacks.released = released
                callbacks.receive = receive
                callbacks.finish = finish
                return SnapshotSubscription(onCancel: {})
            }
        }
    }

    /// Delivers one snapshot, a closed one when `value` is 100 or more.
    func deliver(_ value: Int) {
        if isClosed(value) { closed = true }
        switch kind {
        case .mainActor: callbacks.mainReceive?(value)
        case .shared, .actor: callbacks.receive?(value)
        }
    }
    /// Finishes the registration, as an owner does after its closed snapshot or after its release.
    func finish() {
        switch kind {
        case .mainActor: callbacks.mainFinish?()
        case .shared, .actor: callbacks.finish?()
        }
    }
    /// Releases the owner without closing it.
    ///
    /// Unless closing promised its closed snapshot, every owner closes its lifetime gate at once and
    /// then runs the registration's release notice, which only a `Sendable` owner's publisher has, and
    /// releases the receive callback. The finish that follows is the test's to deliver.
    func release() {
        if !closed {
            lifetime.close()
            callbacks.released?()
        }
        callbacks.mainReceive = nil
        callbacks.receive = nil
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PublisherDemandTests {
    // Revision 0 is already in the publisher when the owner hands over its closed snapshot and its
    // finish. Demand made afterward reaches the closed snapshot, the newest value, and the publisher
    // then finishes.
    @Test(arguments: PublisherConstructor.allCases)
    func theNewestValueConsumesDemandOwedToTheClosedSnapshot(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.deliver(0)
        owner.publisher.subscribe(subscriber)
        owner.deliver(103)
        owner.finish()
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.value(103), .finished])
    }

    // Revision 0 has moved into the publisher, and the closed snapshot and finish are still in the
    // owner's hand-off when a subscriber attaches with demand for one value. Attaching serves that
    // demand at once, before the queued hand-off turn, and it reaches the closed snapshot.
    @Test(arguments: PublisherConstructor.allCases)
    func attachingWithDemandAfterTheClosedSnapshotReceivesIt(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        owner.deliver(0)
        // The main actor runs its jobs in order, so the hand-off turn that revision 0 queued has run
        // once a job queued after it has.
        await Task { @MainActor in }.value
        owner.deliver(103)
        owner.finish()
        let subscriber = Recorder(requesting: .max(1))
        owner.publisher.subscribe(subscriber)
        #expect(await subscriber.untilFinished() == [.value(103), .finished])
    }

    // Demand first made after the owner's release finds nothing promised.
    @Test(arguments: PublisherConstructor.allCases)
    func demandAfterAReleaseReceivesOnlyTheCompletion(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        owner.release()
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.finished])
    }

    // A subscriber attached after the release finishes without a value.
    @Test(arguments: PublisherConstructor.allCases)
    func attachingAfterAReleaseReceivesOnlyTheCompletion(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        owner.deliver(0)
        owner.release()
        let subscriber = Recorder(requesting: .unlimited)
        owner.publisher.subscribe(subscriber)
        #expect(await subscriber.untilFinished() == [.finished])
    }

    // While it receives revision 0, the subscriber makes the owner deliver revision 1 and release
    // itself, and then returns one unit of demand. That demand exists only after the release, so it
    // reaches no ordinary value.
    @Test(arguments: PublisherConstructor.allCases)
    func demandReturnedAfterAReleaseDuringADeliveryReachesNoValue(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        subscriber.onReceive = { value in
            guard value == 0 else { return .none }
            owner.deliver(1)
            owner.release()
            return .max(1)
        }
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.value(0), .finished])
    }

    // The same demand requested through the subscription from inside the delivery.
    @Test(arguments: PublisherConstructor.allCases)
    func demandRequestedAfterAReleaseDuringADeliveryReachesNoValue(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        subscriber.onReceive = { [unowned subscriber] value in
            guard value == 0 else { return .none }
            owner.deliver(1)
            owner.release()
            subscriber.subscription?.request(.max(1))
            return .none
        }
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.value(0), .finished])
    }

    // Demand returned during a delivery, with the owner still open, reaches the next value.
    @Test(arguments: PublisherConstructor.allCases)
    func demandReturnedDuringADeliveryReachesTheNextValue(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        subscriber.onReceive = { value in
            guard value == 0 else { return .none }
            owner.deliver(102)
            owner.finish()
            return .max(1)
        }
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.value(0), .value(102), .finished])
    }

    // Closing promised the closed snapshot, so a release after it keeps it for demand made later.
    @Test(arguments: PublisherConstructor.allCases)
    func aClosedSnapshotSurvivesTheReleaseThatFollowsIt(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        owner.deliver(103)
        owner.finish()
        owner.release()
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.value(103), .finished])
    }

    // Demand made before everything receives values in increasing order, ending with the closed one.
    @Test(arguments: PublisherConstructor.allCases)
    func unlimitedDemandReceivesIncreasingValuesEndingWithTheClosedOne(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .unlimited)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        owner.deliver(1)
        owner.deliver(102)
        owner.finish()
        let observed = await subscriber.untilFinished()
        #expect(observed.last == .finished)
        #expect(subscriber.received.last == 102)
        #expect(zip(subscriber.received, subscriber.received.dropFirst()).allSatisfy { $0 < $1 })
    }

    // Outstanding demand with nothing pending: the release's finish completes the subscriber.
    @Test(arguments: PublisherConstructor.allCases)
    func aReleaseWithDemandOutstandingFinishes(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .max(1))
        owner.publisher.subscribe(subscriber)
        owner.release()
        owner.finish()
        #expect(await subscriber.untilFinished() == [.finished])
    }

    // A finish without the closed snapshot discards an ordinary value that waits for demand.
    @Test(arguments: PublisherConstructor.allCases)
    func aFinishWithoutTheClosedSnapshotDiscardsAWaitingValue(_ kind: PublisherConstructor) async throws {
        let owner = try await Owner(kind)
        let subscriber = Recorder(requesting: .none)
        owner.publisher.subscribe(subscriber)
        owner.deliver(0)
        owner.release()
        owner.finish()
        subscriber.subscription?.request(.max(1))
        #expect(await subscriber.untilFinished() == [.finished])
    }
}
