// A schema's own Never is the type it declares, so an operation that names it can fail with it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    enum Never: Swift.Error, Swift.Sendable { case offline }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Failed: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case failed(Failed)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Failure = Never }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.fetch])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Running, _ failure: Fetch.Failure) -> Failed { Failed() }
}

let lookup = Lookup.Shared(Lookup.Idle(), fetchDriver: { () async -> Result<Void, Lookup.Never> in .failure(.offline) })
