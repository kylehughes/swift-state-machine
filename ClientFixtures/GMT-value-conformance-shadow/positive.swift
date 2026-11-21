// A bare Equatable in the schema's inheritance clause names the standard library's protocol, which the generated effects repeat.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable, Equatable {
    struct Shut: Sendable, Equatable {}
    struct Open: Sendable, Equatable {}
    @Initial case shut(Shut)
    @Terminal case open(Open)
    enum Input: Sendable { case open }
    @Event enum Opened {}
    @Transition(on: Input.open, emits: [Opened.self])
    fileprivate static func open(_ source: Shut) -> Change<Open, Effect.Open> { Change(Open(), effects: [.opened]) }
}
func check() -> Bool { Gate.Effect.opened == Gate.Effect.opened }
