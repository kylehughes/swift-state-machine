// A case that carries Never, even through an alias and with no edge, could never be sent.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Checkout: Sendable {
    struct Idle: Sendable {}
    struct Paying: Sendable {}
    @Initial case idle(Idle)
    case paying(Paying)
    enum Input: Sendable {
        typealias Nothing = Swift.Never
        case pay
        case back
        case refund(Nothing)
    }
    @Transition(on: Input.pay)
    fileprivate static func pay(_ source: Idle) -> Paying { Paying() }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: Paying) -> Idle { Idle() }
}
