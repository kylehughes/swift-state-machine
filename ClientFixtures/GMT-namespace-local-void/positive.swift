// An operation namespace's own Void and an event namespace's own Void are the types they declare, so the operation's input and output and the event's payload carry values of those types.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Journal: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case write }
    @Operation(activeIn: [Idle.self])
    enum Save {
        struct Void: Sendable { let note: Swift.String }
        typealias Input = Void
        typealias Output = Void
    }
    @Event enum Logged {
        struct Void: Sendable { let note: Swift.String }
        typealias Payload = Void
    }
    @Transition(on: Input.write, starts: [Save.self], emits: [Logged.self])
    fileprivate static func write(_ source: Idle) -> Change<Idle, Effect.Write> {
        Change(source, effects: [.save(Save.Void(note: "draft")), .logged(Logged.Void(note: "wrote"))])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Idle, _ output: Save.Void) -> Idle { source }
}

let journal = Journal.Shared(Journal.Idle(), saveDriver: { input in Journal.Save.Void(note: input.note) }, onLogged: { _ in })
