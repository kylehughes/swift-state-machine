// The inheritance clause is read where the schema is declared, so a type of a protocol's name in its body does not take it:
// the schema and its generated effects conform to the standard library's Equatable and Hashable.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable, Equatable, Hashable {
    struct Equatable {}
    protocol Hashable {}
    struct Shut: Sendable, Swift::Hashable {}
    struct Open: Sendable, Swift::Hashable {}
    @Initial case shut(Shut)
    case open(Open)
    enum Input: Sendable { case toggle }
    @Event enum Opened { typealias Payload = Swift::Int }
    @Transition(on: Input.toggle, emits: [Opened.self])
    fileprivate static func open(_ source: Shut) -> Change<Open, Effect.Open> { Change(Open(), effects: [.opened(1)]) }
    @Transition(on: Input.toggle)
    fileprivate static func shut(_ source: Open) -> Shut { Shut() }
}
func needs<T: Swift::Hashable>(_: T.Type) {}
func check() { needs(Gate.Effect.self) }
