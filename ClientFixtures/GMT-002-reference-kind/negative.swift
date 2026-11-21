import StateMachine
@StateMachine(mode: .shared)
nonisolated enum OperationWitness: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    @Initial case idle(Idle)
    case loading(Loading)
    enum RequestFailure: Error { case rejected }
    enum Scope {
        @Active(in: [Loading.self])
        case work
    }
    enum Input: Sendable { case begin }
    @Operation(scope: Scope.work, admission: .latest)
    enum Fetch { typealias Input = any Error; typealias Output = Int; typealias Failure = Never }
    @Transition(on: Input.begin, starts: [Loading.self])
    fileprivate static func begin(_ source: Idle) -> Change<Loading, Effect.Begin> {
        Change(Loading(), effects: [.fetch(RequestFailure.rejected)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ value: Fetch.Output) -> Idle { Idle() }
}
