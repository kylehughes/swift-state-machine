// An alias a class inherits that names a type with values passes the probe the macro emits for a name it cannot confirm.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Product {}
    class Parent { typealias Product = Swift::Int }
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
        Change(Running(), effects: [.push(1), .started])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
}
