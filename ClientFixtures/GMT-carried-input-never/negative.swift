// A file-scope Void that names Never: the carried input could never be constructed, which a check reports.
import StateMachine

typealias Void = Swift::Never

@StateMachine(mode: .shared)
nonisolated enum Upload: Sendable {
    nonisolated struct Idle: Sendable {}
    nonisolated struct Sending: Sendable {}
    @Initial case idle(Idle)
    case sending(Sending)
    enum Input: Sendable { case send }
    @Operation(activeIn: [Sending.self])
    enum Transfer { typealias Input = Void }
    @Event enum Started {}
    @Transition(on: Input.send, starts: [Transfer.self], emits: [Started.self])
    fileprivate static func send(_ source: Idle) -> Change<Sending, Effect.Send> { Change(Sending(), effects: [.started]) }
    @Transition(onSuccess: Transfer.self)
    fileprivate static func sent(_ source: Sending, request: TransferRequest) -> Idle { Idle() }
}
