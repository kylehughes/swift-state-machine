// A schema's own Void is the type it declares, so an operation and an event that name it carry a value.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Journal: Sendable {
    struct Void: Sendable { let note: Swift.String }
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case write }
    @Operation(activeIn: [Idle.self])
    enum Save {
        typealias Input = Void
        typealias Output = Void
    }
    @Event enum Logged { typealias Payload = Void }
    @Transition(on: Input.write, starts: [Save.self], emits: [Logged.self])
    fileprivate static func write(_ source: Idle) -> Change<Idle, Effect.Write> {
        Change(source, effects: [.save(Void(note: "draft")), .logged(Void(note: "wrote"))])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Idle, _ output: Void) -> Idle { source }
}

let journal = Journal.Shared(Journal.Idle(), saveDriver: { input in Journal.Void(note: input.note) }, onLogged: { _ in })
