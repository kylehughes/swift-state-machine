import StateMachine
import StateMachineTesting
import Testing

// A test that repeatedly waits for a started call and cancels the wait before any call starts leaves
// nothing that grows: the waits that ended unanswered are dropped once they outnumber the live ones, in
// both matchers, so the stored entries stay bounded however many waits were cancelled.

/// Waits until `condition` holds, yielding in between, for at most ten seconds.
private func yielding(until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition(), ContinuousClock.now < deadline {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// An actor that owns an isolated driver and cancels waits on it.
private actor Bench {
    let driver = IsolatedControlledDriver<Bench, Int, Int, Never>()

    /// Starts and cancels `count` waits, one at a time, and returns the most entries stored after one.
    func cancelWaits(_ count: Int) async throws -> (stored: Int, waiting: Int) {
        var stored = 0
        for _ in 0 ..< count {
            let wait = Task { (try? await driver.nextStarted()) != nil }
            while driver.waitingCount != 1 {
                try Task.checkCancellation()
                await Task.yield()
            }
            wait.cancel()
            _ = await wait.value
            stored = max(stored, driver.storedCallEntries)
        }
        return (stored, driver.waitingCount)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CancelledWaitStorageTests {
    @Test func cancelledWaitsDoNotAccumulateInTheDriver() async throws {
        let driver = ControlledDriver<Int, Int, Never>()
        var stored = 0
        for _ in 0 ..< 200 {
            let wait = Task { try? await driver.nextStarted() }
            try await yielding { driver.waitingCount == 1 }
            wait.cancel()
            _ = await wait.value
            stored = max(stored, driver.storedCallEntries)
        }
        #expect(driver.waitingCount == 0)
        #expect(driver.startedCount == 0)
        #expect(stored <= 32, "\(stored)")
    }

    @Test func cancelledWaitsDoNotAccumulateInTheIsolatedDriver() async throws {
        let (stored, waiting) = try await Bench().cancelWaits(200)
        #expect(waiting == 0)
        #expect(stored <= 32, "\(stored)")
    }
}
