// A completion edge's request keeps its sending convention on the Owned method that passes it on.
import StateMachine

nonisolated public final class LoadInput { public var count = 0; public init() {} }

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Tray {
    struct Idle {}
    struct Busy {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input { case go(LoadInput) }
    @Operation(activeIn: [Busy.self])
    enum Load { typealias Input = LoadInput }
    @Transition(on: Input.go, starts: [Load.self])
    static func go(_ source: Idle, _ input: sending LoadInput) -> Change<Busy, Effect.Go> {
        Change(Busy(), effects: [.load(input)])
    }
    @Transition(onSuccess: Load.self)
    static func done(_ busy: Busy, request: sending LoadRequest) -> Idle { Idle() }
}
func finish() {
    let started = Tray.owned(Tray.Idle()).go(LoadInput())
    _ = started.next.done(request: Tray.LoadRequest(input: LoadInput()))
}
