import StateMachine
import StateMachineTesting
import Testing

// Consuming a backlog of started calls oldest first with unfiltered waits costs work linear in the
// backlog: each wait takes the oldest unclaimed call without examining the rest. Waits queued before
// any call are answered in linear work too, and long traffic that alternates between a call and a wait
// keeps storage bounded by what is still live, for both matchers.

/// An actor that owns an isolated driver and consumes a backlog of its calls.
private actor Desk {
    let driver = IsolatedControlledDriver<Desk, Int, Int, Never>()

    /// Starts `count` calls, waits until all have started, then takes and finishes each in order.
    func consumeBacklog(of count: Int) async throws -> (order: [Int], examined: Int) {
        var running: [Task<Void, Never>] = []
        for input in 0 ..< count {
            running.append(Task { _ = await driver.run(self, input) })
        }
        while driver.startedCount < count { await Task.yield() }
        let before = driver.examinedCallEntries
        var order: [Int] = []
        for _ in 0 ..< count {
            let call = try await driver.nextStarted()
            order.append(call.input())
            call.succeed(call.input())
        }
        let examined = driver.examinedCallEntries - before
        for task in running { await task.value }
        return (order, examined)
    }

    /// Queues `count` unfiltered waits, then starts `count` calls, which answer them in order.
    func answerQueuedWaits(_ count: Int) async throws -> (answered: Int, examined: Int, stored: Int) {
        var waiting: [Task<Int, any Error>] = []
        for _ in 0 ..< count {
            waiting.append(
                Task {
                    let call = try await driver.nextStarted()
                    call.succeed(call.input())
                    return call.input()
                }
            )
        }
        while driver.waitingCount < count { await Task.yield() }
        let before = driver.examinedCallEntries
        var running: [Task<Void, Never>] = []
        for input in 0 ..< count { running.append(Task { _ = await driver.run(self, input) }) }
        var answered: Set<Int> = []
        for wait in waiting { answered.insert(try await wait.value) }
        for task in running { await task.value }
        return (answered.count, driver.examinedCallEntries - before, driver.storedCallEntries)
    }

    /// Alternates `count` times between starting one call and taking it, finishing each before the
    /// next, half of the time waiting first, and returns the most entries the driver stored.
    func alternate(_ count: Int) async throws -> (examined: Int, stored: Int) {
        let before = driver.examinedCallEntries
        var stored = 0
        for input in 0 ..< count {
            if input.isMultiple(of: 2) {
                let running = Task { _ = await driver.run(self, input) }
                let call = try await driver.nextStarted()
                call.succeed(call.input())
                await running.value
            } else {
                let waiting = Task {
                    let call = try await driver.nextStarted()
                    call.succeed(call.input())
                }
                while driver.waitingCount == 0 { await Task.yield() }
                let running = Task { _ = await driver.run(self, input) }
                try await waiting.value
                await running.value
            }
            stored = max(stored, driver.storedCallEntries)
        }
        return (driver.examinedCallEntries - before, stored)
    }
}

@Suite(.timeLimit(.minutes(1))) struct MatchingWorkTests {
    // Every call starts before any wait, so the waits find a backlog of the whole count.
    @Test func unfilteredWaitsConsumeASharedDriversBacklogInLinearWork() async throws {
        let count = 1_000
        let driver = ControlledDriver<Int, Int, Never>()
        var running: [Task<Void, Never>] = []
        for input in 0 ..< count {
            running.append(Task { _ = await driver.run(input) })
        }
        while driver.startedCount < count { await Task.yield() }
        let before = driver.examinedCallEntries
        var inputs: [Int] = []
        for _ in 0 ..< count {
            let call = try await driver.nextStarted()
            inputs.append(call.input)
            call.succeed(call.input)
        }
        let examined = driver.examinedCallEntries - before
        for task in running { await task.value }
        #expect(Set(inputs).count == count)
        #expect(examined <= 4 * count, "\(examined)")
    }

    // Every wait registers before any call starts, so each call finds every earlier wait answered.
    @Test func queuedWaitsAreAnsweredByASharedDriversCallsInLinearWork() async throws {
        let count = 1_000
        let driver = ControlledDriver<Int, Int, Never>()
        var waiting: [Task<Int, any Error>] = []
        for _ in 0 ..< count {
            waiting.append(
                Task {
                    let call = try await driver.nextStarted()
                    call.succeed(call.input)
                    return call.input
                }
            )
        }
        while driver.waitingCount < count { await Task.yield() }
        let before = driver.examinedCallEntries
        var running: [Task<Void, Never>] = []
        for input in 0 ..< count { running.append(Task { _ = await driver.run(input) }) }
        var answered: Set<Int> = []
        for wait in waiting { answered.insert(try await wait.value) }
        for task in running { await task.value }
        let examined = driver.examinedCallEntries - before
        #expect(answered.count == count)
        #expect(examined <= 4 * count, "\(examined)")
        #expect(driver.storedCallEntries <= 2, "\(driver.storedCallEntries)")
    }

    @Test func queuedWaitsAreAnsweredByAnIsolatedDriversCallsInLinearWork() async throws {
        let count = 1_000
        let (answered, examined, stored) = try await Desk().answerQueuedWaits(count)
        #expect(answered == count)
        #expect(examined <= 4 * count, "\(examined)")
        #expect(stored <= 2, "\(stored)")
    }

    // One call at a time, taken by a wait that came first or second, thousands of times: the driver
    // stores no more than a few entries, and matching examines a few each time.
    @Test func alternatingTrafficKeepsASharedDriversStorageBounded() async throws {
        let count = 2_000
        let driver = ControlledDriver<Int, Int, Never>()
        let before = driver.examinedCallEntries
        var stored = 0
        for input in 0 ..< count {
            let running: Task<Void, Never>
            let call: ControlledDriver<Int, Int, Never>.Call
            if input.isMultiple(of: 2) {
                running = Task { _ = await driver.run(input) }
                call = try await driver.nextStarted()
            } else {
                let waiting = Task { try await driver.nextStarted() }
                while driver.waitingCount == 0 { await Task.yield() }
                running = Task { _ = await driver.run(input) }
                call = try await waiting.value
            }
            call.succeed(call.input)
            await running.value
            stored = max(stored, driver.storedCallEntries)
        }
        let examined = driver.examinedCallEntries - before
        #expect(stored <= 4, "\(stored)")
        #expect(examined <= 4 * count, "\(examined)")
    }

    @Test func alternatingTrafficKeepsAnIsolatedDriversStorageBounded() async throws {
        let count = 2_000
        let (examined, stored) = try await Desk().alternate(count)
        #expect(stored <= 4, "\(stored)")
        #expect(examined <= 4 * count, "\(examined)")
    }

    @Test func unfilteredWaitsConsumeAnIsolatedDriversBacklogInLinearWork() async throws {
        let count = 1_000
        let (order, examined) = try await Desk().consumeBacklog(of: count)
        #expect(Set(order).count == count)
        #expect(examined <= 4 * count, "\(examined)")
    }
}
