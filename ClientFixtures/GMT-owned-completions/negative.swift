// A `Local` owner holds one ticket for the one execution `send` starts, and its completion retires
// it, so `confirmed` can never fire: `Done` is unreachable.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Upload: Sendable {
    struct Ready: Sendable {}
    struct Sending: Sendable {}
    struct Confirming: Sendable {}
    struct Done: Sendable {}
    @Initial case ready(Ready)
    case sending(Sending)
    case confirming(Confirming)
    @Terminal case done(Done)
    enum Input: Sendable { case send }
    @Operation(activeIn: [Sending.self, Confirming.self])
    enum Transfer {}
    @Transition(on: Input.send, starts: [Transfer.self])
    fileprivate static func send(_ source: Ready) -> Change<Sending, Effect.Send> {
        Change(Sending(), effects: [.transfer])
    }
    @Transition(onSuccess: Transfer.self)
    fileprivate static func sent(_ source: Sending) -> Confirming { Confirming() }
    @Transition(onSuccess: Transfer.self)
    fileprivate static func confirmed(_ source: Confirming) -> Done { Done() }
}

func finish(_ upload: consuming Upload.Owned<Upload.Ready>) -> Upload.Owned<Upload.Done> {
    let change = upload.send()
    return change.next.sent().confirmed()
}
