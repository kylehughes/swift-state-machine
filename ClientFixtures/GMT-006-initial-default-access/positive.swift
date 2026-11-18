import StateMachine

@StateMachine(mode: .shared)
nonisolated public enum Lookup: Sendable {
    public struct Idle: Sendable {
        public init() {}
    }
    public struct Done: Sendable {
        public init() {}
    }
    @Initial case idle(Idle = Idle())
    case done(Done)
    public enum Input: Sendable { case finish }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done {
        Done()
    }
}
