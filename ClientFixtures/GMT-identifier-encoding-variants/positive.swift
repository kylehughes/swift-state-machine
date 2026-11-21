// Two edges whose names are in Normalization Form C are two names to the macro as they are to Swift.
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
    fileprivate static func cafés(_ source: Start) -> Waiting { Waiting() }
}

func seat(_ start: Visit.Observed<Visit.Start>) -> Visit.Prepared { start.café() }
