// Input reads the schema's alias of Never as its case's payload, so no input can have the case; the check reads the
// payload through the case's constructor.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Form: Sendable {
    typealias Missing = Swift::Never
    struct Empty: Sendable {}
    struct Filled: Sendable {}
    @Initial case empty(Empty)
    case filled(Filled)
    enum Input: Sendable { case refill(Missing), fill, clear }
    @Transition(on: Input.fill)
    fileprivate static func fill(_ source: Empty) -> Filled { Filled() }
    @Transition(on: Input.clear)
    fileprivate static func clear(_ source: Filled) -> Empty { Empty() }
}
