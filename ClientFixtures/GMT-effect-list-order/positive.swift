// Edges of one name that may emit the same events, listed in any order, share `Effect.Tap`.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lamp: Sendable {
    struct Off: Sendable {}
    struct On: Sendable {}
    @Initial case off(Off)
    case on(On)
    enum Input: Sendable { case tap }
    @Event enum Logged {}
    @Event enum Tracked {}
    @Transition(on: Input.tap, emits: [Logged.self, Tracked.self])
    fileprivate static func tap(_ source: Off) -> Change<On, Effect.Tap> { Change(On(), effects: [.logged]) }
    @Transition(on: Input.tap, emits: [Tracked.self, Logged.self])
    fileprivate static func tap(_ source: On) -> Change<Off, Effect.Tap> { Change(Off(), effects: [.tracked, .logged]) }
}
