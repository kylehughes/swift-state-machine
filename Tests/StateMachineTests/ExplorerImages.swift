import Dispatch
import Foundation
import StateMachine
import StateMachineTestSupport
import os

// The raw owner's `images` family: what a `Shared` owner keeps for its pending-completion registrations
// while a reconciliation handler holds its one report queue.
//
// One `RuntimeSharedHost` under the manual completion policy, with three commit slots, two descriptor and
// execution slots, and every work's driver returning at once. Work A's outcome is refused by every
// preparation, so A stays retained and requires reconciliation; every other work's outcome is accepted. Its
// verbs: `registerPending` (a pending-completion registration whose callback keeps nothing), `cancelNewest`
// (cancels the newest one), `holdReport` (an explicit `reconcile(id:)` of A on a thread of its own, whose
// report the handler holds until `releaseReport`), `completeOthers` (four further works started and
// completed one at a time), and `turn`.
//
// Invariant I55 bounds what the owner keeps for those registrations by the documented live work: each
// registration keeps at most one collection it has not read, a newer one replacing it, and may be handed
// one more, so while the queue is held at most two collections per registration, each showing at most one
// of the works completed one at a time, can keep a completed work's payload alive. Every payload is a
// client object the harness tracks only by a weak identity, and once the handler returns, every completed
// work's payload goes.

/// A completed work's payload, whose release the harness counts.
nonisolated final class ExplorerImagesPayload: Sendable {
    let serial: Int
    private let log: ExplorerImagesLog
    init(serial: Int, log: ExplorerImagesLog) {
        self.serial = serial
        self.log = log
        log.made(serial)
    }
    deinit { log.released(serial) }
}

/// A work's outcome: its ticket, whether every preparation refuses it, and its payload.
nonisolated struct ExplorerImagesOutcome: Sendable {
    let ticket: RuntimeTicket
    let refuses: Bool
    let payload: ExplorerImagesPayload
}

typealias ExplorerImagesHost = RuntimeSharedHost<Int, Int, ExplorerImagesOutcome, ExplorerRefusal>

