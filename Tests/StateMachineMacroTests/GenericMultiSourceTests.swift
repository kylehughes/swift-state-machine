import StateMachine
import Testing
import os

// MARK: - NavigationMachine-style 5-phase .shared schema + omitted phase

nonisolated private protocol NavSelectionCarrying {
    var selectedListID: Int? { get set }
}

nonisolated private protocol NavSheetCarrying: NavSelectionCarrying {
    var sheet: String { get }
}

@StateMachine(mode: .shared, owners: [.owned, .local, .shared])
nonisolated private enum GenericNavigationFlow: Sendable {
    struct Browsing: Sendable, Equatable, NavSelectionCarrying {
        var selectedListID: Int? = nil
    }

    struct Confirming: Sendable, Equatable, NavSelectionCarrying {
        let confirmation: String
        var selectedListID: Int?
    }

    struct PresentingSheet: Sendable, Equatable, NavSheetCarrying {
        let sheet: String
        var selectedListID: Int?
    }

    struct PresentingSheetConfirming: Sendable, Equatable, NavSheetCarrying {
        let confirmation: String
        let sheet: String
        var selectedListID: Int?
    }

    struct PendingNavigation: Sendable, Equatable, NavSelectionCarrying {
        let destination: String
        var selectedListID: Int?
    }

    /// Reachable phase intentionally omitted from `AllNavPhases` to verify explicit membership.
    struct Maintenance: Sendable, Equatable {
        let reason: String
    }

    @Initial case browsing(Browsing = Browsing())
    case confirming(Confirming)
    case presentingSheet(PresentingSheet)
    case presentingSheetConfirming(PresentingSheetConfirming)
    case pendingNavigation(PendingNavigation)
    case maintenance(Maintenance)

    @PhaseSet([
        Browsing.self, Confirming.self, PresentingSheet.self, PresentingSheetConfirming.self, PendingNavigation.self,
    ])
    fileprivate enum AllNavPhases {}

    @PhaseSet([PresentingSheet.self, PresentingSheetConfirming.self])
    fileprivate enum SheetPhases {}

    @PhaseSet([Browsing.self, Confirming.self, PendingNavigation.self])
    fileprivate enum NonSheetPhases {}

    enum Input: Sendable {
        case selectList(Int?)
        case presentSheet(String)
        case dismissSheet
        case presentConfirmation(String)
        case navigate(String)
        case pulse
        case enterMaintenance(String)
        case leaveMaintenance
    }

    @Operation(
        activeIn: [
            Browsing.self, Confirming.self, PresentingSheet.self, PresentingSheetConfirming.self,
            PendingNavigation.self,
        ]
    )
    enum Heartbeat {
        typealias Input = Int
        typealias Output = Void
    }

    @Event enum SelectionLogged {
        typealias Payload = Int
    }

    // Same-phase update across all 5 phases via named @PhaseSet, preserving phase-only fields.
    @Transition(from: AllNavPhases.self, on: Input.selectList)
    fileprivate static func selectList<Source: NavSelectionCarrying>(
        _ source: Source,
        _ listID: Int?
    ) -> Source {
        var next = source
        next.selectedListID = listID
        return next
    }

    // Same-phase Change<Source, Effect.Pulse> using where-clause + starts + emits.
    @Transition(from: AllNavPhases.self, on: Input.pulse, starts: [Heartbeat.self], emits: [SelectionLogged.self])
    fileprivate static func pulse<Source>(
        _ source: Source
    ) -> Change<Source, Effect.Pulse> where Source: NavSelectionCarrying {
        let id = source.selectedListID ?? -1
        return Change(source, effects: [.heartbeat(id), .selectionLogged(id)])
    }

    // Fixed-destination generic transitions via inline list and named @PhaseSets.
    @Transition(from: AllNavPhases.self, on: Input.presentSheet)
    fileprivate static func presentSheet<Source: NavSelectionCarrying>(
        _ source: Source,
        _ sheet: String
    ) -> PresentingSheet {
        PresentingSheet(sheet: sheet, selectedListID: source.selectedListID)
    }

    @Transition(from: SheetPhases.self, on: Input.dismissSheet)
    fileprivate static func dismissSheet<Source: NavSelectionCarrying>(_ source: Source) -> Browsing {
        Browsing(selectedListID: source.selectedListID)
    }

    @Transition(from: NonSheetPhases.self, on: Input.presentConfirmation)
    fileprivate static func presentConfirmation<Source: NavSelectionCarrying>(
        _ source: Source,
        _ confirmation: String
    ) -> Confirming {
        Confirming(confirmation: confirmation, selectedListID: source.selectedListID)
    }

    @Transition(from: SheetPhases.self, on: Input.presentConfirmation)
    fileprivate static func presentConfirmation<Source: NavSheetCarrying>(
        _ source: Source,
        _ confirmation: String
    ) -> PresentingSheetConfirming {
        PresentingSheetConfirming(
            confirmation: confirmation,
            sheet: source.sheet,
            selectedListID: source.selectedListID
        )
    }

    @Transition(from: [Browsing.self, Confirming.self, PresentingSheet.self], on: Input.navigate)
    fileprivate static func navigate<Source: NavSelectionCarrying>(
        _ source: Source,
        _ destination: String
    ) -> PendingNavigation {
        PendingNavigation(destination: destination, selectedListID: source.selectedListID)
    }

    @Transition(on: Input.enterMaintenance)
    fileprivate static func enterMaintenance(_ source: Browsing, _ reason: String) -> Maintenance {
        Maintenance(reason: reason)
    }

    @Transition(on: Input.leaveMaintenance)
    fileprivate static func leaveMaintenance(_ source: Maintenance) -> Browsing {
        Browsing(selectedListID: nil)
    }

    @Transition(onSuccess: Heartbeat.self)
    fileprivate static func heartbeatDoneBrowsing(_ source: Browsing) -> Browsing { source }
    @Transition(onSuccess: Heartbeat.self)
    fileprivate static func heartbeatDoneConfirming(_ source: Confirming) -> Confirming { source }
    @Transition(onSuccess: Heartbeat.self)
    fileprivate static func heartbeatDoneSheet(_ source: PresentingSheet) -> PresentingSheet { source }
    @Transition(onSuccess: Heartbeat.self)
    fileprivate static func heartbeatDoneSheetConfirming(
        _ source: PresentingSheetConfirming
    ) -> PresentingSheetConfirming { source }
    @Transition(onSuccess: Heartbeat.self)
    fileprivate static func heartbeatDonePending(_ source: PendingNavigation) -> PendingNavigation { source }
}

