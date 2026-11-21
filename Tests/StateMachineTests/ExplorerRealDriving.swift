import Combine
import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineUI

// The real-owner driving slice (70, E3): a driving
// presentation of the profile graph's generated `MainActorHost`, whose drivers fail at once, so a load
// returns to the failed phase on a later main-actor turn through the owner's own subscription. Its verbs:
// `send` through the presentation (`apply`, `sendCancel`), a change the owner admits without the
// presentation (`ownerSend`), `commit` of a proposal made from the snapshot shown (`commitCurrent`), of
// one kept from an earlier snapshot (`saveProposal`, `commitSaved`), and of one made from another owner
// (`commitForeign`), `close`, `stop`, `resume`, releases, turns, and for the Combine class a subscriber.
//
// Invariant I45 here: a call returns the owner's own result, the presentation shows it in the same turn,
// and a proposal is admitted only from the owner's current state: a kept proposal from an older revision
// is rejected, one from another owner is rejected as foreign, and one after `close()` as closed. The
// presentation never shows a revision newer than the owner's, and once the main-actor turns have run, an observing
// presentation shows the owner's current revision (UI-001). I15: the presentation and the owner are
// released once the presentation is gone.

/// Runs one sequence against a driving presentation of a generated `MainActorHost`.
@MainActor final class ExplorerRealDrivingRun: ExplorerRunner {
    typealias Owner = GeneratedProfile.MainActorHost

    /// The presentation, reached through closures so both driving classes share the harness.
    struct Subject {
        let held: () -> Bool
        let alive: () -> Bool
        let snapshot: () -> GeneratedProfile.Snapshot?
        let isObserving: () -> Bool
        let send: (GeneratedProfile.Input) -> UInt64?
        let commit: (consuming Owner.Prepared) -> Owner.CommitResult?
        let close: () -> UInt64?
        let stop: () -> Void
        let resume: () throws(SubscriptionFailure) -> Void
        let drop: () -> Void
        let dropElsewhere: () -> Bool
        let subscribe: ((ExplorerRevisionRecorder) -> Void)?
        /// Installs the `isObserving` report and the snapshot change callbacks; the result keeps them.
        let install:
            (_ report: @escaping @MainActor () -> Void, _ change: @escaping @MainActor () -> Void) -> [AnyObject]
    }

    let kind: ExplorerPassiveKind
    let world: ExplorerWorld
    private weak var owner: Owner?
    private var subject: Subject!
    private let foreign: Owner
    private let user: UserID
    private let request: ProfileRequest
    private var kept: Owner.Prepared?
    private var keptRevision: UInt64?
    private var keptBeforeReset = false
    private var closed = false
    private var turns = 0
    private var recorders: [ExplorerRevisionRecorder] = []
    // Reentry (E15) and I10 on a real owner: the armed callback, the revisions of changes admitted through the
    // presentation (receipts, which a stop does not discard), and the newest revision the presentation could
    // still show when it stopped: what it showed, or what a change callback had announced.
    private var installed: [AnyObject] = []
    private var armed: (ExplorerHook, ExplorerEvent)?
    private var armUsed = false
    private var inHook = false
    private var receipts: Set<UInt64> = []
    private var stoppedAt: UInt64?
    private var announced: UInt64?
    private var lastShown: UInt64 = 0
    private var fired = 0

