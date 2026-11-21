// A candidate that throws Swift::Never beside a pinned failure, and an edge that throws an alias of Never, are nonthrowing.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Picker: Sendable {
    enum Problem: Error { case bad }
    enum Other: Error { case worse }
    typealias Nope = Never
    struct Idle: Sendable {}
    struct A: Sendable {}
    @Initial case idle(Idle)
    case a(A)
    enum Input: Sendable { case go, back }
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Swift::Never) -> A { A() }
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem) -> A { throw .bad }
    @Route(on: Input.go, failure: Problem.self)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .left }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: A) throws(Nope) -> Idle { Idle() }
}

func choose(_ owned: consuming Picker.Owned<Picker.Idle>) -> Picker.Route.ChooseResult { owned.choose() }
func back(_ owned: consuming Picker.Owned<Picker.A>) -> Picker.Owned<Picker.Idle> { owned.back() }
