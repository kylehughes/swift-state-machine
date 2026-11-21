// A spelling that names a declaration outside the schema by one of the expansion's implementation names is diagnosed, since the generated declaration would hide it.
import StateMachine

public struct _StateMachineEngine: Swift::Error {}

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable {
    struct Shut: Sendable {}
    struct Open: Sendable {}
    @Initial case shut(Shut)
    @Terminal case open(Open)
    enum Input: Sendable { case open }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Shut) throws(_StateMachineEngine) -> Open { Open() }
}
