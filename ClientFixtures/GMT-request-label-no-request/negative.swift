// An operation without a key or an input has no request, so a request: parameter is diagnosed, whatever it spells.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Echo: Sendable {
    typealias FetchRequest = Swift::Int
    typealias Started = ListenRequest
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Heard: Sendable { let value: Int }
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case heard(Heard)
    enum Input: Sendable { case fetch, load(Int), listen(Int) }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Output = Swift::Int }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Input = Int; typealias Output = StateMachine::OperationRequest<Load, Int> }
    @Operation(activeIn: [Running.self])
    enum Listen { typealias Input = Int; typealias Output = ListenRequest }
    @Transition(on: Input.fetch, starts: [Fetch.self])
    fileprivate static func fetch(_ source: Idle) -> Change<Running, Effect.Fetch> { Change(Running(), effects: [.fetch]) }
    @Transition(on: Input.load, starts: [Load.self])
    fileprivate static func load(_ source: Idle, _ value: Int) -> Change<Running, Effect.Load> { Change(Running(), effects: [.load(value)]) }
    @Transition(on: Input.listen, starts: [Listen.self])
    fileprivate static func listen(_ source: Idle, _ value: Int) -> Change<Running, Effect.Listen> { Change(Running(), effects: [.listen(value)]) }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Running, _ value: Swift::Int, request: FetchRequest) -> Heard { Heard(value: value) }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Running, _ value: LoadRequest) -> Heard { Heard(value: value.input) }
    @Transition(onSuccess: Listen.self)
    fileprivate static func listened(_ source: Running, request: Started) -> Heard { Heard(value: request.input) }
}

extension Echo.Listen { typealias ListenRequest = Swift::Void }
