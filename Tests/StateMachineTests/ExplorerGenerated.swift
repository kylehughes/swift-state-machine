import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineUI
import os

// The generated-owner slice: a passive presentation observing the profile graph's generated
// `IsolatedHost<MainActor>` (owner 0) and `MainActorHost` (owner 1) through their synchronous
// `observe(_:)` overloads. Those owners admit through a registration gate that a presentation released
// on another thread closes at once. Invariant I31: when such a release returns, before any main-actor
// turn, the owner counts no subscriber of the presentation (OBS-005).

/// One passive presentation of generated snapshots, reached through closures.
@MainActor struct ExplorerGeneratedSubject {
    let alive: () -> Bool
    let held: () -> Bool
    let isObserving: () -> Bool?
    let observeIsolated: (GeneratedProfile.IsolatedHost<MainActor>) throws(SubscriptionFailure) -> Void
    let observeMain: (GeneratedProfile.MainActorHost) throws(SubscriptionFailure) -> Void
    let stop: () -> Void
    let dropMain: () -> Void
    let dropElsewhere: () -> Bool
    let dropAfterJob: () async -> Void

    static func make(_ kind: ExplorerPassiveKind, initial: GeneratedProfile.Snapshot) -> ExplorerGeneratedSubject? {
        switch kind {
        case .generatedCombine:
            let holder = ExplorerHolder(SnapshotObservableObject(initial))
            return ExplorerGeneratedSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                isObserving: { holder.weak?.isObserving },
                observeIsolated: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeMain: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                stop: { holder.weak?.stopObserving() },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() }
            )
        case .generatedObservation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let holder = ExplorerHolder(SnapshotPresentation(initial))
            return ExplorerGeneratedSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                isObserving: { holder.weak?.isObserving },
                observeIsolated: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeMain: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                stop: { holder.weak?.stopObserving() },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() }
            )
        default:
            return nil
        }
    }
}

/// Runs one sequence against a passive presentation of the two generated owners.
@MainActor final class ExplorerGeneratedRun: ExplorerRunner {
    let kind: ExplorerPassiveKind
    let world: ExplorerWorld
    private let isolatedOwner: GeneratedProfile.IsolatedHost<MainActor>
    private let mainOwner: GeneratedProfile.MainActorHost
    private var subject: ExplorerGeneratedSubject!
    private var turns = 0

    init?(_ kind: ExplorerPassiveKind, verbose: Bool = false) {
        self.kind = kind
        world = ExplorerWorld(verbose: verbose)
        guard let user = try? UserID("explorer") else { return nil }
        isolatedOwner = GeneratedProfile.IsolatedHost<MainActor>(
            .init(userID: user),
            isolation: MainActor.shared,
            fetchDriver: { _, _ in .failure(.unavailable) },
            auditDriver: { _, _ in .failure(.unavailable) }
        )
        mainOwner = GeneratedProfile.MainActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        guard let subject = ExplorerGeneratedSubject.make(kind, initial: isolatedOwner.snapshot()) else { return nil }
        self.subject = subject
    }

    private var counts: (Int, Int) { (isolatedOwner.subscriberCount(), mainOwner.subscriberCount) }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if subject.held() {
            result += [.observe(0), .observe(1), .stop, .dropMain, .dropElsewhere, .dropAfterJob]
        }
        if turns < 2 { result.append(.turn) }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            switch event {
            case .observe(let owner):
                do throws(SubscriptionFailure) {
                    if owner == 0 {
                        try subject.observeIsolated(isolatedOwner)
                    } else {
                        try subject.observeMain(mainOwner)
                    }
                } catch {
                    world.note("refused: \(error)")
                }
            case .stop: subject.stop()
            case .dropMain: subject.dropMain()
            case .dropElsewhere:
                if !subject.dropElsewhere() { world.violate(.stuck, "release on a worker never returned") }
                // No main-actor turn has run since the release returned.
                if counts != (0, 0), !subject.alive() {
                    world.violate(
                        .gateNotClosed,
                        "a presentation released on another thread left subscribers \(counts) when its release returned"
                    )
                }
            case .dropAfterJob: await subject.dropAfterJob()
            case .turn: await Task { @MainActor in }.value
            default: break
            }
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        await quiesce()
        return ExplorerOutcome(violations: world.violations, enabled: enabledAfter, fingerprint: "", trace: [])
    }

    private func quiesce() async {
        if subject.held(), world.violations.isEmpty {
            var settled = false
            for _ in 0 ..< 30 {
                let live = subject.isObserving() ?? false
                if live == (counts.0 + counts.1 == 1), counts.0 + counts.1 <= 1 {
                    settled = true
                    break
                }
                await Task { @MainActor in }.value
            }
            if !settled {
                world.violate(
                    .finalState,
                    "isObserving \(subject.isObserving() ?? false) with owner subscribers \(counts)"
                )
            }
        }
        if subject.held() { subject.dropMain() }
        for _ in 0 ..< 2000 {
            if !subject.alive(), counts == (0, 0) { return }
            await Task { @MainActor in }.value
        }
        world.violate(.leak, "at quiescence: presentation alive \(subject.alive()), owner subscribers \(counts)")
    }
}
