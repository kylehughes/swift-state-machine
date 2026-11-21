// Redundant backticks around an emoji or an accented identifier change no name, so aliases of Never spelled with them leave operations that cannot fail.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Garden: Sendable {
    typealias 🌱 = Swift::Never
    typealias Café = Swift::Never
    struct Idle: Sendable {}
    struct Growing: Sendable {}
    @Initial case idle(Idle)
    case growing(Growing)
    enum Input: Sendable { case plant }
    @Operation(activeIn: [Growing.self])
    enum Sprout { typealias Failure = `🌱` }
    @Operation(activeIn: [Growing.self])
    enum Bloom { typealias Failure = `Café` }
    @Transition(on: Input.plant, starts: [Sprout.self, Bloom.self])
    fileprivate static func plant(_ source: Idle) -> Change<Growing, Effect.Plant> { Change(Growing(), effects: [.sprout, .bloom]) }
    @Transition(onSuccess: Sprout.self)
    fileprivate static func sprouted(_ source: Growing) -> Idle { Idle() }
    @Transition(onSuccess: Bloom.self)
    fileprivate static func bloomed(_ source: Growing) -> Idle { Idle() }
}
func check() { _ = Garden.Shared(Garden.Idle(), sproutDriver: {}, bloomDriver: {}) }
