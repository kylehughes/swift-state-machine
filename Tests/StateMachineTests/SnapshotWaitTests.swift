import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

/// A deterministic clock that advances only when a test calls ``advance(by:)``, so deadline tests
/// never depend on wall-clock sleeps.
final class ManualTestClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Waiter: Sendable {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var now = Instant(offset: .zero)
        var waiters: [Waiter] = []
        var sleepObservers: [CheckedContinuation<Void, Never>] = []
        var onNowRead: (@Sendable () -> Void)?
        var totalSleepsStarted = 0
        var totalSleepsCancelled = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var now: Instant {
        let hook = lock.withLock { state -> (@Sendable () -> Void)? in
            let next = state.onNowRead
            state.onNowRead = nil
            return next
        }
        hook?()
        return lock.withLock { $0.now }
    }
    var minimumResolution: Duration { .nanoseconds(1) }
    var activeSleepCount: Int { lock.withLock { $0.waiters.count } }
    var totalSleepsStarted: Int { lock.withLock { $0.totalSleepsStarted } }
    var totalSleepsCancelled: Int { lock.withLock { $0.totalSleepsCancelled } }

    func armNextNowRead(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { $0.onNowRead = hook }
    }

    func waitUntilSleeping(count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { state -> Bool in
                if state.waiters.count >= count { return true }
                state.sleepObservers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock { state in
            state.now = state.now.advanced(by: duration)
            var ready: [CheckedContinuation<Void, any Error>] = []
            state.waiters.removeAll { waiter in
                if waiter.deadline <= state.now {
                    ready.append(waiter.continuation)
                    return true
                }
                return false
            }
            return ready
        }
        for continuation in due { continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        if Task.isCancelled { throw CancellationError() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let decision = lock.withLock {
                    state -> (immediate: Bool, cancelled: Bool, observers: [CheckedContinuation<Void, Never>]) in
                    state.totalSleepsStarted += 1
                    if Task.isCancelled {
                        state.totalSleepsCancelled += 1
                        return (false, true, [])
                    }
                    if deadline <= state.now { return (true, false, []) }
                    state.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    let observers = state.sleepObservers
                    state.sleepObservers = []
                    return (false, false, observers)
                }
                for observer in decision.observers { observer.resume() }
                if decision.cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if decision.immediate {
                    continuation.resume()
                }
            }
        } onCancel: {
            let removed = lock.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                state.totalSleepsCancelled += 1
                return state.waiters.remove(at: index).continuation
            }
            removed?.resume(throwing: CancellationError())
        }
    }
}

/// A manual `SnapshotSequence` feeder for testing exact mailbox tie rules deterministically.
private final class ManualFeeder<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var receive: (@Sendable (Element) -> Void)?
        var finish: (@Sendable () -> Void)?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func makeSequence(initial: Element? = nil, finishImmediately: Bool = false) throws -> SnapshotSequence<Element> {
        try SnapshotSequence { receive, finish in
            state.withLock { s in
                s.receive = receive
                s.finish = finish
            }
            if let initial { receive(initial) }
            if finishImmediately { finish() }
            return SnapshotSubscription {
                self.state.withLock { s in
                    s.cancelled = true
                    s.receive = nil
                    s.finish = nil
                }
            }
        }
    }

    func send(_ element: Element) {
        let receive = state.withLock { $0.receive }
        receive?(element)
    }

    func finish() {
        let finish = state.withLock { $0.finish }
        finish?()
    }
}

