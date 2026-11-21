// Generated code names the schema by its name, which names the schema at its own scope.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lamp: Sendable {
    struct Off: Sendable {}
    struct On: Sendable {}
    @Initial case off(Off)
    case on(On)
    enum Input: Sendable { case toggle }
    @Transition(on: Input.toggle)
    fileprivate static func light(_ source: Off) -> On { On() }
    @Transition(on: Input.toggle)
    fileprivate static func dim(_ source: On) -> Off { Off() }
}
extension Lamp { typealias Bulb = On }
