// Direct protocols and identifiers bound by patterns may take names the expansion does not declare.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Board: Sendable {
    protocol Shape {}
    static let (width, height) = (8, 8)
    struct Idle: Sendable {}
    @Initial @Terminal case idle(Idle)
    enum Input: Sendable {}
}
