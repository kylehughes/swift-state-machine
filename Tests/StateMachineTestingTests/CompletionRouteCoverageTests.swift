import StateMachine
import StateMachineTesting
import Testing

// A completion router without candidates refuses an outcome while `deliver` or `reconcile` prepares
// it. The result of that call carries the refusal and the route that refused, and the harness records
// that route, so coverage stops listing the router once a run saw the real owner refuse a completion
// through it, and a failed `send` keeps the owner's typed rejection. A call that prepared nothing, as a
// second delivery of a retained completion, carries no refusal and earns no coverage. `Hold` is a
// generated `Local`; `Gate` is an owner of the test's own, which shows the harness relies on nothing
// but the results' witnesses.

/// A generated fetch whose completion router `loading.hold` has no candidate and refuses every result
/// while loading, which leaves it retained; once paused, the completion edge `paused.resume` admits it.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Hold: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    struct Paused: Sendable {}
    enum Refusal: Error, Sendable, Equatable { case busy }
    @Initial case idle(Idle = Idle())
    case loading(Loading)
    case paused(Paused)
    enum Input: Sendable { case start, pause }
    @Operation(activeIn: [Loading.self, Paused.self])
    enum Fetch { typealias Output = Int }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Loading, Effect.Start> {
        Change(Loading(), effects: [.fetch])
    }
    @Transition(on: Input.pause)
    fileprivate static func pause(_ source: Loading) -> Paused { Paused() }
    @Route(onSuccess: Fetch.self)
    fileprivate static func hold(_ source: Loading, _ value: Int) throws(Refusal) -> Never { throw .busy }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func resume(_ source: Paused, _ value: Int) -> Idle { Idle() }
}

/// Whether `rejection` is the typed refusal of the router `loading.hold`.
private func refusedByHold(_ rejection: Hold.PendingCompletion.Rejection?) -> Bool {
    guard case .preparation(.hold(let refusal))? = rejection else { return false }
    return refusal == .busy
}

/// A `Local` owner of the test's own whose `loading` phase retains every fetched result through the
/// router `loading.reject`, which has no candidate, and whose `paused` phase admits it through the
/// completion edge `paused.received`; the input `pause` moves between them.
private struct Gate: DeliveringLocalStateMachine, ~Copyable {
    enum Input { case pause, refuse }
    struct Snapshot: StateMachineSnapshot {
        let revision: UInt64
        let phase: String
    }
    struct Receipt: StateMachineReceipt {
        let snapshot: Snapshot
        let edgeID: String?
    }
    enum SendRejection: Error, Equatable { case refused, closed }
    struct Prepared: ~Copyable {}
    typealias CommitResult = Receipt?
    typealias InitialPhase = Void
    struct Batch: LocalCommandBatch {
        let receipt: Receipt
        var commands: [Never] { [] }
        var terminal: Bool { false }
    }
    typealias Command = Never
    typealias CommandBatch = Batch
    struct Completion { let value: Int }
    struct ExecutionHandle {}
    struct PendingCompletionID: Hashable { let raw: Int }
    struct PendingCompletion {
        let id: PendingCompletionID
        let value: Int
    }
    enum DeliveryResult {
        case committed(Receipt)
        case pending(PendingCompletionID)
        case refused(PendingCompletionID, route: String?)
    }
    enum ReconcileResult {
        case committed(Receipt)
        case pending(PendingCompletionID)
        case refused(PendingCompletionID, route: String?)
    }
    enum DiscardResult { case notPending }

    static var graph: StateMachineGraph {
        StateMachineGraph(
            name: "Gate",
            mode: .shared,
            owners: [.local],
            initial: "loading",
            terminal: [],
            restorable: [],
            phases: [.init(id: "loading", payload: "Void"), .init(id: "paused", payload: "Void")],
            inputs: [.init(id: "pause", payload: nil), .init(id: "refuse", payload: nil)],
            scopes: [],
            operations: [],
            events: [],
            edges: [
                edge("loading", "pause", "paused", .input("pause")),
                edge("paused", "pause", "loading", .input("pause")),
                edge("paused", "received", "paused", .success("fetch")),
            ],
            routers: [
                .init(
                    id: "loading.reject",
                    name: "reject",
                    source: "loading",
                    trigger: .success("fetch"),
                    candidates: []
                ),
                .init(
                    id: "paused.decline",
                    name: "decline",
                    source: "paused",
                    trigger: .input("refuse"),
                    candidates: []
                ),
            ]
        )
    }
    private static func edge(
        _ source: String,
        _ name: String,
        _ destination: String,
        _ trigger: StateMachineGraph.Trigger
    ) -> StateMachineGraph.Edge {
        .init(
            id: "\(source).\(name)",
            name: name,
            source: source,
            destination: destination,
            trigger: trigger,
            router: nil,
            starts: [],
            cancels: [],
            emits: [],
            invalidates: []
        )
    }

