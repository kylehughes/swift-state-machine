import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Guarded: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    @Initial case idle(Idle)
    case loading(Loading)
    enum Scope { case work }
    enum Input: Sendable { case begin(Int), note(Int), pick(Bool) }
    @Operation(scope: Scope.work, activeIn: [Loading.self], admission: .latest)
    enum Fetch { typealias Input = Int; typealias Output = Int; typealias Failure = Never }
    @Operation(scope: Scope.work, activeIn: [Loading.self], admission: .latest)
    enum Audit { typealias Input = Int; typealias Output = Int; typealias Failure = Never }
    @Transition(on: Input.begin, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ request: Int) -> Change<Loading, Effect.Begin> {
        Change(Loading(), effects: [.audit(request)])
    }
    @Transition(on: Input.note, starts: [Audit.self])
    fileprivate static func note(_ source: Loading, _ value: Int) -> Change<Loading, Effect.Note> {
        Change(source, effects: [.audit(value)])
    }
    @Transition(on: Input.pick)
    fileprivate static func stay(_ source: Loading, _ again: Bool) -> Loading { source }
    @Transition(on: Input.pick)
    fileprivate static func leave(_ source: Loading, _ again: Bool) -> Idle { Idle() }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Loading, _ again: Bool) -> Route.Choose { again ? .stay : .leave }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ value: Fetch.Output) -> Idle { Idle() }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Loading, _ value: Audit.Output) -> Loading { source }
}
