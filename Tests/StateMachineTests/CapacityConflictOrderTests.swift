import Dispatch
import StateMachine
import Testing
import os

// Every owner queues each reconciliation report in the change that decides it, before any callout, and
// delivers its reports one at a time, from the oldest. A handler that reconciles any completion
// synchronously therefore queues that attempt's report behind every report decided before it, so no
// handler invocation ever precedes one for an earlier decision, on any host kind, and a `Shared`
// owner's returning workers share the queue of every copy of the owner.

private typealias ConflictEngine = RuntimeState<Int, Int>
private typealias Ledger = RuntimeDeliveryLedger<Int, Int, Outcome, Refusal>

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

// A preparation that accepts an outcome that accepts on its first preparation, and then starts
// `starts` works, more than the owner ever has free while the scenario holds another; it refuses every
// later preparation.
private func prepare(_ attempt: Ledger.Attempt, _ preparations: Preparations, starts: Int) -> Ledger.Preparation {
    guard attempt.outcome.accepts, preparations.count(attempt.outcome.name) == 1 else {
        return .failure(.preparation(Refusal()))
    }
    let scope = RuntimeScopeID(kind: 1)
    return .success(
        try! ConflictEngine.prepare(
            on: attempt.snapshot,
            next: 99,
            requiring: [attempt.outcome.ticket],
            plan: .init(
                retire: [attempt.outcome.ticket],
                starts: (0 ..< starts).map { .init(.init(kind: UInt32(10 + $0), scope: scope), descriptor: 10 + $0) },
                finishingClaims: [attempt.claim]
            )
        )
    )
}

private func name(_ pending: Ledger.Pending) -> String { "\(pending.outcome.name)\(pending.attempts)" }

private let names = [1: "A", 2: "B", 3: "C", 4: "D"]

/// Drivers that stay suspended until the test returns each of them, reporting each start. A returns
/// an outcome its preparation refuses, B and C ones it accepts once.
private actor Workers {
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var returning: Set<Int> = []
    private var all = false
    let starts: AsyncStream<RuntimeWork<Int>>
    private let started: AsyncStream<RuntimeWork<Int>>.Continuation

    init() { (starts, started) = AsyncStream.makeStream() }
    func run(_ work: RuntimeWork<Int>) async -> Outcome {
        if !all, !returning.contains(work.descriptor) {
            await withCheckedContinuation {
                waiting[work.descriptor] = $0
                started.yield(work)
            }
        }
        let name = names[work.descriptor] ?? "late"
        return Outcome(ticket: work.ticket, name: name, accepts: name == "B" || name == "C")
    }
    func `return`(_ descriptor: Int) {
        returning.insert(descriptor)
        waiting.removeValue(forKey: descriptor)?.resume()
    }
    func returnAll() {
        all = true
        let prior = waiting
        waiting = [:]
        for continuation in prior.values { continuation.resume() }
        started.finish()
    }
}

/// Runs `work` on `workers`, for a driver confined to an owner's actor.
private func drive(_ workers: Workers, _ work: RuntimeWork<Int>) async -> Outcome { await workers.run(work) }

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

/// Waits, a turn at a time, until `condition` holds.
@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async {
    while await !condition() { try? await Task.sleep(for: .milliseconds(1)) }
}

/// Waits until `count` works have started.
private func awaitStarts(_ starts: AsyncStream<RuntimeWork<Int>>, count: Int) async {
    var seen = 0
    for await _ in starts {
        seen += 1
        if seen == count { return }
    }
}

/// The kinds of managed host, each of which must order its reports the same way.
enum ReportingHost: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case shared, actor, mainActor, isolated
    var testDescription: String { rawValue }
}

/// The scenario's starting plan: works A, B, C, and D, which holds one execution slot throughout.
private func startingCandidate(on snapshot: ConflictEngine.Snapshot) throws -> ConflictEngine.Candidate {
    let scope = RuntimeScopeID(kind: 1)
    return try ConflictEngine.prepare(
        on: snapshot,
        next: 1,
        plan: .init(starts: (1 ... 4).map { .init(.init(kind: UInt32($0), scope: scope), descriptor: $0) })
    )
}

