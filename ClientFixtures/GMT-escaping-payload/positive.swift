// A reducer that takes an escaping closure payload, and an operation whose Output is a closure, compile.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    enum Problem: Error { case bad }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop, trigger(@Sendable () -> Int) }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Output = @Sendable () -> Int; typealias Failure = Problem }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, _ work: @escaping @Sendable () -> Int) -> Idle { Idle() }
    @Transition(onFailure: Load.self)
    fileprivate static func broke(_ source: Running, _ failure: Problem) -> Idle { Idle() }
    @Transition(on: Input.trigger)
    fileprivate static func trigger(_ source: Idle, _ work: @escaping @Sendable () -> Int) -> Idle { source }
}
func trigger(_ owned: consuming Flow.Owned<Flow.Idle>) -> Flow.Owned<Flow.Idle> { owned.trigger { 1 } }
