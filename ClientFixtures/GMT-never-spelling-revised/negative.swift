// Without the router, the edge's throws(Never) reads as the standard library's Never, which the expansion checks.
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
    @Transition(on: Input.refuse)
    fileprivate static func refuse(_ source: Idle) -> Idle { Idle() }
}
