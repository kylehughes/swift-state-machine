// An Output that is the request's own type is taken unlabeled as the output, and the request again as request:.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go(Swift::Int) }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Input = Swift::Int; typealias Output = FetchRequest }
    @Operation(activeIn: [Running.self])
    enum Count { typealias Input = Swift::Int; typealias Output = Swift::Int }
    @Transition(on: Input.go, starts: [Fetch.self, Count.self])
    fileprivate static func go(_ source: Idle, _ value: Swift::Int) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.fetch(value), .count(value)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Running, _ output: FetchRequest, request: FetchRequest) -> Running { source }
    @Transition(onSuccess: Count.self)
    fileprivate static func counted(_ source: Running, _ count: Swift::Int, request: CountRequest) -> Idle { Idle() }
}
