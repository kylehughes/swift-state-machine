// A candidate that throws another type cannot join a router that pins its failure.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Pinned: Sendable {
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start)
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int) }
    enum Problem: Error, Sendable { case negative }
    enum Other: Error, Sendable { case odd }
    typealias Alias = Problem
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Other) -> Right { Right() }
    @Route(on: Input.pick, failure: Problem.self)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem) -> Route.Pick {
        guard value >= 0 else { throw .negative }
        return value < 10 ? .goLeft : .goRight
    }
}
