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

struct CompletionRejectionRouteTests {
    private struct Unexpected: Error {}

    /// `Local` names the completion router or edge whose authored function refused a delivered or reconciled
    /// outcome, as the graph identifies it, and nothing for an outcome no authored function refused.
    @Test func aRefusedCompletionNamesItsRouteOrEdge() throws {
        var machine = Retain.Local(Retain.Idle())
        try machine.send(.start)
        guard case .fetch(let work)? = machine.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        let delivered = machine.deliver(work.succeeded(0))
        guard case .pending(let id, .reconciliationRequired) = delivered else { throw Unexpected() }
        #expect(machine.rejectingRoute(of: delivered, in: "loading") == "loading.hold")
        #expect(machine.rejectingRoute(of: delivered, in: "paused") == nil)
        #expect(Retain.Local.graph.routers.map(\.id) == ["loading.hold"])
        try machine.send(.pause)
        let reconciled = machine.reconcile(id: id)
        #expect(machine.rejectingRoute(of: reconciled, in: "paused") == "paused.resume")
        #expect(machine.rejectingRoute(of: ReconcileResult.notPending, in: "paused") == nil)
    }

    private typealias ReconcileResult = Retain.ReconcileResult
}
