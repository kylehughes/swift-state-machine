// An operation whose Output and Failure are both Never could never return, even when cancelled.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Failed: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case failed(Failed)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Output = Swift.Never }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.fetch])
    }
    @Transition(on: Input.start)
    fileprivate static func stop(_ source: Running) -> Failed { Failed() }
}
