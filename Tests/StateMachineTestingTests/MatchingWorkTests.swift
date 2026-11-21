import StateMachine
import StateMachineTesting
import Testing

// Consuming a backlog of started calls oldest first with unfiltered waits costs work linear in the
// backlog: each wait takes the oldest unclaimed call without examining the rest.

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

    @Test func unfilteredWaitsConsumeAnIsolatedDriversBacklogInLinearWork() async throws {
        let count = 1_000
        let (order, examined) = try await Desk().consumeBacklog(of: count)
        #expect(Set(order).count == count)
        #expect(examined <= 4 * count, "\(examined)")
    }
}
