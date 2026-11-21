// Generated code names modules through selectors, so file-scope types named Swift and StateMachine capture nothing it spells.
import StateMachine

enum Swift {}
enum StateMachine {}

@StateMachine::StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start, stop }
    @Operation(activeIn: [Running.self])
    enum Push {
        typealias Output = Swift::Int
        typealias Failure = Lost
    }
    @Event enum Logged { typealias Payload = Swift::String }
    @Transition(on: Input.start, starts: [Push.self], emits: [Logged.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.push, .logged("start")])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running, _ count: Swift::Int) -> Idle { Idle() }
    @Transition(onFailure: Push.self)
    fileprivate static func broke(_ source: Running, _ failure: Push.Failure) -> Idle { Idle() }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
}

enum Lost: Swift::Error { case gone }