/// The identity of the retained completion named `name`.
private func id(_ pending: [Ledger.Pending], _ name: String) throws -> RuntimePendingID {
    try #require(pending.first { $0.outcome.name == name }).id
}

/// Whether B and C both wait for capacity.
private func waiting(_ pending: [Ledger.Pending]) -> Bool {
    pending.filter { $0.status == .waitingForCapacity }.count == 2
}

/// Whether B is retained, so C, returned after it, is retained after it.
private func retainedB(_ pending: [Ledger.Pending]) -> Bool {
    pending.contains { $0.outcome.name == "B" && $0.status == .waitingForCapacity }
}

/// Whether A's preparation refused it.
private func refused(_ pending: [Ledger.Pending]) -> Bool {
    pending.contains { $0.outcome.name == "A" && $0.status == .reconciliationRequired }
}

/// Runs the capacity-conflict schedule and returns its reports in the order the handler received them.
///
/// Under the manual policy, A's preparation refuses its outcome (A1), and B and C wait for capacity
/// with sealed candidates that start four works while D holds a slot. An unrelated edit advances the
/// root, and reconciling A refuses it again (A2), its admission finding both B and C in conflict with
/// the edit (B1, C1) in one batch. When the handler receives `source`, it reconciles `target`, whose
/// preparation refuses.
@MainActor private func run(_ kind: ReportingHost, source: String, target: String) async throws -> [String] {
    let workers = Workers()
    let reports = Reports()
    let preparations = Preparations()
    let limits = try Limits(commits: 8, descriptors: 4, executions: 4)
    switch kind {
    case .shared:
        let emission = EmissionHold()
        let owner = RuntimeSharedHost<Int, Int, Outcome, Refusal>(
            0,
            scopes: [RuntimeScopeID(kind: 1)],
            limits: limits,
            policy: .manual,
            driver: { await workers.run($0) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, starts: 4) },
            reconciliationRequired: { reports.append(name($0)) },
            emit: { descriptor in if descriptor == 7 { emission.hold() } }
        )
        _ = owner.commit(try startingCandidate(on: owner.snapshot()))
        await awaitStarts(workers.starts, count: 4)
        await workers.return(1)
        await eventually { refused(owner.pendingCompletions()) }
        _ = owner.commit(
            try ConflictEngine.prepare(on: owner.snapshot(), next: 2, plan: .init(emissions: [.init(7, position: 0)]))
        )
        await emission.reached()
        await workers.return(2)
        await eventually { retainedB(owner.pendingCompletions()) }
        await workers.return(3)
        await eventually { waiting(owner.pendingCompletions()) }
        _ = owner.commit(try ConflictEngine.prepare(on: owner.snapshot(), next: 3))
        let pending = owner.pendingCompletions()
        let targetID = try id(pending, target)
        reports.once(on: source) { _ = owner.reconcile(id: targetID) }
        _ = owner.reconcile(id: try id(pending, "A"))
        emission.proceed()
        _ = owner.close()
        await workers.returnAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    case .mainActor:
        let owner = RuntimeMainActorHost<Int, Int, Outcome, Refusal>(
            0,
            scopes: [RuntimeScopeID(kind: 1)],
            configuration: try .init(limits: limits),
            policy: .manual,
            driver: { await workers.run($0) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, starts: 4) },
            reconciliationRequired: { reports.append(name($0)) }
        )
        _ = owner.commit(try startingCandidate(on: owner.snapshot()))
        await awaitStarts(workers.starts, count: 4)
        await workers.return(1)
        await eventually { refused(owner.pendingCompletions()) }
        await workers.return(2)
        await eventually { retainedB(owner.pendingCompletions()) }
        await workers.return(3)
        await eventually { waiting(owner.pendingCompletions()) }
        _ = owner.commit(try ConflictEngine.prepare(on: owner.snapshot(), next: 3))
        let pending = owner.pendingCompletions()
        let targetID = try id(pending, target)
        reports.once(on: source) { MainActor.assumeIsolated { _ = owner.reconcile(id: targetID) } }
        _ = owner.reconcile(id: try id(pending, "A"))
        _ = owner.close()
        await workers.returnAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    case .actor:
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else { return [] }
        let owner = RuntimeActorHost<Int, Int, Outcome, Refusal>(
            0,
            scopes: [RuntimeScopeID(kind: 1)],
            configuration: try .init(limits: limits),
            policy: .manual,
            driver: { await workers.run($0) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, starts: 4) },
            reconciliationRequired: { reports.append(name($0)) },
            isolatedTo: MainActor.shared
        )
        _ = await owner.commit(try startingCandidate(on: owner.snapshot()))
        await awaitStarts(workers.starts, count: 4)
        await workers.return(1)
        await eventually { refused(await owner.pendingCompletions()) }
        await workers.return(2)
        await eventually { retainedB(await owner.pendingCompletions()) }
        await workers.return(3)
        await eventually { waiting(await owner.pendingCompletions()) }
        try reconcileOnActor(owner, reports, source: source, target: target)
        await workers.returnAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    case .isolated:
        guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else { return [] }
        try await IsolatedBench().run(workers, reports, preparations, limits, source: source, target: target)
    }
    return reports.names
}

