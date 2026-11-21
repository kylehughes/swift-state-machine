// A file-scope Void that names Int: the completion takes the request, so the input is carried, and it has values.
import StateMachine

typealias Void = Swift::Int

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
