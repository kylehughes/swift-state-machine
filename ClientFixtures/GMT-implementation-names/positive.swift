// Errors outside the schema named like the local aliases of generated checks keep their meaning: each check takes a name the schema never spells.
import StateMachine

public struct _StateMachineProbed: Swift::Error {}
public struct _StateMachineChecked: Swift::Error {}

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable {
    struct Shut: Sendable {}
    struct Open: Sendable {}
    @Initial case shut(Shut)
    @Terminal case open(Open)
    enum Input: Sendable { case open, force }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Shut) throws(_StateMachineProbed) -> Open { Open() }
    @Transition(on: Input.force)
    fileprivate static func force(_ source: Shut) throws(_StateMachineChecked) -> Open { Open() }
}
func check() {
    _ = Gate.PreparationRejection.open(_StateMachineProbed())
    _ = Gate.PreparationRejection.force(_StateMachineChecked())
}