/// An actor that owns a host confined to it and runs the scenario in its own turns.
private actor IsolatedBench {
    private typealias Host = RuntimeIsolatedHost<IsolatedBench, Int, Int, Outcome, Refusal>
    private var host: Host?
    private var target: RuntimePendingID?

    func run(
        _ workers: Workers,
        _ reports: Reports,
        _ preparations: Preparations,
        _ limits: Limits,
        source: String,
        target: String
    ) async throws {
        let host = Host(
            0,
            scopes: [RuntimeScopeID(kind: 1)],
            isolation: self,
            configuration: try ManagedConfiguration(limits: limits),
            policy: .manual,
            driver: { _, work in await workers.run(work) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, starts: 4) },
            reconciliationRequired: { reports.append(name($0)) }
        )
        self.host = host
        _ = host.commit(try startingCandidate(on: host.snapshot(isolation: self)), isolation: self)
        await awaitStarts(workers.starts, count: 4)
        await workers.return(1)
        while !refused(host.pendingCompletions(isolation: self)) { try? await Task.sleep(for: .milliseconds(1)) }
        await workers.return(2)
        while !retainedB(host.pendingCompletions(isolation: self)) { try? await Task.sleep(for: .milliseconds(1)) }
        await workers.return(3)
        while !waiting(host.pendingCompletions(isolation: self)) { try? await Task.sleep(for: .milliseconds(1)) }
        _ = host.commit(try ConflictEngine.prepare(on: host.snapshot(isolation: self), next: 3), isolation: self)
        let pending = host.pendingCompletions(isolation: self)
        self.target = try id(pending, target)
        if #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) {
            reports.once(on: source) { [unowned self] in self.assumeIsolated { $0.reconcileTarget() } }
        }
        _ = host.reconcile(id: try id(pending, "A"), isolation: self)
        _ = host.close(isolation: self)
        await workers.returnAll()
        #expect(await host.shutdown(deadline: .now.advanced(by: .seconds(10)), isolation: self) == nil)
        self.host = nil
    }

    private func reconcileTarget() {
        guard let host, let target else { return }
        _ = host.reconcile(id: target, isolation: self)
    }
}

/// Makes the edit and reconciles A on an actor owner that runs on the main actor's executor, in one
/// turn that holds the owner's isolation throughout, then closes the owner.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
@MainActor private func reconcileOnActor(
    _ owner: RuntimeActorHost<Int, Int, Outcome, Refusal>,
    _ reports: Reports,
    source: String,
    target: String
) throws {
    try owner.assumeIsolated { owner in
        _ = owner.commit(try ConflictEngine.prepare(on: owner.snapshot(), next: 3))
        let pending = owner.pendingCompletions()
        let targetID = try id(pending, target)
        reports.once(on: source) { owner.assumeIsolated { _ = $0.reconcile(id: targetID) } }
        _ = owner.reconcile(id: try id(pending, "A"))
        _ = owner.close()
    }
}

