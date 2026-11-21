// An observing owner keeps each request with its outcome, so a completion edge takes it as sending only when the request is
// Sendable, which a request of a mutable class input is not.
import StateMachine

nonisolated public final class LoadInput { public var count = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated enum Tray {
    struct Idle {}
    struct Busy {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input { case go(LoadInput) }
    @Operation(activeIn: [Busy.self])
    enum Load { typealias Input = LoadInput }
    @Transition(on: Input.go, starts: [Load.self])
    static func go(_ source: Idle, _ input: LoadInput) -> Change<Busy, Effect.Go> { Change(Busy(), effects: [.load(input)]) }
    @Transition(onSuccess: Load.self)
    static func done(_ busy: Busy, request: sending LoadRequest) -> Idle { Idle() }
}
