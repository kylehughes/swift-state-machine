import StateMachine
import StateMachineSchema
@StateMachine(mode: .shared, initial: "idle", scopes: ["work"])
nonisolated enum OperationWitness: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    case idle(Idle)
    case loading(Loading)
    enum RequestFailure: Error { case rejected }
    enum Input: Sendable { case begin }
    enum Effect: Sendable { case fetch(Fetch.Input) }
    @Operation(effect: "fetch", scope: "work", activeIn: ["loading"], admission: .latest)
    enum Fetch { typealias Input = any Error; typealias Output = Int; typealias Failure = Never }
    @Transition(from: "idle", to: "loading", on: .input("begin"), starts: ["fetch"])
    fileprivate static func begin(_ source: borrowing Idle) -> Change<Loading, Effect> {
        Change(Loading(), effects: [.fetch(RequestFailure.rejected)])
    }
    @Transition(from: "loading", to: "idle", on: .success("fetch"))
    fileprivate static func received(_ source: borrowing Loading, _ value: Fetch.Output) -> Change<Idle, Effect> { Change(Idle()) }
}
