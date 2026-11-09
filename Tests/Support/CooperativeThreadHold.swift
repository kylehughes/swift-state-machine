import Testing

/// Admits one test at a time to code that parks a cooperative-pool thread.
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

/// Serializes a test against every other test, in any suite, that parks a cooperative-pool thread.
public struct ParksCooperativeThreadTrait: TestTrait, SuiteTrait, TestScoping {
    /// Applies the scope to each test in a suite rather than to the suite as a whole.
    public var isRecursive: Bool { true }

    /// Runs the test while it alone may park a cooperative-pool thread.
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await CooperativeThreadHold.shared.acquire()
        do {
            try await function()
        } catch {
            await CooperativeThreadHold.shared.release()
            throw error
        }
        await CooperativeThreadHold.shared.release()
    }
}

extension Trait where Self == ParksCooperativeThreadTrait {
    /// Declares that the test blocks a cooperative-pool thread until its own body releases it.
    public static var parksCooperativeThread: Self { Self() }
}
