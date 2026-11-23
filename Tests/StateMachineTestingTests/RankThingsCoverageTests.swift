import StateMachine
import StateMachineTesting
import Testing

nonisolated private protocol CoverageSelection {
    var selectedID: Int? { get set }
}

nonisolated private protocol CoverageSheet: CoverageSelection {
    var sheet: String { get }
}

/// Five-phase navigation-style graph with a generic same-phase self-loop across a `@PhaseSet`,
/// plus a sixth reachable phase omitted from the set.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum FiveLoopNavigation: Sendable {
    struct Browsing: Sendable, CoverageSelection { var selectedID: Int? = nil }
    struct Confirming: Sendable, CoverageSelection {
        let prompt: String
        var selectedID: Int?
    }
    struct PresentingSheet: Sendable, CoverageSheet {
        let sheet: String
        var selectedID: Int?
    }
    struct PresentingSheetConfirming: Sendable, CoverageSheet {
        let prompt: String
        let sheet: String
        var selectedID: Int?
    }
    struct PendingNavigation: Sendable, CoverageSelection {
        let target: String
        var selectedID: Int?
    }
    struct Locked: Sendable { let reason: String }

    @Initial case browsing(Browsing = Browsing())
    case confirming(Confirming)
    case presentingSheet(PresentingSheet)
    case presentingSheetConfirming(PresentingSheetConfirming)
    case pendingNavigation(PendingNavigation)
    case locked(Locked)

    @PhaseSet([
        Browsing.self, Confirming.self, PresentingSheet.self, PresentingSheetConfirming.self, PendingNavigation.self,
    ])
    fileprivate enum AllInteractive {}

    enum Input: Sendable {
        case selectList(Int?)
        case confirm(String)
        case showSheet(String)
        case confirmOnSheet(String)
        case navigate(String)
        case resolve
        case lock(String)
        case unlock
    }

    @Transition(from: AllInteractive.self, on: Input.selectList)
    fileprivate static func selectList<Source: CoverageSelection>(_ source: Source, _ id: Int?) -> Source {
        var next = source
        next.selectedID = id
        return next
    }

    @Transition(on: Input.confirm)
    fileprivate static func confirm(_ source: Browsing, _ prompt: String) -> Confirming {
        Confirming(prompt: prompt, selectedID: source.selectedID)
    }

    @Transition(on: Input.showSheet)
    fileprivate static func showSheet(_ source: Confirming, _ sheet: String) -> PresentingSheet {
        PresentingSheet(sheet: sheet, selectedID: source.selectedID)
    }

    @Transition(on: Input.confirmOnSheet)
    fileprivate static func confirmOnSheet(
        _ source: PresentingSheet,
        _ prompt: String
    ) -> PresentingSheetConfirming {
        PresentingSheetConfirming(prompt: prompt, sheet: source.sheet, selectedID: source.selectedID)
    }

    @Transition(on: Input.navigate)
    fileprivate static func navigate(
        _ source: PresentingSheetConfirming,
        _ target: String
    ) -> PendingNavigation {
        PendingNavigation(target: target, selectedID: source.selectedID)
    }

    @Transition(on: Input.resolve)
    fileprivate static func resolveToBrowsing(
        _ source: PendingNavigation,
        routed selectedID: Int?
    ) -> Browsing {
        Browsing(selectedID: selectedID)
    }

    @Transition(on: Input.resolve)
    fileprivate static func resolveToSheet(
        _ source: PendingNavigation,
        routed target: (selectedID: Int?, sheet: String)
    ) -> PresentingSheet {
        PresentingSheet(sheet: target.sheet, selectedID: target.selectedID)
    }

    @Route(on: Input.resolve)
    fileprivate static func routeResolve(_ source: PendingNavigation) -> Route.RouteResolve {
        if source.target == "sheet" {
            return .resolveToSheet((selectedID: source.selectedID, sheet: "resolved"))
        }
        return .resolveToBrowsing(source.selectedID)
    }

    @Transition(on: Input.lock)
    fileprivate static func lock(_ source: Browsing, _ reason: String) -> Locked {
        Locked(reason: reason)
    }

    @Transition(on: Input.unlock)
    fileprivate static func unlock(_ source: Locked) -> Browsing {
        Browsing(selectedID: nil)
    }
}

/// Combined generic `from:` + `routed:` graph verifying exact per-branch edge IDs.
nonisolated private protocol CoverageTagged {
    var value: Int { get set }
}

