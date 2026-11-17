import StateMachine
import StateMachineSchema

@StateMachine(mode: .shared)
nonisolated public enum Flow: Sendable {
    public struct Idle: Sendable { let attempts: Int }
    public struct Loading: Sendable { let request: Int }
    public struct Loaded: Sendable { let value: String }
    public struct Failed: Sendable { let reason: Problem }
    @Initial case idle(Idle)
    case loading(Loading)
    case loaded(Loaded)
    case failed(Failed)
    public enum Problem: Error, Sendable { case negative, offline }
    enum Scope { case load, session }
    public enum Input: Sendable { case load(Int), cancel, sessionChanged, note(String), tick(Bool) }
    @Operation(scope: Scope.load, requires: [Scope.session], activeIn: [Loading.self], admission: .latest)
    public enum Fetch {
        public typealias Input = Int
        public typealias Output = String
        public typealias Failure = Problem
    }
    @Operation(scope: Scope.load, requires: [Scope.session], activeIn: [Loading.self], admission: .parallel(limit: 2))
    public enum Audit {
        public typealias Input = String
        public typealias Output = Int
        public typealias Failure = Never
    }
    @Restoration
    fileprivate static func restore(_ saved: Int) throws(Problem) -> Restoration {
        guard saved >= 0 else { throw .negative }
        return saved == 0 ? .idle(Idle(attempts: 0)) : .loaded(Loaded(value: String(saved)))
    }
    @Transition(on: Input.load, invalidates: [Scope.load], starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ request: Int) throws(Problem) -> Change<Loading, Effect.Begin> {
        guard request >= 0 else { throw .negative }
        return Change(Loading(request: request), effects: [.fetch(request)])
    }
    @Transition(on: Input.cancel, invalidates: [Scope.load])
    fileprivate static func cancel(_ source: Loading) -> Idle {
        Idle(attempts: source.request)
    }
    @Transition(on: Input.sessionChanged, invalidates: [Scope.session])
    fileprivate static func sessionChanged(_ source: Loading) -> Loading {
        source
    }
    @Transition(on: Input.note, starts: [Audit.self])
    fileprivate static func note(_ source: Loading, _ text: String) -> Change<Loading, Effect.Note> {
        Change(source, effects: [.audit(text)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ value: Fetch.Output) -> Loaded {
        Loaded(value: value)
    }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Loading, _ reason: Fetch.Failure) -> Failed {
        Failed(reason: reason)
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Loading, _ count: Audit.Output) -> Loading {
        source
    }
    @Transition(on: Input.tick)
    fileprivate static func restart(_ source: Loaded, _ again: Bool) -> Idle {
        Idle(attempts: 0)
    }
    @Transition(on: Input.tick)
    fileprivate static func keep(_ source: Loaded, _ again: Bool) -> Loaded {
        source
    }
    @Route(on: Input.tick)
    fileprivate static func choose(_ source: Loaded, _ again: Bool) throws(Problem) -> Route.Choose {
        guard source.value != "offline" else { throw .offline }
        return again ? .restart : .keep
    }
}