/// The attempt a reconciliation of `target` makes in the scenario, which its handler sees last.
private func nextAttempt(of target: String) -> String { target == "A" ? "A3" : "\(target)2" }

@Suite(.serialized, .parksCooperativeThread, .timeLimit(.minutes(2)))
struct CapacityConflictOrderTests {
    // The handler of A's second attempt reconciles C. C's new attempt is reported after the conflicts
    // that the same installation as A's second attempt found, B's first and C's first.
    @Test(arguments: ReportingHost.allCases)
    func anExplicitAttemptsHandlerReconcilingAnotherCompletionReportsAfterTheConflictsOfItsBatch(
        _ kind: ReportingHost
    ) async throws {
        let names = try await run(kind, source: "A2", target: "C")
        guard !names.isEmpty else { return }
        #expect(names == ["A1", "A2", "B1", "C1", "C2"])
    }

    // Every handler of the batch reconciling every completion: the reconciliation's own report comes
    // after the whole batch, in the order the owner decided it.
    @Test(arguments: ReportingHost.allCases)
    func everyHandlerReconcilingEveryCompletionReportsInDecisionOrder(_ kind: ReportingHost) async throws {
        for source in ["A2", "B1", "C1"] {
            for target in ["A", "B", "C"] {
                let names = try await run(kind, source: source, target: target)
                guard !names.isEmpty else { return }
                #expect(
                    names == ["A1", "A2", "B1", "C1", nextAttempt(of: target)],
                    "\(kind): the handler of \(source) reconciles \(target)"
                )
            }
        }
    }

    // A held drainer leaves B and C waiting for capacity while an unrelated edit advances the root. A
    // returning worker frees capacity, and its host, which the coordinator makes for the return, finds
    // both in conflict. B's handler reconciles C through the owner it captured, a different copy of the
    // host, which queues C's new attempt behind C's conflict on the one queue they share; A's own refusal
    // follows them.
    @Test func aReturningWorkersHostSharesTheOwnersReportQueue() async throws {
        let workers = Workers()
        let reports = Reports()
        let preparations = Preparations()
        let emission = EmissionHold()
        let scope = RuntimeScopeID(kind: 1)
        let owner = RuntimeSharedHost<Int, Int, Outcome, Refusal>(
            0,
            scopes: [scope],
            limits: try .init(commits: 8, descriptors: 4, executions: 3),
            policy: .manual,
            driver: { await workers.run($0) },
            ticket: { $0.ticket },
            prepare: { prepare($0, preparations, starts: 3) },
            reconciliationRequired: { reports.append(name($0)) },
            emit: { descriptor in if descriptor == 7 { emission.hold() } }
        )
        var starts = workers.starts.makeAsyncIterator()
        _ = owner.commit(
            try ConflictEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: (1 ... 3).map { .init(.init(kind: UInt32($0), scope: scope), descriptor: $0) })
            )
        )
        var started = 0
        while started < 3, await starts.next() != nil { started += 1 }
        _ = owner.commit(
            try ConflictEngine.prepare(on: owner.snapshot(), next: 2, plan: .init(emissions: [.init(7, position: 0)]))
        )
        await emission.reached()
        await workers.return(2)
        await eventually { retainedB(owner.pendingCompletions()) }
        await workers.return(3)
        await eventually { owner.pendingCompletions().filter { $0.status == .waitingForCapacity }.count == 2 }
        _ = owner.commit(try ConflictEngine.prepare(on: owner.snapshot(), next: 3))
        let c = try #require(owner.pendingCompletions().first { $0.outcome.name == "C" })
        reports.once(on: "B1") { _ = owner.reconcile(id: c.id) }
        await workers.return(1)
        await eventually { reports.names.count == 4 }
        #expect(reports.names == ["B1", "C1", "C2", "A1"])
        emission.proceed()
        _ = owner.close()
        await workers.returnAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }
}
