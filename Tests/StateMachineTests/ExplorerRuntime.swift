import Dispatch
import Foundation
import StateMachine
import os

// The raw-owner slice of the explorer: one `RuntimeSharedHost` driven through its own verbs.
//
// - `counts` (E8): callback and pending-completion registrations that share a capacity of three, their
//   cancellation, and `subscriberCount` read plainly or with `CountReadPause` (H5) bound, so that
//   registrations and cancellations run inside the read after it loaded a version of the state.
//   Invariant I43: a count is one the owner held while it was read, and a registration is refused
//   exactly when every slot is taken.
// - `reconcile` (E4, E13): an owner with the manual completion policy and two works running on drivers
//   the harness holds, two executions free. Its verbs: deliver a work's refused or accepted outcome, hold
//   the batch drainer inside an emission handler and let it go, admit an unrelated edit, reconcile or
//   discard a selected retained completion, and arm a reconciliation from inside the reconciliation
//   handler of another completion. Invariant I44: each completion's handler sees its attempts in
//   increasing order, each with the completion's first outcome.
//
// Every step is a synchronous call, except the drivers' starts, the drainer's arrival in its handler
// and the flush after its release, which the harness awaits.

typealias ExplorerRuntimeEngine = RuntimeState<Int, Int>

/// Batches of two or more capacity conflicts reported while a reconciliation was armed (H9), in this
/// process: how often enumeration reached a window in which a handler of one conflict can reconcile
/// another.
let explorerL1Windows = OSAllocatedUnfairLock(initialState: 0)

/// A work's terminal outcome, which the completion's preparation accepts or refuses.
nonisolated struct ExplorerFinished: Sendable {
    let ticket: RuntimeTicket
    let accepts: Bool
}

/// Why a completion's preparation refused its outcome.
nonisolated struct ExplorerRefusal: Error, Equatable {}

typealias ExplorerRuntimeHost = RuntimeSharedHost<Int, Int, ExplorerFinished, ExplorerRefusal>

/// Drivers that stay suspended until the harness releases them, reporting each start.
actor ExplorerHeldDrivers {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let starts: AsyncStream<RuntimeWork<Int>>
    private let started: AsyncStream<RuntimeWork<Int>>.Continuation

    init() { (starts, started) = AsyncStream.makeStream() }
    func run(_ work: RuntimeWork<Int>) async -> ExplorerFinished {
        if !released {
            await withCheckedContinuation {
                waiting.append($0)
                started.yield(work)
            }
        }
        return ExplorerFinished(ticket: work.ticket, accepts: false)
    }
    func releaseAll() {
        released = true
        let prior = waiting
        waiting = []
        for continuation in prior { continuation.resume() }
        started.finish()
    }
}

/// Holds the owner's batch drainer inside one emission handler until the harness lets it go.
nonisolated final class ExplorerEmissionHold: Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let entered = ExplorerSignal()
    func hold() {
        entered.raise()
        _ = explorerWait(held, seconds: 60)
    }
    func reached() async { await entered.wait() }
    func proceed() { held.signal() }
    /// The action armed to run inside the next handler of emission 8, on the drainer's thread.
    let armed = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    /// Armed actions that have run.
    let fires = OSAllocatedUnfairLock(initialState: 0)
    func emitted() {
        let action = armed.withLock { $0.take() }
        guard let action else { return }
        fires.withLock { $0 += 1 }
        action()
    }
}

