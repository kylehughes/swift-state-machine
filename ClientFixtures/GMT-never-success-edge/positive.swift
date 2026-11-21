// An operation that runs until it fails needs only its failure edge.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    enum Problem: Swift.Error, Sendable { case offline }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Failed: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case failed(Failed)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Fetch {
        typealias Output = Swift.Never
        typealias Failure = Problem
    }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.fetch])
    }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Running, _ failure: Fetch.Failure) -> Failed { Failed() }
}

let lookup = Lookup.Shared(Lookup.Idle(), fetchDriver: { () async -> Result<Never, Lookup.Problem> in .failure(.offline) })
