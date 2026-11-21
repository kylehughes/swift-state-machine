// An operation holding a named scope runs in that scope's phases.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Search: Sendable {
    struct Idle: Sendable {}
    struct Searching: Sendable {}
    @Initial case idle(Idle)
    case searching(Searching)
    enum Scope {
        @Active(in: [Searching.self])
        case query
    }
    enum Input: Sendable { case search, cancel }
    @Operation(scope: Scope.query)
    enum Lookup { typealias Output = Int }
    @Transition(on: Input.search, starts: [Lookup.self])
    fileprivate static func begin(_ source: Idle) -> Change<Searching, Effect.Begin> {
        Change(Searching(), effects: [.lookup])
    }
    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Searching) -> Idle { Idle() }
    @Transition(onSuccess: Lookup.self)
    fileprivate static func found(_ source: Searching, _ count: Lookup.Output) -> Idle { Idle() }
}
