// A request whose input is a mutable class cannot be Sendable, which the request's own conformance reports.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated public enum Tray {
    public struct Idle {}
    public struct Running {}
    @Initial case idle(Idle)
    case running(Running)
    public enum Input { case go(Item) }
    @Operation(activeIn: [Running.self])
    public enum Load { public typealias Input = Item }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ input: Item) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load(input)]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, request: sending LoadRequest) -> Idle { Idle() }
}
