// An edge whose effect type is named apart from its schema expands.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Search: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case search(String) }
    @Operation(activeIn: [Idle.self])
    enum Fetch {
        typealias Input = String
        typealias Output = Int
    }
    @Transition(on: Input.search, starts: [Fetch.self])
    fileprivate static func find(_ source: Idle, _ query: String) -> Change<Idle, Effect.Find> {
        Change(source, effects: [.fetch(query)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Idle, _ hits: Fetch.Output) -> Idle { source }
}
