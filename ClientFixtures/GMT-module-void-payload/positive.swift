// A bare Void is read as Swift.Void, so an event Payload and an operation Input that name a Void declared outside the schema are compile errors, not values the event and the operation do not carry.
import StateMachine

nonisolated struct Void: Sendable { var note = "" }

@StateMachine(mode: .shared)
nonisolated enum Journal: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case write }
    @Operation(activeIn: [Idle.self])
    enum Save { typealias Input = Swift.Void }
    @Event enum Logged { typealias Payload = Swift.Void }
    @Transition(on: Input.write, starts: [Save.self], emits: [Logged.self])
    fileprivate static func write(_ source: Idle) -> Change<Idle, Effect.Write> {
        Change(source, effects: [.save, .logged])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Idle) -> Idle { source }
}

let journal = Journal.Shared(Journal.Idle(), saveDriver: { () async -> Swift.Void in }, onLogged: {})
