import Foundation
import StateMachineTesting
import Synchronization
import Testing

// The Swift runtime does not report to the thread sanitizer the ordering of a continuation resumed
// before its task suspends, so a value carried in that resumption looks unsynchronized to it. The
// controlled drivers' queue and result slot store what they hand over under their lock, and the
// resumed task takes it there, which the sanitizer observes. Each test forces that early resumption
// with explicit ordering on relaxed atomics, which synchronize nothing, and reads memory that another
// thread initialized. The race these tests catch is reported only by a run under `--sanitize thread`;
// without the sanitizer they check that an early resumption still delivers the value.

/// A value whose stored property one thread writes in its initializer before it is handed over.
private final class Payload: Sendable {
    let value: Int

    init(_ value: Int) { self.value = value }
}

/// Flags that order two threads without synchronizing them.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class Steps: Sendable {
    let waiting = Atomic(false)
    let answered = Atomic(false)
}

/// Spins until another thread sets `flag`, without synchronizing with that thread.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func spin(until flag: borrowing Atomic<Bool>) {
    while !flag.load(ordering: .relaxed) {}
}

/// Runs `work` on a thread of its own, so a spinning task cannot starve it.
///
/// Work on Dispatch's global queues waits for a thread in the same per-process allowance as the
/// cooperative pool, so it would not start while every pool thread is blocked or spinning.
private func onAnotherThread(_ work: @escaping @Sendable () -> Void) {
    Thread { work() }.start()
}

@Suite(.timeLimit(.minutes(1))) struct EarlyResumeTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func aWaitAnsweredBeforeItSuspendsTakesTheCallUnderTheQueuesLock() async {
        let steps = Steps()
        // The wait holds before it suspends until another thread's call has answered it.
        let queue = CallQueue<Payload>(beforeSuspending: {
            steps.waiting.store(true, ordering: .relaxed)
            spin(until: steps.answered)
        })
        onAnotherThread {
            spin(until: steps.waiting)
            queue.offer(Payload(7))
            steps.answered.store(true, ordering: .relaxed)
        }
        let call = await queue.next()
        #expect(call?.value == 7)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func aResultChosenBeforeTheDriverSuspendsIsTakenUnderTheSlotsLock() async {
        let steps = Steps()
        let slot = ResultSlot<Payload, Never>()
        // The driver holds before it suspends until another thread has chosen its result.
        let result = await slot.wait(afterInstalling: {
            onAnotherThread {
                _ = slot.finish(.success(Payload(9)))
                steps.answered.store(true, ordering: .relaxed)
            }
            spin(until: steps.answered)
        })
        switch result {
        case .success(let payload): #expect(payload.value == 9)
        }
    }
}
