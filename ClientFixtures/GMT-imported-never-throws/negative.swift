// A thrown type that names Never through an alias declared outside the schema fails the generated probe.
import StateMachine

/// An alias the macro cannot see.
typealias OutsideProblem = Swift::Never
enum Problem: Error { case bad }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct A: Sendable {}
    @Initial case idle(Idle)
    case a(A)
    enum Input: Sendable { case go, back }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) throws(OutsideProblem) -> A { A() }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: A) -> Idle { Idle() }
}
