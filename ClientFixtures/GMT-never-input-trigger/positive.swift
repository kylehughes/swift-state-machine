// An input that carries a value can trigger its edge.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Checkout: Sendable {
    struct Done: Sendable {}
    struct Idle: Sendable {}
    struct Paid: Sendable {}
    @Initial case idle(Idle)
    @Terminal case paid(Paid)
    enum Input: Sendable { case pay(Done) }
    @Transition(on: Input.pay)
    fileprivate static func pay(_ source: Idle, _ receipt: Done) -> Paid { Paid() }
}