// MARK: - Isolated unconstrained <Source> + protocol-constrained stop

nonisolated private final class IsolatedLog {
    var entries: [String] = []
}

nonisolated private protocol IsolatedDemoPhase {
    var log: IsolatedLog { get }
    var tag: String { get }
}

@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
nonisolated private enum IsolatedGenericFlow {
    struct Idle: IsolatedDemoPhase {
        let log: IsolatedLog
        let tag: String
    }
    struct Active: IsolatedDemoPhase {
        let log: IsolatedLog
        let tag: String
        let detail: Int
    }
    struct Paused: IsolatedDemoPhase {
        let log: IsolatedLog
        let tag: String
        let note: String
    }

    @Initial case idle(Idle)
    case active(Active)
    case paused(Paused)

    @Event enum Touched { typealias Payload = String }

    enum Input {
        case begin(Int)
        case pause(String)
        case touch(String)
        case stop
    }

    @Transition(on: Input.begin)
    fileprivate static func begin(_ source: Idle, _ detail: Int) -> Active {
        Active(log: source.log, tag: source.tag, detail: detail)
    }

    @Transition(on: Input.pause)
    fileprivate static func pause(_ source: Active, _ note: String) -> Paused {
        Paused(log: source.log, tag: source.tag, note: note)
    }

    // Unconstrained <Source> same-phase update emitting an event.
    @Transition(from: [Active.self, Paused.self], on: Input.touch, emits: [Touched.self])
    fileprivate static func touch<Source>(_ source: Source, _ label: String) -> Change<Source, Effect.Touch> {
        Change(source, effects: [.touched(label)])
    }

    // Fixed destination via inline list and protocol constraint.
    @Transition(from: [Active.self, Paused.self], on: Input.stop)
    fileprivate static func stop<Source: IsolatedDemoPhase>(_ source: Source) -> Idle {
        source.log.entries.append("stopped:\(source.tag)")
        return Idle(log: source.log, tag: source.tag)
    }
}

