// A bare Never is read as Swift.Never, so an operation whose Failure names a Never declared outside the schema is a compile error, not an infallible operation.
import StateMachine

nonisolated enum Never: Swift.Error, Swift.Sendable { case offline }

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Failure = Swift.Never }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.fetch])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}

let lookup = Lookup.Shared(Lookup.Idle(), fetchDriver: { () async -> Void in })
