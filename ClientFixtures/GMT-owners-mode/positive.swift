// An isolated schema can select the owners its mode supports.
import StateMachine

@StateMachine(mode: .isolated, owners: [.local, .mainActorHost])
nonisolated enum Sketch {
    struct Blank {}
    @Initial case blank(Blank)
    enum Input { case clear }
    @Transition(on: Input.clear)
    fileprivate static func clear(_ source: Blank) -> Blank { source }
}
