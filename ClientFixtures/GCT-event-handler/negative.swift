// A managed owner cannot drop an event's handler.
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
nonisolated func shared() -> Visit.Shared { Visit.Shared(Visit.Browsing()) }
