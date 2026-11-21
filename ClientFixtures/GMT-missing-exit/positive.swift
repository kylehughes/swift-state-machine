// A phase the graph intends to end in is marked terminal.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Upload: Sendable {
    struct Ready: Sendable {}
    struct Sent: Sendable {}
    @Initial case ready(Ready)
    @Terminal case sent(Sent)
    enum Input: Sendable { case send }
    @Transition(on: Input.send)
    fileprivate static func send(_ source: Ready) -> Sent { Sent() }
}
