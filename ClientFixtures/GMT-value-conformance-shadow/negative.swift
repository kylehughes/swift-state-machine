// A file-scope protocol named Equatable is not the standard library's, which the generated effects would conform to.
import StateMachine

protocol Equatable {}

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable, Equatable {
    struct Shut: Sendable {}
    struct Open: Sendable {}
    @Initial case shut(Shut)
    @Terminal case open(Open)
    enum Input: Sendable { case open }
    @Event enum Opened {}
    @Transition(on: Input.open, emits: [Opened.self])
    fileprivate static func open(_ source: Shut) -> Change<Open, Effect.Open> { Change(Open(), effects: [.opened]) }
}
