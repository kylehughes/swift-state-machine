import StateMachine
import os

/// Hands each started call to the test that awaits it, in start order.
///
/// A wait may accept only the calls that match a predicate, such as one key's calls, while any call
/// that no waiting test accepts stays queued until a matching wait arrives. A test whose task is
/// cancelled while it waits receives `nil` and leaves later calls for the next wait.
///
/// Predicates are test code, such as a key's equality, so they run outside the queue's lock. Matching
/// still happens in one order. Each started call and each new wait is recorded as an arrival, and one
/// matcher at a time processes arrivals in the order they happened, so a call goes to the oldest
/// waiting test that accepts it and a wait receives the oldest unclaimed call it accepts, as if every
/// arrival were matched the moment it happened. Whichever offer or wait finds no matcher running
/// becomes the matcher and stops once no arrival is left.
///
/// A match records the call as the wait's answer under the lock, and the continuation only wakes the
/// wait, which takes its answer under the lock once it resumes. The Swift runtime does not report to
/// Thread Sanitizer the ordering of a continuation resumed before its task suspends, so a call
/// carried in that resumption would look unsynchronized with the thread that started it. The lock
/// orders the two in a way the sanitizer observes.
nonisolated package final class CallQueue<Call: Sendable>: Sendable {
    private struct Waiter: Sendable {
        /// The calls the wait accepts, or `nil` for a wait that accepts every call.
        let accepts: (@Sendable (Call) -> Bool)?
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Where one wait is between its registration and its result.
    private enum Wait: Sendable {
        /// The wait has an identifier but has not installed its continuation.
        case registering
        /// The task was cancelled before the wait installed its continuation.
        case cancelledWhileRegistering
        /// The wait is installed and unanswered.
        case waiting(Waiter)
        /// A match gave the wait this call, which it takes once it resumes.
        case answered(Call)
    }

    /// A started call or a new wait, in the order they happened.
    private enum Arrival: Sendable {
        case call(UInt64)
        case wait(UInt64)
    }

    /// What matching a new wait found under the lock.
    private enum Found {
        /// The wait ended, or no call is unclaimed and it waits.
        case none
        /// The wait accepts every call and was answered with the oldest unclaimed one.
        case taken(Waiter)
        /// The unclaimed calls in start order, for the wait's predicate to examine outside the lock.
        case candidates(@Sendable (Call) -> Bool, [(UInt64, Call)])
    }

    private struct State: Sendable {
        /// Every started call no wait has claimed, by identifier.
        var calls: [UInt64: Call] = [:]
        /// The matched calls that no wait accepted in start order, skipping any already claimed.
        var unclaimed = ArrivalQueue<UInt64>()
        /// Every wait that has not ended.
        var waits: [UInt64: Wait] = [:]
        /// The matched waits that no call answered in registration order, skipping any already ended.
        var unanswered = ArrivalQueue<UInt64>()
        /// The arrivals the matcher has not taken, oldest first.
        var arrivals = ArrivalQueue<Arrival>()
        var isMatching = false
        var nextWait: UInt64 = 0
        var nextCall: UInt64 = 0
        var started = 0

        /// Records an arrival and reports whether the caller must become the matcher.
        mutating func arrive(_ arrival: Arrival) -> Bool {
            arrivals.append(arrival)
            guard !isMatching else { return false }
            isMatching = true
            return true
        }

        /// Answers a wait that is still unanswered with `call`, returning the waiter to resume.
        ///
        /// The waiter is returned rather than released here, so its predicate is released outside the
        /// lock.
        mutating func answer(_ wait: UInt64, with call: Call) -> Waiter? {
            guard case .waiting(let waiter) = waits[wait] else { return nil }
            waits[wait] = .answered(call)
            return waiter
        }

        /// Whether a wait is installed and unanswered.
        func isWaiting(_ wait: UInt64) -> Bool {
            guard case .waiting = waits[wait] else { return false }
            return true
        }

        /// The entries matching has examined.
        var examined: Int { unclaimed.examined + unanswered.examined }
        /// The entries the queues of calls and waits store.
        var stored: Int { unclaimed.storedCount + unanswered.storedCount }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let beforeSuspending: (@Sendable () -> Void)?

    /// Creates a queue with no started calls.
    ///
    /// `beforeSuspending` runs in each wait after it has arrived, and finished matching if it became
    /// the matcher, and before it suspends, so a test of the queue can hold a wait in that interval.
    package init(beforeSuspending: (@Sendable () -> Void)? = nil) {
        self.beforeSuspending = beforeSuspending
    }

    /// How many calls have started.
    var startedCount: Int { state.withLock { $0.started } }

    /// How many queued calls and waits matching has examined, which tests read as its work.
    var examinedEntries: Int { state.withLock { $0.examined } }
    /// How many queued calls and waits the queues store, ended ones included, which tests read as
    /// their storage.
    var storedEntries: Int { state.withLock { $0.stored } }
    /// How many waits have registered and not ended.
    var waitCount: Int { state.withLock { $0.waits.count } }

    /// Records a started call and hands it to the oldest waiting test that accepts it, if any.
    package func offer(_ call: Call) {
        let matches = state.withLock { state -> Bool in
            state.started += 1
            state.nextCall += 1
            state.calls[state.nextCall] = call
            return state.arrive(.call(state.nextCall))
        }
        if matches { match() }
    }

    /// Returns the oldest unclaimed call that `accepts` matches (or the oldest unclaimed call when
    /// `accepts` is `nil`) once one has started, or `nil` if the waiting task is cancelled.
    package func next(where accepts: (@Sendable (Call) -> Bool)? = nil) async -> Call? {
        let id = state.withLock { state -> UInt64 in
            state.nextWait += 1
            state.waits[state.nextWait] = .registering
            return state.nextWait
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let matches = state.withLock { state -> Bool? in
                    guard case .registering = state.waits[id] else {
                        // Cancelled first, so the wait ends without arriving.
                        state.waits[id] = nil
                        return nil
                    }
                    state.waits[id] = .waiting(Waiter(accepts: accepts, continuation: continuation))
                    return state.arrive(.wait(id))
                }
                switch matches {
                case nil: continuation.resume()
                case true?: match()
                case false?: break
                }
                beforeSuspending?()
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                switch state.waits[id] {
                case .registering?:
                    state.waits[id] = .cancelledWhileRegistering
                    return nil
                case .waiting(let waiter)?:
                    state.waits[id] = nil
                    return waiter
                // Answered or already ended, so the first outcome stands.
                case .answered?, .cancelledWhileRegistering?, nil: return nil
                }
            }
            waiter?.continuation.resume()
        }
        // A match left the wait's call in its entry, while a cancellation removed the entry. A wait
        // that ended unanswered stays queued until ended waits outnumber live ones.
        let outcome = state.withLock { state in
            let outcome = state.waits.removeValue(forKey: id)
            var unanswered = exchange(&state.unanswered, with: ArrivalQueue())
            defer { state.unanswered = unanswered }
            unanswered.reclaim(keeping: state.waits.count) { state.isWaiting($0) }
            return outcome
        }
        guard case .answered(let call)? = outcome else { return nil }
        return call
    }

    /// Takes arrivals in order until none is left, then stops being the matcher.
    private func match() {
        while let arrival = state.withLock({ state -> Arrival? in
            guard let first = state.arrivals.first else {
                state.isMatching = false
                return nil
            }
            return first
        }) {
            switch arrival {
            case .call(let id): matchCall(id)
            case .wait(let id): matchWait(id)
            }
        }
    }

    /// Hands a started call to the oldest matched wait that accepts it, or leaves it unclaimed.
    ///
    /// Only the matcher claims, so the call stays unclaimed while its predicates run. A candidate
    /// wait can end only by cancellation, in which case the call goes to the next one. The candidates
    /// end at the oldest wait that accepts every call, which needs no predicate.
    private func matchCall(_ id: UInt64) {
        // A candidate that accepted the call but ended meanwhile lets a later wait, beyond the oldest
        // that accepts every call, take it, so the candidates are read again.
        var ended = true
        while ended {
            ended = false
            let (call, candidates) = state.withLock { state -> (Call, [(UInt64, (@Sendable (Call) -> Bool)?)]) in
                // The queue is moved out while it reads the waits, so neither is copied.
                var unanswered = exchange(&state.unanswered, with: ArrivalQueue())
                defer { state.unanswered = unanswered }
                let candidates = unanswered.live(
                    where: { state.isWaiting($0) },
                    through: { if case .waiting(let waiter) = state.waits[$0] { waiter.accepts == nil } else { false } }
                )
                return (
                    state.calls[id]!,
                    candidates.map { wait -> (UInt64, (@Sendable (Call) -> Bool)?) in
                        guard case .waiting(let waiter) = state.waits[wait] else { return (wait, { _ in false }) }
                        return (wait, waiter.accepts)
                    }
                )
            }
            for (wait, accepts) in candidates where accepts?(call) ?? true {
                let waiter = state.withLock { state -> Waiter? in
                    guard let waiter = state.answer(wait, with: call) else { return nil }
                    state.calls[id] = nil
                    state.arrivals.removeFirst()
                    return waiter
                }
                if let waiter {
                    waiter.continuation.resume()
                    return
                }
                ended = true
            }
        }
        state.withLock { state in
            state.arrivals.removeFirst()
            state.unclaimed.append(id)
        }
    }

    /// Gives a new wait the oldest unclaimed call it accepts, or leaves it waiting.
    ///
    /// A wait that accepts every call takes the oldest unclaimed one under the lock. Otherwise only the
    /// matcher claims, so every unclaimed call stays available while the predicate runs outside the
    /// lock, and the wait can end only by cancellation.
    private func matchWait(_ id: UInt64) {
        let found = state.withLock { state -> Found in
            guard case .waiting(let waiter) = state.waits[id] else {
                state.arrivals.removeFirst()
                return .none
            }
            // The queue is moved out while it reads the calls, so neither is copied.
            var unclaimed = exchange(&state.unclaimed, with: ArrivalQueue())
            defer { state.unclaimed = unclaimed }
            guard let accepts = waiter.accepts else {
                guard let call = unclaimed.oldest(where: { state.calls[$0] != nil }) else {
                    state.arrivals.removeFirst()
                    state.unanswered.append(id)
                    return .none
                }
                state.arrivals.removeFirst()
                return .taken(state.answer(id, with: state.calls.removeValue(forKey: call)!)!)
            }
            return .candidates(
                accepts,
                unclaimed.live(where: { state.calls[$0] != nil }).map { ($0, state.calls[$0]!) }
            )
        }
        let (accepts, unclaimed): (@Sendable (Call) -> Bool, [(UInt64, Call)])
        switch found {
        case .none: return
        case .taken(let waiter):
            waiter.continuation.resume()
            return
        case .candidates(let predicate, let calls): (accepts, unclaimed) = (predicate, calls)
        }
        for (call, value) in unclaimed where accepts(value) {
            let waiter = state.withLock { state -> Waiter? in
                state.arrivals.removeFirst()
                guard let waiter = state.answer(id, with: value) else { return nil }
                state.calls[call] = nil
                return waiter
            }
            waiter?.continuation.resume()
            return
        }
        state.withLock { state in
            state.arrivals.removeFirst()
            if state.isWaiting(id) { state.unanswered.append(id) }
        }
    }
}

/// Records that the host cancelled one driver call's task, and wakes the tests waiting for it.
///
/// Each wait ends with whichever happens first, either the driver call's cancellation (answering
/// `true`) or cancellation of the waiting task (answering `false`). Every wait's progress lives under
/// the signal's one lock, and each of those events decides the answers it settles inside that lock,
/// so whichever reaches the lock first is the answer, and a wait that had begun when ``isCancelled``
/// reads `true` has already been answered `true`. Suspended waits are resumed after the lock is
/// released.
///
/// A wait begins once it has armed its task's cancellation handler and registered. A wait whose task
/// is cancelled before it begins answers `false`, as a wait for a call does, even when the driver
/// call's cancellation also came before it began. Otherwise a wait that begins after the driver
/// call's cancellation answers `true` at once regardless of what its task does afterward.
nonisolated package final class CancellationSignal: Sendable {
    /// Where one wait is between its arrival and its answer.
    private enum Wait: Sendable {
        /// The wait has an identifier and is arming its task's cancellation handler.
        case arming
        /// The wait has begun and has not suspended.
        case begun
        /// The wait is suspended and unanswered.
        case suspended(CheckedContinuation<Bool, Never>)
        /// The wait was answered before it suspended.
        case answered(Bool)
    }

    private struct State: Sendable {
        var cancelled = false
        /// Every wait that has arrived and has not returned its answer.
        var waits: [UInt64: Wait] = [:]
        var nextWait: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let beforeArming: (@Sendable () async -> Void)?
    private let afterBeginning: (@Sendable () async -> Void)?

    /// Creates a signal for one driver call.
    ///
    /// `beforeArming` runs in each wait after it is entered and before it arms its cancellation
    /// handler, and `afterBeginning` after the wait has begun and before it suspends, so a test of the
    /// signal can hold a wait in either interval.
    package init(
        beforeArming: (@Sendable () async -> Void)? = nil,
        afterBeginning: (@Sendable () async -> Void)? = nil
    ) {
        self.beforeArming = beforeArming
        self.afterBeginning = afterBeginning
    }

    /// Whether the driver call's task has been cancelled.
    package var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Records the cancellation and answers every wait that has begun.
    ///
    /// Called from the driver task's cancellation handler.
    package func cancel() {
        let suspended = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            guard !state.cancelled else { return [] }
            state.cancelled = true
            var suspended: [CheckedContinuation<Bool, Never>] = []
            for (id, wait) in state.waits {
                switch wait {
                case .begun: state.waits[id] = .answered(true)
                case .suspended(let continuation):
                    state.waits[id] = nil
                    suspended.append(continuation)
                // A wait still arming begins later and finds the flag set, unless its task is cancelled first.
                case .arming, .answered: break
                }
            }
            return suspended
        }
        for continuation in suspended { continuation.resume(returning: true) }
    }

    /// Returns `true` once the driver call's task is cancelled, or `false` if the waiting task is cancelled first.
    package func wait() async -> Bool {
        if Task.isCancelled { return false }
        await beforeArming?()
        let id = state.withLock { state -> UInt64 in
            state.nextWait += 1
            state.waits[state.nextWait] = .arming
            return state.nextWait
        }
        return await withTaskCancellationHandler {
            // The handler is armed, so a cancellation of the waiting task that came earlier has already
            // answered this wait, and one that comes later finds it begun.
            state.withLock { state in
                guard case .arming = state.waits[id] else { return }
                state.waits[id] = state.cancelled ? .answered(true) : .begun
            }
            await afterBeginning?()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let answer = state.withLock { state -> Bool? in
                    guard case .answered(let answer) = state.waits[id] else {
                        state.waits[id] = .suspended(continuation)
                        return nil
                    }
                    state.waits[id] = nil
                    return answer
                }
                if let answer { continuation.resume(returning: answer) }
            }
        } onCancel: {
            let suspended = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                switch state.waits[id] {
                case .arming?, .begun?:
                    state.waits[id] = .answered(false)
                    return nil
                case .suspended(let continuation)?:
                    state.waits[id] = nil
                    return continuation
                // Answered already, so the first answer stands.
                case .answered?, nil: return nil
                }
            }
            suspended?.resume(returning: false)
        }
    }
}

