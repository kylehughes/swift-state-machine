import StateMachine
import StateMachineSchema
import Testing

@StateMachine(mode: .shared, initial: "idle", scopes: ["work"])
nonisolated enum PlanFlow: Sendable {
    struct Idle: Sendable { let value: Int }
    case idle(Idle)
    enum Input: Sendable {
        case run(Int)
        case forbidden
    }
    enum Effect: Sendable {
        case a(A.Input)
        case b(B.Input)
    }
    enum Rejection: Error { case negative }
    @Operation(effect: "a", scope: "work", activeIn: ["idle"], admission: .latest)
    enum A {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(effect: "b", scope: "work", activeIn: ["idle"], admission: .parallel(limit: 2))
    enum B {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    @Transition(from: "idle", to: "idle", on: .input("run"), starts: ["a", "b"])
    fileprivate static func run(_ source: borrowing Idle, _ count: Int) throws(Rejection) -> Change<Idle, Effect> {
        guard count >= 0 else { throw .negative }
        if count == 3 { return Change(copy source, effects: [.b("one"), .b("two"), .b("three")]) }
        return Change(copy source, effects: count == 2 ? [.a(1), .a(2)] : [.b("first"), .a(1)])
    }
    @Transition(from: "idle", to: "idle", on: .input("forbidden"))
    fileprivate static func forbidden(_ source: borrowing Idle) -> Change<Idle, Effect> {
        Change(copy source, effects: [.a(1)])
    }
    @Transition(from: "idle", to: "idle", on: .success("a"))
    fileprivate static func receivedA(_ source: borrowing Idle, _ value: A.Output) -> Change<Idle, Effect> {
        Change(copy source)
    }
    @Transition(from: "idle", to: "idle", on: .success("b"))
    fileprivate static func receivedB(_ source: borrowing Idle, _ value: B.Output) -> Change<Idle, Effect> {
        Change(copy source)
    }
}

@Suite struct PlanTests {
    private enum Failure: Error { case unexpected }
    @Test func validatesActualEffectsBeforeCreatingPreparedAndPreservesArrayOrder() throws {
        var owner = PlanFlow.Local(.init(value: 0))
        guard case .idle(let idle) = owner.snapshot() else { throw Failure.unexpected }
        do {
            _ = try idle.forbidden()
            Issue.record("undeclared actual effect accepted")
        } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
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
