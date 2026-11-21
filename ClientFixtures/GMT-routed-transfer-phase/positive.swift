// The router reads the payload with its source phase, whose internal payload is Sendable, so the edges it selects may
// take the payload as sending.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated internal enum Tray {
    nonisolated internal struct Idle {}
    internal struct Held {}
    @Initial case idle(Idle)
    @Terminal case held(Held)
    internal enum Input { case pick(Item) }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle, _ item: borrowing Item) -> Route.Choose { .hold }
    @Transition(on: Input.pick)
    fileprivate static func hold(_ source: Idle, _ item: sending Item) -> Held { Held() }
    @Transition(on: Input.pick)
    fileprivate static func keep(_ source: Idle, _ item: sending Item) -> Idle { Idle() }
}
