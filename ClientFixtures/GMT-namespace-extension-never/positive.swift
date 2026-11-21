// A namespace's extension can take a name the namespace reads from the schema, so each operation alias and event payload
// that names the schema's alias of Never is checked where the compiler resolves it, which finds the extension's type.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Feed: Sendable {
    typealias Detail = Swift::Never
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    @Initial case idle(Idle)
    case loading(Loading)
    enum Input: Sendable { case load, cancel }
    @Operation(activeIn: [Loading.self])
    enum Load {
        typealias Input = Detail
        typealias Key = Detail
        typealias Output = Detail
    }
    @Event enum Logged { typealias Payload = Detail }
    @Transition(on: Input.load, starts: [Load.self], emits: [Logged.self])
    fileprivate static func load(_ source: Idle) -> Change<Loading, Effect.Load> {
        Change(Loading(), effects: [.load(key: 1, input: 2), .logged(3)])
    }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Loading, _ value: Swift::Int) -> Idle { Idle() }
    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Loading) -> Idle { Idle() }
}
extension Feed.Load { typealias Detail = Swift::Int }
extension Feed.Logged { typealias Detail = Swift::Int }
