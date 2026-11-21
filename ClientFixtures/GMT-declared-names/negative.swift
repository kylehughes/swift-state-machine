// They are checked against the generated names, so the macro diagnoses the collision.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Board: Sendable {
    protocol Owned {}
    static let (width, graph) = (8, 8)
    struct Idle: Sendable {}
    @Initial @Terminal case idle(Idle)
    enum Input: Sendable {}
}
