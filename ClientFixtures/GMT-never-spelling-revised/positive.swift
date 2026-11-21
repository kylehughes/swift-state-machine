// A file-scope Never names Problem. The router with no edge must throw, so its throws(Never) names a type with values,
// and the edge that throws the same spelling throws it too.
import StateMachine

public struct Problem: Swift::Error, Swift::Sendable { public init() {} }
typealias Never = Problem

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable {
    struct Idle: Sendable {}
    struct Open: Sendable {}
    @Initial case idle(Idle)
    @Terminal case open(Open)
    enum Input: Sendable { case open, refuse }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Idle) throws(Never) -> Open { throw Problem() }
    @Route(on: Input.refuse)
    fileprivate static func refuse(_ source: Idle) throws(Never) -> Swift::Never { throw Problem() }
}
