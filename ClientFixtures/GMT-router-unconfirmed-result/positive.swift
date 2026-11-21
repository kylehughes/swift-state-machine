// A router with no edge to choose returns Never, which an alias declared outside the schema may name; the expansion checks it.
import StateMachine

public struct Refusal: Error, Sendable {}
typealias Nothing = Swift::Never

@StateMachine(mode: .shared)
nonisolated enum Desk: Sendable {
    struct Open: Sendable {}
    struct Closed: Sendable {}
    @Initial case open(Open)
    @Terminal case closed(Closed)
    enum Input: Sendable { case ask, close }
    @Route(on: Input.ask)
    fileprivate static func refuse(_ source: Open) throws(Refusal) -> Nothing { throw Refusal() }
    @Transition(on: Input.close)
    fileprivate static func close(_ source: Open) -> Closed { Closed() }
}
