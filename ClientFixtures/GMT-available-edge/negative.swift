// An edge available only from macOS 14 in a schema available everywhere would be called from generated
// members without that availability, so the macro refuses the attribute and asks for it on the schema.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @available(macOS 14, *)
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}
