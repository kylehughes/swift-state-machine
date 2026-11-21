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
        #expect(coverage.unexercisedRejectingRoutes.map(\.id) == ["pending.refuse"])
        var paid = ManualMachineTest(Payment.Local())
        try paid.send(.pay)
        coverage.record(paid)
        try coverage.requireCoverage()
        #expect(coverage.unexercisedRejectingRoutes.map(\.id) == ["pending.refuse"])

        var refused = ManualMachineTest(Payment.Local())
        _ = try refused.rejection(of: .refund)
        let rejection = try #require(refused.rejections.first)
        #expect(refused.rejections.count == 1)
        #expect(rejection.phase == "pending")
        #expect(rejection.snapshot.revision == 0)
        coverage.record(refused)
        let named = rejection.route == "pending.refuse"
        #expect(named || rejection.route == nil)
        #expect(coverage.unexercisedRejectingRoutes.map(\.id) == (named ? [] : ["pending.refuse"]))
        #expect(coverage.rejectingRouteIDs == (named ? ["pending.refuse"] : []))
    }

    // A router that chooses between edges and declines while locked: a failed `send` records the
    // rejection the real owner returned, from the phase it held.
    @Test func aFailedSendRecordsTheOwnersRejection() {
        var test = ManualMachineTest(GeneratedRetry.Local(GeneratedRetry.Waiting(attempts: 1, locked: true)))
        #expect(throws: StateMachineTestFailure.self) { try test.send(.retry) }
        #expect(test.rejections.map(\.phase) == ["waiting"])
        #expect(test.rejections.allSatisfy { $0.route == nil || $0.route == "waiting.decide" })
        #expect(test.history.count == 1)
    }
}
