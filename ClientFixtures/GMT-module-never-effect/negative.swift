// A bare Never is read as Swift.Never, so a Never declared outside the schema as an effect type is a compile error, not a transition that starts no work.
import StateMachine

nonisolated enum Never: Swift.Error, Swift.Sendable { case offline }

@StateMachine(mode: .ownedOnly)
nonisolated enum UniqueCounter: ~Copyable {
    struct Idle: ~Copyable { let value: Int }
    struct Done: ~Copyable { let value: Int }
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input { case finish(Bool) }
    enum Rejection: Swift.Error { case declined }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: consuming Idle, _ accept: Bool) -> Advance<Idle, Done, Never, Rejection> {
        if accept { return .advanced(Done(value: source.value), effects: []) }
        return .rejected(.declined, source)
    }
}
