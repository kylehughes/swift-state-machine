/// Admits one caller at a time to code that parks a cooperative-pool thread.
///
/// Some tests hold a synchronous production callback claimed by blocking it on a semaphore, and
/// the test body that releases it needs a cooperative thread to resume. The pool is process-wide
/// and as narrow as the machine's core count, so unrelated suites doing this in parallel can park
/// every thread and stall until their safety timeouts expire. Waiting here suspends; it never
/// parks a thread itself.
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
/// This module stays free of the Testing library so that it builds for every platform; each test
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
