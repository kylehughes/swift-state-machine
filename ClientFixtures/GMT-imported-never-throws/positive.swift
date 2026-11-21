// A thrown type declared outside the schema is checked to have values.
import StateMachine

/// An alias the macro cannot see.
typealias OutsideProblem = Problem
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
