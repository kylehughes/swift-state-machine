// Throwing functions of one name that throw different types get phase-named PreparationRejection
// cases, so `invalidPhase` from two phases is free; one type, however it is spelled, keeps the name.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Toggle: Sendable {
    enum ProblemA: Swift.Error, Sendable { case a }
    enum ProblemB: Swift.Error, Sendable { case b }
    struct A: Sendable {}
    struct B: Sendable {}
    @Initial case a(A)
    case b(B)
    enum Input: Sendable { case flip }
    @Transition(on: Input.flip)
    fileprivate static func invalidPhase(_ source: A) throws(ProblemA) -> B { B() }
    @Transition(on: Input.flip)
    fileprivate static func invalidPhase(_ source: B) throws(ProblemB) -> A { A() }
}

nonisolated func describe(_ rejection: Toggle.PreparationRejection) -> String {
    switch rejection {
    case .invalidPhase: "no edge"
    case .aInvalidPhase: "from A"
    case .bInvalidPhase: "from B"
    }
}