    private var current = Snapshot(revision: 0, phase: "loading")
    private var retained: [PendingCompletion] = []
    private var nextID = 0
    /// Whether this owner names the route that refused a completion, as a generated owner does.
    private let names: Bool

    init(naming names: Bool = true) { self.names = names }

    static func phase(of snapshot: Snapshot) -> String { snapshot.phase }
    static func receipt(of result: CommitResult) -> Receipt? { result }
    static func rejectingRoute(of rejection: SendRejection, in phase: String) -> String? {
        rejection == .refused && phase == "paused" ? "paused.decline" : nil
    }
    static func receipt(of result: DeliveryResult) -> Receipt? {
        if case .committed(let receipt) = result { receipt } else { nil }
    }
    static func receipt(of result: ReconcileResult) -> Receipt? {
        if case .committed(let receipt) = result { receipt } else { nil }
    }
    static func receipt(of result: DiscardResult) -> Receipt? { nil }
    static func rejectingRoute(of result: DeliveryResult) -> String? {
        if case .refused(_, let route) = result { route } else { nil }
    }
    static func rejectingRoute(of result: ReconcileResult) -> String? {
        if case .refused(_, let route) = result { route } else { nil }
    }

    borrowing func snapshot() -> Snapshot { current }
    borrowing func owns(_ snapshot: Snapshot) -> Bool { true }
    mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
        switch input {
        case .pause:
            return advance(to: current.phase == "loading" ? "paused" : "loading", edge: "\(current.phase).pause")
        case .refuse: throw .refused
        }
    }
    mutating func commit(_ prepared: consuming Prepared) -> CommitResult { nil }
    mutating func close() -> Receipt { Receipt(snapshot: current, edgeID: nil) }
    mutating func reset(to initial: Void) throws(CommitRejection) -> Receipt { Receipt(snapshot: current, edgeID: nil) }
    mutating func reset(to initial: Void, expecting expected: Snapshot) throws(CommitRejection) -> Receipt {
        Receipt(snapshot: current, edgeID: nil)
    }
    mutating func drainCommands(limit: Int) -> [Batch] { [] }
    var queuedBatchCount: Int { 0 }
    var isQuiescent: Bool { retained.isEmpty }
    mutating func deliver(_ completion: Completion) -> DeliveryResult {
        nextID += 1
        let pending = PendingCompletion(id: PendingCompletionID(raw: nextID), value: completion.value)
        retained.append(pending)
        return prepare(pending.id)
    }
    mutating func acknowledgeExecution(
        _ execution: ExecutionHandle,
        disposition: ExecutionDisposition
    ) -> AcknowledgmentResult { .recorded }
    mutating func reconcile(id: PendingCompletionID) -> ReconcileResult {
        switch prepare(id) {
        case .committed(let receipt): .committed(receipt)
        case .pending(let id): .pending(id)
        case .refused(let id, let route): .refused(id, route: route)
        }
    }
    mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult { .pending(id) }
    mutating func discardPending(id: PendingCompletionID) -> DiscardResult { .notPending }
    borrowing func pendingCompletions() -> [PendingCompletion] { retained }

    // Prepares a retained outcome in the current phase: `loading.reject` refuses it, and
    // `paused.received` admits it.
    private mutating func prepare(_ id: PendingCompletionID) -> DeliveryResult {
        guard let index = retained.firstIndex(where: { $0.id == id }) else { return .pending(id) }
        guard current.phase == "paused" else { return .refused(id, route: names ? "loading.reject" : nil) }
        retained.remove(at: index)
        return .committed(advance(to: "paused", edge: "paused.received"))
    }
    private mutating func advance(to phase: String, edge: String) -> Receipt {
        current = Snapshot(revision: current.revision + 1, phase: phase)
        return Receipt(snapshot: current, edgeID: edge)
    }
}

