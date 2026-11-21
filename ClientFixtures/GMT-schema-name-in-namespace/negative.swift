// A namespace's extension can declare a member of the schema's name, so the operation's input, which the namespace spells
// through that name, is Never, although the schema's own type has values; the expansion's check reports it.
import StateMachine

enum Other { typealias Product = Swift::Never }

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Product: Sendable {}
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case push }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Input = Sync.Product }
    @Event enum Pinged {}
    @Transition(on: Input.push, starts: [Push.self], emits: [Pinged.self])
    fileprivate static func push(_ source: Idle) -> Change<Running, Effect.Push> { Change(Running(), effects: [.pinged]) }
    @Transition(onSuccess: Push.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}
extension Sync.Push { typealias Sync = Other }
