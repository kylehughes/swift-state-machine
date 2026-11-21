// Escaped references and declarations name what their unescaped spellings name, and `Phase` is shielded from Owned<Phase>.
import StateMachine

/// A type at file scope that Owned's generic parameter would capture.
struct Phase: Sendable {}

@StateMachine(mode: .shared)
nonisolated enum `Flow`: Sendable {
    typealias `Unit` = Swift.Void
    struct `Idle`: Sendable {}
    struct Running: Sendable {}
    @Initial case `idle`(`Idle`)
    case running(Self.`Running`)
    enum `Input`: Sendable { case `use`(`Phase`), go, stop }
    @Operation(activeIn: [`Running`.self])
    enum `Load` { typealias Output = `Unit` }
    @Transition(on: Input.`use`)
    fileprivate static func `use`(_ source: `Idle`, _ value: `Phase`) -> Idle { source }
    @Transition(on: Input.go, starts: [`Load`.self])
    fileprivate static func go(_ source: Idle) -> Change<`Running`, Effect.`Go`> { Change(Running(), effects: [.load]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
}
func use(_ owned: consuming Flow.Owned<Flow.Idle>) -> Flow.Owned<Flow.Idle> { owned.use(Phase()) }