/// The reconciliation handler's record: each report, and the reconciliation armed to run inside the next
/// report of another completion.
nonisolated final class ExplorerReconciliationLog: Sendable {
    struct Report: Sendable {
        let id: RuntimePendingID
        let work: Int
        let attempts: UInt64
        let accepts: Bool
    }
    struct State: Sendable {
        var reports: [Report] = []
        var firstOutcome: [(id: RuntimePendingID, ticket: RuntimeTicket)] = []
        var armed: (target: Int, action: @Sendable () -> Void)?
        var fired = 0
        var violations: [ExplorerViolation] = []
        var works: [(ticket: RuntimeTicket, work: Int)] = []
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func report(_ pending: ExplorerRuntimeHost.Ledger.Pending) {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            let work = state.works.first { $0.ticket == pending.outcome.ticket }?.work ?? 0
            let name = "work \(work)"
            // I44: attempts in order, each with the completion's first outcome.
            if let last = state.reports.last(where: { $0.id == pending.id }), pending.attempts <= last.attempts {
                state.violations.append(
                    .init(
                        invariant: .attemptOrder,
                        detail:
                            "the reconciliation handler of \(name) saw attempt \(pending.attempts) after attempt \(last.attempts): \(state.reports.filter { $0.id == pending.id }.map(\.attempts) + [pending.attempts])"
                    )
                )
            }
            let first = state.firstOutcome.first { $0.id == pending.id }
            if let first, first.ticket != pending.outcome.ticket {
                state.violations.append(
                    .init(
                        invariant: .attemptOrder,
                        detail: "the retained completion of \(name) changed its first outcome"
                    )
                )
            }
            if first == nil { state.firstOutcome.append((pending.id, pending.outcome.ticket)) }
            state.reports.append(
                Report(id: pending.id, work: work, attempts: pending.attempts, accepts: pending.outcome.accepts)
            )
            // An armed reconciliation runs inside the next report of another completion.
            guard let armed = state.armed, armed.target != work else { return nil }
            state.armed = nil
            state.fired += 1
            return armed.action
        }
        action?()
    }
}

/// Runs one sequence against a fresh raw shared owner.
@MainActor final class ExplorerRuntimeRun: ExplorerRunner {
    let families: ExplorerFamilies
    let world: ExplorerWorld
    private let pruning: Bool
    private let scope = RuntimeScopeID(kind: 1)
    private let drivers = ExplorerHeldDrivers()
    private let emission = ExplorerEmissionHold()
    private let log = ExplorerReconciliationLog()
    private let box = OSAllocatedUnfairLock<ExplorerRuntimeHost?>(initialState: nil)
    private var owner: ExplorerRuntimeHost!
    private static let capacity = 3
    // counts
    private var counts: ExplorerCounts!
    private var counted = false
    // reconcile
    private var works: [Int: RuntimeWork<Int>] = [:]
    private var delivered: Set<Int> = []
    private var drainerHeld = false
    private var drainerUsed = false
    private var armUsed = false
    private var nextModel = 10
    private var namedFirst = false
    private var driversReleased = false
    private var emissionArmed = false

