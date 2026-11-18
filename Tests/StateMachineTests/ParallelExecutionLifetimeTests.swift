import StateMachine
import Testing
import os

/// A one-worker gate that deliberately does not observe task cancellation.
private final class ParallelWorkerGate: Sendable {
    private struct State {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered: AsyncStream<Void>
    private let entry: AsyncStream<Void>.Continuation

    init() {
        (entered, entry) = AsyncStream<Void>.makeStream()
    }

    func wait() async {
        await withCheckedContinuation { waiter in
            let released = state.withLock { state in
                guard !state.released else { return true }
                state.waiter = waiter
                return false
            }
            entry.yield(())
            if released { waiter.resume() }
        }
    }

    func release() {
        let waiter = state.withLock { state in
            state.released = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

@Suite(.timeLimit(.minutes(1))) struct ParallelExecutionLifetimeTests {
    private typealias Core = RuntimeState<Int, Int>
    private enum Failure: Error { case unexpected }

    @Test func parallelAuthorityRevocationRetainsThreePhysicalWorkers_RT039() async throws {
        let scope = RuntimeScopeID(kind: 1)
        let operation = RuntimeOperation(kind: 1, scope: scope, policy: .parallel(2))
        let storage = OSAllocatedUnfairLock(
            initialState: Core(0, scopes: [scope], limits: try .init(executions: 4))
        )
        let gates = [ParallelWorkerGate(), ParallelWorkerGate(), ParallelWorkerGate()]
        defer { for gate in gates { gate.release() } }
        let (terminations, terminated) = AsyncStream<RuntimeTicket>.makeStream()
        defer { terminated.finish() }
        var completions = terminations.makeAsyncIterator()
        let returned = OSAllocatedUnfairLock(initialState: [RuntimeTicket]())
        let coordinator = RuntimeCoordinator<Int, Int>(
            driver: { value in
                await gates[value].wait()
                return value
            },
            authorized: { ticket in storage.withLock { $0.isActive(ticket) } },
            terminated: { ticket, _, _ in
                #expect(storage.withLock { $0.acknowledge(ticket) } == .recorded)
                returned.withLock { $0.append(ticket) }
                terminated.yield(ticket)
            },
            skipped: { _ in Issue.record("Expected each admitted worker to start") }
        )
        func admit(_ values: [Int], retiring: [RuntimeTicket] = []) throws -> Core.Batch {
            let snapshot = storage.withLock { $0.snapshot }
            let candidate = try Core.prepare(
                on: snapshot,
                next: snapshot.model + 1,
                plan: .init(retire: retiring, starts: values.map { .init(operation, descriptor: $0) })
            )
            return try storage.withLock { core in
                guard case .committed = core.commit(candidate), let batch = core.drain(limit: 1).first else {
                    throw Failure.unexpected
                }
                return batch
            }
        }
        func starts(_ batch: Core.Batch) -> [RuntimeWork<Int>] {
            batch.commands.compactMap {
                if case .start(let work) = $0 { return work }
                return nil
            }
        }
        do {
            let initial = starts(try admit([0, 1]))
            #expect(initial.count == 2)
            await coordinator.start(initial)
            for gate in gates.prefix(2) {
                var entries = gate.entered.makeAsyncIterator()
                _ = await entries.next()
            }
            #expect(await coordinator.runningCount == 2)
            let old = try #require(initial.first)
            let batch = try admit([2], retiring: [old.ticket])
            guard case .cancel(let cancelled) = batch.commands.first else { throw Failure.unexpected }
            #expect(cancelled == old.ticket)
            let replacement = try #require(starts(batch).first)
            await coordinator.cancel([cancelled])
            await coordinator.start([replacement])
            var replacementEntries = gates[2].entered.makeAsyncIterator()
            _ = await replacementEntries.next()
            #expect(!storage.withLock { $0.isActive(old.ticket) })
            #expect(storage.withLock { $0.isActive(initial[1].ticket) && $0.isActive(replacement.ticket) })
            #expect(storage.withLock { $0.executionReservations.count } == 3)
            #expect(await coordinator.runningCount == 3)
            gates[0].release()
            #expect(await completions.next() == old.ticket)
            #expect(storage.withLock { $0.executionReservations.count } == 2)
            #expect(await coordinator.runningCount == 2)
            // Closing revokes the remaining authorities; only their actual returns release reservations.
            let cancellations = storage.withLock { core in
                _ = core.close()
                return core.drain(limit: 1).flatMap(\.commands)
                    .compactMap { command -> RuntimeTicket? in
                        if case .cancel(let ticket) = command { return ticket }
                        return nil
                    }
            }
            await coordinator.cancel(cancellations)
            #expect(storage.withLock { $0.executionReservations.count } == 2)
            gates[1].release()
            gates[2].release()
            await coordinator.join()
            #expect(await coordinator.runningCount == 0)
            #expect(storage.withLock { $0.executionReservations.isEmpty && $0.isQuiescent })
            let recorded = returned.withLock { $0 }
            #expect(recorded.count == 3)
            for work in initial + [replacement] {
                #expect(recorded.filter { $0 == work.ticket }.count == 1)
            }
        } catch {
            let tickets = storage.withLock { core in
                let tickets = core.executionReservations.map(\.ticket)
                _ = core.close()
                _ = core.drain(limit: 1)
                return tickets
            }
            await coordinator.cancel(tickets)
            for gate in gates { gate.release() }
            await coordinator.join()
            throw error
        }
    }
}
