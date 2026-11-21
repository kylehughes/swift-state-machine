// The shared error is the candidates' own, so it is not a PreparationRejection.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Picker: Sendable {
    enum Problem: Error { case declined }
    typealias Refusal = Problem
    struct Idle: Sendable {}
    struct Chosen: Sendable {}
    @Initial case idle(Idle)
    case chosen(Chosen)
    enum Input: Sendable { case pick(Bool), back }
    @Transition(on: Input.pick)
    fileprivate static func left(_ source: Idle, _ value: Bool) throws(Problem) -> Chosen { Chosen() }
    @Transition(on: Input.pick)
    fileprivate static func right(_ source: Idle, _ value: Bool) throws(Refusal) -> Chosen { Chosen() }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle, _ value: Bool) -> Route.Choose { value ? .left : .right }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: Chosen) -> Idle { Idle() }
}

func owned(_ owned: consuming Picker.Owned<Picker.Idle>)
    -> StateMachine.Advance<Picker.Owned<Picker.Idle>, Picker.Owned<Picker.Chosen>, Never, Picker.Problem>
{
    owned.choose(true)
}

func observed(_ observed: Picker.Observed<Picker.Idle>) throws(Picker.Problem) -> Picker.Prepared {
    do { return try observed.choose(true) } catch { let rejection: Picker.PreparationRejection = error; _ = rejection; fatalError() }
}
