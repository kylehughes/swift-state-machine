// The request is the last parameter, after the source and the outcome, of a success and a failure edge alike.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go(Swift::Int) }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Input = Swift::Int; typealias Output = Swift::String; typealias Failure = Problem }
    struct Problem: Error {}
    @Transition(on: Input.go, starts: [Fetch.self])
    fileprivate static func go(_ source: Idle, _ value: Swift::Int) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.fetch(value)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running, _ name: Swift::String, request: FetchRequest) -> Idle { Idle() }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Running, _ problem: Problem, request: FetchRequest) -> Idle { Idle() }
}
