import StateMachine
import StateMachineExamples
import StateMachineTesting
import Testing

/// A lamp whose one input reaches two self-edges through a router, so the edge a send took cannot be
/// told from its endpoints.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Lamp: Sendable {
    struct Lit: Sendable { let on: Bool }
    @Initial case lit(Lit)
    enum Input: Sendable { case flip }
    @Transition(on: Input.flip)
    fileprivate static func light(_ source: Lit) -> Lit { Lit(on: true) }
    @Transition(on: Input.flip)
    fileprivate static func darken(_ source: Lit) -> Lit { Lit(on: false) }
    @Route(on: Input.flip)
    fileprivate static func choose(_ source: Lit) -> Route.Choose { source.on ? .darken : .light }
}

/// A lamp with the same declared structure as `Lamp`, whose router chooses differently.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Twin: Sendable {
    struct Lit: Sendable { let on: Bool }
    @Initial case lit(Lit)
    enum Input: Sendable { case flip }
    @Transition(on: Input.flip)
    fileprivate static func light(_ source: Lit) -> Lit { Lit(on: true) }
    @Transition(on: Input.flip)
    fileprivate static func darken(_ source: Lit) -> Lit { Lit(on: true) }
    @Route(on: Input.flip)
    fileprivate static func choose(_ source: Lit) -> Route.Choose { .light }
}

/// A reading whose completion router chooses between two edges into one phase.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Gauge: Sendable {
    struct Idle: Sendable { var readings: [Int] = [] }
    struct Reading: Sendable { var readings: [Int] }
    @Initial case idle(Idle = Idle())
    case reading(Reading)
    enum Input: Sendable { case read }
    @Operation(activeIn: [Reading.self])
    enum Measure { typealias Output = Int }
    @Transition(on: Input.read, starts: [Measure.self])
    fileprivate static func read(_ source: Idle) -> Change<Reading, Effect.Read> {
        Change(Reading(readings: source.readings), effects: [.measure])
    }
    @Transition(onSuccess: Measure.self)
    fileprivate static func keep(_ source: Reading, _ value: Int) -> Idle { Idle(readings: source.readings + [value]) }
    @Transition(onSuccess: Measure.self)
    fileprivate static func drop(_ source: Reading, _ value: Int) -> Idle { Idle(readings: source.readings) }
    @Route(onSuccess: Measure.self)
    fileprivate static func screen(_ source: Reading, _ value: Int) -> Route.Screen { value < 0 ? .drop : .keep }
}

@Suite struct GraphCoverageTests {
    @Test func oneScriptedRunCanExerciseEveryEdgeAndPhase() throws {
        var test = ManualMachineTest(GeneratedTransfers.Local())
        try test.send(.download(1))
        try test.send(.download(2))
        let works = test.drainFlattenedCommands().compactMap { if case .download(let work) = $0 { work } else { nil } }
        _ = test.deliver(.download(works[0].succeeded("one")))
        _ = test.deliver(.download(works[1].failed(.unavailable)))
        try test.send(.cancel(3))
        try test.send(.goOffline)
        try test.send(.goOnline)
        var coverage = GraphCoverage(for: GeneratedTransfers.Local.self)
        coverage.record(test)
        #expect(coverage.graph == GeneratedTransfers.graph)
        #expect(coverage.unexercisedEdges.isEmpty)
        #expect(coverage.unvisitedPhases.isEmpty)
        #expect(coverage.runs == 1)
        try coverage.requireCoverage()
    }

