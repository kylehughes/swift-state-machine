// A Sendable source, but a non-Sendable output read with a non-Sendable request that each edge still reads.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Tray {
    nonisolated struct Idle: Sendable {}
    nonisolated struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input { case go(Item) }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Input = Item; typealias Output = Item }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ input: Item) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load(input)]) }
    @Route(onSuccess: Load.self)
    fileprivate static func pick(_ source: Running, _ output: Item, request: LoadRequest) -> Route.Pick { .left }
    @Transition(onSuccess: Load.self)
    fileprivate static func left(_ source: Running, _ output: sending Item, request: LoadRequest) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func right(_ source: Running, _ output: sending Item, request: LoadRequest) -> Running { Running() }
}