/// An actor owning a confined `GeneratedNote.IsolatedHost` to verify actor-isolated predicates and cleanup.
private actor NoteActor {
    private var acceptedTarget = "done"
    private lazy var host = GeneratedNote.IsolatedHost(
        isolation: self,
        saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) }
    )

    func verifyIsolatedWait() async throws {
        let clock = ManualTestClock()

        // Already matching with expired deadline: returns matched with 0 sleeps and frees slot.
        let initialSeq = try host.distinctSnapshots { snap -> String in
            switch snap {
            case .draft(let d): d.value.text
            case .saving(let s): s.value.text
            case .saved(let s): s.value.text
            }
        }
        let r0 = await initialSeq.wait(deadline: clock.now, clock: clock) { $0.isEmpty }
        #expect(r0 == .matched(""))
        #expect(clock.totalSleepsStarted == 0)
        #expect(host.subscriberCount() == 0)

        // Future match using an actor-isolated predicate reading `self.acceptedTarget`.
        let futureSeq = try host.distinctSnapshots { snap -> String in
            switch snap {
            case .draft(let d): d.value.text
            case .saving(let s): s.value.text
            case .saved(let s): s.value.text
            }
        }
        let editTask = Task {
            await clock.waitUntilSleeping()
            _ = try? self.host.send(.edit("done"))
        }
        let r1 = await futureSeq.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { value in
            value == self.acceptedTarget
        }
        await editTask.value
        #expect(r1 == .matched("done"))
        #expect(host.subscriberCount() == 0)

        // Deadline expiry frees slot immediately.
        let timeoutSeq = try host.distinctSnapshots { snap -> Bool in
            if case .saved = snap { true } else { false }
        }
        let expireTask = Task {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(5))
        }
        let r2 = await timeoutSeq.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 }
        await expireTask.value
        #expect(r2 == .timedOut)
        #expect(host.subscriberCount() == 0)

        // Closing the host ends the wait with `.ended` and frees slot.
        let closeSeq = try host.distinctSnapshots { snap -> Bool in
            if case .saved = snap { true } else { false }
        }
        let closeTask = Task {
            await clock.waitUntilSleeping()
            _ = self.host.close()
        }
        let r3 = await closeSeq.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 }
        await closeTask.value
        #expect(r3 == .ended)
        #expect(host.subscriberCount() == 0)

        await host.shutdown()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SnapshotWaitTests {
    // MARK: - Exact Mailbox Tie & Ownership Rules

    @Test func alreadyBufferedMatchWinsEvenWithExpiredDeadlineAndNoTimer() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Bool>()
        let sequence = try feeder.makeSequence(initial: true)

        let result = await sequence.wait(deadline: clock.now, clock: clock) { $0 }
        #expect(result == .matched(true))
        #expect(clock.totalSleepsStarted == 0)
        #expect(feeder.isCancelled)
    }

    @Test func alreadyFinishedSequenceTestsBufferedFinalElementBeforeEnding() async throws {
        let clock = ManualTestClock()
        let matchingFeeder = ManualFeeder<Int>()
        let matchingSeq = try matchingFeeder.makeSequence(initial: 7, finishImmediately: true)
        #expect(await matchingSeq.wait(deadline: clock.now, clock: clock) { $0 == 7 } == .matched(7))
        #expect(clock.totalSleepsStarted == 0)
        #expect(matchingFeeder.isCancelled)

        let nonMatchingFeeder = ManualFeeder<Int>()
        let nonMatchingSeq = try nonMatchingFeeder.makeSequence(initial: 3, finishImmediately: true)
        #expect(
            await nonMatchingSeq.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 == 7 } == .ended
        )
        #expect(clock.totalSleepsStarted == 0)
        #expect(nonMatchingFeeder.isCancelled)
    }

    @Test func expiredDeadlineWithoutBufferedMatchReturnsTimedOutWithoutTimer() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Bool>()
        let sequence = try feeder.makeSequence(initial: false)

        let result = await sequence.wait(deadline: clock.now, clock: clock) { $0 }
        #expect(result == .timedOut)
        #expect(clock.totalSleepsStarted == 0)
        #expect(feeder.isCancelled)
    }

    @Test func alreadyCancelledTaskReturnsCancelledWithoutPredicateOrTimer() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Bool>()
        let sequence = try feeder.makeSequence(initial: true)
        let predicateCalled = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            await sequence.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { value in
                predicateCalled.withLock { $0 = true }
                return value
            }
        }
        task.cancel()
        let result = await task.value
        #expect(result == .cancelled)
        #expect(!predicateCalled.withLock { $0 })
        #expect(clock.totalSleepsStarted == 0)
        #expect(feeder.isCancelled)
    }

    @Test func initialNonMatchingPredicateOfferingFinalMatchPreservesFinalElement() async throws {
        // When 1 is buffered with a future deadline and the initial predicate synchronously offers
        // 2 and finishes before returning false, 2 must still be evaluated and matched.
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 1)
        var seen: [Int] = []

        let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
            seen.append(value)
            if value == 1 {
                feeder.send(2)
                feeder.finish()
                return false
            }
            return value == 2
        }
        #expect(result == .matched(2))
        #expect(seen == [1, 2])
        #expect(clock.totalSleepsStarted == 0)
        #expect(feeder.isCancelled)
    }

    @Test func expiredDeadlineBoundsReentrantOffersAndHonorsExistingTerminalState() async throws {
        // 1. Deadline already expired on entry: the mailbox closes to new offers atomically on the
        // first expired observation while still testing the one already-buffered element (1). Later
        // offers (2...10, where 10 would match) are ignored and cannot starve the deadline.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            var seen: [Int] = []
            let result = await sequence.wait(deadline: clock.now, clock: clock) { value in
                seen.append(value)
                for next in 2 ... 10 { feeder.send(next) }
                return value == 10
            }
            #expect(result == .timedOut)
            #expect(seen == [1])
            #expect(clock.totalSleepsStarted == 0)
            #expect(feeder.isCancelled)
        }

        // 2. Deadline expires while draining: value 2 offered BEFORE the deadline is observed still
        // runs as the final predicate, while values 3...10 offered AFTER expiry are rejected.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            var seen: [Int] = []
            let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
                seen.append(value)
                if value == 1 {
                    feeder.send(2)
                    clock.advance(by: .seconds(5))
                    return false
                }
                for next in 3 ... 10 { feeder.send(next) }
                return value == 10
            }
            #expect(result == .timedOut)
            #expect(seen == [1, 2])
            #expect(clock.totalSleepsStarted == 0)
            #expect(feeder.isCancelled)
        }

        // 3. Same cutoff when the deadline expires inside the suspended loop: at most the one
        // already-buffered element (3) runs; 4...10 offered after expiry are rejected.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            var seen: [Int] = []
            let trigger = Task {
                await clock.waitUntilSleeping()
                feeder.send(2)
            }
            let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
                seen.append(value)
                if value == 2 {
                    feeder.send(3)
                    clock.advance(by: .seconds(5))
                    return false
                }
                if value == 3 {
                    for next in 4 ... 10 { feeder.send(next) }
                    return false
                }
                return value == 10
            }
            await trigger.value
            #expect(result == .timedOut)
            #expect(seen == [1, 2, 3])
            #expect(feeder.isCancelled)
        }

        // 4. Host finishes before deadline expires (even when clock advances during predicate):
        // `.ended` wins over `.timedOut` and the buffered final element is still evaluated.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            var seen: [Int] = []
            let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
                seen.append(value)
                if value == 1 {
                    feeder.send(2)
                    feeder.finish()
                    clock.advance(by: .seconds(5))
                }
                return false
            }
            #expect(result == .ended)
            #expect(seen == [1, 2])
            #expect(clock.totalSleepsStarted == 0)
            #expect(feeder.isCancelled)
        }

        // 5. Already-finished sequence with expired deadline preserves `.ended` and tests final element.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1, finishImmediately: true)
            var seen: [Int] = []
            let result = await sequence.wait(deadline: clock.now, clock: clock) { value in
                seen.append(value)
                return false
            }
            #expect(result == .ended)
            #expect(seen == [1])
            #expect(clock.totalSleepsStarted == 0)
            #expect(feeder.isCancelled)
        }
    }

    @Test func finishBeforeExternalCancelPreservesEndedInBothPollAndNextStep() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 1, finishImmediately: true)
        // Cancel externally after finish: pending element is discarded, first terminal cause stays `.ended`.
        sequence.cancel()
        let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { _ in true }
        #expect(result == .ended)
        #expect(clock.totalSleepsStarted == 0)
    }

    @Test func callerCancellationSuppressingBufferedFinalOrPostDeadlineMatchReportsCancelled() async throws {
        // 1. Producer offers matching 3 and finishes; caller task is cancelled before `nextStep()`
        // reads 3. Because cancellation discarded the unread buffered match, wait reports `.cancelled`,
        // not `.ended`.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            let taskBox = OSAllocatedUnfairLock<Task<SnapshotWaitResult<Int>, Never>?>(initialState: nil)
            let seen = OSAllocatedUnfairLock<[Int]>(initialState: [])

            let waitTask = Task {
                await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
                    seen.withLock { $0.append(value) }
                    if value == 2 {
                        feeder.send(3)
                        feeder.finish()
                        clock.armNextNowRead { taskBox.withLock { $0 }?.cancel() }
                        return false
                    }
                    return value == 3
                }
            }
            taskBox.withLock { $0 = waitTask }
            await clock.waitUntilSleeping()
            feeder.send(2)
            #expect(await waitTask.value == .cancelled)
            #expect(seen.withLock { $0 } == [1, 2])
            #expect(feeder.isCancelled)
        }

        // 2. Same race with deadline expiry instead of finish: must report `.cancelled`, not `.timedOut`.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            let taskBox = OSAllocatedUnfairLock<Task<SnapshotWaitResult<Int>, Never>?>(initialState: nil)
            let seen = OSAllocatedUnfairLock<[Int]>(initialState: [])

            let waitTask = Task {
                await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
                    seen.withLock { $0.append(value) }
                    if value == 2 {
                        feeder.send(3)
                        clock.advance(by: .seconds(5))
                        clock.armNextNowRead { taskBox.withLock { $0 }?.cancel() }
                        return false
                    }
                    return value == 3
                }
            }
            taskBox.withLock { $0 = waitTask }
            await clock.waitUntilSleeping()
            feeder.send(2)
            #expect(await waitTask.value == .cancelled)
            #expect(seen.withLock { $0 } == [1, 2])
            #expect(feeder.isCancelled)
        }

        // 3. Converse: when the host finished with NO unread element left and cancellation fires
        // right before `nextStep()`, no buffered element was suppressed so `.ended` is preserved.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            let taskBox = OSAllocatedUnfairLock<Task<SnapshotWaitResult<Int>, Never>?>(initialState: nil)

            let waitTask = Task {
                await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
                    if value == 2 {
                        feeder.finish()
                        clock.armNextNowRead { taskBox.withLock { $0 }?.cancel() }
                        return false
                    }
                    return false
                }
            }
            taskBox.withLock { $0 = waitTask }
            await clock.waitUntilSleeping()
            feeder.send(2)
            #expect(await waitTask.value == .ended)
            #expect(feeder.isCancelled)
        }
    }

    @MainActor
    @Test func busyProducerYieldsCallerActorInBoundedAndUnboundedWaits() async throws {
        // 1. Bounded wait in initial synchronous poll loop: yields after 32 evaluations so a
        // sibling @MainActor job runs before evaluation 33, with zero timer tasks created.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            var siblingRanAt: Int?
            var evaluations = 0
            var sibling: Task<Void, Never>?

            let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { value in
                evaluations += 1
                if evaluations == 1 {
                    sibling = Task { @MainActor in siblingRanAt = evaluations }
                }
                if siblingRanAt != nil { return true }
                if value < 100 { feeder.send(value + 1) }
                return false
            }
            await sibling?.value
            #expect(siblingRanAt == 32)
            #expect(result == .matched(33))
            #expect(clock.totalSleepsStarted == 0)
            #expect(feeder.isCancelled)
        }

        // 2. Bounded wait after suspending once: a synchronous burst in the suspended loop also
        // yields after 32 evaluations so a sibling @MainActor job runs.
        do {
            let clock = ManualTestClock()
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 0)
            var siblingRanAt: Int?
            var burstEvaluations = 0
            var sibling: Task<Void, Never>?

            let trigger = Task { @MainActor in
                await clock.waitUntilSleeping()
                feeder.send(1)
            }
            let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { value in
                guard value > 0 else { return false }
                burstEvaluations += 1
                if burstEvaluations == 1 {
                    sibling = Task { @MainActor in siblingRanAt = burstEvaluations }
                }
                if siblingRanAt != nil { return true }
                if value < 100 { feeder.send(value + 1) }
                return false
            }
            await trigger.value
            await sibling?.value
            #expect(siblingRanAt == 32)
            #expect(result == .matched(33))
            #expect(feeder.isCancelled)
        }

        // 3. Unbounded wait: continuous synchronous offers also yield after 32 evaluations.
        do {
            let feeder = ManualFeeder<Int>()
            let sequence = try feeder.makeSequence(initial: 1)
            var siblingRanAt: Int?
            var evaluations = 0
            var sibling: Task<Void, Never>?

            let result = await sequence.wait { value in
                evaluations += 1
                if evaluations == 1 {
                    sibling = Task { @MainActor in siblingRanAt = evaluations }
                }
                if siblingRanAt != nil { return true }
                if value < 100 { feeder.send(value + 1) }
                return false
            }
            await sibling?.value
            #expect(siblingRanAt == 32)
            #expect(result == .matched(33))
            #expect(feeder.isCancelled)
        }
    }

    @Test(.parksCooperativeThread)
    func concurrentFeederOfferingFinalMatchDuringInitialPredicatePreservesMatch() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 1)
        let enteredPredicate = DispatchSemaphore(value: 0)
        let fedAndFinished = DispatchSemaphore(value: 0)

        runOnOwnThread {
            enteredPredicate.wait()
            feeder.send(2)
            feeder.finish()
            fedAndFinished.signal()
        }

        let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
            if value == 1 {
                enteredPredicate.signal()
                fedAndFinished.wait()
                return false
            }
            return value == 2
        }
        #expect(result == .matched(2))
        #expect(clock.totalSleepsStarted == 0)
        #expect(feeder.isCancelled)
    }

    @Test func pendingMatchBufferedBeforeTimeoutIsNotLost() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 1)

        // When predicate observes `2`, offer `3` and advance the clock past the deadline before
        // returning `false` so `3` is already buffered when `timeOut()` fires.
        let trigger = Task {
            await clock.waitUntilSleeping()
            feeder.send(2)
        }
        let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { value in
            if value == 2 {
                feeder.send(3)
                clock.advance(by: .seconds(5))
                return false
            }
            return value == 3
        }
        await trigger.value
        #expect(result == .matched(3))
        #expect(feeder.isCancelled)
    }

    @Test func finishBeforeTimeoutPreservesEndedOverTimedOut() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 1)

        let trigger = Task {
            await clock.waitUntilSleeping()
            feeder.finish()
            clock.advance(by: .seconds(5))
        }
        let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 == 99 }
        await trigger.value
        #expect(result == .ended)
        #expect(feeder.isCancelled)
    }

    @Test func externalSequenceCancelWithoutTaskCancellationReportsEnded() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Bool>()
        let sequence = try feeder.makeSequence(initial: false)

        let cancelTask = Task {
            await clock.waitUntilSleeping()
            sequence.cancel()
        }
        let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { $0 }
        await cancelTask.value
        #expect(result == .ended)
        #expect(feeder.isCancelled)
    }

    @Test func singlePassOwnershipDoesNotDisturbFirstConsumer() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 1)

        var iterator = sequence.makeAsyncIterator()
        #expect(await iterator.next() == 1)

        // A second consumer via `wait` returns `.ended` immediately and must NOT cancel `iterator`.
        let second = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 == 2 }
        #expect(second == .ended)
        #expect(clock.totalSleepsStarted == 0)
        #expect(!feeder.isCancelled)

        feeder.send(2)
        #expect(await iterator.next() == 2)
        sequence.cancel()
        #expect(feeder.isCancelled)
    }

    @Test func cancellationWhileWaitingCancelsTimerAndSubscription() async throws {
        let clock = ManualTestClock()
        let feeder = ManualFeeder<Bool>()
        let sequence = try feeder.makeSequence(initial: false)

        let task = Task {
            await sequence.wait(deadline: clock.now.advanced(by: .seconds(30)), clock: clock) { $0 }
        }
        await clock.waitUntilSleeping()
        #expect(clock.activeSleepCount == 1)

        task.cancel()
        let result = await task.value
        #expect(result == .cancelled)
        #expect(feeder.isCancelled)
    }

    @Test func unboundedWaitOverloadMatchesAndCleansUp() async throws {
        let feeder = ManualFeeder<Int>()
        let sequence = try feeder.makeSequence(initial: 0)

        let task = Task {
            await sequence.wait { $0 == 2 }
        }
        feeder.send(1)
        feeder.send(2)
        let result = await task.value
        #expect(result == .matched(2))
        #expect(feeder.isCancelled)
    }

    // MARK: - MainActorHost (.shared & .isolated schemas, MainActor predicate, cross-actor cleanup)

    @MainActor
    @Test func mainActorHostDistinctSnapshotsWaitMatchesTimesOutCancelsClosesAndCleansUp() async throws {
        let clock = ManualTestClock()
        let host = GeneratedNote.MainActorHost(saveDriver: { draft in GeneratedNote.Saved(text: draft.text) })

        // MainActor-isolated mutable state captured directly by a non-Sendable predicate (no TaskGroup needed).
        var seenValues: [String] = []
        let target = "ready"

        // 1. Already matching with expired deadline: 0 sleeps, synchronous slot release.
        let already = try host.distinctSnapshots { snap -> String in
            switch snap {
            case .draft(let d): d.value.text
            case .saving(let s): s.value.text
            case .saved(let s): s.value.text
            }
        }
        #expect(host.subscriberCount == 1)
        let r0 = await already.wait(deadline: clock.now, clock: clock) { value in
            seenValues.append(value)
            return value == ""
        }
        #expect(r0 == .matched(""))
        #expect(seenValues == [""])
        #expect(clock.totalSleepsStarted == 0)
        #expect(host.subscriberCount == 0)

        // 2. Future match before deadline.
        let future = try host.distinctSnapshots { snap -> String in
            switch snap {
            case .draft(let d): d.value.text
            case .saving(let s): s.value.text
            case .saved(let s): s.value.text
            }
        }
        let editTask = Task { @MainActor in
            await clock.waitUntilSleeping()
            _ = try? host.send(.edit(target))
        }
        let r1 = await future.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { value in
            seenValues.append(value)
            return value == target
        }
        await editTask.value
        #expect(r1 == .matched(target))
        #expect(host.subscriberCount == 0)

        // 3. Timeout.
        let timeoutSeq = try host.distinctSnapshots { snap -> Bool in
            if case .saved = snap { true } else { false }
        }
        let expireTask = Task {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(10))
        }
        let r2 = await timeoutSeq.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { $0 }
        await expireTask.value
        #expect(r2 == .timedOut)
        #expect(host.subscriberCount == 0)

        // 4. Parent cancellation while waiting.
        let cancelSeq = try host.distinctSnapshots { snap -> Bool in
            if case .saved = snap { true } else { false }
        }
        let waitTask = Task { @MainActor in
            await cancelSeq.wait(deadline: clock.now.advanced(by: .seconds(30)), clock: clock) { $0 }
        }
        await clock.waitUntilSleeping()
        #expect(host.subscriberCount == 1)
        waitTask.cancel()
        #expect(await waitTask.value == .cancelled)
        #expect(host.subscriberCount == 0)

        // 5. Host closed while waiting -> `.ended`.
        let closeSeq = try host.distinctSnapshots { snap -> Bool in
            if case .saved = snap { true } else { false }
        }
        let closeTask = Task { @MainActor in
            await clock.waitUntilSleeping()
            _ = host.close()
        }
        let r5 = await closeSeq.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { $0 }
        await closeTask.value
        #expect(r5 == .ended)
        #expect(host.subscriberCount == 0)

        await host.shutdown()
    }

    @MainActor
    @Test func mainActorHostReleasedWithoutClosingEndsWait() async throws {
        let clock = ManualTestClock()
        var host: GeneratedNote.MainActorHost? = GeneratedNote.MainActorHost(
            saveDriver: { draft in GeneratedNote.Saved(text: draft.text) }
        )
        let updates = try host!
            .distinctSnapshots { snap -> Bool in
                if case .saved = snap { true } else { false }
            }
        let releaseTask = Task { @MainActor in
            await clock.waitUntilSleeping()
            host = nil
        }
        let result = await updates.wait(deadline: clock.now.advanced(by: .seconds(30)), clock: clock) { $0 }
        await releaseTask.value
        #expect(result == .ended)
    }

    @Test func mainActorHostSequenceAwaitedOffMainActorFreesSlotImmediatelyOnReturn() async throws {
        let clock = ManualTestClock()
        let host = await MainActor.run {
            GeneratedNote.MainActorHost(saveDriver: { draft in GeneratedNote.Saved(text: draft.text) })
        }
        let updates = try await MainActor.run {
            try host.distinctSnapshots { snap -> Bool in
                if case .saved = snap { true } else { false }
            }
        }
        let expireTask = Task {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(5))
        }
        // Awaited from a nonisolated context: gate closes synchronously before `wait` returns.
        let result = await updates.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 }
        await expireTask.value
        #expect(result == .timedOut)
        let count = await MainActor.run { host.subscriberCount }
        #expect(count == 0)
        await host.shutdown()
    }

    @MainActor
    @Test func continuousClockTimeoutAndDeadlineOverloadsCompileAndReturnImmediatelyWhenMatched() async throws {
        let host = GeneratedNote.MainActorHost(saveDriver: { draft in GeneratedNote.Saved(text: draft.text) })
        let s1 = try host.distinctSnapshots { snap -> Bool in
            if case .draft = snap { true } else { false }
        }
        #expect(await s1.wait(timeout: .zero) { $0 } == .matched(true))

        let s2 = try host.distinctSnapshots { snap -> Bool in
            if case .draft = snap { true } else { false }
        }
        #expect(await s2.wait(deadline: .now) { $0 } == .matched(true))
        #expect(host.subscriberCount == 0)
        await host.shutdown()
    }

    // MARK: - Shared, ActorHost, and IsolatedHost

    @Test func sharedHostWaitHandlesFutureMatchTimeoutCloseAndCleanup() async throws {
        let clock = ManualTestClock()
        let user = try UserID("kyle")
        let host = GeneratedProfile.Shared(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )

        // Future match: wait until phase leaves idle (or closes).
        let seq1 = try host.distinctSnapshots { snap -> Bool in
            if case .idle = snap { false } else { true }
        }
        let trigger1 = Task {
            await clock.waitUntilSleeping()
            _ = try? host.send(.load(ProfileRequest(userID: user)))
        }
        let r1 = await seq1.wait(deadline: clock.now.advanced(by: .seconds(10)), clock: clock) { $0 }
        await trigger1.value
        #expect(r1 == .matched(true))
        #expect(host.subscriberCount == 0)

        // Timeout.
        let seq2 = try host.distinctSnapshots { $0.isClosed }
        let trigger2 = Task {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(5))
        }
        let r2 = await seq2.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 }
        await trigger2.value
        #expect(r2 == .timedOut)
        #expect(host.subscriberCount == 0)

        // Host closed while waiting for a condition that never matches -> `.ended`.
        let seq3 = try host.distinctSnapshots { snap -> Bool in
            if case .loaded = snap { true } else { false }
        }
        let trigger3 = Task {
            await clock.waitUntilSleeping()
            _ = host.close()
        }
        let r3 = await seq3.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 }
        await trigger3.value
        #expect(r3 == .ended)
        #expect(host.subscriberCount == 0)

        await host.shutdown()
    }

    @Test func actorHostWaitHandlesAlreadyMatchingFutureMatchTimeoutAndClose() async throws {
        let clock = ManualTestClock()
        let user = try UserID("kyle")
        let host = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )

        // Already matching with expired deadline: ActorHost buffers initial snapshot synchronously.
        let seq0 = try await host.distinctSnapshots { snap -> Bool in
            if case .idle = snap { true } else { false }
        }
        #expect(await seq0.wait(deadline: clock.now, clock: clock) { $0 } == .matched(true))
        #expect(clock.totalSleepsStarted == 0)
        #expect(await host.subscriberCount == 0)

        // Timeout.
        let seq1 = try await host.distinctSnapshots { $0.isClosed }
        let expire = Task {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(5))
        }
        #expect(await seq1.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 } == .timedOut)
        await expire.value
        #expect(await host.subscriberCount == 0)

        // Close while waiting for `.isClosed` -> `.matched(true)`.
        let seq2 = try await host.distinctSnapshots { $0.isClosed }
        let closer = Task {
            await clock.waitUntilSleeping()
            _ = await host.close()
        }
        #expect(await seq2.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { $0 } == .matched(true))
        await closer.value
        #expect(await host.subscriberCount == 0)

        await host.shutdown()
    }

    @Test func isolatedHostWaitWorksOnCustomActor() async throws {
        let actor = NoteActor()
        try await actor.verifyIsolatedWait()
    }
}
