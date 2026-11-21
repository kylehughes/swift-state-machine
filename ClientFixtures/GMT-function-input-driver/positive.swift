// A driver takes an input the macro confirms is a function type as escaping, so it can return or keep the closure its
// request stores; one behind an alias the macro cannot see reaches the driver as it is, which can call it.
import StateMachine
import StateMachineTesting

public struct Problem: Swift::Error {}

@StateMachine(mode: .shared)
nonisolated enum Work: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Run { typealias Input = @Sendable () -> Int; typealias Output = Input; typealias Failure = Problem }
    @Transition(on: Input.go, starts: [Run.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.run({ 1 })]) }
    @Transition(onSuccess: Run.self)
    fileprivate static func done(_ source: Running, _ value: @escaping @Sendable () -> Int) -> Idle { Idle() }
    @Transition(onFailure: Run.self)
    fileprivate static func failed(_ source: Running, _ failure: Problem) -> Idle { Idle() }
}
func check() {
    _ = Work.Shared(Work.Idle(), runDriver: { work in .success(work) })
    let driver = ControlledDriver<@Sendable () -> Int, @Sendable () -> Int, Problem>()
    _ = Work.Shared(Work.Idle(), runDriver: driver.run)
}

public typealias Closure = @Sendable () -> Int

@StateMachine(mode: .shared)
nonisolated enum Opaque: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Run { typealias Input = Closure; typealias Output = Int; typealias Failure = Problem }
    @Transition(on: Input.go, starts: [Run.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.run({ 1 })]) }
    @Transition(onSuccess: Run.self)
    fileprivate static func done(_ source: Running, _ value: Int) -> Idle { Idle() }
    @Transition(onFailure: Run.self)
    fileprivate static func failed(_ source: Running, _ failure: Problem) -> Idle { Idle() }
}
func opaque() -> Opaque.RunRequest {
    _ = Opaque.Shared(Opaque.Idle(), runDriver: { work in .success(work()) })
    return Opaque.RunRequest(input: { 2 })
}
