// A public phase payload is not Sendable, so reading the payload with it joins the two, and edges that then take the
// payload as sending are rejected by a check that names the cause.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated public enum Tray {
    nonisolated public struct Idle {}
    public struct Held {}
    @Initial case idle(Idle)
    @Terminal case held(Held)
    public enum Input { case pick(Item) }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle, _ item: borrowing Item) -> Route.Choose { .hold }
    @Transition(on: Input.pick)
    fileprivate static func hold(_ source: Idle, _ item: sending Item) -> Held { Held() }
    @Transition(on: Input.pick)
    fileprivate static func keep(_ source: Idle, _ item: sending Item) -> Idle { Idle() }
}
