// Input resolves its case's payload through its own extension, and the witness infers the payload through the case's
// constructor, so the edge takes the type Swift gives the case, even when the schema's alias of that name is Never.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Form: Sendable {
    typealias Detail = Swift::String
    typealias Missing = Swift::Never
    struct Empty: Sendable {}
    struct Filled: Sendable { let value: Int }
    @Initial case empty(Empty)
    case filled(Filled)
    enum Input: Sendable { case fill(Detail), refill(Missing), clear }
    @Transition(on: Input.fill)
    fileprivate static func fill(_ source: Empty, _ value: Swift::Int) -> Filled { Filled(value: value) }
    @Transition(on: Input.refill)
    fileprivate static func refill(_ source: Filled, _ value: Swift::Int) -> Filled { Filled(value: value) }
    @Transition(on: Input.clear)
    fileprivate static func clear(_ source: Filled) -> Empty { Empty() }
}
extension Form.Input {
    typealias Detail = Swift::Int
    typealias Missing = Swift::Int
}
func fill() {
    let form = Form.Shared(Form.Empty())
    _ = try? form.send(.fill(3))
    _ = try? form.send(.refill(4))
}
