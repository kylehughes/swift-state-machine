// The macro does not read inherited members, so an alias that reaches Never through a superclass fails the probe instead of compiling an operation no transition can start.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Product {}
    class Parent { typealias Product = Swift::Never }
    final class Child: Parent { typealias Outcome = Product }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Input = Child.Outcome }
    @Event enum Started {}
    @Transition(on: Input.start, starts: [Push.self], emits: [Started.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.started])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
}