// MARK: - .ownedOnly ~Copyable generic <Source> with Advance<Source, Source, ...>

nonisolated private protocol UniqueTitled: ~Copyable {
    var title: String { get set }
}

nonisolated private protocol HandleCarrying: ~Copyable {
    var title: String { get }
    consuming func takeHandle() -> UniqueGenericArchiveFlow.Handle
}

@StateMachine(mode: .ownedOnly)
nonisolated private enum UniqueGenericArchiveFlow: ~Copyable {
    struct Handle: ~Copyable {
        let id: Int
        let onRelease: @Sendable (Int) -> Void
        deinit { onRelease(id) }
    }

    struct Draft: ~Copyable, UniqueTitled, HandleCarrying {
        var title: String
        let handle: Handle
        consuming func takeHandle() -> Handle { handle }
    }

    struct Review: ~Copyable, UniqueTitled, HandleCarrying {
        var title: String
        let reviewer: String
        let handle: Handle
        consuming func takeHandle() -> Handle { handle }
    }

    struct Archived: ~Copyable {
        let finalTitle: String
        let handle: Handle
    }

    enum RenameFailure: Error, Equatable { case empty }

    @Initial case draft(Draft)
    case review(Review)
    @Terminal case archived(Archived)

    enum Input {
        case submit(String)
        case rename(String)
        case archive
    }

    @Transition(on: Input.submit)
    fileprivate static func submit(_ source: consuming Draft, _ reviewer: String) -> Review {
        Review(title: source.title, reviewer: reviewer, handle: source.handle)
    }

    @Transition(from: [Draft.self, Review.self], on: Input.rename)
    fileprivate static func rename<Source: UniqueTitled & ~Copyable>(
        _ source: consuming Source,
        _ title: String
    ) -> Advance<Source, Source, Never, RenameFailure> {
        guard !title.isEmpty else { return .rejected(.empty, source) }
        var next = source
        next.title = title
        return .advanced(next, effects: [])
    }

    @Transition(from: [Draft.self, Review.self], on: Input.archive)
    fileprivate static func archive<Source: HandleCarrying & ~Copyable>(
        _ source: consuming Source
    ) -> Archived {
        let title = source.title
        let handle = source.takeHandle()
        return Archived(finalTitle: title, handle: handle)
    }
}

// MARK: - Combined Generic <Source> from: + routed: handoff

nonisolated private protocol RoutedTagged {
    var tag: Int { get }
    var note: String { get set }
    var counters: ComposedCounters { get }
}

