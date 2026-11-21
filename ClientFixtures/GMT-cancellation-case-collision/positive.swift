// Two keyed operations whose cancellation cases have distinct names can both be cancelled.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Mirror: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case start(Int), stop(Int) }
    @Operation(activeIn: [Idle.self])
    enum Sync { typealias Key = Int }
    @Operation(activeIn: [Idle.self])
    enum Echo { typealias Key = Int }
    @Transition(on: Input.start, starts: [Sync.self, Echo.self])
    fileprivate static func start(_ source: Idle, _ id: Int) -> Change<Idle, Effect.Start> {
        Change(source, effects: [.sync(key: id), .echo(key: id)])
    }
    @Transition(on: Input.stop, cancels: [Sync.self, Echo.self])
    fileprivate static func stop(_ source: Idle, _ id: Int) -> Change<Idle, Effect.Stop> {
        Change(source, effects: [.cancelSync(key: id), .cancelEcho(key: id)])
    }
    @Transition(onSuccess: Sync.self)
    fileprivate static func synced(_ source: Idle) -> Idle { source }
    @Transition(onSuccess: Echo.self)
    fileprivate static func otherSynced(_ source: Idle) -> Idle { source }
}
