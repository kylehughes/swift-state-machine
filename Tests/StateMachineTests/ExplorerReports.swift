import Dispatch
import Foundation
import StateMachine
import os

// The raw owner's `reconcile` family (E4, E13): one `RuntimeSharedHost` under the manual completion
// policy with three works running on drivers the harness holds one by one, and three executions.
//
// Its verbs: a work's outcome is delivered explicitly (`refuse(k)`, `accept(k)`) or its driver returns
// it (`returnRefuse(k)`, `returnAccept(k)`), which the owner's coordinator delivers from the worker; the
// batch drainer is held inside an emission handler and let go; an unrelated edit advances the root;
// a retained completion is reconciled or discarded; and a reconciliation or discard runs from inside a
// selected work's next report (`onReport(k, e)`: the explicit attempt's own report, a conflict of a
// batch, a worker return's report, or the entry's own report) or from inside an emission handler. A
// `stage(…)` first event puts each work in a starting state: running, refused or waiting for capacity,
// reached by an explicit delivery or by its driver's return, optionally with the drainer held and the
// root edited afterward.
//
// The preparation is revision-sensitive: an accepting outcome yields a candidate that starts two more
// works than are free on its first preparation, and again on a later one only while the model is the
// one its first preparation saw; every other preparation refuses.
//
// Invariant I44 compares every report with an expectation the harness keeps independently: each
// completion's reports carry its first delivered payload and its own retained entry, with status
// `reconciliationRequired`; attempt n is reported only after it was prepared, with the reason its
// preparation produced (a refusal, or an admission failure of a candidate); attempts are reported in
// increasing order, and none is skipped unless a later preparation superseded a candidate that was
// never reported. Once the owner is idle, every refused attempt and every entry that requires
// reconciliation has been reported.

/// Batches of two or more capacity conflicts reported while a report was armed (H9), in this process:
/// how often enumeration reached a window in which a handler of one conflict can reconcile another.
let explorerL1Windows = OSAllocatedUnfairLock(initialState: 0)

/// A work's terminal outcome: its ticket, whether its preparation may accept it, and a serial that
/// distinguishes two payloads under the same ticket.
nonisolated struct ExplorerReportsOutcome: Sendable {
    let ticket: RuntimeTicket
    let accepts: Bool
    let serial: Int
}

typealias ExplorerReportsHost = RuntimeSharedHost<Int, Int, ExplorerReportsOutcome, ExplorerRefusal>

/// Why a report says its attempt failed.
enum ExplorerReportReason: Sendable { case preparation, admission }

/// Drivers that stay suspended until the harness returns one of them, reporting each start.

actor ExplorerSelectableDrivers {
    private var released = false
    private var waiting: [(ticket: RuntimeTicket, continuation: CheckedContinuation<ExplorerReportsOutcome?, Never>)] =
        []
    let starts: AsyncStream<RuntimeWork<Int>>
    private let started: AsyncStream<RuntimeWork<Int>>.Continuation
    private let log: ExplorerReportsLog

    init(log: ExplorerReportsLog) {
        (starts, started) = AsyncStream.makeStream()
        self.log = log
    }
    func run(_ work: RuntimeWork<Int>) async -> ExplorerReportsOutcome {
        if !released {
            let ticket = work.ticket
            let chosen = await withCheckedContinuation { continuation in
                waiting.append((ticket, continuation))
                started.yield(work)
            }
            if let chosen { return chosen }
        }
        // A driver the harness never chose returns a refusing outcome once every driver is let go.
        let outcome = ExplorerReportsOutcome(ticket: work.ticket, accepts: false, serial: log.nextSerial())
        log.offered(outcome)
        return outcome
    }
    /// Returns the outcome from the driver of its work.
    ///
    /// Returns `false` when that driver is not waiting.
    func release(_ outcome: ExplorerReportsOutcome) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.ticket == outcome.ticket }) else { return false }
        waiting.remove(at: index).continuation.resume(returning: outcome)
        return true
    }
    func releaseAll() {
        released = true
        let prior = waiting
        waiting = []
        for entry in prior { entry.continuation.resume(returning: nil) }
        started.finish()
    }
}