nonisolated private final class ComposedCounters: Sendable {
    struct Counts: Sendable {
        var routeACalls = 0
        var routeBCalls = 0
        var keepCalls = 0
        var finishCalls = 0
    }
    let counts = OSAllocatedUnfairLock(initialState: Counts())
    var snapshot: Counts { counts.withLock { $0 } }
}

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated private enum ComposedGenericRoutedFlow: Sendable {
    struct StageA: Sendable, Equatable, RoutedTagged {
        let tag: Int
        var note: String
        let aExtra: String
        let counters: ComposedCounters
        static func == (lhs: StageA, rhs: StageA) -> Bool {
            lhs.tag == rhs.tag && lhs.note == rhs.note && lhs.aExtra == rhs.aExtra
        }
    }

    struct StageB: Sendable, Equatable, RoutedTagged {
        let tag: Int
        var note: String
        let bExtra: Int
        let counters: ComposedCounters
        static func == (lhs: StageB, rhs: StageB) -> Bool {
            lhs.tag == rhs.tag && lhs.note == rhs.note && lhs.bExtra == rhs.bExtra
        }
    }

    struct Done: Sendable, Equatable {
        let total: Int
        let note: String
    }

    @Initial case stageA(StageA)
    case stageB(StageB)
    @Terminal case done(Done)

    @PhaseSet([StageA.self, StageB.self])
    fileprivate enum ActiveStages {}

    enum Input: Sendable {
        case advanceToB(Int)
        case decide(Bool)
    }

    @Transition(on: Input.advanceToB)
    fileprivate static func advanceToB(_ source: StageA, _ extra: Int) -> StageB {
        StageB(tag: source.tag, note: source.note, bExtra: extra, counters: source.counters)
    }

    // Same-phase generic + routed!
    @Transition(from: ActiveStages.self, on: Input.decide)
    fileprivate static func keep<Source: RoutedTagged>(
        _ source: Source,
        _ finishNow: Bool,
        routed note: String
    ) -> Source {
        source.counters.counts.withLock { $0.keepCalls += 1 }
        var next = source
        next.note = note
        return next
    }

    // Fixed-destination generic + routed!
    @Transition(from: ActiveStages.self, on: Input.decide)
    fileprivate static func finish<Source: RoutedTagged>(
        _ source: Source,
        _ finishNow: Bool,
        routed delta: Int
    ) -> Done {
        source.counters.counts.withLock { $0.finishCalls += 1 }
        return Done(total: source.tag + delta, note: source.note)
    }

    @Route(on: Input.decide)
    fileprivate static func routeDecide(_ source: StageA, _ finishNow: Bool) -> Route.RouteDecide {
        source.counters.counts.withLock { $0.routeACalls += 1 }
        return finishNow ? .finish(10) : .keep("kept-A")
    }

    @Route(on: Input.decide)
    fileprivate static func routeDecide(_ source: StageB, _ finishNow: Bool) -> Route.RouteDecide {
        source.counters.counts.withLock { $0.routeBCalls += 1 }
        return finishNow ? .finish(20) : .keep("kept-B")
    }
}

// MARK: - Tests

@Suite struct GenericMultiSourceTests {
    private struct Unexpected: Error {}

    @Test func fivePhaseSamePhaseAndFixedGenericTransitionsPreservePhaseOnlyData() async throws {
        // 1. Owned typed API preserves phase-only fields across all 5 phases.
        let browsing = GenericNavigationFlow.owned().selectList(1)
        #expect(browsing.withValue { $0 } == .init(selectedListID: 1))

        let confirming = browsing.presentConfirmation("delete?").selectList(2)
        #expect(confirming.withValue { $0 } == .init(confirmation: "delete?", selectedListID: 2))

        let sheet = confirming.presentSheet("settings").selectList(3)
        #expect(sheet.withValue { $0 } == .init(sheet: "settings", selectedListID: 3))

        let sheetConfirming = sheet.presentConfirmation("discard?").selectList(4)
        #expect(
            sheetConfirming.withValue { $0 }
                == .init(confirmation: "discard?", sheet: "settings", selectedListID: 4)
        )

        let backToBrowsing = sheetConfirming.dismissSheet()
        #expect(backToBrowsing.withValue { $0 } == .init(selectedListID: 4))

        let pending = backToBrowsing.navigate("deep-link").selectList(5)
        #expect(pending.withValue { $0 } == .init(destination: "deep-link", selectedListID: 5))

