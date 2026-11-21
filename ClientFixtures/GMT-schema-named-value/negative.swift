// A type named like the schema directly inside it is found where generated code names the schema's types.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Flow {}
    struct Idle: Sendable {}
    @Initial @Terminal case idle(Idle)
    enum Input: Sendable {}
}
