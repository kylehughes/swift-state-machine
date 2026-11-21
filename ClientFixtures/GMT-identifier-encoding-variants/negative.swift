// Two edges, one spelled with U+00E9 and one with U+0065 U+0301, differ only in how the accent is encoded:
// two names to Swift, which the macro would compare as text, so it refuses the one not in Normalization Form C.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Visit: Sendable {
    struct Start: Sendable {}
    struct Seated: Sendable {}
    struct Waiting: Sendable {}
    @Initial case start(Start)
    @Terminal case seated(Seated)
    @Terminal case waiting(Waiting)
    enum Input: Sendable { case sit, wait }
    @Transition(on: Input.sit)
    fileprivate static func café(_ source: Start) -> Seated { Seated() }
    @Transition(on: Input.wait)
    fileprivate static func café(_ source: Start) -> Waiting { Waiting() }
}
