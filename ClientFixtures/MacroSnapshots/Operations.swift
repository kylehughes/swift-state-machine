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
    public enum Effect: Sendable {
        case fetch(Fetch.Input)
        case audit(Audit.Input)
    }
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
    @Transition(on: Input.load, invalidates: [Scope.load], starts: [Fetch.self])
    fileprivate static func begin(_ source: borrowing Idle, _ request: Int) throws(Problem) -> Change<Loading, Effect> {
        guard request >= 0 else { throw .negative }
        return Change(Loading(request: request), effects: [.fetch(request)])
    }
    @Transition(on: Input.cancel, invalidates: [Scope.load])
    fileprivate static func cancel(_ source: borrowing Loading) -> Change<Idle, Effect> {
        Change(Idle(attempts: source.request))
    }
    @Transition(on: Input.sessionChanged, invalidates: [Scope.session])
    fileprivate static func sessionChanged(_ source: borrowing Loading) -> Change<Loading, Effect> {
        Change(copy source)
    }
    @Transition(on: Input.note, starts: [Audit.self])
    fileprivate static func note(_ source: borrowing Loading, _ text: String) -> Change<Loading, Effect> {
        Change(copy source, effects: [.audit(text)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: borrowing Loading, _ value: Fetch.Output) -> Change<Loaded, Effect> {
        Change(Loaded(value: value))
    }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: borrowing Loading, _ reason: Fetch.Failure) -> Change<Failed, Effect> {
        Change(Failed(reason: reason))
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: borrowing Loading, _ count: Audit.Output) -> Change<Loading, Effect> {
        Change(copy source)
    }
    @Transition(on: Input.tick)
    fileprivate static func restart(_ source: borrowing Loaded, _ again: Bool) -> Change<Idle, Effect> {
        Change(Idle(attempts: 0))
    }
    @Transition(on: Input.tick)
    fileprivate static func keep(_ source: borrowing Loaded, _ again: Bool) -> Change<Loaded, Effect> {
        Change(copy source)
    }
    @Route(on: Input.tick)
    fileprivate static func route(_ source: Observed<Loaded>, _ again: Bool) -> PreparationResult {
        do { return .prepared(again ? try source.restart(again) : try source.keep(again)) } catch {
            switch error {
            case .plan(let reason): return .rejected(.plan(reason))
            case .domain(let never): switch never {}
            }
        }
    }
}
