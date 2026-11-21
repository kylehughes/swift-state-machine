// The namespace's extension makes its Output an Int, which the macro cannot see, and the success edge takes the output,
// so the operation produces one.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Meter: Sendable {
    typealias Product = Swift::Void
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Read { typealias Output = Product }
    @Transition(on: Input.go, starts: [Read.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.read]) }
    @Transition(onSuccess: Read.self)
    fileprivate static func done(_ source: Running, _ value: Read.Output) -> Idle { Idle() }
}
extension Meter.Read { typealias Product = Swift::Int }
func check() { _ = Meter.Shared(Meter.Idle(), readDriver: { 42 }) }
