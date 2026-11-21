// A type alias of the schema's name hides the schema inside it, which the check reports.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Form: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle = Idle())
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}
enum Other {}
extension Form { typealias Form = Other }
