// A deprecation on every platform is the one availability an authored function may carry.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @available(*, deprecated)
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}

func start() throws {
    _ = try Flow.Shared(Flow.Idle()).send(.go)
}
