import Foundation
import StateMachine
import StateMachineExamples
import StateMachineUI

// The multi-owner slice (E8): three passive presentations of one class and three generated `Shared`
// owners of the profile graph, A and B with two subscriber slots and C with one, and pending-completion
// registrations that take the same slots as the presentations' snapshot registrations. Its verbs:
// `present(p,K)` (presentation p observes owner K, replacing what it observed), `stopP(p)`, `dropP(p)`,
// `pending(K)` (a pending-completion registration on K), `cancelOldest` (the oldest pending
// registration ends), `deliver(K)` (owner K admits two changes on its own), and `turn`.
//
// Invariants: I43 here, an owner refuses a registration exactly when its slots are all taken by live
// presentations and pending registrations; at the settled state (deliveries cross executors, so each step
// waits for it with a safety net) every observing presentation shows its owner's current revision, each
// presentation observes exactly when the model says it holds a slot (I14), and each owner counts the
// model's registrations. I15: once every presentation is released, no owner counts one of theirs.

/// Runs one sequence against three passive presentations of three generated owners.
@MainActor final class ExplorerMultiOwnerRun: ExplorerRunner {
    /// One presentation, reached through closures so both passive classes share the harness.
    struct Presentation {
        let held: () -> Bool
        let alive: () -> Bool
        let isObserving: () -> Bool
        let revision: () -> UInt64?
        let observe: (GeneratedProfile.Shared) throws(SubscriptionFailure) -> Void
        let stop: () -> Void
        let drop: () -> Void
    }

    static let capacities = [2, 2, 1]
    let kind: ExplorerPassiveKind
    let world: ExplorerWorld
    private let owners: [GeneratedProfile.Shared]
    private var presentations: [Presentation] = []
    private let request: ProfileRequest
    // The model: the owner each presentation holds a slot of, and the pending registrations per owner.
    private var observing: [Int?] = [nil, nil, nil]
    private var pending: [(owner: Int, cancel: () -> Void)] = []
    private var turns = 0

    init?(_ kind: ExplorerPassiveKind, verbose: Bool = false) {
        self.kind = kind
        world = ExplorerWorld(verbose: verbose)
        guard let user = try? UserID("explorer"), let request = try? ProfileRequest(userID: user) else { return nil }
        self.request = request
        var made: [GeneratedProfile.Shared] = []
        for capacity in Self.capacities {
            guard let configuration = try? ManagedConfiguration(limits: .default, subscribers: capacity) else {
                return nil
            }
            made.append(
                GeneratedProfile.Shared(
                    .init(userID: user),
                    fetchDriver: { _ in .failure(.unavailable) },
                    auditDriver: { _ in .failure(.unavailable) },
                    configuration: configuration
                )
            )
        }
        owners = made
        let initial = made[0].snapshot()
        for _ in 0 ..< 3 {
            switch kind {
            case .multiCombine:
                let holder = ExplorerHolder(SnapshotObservableObject(initial))
                presentations.append(
                    Presentation(
                        held: { holder.strong != nil },
                        alive: { holder.weak != nil },
                        isObserving: { holder.weak?.isObserving ?? false },
                        revision: { holder.weak?.snapshot.revision },
                        observe: { (owner) throws(SubscriptionFailure) in try holder.weak?.observe(owner) },
                        stop: { holder.weak?.stopObserving() },
                        drop: { holder.dropMain() }
                    )
                )
            case .multiObservation:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
                let holder = ExplorerHolder(SnapshotPresentation(initial))
                presentations.append(
                    Presentation(
                        held: { holder.strong != nil },
                        alive: { holder.weak != nil },
                        isObserving: { holder.weak?.isObserving ?? false },
                        revision: { holder.weak?.snapshot.revision },
                        observe: { (owner) throws(SubscriptionFailure) in try holder.weak?.observe(owner) },
                        stop: { holder.weak?.stopObserving() },
                        drop: { holder.dropMain() }
                    )
                )
            default:
                return nil
            }
        }
    }

