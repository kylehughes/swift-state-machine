// Without the inherited member, the aliases name each other through the class, which Swift reports; the macro, which
// cannot confirm the link through the class, leaves the cycle to the compiler.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Count: Sendable {
    typealias Product = Child.Outcome
    class Parent {}
    final class Child: Parent { typealias Outcome = Product }
    struct Idle: Sendable {}
    @Initial @Terminal case idle(Idle)
    enum Input: Sendable {}
}
