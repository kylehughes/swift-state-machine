import Combine
import StateMachine
import StateMachineUI
import Testing
import os

// Attacks on the three rules the presentation and registration code follow. A record that another
// thread reads holds no client value, and a change of shared state takes every value it displaces out
// of the state and releases it after unlocking: a destructor that reenters the same object would stop
// the program on the lock it already holds otherwise. The end of a registration is the moment its
// token's cancellation has returned, and a registration that begins inside that cancellation waits
// for it.

/// The order of the events a test records.
private final class Events: Sendable {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    var all: [String] { log.withLock { $0 } }
    func record(_ event: String) { log.withLock { $0.append(event) } }
}

/// A value whose destructor records its name and then runs a hook, which may reenter whatever
/// released it.
private final class Reentering: Sendable {
    private let name: String
    private let events: Events
    private let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(_ name: String, _ events: Events, _ hook: (@Sendable () -> Void)? = nil) {
        self.name = name
        self.events = events
        self.hook.withLock { $0 = hook }
    }
    deinit {
        events.record("\(name) released")
        hook.withLock { $0.take() }?()
    }
}

/// A value any thread fills and reads.
private final class Later<Value: Sendable>: Sendable {
    private let stored = OSAllocatedUnfairLock<Value?>(initialState: nil)
    var value: Value? { stored.withLock { $0 } }
    func fill(_ value: Value) { stored.withLock { $0 = value } }
}