    init?(families: ExplorerFamilies, verbose: Bool = false, pruning: Bool = false) {
        // A replay that names neither family runs both.
        self.families = families.isDisjoint(with: [.counts, .reconcile]) ? [.counts, .reconcile] : families
        self.pruning = pruning
        world = ExplorerWorld(verbose: verbose)
        let drivers = drivers
        let emission = emission
        let log = log
        let scope = scope
        guard let limits = try? Limits(commits: 8, descriptors: 4, executions: 2) else {
            return nil
        }
        owner = ExplorerRuntimeHost(
            0,
            scopes: [scope],
            limits: limits,
            subscriberCapacity: Self.capacity,
            policy: .manual,
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { attempt in
                guard attempt.outcome.accepts else { return .failure(.preparation(ExplorerRefusal())) }
                // The accepted outcome's candidate starts two more works, more than are free.
                guard
                    let candidate = try? ExplorerRuntimeEngine.prepare(
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
        counts = ExplorerCounts(made, world, capacity: Self.capacity)
    }

    private func setUp() async {
        guard families.contains(.reconcile) else { return }
        var starts = drivers.starts.makeAsyncIterator()
        guard
            let candidate = try? ExplorerRuntimeEngine.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [
                    .init(.init(kind: 1, scope: scope), descriptor: 1),
                    .init(.init(kind: 2, scope: scope), descriptor: 2),
                ])
            )
        else {
            world.violate(.stuck, "the launch plan was refused")
            return
        }
        _ = owner.commit(candidate)
        while works.count < 2, let work = await starts.next() { works[work.descriptor] = work }
        let named = works.map { (ticket: $0.value.ticket, work: $0.key) }
        log.state.withLock { $0.works = named }
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if families.contains(.counts) {
            result += [.register, .registerPending, .count]
            if counts.live > 0 { result += [.cancelOldest, .cancelNewest] }
            if !counted {
                for inner in Self.countInners { result.append(.countDuring(inner)) }
            }
        }
        if families.contains(.reconcile) {
            // Symmetry: works 1 and 2 are alike until an event names work 1.
            let named = namedFirst ? [1, 2] : [1]
            for work in named where !delivered.contains(work) { result += [.refuse(work), .accept(work)] }
            if !drainerUsed { result.append(.holdDrainer) }
            result.append(.emit)
            if emission.armed.withLock({ $0 == nil }), !emissionArmed {
                for work in named { result.append(.arm(.emission, .reconcile(work))) }
                result.append(.arm(.emission, .edit))
            }
            if !driversReleased { result.append(.releaseDrivers) }
            if drainerHeld { result.append(.releaseDrainer) }
            result.append(.edit)
            for work in named where pendingID(work) != nil { result += [.reconcile(work), .discard(work)] }
            if !armUsed { for work in named { result.append(.arm(.reconciliation, .reconcile(work))) } }
        }
        return result
    }

    /// The registrations and cancellations that run inside one count's read: every order of up to four.
    static var countInners: [ExplorerEvent] {
        let parts: [ExplorerEvent] = [.register, .cancelOldest]
        var chains: [ExplorerEvent] = parts
        var last: [ExplorerEvent] = parts
        for _ in 1 ..< 4 {
            var grown: [ExplorerEvent] = []
            for chain in last { for part in parts { grown.append(.then(chain, part)) } }
            chains += grown
            last = grown
        }
        return chains
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        await setUp()
        var enabledAfter = sequence.isEmpty ? enabled() : []
        var redundant = false
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            let firedBefore = log.state.withLock { $0.fired } + emission.fires.withLock { $0 }
            // H9 sees every batch of capacity conflicts the step's work finds, before any handler: a batch
            // of two or more with a reconciliation armed is a window in which a handler of one conflict can
            // reconcile another.
            let log = log
            await explorerWithCapacityConflictPause({ ids in
                guard ids.count > 1, log.state.withLock({ $0.armed != nil }) else { return }
                explorerL1Windows.withLock { $0 += 1 }
            }) { await perform(event) }
            // The batch drainer processes each admitted batch on a task of its own, where capacity
            // conflicts are reported: the step ends once it has processed everything admitted so far,
            // unless it is held.
            if families.contains(.reconcile), !drainerHeld { _ = await owner.flush(through: owner.snapshot()) }
            collect()
            let firedAfter = log.state.withLock { $0.fired } + emission.fires.withLock { $0 }
            if index > 0, case .arm = sequence[index - 1], pruning, firedAfter == firedBefore {
                redundant = true
                break
            }
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
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

    private func perform(_ event: ExplorerEvent) async {
        if event.works.contains(1) { namedFirst = true }
        switch event {
        case .countDuring(let inner):
            counted = true
            let read = counts.countDuring(Self.flatten(inner))
            world.note("count read \(read.value) across \(read.history)")
            if !read.history.contains(read.value) {
                world.violate(
                    .countHeld,
                    "subscriberCount returned \(read.value) while the registrations inside the read went through \(read.history)"
                )
            }
        case .register, .registerPending, .cancelOldest, .cancelNewest, .count:
            counts.perform(event)
        case .refuse(let work), .accept(let work):
            guard let ticket = works[work]?.ticket else { return }
            delivered.insert(work)
            let accepts = if case .accept = event { true } else { false }
            let result = owner.deliver(ExplorerFinished(ticket: ticket, accepts: accepts))
            world.note("deliver \(event): \(result)")
        case .releaseDrivers:
            driversReleased = true
            await drivers.releaseAll()
            // Each driver's return is processed on the owner's tasks; wait until none runs.
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
            _ = owner.commit(candidate)
            await emission.reached()
        case .releaseDrainer:
            drainerHeld = false
            emission.proceed()
            _ = await owner.flush(through: owner.snapshot())
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
            // An emission whose handler runs the armed action on the drainer's thread.
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
            let box = box
            let ticket = inner.works.first.flatMap { works[$0]?.ticket }
            let model = nextModel + 100
            emission.armed.withLock {
                $0 = {
                    guard let owner = box.withLock({ $0 }) else { return }
                    if let ticket {
                        guard let id = owner.pendingCompletions().first(where: { $0.outcome.ticket == ticket })?.id
                        else { return }
                        _ = owner.reconcile(id: id)
                    } else if let candidate = try? ExplorerRuntimeEngine.prepare(on: owner.snapshot(), next: model) {
                        _ = owner.commit(candidate)
                    }
                }
            }
        case .arm(.reconciliation, .reconcile(let work)):
            armUsed = true
            let box = box
            let ticket = works[work]?.ticket
            log.state.withLock {
                $0.armed = (
                    work,
                    {
                        guard let owner = box.withLock({ $0 }), let ticket,
                            let id = owner.pendingCompletions().first(where: { $0.outcome.ticket == ticket })?.id
                        else { return }
                        _ = owner.reconcile(id: id)
                    }
                )
            }
        default:
            break
        }
    }

    static func flatten(_ event: ExplorerEvent) -> [ExplorerEvent] {
        if case .then(let first, let second) = event { return flatten(first) + flatten(second) }
        return [event]
    }

    private func quiesce() async {
        world.note("quiesce")
        counts.cancelAll()
        log.state.withLock { $0.armed = nil }
        if drainerHeld { emission.proceed() }
        _ = owner.close()
        await drivers.releaseAll()
        if let diagnostics = await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) {
            world.violate(.leak, "the owner did not shut down: \(diagnostics)")
        }
        collect()
        box.withLock { $0 = nil }
    }
}

/// The counts family's registrations, which a count's pause also changes from inside the read.
///
/// The model count is the number of live registrations held here.
nonisolated final class ExplorerCounts: Sendable {
    let owner: ExplorerRuntimeHost
    let world: ExplorerWorld
    let capacity: Int
    private let tokens = OSAllocatedUnfairLock<[SnapshotSubscription]>(initialState: [])

    init(_ owner: ExplorerRuntimeHost, _ world: ExplorerWorld, capacity: Int) {
        self.owner = owner
        self.world = world
        self.capacity = capacity
    }
    var live: Int { tokens.withLock { $0.count } }

    func perform(_ event: ExplorerEvent) {
        switch event {
        case .register, .registerPending:
            let token: SnapshotSubscription?
            do throws(SubscriptionFailure) {
                token =
                    if case .register = event {
                        try owner.subscribe { _ in }
                    } else {
                        try owner.subscribePending { _ in }
                    }
            } catch {
                token = nil
            }
            let held = live
            if let token {
                tokens.withLock { $0.append(token) }
                if held + 1 > capacity {
                    world.violate(.countHeld, "the owner admitted registration \(held + 1) beyond its capacity")
                }
            } else if held < capacity {
                world.violate(.countHeld, "the owner refused a registration with \(held) of \(capacity) slots taken")
            }
        case .cancelOldest:
            let token = tokens.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            token?.cancel()
        case .cancelNewest:
            let token = tokens.withLock { $0.popLast() }
            token?.cancel()
        case .count:
            let read = owner.subscriberCount
            let held = live
            if read != held {
                world.violate(.countHeld, "subscriberCount returned \(read) while \(held) registrations are live")
            }
        default:
            break
        }
    }

    /// Reads the count with H5 bound: on the read's first pass, after it loaded a version of the state,
    /// `steps` run; returns the count and the live counts before and after each step.
    func countDuring(_ steps: [ExplorerEvent]) -> (value: Int, history: [Int]) {
        let history = OSAllocatedUnfairLock(initialState: [live])
        let ran = OSAllocatedUnfairLock(initialState: false)
        let value = CountReadPause.$afterLoading.withValue({ [self] in
            let first = ran.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            guard first else { return }
            for step in steps {
                perform(step)
                let now = live
                history.withLock { $0.append(now) }
            }
        }) { owner.subscriberCount }
        return (value, history.withLock { $0 })
    }

    func cancelAll() {
        let all = tokens.withLock { tokens -> [SnapshotSubscription] in
            defer { tokens = [] }
            return tokens
        }
        for token in all { token.cancel() }
    }
}

/// The raw owner's `copies` family, copies of a raw owner around its release.
///
/// A manual `RuntimeSharedHost` whose only references are the harness's and one copy, both in slots
/// the harness empties here or on a worker. Its verbs: `register` (a callback registration
/// that records its finish), `copyOwner`, `dropCopy`, `releaseOwner` (here or on a worker), `edit`, and
/// `turn`. Invariant I49: no registration learns of the owner's release while a copy of the owner is
/// kept, and once the last copy is released every registration finishes.
@MainActor final class ExplorerCopiesRun: ExplorerRunner {
    let world: ExplorerWorld
    private let slots = OSAllocatedUnfairLock<[ExplorerRuntimeHost?]>(initialState: [nil, nil])
    private let kept = OSAllocatedUnfairLock(initialState: 0)
    private let finishes = OSAllocatedUnfairLock<[Int]>(initialState: [])
    private var tokens: [SnapshotSubscription] = []
    private var model = 0
    private var turns = 0

