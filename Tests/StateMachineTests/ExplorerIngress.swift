import Dispatch
import Foundation
import StateMachineUI
import os

// The ingress slice (E12): a `MainActorSnapshotIngress` of the explorer's client values. Its verbs: `offer`
// (a newer revision, from the main thread), `deliverElsewhere(A)` (a newer one from a worker while the
// main actor waits), `applyBelow` (a revision below the newest offered so far), `request` (a burst of 40
// newer offers in one step), `echo(A)` (from then on every delivery offers a newer value from inside the
// callback, up to 100), `stop` (`cancel()`), and `turn`.
//
// Invariant I50 (`MainActorSnapshotIngress`, "at most one responsible delivery task"): deliveries never
// overlap, so no delivery begins inside another; they carry strictly increasing revisions, each one
// staged (newer than every revision offered before it); none begins after `cancel()` returned; and once
// the ingress is idle, unless cancelled, the newest staged value has been delivered. A delivery task
// applies at most 32 values before it gives up the main actor (I32's bound).

/// Runs one sequence against a fresh ingress.
@MainActor final class ExplorerIngressRun: ExplorerRunner {
    let world: ExplorerWorld
    private var ingress: MainActorSnapshotIngress<ExplorerShot>!
    private var delivered: [UInt64] = []
    private var depth = 0
    private var cancelled = false
    private var newest: UInt64 = 0
    private var staged: UInt64?
    private var echoing = false
    private var echoes = 0
    private var turns = 0
    // Deliveries since the first one of the current main-actor job (I32's bound).
    private var batch = 0
    private var batchOpen = false

    init(verbose: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        // The ingress releases a replaced value where the offer that replaced it runs: no executor is promised.
        world.state.withLock { $0.offMainExempt = true }
        ingress = MainActorSnapshotIngress { [weak self] shot in self?.received(shot) }
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = [.apply, .deliverElsewhere(0), .applyBelow, .request]
        if !echoing { result.append(.echo(0)) }
        if !cancelled { result.append(.stop) }
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

    // Offers a value of `revision`; it is staged when it is newer than everything offered before.
    private func offer(_ revision: UInt64? = nil, elsewhere: Bool = false) {
        let value = world.makeValue(.applied(attempt: nil), attempt: nil, revision: revision)
        let revision = value.revision
        if revision > newest {
            newest = revision
            if !cancelled { staged = revision }
        }
        guard elsewhere else {
            ingress.offer(value, revision: revision)
            return
        }
        let slot = OSAllocatedUnfairLock<ExplorerShot?>(initialState: value)
        _ = consume value
        let ingress = ingress!
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global()
            .async {
                if let shot = slot.withLock({ $0.take() }) { ingress.offer(shot, revision: revision) }
                done.signal()
            }
        if !explorerWait(done) { world.violate(.stuck, "an offer on a worker never returned") }
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .apply: offer()
        case .deliverElsewhere: offer(elsewhere: true)
        case .applyBelow: offer(newest >= 5 ? newest - 5 : 0)
        case .request: for _ in 0 ..< 40 { offer() }
        case .echo: echoing = true
        case .stop:
            cancelled = true
            staged = nil
            ingress.cancel()
        case .turn: await Task { @MainActor in }.value
        default: break
        }
    }

    private func received(_ shot: ExplorerShot) {
        depth += 1
        defer { depth -= 1 }
        if depth > 1 {
            world.violate(.ingressDelivery, "a delivery of r\(shot.revision) began inside another delivery")
        }
        if cancelled { world.violate(.ingressDelivery, "r\(shot.revision) was delivered after cancel() returned") }
        if let last = delivered.last, shot.revision <= last {
            world.violate(.ingressDelivery, "r\(shot.revision) was delivered after r\(last)")
        }
        delivered.append(shot.revision)
        world.considered(shot.id)
        if !batchOpen {
            batchOpen = true
            batch = 0
            Task { @MainActor [weak self] in self?.batchOpen = false }
        }
        batch += 1
        if batch == 33 { world.violate(.ingressDelivery, "33 values were delivered in one main-actor job") }
        if echoing, echoes < 100 {
            echoes += 1
            offer()
        }
    }

    private func quiesce() async {
        world.note("quiesce")
        echoing = false
        // The delivery task gives up the main actor after 32 values; wait for it to drain.
        for _ in 0 ..< 2000 {
            if cancelled || staged == nil || delivered.last == staged { break }
            await Task { @MainActor in }.value
        }
        if !cancelled, let staged, delivered.last != staged {
            world.violate(
                .ingressDelivery,
                "the ingress went idle with r\(staged) staged but last delivered \(delivered.last.map { "r\($0)" } ?? "nothing")"
            )
        }
        ingress.cancel()
        ingress = nil
        for _ in 0 ..< 2000 {
            if world.liveValues().isEmpty { return }
            await Task { @MainActor in }.value
        }
        world.violate(.leak, "values outlived the ingress: \(world.liveValues().count)")
    }
}