    private func taken(_ owner: Int, except presentation: Int? = nil) -> Int {
        let presenting = observing.indices.filter { $0 != presentation && observing[$0] == owner }.count
        return presenting + pending.filter { $0.owner == owner }.count
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        for index in 0 ..< 3 where presentations[index].held() {
            for owner in 0 ..< 3 { result.append(.present(index, owner)) }
            if observing[index] != nil { result.append(.stopP(index)) }
            result.append(.dropP(index))
        }
        for owner in 0 ..< 3 { result += [.pending(owner), .deliver(owner)] }
        if !pending.isEmpty { result.append(.cancelOldest) }
        if turns < 2 { result.append(.turn) }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            await perform(event)
            await settle()
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
        case .present(let index, let owner):
            // A new observation releases the one it replaces first, so re-observing the same owner reuses
            // its slot (UI-004).
            let full = taken(owner, except: index) >= Self.capacities[owner]
            do throws(SubscriptionFailure) {
                try presentations[index].observe(owners[owner])
                observing[index] = owner
                if full {
                    world.violate(.countHeld, "owner \(owner) admitted presentation \(index) with every slot taken")
                }
            } catch {
                observing[index] = nil
                if !full {
                    world.violate(
                        .countHeld,
                        "owner \(owner) refused presentation \(index) with \(taken(owner)) of \(Self.capacities[owner]) slots taken"
                    )
                }
            }
        case .stopP(let index):
            observing[index] = nil
            presentations[index].stop()
        case .dropP(let index):
            observing[index] = nil
            presentations[index].drop()
        case .pending(let owner):
            let full = taken(owner) >= Self.capacities[owner]
            do throws(SubscriptionFailure) {
                let sequence = try owners[owner].pendingCompletionUpdates()
                pending.append((owner, { sequence.cancel() }))
                if full {
                    world.violate(.countHeld, "owner \(owner) admitted a pending registration with every slot taken")
                }
            } catch {
                if !full {
                    world.violate(
                        .countHeld,
                        "owner \(owner) refused a pending registration with \(taken(owner)) of \(Self.capacities[owner]) slots taken"
                    )
                }
            }
        case .cancelOldest:
            guard !pending.isEmpty else { return }
            pending.removeFirst().cancel()
        case .deliver(let owner):
            _ = try? owners[owner].send(.cancel)
            _ = try? owners[owner].send(.load(request))
        case .turn:
            await Task { @MainActor in }.value
        default:
            break
        }
    }

    // What the settled state must be; `nil` when it holds.
    private func unsettled() -> String? {
        for index in 0 ..< 3 where presentations[index].held() {
            let live = presentations[index].isObserving()
            guard let owner = observing[index] else {
                if live { return "presentation \(index) observes with no slot in the model" }
                continue
            }
            if !live { return "presentation \(index) does not observe owner \(owner)" }
            if presentations[index].revision() != owners[owner].snapshot().revision {
                return
                    "presentation \(index) shows r\(presentations[index].revision() ?? 0) while owner \(owner) is at r\(owners[owner].snapshot().revision)"
            }
        }
        for owner in 0 ..< 3 where owners[owner].subscriberCount != taken(owner) {
            return "owner \(owner) counts \(owners[owner].subscriberCount) registrations, the model \(taken(owner))"
        }
        return nil
    }

    private func settle() async {
        for _ in 0 ..< 2000 {
            if unsettled() == nil { return }
            await Task { @MainActor in }.value
        }
        if let problem = unsettled() { world.violate(.finalState, problem) }
    }

    private func quiesce() async {
        world.note("quiesce")
        for index in 0 ..< 3 where presentations[index].held() { presentations[index].drop() }
        for entry in pending { entry.cancel() }
        pending = []
        observing = [nil, nil, nil]
        for _ in 0 ..< 2000 {
            if presentations.allSatisfy({ !$0.alive() }), owners.allSatisfy({ $0.subscriberCount == 0 }) { return }
            await Task { @MainActor in }.value
        }
        world.violate(
            .leak,
            "at quiescence: presentations alive \(presentations.map { $0.alive() }), owner registrations \(owners.map(\.subscriberCount))"
        )
    }
}
