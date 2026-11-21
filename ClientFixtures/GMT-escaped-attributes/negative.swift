// An escaped autoclosure is the autoclosure generated code cannot pass on.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case run(Int) }
    @Transition(on: Input.run)
    fileprivate static func run(_ source: Idle, _ value: @`autoclosure` () -> Int) -> Idle { source }
}
