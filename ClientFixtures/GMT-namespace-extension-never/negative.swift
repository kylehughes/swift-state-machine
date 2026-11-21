// Without the extension, the operation's input is the schema's alias of Never, which the check reports.
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
    enum Load { typealias Input = Detail }
    @Event enum Logged {}
    @Transition(on: Input.load, starts: [Load.self], emits: [Logged.self])
    fileprivate static func load(_ source: Idle) -> Change<Loading, Effect.Load> { Change(Loading(), effects: [.logged]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Loading) -> Idle { Idle() }
    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Loading) -> Idle { Idle() }
}