/// The harness's record of payloads, preparations, and reports, behind one lock that never releases a
/// client value.
nonisolated final class ExplorerImagesLog: Sendable {
    struct State: Sendable {
        var serial = 0
        var alive: Set<Int> = []
        /// Payloads of works whose completion was admitted and is no longer retained or running.
        var completed: Set<Int> = []
        var accepted: [(ticket: RuntimeTicket, serial: Int)] = []
        var reportsOfA = 0
        /// Whether the next report of A holds its thread until the gate opens.
        var holdNext = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let gate = ThreadGate()
    let arrived = DispatchSemaphore(value: 0)

    func nextSerial() -> Int {
        state.withLock {
            $0.serial += 1
            return $0.serial
        }
    }
    func made(_ serial: Int) { state.withLock { _ = $0.alive.insert(serial) } }
    func released(_ serial: Int) { state.withLock { _ = $0.alive.remove(serial) } }
    func accepted(_ ticket: RuntimeTicket, serial: Int) { state.withLock { $0.accepted.append((ticket, serial)) } }
    /// The live payloads of completed works.
    var liveCompleted: [Int] { state.withLock { $0.completed.intersection($0.alive).sorted() } }
    func report() {
        let hold = state.withLock { state -> Bool in
            state.reportsOfA += 1
            return exchange(&state.holdNext, with: false)
        }
        guard hold else { return }
        arrived.signal()
        gate.wait()
    }
}

/// Runs one sequence against a fresh raw shared owner with a retained work A.
@MainActor final class ExplorerImagesRun: ExplorerRunner {
    let world: ExplorerWorld
    private let scope = RuntimeScopeID(kind: 1)
    private let log = ExplorerImagesLog()
    private var owner: ExplorerImagesHost!
    private var pending: [SnapshotSubscription] = []
    private var heldReturned: DispatchSemaphore?
    private var holdUsed = false
    private var completions = 0
    private var turns = 0
    private var aID: RuntimePendingID?

    init?(verbose: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        let log = log
        let scope = scope
        guard let limits = try? Limits(commits: 3, descriptors: 2, executions: 2) else { return nil }
        owner = ExplorerImagesHost(
            0,
            scopes: [scope],
            limits: limits,
            subscriberCapacity: 3,
            policy: .manual,
            driver: { work in
                ExplorerImagesOutcome(
                    ticket: work.ticket,
                    refuses: work.descriptor == 1,
                    payload: ExplorerImagesPayload(serial: log.nextSerial(), log: log)
                )
            },
            ticket: { $0.ticket },
            prepare: { attempt in
                guard !attempt.outcome.refuses,
                    let candidate = try? ExplorerRuntimeEngine.prepare(
                        on: attempt.snapshot,
                        next: attempt.snapshot.model + 1,
                        requiring: [attempt.outcome.ticket],
                        plan: .init(retire: [attempt.outcome.ticket], finishingClaims: [attempt.claim])
                    )
                else { return .failure(.preparation(ExplorerRefusal())) }
                log.accepted(attempt.outcome.ticket, serial: attempt.outcome.payload.serial)
                return .success(candidate)
            },
            reconciliationRequired: { _ in log.report() }
        )
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        // The held handler waits on the gate; every path out of the run opens it.
        defer { log.gate.open() }
        await setUp()
        var enabledAfter = sequence.isEmpty ? enabled() : []
        if world.violations.isEmpty {
            for (index, event) in sequence.enumerated() {
                world.note("step \(index + 1): \(event)")
                turns = event == .turn ? turns + 1 : 0
                await perform(event)
                if world.violations.isEmpty { await checkBound("after \(event)") }
                if !world.violations.isEmpty { break }
                if index == sequence.count - 1 { enabledAfter = enabled() }
            }
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    private func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if pending.count < 2 { result.append(.registerPending) }
        if !pending.isEmpty { result.append(.cancelNewest) }
        if heldReturned == nil, !holdUsed { result.append(.holdReport) }
        if heldReturned != nil { result.append(.releaseReport) }
        if completions < 2 { result.append(.completeOthers) }
        if turns < 2 { result.append(.turn) }
        return result
    }

    // Work A starts, its driver returns at once, its preparation refuses it, and the owner reports it.
    private func setUp() async {
        guard
            let candidate = try? ExplorerRuntimeEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [.init(.init(kind: 1, scope: scope), descriptor: 1)])
            )
        else {
            world.violate(.stuck, "the launch of work A was refused")
            return
        }
        _ = owner.commit(candidate)
        let reported = await hop(until: { self.log.state.withLock { $0.reportsOfA } > 0 }, limit: 2000)
        aID = owner.pendingCompletions().first?.id
        if !reported || aID == nil { world.violate(.stuck, "work A was never reported as retained") }
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .registerPending:
            guard let subscription = try? owner.subscribePending({ _ in }) else {
                world.violate(.stuck, "a pending-completion registration was refused")
                return
            }
            pending.append(subscription)
        case .cancelNewest:
            pending.popLast()?.cancel()
        case .holdReport:
            guard let aID else { return }
            holdUsed = true
            log.state.withLock { $0.holdNext = true }
            let returned = DispatchSemaphore(value: 0)
            heldReturned = returned
            let owner = owner!
            runOnOwnThread {
                _ = owner.reconcile(id: aID)
                returned.signal()
            }
            if !explorerWait(log.arrived) { world.violate(.stuck, "A's reconciliation never reported") }
        case .releaseReport:
            await releaseReport()
        case .completeOthers:
            completions += 1
            for _ in 0 ..< 4 { await completeOne() }
        case .turn:
            await hop()
        default:
            break
        }
    }

    // One further work starts, its driver returns, and the owner admits its completion.
    private func completeOne() async {
        let accepted = log.state.withLock { $0.accepted.count }
        guard
            let candidate = try? ExplorerRuntimeEngine.prepare(
                on: owner.snapshot(),
                next: owner.snapshot().model + 1,
                plan: .init(starts: [.init(.init(kind: 2, scope: scope), descriptor: 2)])
            )
        else {
            world.violate(.stuck, "a further work's launch was refused")
            return
        }
        _ = owner.commit(candidate)
        let owner = owner!
        let done = await hop(
            until: {
                let found = self.log.state.withLock { state -> (RuntimeTicket, Int)? in
                    state.accepted.count > accepted ? state.accepted.last.map { ($0.ticket, $0.serial) } : nil
                }
                guard let (ticket, serial) = found else { return false }
                let settled =
                    !owner.isActive(ticket) && !owner.pendingCompletions().contains { $0.outcome.ticket == ticket }
                if settled { self.log.state.withLock { _ = $0.completed.insert(serial) } }
                return settled
            },
            limit: 2000
        )
        if !done { world.violate(.stuck, "a further work's completion was never admitted") }
    }

    private func releaseReport() async {
        guard let returned = heldReturned else { return }
        heldReturned = nil
        log.gate.open()
        if !explorerWait(returned) { world.violate(.stuck, "the held reconciliation never returned") }
    }

    // I55: while the report queue is held, completed works' payloads alive stay within two collections per
    // pending registration; otherwise none stays alive. A payload's release can lag the admission on the
    // owner's worker, so the check waits a few turns before it judges.
    private func checkBound(_ when: String) async {
        let bound = heldReturned == nil ? 0 : 2 * pending.count
        _ = await hop(until: { self.log.liveCompleted.count <= bound }, limit: 200)
        let live = log.liveCompleted
        if let problem = explorerRetainedPayloadProblem(live: live.count, bound: bound) {
            world.violate(
                .retainedPayloads,
                "\(problem) \(when) (\(pending.count) pending registrations, handler \(heldReturned == nil ? "free" : "held"), payloads \(live))"
            )
        }
    }

    private func quiesce() async {
        world.note("quiesce")
        await releaseReport()
        if world.violations.isEmpty { await checkBound("once the handler returned") }
        for subscription in pending { subscription.cancel() }
        pending = []
        if await owner.shutdown(deadline: .now.advanced(by: .seconds(5))) != nil {
            world.violate(.stuck, "the owner did not shut down")
        }
    }

    private func hop() async { await Task { @MainActor in }.value }
    private func hop(until condition: () -> Bool, limit: Int) async -> Bool {
        for _ in 0 ..< limit {
            if condition() { return true }
            await hop()
        }
        return condition()
    }
}
