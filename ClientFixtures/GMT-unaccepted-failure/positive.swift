import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Upload: Sendable {
    struct Idle: Sendable {}
    struct Sending: Sendable {}
    @Initial case idle(Idle)
    case sending(Sending)
    enum Input: Sendable { case send }
    enum Problem: Error, Sendable { case offline }
    @Operation(activeIn: [Sending.self])
    enum Transfer { typealias Failure = Problem }
    @Transition(on: Input.send, starts: [Transfer.self])
    fileprivate static func send(_ source: Idle) -> Change<Sending, Effect.Send> { Change(Sending(), effects: [.transfer]) }
    @Transition(onSuccess: Transfer.self)
    fileprivate static func sent(_ source: Sending) -> Idle { Idle() }
    @Transition(onFailure: Transfer.self)
    fileprivate static func failed(_ source: Sending, _ failure: Problem) -> Idle { Idle() }
}
