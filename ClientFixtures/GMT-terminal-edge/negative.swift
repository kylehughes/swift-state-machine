// A terminal phase cannot gain an outgoing edge.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Door: Sendable {
    struct Closed: Sendable {}
    struct Open: Sendable {}
    struct Broken: Sendable {}
    @Initial case closed(Closed)
    case open(Open)
    @Terminal case broken(Broken)
    enum Input: Sendable { case push, pull, kick }
    @Transition(on: Input.push)
    fileprivate static func swingOpen(_ source: Closed) -> Open { Open() }
    @Transition(on: Input.pull)
    fileprivate static func swingShut(_ source: Open) -> Closed { Closed() }
    @Transition(from: [Closed.self, Open.self], on: Input.kick)
    fileprivate static func kick() -> Broken { Broken() }
    @Transition(on: Input.push)
    fileprivate static func mend(_ source: Broken) -> Closed { Closed() }
}
