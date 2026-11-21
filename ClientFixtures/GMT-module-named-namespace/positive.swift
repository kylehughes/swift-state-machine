// A router or transition named for a module generates a type with the module's name, so generated
// code inside Route and Effect spells that module through a module selector.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Compiler: Sendable, Hashable {
    struct Idle: Sendable, Hashable {}
    struct Built: Sendable, Hashable {}
    @Initial case idle(Idle)
    case built(Built)
    enum Input: Sendable { case build, clean, log }
    @Event enum Logged {}
    @Route(on: Input.build)
    fileprivate static func swift(_ source: Idle) -> Route.Swift { .compile }
    @Transition(on: Input.build)
    fileprivate static func compile(_ source: Idle) -> Built { Built() }
    @Transition(on: Input.build)
    fileprivate static func skip(_ source: Idle) -> Idle { source }
    @Transition(on: Input.clean)
    fileprivate static func clean(_ source: Built) -> Idle { Idle() }
    @Transition(on: Input.log, emits: [Logged.self])
    fileprivate static func stateMachine(_ source: Idle) -> Change<Idle, Effect.StateMachine> {
        Change(source, effects: [.logged])
    }
}

let choice: Compiler.Route.Swift = .compile
