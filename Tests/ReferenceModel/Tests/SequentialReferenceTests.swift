import Testing

@testable import StateMachineReferenceModel

@Suite("Independent specification reference")
struct SequentialReferenceTests {
    private func loadedMachine(
        configuration: ReferenceConfiguration = .init()
    ) throws -> (SequentialReference, ReferenceTicket) {
        var model = SequentialReference(owner: 1, configuration: configuration)
        _ = model.commit(try model.prepare(.load(7)))
        let ticket = try #require(model.active.first)
        return (model, ticket)
    }
    @Test func proposalsAreInertAndOneRootWins() throws {
        var model = SequentialReference(owner: 1)
        let before = model.snapshot
        let first = try model.prepare(.load(7))
        let second = try model.prepare(.load(8))
        #expect(model.snapshot == before)
        #expect(model.reservations.isEmpty)
        #expect(model.batches.isEmpty)
        _ = model.commit(first)
        let installed = model.snapshot
        #expect(model.commit(second) == .rejected(.conflict))
        #expect(model.snapshot == installed)
        #expect(model.active.count == 1)
        #expect(model.batches.count == 1)
    }
    @Test func unrelatedFieldSurvivesFreshCompletionAndDuplicatesFail() throws {
        var (model, ticket) = try loadedMachine()
        let old = try model.prepareCompletion(ticket, outcome: .success(11))
        _ = model.commit(try model.prepare(.presentation(99)))
        #expect(model.valid(ticket))
        #expect(model.commit(old) == .rejected(.conflict))
        let fresh = try model.prepareCompletion(ticket, outcome: .success(11))
        _ = model.commit(fresh)
        #expect(model.root == .init(.loaded(11), presentation: 99))
        #expect(model.commit(fresh) == .rejected(.inactiveAuthority))
        #expect(model.active.isEmpty)
    }
    @Test func domainRejectionDoesNotRetireAuthority() throws {
        var (model, ticket) = try loadedMachine()
        let before = model.snapshot
        #expect(throws: ReferenceRejection.domain) { try model.prepareCompletion(ticket, outcome: .success(-1)) }
        #expect(model.snapshot == before)
        #expect(model.valid(ticket))
        _ = model.commit(try model.prepareCompletion(ticket, outcome: .failure(500)))
        #expect(model.root.phase == .failed(request: 7, failure: 500))
    }
    @Test func restoreAndForkUseExplicitLoadingPolicyAndFreshHistory() throws {
        let (source, ticket) = try loadedMachine()
        #expect(throws: ReferenceRejection.domain) { try source.fork(owner: 2) }
        #expect(throws: ReferenceRejection.domain) { try SequentialReference.restore(owner: 2, root: source.root) }
        let fork = try source.fork(owner: 2, loading: .cancelLoading)
        let restored = try SequentialReference.restore(owner: 3, root: source.root, loading: .cancelLoading)
        #expect(fork.root.phase == .idle(7))
        #expect(restored.root.phase == .idle(7))
        #expect(fork.revision == 0 && restored.revision == 0)
        #expect(!fork.valid(ticket) && !restored.valid(ticket))
        #expect(restored.active.isEmpty && restored.reservations.isEmpty && restored.pending.isEmpty)
        var replay = ReferenceReplay(source)
        #expect(replay.execute(.fork(owner: 4, loading: .rejectLoading)) == .rejected(.domain))
        guard
            case .snapshot(let snapshot) = replay.execute(
                .restore(owner: 5, root: .init(.loaded(9)), loading: .rejectLoading)
            )
        else {
            Issue.record("Missing restored history")
            return
        }
        #expect(snapshot.stamp.owner == 5 && snapshot.stamp.revision == 0)
    }
    @Test func ownerResetAndABAStayDistinct() throws {
        var (model, oldTicket) = try loadedMachine()
        let old = try model.prepare(.presentation(1))
        var other = try model.fork(owner: 2, loading: .cancelLoading)
        #expect(other.revision == 0)
        #expect(other.active.isEmpty && other.reservations.isEmpty && other.batches.isEmpty)
        #expect(other.commit(old) == .rejected(.foreignOwner))
        _ = model.commit(try model.prepare(.cancel))
        _ = model.commit(try model.prepare(.load(7)))
        let replacement = try #require(model.active.first)
        #expect(oldTicket.operation != replacement.operation)
        #expect(!model.valid(oldTicket))
        let resetProof = try model.prepare(.presentation(2))
        let previousRevision = model.revision
        _ = model.commit(try model.prepareReset(.init(.idle(7))))
        #expect(model.revision == previousRevision + 1)
        #expect(model.commit(resetProof) == .rejected(.obsoleteIncarnation))
    }
    @Test func dependencyAndDynamicReinsertionInvalidateEqualData() throws {
        var (model, ticket) = try loadedMachine()
        let phase = model.root.phase
        _ = model.commit(try model.prepare(.authentication))
        #expect(model.root.phase == phase)
        #expect(!model.valid(ticket))
        let child = ReferenceStart(kind: 4, scope: .child, dependencies: [], policy: .parallel(2))
        _ = model.commit(try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [child])))
        let childTicket = try #require(model.active.first)
        _ = model.commit(try model.prepare(.removeReinsertChild))
        #expect(!model.valid(childTicket))
        _ = model.commit(try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [child])))
        #expect(model.active.first?.activations[.child] != childTicket.activations[.child])
    }
    @Test func closeUsesReservedRevisionAndQueueAndIsIdempotent() throws {
        var model = SequentialReference(owner: 1, configuration: .init(queue: 1), revision: UInt64.max - 2)
        _ = model.commit(try model.prepare(.presentation(1)))
        #expect(model.revision == UInt64.max - 1)
        #expect(model.commit(try model.prepare(.presentation(2))) == .rejected(.revisionExhausted))
        let close = model.close()
        #expect(close.stamp.revision == UInt64.max)
        #expect(model.close() == close)
        #expect(model.batches.count == 1)
        #expect(model.terminal != nil)
        #expect(model.commit(try model.prepare(.presentation(3))) == .rejected(.closed))
        #expect(model.drain().map(\.terminal) == [false, true])
        #expect(model.isQuiescent)
    }
    @Test func permanentPlanAndTransientCapacityDiffer() throws {
        var model = SequentialReference(owner: 1, configuration: .init(queue: 1, descriptors: 1, reservations: 2))
        #expect(throws: ReferenceRejection.planTooLarge) {
            try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [.init(), .init(kind: 2)]))
        }
        #expect(throws: ReferenceRejection.invalidPlan) {
            try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [.init(policy: .parallel(0))]))
        }
        _ = model.commit(try model.prepare(.presentation(1)))
        let candidate = try model.prepare(.presentation(2))
        #expect(model.commit(candidate) == .rejected(.commitQueue))
        _ = model.drain()
        #expect(model.commit(candidate) == .committed(model.snapshot))
    }
    @Test func operationPolicyRejectsWithoutPublishingProspectiveChanges() throws {
        for policy in [ReferencePolicy.rejectWhenActive, .parallel(1)] {
            var model = SequentialReference(owner: 1)
            let start = ReferenceStart(scope: .child, dependencies: [], policy: policy)
            _ = model.commit(try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [start])))
            let before = model.snapshot
            let authorities = model.active
            let activations = model.activations
            let candidate = try model.prepare(
                on: model.snapshot,
                next: .init(.idle(99)),
                plan: .init(invalidates: [.authentication], starts: [start])
            )
            let reason: ReferenceRejection = policy == .rejectWhenActive ? .alreadyActive : .parallelLimit
            #expect(model.commit(candidate) == .rejected(reason))
            #expect(model.snapshot == before && model.active == authorities && model.activations == activations)
        }
    }
    @Test func cancellationPreservesReservationAndRegistryUntilTermination() throws {
        var (model, ticket) = try loadedMachine(configuration: .init(reservations: 1))
        _ = model.drain()
        #expect(model.reservations.first?.execution == .running)
        _ = model.commit(try model.prepare(.cancel))
        #expect(!model.valid(ticket))
        #expect(model.reservations.count == 1)
        let replacement = try model.prepare(.load(7))
        #expect(model.commit(replacement) == .rejected(.executionReservations))
        _ = model.drain()
        #expect(model.reservations.first?.cancellationRequested == true)
        model.close()
        _ = model.drain()
        #expect(!model.isQuiescent)
        model.acknowledge(ticket)
        #expect(model.isQuiescent)
    }
    @Test func terminationAloneDoesNotSettleDelivery() throws {
        var (model, ticket) = try loadedMachine()
        _ = model.drain()
        model.acknowledge(ticket)
        #expect(model.reservations.count == 1)
        #expect(model.reservations.first?.deliverySettled == false)
        _ = model.retain(ticket, outcome: .success(12))
        _ = model.reconcile(ticket.operation)
        #expect(model.reservations.isEmpty)
    }
    @Test func closeDuringClaimRetainsReservationUntilClaimExit() throws {
        var (model, ticket) = try loadedMachine()
        _ = model.drain()
        model.acknowledge(ticket)
        _ = model.retain(ticket, outcome: .success(12))
        guard case .claimed(let attempt) = model.beginAttempt(ticket.operation) else {
            Issue.record("missing claim")
            return
        }
        #expect(model.beginAttempt(ticket.operation) == .inProgress)
        #expect(model.pending.first?.status == .preparing)
        let candidate = try model.prepareCompletion(ticket, outcome: attempt.outcome, on: attempt.snapshot)
        model.close()
        _ = model.drain()
        #expect(model.pending.isEmpty)
        #expect(model.reservations.count == 1)
        #expect(!model.isQuiescent)
        #expect(model.finishAttempt(attempt, preparation: .success(candidate)) == .discarded(.closed))
        #expect(model.isQuiescent)
        #expect(model.beginAttempt(ticket.operation) == .notPending)
    }
    @Test func firstEnvelopeRetainedAndManualConflictDoesNotReplay() throws {
        var (model, ticket) = try loadedMachine()
        _ = model.retain(ticket, outcome: .success(12))
        _ = model.retain(ticket, outcome: .failure(500))
        #expect(model.pending.first?.outcome == .success(12))
        let result = model.deliveryTurn(ticket.operation, interference: [.presentation(10)])
        #expect(result == .pending(ticket.operation, .reconciliationRequired))
        #expect(model.pending.first?.attempts == 1)
        #expect(model.ready.isEmpty)
        _ = model.reconcile(ticket.operation)
        #expect(model.root == .init(.loaded(12), presentation: 10))
    }
    @Test func retryYieldsAfterFourPreparations() throws {
        var (model, ticket) = try loadedMachine(configuration: .init(delivery: .retry))
        _ = model.retain(ticket, outcome: .success(12))
        let result = model.deliveryTurn(
            ticket.operation,
            interference: [.presentation(1), .presentation(2), .presentation(3), .presentation(4), .presentation(5)]
        )
        #expect(result == .pending(ticket.operation, .retryScheduled))
        #expect(model.pending.first?.attempts == 4)
        #expect(model.ready == [ticket.operation])
        #expect(model.root.presentation == 4)
        _ = model.scheduledRound()
        #expect(model.root == .init(.loaded(12), presentation: 4))
    }
    @Test func retryParksAfterSixteenConflictingTurns() throws {
        var (model, ticket) = try loadedMachine(configuration: .init(delivery: .retry))
        _ = model.retain(ticket, outcome: .success(12))
        var presentation = 0
        func conflicts() -> [SequentialReference.Input] {
            var edits: [SequentialReference.Input] = []
            for _ in 0 ..< 4 {
                presentation += 1
                edits.append(.presentation(presentation))
            }
            return edits
        }
        for turn in 1 ... 15 {
            #expect(model.ready.isEmpty || model.ready == [ticket.operation])
            let result = model.deliveryTurn(ticket.operation, interference: conflicts())
            #expect(result == .pending(ticket.operation, .retryScheduled), "turn \(turn)")
            #expect(model.ready == [ticket.operation], "turn \(turn)")
        }
        let last = model.deliveryTurn(ticket.operation, interference: conflicts())
        #expect(last == .pending(ticket.operation, .reconciliationRequired))
        #expect(model.pending.first?.status == .reconciliationRequired)
        #expect(model.pending.first?.attempts == 64)
        #expect(model.pending.first?.lastRejection == .conflict)
        #expect(model.ready.isEmpty)
        #expect(model.scheduledRound().isEmpty)
        guard case .committed = model.reconcile(ticket.operation) else {
            Issue.record("explicit reconciliation did not commit the parked outcome")
            return
        }
        #expect(model.root.phase == .loaded(12))
    }
    @Test func capacityRetryReusesCandidateWithoutPreparingAgain() throws {
        var (model, ticket) = try loadedMachine(configuration: .init(queue: 1))
        _ = model.retain(ticket, outcome: .success(12))
        #expect(model.deliveryTurn(ticket.operation) == .pending(ticket.operation, .waitingForCapacity))
        #expect(model.pending.first?.attempts == 1)
        _ = model.drain()
        guard case .committed = model.retryCapacity(ticket.operation) else {
            Issue.record("expected admission")
            return
        }
        #expect(model.pending.isEmpty)
        #expect(model.root.phase == .loaded(12))
    }
    @Test func successfulClaimCanReleaseOwnReservationProspectively() throws {
        var (model, ticket) = try loadedMachine(configuration: .init(reservations: 1))
        _ = model.drain()
        model.acknowledge(ticket)
        _ = model.retain(ticket, outcome: .success(12))
        guard case .claimed(let attempt) = model.beginAttempt(ticket.operation) else {
            Issue.record("missing claim")
            return
        }
        let candidate = try model.prepare(
            on: attempt.snapshot,
            next: .init(.loading(8)),
            requirements: [ticket],
            plan: .init(starts: [.init(input: 8)], retires: [ticket.operation])
        )
        guard case .committed = model.finishAttempt(attempt, preparation: .success(candidate)) else {
            Issue.record("self blocked")
            return
        }
        #expect(model.reservations.count == 1)
        #expect(model.active.first?.operation != ticket.operation)
    }
    @Test func subscriberHandshakeCoalescingAndLateCloseAreMonotonic() throws {
        var model = SequentialReference(owner: 1, configuration: .init(subscribers: 1))
        _ = model.commit(try model.prepare(.presentation(1)))
        let registered = model.subscribe()
        let id = try #require(registered)
        #expect(model.subscribe() == nil)
        _ = model.commit(try model.prepare(.presentation(2)))
        _ = model.drain()
        #expect(model.consumeSubscriber(id)?.stamp.revision == 2)
        model.close()
        _ = model.drain()
        #expect(model.consumeSubscriber(id)?.closed == true)
        let lateRegistered = model.subscribe()
        let late = try #require(lateRegistered)
        #expect(model.consumeSubscriber(late)?.closed == true)
        #expect(model.subscribers[id]?.delivered.map(\.stamp.revision) == [2, 3])
    }
    @Test func batchOrderAndEmptyWakeResponsibility() throws {
        var (model, ticket) = try loadedMachine()
        _ = model.commit(try model.prepare(.cancel))
        #expect(model.drainerScheduled)
        #expect(model.drain(limit: 0).isEmpty)
        let drained = model.drain()
        #expect(drained.map { $0.snapshot.stamp.revision } == [1, 2])
        #expect(model.runnerEvents == ["offer:1", "skip:\(ticket.operation)", "offer:2"])
        #expect(!model.drainerScheduled)
        _ = model.commit(try model.prepare(.presentation(1)))
        #expect(model.drainerScheduled)
        #expect(model.reservations.isEmpty)
    }
    @Test func rejectionPrecedenceAndDiscardFailurePreservePending() throws {
        var model = SequentialReference(owner: 1, configuration: .init(queue: 2), revision: UInt64.max - 2)
        let start = ReferenceStart(scope: .child, dependencies: [], policy: .rejectWhenActive)
        _ = model.commit(try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [start])))
        let policyCandidate = try model.prepare(on: model.snapshot, next: model.root, plan: .init(starts: [start]))
        #expect(model.commit(policyCandidate) == .rejected(.alreadyActive))
        #expect(model.commit(try model.prepare(.presentation(1))) == .rejected(.revisionExhausted))
        model.close()
        #expect(model.commit(policyCandidate) == .rejected(.closed))
        var foreign = SequentialReference(owner: 2)
        foreign.close()
        #expect(foreign.commit(policyCandidate) == .rejected(.foreignOwner))

        var (pendingModel, ticket) = try loadedMachine(configuration: .init(queue: 1))
        _ = pendingModel.retain(ticket, outcome: .success(12))
        #expect(pendingModel.discard(ticket.operation) == .discarded(.commitQueue))
        #expect(pendingModel.pending.count == 1 && pendingModel.valid(ticket))
        _ = pendingModel.drain()
        _ = pendingModel.discard(ticket.operation)
        #expect(pendingModel.pending.isEmpty && !pendingModel.valid(ticket))
        #expect(pendingModel.root.phase == .loading(7))
    }
    @Test func singleDrainerRetainsResponsibilityWhileBatchIsPopped() throws {
        var model = SequentialReference(owner: 1, configuration: .init(queue: 1))
        _ = model.commit(try model.prepare(.presentation(1)))
        let popped = model.popBatch()
        let first = try #require(popped)
        #expect(model.batches.isEmpty && model.drainerScheduled)
        _ = model.commit(try model.prepare(.presentation(2)))
        #expect(model.popBatch() == nil)
        model.process(first)
        #expect(model.processedThrough == 1)
        #expect(model.drain().map { $0.snapshot.stamp.revision } == [2])
        #expect(!model.drainerScheduled)
    }
    @Test(arguments: Array(UInt64(0) ... 31))
    func seededReferenceTracesAreReproducible(seed: UInt64) {
        let first = ReferenceTraceGenerator.replay(seed: seed)
        #expect(first.count == 100)
        #expect(first == ReferenceTraceGenerator.replay(seed: seed))
        guard case .snapshot(let final) = first.last?.response else {
            Issue.record("missing close")
            return
        }
        #expect(final.closed)
    }
    @Test func fourCallTwoClientHistoriesRespectRealTimePrecedence() {
        // Sixteen reproducible overlap schedules. Oracle responses are generated
        // from a known legal serialization, then searched independently.
        for schedule in 0 ..< 16 {
            let commands: [ReferenceCommand] = [
                .input(.presentation(1)), .snapshot(0), .input(.presentation(2)), .snapshot(1),
            ]
            var replay = ReferenceReplay(.init(owner: 1))
            let order = schedule % 2 == 0 ? [0, 1, 2, 3] : [1, 0, 3, 2]
            var results: [Int: ReferenceResponse] = [:]
            for index in order { results[index] = replay.execute(commands[index]) }
            let calls = commands.indices.map { index in
                ReferenceHistoryCall(
                    client: index % 2,
                    invocation: index < 2 ? 0 : 4,
                    response: index < 2 ? 3 : 7 + schedule,
                    command: commands[index],
                    result: results[index] ?? .missingSlot
                )
            }
            guard case .witness(let witness) = ReferenceHistoryChecker.check(calls, initial: .init(.init(owner: 1)))
            else {
                Issue.record("no witness for schedule \(schedule)")
                continue
            }
            #expect((witness.firstIndex(of: 0) ?? 4) < (witness.firstIndex(of: 2) ?? 0))
            #expect((witness.firstIndex(of: 1) ?? 4) < (witness.firstIndex(of: 3) ?? 0))
        }
        var machine = SequentialReference(owner: 1)
        let stale = machine.snapshot
        _ = machine.close()
        let impossible = [
            ReferenceHistoryCall(
                client: 0,
                invocation: 0,
                response: 1,
                command: .close,
                result: .snapshot(machine.snapshot)
            ),
            ReferenceHistoryCall(
                client: 1,
                invocation: 2,
                response: 3,
                command: .snapshot(0),
                result: .snapshot(stale)
            ),
        ]
        #expect(ReferenceHistoryChecker.check(impossible, initial: .init(.init(owner: 1))) == .noWitness)
    }
}
