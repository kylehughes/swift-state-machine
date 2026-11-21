import StateMachine

@StateMachine(mode: .shared, owners: [.local, .shared])
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    @Initial case idle(Idle)
    case loading(Loading)
    enum Input: Sendable { case load }
    @Operation(activeIn: [Loading.self])
    enum Fetch { typealias Output = Int }
    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func load(_ source: Idle) -> Change<Loading, Effect.Load> { Change(Loading(), effects: [.fetch]) }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func loaded(_ source: Loading, _ value: Int) -> Idle { Idle() }
}

/// A completion is a public type only for an owner that hands it to its caller.
func value(of completion: Lookup.FetchCompletion) -> Int { completion.value }
