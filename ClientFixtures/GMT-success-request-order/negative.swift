// A success edge that takes only the request leaves out the output its operation succeeds with, which is diagnosed at
// the request parameter.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go(Swift::String) }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Input = Swift::String; typealias Output = Swift::Int }
    @Transition(on: Input.go, starts: [Fetch.self])
    fileprivate static func go(_ source: Idle, _ name: Swift::String) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.fetch(name)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running, request: FetchRequest) -> Idle { Idle() }
}
