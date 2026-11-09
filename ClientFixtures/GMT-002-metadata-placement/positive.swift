import StateMachine
import StateMachineSchema
@StateMachine(mode: .shared)
nonisolated enum OperationWitness: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    @Initial case idle(Idle)
    case loading(Loading)
    enum RequestFailure: Error { case rejected }
    enum Scope { case work }
    enum Input: Sendable { case begin }
    enum Effect: Sendable { case fetch(Fetch.Input) }
    @Operation(scope: Scope.work, activeIn: [Loading.self], admission: .latest)
    enum Fetch { typealias Input = any Error; typealias Output = Int; typealias Failure = Never }
    @Transition(on: Input.begin, starts: [Fetch.self])
    fileprivate static func begin(_ source: borrowing Idle) -> Change<Loading, Effect> {
        Change(Loading(), effects: [.fetch(RequestFailure.rejected)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: borrowing Loading, _ value: Fetch.Output) -> Change<Idle, Effect> { Change(Idle()) }
}
