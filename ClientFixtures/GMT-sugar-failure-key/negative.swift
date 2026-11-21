// Problem<[Detail]> and Problem<Set<Detail>> differ, so the router throws PreparationRejection.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Picker: Sendable {
    struct Detail: Sendable, Hashable {}
    struct Problem<T: Sendable>: Error { let detail: T }
    struct Idle: Sendable {}
    struct A: Sendable {}
    @Initial case idle(Idle)
    case a(A)
    enum Input: Sendable { case go, back }
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Problem<[Detail]>) -> A { A() }
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem<Set<Detail>>) -> A { A() }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .left }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: A) -> Idle { Idle() }
}

func choose(_ observed: Picker.Observed<Picker.Idle>) throws(Picker.Problem<[Picker.Detail]>) -> Picker.Prepared {
    try observed.choose()
}
