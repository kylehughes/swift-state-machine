// A spelling that spans lines and names an authored _StateMachineType1 is aliased under another name where Owned<Phase> would capture it.
import StateMachine

public struct Phase: Sendable { public init() {} }
public struct _StateMachineType1: Sendable { public init() {} }

@StateMachine(mode: .shared)
public nonisolated enum Gate: Sendable {
    public struct Shut: Sendable {}
    public struct Open: Sendable {}
    @Initial case shut(Shut)
    case open(Open)
    public enum Input: Sendable {
        case open((
            Phase, // the caller's phase
            _StateMachineType1
        ))
        case close
    }
    @Transition(on: Input.open)
    public static func open(_ source: Shut, _ value: (
        Phase, // the caller's phase
        _StateMachineType1
    )) -> Open { Open() }
    @Transition(on: Input.close)
    public static func close(_ source: Open) -> Shut { Shut() }
}

func open(_ owned: consuming Gate.Owned<Gate.Shut>) -> Gate.Owned<Gate.Open> {
    owned.open((Phase(), _StateMachineType1()))
}
