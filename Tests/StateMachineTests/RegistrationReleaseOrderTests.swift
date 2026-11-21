import Dispatch
import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

// Every path that ends a sequence removes its registration before it releases the element it held
// unread, so a destructor that registers again finds the slot free. These tests let one release
// arrive while another is still removing the registration, on another thread or on a later main-actor
// turn, and record the order of the removal and the release.

/// The order of the events a test records.
private final class Events: Sendable {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    var all: [String] { log.withLock { $0 } }
    func record(_ event: String) { log.withLock { $0.append(event) } }
}

/// A projection whose release a test records.
private final class Probe: Sendable {
    private let events: Events?
    init(_ events: Events?) { self.events = events }
    deinit { events?.record("released") }
}

/// A sequence a callback reaches before the registration that returns it has returned.
private final class Later<Value: Sendable>: Sendable {
    private let stored = OSAllocatedUnfairLock<Value?>(initialState: nil)
    var value: Value? { stored.withLock { $0 } }
    func fill(_ value: Value) { stored.withLock { $0 = value } }
    /// Drops the value, outside the lock.
    func clear() {
        let dropped = stored.withLock { stored in
            let value = stored
            stored = nil
            return value
        }
        withExtendedLifetime(dropped) {}
    }
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

/// Runs `body` on another thread and returns once it has.
private func elsewhere(_ body: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    runOnOwnThread {
        body()
        done.signal()
    }
    done.wait()
}

/// A `MainActor` host of the test's own with one subscriber slot.
///
/// It frees the slot when the subscription it returned is cancelled. A hook runs inside its finish
/// callback, after the observer's.
@MainActor private final class OneSlotHost: MainActorStateMachineHost {
    typealias Inner = GeneratedTransfers.MainActorHost
    private let inner: Inner
    private let events: Events
    private(set) var registrations = 0
    var afterFinish: (() -> Void)?
    var onFreed: (() -> Void)?

    init(_ events: Events) throws {
        self.events = events
        inner = GeneratedTransfers.MainActorHost(
            downloadDriver: { _, _ in .success("") },
            onLogged: { _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 8)
        )
    }

