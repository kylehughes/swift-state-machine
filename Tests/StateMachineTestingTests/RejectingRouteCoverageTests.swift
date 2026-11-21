import StateMachine
import StateMachineExamples
import StateMachineTesting
import Testing

/// A payment whose refund input reaches a router with no candidate edge, which always declines it.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Payment: Sendable {
    struct Pending: Sendable {}
    struct Paid: Sendable {}
    @Initial case pending(Pending = Pending())
    @Terminal case paid(Paid)
    enum Input: Sendable { case pay, refund }
    enum Refusal: Error, Sendable { case nothingToRefund }
    @Transition(on: Input.pay)
    fileprivate static func settle(_ source: Pending) -> Paid { Paid() }
    @Route(on: Input.refund)
    fileprivate static func refuse(_ source: Pending) throws(Refusal) -> Never { throw .nothingToRefund }
}

@Suite struct RejectingRouteCoverageTests {
    // The router without candidates is listed until a run makes the real owner decline through it, and
    // requiring coverage requires nothing of it.
    @Test func aRouterWithoutCandidatesCountsOnceTheOwnerDeclinesThroughIt() throws {
        var coverage = GraphCoverage(for: Payment.Local.self)
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["pending.refuse"])
        var paid = ManualMachineTest(Payment.Local())
        try paid.send(.pay)
        coverage.record(paid)
        try coverage.requireCoverage()
        #expect(coverage.unexercisedRejectingRouters.map(\.id) == ["pending.refuse"])

        var refused = ManualMachineTest(Payment.Local())
        let reason = try refused.rejection(of: .refund)
        guard case .preparation(.refuse(.nothingToRefund)) = reason else {
            Issue.record("Expected the router's typed refusal, not \(reason)")
            return
        }
        let rejection = try #require(refused.rejections.first)
        #expect(refused.rejections.count == 1)
        #expect(rejection.phase == "pending")
        #expect(rejection.route == "pending.refuse")
        #expect(rejection.snapshot.revision == 0)
        coverage.record(refused)
        #expect(coverage.unexercisedRejectingRouters.isEmpty)
        #expect(coverage.rejectingRouteIDs == ["pending.refuse"])
    }

    // A router that chooses between edges and declines while locked: a failed `send` records the
    // rejection the real owner returned, from the phase it held, with the router the generated owner
    // names for it.
    @Test func aFailedSendRecordsTheOwnersRejection() {
        var test = ManualMachineTest(GeneratedRetry.Local(GeneratedRetry.Waiting(attempts: 1, locked: true)))
        #expect(throws: StateMachineTestFailure.self) { try test.send(.retry) }
        #expect(test.rejections.map(\.phase) == ["waiting"])
        #expect(test.rejections.map(\.route) == ["waiting.decide"])
        #expect(
            test.rejections.allSatisfy { rejection in
                if case .preparation(.decide(.locked)) = rejection.reason { true } else { false }
            }
        )
        #expect(test.history.count == 1)
    }
}
