import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineUI
import os

// The owner-forms slice (74): a passive presentation of four
// real generated owners of the profile graph, across their verbs. Owner A is a `Shared`, B an
// `ActorHost`, M an `ActorHost(isolatedTo:)` that shares an actor's executor, and I an
// `IsolatedHost<ExplorerOwnerActor>` confined to an actor other than the main actor, which the
// presentation observes from that actor and which is created and torn down there. In this slice
// `observe(k)` observes owner k, `deliver(k)` makes owner k admit two changes on its own, `finish(k)`
// closes it, and `hostCancelMain(k)` releases the harness's only reference to it (on its actor for I).
//
// Deliveries cross executors that the harness does not order, so the slice is full-mode only, and each
// step waits, with a safety net, for the state it caused to settle. Invariants at the settled state: an
// observing presentation shows its owner's current revision and the owner counts its registration
// (I14); a closed owner leaves the presentation not observing and showing the closed snapshot; a
// released owner leaves it not observing; and once the presentation is released no owner counts a
// registration of it (I15).

/// The non-main actor an isolated generated owner is confined to, which also serves as the executor of
/// the `ActorHost(isolatedTo:)` owner.
actor ExplorerOwnerActor {
    private var host: GeneratedProfile.IsolatedHost<ExplorerOwnerActor>?
    private weak var released: GeneratedProfile.IsolatedHost<ExplorerOwnerActor>?

    func make(_ user: UserID) {
        host = GeneratedProfile.IsolatedHost<ExplorerOwnerActor>(
            .init(userID: user),
            isolation: self,
            fetchDriver: { _, _ in .failure(.unavailable) },
            auditDriver: { _, _ in .failure(.unavailable) }
        )
    }
    func observe(_ presentation: SnapshotObservableObject<GeneratedProfile.Snapshot>) async {
        guard let host else { return }
        try? await presentation.observe(host)
    }
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func observe(_ presentation: SnapshotPresentation<GeneratedProfile.Snapshot>) async {
        guard let host else { return }
        try? await presentation.observe(host)
    }
    func change(_ request: ProfileRequest) {
        _ = try? host?.send(.cancel)
        _ = try? host?.send(.load(request))
    }
    func close() { _ = host?.close() }
    /// Releases the owner here, on its own actor: its teardown runs off the main actor.
    func release() {
        released = host
        host = nil
    }
    var alive: Bool { host != nil || released != nil }
    var state: (revision: UInt64, closed: Bool, subscribers: Int)? {
        guard let host else { return nil }
        let snapshot = host.snapshot()
        return (snapshot.revision, snapshot.isClosed, host.subscriberCount())
    }
}

/// Runs one sequence against a passive presentation of four real generated owners.
@MainActor final class ExplorerOwnerFormsRun: ExplorerRunner {
    typealias Snapshot = GeneratedProfile.Snapshot

    let kind: ExplorerPassiveKind
    let world: ExplorerWorld
    private let request: ProfileRequest
    private var shared: GeneratedProfile.Shared?
    private var actorOwner: GeneratedProfile.ActorHost?
    private var executorOwner: GeneratedProfile.ActorHost?
    private let island = ExplorerOwnerActor()
    private let holder: AnyObject
    private let subject: ExplorerGeneratedSubject
    private let observeOn: (ExplorerOwnerActor) async -> Void
    private let observeActor: (GeneratedProfile.ActorHost) async -> Void
    private var observed: Int?
    private var closed: Set<Int> = []
    private var released: Set<Int> = []
    private var calls: [Task<Void, Never>] = []
    private var turns = 0

