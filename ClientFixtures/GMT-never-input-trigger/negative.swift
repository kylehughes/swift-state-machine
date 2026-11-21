// No value of Never exists, so no input can ever have this case.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Checkout: Sendable {
    struct Done: Sendable {}
    struct Idle: Sendable {}
    struct Paid: Sendable {}
    @Initial case idle(Idle)
    @Terminal case paid(Paid)
    enum Input: Sendable { case pay(Swift.Never) }
    @Transition(on: Input.pay)
    fileprivate static func pay(_ source: Idle, _ receipt: Swift.Never) -> Paid { Paid() }
}