        // 2. Local + Observed + same-phase Change<Source, Effect.Pulse> + omitted phase rejection.
        var local = GenericNavigationFlow.Local()
        let r1 = try local.send(.presentSheet("history"))
        #expect(r1.edgeID == "browsing.presentSheet")
        guard case .presentingSheet(let observedSheet) = local.snapshot() else { throw Unexpected() }
        let preparedSelect = observedSheet.selectList(99)
        guard case .committed(let selectReceipt) = local.commit(preparedSelect) else { throw Unexpected() }
        #expect(selectReceipt.edgeID == "presentingSheet.selectList")
        guard case .presentingSheet(let afterSelect) = local.snapshot() else { throw Unexpected() }
        #expect(afterSelect.value == .init(sheet: "history", selectedListID: 99))

        let pulseReceipt = try local.send(.pulse)
        #expect(pulseReceipt.edgeID == "presentingSheet.pulse")
        let commands = local.drainCommands(limit: 4).flatMap(\.commands)
        #expect(commands.count == 2)
        guard case .heartbeat(let work) = commands[0], case .selectionLogged(99) = commands[1] else {
            throw Unexpected()
        }
        #expect(work.input == 99)

        try local.send(.dismissSheet)
        try local.send(.enterMaintenance("migrating"))
        // Maintenance is omitted from AllNavPhases, so selectList must reject with .invalidPhase.
        do {
            try local.send(.selectList(123))
            Issue.record("Omitted phase accepted selectList")
        } catch {
            guard case .preparation(.invalidPhase) = error else { throw Unexpected() }
        }

