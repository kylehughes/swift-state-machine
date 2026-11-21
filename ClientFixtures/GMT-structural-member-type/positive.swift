// A member of an array type, of a parenthesized base, and of an alias of a parenthesized namespace each read as Swift reads them.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    enum Values { typealias Value = Swift::Int }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop, element([Int].Element), value((Values).Value) }
    @Operation(activeIn: [Running.self])
    enum Load {
        enum Spaces { enum Types { typealias Unit = Swift::Void }; typealias NS = (Types) }
        typealias Output = Spaces.NS.Unit
    }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(on: Input.element)
    fileprivate static func element(_ source: Idle, _ value: Int) -> Idle { source }
    @Transition(on: Input.value)
    fileprivate static func value(_ source: Idle, _ value: Swift::Int) -> Idle { source }
}
