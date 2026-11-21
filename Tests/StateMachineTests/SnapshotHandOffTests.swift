import StateMachine
import StateMachineTestSupport
import Synchronization
import Testing
import os

// The Swift runtime does not report to the thread sanitizer the ordering of a continuation resumed
// before its task suspends, so an element carried in that resumption looks unsynchronized with the
// thread that offered it. A `SnapshotSequence` stores the element it hands a waiting read under its
// lock, and the read takes it there once it resumes, which the sanitizer observes. Each test forces
// that early resumption with explicit ordering on relaxed atomics, which synchronize nothing, and
// reads memory the offering thread initialized. The race these tests catch is reported only by a run
// under `--sanitize thread`; without the sanitizer they check that an early resumption still delivers
// the element, in order, and keeps it through a cancellation that comes after the hand-off.

/// An element whose stored property the offering thread writes in its initializer.
private final class Payload: Sendable {
    let value: Int

    init(_ value: Int) { self.value = value }
}

/// Flags that order two threads without synchronizing them.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class Steps: Sendable {
    let waiting = Atomic(false)
    let offered = Atomic(false)
}

/// Spins until another thread sets `flag`, without synchronizing with that thread.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func spin(until flag: borrowing Atomic<Bool>) {
    while !flag.load(ordering: .relaxed) {}
}

/// Runs `work` on a thread of its own, so a spinning task cannot starve it.
private func onAnotherThread(_ work: @escaping @Sendable () -> Void) { runOnOwnThread(work) }

/// A host of the test's own that keeps the callback its one registration offers elements through.
private final class Feed: Sendable {
    private let receive = OSAllocatedUnfairLock<(@Sendable (Payload) -> Void)?>(initialState: nil)

    func sequence() throws(SubscriptionFailure) -> SnapshotSequence<Payload> {
        try SnapshotSequence { receive, _ in
            self.receive.withLock { $0 = receive }
            return SnapshotSubscription(onCancel: {})
        }
    }

    func offer(_ value: Int) { receive.withLock { $0 }?(Payload(value)) }
}

@Suite(.timeLimit(.minutes(1))) struct SnapshotHandOffTests {
    // The read holds before it suspends until another thread has offered two elements: the first is
    // handed to the waiting read, and the second waits for the next read.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func anElementHandedBeforeTheReadSuspendsIsTakenUnderTheMailboxsLock() async throws {
        let steps = Steps()
        // A read that returns without suspending, as a cancelled one may, never runs the hook that lets
        // the other thread stop spinning, so the test lets it go on its way out.
        defer { steps.waiting.store(true, ordering: .relaxed) }
        let feed = Feed()
        let snapshots = try feed.sequence()
        defer { snapshots.cancel() }
        var iterator = snapshots.makeAsyncIterator()
        onAnotherThread {
            spin(until: steps.waiting)
            feed.offer(1)
            feed.offer(2)
            steps.offered.store(true, ordering: .relaxed)
        }
        let first = await SnapshotWaitPause.$beforeSuspending.withValue({
            steps.waiting.store(true, ordering: .relaxed)
            spin(until: steps.offered)
        }) {
            await iterator.next()
        }
        #expect(first?.value == 1)
        #expect(await iterator.next()?.value == 2)
    }

    // A cancellation from another thread after the element was handed to the waiting read leaves that
    // element to the read, as `cancel(isolation:)` documents, and ends every later read.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func aReadHandedAnElementBeforeACancellationStillReturnsIt() async throws {
        let steps = Steps()
        // A read that returns without suspending never runs the hook that lets the other thread stop
        // spinning, so the test lets it go on its way out.
        defer { steps.waiting.store(true, ordering: .relaxed) }
        let feed = Feed()
        let snapshots = try feed.sequence()
        var iterator = snapshots.makeAsyncIterator()
        onAnotherThread {
            spin(until: steps.waiting)
            feed.offer(3)
            snapshots.cancel()
            steps.offered.store(true, ordering: .relaxed)
        }
        let handed = await SnapshotWaitPause.$beforeSuspending.withValue({
            steps.waiting.store(true, ordering: .relaxed)
            spin(until: steps.offered)
        }) {
            await iterator.next()
        }
        #expect(handed?.value == 3)
        #expect(await iterator.next() == nil)
    }
}
