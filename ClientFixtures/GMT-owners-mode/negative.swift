// An isolated schema cannot select an owner that shares its values.
import StateMachine

@StateMachine(mode: .isolated, owners: [.local, .shared])
nonisolated enum Sketch {
    struct Blank {}
    @Initial case blank(Blank)
    enum Input { case clear }
    @Transition(on: Input.clear)
    fileprivate static func clear(_ source: Blank) -> Blank { source }
}