/// The result a test chooses for one driver call, which the suspended driver returns.
///
/// The test stores the result under the lock and the continuation only wakes the driver, which takes
/// the result under the lock once it resumes, so Thread Sanitizer observes the hand-off even when
/// the test chooses the result before the driver suspends, as ``CallQueue`` explains.
nonisolated package final class ResultSlot<Output: Sendable, Failure: Error>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var result: Result<Output, Failure>?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a slot whose result is not chosen.
    package init() {}

    /// Whether the test has chosen the result.
    package var isFinished: Bool { state.withLock { $0.finished } }

    /// Suspends the driver until the test chooses its result.
    ///
    /// Cancellation does not end the wait.
    package func wait(afterInstalling started: @Sendable () -> Void) async -> Result<Output, Failure> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                guard !state.finished else { return true }
                state.continuation = continuation
                return false
            }
            if ready { continuation.resume() }
            started()
        }
        // The test stored the result before it woke the driver, and the driver takes it once.
        return state.withLock { $0.result.take()! }
    }

    /// Chooses the result once, reporting whether this call chose it.
    package func finish(_ result: Result<Output, Failure>) -> Bool {
        let chosen = state.withLock { state -> (Bool, CheckedContinuation<Void, Never>?) in
            guard !state.finished else { return (false, nil) }
            state.finished = true
            state.result = result
            defer { state.continuation = nil }
            return (true, state.continuation)
        }
        chosen.1?.resume()
        return chosen.0
    }
}

/// Waits for a driver call's cancellation, failing at the caller's location when the waiting task ends first.
nonisolated func awaitCancellation(
    _ signal: CancellationSignal,
    fileID: String,
    filePath: String,
    line: Int,
    column: Int
) async throws(StateMachineTestFailure) {
    guard await signal.wait() else {
        throw StateMachineTestFailure(
            "The test's task was cancelled before the host cancelled the driver call",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

/// Waits for the next started call that `accepts` matches, failing at the caller's location when the
/// waiting task ends first.
nonisolated func awaitNextCall<Call: Sendable>(
    _ calls: CallQueue<Call>,
    where accepts: (@Sendable (Call) -> Bool)? = nil,
    awaited description: String = "another call",
    fileID: String,
    filePath: String,
    line: Int,
    column: Int
) async throws(StateMachineTestFailure) -> Call {
    guard let call = await calls.next(where: accepts) else {
        throw StateMachineTestFailure(
            "The test's task was cancelled before the driver started \(description)",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
    return call
}
