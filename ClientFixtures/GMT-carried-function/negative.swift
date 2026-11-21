// The request's generic parameter stores the closure, so it rejects a non-escaping argument as an escaping parameter does.
import StateMachine

public typealias Closure = @Sendable () -> Swift::Int

@StateMachine(mode: .shared)
nonisolated enum Job: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go(Run.Input) }
    @Operation(activeIn: [Running.self])
    enum Run { typealias Input = Closure; typealias Output = Closure }
    @Transition(on: Input.go, starts: [Run.self])
    fileprivate static func go(_ source: Idle, _ work: @escaping Run.Input) -> Change<Running, Effect.Go> { Change(Running(), effects: [.run(work)]) }
    @Transition(onSuccess: Run.self)
    fileprivate static func done(_ source: Running, _ value: Run.Output, request: RunRequest) -> Idle { Idle() }
}
func check(_ work: Closure) -> Job.RunRequest {
    var local = Job.Local(Job.Idle())
    _ = try? local.send(.go({ 1 }))
    for batch in local.drainCommands() {
        for command in batch.commands {
            if case .run(let work) = command { _ = local.deliver(.run(work.succeeded(work.input))) }
        }
    }
    _ = Job.Shared(Job.Idle(), runDriver: { input in let value = input(); return { value } })
    return Job.RunRequest(input: work)
}
