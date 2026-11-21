import Dispatch
import StateMachine
import StateMachineTestSupport
import Testing
import os

// A shared owner reports each attempt's decision before any other callout of that attempt: the
// attempt that an explicit reconciliation made is reported before the capacity conflict its
// admission found, so a handler of that conflict that reconciles again reports a newer attempt only
// after the older one.

private typealias OrderEngine = RuntimeState<Int, Int>

/// A terminal outcome that the completion's preparation accepts or refuses.
private struct Finished: Sendable {
    let ticket: RuntimeTicket
    let accepts: Bool
}

/// Why the completion's preparation refused an outcome.
private struct Refusal: Error, Equatable {}

private typealias OrderHost = RuntimeSharedHost<Int, Int, Finished, Refusal>

/// Drivers that stay suspended until the test releases them, reporting each start.
private actor HeldDrivers {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let starts: AsyncStream<RuntimeWork<Int>>
    private let started: AsyncStream<RuntimeWork<Int>>.Continuation

    init() { (starts, started) = AsyncStream.makeStream() }
    func run(_ work: RuntimeWork<Int>) async -> Finished {
        if !released {
            await withCheckedContinuation {
                waiting.append($0)
                started.yield(work)
            }
        }
        return Finished(ticket: work.ticket, accepts: false)
    }
    func releaseAll() {
        released = true
        let prior = waiting
        waiting = []
        for continuation in prior { continuation.resume() }
        started.finish()
    }
}

/// Holds the owner's batch drainer inside the handler of one emission until the test lets it go.
private final class EmissionHold: Sendable {
    private let held = ThreadGate()
    private let entered = AsyncStream<Void>.makeStream()
    func hold() {
        entered.continuation.yield(())
        held.wait()
    }
    func reached() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func proceed() { held.open() }
}

@Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct ReconciliationOrderTests {
    // Under the manual policy, completion A is retained after its preparation refused it, and completion
    // B waits for capacity with a sealed candidate that starts more work than is free. An event handler
    // keeps the batch drainer busy while an unrelated edit advances the root. Reconciling A explicitly
    // refuses A again, and admitting B's candidate then conflicts with the edit. B's handler reconciles
    // A once more. A's handler sees its attempts in order: 1, 2, and then 3, which B's handler made.
    @Test func aSharedOwnerReportsAnExplicitAttemptBeforeTheConflictItsAdmissionFound() async throws {
        let scope = RuntimeScopeID(kind: 1)
        let drivers = HeldDrivers()
        let emission = EmissionHold()
        // A thrown error returns before the step that lets the drainer go.
        defer { emission.proceed() }
        let reports = OSAllocatedUnfairLock<[String]>(initialState: [])
        let reentry = OSAllocatedUnfairLock<(@Sendable (OrderHost.Ledger.Pending) -> Void)?>(initialState: nil)
        let owner = OrderHost(
            0,
            scopes: [scope],
            limits: try .init(commits: 8, descriptors: 4, executions: 2),
            policy: .manual,
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { attempt in
                guard attempt.outcome.accepts else { return .failure(.preparation(Refusal())) }
                return .success(
                    try! OrderEngine.prepare(
                        on: attempt.snapshot,
                        next: 99,
                        requiring: [attempt.outcome.ticket],
                        plan: .init(
                            retire: [attempt.outcome.ticket],
                            starts: [
                                .init(.init(kind: 3, scope: scope), descriptor: 3),
                                .init(.init(kind: 4, scope: scope), descriptor: 4),
                            ],
                            finishingClaims: [attempt.claim]
                        )
                    )
                )
            },
            reconciliationRequired: { pending in
                let name = pending.outcome.accepts ? "B" : "A\(pending.attempts)"
                reports.withLock { $0.append(name) }
                reentry.withLock { $0 }?(pending)
            },
            emit: { descriptor in if descriptor == 7 { emission.hold() } }
        )
        var starts = drivers.starts.makeAsyncIterator()
        _ = owner.commit(
            try OrderEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [
                    .init(.init(kind: 1, scope: scope), descriptor: 1),
                    .init(.init(kind: 2, scope: scope), descriptor: 2),
                ])
            )
        )
        var works: [Int: RuntimeWork<Int>] = [:]
        while works.count < 2, let work = await starts.next() { works[work.descriptor] = work }
        let first = try #require(works[1])
        let second = try #require(works[2])
        _ = owner.deliver(Finished(ticket: first.ticket, accepts: false))
        let a = try #require(owner.pendingCompletions().first { $0.outcome.ticket == first.ticket })
        #expect(a.status == .reconciliationRequired)
        _ = owner.commit(
            try OrderEngine.prepare(on: owner.snapshot(), next: 2, plan: .init(emissions: [.init(7, position: 0)]))
        )
        await emission.reached()
        _ = owner.deliver(Finished(ticket: second.ticket, accepts: true))
        #expect(owner.pendingCompletions().first { $0.outcome.ticket == second.ticket }?.status == .waitingForCapacity)
        _ = owner.commit(try OrderEngine.prepare(on: owner.snapshot(), next: 3))
        let reconciled = OSAllocatedUnfairLock(initialState: false)
        reentry.withLock {
            $0 = { pending in
                guard pending.outcome.accepts else { return }
                let first = reconciled.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { _ = owner.reconcile(id: a.id) }
            }
        }
        _ = owner.reconcile(id: a.id)
        reentry.withLock { $0 = nil }
        #expect(reports.withLock { $0 } == ["A1", "A2", "B", "A3"])
        emission.proceed()
        _ = owner.close()
        await drivers.releaseAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }
}
