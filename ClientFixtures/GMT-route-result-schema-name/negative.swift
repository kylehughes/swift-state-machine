// The router `flow` would generate `Route.FlowResult`, the schema's own name, inside Route.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum FlowResult: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    case done(Done)
    enum Input: Sendable { case go, back }
    @Route(on: Input.go)
    fileprivate static func flow(_ source: Idle) -> Route.Flow { .finish }
    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Idle) -> Idle { source }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: Done) -> Idle { Idle() }
}