    init?(verbose: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        guard let limits = try? Limits() else { return nil }
        let owner = ExplorerRuntimeHost(
            manual: 0,
            scopes: [],
            limits: limits,
            subscriberCapacity: 4,
            ticket: { $0.ticket },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        slots.withLock { $0[0] = owner }
        kept.withLock { $0 = 1 }
    }

    private var current: ExplorerRuntimeHost? { slots.withLock { $0.compactMap { $0 }.first } }
    private var copies: Int { slots.withLock { $0.compactMap { $0 }.count } }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        let held = slots.withLock { $0.map { $0 != nil } }
        if held.contains(true) {
            if tokens.count < 4 { result.append(.register) }
            result.append(.edit)
        }
        if held[0], !held[1] { result.append(.copyOwner) }
        if held[1] { result.append(.dropCopy) }
        if held[0] { result += [.releaseOwner(elsewhere: false), .releaseOwner(elsewhere: true)] }
        if turns < 2 { result.append(.turn) }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            await perform(event)
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .register:
            guard let owner = current else { return }
            let index = tokens.count
            let kept = kept
            let finishes = finishes
            let world = world
            let token = try? owner.subscribe(
                { _ in },
                onFinish: {
                    let copies = kept.withLock { $0 }
                    if copies > 0 {
                        world.violate(
                            .ownerCopies,
                            "registration \(index) finished while \(copies) references to the owner are kept"
                        )
                    }
                    finishes.withLock { $0.append(index) }
                }
            )
            if let token { tokens.append(token) }
        case .edit:
            guard let owner = current else { return }
            model += 1
            guard let candidate = try? ExplorerRuntimeEngine.prepare(on: owner.snapshot(), next: model) else { return }
            _ = owner.commit(candidate)
        case .copyOwner:
            slots.withLock { $0[1] = $0[0] }
            kept.withLock { $0 = 2 }
        case .dropCopy:
            release(1, elsewhere: true)
        case .releaseOwner(let elsewhere):
            release(0, elsewhere: elsewhere)
        case .turn:
            await Task { @MainActor in }.value
        default:
            break
        }
    }

