// A request that carries a mutable class is not Sendable, and the phase it is read with is not either.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated public enum Tray {
    nonisolated public struct Idle { public init() {} }
    nonisolated public struct Running { public init() {} }
    @Initial case idle(Idle)
    case running(Running)
    public enum Input { case go(Item) }
    @Operation(activeIn: [Running.self])
    public enum Load { public typealias Input = Item }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ input: Item) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load(input)]) }
    @Route(onSuccess: Load.self)
    fileprivate static func pick(_ source: Running, request: LoadRequest) -> Route.Pick { .left }
    @Transition(onSuccess: Load.self)
    fileprivate static func left(_ source: Running, request: sending LoadRequest) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func right(_ source: Running, request: sending LoadRequest) -> Running { Running() }
}

func requireSendable<Value: Sendable>(_ type: Value.Type) {}
func check() {  }