    init?(_ kind: ExplorerPassiveKind, verbose: Bool = false) {
        self.kind = kind
        world = ExplorerWorld(verbose: verbose)
        guard let user = try? UserID("explorer"), let request = try? ProfileRequest(userID: user) else { return nil }
        self.request = request
        shared = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        actorOwner = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        executorOwner = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) }),
            isolatedTo: island
        )
        guard let initial = shared?.snapshot() else { return nil }
        switch kind {
        case .ownerFormsCombine:
            let presentation = SnapshotObservableObject(initial)
            let holder = ExplorerHolder(presentation)
            self.holder = holder
            observeOn = { [weak presentation = holder.weak] island in
                guard let presentation else { return }
                await island.observe(presentation)
            }
            observeActor = { [weak presentation = holder.weak] owner in
                guard let presentation else { return }
                try? await presentation.observe(owner)
            }
            subject = ExplorerGeneratedSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                isObserving: { holder.weak?.isObserving },
                observeIsolated: { _ in },
                observeMain: { _ in },
                stop: { holder.weak?.stopObserving() },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() }
            )
            snapshot = { holder.weak?.snapshot }
            observeShared = { (owner) throws(SubscriptionFailure) in try holder.weak?.observe(owner) }
        case .ownerFormsObservation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let presentation = SnapshotPresentation(initial)
            let holder = ExplorerHolder(presentation)
            self.holder = holder
            observeOn = { [weak presentation = holder.weak] island in
                guard let presentation else { return }
                await island.observe(presentation)
            }
            observeActor = { [weak presentation = holder.weak] owner in
                guard let presentation else { return }
                try? await presentation.observe(owner)
            }
            subject = ExplorerGeneratedSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                isObserving: { holder.weak?.isObserving },
                observeIsolated: { _ in },
                observeMain: { _ in },
                stop: { holder.weak?.stopObserving() },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() }
            )
            snapshot = { holder.weak?.snapshot }
            observeShared = { (owner) throws(SubscriptionFailure) in try holder.weak?.observe(owner) }
        default:
            return nil
        }
    }

    private let snapshot: () -> Snapshot?
    private let observeShared: (GeneratedProfile.Shared) throws(SubscriptionFailure) -> Void

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if subject.held() {
            for owner in 0 ..< 4 where !released.contains(owner) { result.append(.observe(owner)) }
            result += [.stop, .dropMain, .dropElsewhere]
        }
        for owner in 0 ..< 4 where !released.contains(owner) {
            if !closed.contains(owner) { result += [.deliver(owner), .finish(owner)] }
            result.append(.hostCancelMain(owner))
        }
        if turns < 2 { result.append(.turn) }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        await island.make(request.userID)
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
        case .observe(let owner):
            observed = owner
            switch owner {
            case 0:
                guard let shared else { return }
                do throws(SubscriptionFailure) { try observeShared(shared) } catch { world.note("refused") }
            case 1, 2:
                guard let actorHost = owner == 1 ? actorOwner : executorOwner else { return }
                let observe = observeActor
                // Started at this step, to its first suspension, so a later step's observation is later.
                guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
                calls.append(Task.immediate { @MainActor in await observe(actorHost) })
            default:
                let observe = observeOn
                let island = island
                guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
                calls.append(Task.immediate { @MainActor in await observe(island) })
            }
        case .stop:
            observed = nil
            subject.stop()
        case .dropMain:
            subject.dropMain()
        case .dropElsewhere:
            if !subject.dropElsewhere() { world.violate(.stuck, "release on a worker never returned") }
        case .deliver(let owner):
            switch owner {
            case 0:
                _ = try? shared?.send(.cancel)
                _ = try? shared?.send(.load(request))
            case 1, 2:
                guard let owner = owner == 1 ? actorOwner : executorOwner else { return }
                _ = try? await owner.send(.cancel)
                _ = try? await owner.send(.load(request))
            default:
                await island.change(request)
            }
        case .finish(let owner):
            closed.insert(owner)
            switch owner {
            case 0: _ = shared?.close()
            case 1: _ = await actorOwner?.close()
            case 2: _ = await executorOwner?.close()
            default: await island.close()
            }
        case .hostCancelMain(let owner):
            released.insert(owner)
            switch owner {
            case 0: shared = nil
            case 1: actorOwner = nil
            case 2: executorOwner = nil
            default: await island.release()
            }
        case .turn:
            await Task { @MainActor in }.value
        default:
            break
        }
    }

    // The observed owner's revision, closed state, and registrations, or `nil` once it is released.
    private func ownerState(_ owner: Int) async -> (revision: UInt64, closed: Bool, subscribers: Int)? {
        switch owner {
        case 0:
            guard let shared else { return nil }
            return (shared.snapshot().revision, shared.snapshot().isClosed, shared.subscriberCount)
        case 1, 2:
            guard let actorHost = owner == 1 ? actorOwner : executorOwner else { return nil }
            let snapshot = await actorHost.snapshot()
            return (snapshot.revision, snapshot.isClosed, await actorHost.subscriberCount)
        default:
            return await island.state
        }
    }

    // What the settled state must be; `nil` when it holds.
    private func unsettled() async -> String? {
        guard subject.held(), let shown = snapshot() else { return nil }
        let observing = subject.isObserving() ?? false
        guard let owner = observed else {
            return observing ? "observing after stopObserving()" : nil
        }
        guard let state = await ownerState(owner) else {
            // A released owner ends the observation.
            return observing ? "observing owner \(owner) after its release" : nil
        }
        if state.closed {
            if observing { return "observing closed owner \(owner)" }
            if !shown.isClosed { return "showing r\(shown.revision) of closed owner \(owner), not its closed snapshot" }
            return nil
        }
        if !observing { return "not observing open owner \(owner)" }
        if shown.revision != state.revision {
            return "showing r\(shown.revision) while owner \(owner) is at r\(state.revision)"
        }
        if state.subscribers != 1 { return "owner \(owner) counts \(state.subscribers) registrations" }
        return nil
    }

    // Waits for the state to settle, with a safety net that fails the run.
    private func settle() async {
        for _ in 0 ..< 2000 {
            if await unsettled() == nil { return }
            await Task { @MainActor in }.value
        }
        if let problem = await unsettled() { world.violate(.finalState, problem) }
    }

    private func quiesce() async {
        world.note("quiesce")
        if subject.held() { subject.dropMain() }
        for call in calls { await call.value }
        calls = []
        for _ in 0 ..< 2000 {
            let left = await registrations()
            if !subject.alive(), left == 0 { break }
            await Task { @MainActor in }.value
        }
        let left = await registrations()
        if subject.alive() || left != 0 {
            world.violate(.leak, "at quiescence: presentation alive \(subject.alive()), owner registrations \(left)")
        }
        // The isolated owner's teardown runs on its own actor.
        await island.release()
        for _ in 0 ..< 2000 {
            if !(await island.alive) { break }
            await Task { @MainActor in }.value
        }
        if await island.alive { world.violate(.leak, "the isolated owner outlived its release on its actor") }
        _ = holder
    }

    private func registrations() async -> Int {
        var total = 0
        for owner in 0 ..< 4 { total += await ownerState(owner)?.subscribers ?? 0 }
        return total
    }
}
