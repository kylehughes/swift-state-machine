import StateMachine
import Testing

/// An emission is published in its acceptance's batch, in authored order among the starts, and
/// carries no authority.
@Suite struct RuntimeEmissionTests {
    private typealias Core = RuntimeState<Int, String>
    private let scope = RuntimeScopeID(kind: 1)

    /// Spells each command so a whole batch compares at once.
    private func spelled(_ batch: Core.Batch) -> [String] {
        batch.commands.map { command in
            switch command {
            case .cancel: "cancel"
            case .start(let work): "start \(work.descriptor)"
            case .emit(let descriptor): "emit \(descriptor)"
            }
        }
    }

    private func commit(_ state: inout Core, model: Int, plan: Core.Plan) throws -> Core.Admission {
        state.commit(try Core.prepare(on: state.snapshot, next: model, plan: plan))
    }

    @Test func emissionsKeepTheirPlaceAmongStartsAfterCancellations() throws {
        var state = Core(0, scopes: [scope], limits: try Limits())
        let operation = RuntimeOperation(kind: 1, scope: scope, policy: .parallel(4))
        _ = try commit(&state, model: 1, plan: .init(starts: [.init(operation, descriptor: "first")]))
        _ = state.drain(limit: 1)
        // Revoking the first start's scope cancels it ahead of everything this plan authored.
        let plan = Core.Plan(
            scopes: [.activate(scope)],
            starts: [.init(operation, descriptor: "a"), .init(operation, descriptor: "b")],
            emissions: [.init("before", position: 0), .init("between", position: 1), .init("after", position: 2)]
        )
        guard case .committed = try commit(&state, model: 2, plan: plan) else {
            Issue.record("Expected acceptance")
            return
        }
        let batch = try #require(state.drain(limit: 1).first)
        #expect(spelled(batch) == ["cancel", "emit before", "start a", "emit between", "start b", "emit after"])
    }

    @Test func anEmissionAloneQueuesABatchForAManualOwner() throws {
        var state = Core(0, limits: try Limits(), recording: .commands)
        _ = try commit(&state, model: 1, plan: .init())
        #expect(!state.hasQueuedBatches)
        _ = try commit(&state, model: 2, plan: .init(emissions: [.init("tracked", position: 0)]))
        let batch = try #require(state.drain(limit: 2).first)
        #expect(batch.snapshot.model == 2)
        #expect(spelled(batch) == ["emit tracked"])
        // The terminal batch cancels work only; emissions belong to the acceptance that authored them.
        _ = state.close()
        #expect(state.drain(limit: 1).map(spelled) == [[]])
    }

    @Test func emissionsCountTowardThePlanDescriptorLimit() throws {
        let state = Core(0, scopes: [scope], limits: try Limits(descriptors: 2))
        let operation = RuntimeOperation(kind: 1, scope: scope, policy: .parallel(4))
        let plan = Core.Plan(
            starts: [.init(operation, descriptor: "a")],
            emissions: [.init("one", position: 1), .init("two", position: 1)]
        )
        #expect(throws: PlanRejection.planTooLarge) {
            try Core.prepare(on: state.snapshot, next: 1, plan: plan)
        }
    }

    @Test func emissionPositionsMustFollowTheirStarts() throws {
        let state = Core(0, limits: try Limits())
        for emissions: [Core.Emission] in [
            [.init("past the end", position: 1)],
            [.init("negative", position: -1)],
            [.init("later", position: 0), .init("earlier", position: -1)],
        ] {
            #expect(throws: PlanRejection.invalidPlan) {
                try Core.prepare(on: state.snapshot, next: 1, plan: .init(emissions: emissions))
            }
        }
    }

    @Test func aRejectedPlanPublishesNoEmission() throws {
        var state = Core(0, limits: try Limits(), recording: .commands)
        let stale = state.snapshot
        _ = try commit(&state, model: 1, plan: .init())
        let candidate = try Core.prepare(on: stale, next: 2, plan: .init(emissions: [.init("lost", position: 0)]))
        guard case .rejected(.conflict, _) = state.commit(candidate) else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(!state.hasQueuedBatches)
    }
}
