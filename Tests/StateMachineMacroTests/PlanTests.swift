import StateMachine
import StateMachineSchema
import Testing

@StateMachine(mode: .shared)
nonisolated enum PlanFlow: Sendable {
    struct Idle: Sendable { let value: Int }
    @Initial case idle(Idle)
    enum Scope { case work }
    enum Input: Sendable {
        case run(Int)
    }
    enum Rejection: Error { case negative }
    @Operation(scope: Scope.work, activeIn: [Idle.self], admission: .latest)
    enum A {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(scope: Scope.work, activeIn: [Idle.self], admission: .parallel(limit: 2))
    enum B {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    @Transition(on: Input.run, starts: [A.self, B.self])
    fileprivate static func run(_ source: Idle, _ count: Int) throws(Rejection) -> Change<Idle, Effect.Run> {
        guard count >= 0 else { throw .negative }
        if count == 3 { return Change(source, effects: [.b("one"), .b("two"), .b("three")]) }
        return Change(source, effects: count == 2 ? [.a(1), .a(2)] : [.b("first"), .a(1)])
    }
    @Transition(onSuccess: A.self)
    fileprivate static func receivedA(_ source: Idle, _ value: A.Output) -> Idle {
        source
    }
    @Transition(onSuccess: B.self)
    fileprivate static func receivedB(_ source: Idle, _ value: B.Output) -> Idle {
        source
    }
}

@Suite struct PlanTests {
    private enum Failure: Error { case unexpected }
    @Test func validatesEffectMultiplicityBeforeCreatingPreparedAndPreservesArrayOrder() throws {
        var owner = PlanFlow.Local(.init(value: 0))
        guard case .idle(let idle) = owner.snapshot() else { throw Failure.unexpected }
        do {
            _ = try idle.run(2)
            Issue.record("duplicate latest accepted")
        } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
        do {
            _ = try idle.run(3)
            Issue.record("Oversized parallel group accepted")
        } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
        guard case .rejected(.run(.negative)) = PlanFlow.prepare(.run(-1), on: owner.snapshot()) else {
            throw Failure.unexpected
        }
        guard case .committed = owner.commit(try idle.run(1)), let batch = owner.drainCommands(limit: 1).first else {
            throw Failure.unexpected
        }
        #expect(batch.commands.count == 2)
        guard case .b(let b) = batch.commands[0], case .a(let a) = batch.commands[1] else { throw Failure.unexpected }
        #expect(b.input == "first")
        #expect(a.input == 1)
    }
    @Test func rejectsPermanentPlanSizeBeforePreparedExists() throws {
        let owner = PlanFlow.Local(.init(value: 0), configuration: try RuntimeLimits(descriptors: 1))
        guard case .idle(let idle) = owner.snapshot() else { throw Failure.unexpected }
        do {
            _ = try idle.run(1)
            Issue.record("oversized plan accepted")
        } catch { guard case .plan(.planTooLarge) = error else { throw Failure.unexpected } }
    }
}
