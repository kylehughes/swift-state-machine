/// Admits one caller at a time to code that parks a cooperative-pool thread.
///
/// Some tests hold a synchronous production callback claimed by blocking it on a semaphore, and
/// the test body that releases it needs a cooperative thread to resume. The pool is process-wide
/// and as narrow as the machine's core count, so unrelated suites doing this in parallel can park
/// every thread and stall until their safety timeouts expire. Waiting here suspends without parking
/// a thread itself.
private actor CooperativeThreadHold {
    static let shared = CooperativeThreadHold()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }
        isHeld = false
    }
}

/// Runs an operation while it alone, across every test target in the process, may park a
/// cooperative-pool thread.
///
/// This module stays free of the Testing library so it builds for every platform. Each test
/// target wraps this function in its own `parksCooperativeThread` trait.
public func withExclusiveCooperativeThreadHold(_ operation: @Sendable () async throws -> Void) async throws {
    await CooperativeThreadHold.shared.acquire()
    do {
        try await operation()
    } catch {
        await CooperativeThreadHold.shared.release()
        throw error
    }
    await CooperativeThreadHold.shared.release()
}

/// The hold of a long operation that runs as a series of steps, each of which may park a
/// cooperative-pool thread and lets it go before it returns.
///
/// Holding the exclusion for the whole operation would make every other test that parks a thread wait
/// for all of it, past its own time limit. ``yieldIfDue()`` lets the waiting tests take their turn
/// between two steps once the operation has held the exclusion for its interval.
public struct CooperativeThreadHoldTurns: Sendable {
    private let interval: Duration
    private var since: ContinuousClock.Instant

    fileprivate init(interval: Duration) {
        self.interval = interval
        self.since = .now
    }

    /// Lets the tests waiting for the exclusion run, once the operation has held it for its interval.
    ///
    /// It takes the exclusion back before it returns. Call it only between two steps, while no thread
    /// of the operation is parked.
    public mutating func yieldIfDue(isolation: isolated (any Actor)? = #isolation) async {
        guard since.duration(to: .now) >= interval else { return }
        await CooperativeThreadHold.shared.release()
        await CooperativeThreadHold.shared.acquire()
        since = .now
    }
}

/// Runs a long operation, made of steps that each may park a cooperative-pool thread, while it alone
/// may park one, giving up the exclusion between two steps at most once per interval.
///
/// The operation calls ``CooperativeThreadHoldTurns/yieldIfDue()`` between its steps.
public func withExclusiveCooperativeThreadHold<Value>(
    takingTurnsEvery interval: Duration,
    isolation: isolated (any Actor)? = #isolation,
    _ operation: (inout CooperativeThreadHoldTurns) async throws -> Value
) async rethrows -> Value {
    await CooperativeThreadHold.shared.acquire()
    var turns = CooperativeThreadHoldTurns(interval: interval)
    do {
        let value = try await operation(&turns)
        await CooperativeThreadHold.shared.release()
        return value
    } catch {
        await CooperativeThreadHold.shared.release()
        throw error
    }
}
