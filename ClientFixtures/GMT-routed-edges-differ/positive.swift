// Every edge that takes the request sends it, so the method transfers it once.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Tray {
    nonisolated struct Idle {}
    nonisolated struct Running {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input { case go(Item) }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Input = Item }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ input: Item) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load(input)]) }
    @Route(onSuccess: Load.self)
    fileprivate static func pick(_ source: Running) -> Route.Pick { .left }
    @Transition(onSuccess: Load.self)
    fileprivate static func left(_ source: Running, request: sending LoadRequest) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func right(_ source: Running, request: sending LoadRequest) -> Running { Running() }
}
