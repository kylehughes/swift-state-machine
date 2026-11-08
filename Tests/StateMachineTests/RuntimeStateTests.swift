import StateMachine
import Testing

@Suite struct RuntimeStateTests {
    private typealias Core = RuntimeState<Int, String>
    private let a = RuntimeScopeID(kind: 1)
    private let b = RuntimeScopeID(kind: 2)

    private func engine(limits: RuntimeLimits? = nil) throws -> Core {
        Core(0, scopes: [a, b], limits: try limits ?? RuntimeLimits())
    }

    @discardableResult
    private func accept(_ state: inout Core, model: Int, plan: Core.Plan = .init()) throws -> Core.Snapshot {
        let candidate = try Core.prepare(on: state.snapshot, next: model, plan: plan)
        let result = state.commit(candidate)
        let accepted: Core.Snapshot?
        if case .committed(let snapshot) = result { accepted = snapshot } else { accepted = nil }
        return try #require(accepted)
    }

    private func works(_ batches: [Core.Batch]) -> [RuntimeWork<String>] {
        batches.flatMap { batch in
            batch.commands.compactMap { command in
                if case .start(let work) = command { return work }
                return nil
            }
        }
    }

    private func reject(_ result: Core.Admission, as expected: Core.Rejection, model: Int, ordinal: UInt64) {
        guard case .rejected(let reason, let current) = result else {
            Issue.record("Expected rejection")
            return
        }
        #expect(reason == expected)
        #expect(current.model == model)
        #expect(current.ordinal == ordinal)
    }

    @Test func latestRevokesOldAuthorityAndPreservesAuthoredStartOrder() throws {
        var state = try engine()
        let latest = RuntimeOperation(kind: 1, scope: a)
        try accept(&state, model: 1, plan: .init(starts: [.init(latest, descriptor: "old")]))
        let old = try #require(works(state.drain(limit: 1)).first)
        #expect(state.executionReservations.first?.execution == .issued)
        try accept(
            &state,
            model: 2,
            plan: .init(starts: [
                .init(latest, descriptor: "replacement"),
                .init(.init(kind: 2, scope: b), descriptor: "second"),
            ])
        )
        let batch = try #require(state.drain(limit: 1).first)
        #expect(batch.commands.count == 3)
        guard case .cancel(let canceled) = batch.commands.first else {
            Issue.record("Expected cancellation before authored starts")
            return
        }
        #expect(canceled == old.ticket)
        #expect(works([batch]).map(\.descriptor) == ["replacement", "second"])
        #expect(!state.isActive(old.ticket))
        #expect(works([batch]).allSatisfy { state.isActive($0.ticket) })
        #expect(state.executionReservations.count == 3)
    }

