// A dotted Swift.Equatable names the Equatable of a Swift declared at file scope, which the schema conforms to instead of
// the standard library's; the generated check of the schema's conformance reports it.
import StateMachine

enum Swift { protocol Equatable {} }

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable, Swift.Equatable {
    struct Shut: Sendable {}
    struct Open: Sendable {}
    @Initial case shut(Shut)
    @Terminal case open(Open)
    enum Input: Sendable { case open }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Shut) -> Open { Open() }
}
