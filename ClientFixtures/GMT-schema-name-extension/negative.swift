// An extension of the schema that declares a member of the schema's name hides the schema from generated code.
import StateMachine

enum Other {}

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
extension Lamp { typealias Lamp = Other }
