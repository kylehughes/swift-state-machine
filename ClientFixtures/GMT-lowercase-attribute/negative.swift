// A custom attribute whose name begins with a lowercase letter is still a custom attribute, here a global
// actor, so it is refused on an authored function as any other is.
import StateMachine

@globalActor actor uiActor { static let shared = uiActor() }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @uiActor
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}
