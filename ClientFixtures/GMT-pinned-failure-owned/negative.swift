// With only Owned generated, no Observed method checks the candidate; the pinned-failure witness still does.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Picker: Sendable {
    enum Problem: Error { case declined }
    enum Other: Error { case worse }
    struct Idle: Sendable {}
    struct Chosen: Sendable {}
    @Initial case idle(Idle)
    case chosen(Chosen)
    enum Input: Sendable { case pick(Bool), back }
    @Transition(on: Input.pick)
    fileprivate static func left(_ source: Idle, _ value: Bool) throws(Other) -> Chosen { Chosen() }
    @Transition(on: Input.pick)
    fileprivate static func right(_ source: Idle, _ value: Bool) -> Chosen { Chosen() }
    @Route(on: Input.pick, failure: Problem.self)
    fileprivate static func choose(_ source: Idle, _ value: Bool) -> Route.Choose { value ? .left : .right }
    @Transition(on: Input.back)
    fileprivate static func back(_ source: Chosen) -> Idle { Idle() }
}
