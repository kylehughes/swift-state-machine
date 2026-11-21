// The label decides each role: an Output that is the request's own type is taken unlabeled as the output, and an alias of
// the request labeled request: is the request of an operation without output.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Echo: Sendable {
    typealias Started = ListenRequest
    nonisolated struct Idle: Sendable {}
    nonisolated struct Running: Sendable {}
    nonisolated struct Heard: Sendable { let value: Int }
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case heard(Heard)
    enum Input: Sendable { case fetch(Int), listen(Int) }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Input = Int; typealias Output = FetchRequest }
    @Operation(activeIn: [Running.self])
    enum Listen { typealias Input = Int }
    @Transition(on: Input.fetch, starts: [Fetch.self])
    fileprivate static func fetch(_ source: Idle, _ value: Int) -> Change<Running, Effect.Fetch> { Change(Running(), effects: [.fetch(value)]) }
    @Transition(on: Input.listen, starts: [Listen.self])
    fileprivate static func listen(_ source: Idle, _ value: Int) -> Change<Running, Effect.Listen> { Change(Running(), effects: [.listen(value)]) }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Running, _ output: FetchRequest) -> Heard { Heard(value: output.input) }
    @Transition(onSuccess: Listen.self)
    fileprivate static func listened(_ source: Running, request: Started) -> Heard { Heard(value: request.input) }
}
