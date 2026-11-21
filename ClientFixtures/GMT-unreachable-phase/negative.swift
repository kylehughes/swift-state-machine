// A phase that no declared path reaches is diagnosed.
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
}
