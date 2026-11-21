import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Pinger: Sendable {
    struct Ready: Sendable {}
    struct Running: Sendable { let attempt: Int }
    @Initial case ready(Ready)
    case running(Running)
    enum Input: Sendable { case ping(Int) }
    @Operation(activeIn: [Running.self])
    enum Ping { typealias Input = Int }
    @Transition(on: Input.ping, starts: [Ping.self])
    fileprivate static func ping(_ source: Ready, _ attempt: Int) -> Change<Running, Effect.Ping> {
        Change(Running(attempt: attempt), effects: [.ping(attempt)])
    }
    @Transition(onSuccess: Ping.self)
    fileprivate static func finished(_ source: Running, _ output: Void, request: PingRequest) -> Ready { Ready() }
}
