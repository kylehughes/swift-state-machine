import StateMachine
import Testing

@StateMachine(mode: .shared)
nonisolated enum PlanFlow: Sendable {
    struct Idle: Sendable { let value: Int }
    @Initial case idle(Idle)
    enum Scope {
        @Active(in: [Idle.self])
        case work
    }
    enum Input: Sendable {
        case run(Int)
    }
    enum Rejection: Error { case negative }
    @Operation(scope: Scope.work, admission: .latest)
    enum A {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(scope: Scope.work, admission: .parallel(limit: 2))
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

@Suite(.timeLimit(.minutes(1))) struct PlanTests {
    private enum Failure: Error { case unexpected }
    @Test func carriesEffectMultiplicityDefectsToAdmissionAndPreservesArrayOrder() throws {
        var owner = PlanFlow.Local(.init(value: 0))
        guard case .idle(let idle) = owner.snapshot() else { throw Failure.unexpected }
        // Preparing a defective plan does not throw; admission reports it and installs nothing.
        guard case .rejected(.plan(.invalidPlan), let duplicate) = owner.commit(try idle.run(2)) else {
            throw Failure.unexpected
        }
        #expect(duplicate.revision == 0)
        guard case .rejected(.plan(.invalidPlan), _) = owner.commit(try idle.run(3)) else {
            throw Failure.unexpected
        }
        do {
            try owner.send(.run(2))
            Issue.record("duplicate latest accepted through send")
        } catch { guard case .commit(.plan(.invalidPlan)) = error else { throw Failure.unexpected } }
        do {
            _ = try PlanFlow.prepare(.run(-1), on: owner.snapshot())
            Issue.record("negative run prepared")
        } catch { guard case .run(.negative) = error else { throw Failure.unexpected } }
        #expect(owner.drainCommands(limit: 1).isEmpty)
        guard case .committed = owner.commit(try idle.run(1)), let batch = owner.drainCommands(limit: 1).first else {
            throw Failure.unexpected
        }
        #expect(batch.commands.count == 2)
        guard case .b(let b) = batch.commands[0], case .a(let a) = batch.commands[1] else { throw Failure.unexpected }
        #expect(b.input == "first")
        #expect(a.input == 1)
    }
    @Test func managedOwnersReportAPreparedPlanDefectAtAdmission() async throws {
        let shared = PlanFlow.Shared(.init(value: 0), aDriver: { $0 }, bDriver: { $0 })
        guard case .idle(let idle) = shared.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.plan(.invalidPlan), let current) = shared.commit(try idle.run(2)) else {
            throw Failure.unexpected
        }
        #expect(current.revision == 0)
        do {
            try shared.send(.run(2))
            Issue.record("the shared owner admitted a defective plan")
        } catch { guard case .commit(.plan(.invalidPlan)) = error else { throw Failure.unexpected } }
        await shared.shutdown()
        let actor = PlanFlow.ActorHost(.init(value: 0), aDriver: { $0 }, bDriver: { $0 })
        guard case .idle(let observed) = await actor.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.plan(.invalidPlan), _) = await actor.commit(try observed.run(3)) else {
            throw Failure.unexpected
        }
        do {
            try await actor.send(.run(3))
            Issue.record("the actor owner admitted a defective plan")
        } catch { guard case .commit(.plan(.invalidPlan)) = error else { throw Failure.unexpected } }
        #expect(await actor.snapshot().revision == 0)
        await actor.shutdown()
    }
    /// Closure takes precedence over the plan defect it causes.
    ///
    /// `run(1)` is valid on an open `Idle`. Closing removes the scope it starts in, so preparing it
    /// from the closed `Idle` finds a plan defect that only the closure caused.
    @Test func closureAndAnotherOwnerTakePrecedenceOverAPlanDefect() throws {
        var owner = PlanFlow.Local(PlanFlow.Idle(value: 0))
        guard case .idle(let open) = owner.snapshot() else { throw Failure.unexpected }
        owner.close()
        guard case .idle(let closed) = owner.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.closed, let current) = owner.commit(try closed.run(1)) else {
            Issue.record("a closed owner reported the plan defect its closure caused")
            return
        }
        #expect(current.isClosed)
        do {
            try owner.send(.run(1))
            Issue.record("a closed owner admitted an input")
        } catch {
            guard case .commit(.closed) = error else {
                Issue.record("send to a closed owner reported \(error)")
                return
            }
        }
        var other = PlanFlow.Local(PlanFlow.Idle(value: 0))
        guard case .rejected(.foreignOwner, _) = other.commit(try closed.run(1)),
            case .rejected(.foreignOwner, _) = other.commit(try open.run(2))
        else {
            Issue.record("another owner reported a plan defect instead of its provenance")
            return
        }
    }
    @Test func managedOwnersGiveClosurePrecedenceOverAPlanDefect() async throws {
        let shared = PlanFlow.Shared(PlanFlow.Idle(value: 0), aDriver: { $0 }, bDriver: { $0 })
        shared.close()
        guard case .idle(let closed) = shared.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.closed, _) = shared.commit(try closed.run(1)) else {
            Issue.record("a closed shared owner reported a plan defect")
            return
        }
        do {
            try shared.send(.run(1))
            Issue.record("a closed shared owner admitted an input")
        } catch {
            guard case .commit(.closed) = error else {
                Issue.record("send to a closed shared owner reported \(error)")
                return
            }
        }
        await shared.shutdown()
        let actor = PlanFlow.ActorHost(PlanFlow.Idle(value: 0), aDriver: { $0 }, bDriver: { $0 })
        await actor.close()
        guard case .idle(let observed) = await actor.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.closed, _) = await actor.commit(try observed.run(1)) else {
            Issue.record("a closed actor owner reported a plan defect")
            return
        }
        do {
            try await actor.send(.run(1))
            Issue.record("a closed actor owner admitted an input")
        } catch {
            guard case .commit(.closed) = error else {
                Issue.record("send to a closed actor owner reported \(error)")
                return
            }
        }
        await actor.shutdown()
    }
    @Test func reportsPermanentPlanSizeAtAdmission() throws {
        var owner = PlanFlow.Local(.init(value: 0), configuration: try Limits(descriptors: 1))
        guard case .idle(let idle) = owner.snapshot() else { throw Failure.unexpected }
        guard case .rejected(.plan(.planTooLarge), let current) = owner.commit(try idle.run(1)) else {
            throw Failure.unexpected
        }
        #expect(current.revision == 0)
        #expect(owner.drainCommands(limit: 1).isEmpty)
    }
}
