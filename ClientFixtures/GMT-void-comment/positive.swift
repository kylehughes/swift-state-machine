// An empty tuple is `Void` whatever its comments, so the success edge takes only its source.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Pinger: Sendable {
    struct Ready: Sendable {}
    struct Running: Sendable {}
    @Initial case ready(Ready)
    case running(Running)
    enum Input: Sendable { case ping }
    @Operation(activeIn: [Running.self])
    enum Ping { typealias Output = ( /* nothing to report */ ) }
    @Transition(on: Input.ping, starts: [Ping.self])
    fileprivate static func ping(_ source: Ready) -> Change<Running, Effect.Ping> {
        Change(Running(), effects: [.ping])
    }
    @Transition(onSuccess: Ping.self)
    fileprivate static func finished(_ source: Running) -> Ready { Ready() }
}
