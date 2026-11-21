// An isolated Owned edge receives its payload transferred, a router that borrows the payload lets its edges take it, and an
// observing owner passes on a sending payload whose type is Sendable.
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
    enum Input { case pick(Item), place(Item) }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle, _ item: borrowing Item) -> Route.Choose { .hold }
    @Transition(on: Input.pick)
    fileprivate static func hold(_ source: Idle, _ item: sending Item) -> Held { Held(item: item) }
    @Transition(on: Input.pick)
    fileprivate static func keep(_ source: Idle, _ item: sending Item) -> Other { Other(item: item) }
    @Transition(on: Input.place)
    fileprivate static func place(_ source: Idle, _ item: sending Item) -> Held { Held(item: item) }
}
func check() {
    switch Tray.owned(Tray.Idle()).choose(Item()) {
    case .hold(let held): _ = held
    case .keep(let other): _ = other
    }
    _ = Tray.owned(Tray.Idle()).place(Item())
}

@StateMachine(mode: .isolated, owners: [.owned, .local])
enum Counter {
    struct Idle {}
    struct Counted { let count: Int }
    @Initial case idle(Idle)
    @Terminal case counted(Counted)
    enum Input { case count(Int) }
    @Transition(on: Input.count)
    fileprivate static func count(_ source: Idle, _ count: sending Int) -> Counted { Counted(count: count) }
}
func count() {
    var counter = Counter.Local(Counter.Idle())
    _ = try? counter.send(.count(3))
}
