import StateMachine
import Testing

/// A graph whose completion router refuses an outcome while loading, so it is retained for reconciliation,
/// and whose completion edge refuses it again while paused.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Retain: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    struct Paused: Sendable {}
    enum Refusal: Error, Sendable { case busy, paused }
    @Initial case idle(Idle)
    case loading(Loading)
    case paused(Paused)
    enum Input: Sendable {
        case start
        case pause
    }
    @Operation(activeIn: [Loading.self, Paused.self])
    enum Fetch { typealias Output = Int }
    @Transition(on: Input.start, starts: [Fetch.self])
    static func start(_ source: Idle) -> Change<Loading, Effect.Start> { Change(Loading(), effects: [.fetch]) }
    @Transition(on: Input.pause)
    static func pause(_ source: Loading) -> Paused { Paused() }
    @Route(onSuccess: Fetch.self)
    static func hold(_ source: Loading, _ value: Int) throws(Refusal) -> Never { throw .busy }
    @Transition(onSuccess: Fetch.self)
    static func resume(_ source: Paused, _ value: Int) throws(Refusal) -> Idle {
        guard value > 0 else { throw .paused }
        return Idle()
    }
}

/// A graph whose completion edges of one name refuse an outcome from either phase they leave, so both
/// share one `PreparationRejection` case.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Settle: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    struct Paused: Sendable {}
    enum Refusal: Error, Sendable { case refused }
    @Initial case idle(Idle)
    case loading(Loading)
    case paused(Paused)
    enum Input: Sendable {
        case start
        case pause
    }
    @Operation(activeIn: [Loading.self, Paused.self])
    enum Fetch { typealias Output = Int }
    @Transition(on: Input.start, starts: [Fetch.self])
    static func start(_ source: Idle) -> Change<Loading, Effect.Start> { Change(Loading(), effects: [.fetch]) }
    @Transition(on: Input.pause)
    static func pause(_ source: Loading) -> Paused { Paused() }
    @Transition(onSuccess: Fetch.self)
    static func settle(_ source: Loading, _ value: Int) throws(Refusal) -> Idle { throw .refused }
    @Transition(onSuccess: Fetch.self)
    static func settle(_ source: Paused, _ value: Int) throws(Refusal) -> Idle { throw .refused }
}

/// A managed graph whose completion edge refuses every outcome.
@StateMachine(mode: .shared, owners: [.shared])
nonisolated private enum Refuse: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    enum Refusal: Error, Sendable { case busy }
    @Initial case idle(Idle)
    case loading(Loading)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Loading.self])
    enum Fetch { typealias Output = Int }
    @Transition(on: Input.start, starts: [Fetch.self])
    static func start(_ source: Idle) -> Change<Loading, Effect.Start> { Change(Loading(), effects: [.fetch]) }
    @Transition(onSuccess: Fetch.self)
    static func loaded(_ source: Loading, _ value: Int) throws(Refusal) -> Idle { throw .busy }
}

struct CompletionRejectionRouteTests {
    private struct Unexpected: Error {}

    /// The call whose preparation refused an outcome returns the refusal, with the router or completion edge
    /// whose authored function refused it as the graph identifies it, and the result keeps it after the
    /// outcome is settled; a call that did not prepare it returns no refusal.
    @Test func aRefusalIsEvidenceOfTheCallThatPreparedIt() throws {
        var machine = Retain.Local(Retain.Idle())
        try machine.send(.start)
        guard case .fetch(let work)? = machine.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        let delivered = machine.deliver(work.succeeded(0))
        guard case .refused(let id, .hold(.busy), routeID: "loading.hold") = delivered else { throw Unexpected() }
        #expect(Retain.Local.rejectingRoute(of: delivered) == "loading.hold")
        #expect(Retain.Local.graph.routers.map(\.id) == ["loading.hold"])
        // Delivering the same outcome again prepares nothing, so it refuses nothing.
        let duplicate = machine.deliver(work.succeeded(0))
        guard case .pending(id, .reconciliationRequired) = duplicate else { throw Unexpected() }
        #expect(Retain.Local.rejectingRoute(of: duplicate) == nil)
        // Retrying admission never prepares.
        let retried = machine.retryAdmission(id: id)
        guard case .pending(id, .reconciliationRequired) = retried else { throw Unexpected() }
        #expect(Retain.Local.rejectingRoute(of: retried) == nil)
        try machine.send(.pause)
        let reconciled = machine.reconcile(id: id)
        guard case .refused(id, .resume(.paused), routeID: "paused.resume") = reconciled else { throw Unexpected() }
        #expect(Retain.Local.rejectingRoute(of: reconciled) == "paused.resume")
        guard case .discarded = machine.discardPending(id: id) else { throw Unexpected() }
        #expect(Retain.Local.rejectingRoute(of: delivered) == "loading.hold")
        #expect(Retain.Local.rejectingRoute(of: reconciled) == "paused.resume")
        #expect(Retain.Local.rejectingRoute(of: ReconcileResult.notPending) == nil)
    }

    /// One `PreparationRejection` case serves functions of one name in several phases, and a refusal names
    /// the route of the phase its preparation ran from.
    @Test func aSharedCaseNamesThePhaseItWasPreparedFrom() throws {
        var machine = Settle.Local(Settle.Idle())
        try machine.send(.start)
        guard case .fetch(let work)? = machine.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        let delivered = machine.deliver(work.succeeded(1))
        guard case .refused(let id, .settle(.refused), routeID: "loading.settle") = delivered else {
            throw Unexpected()
        }
        try machine.send(.pause)
        let reconciled = machine.reconcile(id: id)
        guard case .refused(id, .settle(.refused), routeID: "paused.settle") = reconciled else { throw Unexpected() }
    }

    /// A managed owner's reconciliation returns the refusal of its own preparation.
    @Test func aManagedReconciliationReturnsItsOwnRefusal() async throws {
        let (reports, report) = AsyncStream<Refuse.PendingCompletion>.makeStream()
        let owner = Refuse.Shared(
            Refuse.Idle(),
            fetchDriver: { 1 },
            completionPolicy: .manual(onReconciliationRequired: { report.yield($0) })
        )
        try owner.send(.start)
        var reported = reports.makeAsyncIterator()
        let refused = try #require(await reported.next())
        guard case .refused(refused.id, .loaded(.busy), routeID: "loading.loaded") = owner.reconcile(id: refused.id)
        else { throw Unexpected() }
        await owner.shutdown()
        report.finish()
    }

    private typealias ReconcileResult = Retain.ReconcileResult
}