/// Returns once every main-actor job enqueued before this call has run.
@MainActor private func drainMainActorJobs() async {
    await Task { @MainActor in }.value
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LockedStateReentryTests {
    // An offer displaces an unread element whose destructor cancels the sequence. The mailbox releases
    // it after unlocking, so the cancellation takes effect, and the element the cancellation discards
    // is released once the slot is free; its destructor, which cancels again, changes nothing.
    @Test func aDisplacedElementWhoseDestructorCancelsTheSequenceReentersNoLock() async throws {
        let events = Events()
        let held = Later<SnapshotSequence<Reentering>>()
        var receive: (@Sendable (Reentering) -> Void)?
        let sequence = try SnapshotSequence<Reentering> { offer, finish in
            receive = offer
            return SnapshotSubscription { withExtendedLifetime((offer, finish)) { events.record("slot freed") } }
        }
        held.fill(sequence)
        let cancel: @Sendable () -> Void = { held.value?.cancel(isolation: nil) }
        receive?(Reentering("first", events, cancel))
        receive?(Reentering("second", events, cancel))
        var iterator = sequence.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(events.all == ["first released", "slot freed", "second released"])
    }

    // A shared owner's mailbox releases the envelope an offer displaces after unlocking, so the
    // envelope's destructor can cancel the registration, and offer again, on the same mailbox.
    @Test func aDisplacedEnvelopeWhoseDestructorCancelsItsMailboxReentersNoLock() async {
        let events = Events()
        let mailbox = Later<LatestMailbox<Reentering>>()
        let made = LatestMailbox<Reentering>(
            initial: Reentering("initial", events) {
                mailbox.value?.cancel()
                mailbox.value?.offer(Reentering("late", events), revision: 3, terminal: false)
            },
            revision: 0,
            terminal: false,
            receive: { _ in events.record("received") },
            finish: { events.record("finished") }
        )
        mailbox.fill(made)
        made.offer(Reentering("newer", events), revision: 1, terminal: false)
        #expect(events.all == ["initial released", "late released", "newer released"])
        #expect(!made.gate.isOpen)
    }

    // The main-actor bridge releases the snapshot an offer displaces after unlocking, so its
    // destructor can cancel the bridge and offer again; nothing is delivered afterward.
    @Test func aDisplacedSnapshotWhoseDestructorCancelsTheBridgeReentersNoLock() async {
        let events = Events()
        let bridge = Later<MainActorSnapshotIngress<Reentering>>()
        let made = MainActorSnapshotIngress<Reentering> { _ in events.record("received") }
        bridge.fill(made)
        made.offer(
            Reentering("first", events) {
                bridge.value?.cancel()
                bridge.value?.offer(Reentering("late", events), revision: 3)
            },
            revision: 1
        )
        made.offer(Reentering("second", events), revision: 2)
        await drainMainActorJobs()
        #expect(events.all == ["first released", "late released", "second released"])
    }

    // A token's action captures a value whose destructor cancels the token again. The token releases
    // the action after it has run and before it records that its cancellation has returned, so that
    // second call finds the cancellation running and its completion runs after the first call's.
    @Test func aTokenActionCaptureWhoseDestructorCancelsTheTokenWaitsForTheCancellation() {
        let events = Events()
        let token = Later<SnapshotSubscription>()
        let made = Self.token(
            capturing: Reentering("capture", events) {
                token.value?.cancel(then: { events.record("inner done") })
            },
            events
        )
        token.fill(made)
        made.cancel(then: { events.record("outer done") })
        #expect(events.all == ["action", "capture released", "outer done", "inner done"])
    }

    // A token whose action holds the only reference to `capture`.
    private static func token(capturing capture: consuming Reentering, _ events: Events) -> SnapshotSubscription {
        SnapshotSubscription { [capture] in withExtendedLifetime(capture) { events.record("action") } }
    }
}

/// A `MainActor` host of the test's own with one slot, which it frees when its subscription's
/// cancellation returns, and which cancels that subscription itself, running a hook inside it.
@MainActor private final class SlotHost: MainActorStateMachineHost {
    typealias Input = Never
    struct Snapshot: StateMachineSnapshot, Sendable {
        let revision: UInt64
    }
    struct Receipt: StateMachineReceipt {
        let snapshot: Snapshot
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private(set) var registrations = 0
    private(set) var refusals = 0
    private var token: MainActorSnapshotSubscription?
    var inCancellation: (@MainActor () -> Void)?

    func snapshot() -> Snapshot { Snapshot(revision: 1) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else {
            refusals += 1
            throw .capacityExceeded
        }
        registrations += 1
        receive(Snapshot(revision: 1))
        let token = MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            let hook = inCancellation
            inCancellation = nil
            hook?()
            registrations -= 1
        }
        self.token = token
        return token
    }
    func cancelSubscription() { token?.cancel() }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Snapshot(revision: 1)) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct RegistrationInsideCancellationTests {
    // A host cancels a presentation's subscription, and from inside that cancellation the
    // presentation observes the same host again, synchronously. The old registration still holds the
    // slot, so the host refuses, and the refusal is thrown at once; nothing registers behind it, and
    // observing again once the cancellation has returned registers.
    @Test(arguments: PresentationClass.allCases)
    func anObservationStartedInsideItsPredecessorsCancellationThrowsItsRefusal(
        _ kind: PresentationClass
    ) async throws {
        let host = SlotHost()
        var thrown: SubscriptionFailure?
        let observe: @MainActor () throws(SubscriptionFailure) -> Void
        let live: @MainActor () -> Bool
        let presentation: AnyObject
        switch kind {
        case .combine:
            let made = SnapshotObservableObject(SlotHost.Snapshot(revision: 0))
            presentation = made
            observe = { () throws(SubscriptionFailure) in try made.observe(host) }
            live = { made.isObserving }
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            let made = SnapshotPresentation(SlotHost.Snapshot(revision: 0))
            presentation = made
            observe = { () throws(SubscriptionFailure) in try made.observe(host) }
            live = { made.isObserving }
        }
        try observe()
        #expect(live())
        host.inCancellation = {
            do throws(SubscriptionFailure) { try observe() } catch { thrown = error }
        }
        host.cancelSubscription()
        #expect(thrown == .capacityExceeded)
        #expect(host.refusals == 1)
        #expect(host.registrations == 0)
        #expect(!live())
        try observe()
        #expect(host.registrations == 1)
        #expect(live())
        withExtendedLifetime(presentation) {}
    }
}
