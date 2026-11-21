// Unicode is no standard name whose kind the macro knows, so without a success edge its Output is checked to be Never.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .mainActorHost])
nonisolated enum Scan {
    nonisolated struct Idle {}
    nonisolated struct Running {}
    nonisolated struct Problem: Swift::Error {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input { case go }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Input = Swift::UnboundedRange; typealias Output = Swift::Unicode; typealias Failure = Problem }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load({ _ in })]) }
    
    @Transition(onFailure: Load.self)
    fileprivate static func failed(_ source: Running, _ failure: Problem) -> Idle { Idle() }
}

@MainActor func makeScan() -> Scan.MainActorHost { Scan.MainActorHost(Scan.Idle(), loadDriver: { _ in .failure(Scan.Problem()) }) }
