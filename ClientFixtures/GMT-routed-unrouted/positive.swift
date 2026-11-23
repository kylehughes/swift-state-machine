// A transition with routed: compiles when a @Route selects it.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum RoutedRequirementControl: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle = Idle())
    @Terminal case done(Done)
    enum Input: Sendable { case go }

    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Idle, routed value: Int) -> Done { Done(value: value) }

    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Idle) -> Idle { source }

    @Route(on: Input.go)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .finish(1) }
}
