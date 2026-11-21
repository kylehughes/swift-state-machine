// A success edge of an operation that succeeds with output takes the output after the source, then the request, labeled
// request:.
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
    fileprivate static func done(_ source: Running, _ count: Fetch.Output, request: FetchRequest) -> Idle { Idle() }
}
