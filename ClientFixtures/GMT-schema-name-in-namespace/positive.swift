// A namespace's extension can declare a member of the schema's name, which the namespace then names.
// Read through it, the operation's input is a type with values, which the expansion checks.
import StateMachine

enum Other { struct Product: Sendable {} }

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
    @Transition(on: Input.push, starts: [Push.self])
    fileprivate static func push(_ source: Idle) -> Change<Running, Effect.Push> {
        Change(Running(), effects: [.push(Other.Product())])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}
extension Sync.Push { typealias Sync = Other }
