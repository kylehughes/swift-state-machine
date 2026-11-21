// The qualified payload still has to match the input case: a reducer that takes other values is rejected.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Scores: Sendable {
    struct Open: Sendable { var totals: [Input.Player: Int] = [:] }
    struct Closed: Sendable {}
    @Initial case open(Open = Open())
    @Terminal case closed(Closed)
    enum Input: Sendable {
        struct Player: Hashable, Sendable { let name: String }
        case add([Player: Int])
        case close
    }
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Open, _ scores: [Input.Player: String]) -> Open {
        source
    }
    @Transition(on: Input.close)
    fileprivate static func close(_ source: Open) -> Closed { Closed() }
}
