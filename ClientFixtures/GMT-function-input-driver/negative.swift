// A function-typed input spelled through an alias the macro cannot see is stored by its request, but reaches the driver as
// it is, so a driver that returns it is rejected.
import StateMachine

public struct Problem: Swift::Error {}
public typealias Closure = @Sendable () -> Int

@StateMachine(mode: .shared)
nonisolated enum Work: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Run { typealias Input = Closure; typealias Output = Closure; typealias Failure = Problem }
    @Transition(on: Input.go, starts: [Run.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.run({ 1 })]) }
    @Transition(onSuccess: Run.self)
    fileprivate static func done(_ source: Running, _ value: @escaping @Sendable () -> Int) -> Idle { Idle() }
    @Transition(onFailure: Run.self)
    fileprivate static func failed(_ source: Running, _ failure: Problem) -> Idle { Idle() }
}
func check() { _ = Work.Shared(Work.Idle(), runDriver: { work in .success(work) }) }
