// A static property of the schema's name hides no type, so generated code that names the schema, its check and its
// initial default included, still names it.
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
extension Form { static var Form: Swift::Int { 123 } }