        // 3. Shared managed owner executes generic same-phase pulse effects & event handlers.
        let logged = OSAllocatedUnfairLock(initialState: [Int]())
        let heartbeats = OSAllocatedUnfairLock(initialState: [Int]())
        let shared = GenericNavigationFlow.Shared(
            heartbeatDriver: { input in heartbeats.withLock { $0.append(input) } },
            onSelectionLogged: { value in logged.withLock { $0.append(value) } }
        )
        try shared.send(.presentConfirmation("confirm-shared"))
        try shared.send(.selectList(77))
        let sharedPulse = try shared.send(.pulse)
        #expect(await shared.flush(through: sharedPulse) == .processed)
        guard case .confirming(let sharedConfirming) = shared.snapshot() else { throw Unexpected() }
        #expect(sharedConfirming.value == .init(confirmation: "confirm-shared", selectedListID: 77))
        #expect(logged.withLock { $0 } == [77])
        await shared.shutdown()
    }

    @MainActor
    @Test func isolatedUnconstrainedAndConstrainedGenericFromWorksWithMainActorHost() async throws {
        let log = IsolatedLog()
        let host = IsolatedGenericFlow.MainActorHost(
            .init(log: log, tag: "demo"),
            onTouched: { label in log.entries.append("touched:\(label)") }
        )
        try host.send(.begin(42))
        let r1 = try host.send(.touch("in-active"))
        #expect(await host.flush(through: r1) == .processed)
        guard case .active(let active) = host.currentSnapshot else { throw Unexpected() }
        #expect(active.value.detail == 42)

        try host.send(.pause("holding"))
        let r2 = try host.send(.touch("in-paused"))
        #expect(await host.flush(through: r2) == .processed)
        guard case .paused(let paused) = host.currentSnapshot else { throw Unexpected() }
        #expect(paused.value.note == "holding")

        let r3 = try host.send(.stop)
        #expect(await host.flush(through: r3) == .processed)
        guard case .idle(let idle) = host.currentSnapshot else { throw Unexpected() }
        #expect(idle.value.tag == "demo")
        #expect(log.entries == ["touched:in-active", "touched:in-paused", "stopped:demo"])
        await host.shutdown()
    }

    @Test func ownedOnlyGenericSourceAdvancePreservesResourceAndPhaseOnlyData() {
        let releases = OSAllocatedUnfairLock(initialState: [Int]())
        do {
            let handle = UniqueGenericArchiveFlow.Handle(id: 7) { id in
                releases.withLock { $0.append(id) }
            }
            let draft = UniqueGenericArchiveFlow.owned(.init(title: "v1", handle: handle))
            let review = draft.submit("alice")
            // Rejection preserves Review (including reviewer and move-only handle) with zero premature release.
            switch review.rename("") {
            case .advanced:
                Issue.record("Empty title should be rejected")
            case .rejected(.empty, let unchangedReview):
                #expect(unchangedReview.withValue { $0.title } == "v1")
                #expect(unchangedReview.withValue { $0.reviewer } == "alice")
                #expect(releases.withLock { $0 }.isEmpty)
                switch unchangedReview.rename("v2") {
                case .rejected:
                    Issue.record("Non-empty title should advance")
                case .advanced(let renamedReview, _):
                    #expect(renamedReview.withValue { $0.title } == "v2")
                    #expect(renamedReview.withValue { $0.reviewer } == "alice")
                    #expect(releases.withLock { $0 }.isEmpty)
                    let archived = renamedReview.archive()
                    #expect(archived.withValue { $0.finalTitle } == "v2")
                    #expect(archived.withValue { $0.handle.id } == 7)
                    #expect(releases.withLock { $0 }.isEmpty)
                }
            }
        }
        #expect(releases.withLock { $0 } == [7])
    }

    @Test func combinedGenericFromAndRoutedPreservesPhaseDataAndComputesOnce() throws {
        let counters = ComposedCounters()
        var local = ComposedGenericRoutedFlow.Local(
            .init(tag: 5, note: "init", aExtra: "keep-a", counters: counters)
        )
        // StageA -> keep (same-phase generic + routed).
        let keepA = try local.send(.decide(false))
        #expect(keepA.edgeID == "stageA.keep")
        #expect(counters.snapshot.routeACalls == 1)
        #expect(counters.snapshot.routeBCalls == 0)
        #expect(counters.snapshot.keepCalls == 1)
        #expect(counters.snapshot.finishCalls == 0)
        guard case .stageA(let snapA) = local.snapshot() else { throw Unexpected() }
        #expect(snapA.value == .init(tag: 5, note: "kept-A", aExtra: "keep-a", counters: counters))

        // Move to StageB, then keep via Observed + commit (same-phase generic + routed).
        try local.send(.advanceToB(88))
        guard case .stageB(let observedB) = local.snapshot() else { throw Unexpected() }
        let preparedKeepB = observedB.routeDecide(false)
        guard case .committed(let keepB) = local.commit(preparedKeepB) else { throw Unexpected() }
        #expect(keepB.edgeID == "stageB.keep")
        #expect(counters.snapshot.routeBCalls == 1)
        #expect(counters.snapshot.keepCalls == 2)
        #expect(counters.snapshot.finishCalls == 0)
        guard case .stageB(let snapB) = local.snapshot() else { throw Unexpected() }
        #expect(snapB.value == .init(tag: 5, note: "kept-B", bExtra: 88, counters: counters))

        // StageB -> finish (fixed-destination generic + routed).
        let finishB = try local.send(.decide(true))
        #expect(finishB.edgeID == "stageB.finish")
        #expect(counters.snapshot.routeBCalls == 2)
        #expect(counters.snapshot.keepCalls == 2)
        #expect(counters.snapshot.finishCalls == 1)
        guard case .done(let doneB) = local.snapshot() else { throw Unexpected() }
        #expect(doneB.value == .init(total: 25, note: "kept-B"))

        // Owned path on StageA -> finish.
        let ownedA = ComposedGenericRoutedFlow.owned(
            .init(tag: 3, note: "owned", aExtra: "x", counters: counters)
        )
        switch ownedA.routeDecide(true) {
        case .finish(let done):
            #expect(done.withValue { $0 } == .init(total: 13, note: "owned"))
            #expect(counters.snapshot.routeACalls == 2)
            #expect(counters.snapshot.finishCalls == 2)
        case .keep:
            Issue.record("Expected finish branch")
        }
    }
}
