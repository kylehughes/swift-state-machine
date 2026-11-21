// Sync's cancel-all case and AllSync's per-key case are both cancelAllSync.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Mirror: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case start(Int), stop(Int) }
    @Operation(activeIn: [Idle.self])
    enum Sync { typealias Key = Int }
    @Operation(activeIn: [Idle.self])
    enum AllSync { typealias Key = Int }
    @Transition(on: Input.start, starts: [Sync.self, AllSync.self])
    fileprivate static func start(_ source: Idle, _ id: Int) -> Change<Idle, Effect.Start> {
        Change(source, effects: [.sync(key: id), .allSync(key: id)])
    }
    @Transition(on: Input.stop, cancels: [Sync.self, AllSync.self])
    fileprivate static func stop(_ source: Idle, _ id: Int) -> Change<Idle, Effect.Stop> {
        Change(source, effects: [.cancelSync(key: id), .cancelAllSync(key: id)])
    }
    @Transition(onSuccess: Sync.self)
    fileprivate static func synced(_ source: Idle) -> Idle { source }
    @Transition(onSuccess: AllSync.self)
    fileprivate static func otherSynced(_ source: Idle) -> Idle { source }
}
