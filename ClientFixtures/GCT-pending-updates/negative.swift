// A manual owner's caller reads its retained completions instead.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Screening: Sendable {
    struct Ready: Sendable {}
    @Initial case ready(Ready)
    enum Input: Sendable { case check(Int) }
    enum Refusal: Error, Sendable { case negative }
    @Operation(activeIn: [Ready.self])
    enum Check {
        typealias Input = Int
        typealias Output = Int
    }
    @Transition(on: Input.check, starts: [Check.self])
    fileprivate static func check(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Check> {
        Change(source, effects: [.check(value)])
    }
    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Ready {
        guard value >= 0 else { throw .negative }
        return source
    }
}

nonisolated func updates(_ local: borrowing Screening.Local) {
    _ = local.pendingCompletionUpdates()
}
