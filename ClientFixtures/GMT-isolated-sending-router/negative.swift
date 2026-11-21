// A router passes its payload on to the edge it selects, so in an isolated schema it takes the payload as sending only when its
// type is Sendable.
import StateMachine

nonisolated public final class Item { public var count = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
enum Tray {
    struct Idle {}
    struct Held { let item: Item }
    struct Other { let item: Item }
    @Initial case idle(Idle)
    @Terminal case held(Held)
    @Terminal case other(Other)
    enum Input { case pick(Item) }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle, _ item: sending Item) -> Route.Choose { .hold }
    @Transition(on: Input.pick)
    fileprivate static func hold(_ source: Idle, _ item: sending Item) -> Held { Held(item: item) }
    @Transition(on: Input.pick)
    fileprivate static func keep(_ source: Idle, _ item: sending Item) -> Other { Other(item: item) }
}
