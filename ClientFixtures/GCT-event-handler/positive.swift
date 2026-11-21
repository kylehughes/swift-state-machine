// Every managed owner takes one handler per event.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Visit: Sendable {
    struct Browsing: Sendable {}
    @Initial case browsing(Browsing)
    enum Input: Sendable { case view(String) }
    @Event
    enum Tracked { typealias Payload = String }
    @Transition(on: Input.view, emits: [Tracked.self])
    fileprivate static func view(_ source: Browsing, _ page: String) -> Change<Browsing, Effect.View> {
        Change(source, effects: [.tracked(page)])
    }
}
nonisolated func shared() -> Visit.Shared { Visit.Shared(Visit.Browsing(), onTracked: { _ in }) }
@MainActor func main() -> Visit.MainActorHost { Visit.MainActorHost(Visit.Browsing(), onTracked: { _ in }) }
