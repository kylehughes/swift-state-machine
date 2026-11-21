// Local keeps each request with its outcome, so a public request that a completion takes as sending declares Sendable,
// which the compiler checks from its stored fields.
import StateMachine

nonisolated public final class Item { public var value = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated public enum Tray {
    public struct Idle {}
    public struct Running {}
    @Initial case idle(Idle)
    case running(Running)
    public enum Input { case go(Swift::Int) }
    @Operation(activeIn: [Running.self])
    public enum Load { public typealias Input = Swift::Int }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ input: Swift::Int) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load(input)]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, request: sending LoadRequest) -> Idle { Idle() }
}
