// Resetting names the initial payload unless the initial phase declares a default.
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
@StateMachine(mode: .shared)
nonisolated enum Defaulted: Sendable {
    struct Ready: Sendable {}
    @Initial case ready(Ready = Ready())
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

nonisolated func reset(_ local: inout Screening.Local, _ defaulted: inout Defaulted.Local) throws(CommitRejection) {
    try local.reset(to: Screening.Ready())
    try defaulted.reset()
}
