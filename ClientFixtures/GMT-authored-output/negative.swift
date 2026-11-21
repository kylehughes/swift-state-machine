// The success edge takes no output, so the macro reads the operation's Output as Void, which the expansion checks: the
// namespace's extension makes it an Int.
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
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}
extension Meter.Read { typealias Product = Swift::Int }
func check() { _ = Meter.Shared(Meter.Idle(), readDriver: { 42 }) }
