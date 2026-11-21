// Every phase is reachable from the initial phase.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Order: Sendable {
    struct Cart: Sendable {}
    struct Placed: Sendable {}
    struct Refunded: Sendable {}
    @Initial case cart(Cart)
    @Terminal case placed(Placed)
    @Terminal case refunded(Refunded)
    enum Input: Sendable { case place, refund }
    @Transition(on: Input.place)
    fileprivate static func place(_ source: Cart) -> Placed { Placed() }
    @Transition(on: Input.refund)
    fileprivate static func refund(_ source: Cart) -> Refunded { Refunded() }
}
