// An isolated Owned edge receives its payload transferred, a router that borrows the payload lets its edges take it, and a
// router takes a sending payload whose type is Sendable, which it passes on to the edge it selects.
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
enum Tally {
    struct Idle {}
    struct Low { let count: Int }
    struct High { let count: Int }
    @Initial case idle(Idle)
    @Terminal case low(Low)
    @Terminal case high(High)
    enum Input { case add(Int) }
    @Route(on: Input.add)
    fileprivate static func choose(_ source: Idle, _ count: sending Int) -> Route.Choose { count < 10 ? .low : .high }
    @Transition(on: Input.add)
    fileprivate static func low(_ source: Idle, _ count: sending Int) -> Low { Low(count: count) }
    @Transition(on: Input.add)
    fileprivate static func high(_ source: Idle, _ count: sending Int) -> High { High(count: count) }
}
func tally() {
    var tally = Tally.Local(Tally.Idle())
    _ = try? tally.send(.add(3))
    switch Tally.owned(Tally.Idle()).choose(12) {
    case .low(let low): _ = low
    case .high(let high): _ = high
    }
}
