// A bare Void is read as Swift.Void, so an operation whose Output names a Void declared outside the schema is a compile error, not an operation that produces no value.
import StateMachine

nonisolated struct Void: Sendable { var note = "" }

@StateMachine(mode: .shared)
nonisolated enum Journal: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case write }
    @Operation(activeIn: [Idle.self])
    enum Save { typealias Output = Swift.Void }
    @Transition(on: Input.write, starts: [Save.self])
    fileprivate static func write(_ source: Idle) -> Change<Idle, Effect.Write> {
        Change(source, effects: [.save])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Idle) -> Idle { source }
}

let journal = Journal.Shared(Journal.Idle(), saveDriver: { () async -> Swift.Void in })
