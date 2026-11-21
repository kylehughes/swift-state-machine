import Dispatch
import StateMachine
import Testing
import os

// An owner that finds several capacity conflicts at once reports each as it captured it. A handler of
// an earlier entry that reconciles a later one synchronously sees that entry's captured attempt
// before the attempt it starts, so each completion's attempts are reported in order and once each.

private typealias ConflictEngine = RuntimeState<Int, Int>

/// A terminal outcome, named for the work that produced it, whose preparation accepts or refuses it.
private struct Outcome: Sendable {
    let ticket: RuntimeTicket
    let name: String
    let accepts: Bool
}

/// Why a preparation refused an outcome.
private struct Refusal: Error, Equatable {}

/// The reports a reconciliation handler saw, and what it does with the next one.
private final class Reports: Sendable {
    private let state = OSAllocatedUnfairLock<(names: [String], reentry: (@Sendable (String) -> Void)?)>(
        initialState: ([], nil)
    )
    var names: [String] { state.withLock { $0.names } }
    func append(_ name: String) {
        let reentry = state.withLock { state -> (@Sendable (String) -> Void)? in
            state.names.append(name)
            return state.reentry
        }
        reentry?(name)
    }
    /// Runs `action` once, for the first report named `name`.
    func once(on name: String, _ action: @escaping @Sendable () -> Void) {
        let done = OSAllocatedUnfairLock(initialState: false)
        state.withLock {
            $0.reentry = { reported in
                guard reported == name, done.withLock({ done in exchange(&done, with: true) }) == false else { return }
                action()
            }
        }
    }
}

/// How many times each outcome has been prepared, so a later preparation can refuse what an earlier
/// one accepted.
private final class Preparations: Sendable {
    private let counts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    func count(_ name: String) -> Int {
        counts.withLock { counts in
            counts[name, default: 0] += 1
            return counts[name]!
        }
    }
}

// A preparation that accepts an outcome that accepts on its first preparation, and then starts two
// works, more than the owner has free; it refuses every later preparation.
private func prepare(
    _ attempt: RuntimeDeliveryLedger<Int, Int, Outcome, Refusal>.Attempt,
    _ preparations: Preparations,
    _ scope: RuntimeScopeID
) -> RuntimeDeliveryLedger<Int, Int, Outcome, Refusal>.Preparation {
    guard attempt.outcome.accepts, preparations.count(attempt.outcome.name) == 1 else {
        return .failure(.preparation(Refusal()))
    }
    return .success(
        try! ConflictEngine.prepare(
            on: attempt.snapshot,
            next: 99,
            requiring: [attempt.outcome.ticket],
            plan: .init(
                retire: [attempt.outcome.ticket],
                starts: [
                    .init(.init(kind: 5, scope: scope), descriptor: 5),
                    .init(.init(kind: 6, scope: scope), descriptor: 6),
                ],
                finishingClaims: [attempt.claim]
            )
        )
    )
}

private func name(_ pending: RuntimeDeliveryLedger<Int, Int, Outcome, Refusal>.Pending) -> String {
    "\(pending.outcome.name)\(pending.attempts)"
}

/// Drivers that stay suspended until the test releases them, reporting each start.
private actor HeldDrivers {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let starts: AsyncStream<RuntimeWork<Int>>
    private let started: AsyncStream<RuntimeWork<Int>>.Continuation

    init() { (starts, started) = AsyncStream.makeStream() }
    func run(_ work: RuntimeWork<Int>) async -> Outcome {
        if !released {
            await withCheckedContinuation {
                waiting.append($0)
                started.yield(work)
            }
        }
        return Outcome(ticket: work.ticket, name: "late", accepts: false)
    }
    func releaseAll() {
        released = true
        let prior = waiting
        waiting = []
        for continuation in prior { continuation.resume() }
        started.finish()
    }
}

/// Holds a `Shared` owner's batch drainer inside the handler of one emission until the test lets it go.
private final class EmissionHold: Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let entered = AsyncStream<Void>.makeStream()
    func hold() {
        entered.continuation.yield(())
        held.wait()
    }
    func reached() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func proceed() { held.signal() }
}

@Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(1)))
struct CapacityConflictOrderTests {
    // Under the manual policy, A is retained after its preparation refused it, and B and C wait for
    // capacity with sealed candidates that start more work than is free. An event handler keeps the
    // batch drainer busy while an unrelated edit advances the root. Reconciling A refuses it again, and
    // its admission then finds both B and C in conflict with the edit, in one batch. B's handler
    // reconciles C, whose second preparation refuses it. C's handler sees C's captured first attempt
    // before its second.
    @Test func aSharedOwnerReportsALaterConflictOfTheBatchBeforeTheAttemptItsHandlerStarts() async throws {
        let scope = RuntimeScopeID(kind: 1)
        let drivers = HeldDrivers()
        let emission = EmissionHold()
        let reports = Reports()
        let preparations = Preparations()
        let owner = RuntimeSharedHost<Int, Int, Outcome, Refusal>(
            0,
            scopes: [scope],
            limits: try .init(commits: 8, descriptors: 4, executions: 3),
            policy: .manual,
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, scope) },
            reconciliationRequired: { reports.append(name($0)) },
            emit: { descriptor in if descriptor == 7 { emission.hold() } }
        )
        var starts = drivers.starts.makeAsyncIterator()
        _ = owner.commit(
            try ConflictEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [
                    .init(.init(kind: 1, scope: scope), descriptor: 1),
                    .init(.init(kind: 2, scope: scope), descriptor: 2),
                    .init(.init(kind: 3, scope: scope), descriptor: 3),
                ])
            )
        )
        var works: [Int: RuntimeWork<Int>] = [:]
        while works.count < 3, let work = await starts.next() { works[work.descriptor] = work }
        _ = owner.deliver(Outcome(ticket: try #require(works[1]).ticket, name: "A", accepts: false))
        let a = try #require(owner.pendingCompletions().first { $0.outcome.name == "A" })
        _ = owner.commit(
            try ConflictEngine.prepare(on: owner.snapshot(), next: 2, plan: .init(emissions: [.init(7, position: 0)]))
        )
        await emission.reached()
        _ = owner.deliver(Outcome(ticket: try #require(works[2]).ticket, name: "B", accepts: true))
        _ = owner.deliver(Outcome(ticket: try #require(works[3]).ticket, name: "C", accepts: true))
        #expect(
            owner.pendingCompletions().map(\.status) == [
                .reconciliationRequired, .waitingForCapacity, .waitingForCapacity,
            ]
        )
        _ = owner.commit(try ConflictEngine.prepare(on: owner.snapshot(), next: 3))
        let c = try #require(owner.pendingCompletions().first { $0.outcome.name == "C" })
        reports.once(on: "B1") { _ = owner.reconcile(id: c.id) }
        let batches = OSAllocatedUnfairLock<[[RuntimePendingID]]>(initialState: [])
        CapacityConflictPause.$beforeReports.withValue({ batch in batches.withLock { $0.append(batch) } }) {
            _ = owner.reconcile(id: a.id)
        }
        #expect(batches.withLock { $0.map(\.count) } == [2])
        #expect(reports.names == ["A1", "A2", "B1", "C1", "C2"])
        emission.proceed()
        _ = owner.close()
        await drivers.releaseAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }

    // The same batch on a `MainActor` owner, which finds the conflicts and reports them in the
    // reconciliation's own turn.
    @MainActor @Test func aMainActorOwnerReportsALaterConflictOfTheBatchBeforeTheAttemptItsHandlerStarts() async throws
    {
        let scope = RuntimeScopeID(kind: 1)
        let drivers = HeldDrivers()
        let reports = Reports()
        let preparations = Preparations()
        let owner = RuntimeMainActorHost<Int, Int, Outcome, Refusal>(
            0,
            scopes: [scope],
            configuration: try .init(limits: .init(commits: 8, descriptors: 4, executions: 3)),
            policy: .manual,
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, scope) },
            reconciliationRequired: { reports.append(name($0)) }
        )
        var starts = drivers.starts.makeAsyncIterator()
        _ = owner.commit(
            try ConflictEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [
                    .init(.init(kind: 1, scope: scope), descriptor: 1),
                    .init(.init(kind: 2, scope: scope), descriptor: 2),
                    .init(.init(kind: 3, scope: scope), descriptor: 3),
                ])
            )
        )
        var works: [Int: RuntimeWork<Int>] = [:]
        while works.count < 3, let work = await starts.next() { works[work.descriptor] = work }
        _ = owner.deliver(Outcome(ticket: try #require(works[1]).ticket, name: "A", accepts: false))
        let a = try #require(owner.pendingCompletions().first { $0.outcome.name == "A" })
        _ = owner.deliver(Outcome(ticket: try #require(works[2]).ticket, name: "B", accepts: true))
        _ = owner.deliver(Outcome(ticket: try #require(works[3]).ticket, name: "C", accepts: true))
        #expect(
            owner.pendingCompletions().map(\.status) == [
                .reconciliationRequired, .waitingForCapacity, .waitingForCapacity,
            ]
        )
        _ = owner.commit(try ConflictEngine.prepare(on: owner.snapshot(), next: 3))
        let c = try #require(owner.pendingCompletions().first { $0.outcome.name == "C" })
        reports.once(on: "B1") { MainActor.assumeIsolated { _ = owner.reconcile(id: c.id) } }
        let batches = OSAllocatedUnfairLock<[[RuntimePendingID]]>(initialState: [])
        CapacityConflictPause.$beforeReports.withValue({ batch in batches.withLock { $0.append(batch) } }) {
            _ = owner.reconcile(id: a.id)
        }
        #expect(batches.withLock { $0.map(\.count) } == [2])
        #expect(reports.names == ["A1", "A2", "B1", "C1", "C2"])
        _ = owner.close()
        await drivers.releaseAll()
    }
}
