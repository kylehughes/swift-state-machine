// @PhaseSet placed outside a @StateMachine enum is rejected by MetadataMacro.
import StateMachine

struct Idle {}

@PhaseSet([Idle.self])
enum StandalonePhaseSet {}
