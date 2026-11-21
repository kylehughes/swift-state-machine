import StateMachine

/// Records which declared edges, routers, and phases scripted runs of one owner type exercised, and
/// reports the rest.
///
/// Coverage is bound to an owner type, so only runs of that owner count toward it: a graph of another
/// schema, even one with identical structure, cannot be recorded. Record the history of each
/// ``ManualMachineTest`` that a test drives, then read ``unexercisedEdges``, ``unexercisedRouters``,
/// ``unexercisedRejectingRouters``, and ``unvisitedPhases``, or require coverage with
/// ``requireCoverage(excluding:includingRejectingRouters:fileID:filePath:line:column:)``, which also
/// fails for every invariant a recorded run violated:
///
/// ```swift
/// var coverage = GraphCoverage(for: GeneratedTransfers.Local.self)
/// var test = ManualMachineTest(GeneratedTransfers.Local())
/// try test.send(.goOffline)
/// coverage.record(test)
/// #expect(coverage.unexercisedEdges.map(\.id).contains("browsing.download"))
/// ```
///
/// Every step comes from a real owner admitting a real change, and names the edge from that change's
/// receipt, so an exercised edge is one that a test actually took, even when a router chooses between
/// edges with the same destination. Every rejection comes from the real owner refusing an input, or a
/// completion that a `deliver` or `reconcile` call itself prepared, and names the route, a router or an
/// edge, that the owner reports for that call, so a route counts as declining only once a test saw it
/// decline.
nonisolated public struct GraphCoverage<Owner: LocalStateMachine & ~Copyable>: Sendable {
    /// The graph the coverage measures: the owner's.
    public var graph: StateMachineGraph { Owner.graph }
    /// The identifiers of the edges that recorded runs exercised.
    public private(set) var exercisedEdgeIDs: Set<String> = []
    /// The identifiers of the phases that recorded runs held.
    public private(set) var visitedPhaseIDs: Set<String> = []
    /// The identifiers of the routers and edges whose authored functions refused an input or a
    /// completion in recorded runs, as the owner named them.
    public private(set) var rejectingRouteIDs: Set<String> = []
    /// A description of each invariant violation that recorded runs reported.
    public private(set) var violations: [String] = []
    /// How many accepted changes recorded runs made inside `withOwner` without observing them.
    public private(set) var unobservedChanges = 0
    /// How many times recorded runs replaced their owner inside `withOwner`.
    public private(set) var replacedOwners = 0
    /// How many runs have been recorded.
    public private(set) var runs = 0

    /// Creates coverage of an owner type's graph with nothing recorded.
    public init(for owner: Owner.Type) {}

    /// Records the steps of one run, and the invariant violations, unobserved changes, and owner
    /// replacements it reported.
    public mutating func record(_ test: borrowing ManualMachineTest<Owner>) {
        runs += 1
        for step in test.history {
            visitedPhaseIDs.insert(step.source)
            visitedPhaseIDs.insert(step.phase)
            if let edge = step.edge { exercisedEdgeIDs.insert(edge) }
        }
        for rejection in test.rejections {
            if let route = rejection.route { rejectingRouteIDs.insert(route) }
        }
        for rejection in test.completionRejections { rejectingRouteIDs.insert(rejection.route) }
        violations += test.violations.map { "\($0.invariant) at revision \($0.step.revision) in \($0.step.phase)" }
        unobservedChanges += test.unobservedChanges
        replacedOwners += test.replacedOwners
    }

    /// The declared edges that no recorded run exercised, in declaration order.
    public var unexercisedEdges: [StateMachineGraph.Edge] {
        graph.edges.filter { !exercisedEdgeIDs.contains($0.id) }
    }

    /// The declared phases that no recorded run held, in declaration order.
    public var unvisitedPhases: [StateMachineGraph.Phase] {
        graph.phases.filter { !visitedPhaseIDs.contains($0.id) }
    }

    /// The declared routers none of whose candidate edges a recorded run exercised, in declaration order.
    ///
    /// A router without candidates always declines, so no step can exercise it, and it is not listed.
    public var unexercisedRouters: [StateMachineGraph.Router] {
        graph.routers.filter { router in
            !router.candidates.isEmpty && !router.candidates.contains(where: exercisedEdgeIDs.contains)
        }
    }

    /// The declared routers without candidate edges that no recorded run saw decline, in declaration order.
    ///
    /// Such a router exists only to decline an input or a completion, so no step can exercise it. An
    /// input router counts once a recorded run's ``ManualMachineTest/rejection(of:fileID:filePath:line:column:)``
    /// or failed ``ManualMachineTest/send(_:fileID:filePath:line:column:)`` made the real owner refuse an
    /// input through it, and a completion router once a recorded run's `deliver` or `reconcile` prepared a
    /// completion that the real owner refused through it, as that call's result names the route. An
    /// owner that names no route for its rejections leaves every such router listed.
    public var unexercisedRejectingRouters: [StateMachineGraph.Router] {
        graph.routers.filter { $0.candidates.isEmpty && !rejectingRouteIDs.contains($0.id) }
    }

    /// Requires that recorded runs held every phase, exercised every edge except those in `excluded`
    /// and every router with at least one candidate except those in `excluded`, violated no invariant,
    /// observed every change they made, and kept one owner each.
    ///
    /// `excluded` holds edge and router identifiers, `"<phase>.<name>"`, which are distinct because an
    /// edge and a router that leave one phase cannot share a name. A router counts as exercised once a
    /// step takes one of its candidate edges.
    ///
    /// By default it requires nothing of rejections: a router that declined, or an edge or router whose
    /// function can throw, is not required to have refused an input, and a router without candidates,
    /// which always declines, is not required at all. With `includingRejectingRouters`, it also requires
    /// every router without candidates, except those in `excluded`, to have declined in a recorded run,
    /// as ``unexercisedRejectingRouters`` lists them.
    ///
    /// The failure lists each unexercised edge and router, each required rejecting router that never
    /// declined, each unvisited phase, each violation, the number of changes made inside `withOwner`
    /// that no invariant could check, and the number of owners replaced there.
    public func requireCoverage(
        excluding excluded: Set<String> = [],
        includingRejectingRouters: Bool = false,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws(StateMachineTestFailure) {
        let edges = unexercisedEdges.map(\.id).filter { !excluded.contains($0) }
        let routers = unexercisedRouters.map(\.id).filter { !excluded.contains($0) }
        let rejecting =
            includingRejectingRouters ? unexercisedRejectingRouters.map(\.id).filter { !excluded.contains($0) } : []
        let phases = unvisitedPhases.map(\.id)
        var parts: [String] = []
        if !edges.isEmpty { parts.append("unexercised edges: " + edges.joined(separator: ", ")) }
        if !routers.isEmpty { parts.append("unexercised routers: " + routers.joined(separator: ", ")) }
        if !rejecting.isEmpty { parts.append("unexercised rejecting routers: " + rejecting.joined(separator: ", ")) }
        if !phases.isEmpty { parts.append("unvisited phases: " + phases.joined(separator: ", ")) }
        if !violations.isEmpty { parts.append("invariant violations: " + violations.joined(separator: "; ")) }
        if unobservedChanges > 0 {
            parts.append("changes made inside withOwner and never observed: \(unobservedChanges)")
        }
        if replacedOwners > 0 { parts.append("owners replaced inside withOwner: \(replacedOwners)") }
        guard !parts.isEmpty else { return }
        throw StateMachineTestFailure(
            "\(graph.name) after \(runs) recorded runs has " + parts.joined(separator: "; "),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}
