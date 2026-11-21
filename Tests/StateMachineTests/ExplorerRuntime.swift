import Dispatch
import Foundation
import StateMachine
import StateMachineTestSupport
import os

// The raw-owner slice of the explorer: one `RuntimeSharedHost` driven through its own verbs.
//
// - `counts` (E8): callback and pending-completion registrations that share a capacity of three, their
//   cancellation, and `subscriberCount` read plainly or with `CountReadPause` (H5) bound, so that
//   registrations and cancellations run inside the read after it loaded a version of the state.
//   Invariant I43: a count is one the owner held while it was read, and a registration is refused
//   exactly when every slot is taken.
// - `reconcile` (E4, E13) is `ExplorerReportsRun` (`ExplorerReports.swift`).
//
// Every step is a synchronous call.

typealias ExplorerRuntimeEngine = RuntimeState<Int, Int>

/// A work's terminal outcome, which the completion's preparation accepts or refuses.
nonisolated struct ExplorerFinished: Sendable {
    let ticket: RuntimeTicket
    let accepts: Bool
}

/// Why a completion's preparation refused its outcome.
nonisolated struct ExplorerRefusal: Error, Equatable {}

typealias ExplorerRuntimeHost = RuntimeSharedHost<Int, Int, ExplorerFinished, ExplorerRefusal>

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

/// Runs one sequence of the `counts` family against a fresh raw shared owner.
@MainActor final class ExplorerRuntimeRun: ExplorerRunner {
    let world: ExplorerWorld
    private var owner: ExplorerRuntimeHost!
    private static let capacity = 3
    private var counts: ExplorerCounts!
    private var counted = false

    init?(verbose: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        guard let limits = try? Limits(commits: 8, descriptors: 4, executions: 2) else { return nil }
        owner = ExplorerRuntimeHost(
            0,
            scopes: [],
            limits: limits,
            subscriberCapacity: Self.capacity,
            policy: .manual,
            driver: { ExplorerFinished(ticket: $0.ticket, accepts: false) },
            ticket: { $0.ticket },
            prepare: { _ in .failure(.preparation(ExplorerRefusal())) }
        )
        counts = ExplorerCounts(owner, world, capacity: Self.capacity)
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = [.register, .registerPending, .count]
        if counts.live > 0 { result += [.cancelOldest, .cancelNewest] }
        if !counted {
            for inner in Self.countInners { result.append(.countDuring(inner)) }
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
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            perform(event)
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        counts.cancelAll()
        _ = owner.close()
        if let diagnostics = await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) {
            world.violate(.leak, "the owner did not shut down: \(diagnostics)")
        }
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    private func perform(_ event: ExplorerEvent) {
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
        default:
            counts.perform(event)
        }
    }

    static func flatten(_ event: ExplorerEvent) -> [ExplorerEvent] {
        if case .then(let first, let second) = event { return flatten(first) + flatten(second) }
        return [event]
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
        runOnOwnThread {
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