@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum GenericRoutedCoverageGraph: Sendable {
    struct StageA: Sendable, CoverageTagged { var value: Int = 1 }
    struct StageB: Sendable, CoverageTagged { var value: Int }
    struct Done: Sendable { let total: Int }

    @Initial case stageA(StageA = StageA())
    case stageB(StageB)
    @Terminal case done(Done)

    enum Input: Sendable {
        case move
        case step(Bool)
    }

    @Transition(on: Input.move)
    fileprivate static func move(_ source: StageA) -> StageB { StageB(value: source.value) }

    @Transition(from: [StageA.self, StageB.self], on: Input.step)
    fileprivate static func keep<Source: CoverageTagged>(
        _ source: Source,
        _ finishNow: Bool,
        routed delta: Int
    ) -> Source {
        var next = source
        next.value += delta
        return next
    }

    @Transition(from: [StageA.self, StageB.self], on: Input.step)
    fileprivate static func finish<Source: CoverageTagged>(
        _ source: Source,
        _ finishNow: Bool,
        routed bonus: Int
    ) -> Done {
        Done(total: source.value + bonus)
    }

    @Route(on: Input.step)
    fileprivate static func routeStep(_ source: StageA, _ finishNow: Bool) -> Route.RouteStep {
        finishNow ? .finish(10) : .keep(1)
    }

    @Route(on: Input.step)
    fileprivate static func routeStep(_ source: StageB, _ finishNow: Bool) -> Route.RouteStep {
        finishNow ? .finish(20) : .keep(2)
    }
}

@Suite struct RankThingsCoverageTests {
    @Test func genericSamePhaseProducesFiveTrueSelfLoopsAndRejectsOmittedPhase() throws {
        #expect(FiveLoopNavigation.graph.formatVersion == 2)
        let selectEdges = FiveLoopNavigation.graph.edges.filter { $0.name == "selectList" }
        #expect(selectEdges.count == 5)
        #expect(
            selectEdges.map { "\($0.id):\($0.source)->\($0.destination)" } == [
                "browsing.selectList:browsing->browsing",
                "confirming.selectList:confirming->confirming",
                "presentingSheet.selectList:presentingSheet->presentingSheet",
                "presentingSheetConfirming.selectList:presentingSheetConfirming->presentingSheetConfirming",
                "pendingNavigation.selectList:pendingNavigation->pendingNavigation",
            ]
        )
        // Omitted phase `locked` has no `selectList` edge.
        #expect(!FiveLoopNavigation.graph.edges.contains { $0.id == "locked.selectList" })

        var partial = ManualMachineTest(FiveLoopNavigation.Local())
        // Exercise only 4 of the 5 self-loops (omitting pendingNavigation.selectList) and only 1 routed branch.
        try partial.send(.selectList(1))
        try partial.send(.confirm("c"))
        try partial.send(.selectList(2))
        try partial.send(.showSheet("s"))
        try partial.send(.selectList(3))
        try partial.send(.confirmOnSheet("sc"))
        try partial.send(.selectList(4))
        try partial.send(.navigate("home"))
        try partial.send(.resolve)
        try partial.send(.lock("busy"))
        // Omitted phase rejects selectList at runtime.
        let rejection = try partial.rejection(of: .selectList(99))
        guard case .preparation(.invalidPhase) = rejection else {
            Issue.record("Expected invalidPhase, got \(rejection)")
            return
        }
        try partial.send(.unlock)

        var coverage = GraphCoverage(for: FiveLoopNavigation.Local.self)
        coverage.record(partial)
        #expect(
            coverage.unexercisedEdges.map(\.id) == [
                "pendingNavigation.selectList",
                "pendingNavigation.resolveToSheet",
            ]
        )
        #expect(throws: StateMachineTestFailure.self) { try coverage.requireCoverage() }

        // Now exercise the 5th self-loop and the second routed branch (.resolveToSheet).
        var rest = ManualMachineTest(FiveLoopNavigation.Local())
        try rest.send(.confirm("c"))
        try rest.send(.showSheet("s"))
        try rest.send(.confirmOnSheet("sc"))
        try rest.send(.navigate("sheet"))
        let fifthLoop = try rest.send(.selectList(5))
        #expect(fifthLoop.edgeID == "pendingNavigation.selectList")
        let toSheet = try rest.send(.resolve)
        #expect(toSheet.edgeID == "pendingNavigation.resolveToSheet")
        coverage.record(rest)
        #expect(coverage.unexercisedEdges.isEmpty)
        #expect(coverage.unexercisedRouters.isEmpty)
        try coverage.requireCoverage()
    }

    @Test func combinedGenericFromAndRoutedPreservesPerBranchEdgeCoverage() throws {
        var runA = ManualMachineTest(GenericRoutedCoverageGraph.Local())
        let keepA = try runA.send(.step(false))
        #expect(keepA.edgeID == "stageA.keep")
        let finishA = try runA.send(.step(true))
        #expect(finishA.edgeID == "stageA.finish")

        var coverage = GraphCoverage(for: GenericRoutedCoverageGraph.Local.self)
        coverage.record(runA)
        #expect(coverage.unexercisedEdges.map(\.id) == ["stageA.move", "stageB.keep", "stageB.finish"])
        #expect(throws: StateMachineTestFailure.self) { try coverage.requireCoverage() }

        var runB = ManualMachineTest(GenericRoutedCoverageGraph.Local())
        try runB.send(.move)
        let keepB = try runB.send(.step(false))
        #expect(keepB.edgeID == "stageB.keep")
        let finishB = try runB.send(.step(true))
        #expect(finishB.edgeID == "stageB.finish")

        coverage.record(runB)
        #expect(coverage.unexercisedEdges.isEmpty)
        try coverage.requireCoverage()
    }
}
