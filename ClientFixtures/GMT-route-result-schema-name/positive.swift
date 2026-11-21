// The router `pick` generates `Route.PickResult`, which leaves the schema's name visible.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum FlowResult: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    case done(Done)
    enum Input: Sendable { case go, back }
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle) -> Route.Pick { .finish }
    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Idle) -> Idle { source }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: Done) -> Idle { Idle() }
}
