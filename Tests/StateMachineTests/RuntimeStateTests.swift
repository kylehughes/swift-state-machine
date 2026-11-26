import StateMachine
import Testing

@Suite struct RuntimeStateTests {
    private typealias Core = RuntimeState<Int, String>
    private let a = RuntimeScopeID(kind: 1)
    private let b = RuntimeScopeID(kind: 2)

    private func engine(limits: Limits? = nil) throws -> Core {
        Core(0, scopes: [a, b], limits: try limits ?? Limits())
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

    private func reject(_ result: Core.Admission, as expected: Core.Rejection, model: Int, revision: UInt64) {
        guard case .rejected(let reason, let current) = result else {
            Issue.record("Expected rejection")
            return
        }
        #expect(reason == expected)
        #expect(current.model == model)
        #expect(current.revision == revision)
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
        guard case .cancel(let cancelled) = batch.commands.first else {
            Issue.record("Expected cancellation before authored starts")
            return
        }
        #expect(cancelled == old.ticket)
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
        reject(state.commit(candidate), as: .operationPolicy(.alreadyActive), model: 1, revision: 1)
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
        reject(state.commit(blocked), as: .operationPolicy(.parallelLimit), model: 1, revision: 1)
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
        reject(empty.commit(tooMany), as: .operationPolicy(.parallelLimit), model: 0, revision: 0)
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
        reject(empty.commit(third), as: .operationPolicy(.parallelLimit), model: 1, revision: 1)
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
        reject(state.commit(oldProof), as: .inactiveAuthority, model: 7, revision: 3)
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
        #expect(state.snapshot.revision == 0)
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
        reject(state.commit(stale), as: .conflict, model: 2, revision: 2)
        let policy = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(exclusive, descriptor: "policy")
            ])
        )
        reject(state.commit(policy), as: .operationPolicy(.alreadyActive), model: 2, revision: 2)
        let capacity = try Core.prepare(
            on: state.snapshot,
            next: 99,
            plan: .init(starts: [
                .init(.init(kind: 2, scope: b), descriptor: "capacity")
            ])
        )
        reject(state.commit(capacity), as: .capacityExceeded(.commitQueue), model: 2, revision: 2)
        #expect(state.drain(limit: 1).map(\.snapshot.revision) == [2])
        reject(state.commit(capacity), as: .capacityExceeded(.executionReservations), model: 2, revision: 2)
        #expect(state.acknowledge(work.ticket) == .recorded)
        #expect(state.executionReservations.first?.execution == .terminated)
        #expect(state.executionReservations.first?.delivery == .awaitingOutcome)
        // Physical termination alone cannot dispose an unconsumed outcome.
        reject(state.commit(capacity), as: .capacityExceeded(.executionReservations), model: 2, revision: 2)
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
        reject(state.commit(next), as: .capacityExceeded(.executionReservations), model: 1, revision: 1)
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
        #expect(closed.revision == 2)
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
    private func keyed(_ key: String, policy: RuntimeOperationPolicy = .latest) -> Core.Start {
        .init(.init(kind: 7, scope: a, policy: policy), descriptor: key, key: RuntimeKey(key))
    }

    @Test func aKeyLeavesTheTableWithItsLastWorkAndReturnsWithAFreshIdentity() throws {
        var state = try engine()
        try accept(&state, model: 1, plan: .init(starts: [keyed("a")]))
        let first = try #require(state.keyIdentity(kind: 7, key: RuntimeKey("a")))
        // Replacing the key's work under `.latest` keeps the key's identity.
        try accept(&state, model: 2, plan: .init(starts: [keyed("a")]))
        #expect(state.keyIdentity(kind: 7, key: RuntimeKey("a")) === first)
        // Cancelling the key's work retires the key, and an absent key cancels nothing.
        try accept(
            &state,
            model: 3,
            plan: .init(cancellations: [.init(kind: 7, key: RuntimeKey("a")), .init(kind: 7, key: RuntimeKey("z"))])
        )
        #expect(state.keyIdentity(kind: 7, key: RuntimeKey("a")) == nil)
        let batches = state.drain(limit: 8)
        #expect(batches.last?.commands.filter { if case .cancel = $0 { true } else { false } }.count == 1)
        try accept(&state, model: 4, plan: .init(starts: [keyed("a")]))
        let second = try #require(state.keyIdentity(kind: 7, key: RuntimeKey("a")))
        #expect(second !== first)
    }

    @Test func aRejectedKeyedPlanLeavesTheKeyTableUnchanged() throws {
        var state = try engine()
        try accept(&state, model: 1, plan: .init(starts: [keyed("a", policy: .rejectWhenActive)]))
        let held = try #require(state.keyIdentity(kind: 7, key: RuntimeKey("a")))
        let candidate = try Core.prepare(
            on: state.snapshot,
            next: 2,
            plan: .init(starts: [keyed("b", policy: .rejectWhenActive), keyed("a", policy: .rejectWhenActive)])
        )
        reject(state.commit(candidate), as: .operationPolicy(.alreadyActive), model: 1, revision: 1)
        #expect(state.keyIdentity(kind: 7, key: RuntimeKey("a")) === held)
        #expect(state.keyIdentity(kind: 7, key: RuntimeKey("b")) == nil)
    }

    @Test func aResetRevokesEveryKeyAndQueuesItsCancellations() throws {
        var state = try engine()
        try accept(&state, model: 1, plan: .init(starts: [keyed("a"), keyed("b")]))
        let issued = works(state.drain(limit: 8))
        let stale = state.snapshot
        guard case .committed(let reset) = state.reset(9, scopes: [a]) else {
            Issue.record("Reset was rejected")
            return
        }
        #expect(reset.revision == 2)
        #expect(reset.model == 9)
        #expect(state.keyIdentity(kind: 7, key: RuntimeKey("a")) == nil)
        #expect(issued.allSatisfy { !state.isActive($0.ticket) })
        let batch = try #require(state.drain(limit: 8).first)
        #expect(batch.commands.count == 2)
        // A candidate prepared before the reset belongs to the earlier incarnation.
        let candidate = try Core.prepare(on: stale, next: 3)
        reject(state.commit(candidate), as: .obsoleteIncarnation, model: 9, revision: 2)
        _ = state.close()
        guard case .rejected(.closed, _) = state.reset(0, scopes: []) else {
            Issue.record("A closed engine was reset")
            return
        }
    }

    private struct LargeSendableModel: Sendable, Equatable {
        var a: Int
        var b: Int
        var c: Int
        var d: Int
        var tag: String
    }

    private final class NonSendablePayload {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    private final class TrackedModel: Sendable {
        let value: Int
        init(_ value: Int) { self.value = value }
    }

    @Test func snapshotAndDeliveryClaimKeepPointerSizedInlineLayoutsAndConditionalSendable() throws {
        let pointerSize = MemoryLayout<AnyObject>.size
        #expect(MemoryLayout<RuntimeState<LargeSendableModel, NonSendablePayload>.Snapshot>.size == pointerSize)
        #expect(MemoryLayout<RuntimeState<LargeSendableModel, NonSendablePayload>.Snapshot?>.size == pointerSize)
        #expect(MemoryLayout<RuntimeDeliveryClaim>.size == pointerSize)
        #expect(MemoryLayout<RuntimeDeliveryClaim?>.size == pointerSize)

        let model = LargeSendableModel(a: 1, b: 2, c: 3, d: 4, tag: "v0")
        let engine = RuntimeState<LargeSendableModel, NonSendablePayload>(model, limits: try .init())
        let sendableSnapshot: any Sendable = engine.snapshot
        let roundTripped = try #require(
            sendableSnapshot as? RuntimeState<LargeSendableModel, NonSendablePayload>.Snapshot
        )
        #expect(roundTripped.model == model)
        #expect(roundTripped.revision == 0)
        #expect(!roundTripped.isClosed)
        #expect(roundTripped.edge == nil)

        var nonSendableEngine = RuntimeState<NonSendablePayload, Int>(NonSendablePayload(7), limits: try .init())
        let candidate = try RuntimeState<NonSendablePayload, Int>
            .prepare(
                on: nonSendableEngine.snapshot,
                next: NonSendablePayload(9),
                plan: .init(edge: "advance")
            )
        guard case .committed(let next) = nonSendableEngine.commit(candidate) else {
            Issue.record("Non-Sendable model commit failed")
            return
        }
        #expect(next.model.value == 9)
        #expect(next.edge == "advance")
    }

    @Test func historicalSnapshotsRemainImmutableAndTicketsOrClaimsDoNotRetainOldModels() throws {
        var engine = RuntimeState<TrackedModel, Int>(TrackedModel(0), scopes: [a], limits: try .init())
        let s0 = engine.snapshot
        weak var m1: TrackedModel?
        let ticket: RuntimeTicket
        let claim: RuntimeDeliveryClaim
        do {
            let model1 = TrackedModel(1)
            m1 = model1
            let start = trackedStart(scope: a)
            let candidate = try RuntimeState<TrackedModel, Int>
                .prepare(
                    on: engine.snapshot,
                    next: model1,
                    plan: .init(starts: [start], edge: "start")
                )
            guard case .committed(let s1) = engine.commit(candidate) else {
                Issue.record("Expected start commit")
                return
            }
            #expect(s1.revision == 1)
            #expect(s1.edge == "start")
            #expect(s1.model.value == 1)
            let batch = try #require(engine.drain(limit: 1).first)
            guard case .start(let work)? = batch.commands.first else {
                Issue.record("Expected drained start work")
                return
            }
            ticket = work.ticket
            guard case .retained = engine.retainOutcome(for: ticket) else {
                Issue.record("Expected outcome retention")
                return
            }
            let claimed = engine.claimDelivery(for: ticket)
            claim = try #require(claimed)
            // Advancing to revision 2 and draining drops every engine reference to revision 1's storage.
            let c2 = try RuntimeState<TrackedModel, Int>
                .prepare(
                    on: engine.snapshot,
                    next: TrackedModel(2),
                    plan: .init(edge: "next")
                )
            guard case .committed(let s2) = engine.commit(c2) else {
                Issue.record("Expected revision 2 commit")
                return
            }
            #expect(s2.revision == 2)
            #expect(s2.edge == "next")
            _ = engine.drain(limit: 1)
            // s1 is still in scope here so m1 stays alive until the block exits.
            #expect(m1 != nil)
        }
        // Neither the active ticket nor its live delivery claim keeps revision 1's model alive.
        #expect(m1 == nil)
        #expect(engine.isActive(ticket))
        // Claim equality holds across repeated diagnostics reads, while a new claim is distinct.
        let diag1 = try #require(engine.executionReservations.first?.preparationClaim)
        let diag2 = try #require(engine.executionReservations.first?.preparationClaim)
        #expect(diag1 == claim)
        #expect(diag1 == diag2)
        engine.finishDeliveryClaim(claim)
        let claimedSecond = engine.claimDelivery(for: ticket)
        let secondClaim = try #require(claimedSecond)
        #expect(secondClaim != claim)
        // A candidate carrying the finished claim is rejected with inactiveAuthority.
        let staleClaimCandidate = try RuntimeState<TrackedModel, Int>
            .prepare(
                on: engine.snapshot,
                next: TrackedModel(3),
                requiring: [ticket],
                plan: .init(retire: [ticket], finishingClaims: [claim])
            )
        guard case .rejected(.inactiveAuthority, _) = engine.commit(staleClaimCandidate) else {
            Issue.record("Expected stale delivery claim to be rejected")
            return
        }
        engine.finishDeliveryClaim(secondClaim)
        // Idempotent close preserves final revision, clears edge, and keeps s0 untouched.
        let closed1 = engine.close()
        let closed2 = engine.close()
        #expect(closed1.revision == 3)
        #expect(closed1.isClosed)
        #expect(closed1.edge == nil)
        #expect(closed2.revision == closed1.revision)
        #expect(closed2.isClosed)
        #expect(s0.revision == 0)
        #expect(!s0.isClosed)
        #expect(s0.model.value == 0)
        #expect(engine.owns(s0))
    }

    private func trackedStart(scope: RuntimeScopeID) -> RuntimeState<TrackedModel, Int>.Start {
        .init(RuntimeOperation(kind: 1, scope: scope), descriptor: 1)
    }

    @Test func valueCopiesOfRuntimeStateKeepIndependentRevisionsInOneRealm() throws {
        var original = try engine()
        var fork = original
        let forkCandidate = try Core.prepare(on: fork.snapshot, next: 10, plan: .init(edge: "fork"))
        guard case .committed(let forked) = fork.commit(forkCandidate) else {
            Issue.record("Expected fork commit")
            return
        }
        #expect(forked.model == 10)
        #expect(forked.revision == 1)
        #expect(forked.edge == "fork")
        #expect(original.snapshot.model == 0)
        #expect(original.snapshot.revision == 0)
        #expect(original.snapshot.edge == nil)
        #expect(original.owns(forked))
        // A candidate prepared on the fork's revision conflicts on the original value copy.
        let fromFork = try Core.prepare(on: forked, next: 20)
        reject(original.commit(fromFork), as: .conflict, model: 0, revision: 0)
        // The original copy can still advance from its own revision.
        let fromOriginal = try Core.prepare(on: original.snapshot, next: 30, plan: .init(edge: "orig"))
        guard case .committed(let advanced) = original.commit(fromOriginal) else {
            Issue.record("Expected original commit")
            return
        }
        #expect(advanced.model == 30)
        #expect(advanced.revision == 1)
        #expect(advanced.edge == "orig")
        // A foreign owner's snapshot is still rejected as foreignOwner.
        let other = try engine()
        #expect(!original.owns(other.snapshot))
        let foreign = try Core.prepare(on: other.snapshot, next: 40)
        reject(original.commit(foreign), as: .foreignOwner, model: 30, revision: 1)
    }
}
