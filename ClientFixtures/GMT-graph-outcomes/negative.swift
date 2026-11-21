// An operation description states both outcomes explicitly.
import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Sync: Sendable {
    typealias Problem = Swift.Never
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Failure = Problem }
    @Transition(on: Input.start, starts: [Push.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.push])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
}

func infallible() -> Bool {
    let push = Sync.graph.operations[0]
    return StateMachineGraph.Operation(id: "Push", effect: "push", scope: nil, requires: [], activeIn: ["running"], admission: .latest, key: nil, input: "Swift::Void", output: "Swift::Void", failure: "Problem") == push
}