@Suite struct CompletionRouteCoverageTests {
    // A generated `Local` refuses a result delivered while loading through `loading.hold`, and retains
    // it; the delivery's result carries the router's typed refusal and its route, which the harness
    // records, so coverage no longer lists the router. After `pause`, reconciling admits the result through `paused.resume`,
    // and the run covers the graph.
    @Test func aGeneratedLocalsRefusedDeliveryCountsTheRouter() throws {
        var coverage = GraphCoverage(for: Hold.Local.self)
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["loading.hold"])
        var test = ManualMachineTest(Hold.Local())
        try test.send(.start)
        let works = test.drainFlattenedCommands().compactMap { if case .fetch(let work) = $0 { work } else { nil } }
        let work = try #require(works.first)
        guard case .refused(let id, .hold(.busy), routeID: "loading.hold") = test.deliver(.fetch(work.succeeded(1)))
        else {
            Issue.record("Expected the router to refuse the result and retain it")
            return
        }
        #expect(test.completionRejections.map(\.kind) == [.delivery])
        #expect(test.completionRejections.map(\.route) == ["loading.hold"])
        #expect(test.completionRejections.map(\.phase) == ["loading"])
        #expect(test.completionRejections.first?.snapshot.revision == 1)
        #expect(test.pendingCompletions().first { $0.id == id }?.status == .reconciliationRequired)
        #expect(refusedByHold(test.pendingCompletions().first { $0.id == id }?.lastRejection))
        try test.send(.pause)
        guard case .committed(let receipt) = test.reconcile(id: id) else {
            Issue.record("Expected the reconciliation to commit")
            return
        }
        #expect(receipt.edgeID == "paused.resume")
        #expect(test.completionRejections.count == 1)
        #expect(test.acknowledgeExecution(work.execution) == .recorded)
        coverage.record(test)
        #expect(coverage.rejectingRouteIDs == ["loading.hold"])
        #expect(coverage.unexercisedRejectingRouters.isEmpty)
        try coverage.requireCoverage()
    }

    // A result that the owner retained before the harness took it is refused again by the router when
    // the harness reconciles it while loading: the reconciliation alone names the route, and coverage
    // stops listing the router.
    @Test func aGeneratedLocalsRefusedReconciliationCountsTheRouter() throws {
        var owner = Hold.Local()
        try owner.send(.start)
        let commands = owner.drainCommands(limit: .max).flatMap(\.commands)
        guard case .fetch(let work)? = commands.first else {
            Issue.record("Expected the start to issue a fetch")
            return
        }
        guard case .refused(let id, _, _) = owner.deliver(.fetch(work.succeeded(2))) else {
            Issue.record("Expected the router to refuse the result and retain it")
            return
        }
        var coverage = GraphCoverage(for: Hold.Local.self)
        var test = ManualMachineTest(owner)
        guard case .refused(id, .hold(.busy), routeID: "loading.hold") = test.reconcile(id: id) else {
            Issue.record("Expected the router to refuse the result again")
            return
        }
        #expect(test.completionRejections.map(\.kind) == [.reconciliation])
        #expect(test.completionRejections.map(\.route) == ["loading.hold"])
        #expect(test.completionRejections.map(\.phase) == ["loading"])
        #expect(refusedByHold(test.pendingCompletions().first { $0.id == id }?.lastRejection))
        #expect(test.pendingCompletions().first { $0.id == id }?.attempts == 2)
        coverage.record(test)
        #expect(coverage.rejectingRouteIDs == ["loading.hold"])
        #expect(coverage.unexercisedRejectingRouters.isEmpty)
    }

    // A result delivered while `loading` is refused by the router without candidates and retained;
    // after `pause`, reconciling admits it. The run records the refusal with the route the owner named,
    // so coverage no longer lists the router, and every edge is exercised.
    @Test func aCompletionRouterCountsOnceTheOwnerRefusesACompletionThroughIt() throws {
        var coverage = GraphCoverage(for: Gate.self)
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["loading.reject", "paused.decline"])
        var test = ManualMachineTest(Gate())
        guard case .refused(let id, _) = test.deliver(Gate.Completion(value: 1)) else {
            Issue.record("Expected the result to be retained")
            return
        }
        try test.send(.pause)
        guard case .committed = test.reconcile(id: id) else {
            Issue.record("Expected the reconciliation to commit")
            return
        }
        try test.send(.pause)
        try test.send(.pause)
        #expect(test.completionRejections.map(\.route) == ["loading.reject"])
        #expect(test.completionRejections.map(\.kind) == [.delivery])
        #expect(test.completionRejections.map(\.phase) == ["loading"])
        #expect(test.completionRejections.first?.snapshot.revision == 0)
        coverage.record(test)
        #expect(coverage.rejectingRouteIDs == ["loading.reject"])
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["paused.decline"])
        try coverage.requireCoverage()
    }

    // The refusal of a reconciliation counts the same way.
    @Test func aRefusedReconciliationRecordsItsRoute() {
        var test = ManualMachineTest(Gate())
        guard case .refused(let id, _) = test.deliver(Gate.Completion(value: 1)) else {
            Issue.record("Expected the result to be retained")
            return
        }
        _ = test.reconcile(id: id)
        #expect(test.completionRejections.map(\.kind) == [.delivery, .reconciliation])
        #expect(test.completionRejections.map(\.route) == ["loading.reject", "loading.reject"])
    }

    // An owner that names no route for a refused completion records none, so the router stays listed.
    @Test func anOwnerThatNamesNoRouteRecordsNoCompletionRejection() {
        var coverage = GraphCoverage(for: Gate.self)
        var test = ManualMachineTest(Gate(naming: false))
        _ = test.deliver(Gate.Completion(value: 1))
        #expect(test.completionRejections.isEmpty)
        coverage.record(test)
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["loading.reject", "paused.decline"])
    }

    // A rejected input keeps the owner's typed rejection beside the route it names.
    @Test func aRejectionCarriesTheOwnersTypedReason() throws {
        var test = ManualMachineTest(Gate())
        try test.send(.pause)
        let reason = try test.rejection(of: .refuse)
        #expect(reason == .refused)
        #expect(test.rejections.map(\.reason) == [.refused])
        #expect(test.rejections.map(\.route) == ["paused.decline"])
    }

    // A result that the owner refused before the harness took it is delivered again inside the test.
    // That delivery finds the completion retained and prepares nothing, so it carries no refusal, the
    // run records none, and coverage still lists the router, which the test never saw decline.
    @Test func aDuplicateDeliveryEarnsNoRejectingCoverage() throws {
        var owner = Hold.Local()
        try owner.send(.start)
        let commands = owner.drainCommands(limit: .max).flatMap(\.commands)
        guard case .fetch(let work)? = commands.first else {
            Issue.record("Expected the start to issue a fetch")
            return
        }
        guard case .refused(let id, _, _) = owner.deliver(.fetch(work.succeeded(3))) else {
            Issue.record("Expected the router to refuse the result and retain it")
            return
        }
        var coverage = GraphCoverage(for: Hold.Local.self)
        var test = ManualMachineTest(owner)
        let duplicate = test.deliver(.fetch(work.succeeded(3)))
        guard case .pending(id, .reconciliationRequired) = duplicate else {
            Issue.record("Expected the duplicate to report the retained completion's status")
            return
        }
        #expect(Hold.Local.rejectingRoute(of: duplicate) == nil)
        #expect(test.completionRejections.isEmpty)
        #expect(test.pendingCompletions().first { $0.id == id }?.attempts == 1)
        coverage.record(test)
        #expect(coverage.rejectingRouteIDs.isEmpty)
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["loading.hold"])
        #expect(throws: StateMachineTestFailure.self) { try coverage.requireCoverage(includingRejectingRouters: true) }
    }

    // The refusal is part of the result, so discarding the completion afterward changes nothing the
    // saved result reports.
    @Test func discardingTheCompletionLeavesAnEarlierResultsRefusal() throws {
        var test = ManualMachineTest(Hold.Local())
        try test.send(.start)
        let works = test.drainFlattenedCommands().compactMap { if case .fetch(let work) = $0 { work } else { nil } }
        let work = try #require(works.first)
        let delivered = test.deliver(.fetch(work.succeeded(4)))
        guard case .refused(let id, _, _) = delivered else {
            Issue.record("Expected the router to refuse the result and retain it")
            return
        }
        #expect(Hold.Local.rejectingRoute(of: delivered) == "loading.hold")
        guard case .discarded = test.discardPending(id: id) else {
            Issue.record("Expected the discard to commit")
            return
        }
        #expect(Hold.Local.rejectingRoute(of: delivered) == "loading.hold")
        #expect(test.completionRejections.map(\.route) == ["loading.hold"])
    }

    // Requiring rejecting routers lists each one without candidates that no recorded run saw decline,
    // unless it is excluded.
    @Test func requiringRejectingRoutersListsTheOnesThatNeverDeclined() throws {
        var coverage = GraphCoverage(for: Gate.self)
        var test = ManualMachineTest(Gate())
        guard case .refused(let id, _) = test.deliver(Gate.Completion(value: 1)) else {
            Issue.record("Expected the result to be retained")
            return
        }
        try test.send(.pause)
        _ = test.reconcile(id: id)
        try test.send(.pause)
        try test.send(.pause)
        coverage.record(test)
        try coverage.requireCoverage()
        do {
            try coverage.requireCoverage(includingRejectingRouters: true)
            Issue.record("Expected paused.decline to be required")
        } catch {
            #expect("\(error)".contains("unexercised rejecting routers: paused.decline"))
        }
        try coverage.requireCoverage(excluding: ["paused.decline"], includingRejectingRouters: true)
    }
}
