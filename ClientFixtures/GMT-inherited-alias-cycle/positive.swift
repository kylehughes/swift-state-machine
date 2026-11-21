// An inherited member breaks what the schema's own declarations alone would make a cycle, as Swift reads it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Count: Sendable {
    typealias Product = Child.Outcome
    class Parent { typealias Product = Swift::Int }
    final class Child: Parent { typealias Outcome = Product }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Output = Count.Product }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, _ value: Swift::Int) -> Idle { Idle() }
}
func product() { let _: Count.Product = 3 }