    @Test func coverageFailsForUnexercisedEdgesAndViolatedInvariants() throws {
        let online = ManualMachineTest<GeneratedTransfers.Local>
            .Invariant("always online") { snapshot in
                if case .offline = snapshot { false } else { true }
            }
        var test = ManualMachineTest(GeneratedTransfers.Local(), invariants: [online])
        try test.send(.goOffline)
        var coverage = GraphCoverage(for: GeneratedTransfers.Local.self)
        coverage.record(test)
        #expect(coverage.visitedPhaseIDs == ["browsing", "offline"])
        #expect(
            coverage.unexercisedEdges.map(\.id) == [
                "browsing.download", "browsing.cancel", "offline.goOnline", "browsing.downloaded", "browsing.failed",
            ]
        )
        #expect(coverage.violations == ["always online at revision 1 in offline"])
        do {
            try coverage.requireCoverage(excluding: ["browsing.failed"])
            Issue.record("an incomplete run satisfied coverage")
        } catch {
            #expect(
                error.message.contains(
                    "unexercised edges: browsing.download, browsing.cancel, offline.goOnline, browsing.downloaded;"
                )
            )
            #expect(!error.message.contains("browsing.failed"))
            #expect(error.message.contains("invariant violations: always online at revision 1 in offline"))
        }
        // A second run covers the rest, but the first run's violation still fails coverage.
        var rest = ManualMachineTest(GeneratedTransfers.Local())
        try rest.send(.download(1))
        try rest.send(.cancel(1))
        try rest.send(.goOffline)
        try rest.send(.goOnline)
        coverage.record(rest)
        #expect(coverage.unexercisedEdges.map(\.id) == ["browsing.downloaded", "browsing.failed"])
        #expect(throws: StateMachineTestFailure.self) { try coverage.requireCoverage() }
    }

    @Test func aRoutedSendNamesTheEdgeItTookAmongSameDestinationEdges() throws {
        var test = ManualMachineTest(Lamp.Local(Lamp.Lit(on: false)))
        let lit = try test.send(.flip)
        #expect(lit.edgeID == "lit.light")
        try test.send(.flip)
        #expect(test.history.map(\.edge) == [nil, "lit.light", "lit.darken"])
        #expect(test.history.last?.trigger == .input("flip"))
        var coverage = GraphCoverage(for: Lamp.Local.self)
        coverage.record(test)
        #expect(coverage.unexercisedRouters.isEmpty)
        try coverage.requireCoverage()
    }

    @Test func aRoutedCompletionNamesTheEdgeItTookAmongSameDestinationEdges() throws {
        var test = ManualMachineTest(Gauge.Local())
        var coverage = GraphCoverage(for: Gauge.Local.self)
        try test.send(.read)
        let first = test.drainFlattenedCommands().compactMap { if case .measure(let work) = $0 { work } else { nil } }
        guard case .committed(let kept) = test.deliver(.measure(first[0].succeeded(4))) else {
            Issue.record("the reading was not admitted")
            return
        }
        #expect(kept.edgeID == "reading.keep")
        #expect(test.acknowledgeExecution(first[0].execution) == .recorded)
        coverage.record(test)
        #expect(coverage.unexercisedEdges.map(\.id) == ["reading.drop"])
        try test.send(.read)
        let second = test.drainFlattenedCommands().compactMap { if case .measure(let work) = $0 { work } else { nil } }
        _ = test.deliver(.measure(second[0].succeeded(-1)))
        #expect(test.acknowledgeExecution(second[0].execution) == .recorded)
        #expect(test.history.map(\.edge) == [nil, "idle.read", "reading.keep", "idle.read", "reading.drop"])
        var complete = GraphCoverage(for: Gauge.Local.self)
        complete.record(test)
        try complete.requireCoverage()
    }

    @Test func coverageIsBoundToItsOwnerType() throws {
        // `Twin` declares the same graph as `Lamp`, but its runs cannot count toward `Lamp`'s coverage:
        // `record` accepts only a harness of `Lamp.Local`.
        #expect(Twin.graph.edges.map(\.id) == Lamp.graph.edges.map(\.id))
        var twin = ManualMachineTest(Twin.Local(Twin.Lit(on: false)))
        try twin.send(.flip)
        var coverage = GraphCoverage(for: Lamp.Local.self)
        var twinCoverage = GraphCoverage(for: Twin.Local.self)
        twinCoverage.record(twin)
        #expect(twinCoverage.exercisedEdgeIDs == ["lit.light"])
        #expect(coverage.runs == 0)
        let lamp = ManualMachineTest(Lamp.Local(Lamp.Lit(on: false)))
        coverage.record(lamp)
        #expect(coverage.exercisedEdgeIDs.isEmpty)
    }

    @Test func aRouterWithDistinctDestinationsNamesTheEdgeASendTook() throws {
        var test = ManualMachineTest(GeneratedRetry.Local(GeneratedRetry.Waiting(attempts: 3, locked: false)))
        try test.send(.retry)
        #expect(test.exercisedEdges == ["waiting.giveUp"])
        var coverage = GraphCoverage(for: GeneratedRetry.Local.self)
        coverage.record(test)
        #expect(coverage.unexercisedEdges.map(\.id) == ["waiting.again"])
        #expect(coverage.unvisitedPhases.map(\.id) == ["trying"])
    }

    @Test func changesTheHarnessNeverObservedFailCoverage() throws {
        var test = ManualMachineTest(GeneratedTransfers.Local())
        test.withOwner { (owner: inout GeneratedTransfers.Local) in
            _ = try? owner.send(.goOffline)
            _ = try? owner.send(.goOnline)
        }
        try test.send(.goOffline)
        try test.send(.goOnline)
        var coverage = GraphCoverage(for: GeneratedTransfers.Local.self)
        coverage.record(test)
        #expect(coverage.unobservedChanges == 1)
        do {
            try coverage.requireCoverage(excluding: [
                "browsing.download", "browsing.cancel", "browsing.downloaded", "browsing.failed",
            ])
            Issue.record("coverage vouched for a change the harness never observed")
        } catch {
            #expect(error.message.hasSuffix("has changes made inside withOwner and never observed: 1"))
        }
    }
}
