// The namespace's alias names Void, which the macro confirms, so the success edge takes no output parameter.
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
    fileprivate static func pushed(_ source: Running, _ value: Unit) -> Idle { Idle() }
}

func seal(_ work: Sync.PushWork) -> Sync.PushCompletion { work.succeeded() }
