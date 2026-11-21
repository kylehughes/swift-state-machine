// An edge takes exactly the type its Input case carries, whichever owners the schema generates.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
enum Counter {
    struct Idle {}
    struct Done {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input { case set(Swift::Int?) }
    @Transition(on: Input.set)
    fileprivate static func set(_ source: Idle, _ value: Swift::Int?) -> Done { Done() }
}
