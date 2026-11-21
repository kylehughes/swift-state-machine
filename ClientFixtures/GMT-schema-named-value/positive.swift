// A value or method named like the schema is not found where generated code looks up a type, so it hides nothing
// from the expansion, whatever the schema declares.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    static var Flow: Int { 0 }
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    struct Done: Sendable {}
    enum Problem: Error { case refused }
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    @Terminal case done(Done)
    enum Input: Sendable { case begin, pick, stop }
    @Operation(activeIn: [Busy.self])
    enum Load { typealias Output = Int; typealias Failure = Problem }
    @Event
    enum Logged { typealias Payload = Int }
    @Transition(on: Input.begin, starts: [Load.self], emits: [Logged.self])
    fileprivate static func begin(_ source: Idle) -> Change<Busy, Effect.Begin> {
        Change(Busy(), effects: [.load, .logged(1)])
    }
    @Route(onSuccess: Load.self)
    fileprivate static func received(_ source: Busy, _ output: Int) -> Route.Received { .loaded }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Busy, _ output: Int) -> Idle { Idle() }
    @Transition(onFailure: Load.self)
    fileprivate static func failed(_ source: Busy, _ failure: Problem) -> Idle { Idle() }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Idle) -> Done { Done() }
    @Restoration
    fileprivate static func restore(_ saved: Int) throws(Problem) -> Restoration { .idle(Idle()) }
}

func start() throws {
    let flow = Flow.Shared(Flow.Idle(), drivers: .init(load: { .success(1) }), onLogged: { _ in })
    _ = try flow.send(.begin)
    _ = Flow.Flow
}