    // Empties a slot here or on a worker; the count of kept references drops first, so a finish that the
    // release causes sees the count it must.
    private func release(_ slot: Int, elsewhere: Bool) {
        let taken = slots.withLock { $0[slot].take() }
        guard let taken else { return }
        let kept = kept
        let remaining = copies
        kept.withLock { $0 = remaining }
        if !elsewhere {
            _ = consume taken
            return
        }
        let box = OSAllocatedUnfairLock<ExplorerRuntimeHost?>(initialState: taken)
        _ = consume taken
        let dropped = DispatchSemaphore(value: 0)
        DispatchQueue.global()
            .async {
                box.withLock { $0 = nil }
                dropped.signal()
            }
        if !explorerWait(dropped) { world.violate(.stuck, "the release on a worker never returned") }
    }

    private func quiesce() async {
        world.note("quiesce")
        release(1, elsewhere: false)
        release(0, elsewhere: false)
        // Each live registration learns of the release on a delivery task: wait for every finish.
        let registered = tokens.count
        for _ in 0 ..< 2000 where finishes.withLock({ $0.count }) < registered {
            await Task { @MainActor in }.value
        }
        let finished = finishes.withLock { $0 }
        if finished.count != registered {
            world.violate(
                .ownerCopies,
                "after the last reference went, registrations \(finished.sorted()) of \(registered) finished"
            )
        }
        tokens = []
    }
}
