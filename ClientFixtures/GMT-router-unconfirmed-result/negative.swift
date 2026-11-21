// An alias outside the schema that names a type with values cannot be what a router with no edge to choose returns.
import StateMachine

public struct Refusal: Error, Sendable {}
typealias Nothing = Swift::Int

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
