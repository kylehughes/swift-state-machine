// An isolated observing owner keeps an input it receives, so it passes a sending payload on only when its type is Sendable.
import StateMachine

nonisolated public final class Item { public var count = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned, .local])
enum Tray {
    struct Idle {}
    struct Held { let item: Item }
    @Initial case idle(Idle)
    @Terminal case held(Held)
    enum Input { case place(Item) }
    @Transition(on: Input.place)
    fileprivate static func place(_ source: Idle, _ item: sending Item) -> Held { Held(item: item) }
}