    @Test func exclusivePolicyRejectsAllProspectiveChangesAtomically() throws {
        var state = try engine()
        let exclusive = RuntimeOperation(kind: 2, scope: b, policy: .rejectWhenActive)
        try accept(
            &state,
            model: 1,
            plan: .init(starts: [
                .init(.init(kind: 1, scope: a), descriptor: "unrelated"),
                .init(exclusive, descriptor: "exclusive"),
            ])
        )
        let originals = works(state.drain(limit: 1))
        let candidate = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(
                scopes: [.activate(a)],
                starts: [.init(exclusive, descriptor: "blocked")]
            )
        )
        reject(state.commit(candidate), as: .operationPolicy(.alreadyActive), model: 1, ordinal: 1)
        #expect(originals.allSatisfy { state.isActive($0.ticket) })
        #expect(state.executionReservations.count == 2)
        #expect(!state.hasQueuedBatches)
        // Rejection must also leave the unrelated scope activation intact.
        let proof = try Core.prepare(on: state.snapshot, next: 2, requiring: originals.map(\.ticket))
        guard case .committed = state.commit(proof) else {
            Issue.record("Rejected policy changed original authority")
            return
        }
    }

    @Test func parallelPolicyCountsProspectiveStartsAndIndependentActivations() throws {
        let first = RuntimeScopeID(kind: 7, instance: RuntimeIdentity())
        let second = RuntimeScopeID(kind: 7, instance: RuntimeIdentity())
        var state = Core(0, scopes: [first, second], limits: try .init())
        let firstOperation = RuntimeOperation(kind: 3, scope: first, policy: .parallel(1))
        let secondOperation = RuntimeOperation(kind: 3, scope: second, policy: .parallel(1))
        try accept(
            &state,
            model: 1,
            plan: .init(starts: [
                .init(firstOperation, descriptor: "first instance"),
                .init(secondOperation, descriptor: "second instance"),
            ])
        )
        let originals = works(state.drain(limit: 1))
        let blocked = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(firstOperation, descriptor: "too many")
            ])
        )
        reject(state.commit(blocked), as: .operationPolicy(.parallelLimit), model: 1, ordinal: 1)
        #expect(originals.allSatisfy { state.isActive($0.ticket) })
        try accept(
            &state,
            model: 2,
            plan: .init(
                scopes: [.activate(first)],
                starts: [
                    .init(firstOperation, descriptor: "fresh activation")
                ]
            )
        )
        #expect(!state.isActive(originals[0].ticket))
        #expect(state.isActive(originals[1].ticket))
        let replacement = works(state.drain(limit: 1))
        #expect(replacement.map(\.descriptor) == ["fresh activation"])

        var empty = try engine()
        let parallel = RuntimeOperation(kind: 4, scope: a, policy: .parallel(2))
        let tooMany = try Core.prepare(
            on: empty.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(parallel, descriptor: "one"), .init(parallel, descriptor: "two"),
                .init(parallel, descriptor: "three"),
            ])
        )
        reject(empty.commit(tooMany), as: .operationPolicy(.parallelLimit), model: 0, ordinal: 0)
        #expect(empty.executionReservations.isEmpty)
        #expect(!empty.hasQueuedBatches)
        try accept(
            &empty,
            model: 1,
            plan: .init(starts: [
                .init(parallel, descriptor: "one"), .init(parallel, descriptor: "two"),
            ])
        )
        let activePair = works(empty.drain(limit: 1))
        let third = try Core.prepare(
            on: empty.snapshot,
            next: 99,
            plan: .init(
                scopes: [.activate(b)],
                starts: [.init(parallel, descriptor: "third")]
            )
        )
        reject(empty.commit(third), as: .operationPolicy(.parallelLimit), model: 1, ordinal: 1)
        #expect(activePair.allSatisfy { empty.isActive($0.ticket) })
        #expect(empty.executionReservations.count == 2)
        #expect(!empty.hasQueuedBatches)
    }

    @Test func dynamicKeyRemovalAndEqualReinsertionInvalidateOldDependentTicket() throws {
        let key = RuntimeScopeID(kind: 8, instance: RuntimeIdentity())
        var state = Core(7, scopes: [a, key], limits: try .init())
        let operation = RuntimeOperation(kind: 1, scope: a, dependencies: [key])
        try accept(&state, model: 7, plan: .init(starts: [.init(operation, descriptor: "old")]))
        let old = try #require(works(state.drain(limit: 1)).first)
        let retained = state.snapshot
        let oldProof = try Core.prepare(on: retained, next: 99, requiring: [old.ticket])
        try accept(&state, model: 7, plan: .init(scopes: [.remove(key)]))
        try accept(
            &state,
            model: 7,
            plan: .init(
                scopes: [.activate(key)],
                starts: [
                    .init(operation, descriptor: "reinserted")
                ]
            )
        )
        #expect(state.snapshot.model == retained.model)
        #expect(!state.isActive(old.ticket))
        reject(state.commit(oldProof), as: .inactiveAuthority, model: 7, ordinal: 3)
        let replacement = try #require(works(state.drain(limit: 10)).first)
        #expect(replacement.ticket != old.ticket)
        #expect(state.isActive(replacement.ticket))
        #expect(replacement.descriptor == "reinserted")
    }

    @Test func permanentPlanSizeAndTemporalRejectionPrecedenceRemainDistinct() throws {
        var state = try engine(limits: .init(commits: 1, descriptors: 1, executions: 1))
        let exclusive = RuntimeOperation(kind: 1, scope: a, policy: .rejectWhenActive)
        do {
            _ = try Core.prepare(
                on: state.snapshot,
                next: 99,
                plan: .init(starts: [
                    .init(exclusive, descriptor: "one"),
                    .init(.init(kind: 2, scope: b), descriptor: "two"),
                ])
            )
            Issue.record("Oversized plan was prepared")
        } catch {
            guard case .planTooLarge = error else {
                Issue.record("Oversized plan had wrong permanent rejection")
                return
            }
        }
        #expect(state.snapshot.ordinal == 0)
        #expect(state.executionReservations.isEmpty)
        try accept(&state, model: 1, plan: .init(starts: [.init(exclusive, descriptor: "active")]))
        let work = try #require(works(state.drain(limit: 1)).first)
        let stale = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(exclusive, descriptor: "stale")
            ])
        )
        try accept(&state, model: 2)
        reject(state.commit(stale), as: .conflict, model: 2, ordinal: 2)
        let policy = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(exclusive, descriptor: "policy")
            ])
        )
        reject(state.commit(policy), as: .operationPolicy(.alreadyActive), model: 2, ordinal: 2)
        let capacity = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(.init(kind: 2, scope: b), descriptor: "capacity")
            ])
        )
        reject(state.commit(capacity), as: .capacityExceeded(.commitQueue), model: 2, ordinal: 2)
        #expect(state.drain(limit: 1).map(\.snapshot.ordinal) == [2])
        reject(state.commit(capacity), as: .capacityExceeded(.executionReservations), model: 2, ordinal: 2)
        #expect(state.acknowledge(work.ticket) == .recorded)
        #expect(state.executionReservations.first?.execution == .terminated)
        #expect(state.executionReservations.first?.delivery == .awaitingOutcome)
        // Physical termination alone cannot dispose an unconsumed outcome.
        reject(state.commit(capacity), as: .capacityExceeded(.executionReservations), model: 2, ordinal: 2)
        #expect(state.isActive(work.ticket))
        #expect(!state.hasQueuedBatches)
    }

    @Test func latestCapacityRejectionDoesNotPublishProspectiveRevocation() throws {
        var state = try engine(limits: .init(executions: 1))
        let operation = RuntimeOperation(kind: 1, scope: a)
        try accept(&state, model: 1, plan: .init(starts: [.init(operation, descriptor: "old")]))
        let old = try #require(works(state.drain(limit: 1)).first)
        let next = try Core.prepare(
            on: state.snapshot,
            next: 2,
            plan: .init(starts: [
                .init(operation, descriptor: "new")
            ])
        )
        reject(state.commit(next), as: .capacityExceeded(.executionReservations), model: 1, ordinal: 1)
        #expect(state.isActive(old.ticket))
        #expect(!state.hasQueuedBatches)
        #expect(state.acknowledge(old.ticket) == .recorded)
        guard case .committed = state.commit(next) else {
            Issue.record("Terminated predecessor did not free its prospective retired reservation")
            return
        }
        #expect(!state.isActive(old.ticket))
        #expect(state.executionReservations.count == 1)
        #expect(works(state.drain(limit: 1)).map(\.descriptor) == ["new"])
    }

    @Test func ownFinishedDeliveryClaimCanRetireAndStartSuccessorAtCapacityOne() throws {
        var state = try engine(limits: .init(executions: 1))
        let operation = RuntimeOperation(kind: 1, scope: a)
        try accept(&state, model: 1, plan: .init(starts: [.init(operation, descriptor: "old")]))
        let old = try #require(works(state.drain(limit: 1)).first)
        #expect(state.acknowledge(old.ticket) == .recorded)
        guard case .retained = state.retainOutcome(for: old.ticket) else {
            Issue.record("First outcome was not retained")
            return
        }
        let acquiredClaim = state.claimDelivery(for: old.ticket)
        let claim = try #require(acquiredClaim)
        #expect(state.claimDelivery(for: old.ticket) == nil)
        let terminal = try Core.prepare(
            on: state.snapshot,
            next: 2,
            requiring: [old.ticket],
            plan: .init(
                retire: [old.ticket],
                starts: [.init(operation, descriptor: "successor")],
                finishingClaims: [claim]
            )
        )
        guard case .committed = state.commit(terminal) else {
            Issue.record("Completed claim self-blocked capacity-one successor")
            return
        }
        #expect(!state.isActive(old.ticket))
        #expect(state.executionReservations.count == 1)
        #expect(state.executionReservations.first?.isPreparing == false)
        state.finishDeliveryClaim(claim)
        let successor = try #require(works(state.drain(limit: 1)).first)
        #expect(successor.descriptor == "successor")
        #expect(state.isActive(successor.ticket))
        #expect(state.executionReservations.first?.ticket == successor.ticket)
    }

    @Test func pendingClaimHoldsTerminatedReservationThroughCloseUntilAttemptExits() throws {
        var state = try engine(limits: .init(executions: 1))
        try accept(
            &state,
            model: 1,
            plan: .init(starts: [
                .init(.init(kind: 1, scope: a), descriptor: "pending")
            ])
        )
        let work = try #require(works(state.drain(limit: 1)).first)
        guard case .retained = state.retainOutcome(for: work.ticket) else {
            Issue.record("First outcome was not retained")
            return
        }
        guard case .duplicate = state.retainOutcome(for: work.ticket) else {
            Issue.record("Duplicate outcome replaced first retention")
            return
        }
        let acquiredClaim = state.claimDelivery(for: work.ticket)
        let claim = try #require(acquiredClaim)
        #expect(state.claimDelivery(for: work.ticket) == nil)
        #expect(state.acknowledge(work.ticket) == .recorded)
        #expect(state.executionReservations.first?.isPreparing == true)
        let closed = state.close()
        #expect(closed.ordinal == 2)
        #expect(state.executionReservations.first?.delivery == .settled)
        #expect(state.executionReservations.first?.execution == .terminated)
        #expect(state.executionReservations.first?.isPreparing == true)
        #expect(!state.isActive(work.ticket))
        #expect(state.drain(limit: 10).map(\.terminal) == [true])
        #expect(!state.isQuiescent)
        state.finishDeliveryClaim(claim)
        #expect(state.executionReservations.isEmpty)
        #expect(state.isQuiescent)
        state.finishDeliveryClaim(claim)
        #expect(state.isQuiescent)
    }
}
