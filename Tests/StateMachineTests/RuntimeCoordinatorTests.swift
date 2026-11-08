import StateMachine
import Testing
import os

/// Announces continuation registration through a stream but deliberately ignores cancellation.
private final class CoordinatorGate: Sendable {
    private struct State {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    let entered: AsyncStream<Void>
    private let entry: AsyncStream<Void>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        let (entered, entry) = AsyncStream<Void>.makeStream()
        self.entered = entered
        self.entry = entry
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.released { return true }
                state.continuation = continuation
                return false
            }
            entry.yield(())
            if resume { continuation.resume() }
        }
    }

    func release() {
        let continuation = state.withLock { state in
            state.released = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

@Suite(.timeLimit(.minutes(1))) struct RuntimeCoordinatorTests {
    private typealias Core = RuntimeState<Int, Int>
    private let scope = RuntimeScopeID(kind: 1)

    private struct Events: Sendable {
        var calls: [Int] = []
        var skipped: [RuntimeTicket] = []
        var terminated: [RuntimeTicket] = []
        var outcomes: [Int] = []
        var authorityChecks = 0
    }

    private func engine() throws -> Core {
        Core(0, scopes: [scope], limits: try .init())
    }

    private func start(_ core: inout Core, descriptor: Int, kind: UInt32 = 1) throws -> RuntimeWork<Int> {
        let candidate = try Core.prepare(
            on: core.snapshot,
            next: descriptor,
            plan: .init(starts: [.init(.init(kind: kind, scope: scope), descriptor: descriptor)])
        )
        guard case .committed = core.commit(candidate),
            let batch = core.drain(limit: 1).first,
            case .start(let work) = batch.commands.last
        else {
            Issue.record("Expected committed raw work")
            throw SetupFailure.noWork
        }
        return work
    }

    private enum SetupFailure: Error { case noWork }

    @Test func revokedPrecheckSkipsWithoutCallingDriver() async throws {
        var core = try engine()
        let work = try start(&core, descriptor: 1)
        let events = OSAllocatedUnfairLock(initialState: Events())
        let coordinator = RuntimeCoordinator<Int, Int>(
            driver: { descriptor in
                events.withLock { $0.calls.append(descriptor) }
                return descriptor
            },
            authorized: { _ in false },
            terminated: { ticket, outcome, _ in
                events.withLock {
                    $0.terminated.append(ticket)
                    $0.outcomes.append(outcome)
                }
            },
            skipped: { ticket in events.withLock { $0.skipped.append(ticket) } }
        )
        await coordinator.start([work])
        await coordinator.join()
        #expect(await coordinator.runningCount == 0)
        let recorded = events.withLock { $0 }
        #expect(recorded.calls.isEmpty)
        #expect(recorded.skipped == [work.ticket])
        #expect(recorded.terminated.isEmpty)
    }

    @Test func cancellationRetainsInsensitiveDriverUntilActualTermination() async throws {
        var core = try engine()
        let work = try start(&core, descriptor: 7)
        let gate = CoordinatorGate()
        defer { gate.release() }
        var entered = gate.entered.makeAsyncIterator()
        let events = OSAllocatedUnfairLock(initialState: Events())
        let coordinator = RuntimeCoordinator<Int, Int>(
            driver: { descriptor in
                events.withLock { $0.calls.append(descriptor) }
                await gate.wait()
                return Task.isCancelled ? -descriptor : descriptor
            },
            authorized: { _ in true },
            terminated: { ticket, outcome, _ in
                events.withLock {
                    $0.terminated.append(ticket)
                    $0.outcomes.append(outcome)
                }
            },
            skipped: { ticket in events.withLock { $0.skipped.append(ticket) } }
        )
        await coordinator.start([work])
        _ = await entered.next()
        await coordinator.cancel([work.ticket, work.ticket])
        #expect(await coordinator.runningCount == 1)
        #expect(events.withLock { $0.terminated.isEmpty })
        gate.release()
        await coordinator.join()
        #expect(await coordinator.runningCount == 0)
        let recorded = events.withLock { $0 }
        #expect(recorded.calls == [7])
        #expect(recorded.terminated == [work.ticket])
        #expect(recorded.outcomes == [-7])
        #expect(recorded.skipped.isEmpty)
    }

    @Test func staleWorkerTerminationCannotRemoveReplacementHandle() async throws {
        var core = try engine()
        let old = try start(&core, descriptor: 1)
        let oldGate = CoordinatorGate()
        let replacementGate = CoordinatorGate()
        defer {
            oldGate.release()
            replacementGate.release()
        }
        var oldEntered = oldGate.entered.makeAsyncIterator()
        var replacementEntered = replacementGate.entered.makeAsyncIterator()
        let (terminated, termination) = AsyncStream<RuntimeTicket>.makeStream()
        defer { termination.finish() }
        var completions = terminated.makeAsyncIterator()
        let events = OSAllocatedUnfairLock(initialState: Events())
        let coordinator = RuntimeCoordinator<Int, Int>(
            driver: { descriptor in
                if descriptor == 1 { await oldGate.wait() } else { await replacementGate.wait() }
                return descriptor
            },
            authorized: { _ in true },
            terminated: { ticket, outcome, _ in
                events.withLock {
                    $0.terminated.append(ticket)
                    $0.outcomes.append(outcome)
                }
                termination.yield(ticket)
            },
            skipped: { _ in Issue.record("Authorized replacement was skipped") }
        )
        await coordinator.start([old])
        _ = await oldEntered.next()
        let replacement = try start(&core, descriptor: 2)
        #expect(old.ticket != replacement.ticket)
        #expect(!core.isActive(old.ticket))
        #expect(core.isActive(replacement.ticket))
        await coordinator.cancel([old.ticket])
        await coordinator.start([replacement])
        _ = await replacementEntered.next()
        #expect(await coordinator.runningCount == 2)
        oldGate.release()
        #expect(await completions.next() == old.ticket)
        #expect(await coordinator.runningCount == 1)
        #expect(events.withLock { $0.terminated } == [old.ticket])
        replacementGate.release()
        await coordinator.join()
        #expect(await coordinator.runningCount == 0)
        #expect(events.withLock { $0.terminated } == [old.ticket, replacement.ticket])
        #expect(events.withLock { $0.outcomes } == [1, 2])
    }

    @Test func immediateCompletionAfterRegistrationLeavesNoHandles() async throws {
        var core = try engine()
        var works: [RuntimeWork<Int>] = []
        for kind in UInt32(1) ... 32 { works.append(try start(&core, descriptor: Int(kind), kind: kind)) }
        let events = OSAllocatedUnfairLock(initialState: Events())
        let coordinator = RuntimeCoordinator<Int, Int>(
            driver: { $0 },
            authorized: { _ in true },
            terminated: { ticket, outcome, _ in
                events.withLock {
                    $0.terminated.append(ticket)
                    $0.outcomes.append(outcome)
                }
            },
            skipped: { _ in Issue.record("Authorized immediate worker was skipped") }
        )
        await coordinator.start(works)
        await coordinator.join()
        #expect(await coordinator.runningCount == 0)
        let recorded = events.withLock { $0 }
        #expect(recorded.outcomes.sorted() == Array(1 ... 32))
        #expect(recorded.terminated.count == works.count)
        for work in works { #expect(recorded.terminated.filter { $0 == work.ticket }.count == 1) }
    }

    @Test func revocationAtPostcheckCancelsRegisteredHandleUntilDriverReturns() async throws {
        var core = try engine()
        let work = try start(&core, descriptor: 9)
        let gate = CoordinatorGate()
        defer { gate.release() }
        var entered = gate.entered.makeAsyncIterator()
        let events = OSAllocatedUnfairLock(initialState: Events())
        let coordinator = RuntimeCoordinator<Int, Int>(
            driver: { descriptor in
                events.withLock { $0.calls.append(descriptor) }
                await gate.wait()
                return Task.isCancelled ? -descriptor : descriptor
            },
            authorized: { _ in
                events.withLock {
                    $0.authorityChecks += 1
                    return $0.authorityChecks == 1
                }
            },
            terminated: { ticket, outcome, _ in
                events.withLock {
                    $0.terminated.append(ticket)
                    $0.outcomes.append(outcome)
                }
            },
            skipped: { ticket in events.withLock { $0.skipped.append(ticket) } }
        )
        await coordinator.start([work])
        _ = await entered.next()
        #expect(events.withLock { $0.authorityChecks } == 2)
        #expect(await coordinator.runningCount == 1)
        #expect(events.withLock { $0.terminated.isEmpty && $0.skipped.isEmpty })
        gate.release()
        await coordinator.join()
        #expect(await coordinator.runningCount == 0)
        let recorded = events.withLock { $0 }
        #expect(recorded.calls == [9])
        #expect(recorded.terminated == [work.ticket])
        #expect(recorded.outcomes == [-9])
        #expect(recorded.skipped.isEmpty)
    }
}