    func snapshot() -> Inner.Snapshot { inner.snapshot() }
    func send(_ input: Inner.Input) throws(Inner.SendRejection) -> Inner.Receipt { try inner.send(input) }
    func commit(_ prepared: consuming Inner.Prepared) -> Inner.CommitResult { inner.commit(prepared) }
    func subscribe(
        _ receive: @escaping @MainActor (Inner.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        let token = try inner.subscribe(
            receive,
            onFinish: { [weak self] in
                onFinish()
                self?.afterFinish?()
            }
        )
        registrations += 1
        return MainActorSnapshotSubscription { [weak self, events] in
            self?.registrations -= 1
            events.record("slot freed")
            token.cancel()
            self?.onFreed?()
        }
    }
    func close() -> Inner.Receipt { inner.close() }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct RegistrationReleaseOrderTests {
    // The owner's finish queues the removal of the registration on the main actor. Before that turn
    // runs, another thread cancels the sequence and discards the final projection, which waited unread.
    // The projection stays with the queued removal and is released after it.
    @Test func aCancellationElsewhereAfterTheOwnersFinishReleasesTheUnreadElementAfterTheRemoval() async throws {
        let events = Events()
        let host = try OneSlotHost(events)
        let sequence = Later<SnapshotSequence<Probe>>()
        let freed = Signal()
        var occupied: Bool?
        host.afterFinish = { [weak host] in
            elsewhere {
                sequence.value?.cancel(isolation: nil)
                events.record("cancel returned")
            }
            occupied = host?.registrations == 1
        }
        host.onFreed = { freed.raise() }
        sequence.fill(try host.snapshots { Probe($0.isClosed ? events : nil) })
        _ = host.close()
        await freed.wait()
        #expect(occupied == true)
        #expect(events.all == ["cancel returned", "slot freed", "released"])
    }

    // Two cancellations on other threads: the first queues the removal, and the second, which finds it
    // queued, changes nothing and releases nothing before it.
    @Test func aSecondCancellationElsewhereWaitsForTheQueuedRemoval() async throws {
        let events = Events()
        let host = try OneSlotHost(events)
        let freed = Signal()
        host.onFreed = { freed.raise() }
        let sequence = try host.snapshots { _ in Probe(events) }
        elsewhere {
            sequence.cancel(isolation: nil)
            sequence.cancel(isolation: nil)
            events.record("cancels returned")
        }
        #expect(events.all == ["cancels returned"])
        #expect(host.registrations == 1)
        await freed.wait()
        #expect(events.all == ["cancels returned", "slot freed", "released"])
    }

    // A cancellation on another thread queues the removal on the main actor. A cancellation isolated to
    // the main actor then carries out that removal before it returns, and releases the element the first
    // one discarded right after it.
    @Test func aMainActorCancellationReleasesTheElementAQueuedRemovalHeldAfterRemovingIt() throws {
        let events = Events()
        let host = try OneSlotHost(events)
        let sequence = try host.snapshots { _ in Probe(events) }
        elsewhere {
            sequence.cancel(isolation: nil)
            events.record("cancel returned")
        }
        sequence.cancel()
        events.record("main cancel returned")
        #expect(events.all == ["cancel returned", "slot freed", "released", "main cancel returned"])
    }

    // The sequence's last reference goes away on another thread after the owner's finish queued the
    // removal, with the final projection unread. The projection is released after the removal.
    @Test func releasingTheSequenceElsewhereAfterTheOwnersFinishReleasesTheElementAfterTheRemoval() async throws {
        let events = Events()
        let host = try OneSlotHost(events)
        let sequence = Later<SnapshotSequence<Probe>>()
        let freed = Signal()
        host.afterFinish = {
            elsewhere {
                sequence.clear()
                events.record("released the sequence")
            }
        }
        host.onFreed = { freed.raise() }
        sequence.fill(try host.snapshots { Probe($0.isClosed ? events : nil) })
        _ = host.close()
        await freed.wait()
        #expect(events.all == ["released the sequence", "slot freed", "released"])
    }

    // The token's `onCancel` cancels the same sequence again. The inner call finds the removal in
    // progress and changes nothing, and the element the outer call discarded is released after the
    // outer `onCancel` returns.
    @Test func aCancellationFromInsideTheTokensCancellationChangesNothing() throws {
        let events = Events()
        let sequence = Later<SnapshotSequence<Probe>>()
        let callbacks = Later<RegisteredCallbacks>()
        let registered = try SnapshotSequence<Probe> { receive, finish in
            callbacks.fill(RegisteredCallbacks(receive: receive, finish: finish))
            return SnapshotSubscription {
                sequence.value?.cancel(isolation: nil)
                events.record("slot freed")
            }
        }
        sequence.fill(registered)
        callbacks.value?.receive(Probe(events))
        registered.cancel()
        events.record("cancel returned")
        #expect(events.all == ["slot freed", "released", "cancel returned"])
    }

    // A host of the test's own finishes the sequence on one thread, which cancels the token, and its
    // `onCancel` frees the slot only once the test lets it. A cancellation on another thread meanwhile
    // discards the final element, which stays with the first cancellation and is released after its
    // `onCancel` has returned.
    @Test func aCancellationDuringTheFinishsCancellationReleasesTheUnreadElementAfterIt() throws {
        let events = Events()
        let callbacks = Later<RegisteredCallbacks>()
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let sequence = try SnapshotSequence<Probe> { receive, finish in
            callbacks.fill(RegisteredCallbacks(receive: receive, finish: finish))
            return SnapshotSubscription {
                entered.signal()
                proceed.wait()
                events.record("slot freed")
            }
        }
        let finishing = DispatchSemaphore(value: 0)
        runOnOwnThread {
            callbacks.value?.receive(Probe(events))
            callbacks.value?.finish()
            finishing.signal()
        }
        entered.wait()
        elsewhere {
            sequence.cancel(isolation: nil)
            events.record("cancel returned")
        }
        #expect(events.all == ["cancel returned"])
        proceed.signal()
        finishing.wait()
        #expect(events.all == ["cancel returned", "slot freed", "released"])
    }
}

/// The callbacks a host of the test's own registered.
private struct RegisteredCallbacks: Sendable {
    let receive: @Sendable (Probe) -> Void
    let finish: @Sendable () -> Void
}
