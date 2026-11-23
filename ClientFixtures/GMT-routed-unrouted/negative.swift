// A transition with routed: is rejected when no @Route selects it.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum RoutedRequirementRefused: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle = Idle())
    @Terminal case done(Done)
    enum Input: Sendable { case go }

    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Idle, routed value: Int) -> Done { Done(value: value) }
}