/// The harness's independent record of deliveries, preparations, and reports, and the action armed at
/// a selected work's next report.
nonisolated final class ExplorerReportsLog: Sendable {
    struct State: Sendable {
        var tickets: [RuntimeTicket] = []
        var firstSerial: [Int: Int] = [:]
        /// Each preparation's result, in order: `true` for a candidate.
        var preparations: [Int: [Bool]] = [:]
        var firstModel: [Int: Int] = [:]
        var reported: [Int: [UInt64]] = [:]
        /// The retained entry each work's reports named, by the entry's index in `entries`.
        var ids: [Int: Int] = [:]
        var entries: [RuntimePendingID: Int] = [:]
        /// Candidate attempts a later preparation superseded before any report of them.
        var superseded: [Int: Set<UInt64>] = [:]
        var armed: (source: Int, action: @Sendable () -> Void)?
        var fired = 0
        var violations: [ExplorerViolation] = []
        var serial = 0
        var reports: [String] = []
        /// Reports owed when a handler reconciled `work` (decided before that call): each must be delivered
        /// before any later attempt of `work` (one queue per owner, oldest decision first).
        var owedBefore: [Int: (after: UInt64, owed: [(work: Int, attempt: UInt64)])] = [:]
        /// Preparations and report handlers running now.
        var inFlight = 0

        // The staged works occupy slots 1 through 3. A committed completion can launch
        // successors too, each with its own first outcome and attempt history.
        mutating func work(of ticket: RuntimeTicket) -> Int {
            if let index = tickets.firstIndex(of: ticket) { return index + 1 }
            tickets.append(ticket)
            return tickets.count
        }
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    private func work(of ticket: RuntimeTicket) -> Int { state.withLock { $0.work(of: ticket) } }
    func nextSerial() -> Int {
        state.withLock {
            $0.serial += 1
            return $0.serial
        }
    }
    /// An outcome offered for its work, explicitly or by its driver: the first one is the one retained.
    func offered(_ outcome: ExplorerReportsOutcome) { offered(work: work(of: outcome.ticket), serial: outcome.serial) }
    func offered(work: Int, serial: Int) {
        state.withLock { state in
            if state.firstSerial[work] == nil { state.firstSerial[work] = serial }
        }
    }

    /// Decides one preparation and records it: a candidate for an accepting outcome on its first
    /// preparation, or on a later one at the model the first saw.
    func prepare(_ outcome: ExplorerReportsOutcome, model: Int) -> Bool {
        prepare(work: work(of: outcome.ticket), accepts: outcome.accepts, model: model)
    }
    func prepare(work: Int, accepts: Bool, model: Int) -> Bool {
        state.withLock { state in
            state.inFlight += 1
            var made = state.preparations[work] ?? []
            let first = state.firstModel[work]
            if first == nil { state.firstModel[work] = model }
            let candidate = accepts && (first == nil || first == model)
            // A new preparation supersedes an earlier candidate attempt that was never reported.
            if let previous = made.last, previous {
                let attempt = UInt64(made.count)
                if !(state.reported[work] ?? []).contains(attempt) {
                    state.superseded[work, default: []].insert(attempt)
                }
            }
            made.append(candidate)
            state.preparations[work] = made
            return candidate
        }
    }
    /// A preparation or a report handler returned.
    func left() { state.withLock { $0.inFlight -= 1 } }

    func report(_ pending: ExplorerReportsHost.Ledger.Pending) {
        // The handler is in flight until the action armed at it, which may reconcile, returns.
        state.withLock { $0.inFlight += 1 }
        defer { left() }
        let reason: ExplorerReportReason? =
            switch pending.lastRejection {
            case .preparation: .preparation
            case .admission: .admission
            case nil: nil
            }
        let work = work(of: pending.outcome.ticket)
        let entry = state.withLock { state in
            if let index = state.entries[pending.id] { return index }
            let index = state.entries.count
            state.entries[pending.id] = index
            return index
        }
        let action = record(
            work: work,
            attempt: pending.attempts,
            serial: pending.outcome.serial,
            entry: entry,
            requiresReconciliation: pending.status == .reconciliationRequired,
            reason: reason
        )
        action?()
    }

    /// Checks one report against the independent expectation and returns the action armed at it, if any.
    func record(
        work: Int,
        attempt: UInt64,
        serial: Int,
        entry: Int,
        requiresReconciliation: Bool,
        reason: ExplorerReportReason?
    ) -> (@Sendable () -> Void)? {
        state.withLock { state -> (@Sendable () -> Void)? in
            let name = "work \(work)"
            state.reports.append("\(work).\(attempt)")
            func violate(_ detail: String) {
                state.violations.append(.init(invariant: .attemptOrder, detail: detail))
            }
            if let first = state.firstSerial[work], first != serial {
                violate("the report of \(name) carries payload #\(serial), not its first payload #\(first)")
            }
            if let id = state.ids[work], id != entry {
                violate("a report of \(name) names another retained entry")
            }
            if let other = state.ids.first(where: { $0.key != work && $0.value == entry })?.key {
                violate("a report of \(name) names the retained entry of work \(other)")
            }
            if state.ids[work] == nil { state.ids[work] = entry }
            if !requiresReconciliation {
                violate("attempt \(attempt) of \(name) was reported without requiring reconciliation")
            }
            let made = state.preparations[work] ?? []
            if attempt == 0 || attempt > UInt64(made.count) {
                violate("attempt \(attempt) of \(name) was reported after \(made.count) preparations")
            } else {
                let candidate = made[Int(attempt) - 1]
                switch reason {
                case .preparation:
                    if candidate {
                        violate("attempt \(attempt) of \(name), a candidate, was reported as a preparation refusal")
                    }
                case .admission:
                    if !candidate {
                        violate("attempt \(attempt) of \(name), a refusal, was reported as an admission failure")
                    }
                case nil:
                    violate("attempt \(attempt) of \(name) was reported without a reason")
                }
            }
            if let owed = state.owedBefore[work], attempt > owed.after {
                let missing = owed.owed.filter { !(state.reported[$0.work] ?? []).contains($0.attempt) }
                if !missing.isEmpty {
                    violate(
                        "attempt \(attempt) of \(name), reconciled from a handler, was reported before the reports decided earlier: \(missing.map { "work \($0.work) attempt \($0.attempt)" })"
                    )
                }
                state.owedBefore[work] = nil
            }
            let earlier = state.reported[work] ?? []
            if let last = earlier.last, attempt <= last {
                violate(
                    "the reconciliation handler of \(name) saw attempt \(attempt) after attempt \(last): \(earlier + [attempt])"
                )
            } else {
                let skipped = ((earlier.last ?? 0) + 1 ..< attempt)
                    .filter {
                        !(state.superseded[work] ?? []).contains($0)
                    }
                if !skipped.isEmpty {
                    violate("attempt \(attempt) of \(name) was reported before attempts \(skipped)")
                }
            }
            state.reported[work, default: []].append(attempt)
            guard let armed = state.armed, armed.source == work else { return nil }
            state.armed = nil
            state.fired += 1
            return armed.action
        }
    }

    /// Records, from inside a handler about to reconcile `work`, every report decided and not yet delivered.
    func reconciling(_ work: Int, _ pending: [ExplorerReportsHost.Ledger.Pending]) {
        state.withLock { state in
            let owed = pending.compactMap { entry -> (work: Int, attempt: UInt64)? in
                guard entry.status == .reconciliationRequired else { return nil }
                let owner = state.work(of: entry.outcome.ticket)
                return (state.reported[owner] ?? []).contains(entry.attempts) ? nil : (owner, entry.attempts)
            }
            state.owedBefore[work] = (UInt64(state.preparations[work]?.count ?? 0), owed)
        }
    }
    /// As above, with the undelivered reports given.
    func reconciling(_ work: Int, owed: [(work: Int, attempt: UInt64)]) {
        state.withLock { $0.owedBefore[work] = (UInt64($0.preparations[work]?.count ?? 0), owed) }
    }

    /// Whether no preparation or handler runs, no entry is being admitted or prepared, and every entry
    /// that requires reconciliation has had its current attempt reported.
    func caughtUp(_ pending: [ExplorerReportsHost.Ledger.Pending]) -> Bool {
        state.withLock { state in
            state.inFlight == 0
                && pending.allSatisfy { entry in
                    entry.status != .awaitingAdmission && entry.status != .preparing
                }
                && pending.allSatisfy { entry in
                    guard entry.status == .reconciliationRequired else { return true }
                    let work = state.work(of: entry.outcome.ticket)
                    return (state.reported[work] ?? []).contains(entry.attempts)
                }
        }
    }

    /// The idle owner's obligations: every refused attempt, and the current attempt of every entry that
    /// requires reconciliation, has been reported.
    func checkSettled(_ pending: [ExplorerReportsHost.Ledger.Pending]) {
        state.withLock { state in
            for (work, made) in state.preparations.sorted(by: { $0.key < $1.key }) {
                let reported = state.reported[work] ?? []
                for (index, candidate) in made.enumerated() where !candidate {
                    let attempt = UInt64(index + 1)
                    if !reported.contains(attempt) {
                        state.violations.append(
                            .init(
                                invariant: .attemptOrder,
                                detail: "attempt \(attempt) of work \(work) was refused and never reported"
                            )
                        )
                    }
                }
            }
            for entry in pending where entry.status == .reconciliationRequired {
                let work = state.work(of: entry.outcome.ticket)
                if !(state.reported[work] ?? []).contains(entry.attempts) {
                    state.violations.append(
                        .init(
                            invariant: .attemptOrder,
                            detail:
                                "work \(work) requires reconciliation at attempt \(entry.attempts), which was never reported"
                        )
                    )
                }
            }
        }
    }
}

/// Runs one sequence against a fresh raw shared owner with three held works.
@MainActor final class ExplorerReportsRun: ExplorerRunner {
    /// How a work starts, by `stage(…)`.
    enum Start: String, CaseIterable, Comparable, Sendable {
        case refusedByDelivery = "rD"
        case refusedByReturn = "rR"
        case waitingByDelivery = "aD"
        case waitingByReturn = "aR"
        case running = "run"
        static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Every starting arrangement, works ordered by their starting state (the works are alike, so one
    /// order stands for every permutation), with the drainer held or not and the root edited or not.
    static let stages: [String] = {
        var result: [String] = []
        let kinds = Start.allCases
        for a in kinds.indices {
            for b in a ..< kinds.count {
                for c in b ..< kinds.count {
                    let works = [kinds[a], kinds[b], kinds[c]]
                    if works.allSatisfy({ $0 == .running }) { continue }
                    for held in [false, true] {
                        for edited in [false, true] {
                            var parts = works.map(\.rawValue)
                            if held { parts.append("held") }
                            if edited { parts.append("edit") }
                            result.append(parts.joined(separator: ","))
                        }
                    }
                }
            }
        }
        return result
    }()

    let world: ExplorerWorld
    private let scope = RuntimeScopeID(kind: 1)
    private let log = ExplorerReportsLog()
    private let drivers: ExplorerSelectableDrivers
    private let emission = ExplorerEmissionHold()
    private let box = OSAllocatedUnfairLock<ExplorerReportsHost?>(initialState: nil)
    private let pruning: Bool
    private var owner: ExplorerReportsHost!
    private var works: [Int: RuntimeWork<Int>] = [:]
    private var delivered: Set<Int> = []
    private var named: Set<Int> = []
    private var drainerHeld = false
    private var drainerUsed = false
    private var armUsed = false
    private var emissionArmed = false
    private var driversReleased = false
    private var redelivered = false
    private var nextModel = 10
    private var steps = 0
    // I53: the receipt of the held drainer's batch, and a flush through it that the harness started.
    private var heldReceipt: ExplorerRuntimeEngine.Snapshot?
    private let flushed = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private var flushStarted = false

    init?(verbose: Bool = false, pruning: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        self.pruning = pruning
        let log = log
        drivers = ExplorerSelectableDrivers(log: log)
        let drivers = drivers
        let emission = emission
        let scope = scope
        guard let limits = try? Limits(commits: 8, descriptors: 4, executions: 3) else { return nil }
        owner = ExplorerReportsHost(
            0,
            scopes: [scope],
            limits: limits,
            subscriberCapacity: 3,
            policy: .manual,
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { attempt in
                defer { log.left() }
                guard log.prepare(attempt.outcome, model: attempt.snapshot.model) else {
                    return .failure(.preparation(ExplorerRefusal()))
                }
                // The candidate starts two more works, one more than its retirement frees.
                guard
                    let candidate = try? ExplorerRuntimeEngine.prepare(
                        on: attempt.snapshot,
                        next: attempt.snapshot.model,
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
                else { return .failure(.preparation(ExplorerRefusal())) }
                return .success(candidate)
            },
            reconciliationRequired: { log.report($0) },
            emit: { descriptor in
                if descriptor == 7 { emission.hold() }
                if descriptor == 8 { emission.emitted() }
            }
        )
        let made = owner!
        box.withLock { $0 = made }
    }

    private func setUp() async {
        var starts = drivers.starts.makeAsyncIterator()
        guard
            let candidate = try? ExplorerRuntimeEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [
                    .init(.init(kind: 1, scope: scope), descriptor: 1),
                    .init(.init(kind: 2, scope: scope), descriptor: 2),
                    .init(.init(kind: 3, scope: scope), descriptor: 3),
                ])
            )
        else {
            world.violate(.stuck, "the launch plan was refused")
            return
        }
        _ = owner.commit(candidate)
        while works.count < 3, let work = await starts.next() { works[work.descriptor] = work }
        let tickets = works.values.sorted { $0.descriptor < $1.descriptor }.map(\.ticket)
        log.state.withLock { $0.tickets = tickets }
    }

    /// Works an event may name: every work named so far, and the lowest of the alike unnamed ones.
    private var nameable: [Int] {
        let unnamed = (1 ... 3).filter { !named.contains($0) }
        return (named.sorted() + (unnamed.first.map { [$0] } ?? [])).sorted()
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if steps == 0 { result += Self.stages.map { .stage($0) } }
        let works = nameable
        for work in works where !delivered.contains(work) {
            result += [.refuse(work), .accept(work)]
            if !driversReleased {
                result += [.returnWork(work, accepts: false), .returnWork(work, accepts: true)]
            }
        }
        if !drainerUsed { result.append(.holdDrainer) }
        if drainerHeld { result.append(.releaseDrainer) }
        if drainerHeld, heldReceipt != nil, !flushStarted { result.append(.flushHeld) }
        result.append(.edit)
        result.append(.emit)
        if !emissionArmed, emission.armed.withLock({ $0 == nil }) {
            for work in works { result.append(.arm(.emission, .reconcile(work))) }
            result.append(.arm(.emission, .edit))
        }
        if !driversReleased { result.append(.releaseDrivers) }
        for work in works where pendingID(work) != nil {
            result += [.reconcile(work), .discard(work)]
            // Another payload under the same ticket, once per sequence: the first retained outcome stays.
            if !redelivered { result.append(.redeliver(work)) }
        }
        if !armUsed {
            for source in works {
                for target in works {
                    result += [.onReport(source, .reconcile(target)), .onReport(source, .discard(target))]
                }
            }
        }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        await setUp()
        var enabledAfter = sequence.isEmpty ? enabled() : []
        var redundant = false
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            steps += 1
            let firedBefore = log.state.withLock { $0.fired } + emission.fires.withLock { $0 }
            // H9 sees every batch of capacity conflicts the step's own calls find, before any handler: a
            // batch of two or more with a report armed is a window in which a handler of one conflict can
            // reconcile another.
            let log = log
            await explorerWithCapacityConflictPause({ ids in
                guard ids.count > 1, log.state.withLock({ $0.armed != nil }) else { return }
                explorerL1Windows.withLock { $0 += 1 }
            }) { await perform(event) }
            await settle()
            collect()
            let firedAfter = log.state.withLock { $0.fired } + emission.fires.withLock { $0 }
            if index > 0, pruning, firedAfter == firedBefore {
                switch sequence[index - 1] {
                case .onReport, .arm:
                    redundant = true
                default: break
                }
            }
            if redundant || !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        if !redundant, world.violations.isEmpty {
            // Once more, with its safety net: a report the drainer or a worker makes after the last step's wait
            // is late, not lost.
            await settle()
            log.checkSettled(owner.pendingCompletions())
            collect()
        }
        world.state.withLock { $0.trace.append("reports \(log.state.withLock { $0.reports })") }
        if world.verbose { print("    . reports \(log.state.withLock { $0.reports })") }
        await quiesce()
        if redundant {
            return ExplorerOutcome(violations: [], enabled: [], fingerprint: "", trace: [], redundant: true)
        }
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    /// The step's work is done: the drainer, unless held, has processed everything admitted, and every
    /// entry that requires reconciliation has had its current attempt reported.
    private func settle() async {
        if !drainerHeld { _ = await owner.flush(through: owner.snapshot()) }
        if await !hop(until: { self.log.caughtUp(self.owner.pendingCompletions()) }) {
            world.violate(.attemptOrder, "an entry that requires reconciliation was never reported")
        }
    }
    // Main-actor turns until `condition` holds, with a five-second safety net for the owner's own tasks
    // and the coordinator's workers, which turns do not order.
    private func hop(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task { @MainActor in }.value
        }
        return condition()
    }

    private func collect() {
        let found = log.state.withLock { state -> [ExplorerViolation] in
            defer { state.violations = [] }
            return state.violations
        }
        for violation in found { world.violate(violation.invariant, violation.detail) }
    }

    private func pendingID(_ work: Int) -> RuntimePendingID? {
        guard let ticket = works[work]?.ticket else { return nil }
        return owner.pendingCompletions().first { $0.outcome.ticket == ticket }?.id
    }

    private func outcome(_ work: Int, accepts: Bool) -> ExplorerReportsOutcome? {
        guard let ticket = works[work]?.ticket else { return nil }
        return ExplorerReportsOutcome(ticket: ticket, accepts: accepts, serial: log.nextSerial())
    }

    private func perform(_ event: ExplorerEvent) async {
        named.formUnion(event.works)
        switch event {
        case .stage(let text):
            let parts = text.split(separator: ",").map(String.init)
            let starts = parts.compactMap(Start.init(rawValue:))
            named.formUnion(starts.indices.filter { starts[$0] != .running }.map { $0 + 1 })
            for (index, start) in starts.enumerated() where start == .refusedByDelivery || start == .refusedByReturn {
                await perform(start == .refusedByDelivery ? .refuse(index + 1) : .returnWork(index + 1, accepts: false))
                await settle()
            }
            if parts.contains("held") { await perform(.holdDrainer) }
            for (index, start) in starts.enumerated() where start == .waitingByDelivery || start == .waitingByReturn {
                await perform(start == .waitingByDelivery ? .accept(index + 1) : .returnWork(index + 1, accepts: true))
                await settle()
            }
            if parts.contains("edit") { await perform(.edit) }
        case .refuse(let work), .accept(let work):
            let accepts = if case .accept = event { true } else { false }
            guard let outcome = outcome(work, accepts: accepts) else { return }
            delivered.insert(work)
            log.offered(outcome)
            world.note("deliver \(event): \(owner.deliver(outcome))")
        case .redeliver(let work):
            // DELIVERY-003: a duplicate delivery of a retained completion prepares nothing and keeps the first
            // payload, which I44 checks on every later report.
            redelivered = true
            guard let outcome = outcome(work, accepts: true) else { return }
            let before = log.state.withLock { $0.preparations[work]?.count ?? 0 }
            world.note("redeliver \(work): \(owner.deliver(outcome))")
            let after = log.state.withLock { $0.preparations[work]?.count ?? 0 }
            if after != before {
                world.violate(
                    .attemptOrder,
                    "a duplicate delivery of work \(work)'s retained completion prepared it \(after - before) more times"
                )
            }
        case .returnWork(let work, let accepts):
            guard let outcome = outcome(work, accepts: accepts) else { return }
            delivered.insert(work)
            log.offered(outcome)
            guard await drivers.release(outcome) else { return }
            // The coordinator records the termination, then delivers the outcome from the worker: wait until
            // the outcome is retained past admission and preparation, or its work is no longer active. (The
            // running count is no measure: an accepted outcome may start more work than it ends.)
            let ticket = outcome.ticket
            if await !hop(until: { self.returned(ticket) }) {
                world.violate(.stuck, "work \(work)'s returned outcome was never processed")
            }
        case .releaseDrivers:
            driversReleased = true
            await drivers.releaseAll()
            for _ in 0 ..< 2000 where owner.runningCount > 0 { await Task { @MainActor in }.value }
            if owner.runningCount > 0 { world.violate(.stuck, "the released drivers never finished") }
        case .holdDrainer:
            drainerUsed = true
            drainerHeld = true
            nextModel += 1
            guard
                let candidate = try? ExplorerRuntimeEngine.prepare(
                    on: owner.snapshot(),
                    next: nextModel,
                    plan: .init(emissions: [.init(7, position: 0)])
                )
            else { return }
            if case .committed(let receipt) = owner.commit(candidate) { heldReceipt = receipt }
            await emission.reached()
        case .flushHeld:
            // I53: a flush through the held batch's receipt waits for that batch; it may not return while the
            // batch's emission handler is still held.
            guard let receipt = heldReceipt else { return }
            flushStarted = true
            let owner = owner!
            let flushed = flushed
            Task.detached {
                flushed.withLock { $0 = nil }
                let done = await owner.flush(through: receipt)
                flushed.withLock { $0 = done }
            }
            for _ in 0 ..< 20 { await Task { @MainActor in }.value }
            if let problem = explorerFlushProblem(held: true, result: flushed.withLock { $0 }) {
                world.violate(.flushBoundary, problem)
            }
        case .releaseDrainer:
            drainerHeld = false
            emission.proceed()
            if flushStarted {
                _ = await hop(until: { self.flushed.withLock { $0 } == true })
                if let problem = explorerFlushProblem(held: false, result: flushed.withLock { $0 }) {
                    world.violate(.flushBoundary, problem)
                }
            }
        case .edit:
            nextModel += 1
            guard let candidate = try? ExplorerRuntimeEngine.prepare(on: owner.snapshot(), next: nextModel) else {
                return
            }
            world.note("edit: \(owner.commit(candidate))")
        case .reconcile(let work):
            guard let id = pendingID(work) else { return }
            world.note("reconcile work \(work): \(owner.reconcile(id: id))")
        case .discard(let work):
            guard let id = pendingID(work) else { return }
            world.note("discard work \(work): \(owner.discardPending(id: id))")
        case .emit:
            nextModel += 1
            guard
                let candidate = try? ExplorerRuntimeEngine.prepare(
                    on: owner.snapshot(),
                    next: nextModel,
                    plan: .init(emissions: [.init(8, position: 0)])
                )
            else { return }
            _ = owner.commit(candidate)
        case .arm(.emission, let inner):
            emissionArmed = true
            let action = action(inner)
            emission.armed.withLock { $0 = action }
        case .onReport(let source, let inner):
            armUsed = true
            let action = action(inner)
            log.state.withLock { $0.armed = (source, action) }
        default:
            break
        }
    }

    // Whether the coordinator has delivered a returned outcome: its work is no longer active, or its
    // retained entry is past admission and preparation.
    private func returned(_ ticket: RuntimeTicket) -> Bool {
        guard owner.isActive(ticket) else { return true }
        guard let entry = owner.pendingCompletions().first(where: { $0.outcome.ticket == ticket }) else {
            return false
        }
        return entry.status != .awaitingAdmission && entry.status != .preparing
    }

    // A reconciliation, discard, or edit of the original owner, run from inside a handler.
    private func action(_ inner: ExplorerEvent) -> @Sendable () -> Void {
        let box = box
        let log = log
        let target = inner.works.first
        let ticket = target.flatMap { works[$0]?.ticket }
        let model = nextModel + 100
        let discards = if case .discard = inner { true } else { false }
        return {
            guard let owner = box.withLock({ $0 }) else { return }
            if let ticket, let target {
                let pending = owner.pendingCompletions()
                guard let id = pending.first(where: { $0.outcome.ticket == ticket })?.id else {
                    return
                }
                if !discards { log.reconciling(target, pending) }
                _ = discards ? owner.discardPending(id: id) : owner.reconcile(id: id)
            } else if let candidate = try? ExplorerRuntimeEngine.prepare(on: owner.snapshot(), next: model) {
                _ = owner.commit(candidate)
            }
        }
    }

    private func quiesce() async {
        world.note("quiesce")
        log.state.withLock { $0.armed = nil }
        emission.armed.withLock { $0 = nil }
        if drainerHeld { emission.proceed() }
        _ = owner.close()
        await drivers.releaseAll()
        if let diagnostics = await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) {
            world.violate(.leak, "the owner did not shut down: \(diagnostics)")
        }
        box.withLock { $0 = nil }
    }
}
