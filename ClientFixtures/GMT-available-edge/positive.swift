// A schema available from macOS 14 compiles for a macOS 13 client: its generated members are inside it, so
// they share its availability, and so do the payload and helper types it declares.
import StateMachine

@available(macOS 14, *)
struct Detail: Sendable { let value: Int }

@available(macOS 14, *)
@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    @available(macOS 14, *)
    struct Idle: Sendable {}
    struct Loading: Sendable { let detail: Detail }
    @Initial case idle(Idle)
    case loading(Loading)
    enum Input: Sendable { case go(Detail) }
    @Operation(activeIn: [Loading.self])
    enum Load { typealias Input = Detail; typealias Output = Void }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ detail: Detail) -> Change<Loading, Effect.Go> {
        Change(Loading(detail: detail), effects: [.load(detail)])
    }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Loading) -> Idle { Idle() }
    @Restoration
    fileprivate static func restore(_ saved: Detail) -> Restoration { .idle(Idle()) }
}

func start() {
    if #available(macOS 14, *) {
        let flow = Flow.Shared(Flow.Idle(), drivers: .init(load: { _ in }))
        _ = try? flow.send(.go(Detail(value: 1)))
        _ = Flow.graph
    }
}
