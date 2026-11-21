// An Output spelled through an alias of Void the namespace declares carries no value.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    typealias Unit = Swift.Void
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Push { enum Units { typealias Empty = Swift::Void }; typealias Output = Units.Empty }
    @Transition(on: Input.start, starts: [Push.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.push])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
}

func seal(_ work: Sync.PushWork) -> Sync.PushCompletion { work.succeeded() }
