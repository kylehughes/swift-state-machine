// An input payload may key a dictionary by a type nested in `Input`; the key is qualified as a type.
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
    fileprivate static func add(_ source: Open, _ scores: [Input.Player: Int]) -> Open {
        Open(totals: source.totals.merging(scores, uniquingKeysWith: +))
    }
    @Transition(on: Input.close)
    fileprivate static func close(_ source: Open) -> Closed { Closed() }
}