    init?(_ kind: ExplorerPassiveKind, verbose: Bool = false) {
        self.kind = kind
        world = ExplorerWorld(verbose: verbose)
        guard let user = try? UserID("explorer"), let request = try? ProfileRequest(userID: user) else { return nil }
        self.user = user
        self.request = request
        let owner = Owner(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        foreign = Owner(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        self.owner = owner
        switch kind {
        case .realDrivingCombine:
            let holder = ExplorerHolder(StateMachineObservableObject(owner))
            subject = Subject(
                held: { holder.strong != nil },
                alive: { holder.weak != nil },
                snapshot: { holder.weak?.snapshot },
                isObserving: { holder.weak?.isObserving ?? false },
                send: { input in (try? holder.weak?.send(input))?.revision },
                commit: { prepared in holder.weak?.commit(prepared) },
                close: { holder.weak?.close().revision },
                stop: { holder.weak?.stopObserving() },
                resume: { () throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try explorerResume(presentation)
                },
                drop: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                subscribe: { recorder in
                    holder.weak?.presentedSnapshots.map { (shot: GeneratedProfile.Snapshot) in shot.revision }
                        .subscribe(recorder)
                },
                install: { report, change in
                    guard let presentation = holder.weak else { return [] }
                    let reports = presentation.$isObserving.dropFirst().sink { _ in report() }
                    let changes = presentation.objectWillChange.sink { _ in change() }
                    return [ExplorerKeep((reports, changes))]
                }
            )
        case .realDrivingObservation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let holder = ExplorerHolder(StateMachinePresentation(owner))
            subject = Subject(
                held: { holder.strong != nil },
                alive: { holder.weak != nil },
                snapshot: { holder.weak?.snapshot },
                isObserving: { holder.weak?.isObserving ?? false },
                send: { input in (try? holder.weak?.send(input))?.revision },
                commit: { prepared in holder.weak?.commit(prepared) },
                close: { holder.weak?.close().revision },
                stop: { holder.weak?.stopObserving() },
                resume: { () throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try explorerResume(presentation)
                },
                drop: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                subscribe: nil,
                install: { report, change in
                    let installed = ExplorerKeep(())
                    explorerTrack({ [weak presentation = holder.weak] in presentation?.isObserving }, installed) { _ in
                        report()
                    }
                    explorerTrack({ [weak presentation = holder.weak] in presentation?.snapshot.revision }, installed) {
                        _ in change()
                    }
                    return [installed]
                }
            )
        default:
            return nil
        }
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if subject.held() {
            result += [.apply, .sendCancel, .commitCurrent, .commitForeign, .close, .stop, .dropMain, .dropElsewhere]
            if explorerHasResume { result.append(.resume) }
            if kept == nil { result.append(.saveProposal) } else { result.append(.commitSaved) }
            if subject.subscribe != nil { result.append(.subscribe(saved: false, unlimited: true)) }
        }
        if owner != nil { result += [.ownerSend, .resetOwner] }
        if turns < 2 { result.append(.turn) }
        if subject.held(), !armUsed {
            let resume: [ExplorerEvent] = explorerHasResume ? [.resume, .then(.ownerSend, .then(.resume, .stop))] : []
            for event in [ExplorerEvent.stop] + resume { result.append(.arm(.change, event)) }
            for event in [ExplorerEvent.stop] + resume.prefix(1) { result.append(.arm(.report, event)) }
        }
        return result
    }

    private func fire(_ hook: ExplorerHook) {
        guard !inHook, let (armedHook, event) = armed, armedHook == hook else { return }
        armed = nil
        fired += 1
        // The value whose publication this callback announces is the owner's at most.
        if hook == .change { announced = ownerRevision }
        inHook = true
        world.note("hook \(hook.rawValue) runs \(event)")
        perform(now: event)
        inHook = false
        boundary()
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        installed = subject.install({ [weak self] in self?.fire(.report) }, { [weak self] in self?.fire(.change) })
        lastShown = subject.snapshot()?.revision ?? 0
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            await perform(event)
            boundary()
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

    private var ownerRevision: UInt64? { owner?.snapshot().revision }

    // The proposal the shown snapshot offers: begin a load, cancel it, or retry a failed one.
    private func proposal(from snapshot: GeneratedProfile.Snapshot) -> Owner.Prepared? {
        switch snapshot {
        case .idle(let idle): try? idle.begin(request)
        case .loading(let loading): loading.cancel()
        case .failed(let failed): failed.retry()
        default: nil
        }
    }

    private func perform(_ event: ExplorerEvent) async {
        if event == .turn {
            await Task { @MainActor in }.value
            return
        }
        perform(now: event)
    }

    private func perform(now event: ExplorerEvent) {
        switch event {
        case .then(let first, let second):
            perform(now: first)
            perform(now: second)
        case .arm(let hook, let inner):
            armed = (hook, inner)
            armUsed = true
        case .apply, .sendCancel:
            let input: GeneratedProfile.Input = event == .apply ? .load(request) : .cancel
            let firedBefore = fired
            guard let revision = subject.send(input) else { return }
            receipts.insert(revision)
            // A callback that changed the owner during the call leaves the receipt older than the owner.
            guard !inHook, fired == firedBefore else { return }
            // The owner's receipt, shown in the same turn.
            if revision != ownerRevision {
                world.violate(.drivingResult, "send returned r\(revision) while the owner is at r\(ownerRevision ?? 0)")
            }
            if let shown = subject.snapshot()?.revision, shown != revision {
                world.violate(.drivingResult, "send returned r\(revision) but the presentation shows r\(shown)")
            }
        case .ownerSend:
            _ = try? owner?.send(.cancel)
            _ = try? owner?.send(.load(request))
        case .resetOwner:
            // A proposal kept from before the reset is stale afterward, whatever its revision says.
            if keptRevision != nil { keptBeforeReset = true }
            _ = try? owner?.reset(to: .init(userID: user))
        case .commitCurrent:
            guard let snapshot = subject.snapshot(), let prepared = proposal(from: snapshot) else { return }
            check(commit: prepared, madeAt: snapshot.revision, what: "a current proposal")
        case .saveProposal:
            guard let snapshot = subject.snapshot() else { return }
            kept = proposal(from: snapshot)
            keptRevision = kept == nil ? nil : snapshot.revision
        case .commitSaved:
            guard let prepared = kept.take(), let made = keptRevision else { return }
            keptRevision = nil
            let stale = keptBeforeReset
            keptBeforeReset = false
            if stale {
                guard let result = subject.commit(prepared) else { return }
                if case .rejected(_, let snapshot) = result { receipts.insert(snapshot.revision) }
                if case .committed = result {
                    world.violate(.drivingResult, "a proposal kept from before the owner's reset was committed")
                }
                return
            }
            check(commit: prepared, madeAt: made, what: "a kept proposal")
        case .commitForeign:
            guard let prepared = proposal(from: foreign.snapshot()) else { return }
            guard let result = subject.commit(prepared) else { return }
            if case .rejected(_, let snapshot) = result { receipts.insert(snapshot.revision) }
            guard case .rejected(.foreignOwner, _) = result else {
                world.violate(.drivingResult, "a proposal of another owner was not rejected as foreign: \(result)")
                return
            }
        case .close:
            closed = true
            guard let revision = subject.close() else { return }
            receipts.insert(revision)
            if revision != ownerRevision {
                world.violate(
                    .drivingResult,
                    "close returned r\(revision) while the owner is at r\(ownerRevision ?? 0)"
                )
            }
        case .stop:
            stoppedAt = max(subject.snapshot()?.revision ?? 0, announced ?? 0)
            subject.stop()
        case .resume:
            let before = subject.snapshot()?.revision
            let firedBefore = fired
            do throws(SubscriptionFailure) {
                try subject.resume()
            } catch {
                if subject.snapshot()?.revision != before {
                    world.violate(.resumeContract, "a refused resumeObserving() changed the snapshot")
                }
                return
            }
            stoppedAt = nil
            guard !inHook, fired == firedBefore else { return }
            if closed, subject.isObserving() {
                world.violate(.resumeContract, "resumeObserving() after close() is observing")
            }
            if !closed, !subject.isObserving() {
                world.violate(.resumeContract, "resumeObserving() of an open generated owner is not observing")
            }
        case .subscribe:
            let recorder = ExplorerRevisionRecorder(index: recorders.count, world: world)
            recorders.append(recorder)
            subject.subscribe?(recorder)
        case .dropMain:
            subject.drop()
        case .dropElsewhere:
            if !subject.dropElsewhere() { world.violate(.stuck, "release on a worker never returned") }
        default:
            break
        }
    }

    // A commit returns the owner's own result, which the presentation shows in the same turn; a proposal
    // made from an older revision than the owner's, or after closing, is rejected.
    private func check(commit prepared: consuming Owner.Prepared, madeAt: UInt64, what: String) {
        let current = ownerRevision
        let wasClosed = closed
        let firedBefore = fired
        guard let result = subject.commit(prepared) else { return }
        // A callback that changed the owner during the call leaves the result older than the owner.
        let unchanged = !inHook && fired == firedBefore
        switch result {
        case .committed(let receipt):
            receipts.insert(receipt.revision)
            if wasClosed { world.violate(.drivingResult, "\(what) was committed after close()") }
            guard unchanged else { return }
            if madeAt != current {
                world.violate(
                    .drivingResult,
                    "\(what) made at r\(madeAt) was committed while the owner was at r\(current ?? 0)"
                )
            }
            if let shown = subject.snapshot()?.revision, shown != receipt.revision {
                world.violate(
                    .drivingResult,
                    "commit returned r\(receipt.revision) but the presentation shows r\(shown)"
                )
            }
        case .rejected(let reason, let snapshot):
            // The rejection's snapshot is what the presentation's own call returned, not an observation value.
            receipts.insert(snapshot.revision)
            guard unchanged else { return }
            if wasClosed, reason != .closed {
                world.violate(.drivingResult, "\(what) after close() was rejected as \(reason), not closed")
            }
            if snapshot.revision != ownerRevision {
                world.violate(
                    .drivingResult,
                    "a rejected commit returned r\(snapshot.revision) while the owner is at r\(ownerRevision ?? 0)"
                )
            }
        }
    }

    // The presentation never shows a revision newer than its owner's. A change the owner admits without it
    // arrives through the subscription on a later main-actor turn, so equality while observing is checked
    // once the turns have run (`settled`).
    private func boundary(settled: Bool = false) {
        guard subject.held(), let shown = subject.snapshot()?.revision, let ownerRevision else { return }
        // I10: once stopped, a revision first shown is a receipt of a change admitted through the presentation, or
        // one a change callback announced before the stop; an observation value, such as a resumed registration's
        // deferred seed, is discarded.
        if shown != lastShown, let stoppedAt, shown > stoppedAt, !receipts.contains(shown), !inHook {
            world.violate(
                .shownAfterEnd,
                "r\(shown), an observation value, first shown after the presentation stopped at r\(stoppedAt)"
            )
        }
        if shown != lastShown { announced = nil }
        lastShown = shown
        if settled, subject.isObserving(), shown != ownerRevision {
            world.violate(
                .drivingResult,
                "an observing presentation shows r\(shown) while its owner is at r\(ownerRevision)"
            )
        }
        if shown > ownerRevision {
            world.violate(.drivingResult, "the presentation shows r\(shown), newer than its owner's r\(ownerRevision)")
        }
    }

    private func quiesce() async {
        world.note("quiesce")
        armed = nil
        kept = nil
        for _ in 0 ..< 3 { await Task { @MainActor in }.value }
        boundary(settled: true)
        if subject.held() { subject.drop() }
        for _ in 0 ..< 2000 {
            if !subject.alive(), owner == nil, recorders.allSatisfy(\.finished) { break }
            await Task { @MainActor in }.value
        }
        if subject.alive() || owner != nil {
            world.violate(
                .leak,
                "at quiescence: presentation alive \(subject.alive()), owner alive \(owner != nil)"
            )
        }
        if !recorders.allSatisfy(\.finished) {
            world.violate(.combineFinish, "a subscriber did not finish once the presentation was gone")
        }
        recorders = []
        installed = []
    }
}

/// A subscriber of a presentation's revisions that checks I17 within one owner and I47.
@MainActor final class ExplorerRevisionRecorder {
    let index: Int
    let world: ExplorerWorld
    var values: [UInt64] = []
    var finished = false
    private var subscriptions = 0
    private var completions = 0
    init(index: Int, world: ExplorerWorld) {
        self.index = index
        self.world = world
    }
}

extension ExplorerRevisionRecorder: @MainActor Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    func receive(subscription: any Subscription) {
        subscriptions += 1
        if subscriptions > 1 {
            world.violate(.subscriptionProtocol, "subscriber \(index) received a second subscription")
        }
        subscription.request(.unlimited)
    }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        if let last = values.last, input <= last {
            world.violate(.combineDuplicate, "subscriber \(index) received r\(input) after r\(last)")
        }
        if finished { world.violate(.combineFinish, "subscriber \(index) received r\(input) after finishing") }
        values.append(input)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        completions += 1
        if completions > 1 {
            world.violate(.subscriptionProtocol, "subscriber \(index) received \(completions) completions")
        }
        finished = true
    }
}
