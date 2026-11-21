// An edge that takes Int for a case that carries Int? is rejected by the witness, which infers the case's payload from its
// constructor alone, so the constructor cannot adapt to the edge.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
enum Counter {
    struct Idle {}
    struct Done {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input { case set(Swift::Int?) }
    @Transition(on: Input.set)
    fileprivate static func set(_ source: Idle, _ value: Swift::Int) -> Done { Done() }
}
