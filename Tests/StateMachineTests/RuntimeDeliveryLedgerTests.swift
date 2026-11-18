import StateMachine
import Testing

@Suite struct RuntimeDeliveryLedgerTests {
    private typealias Core = RuntimeState<Int, Int>
    private typealias Ledger = RuntimeDeliveryLedger<Int, Int, Int, DomainFailure>
    private enum DomainFailure: Error, Equatable { case denied }
    private let scope = RuntimeScopeID(kind: 1)

    private func engine(commits: Int = 8, executions: Int = 8) throws -> Core {
        Core(0, scopes: [scope], limits: try .init(commits: commits, executions: executions))
    }

    private func accept(_ core: inout Core, model: Int, plan: Core.Plan = .init()) throws {
        let candidate = try Core.prepare(on: core.snapshot, next: model, plan: plan)
        guard case .committed = core.commit(candidate) else {
            Issue.record("Expected admission")
            throw TestFailure.admission
        }
    }

    private enum TestFailure: Error { case admission, retention, claim }

    private func start(_ core: inout Core, kinds: [UInt32] = [1]) throws -> [RuntimeWork<Int>] {
        try accept(
            &core,
            model: 1,
            plan: .init(starts: kinds.map { .init(.init(kind: $0, scope: scope), descriptor: Int($0)) })
        )
        return core.drain(limit: 1)
            .flatMap { batch in
                batch.commands.compactMap {
                    if case .start(let work) = $0 { return work }
                    return nil
                }
            }
    }

    private func retain(
        _ value: Int,
        ticket: RuntimeTicket,
        ledger: inout Ledger,
        core: inout Core
    ) throws
        -> RuntimePendingID
    {
        guard case .pending(let id) = ledger.retain(value, for: ticket, in: &core) else {
            Issue.record("Expected retained envelope")
            throw TestFailure.retention
        }
        return id
    }

    private func claim(_ id: RuntimePendingID, ledger: inout Ledger, core: inout Core) throws -> Ledger.Attempt {
        guard case .claimed(let attempt) = ledger.claim(id, in: &core) else {
            Issue.record("Expected preparation claim")
            throw TestFailure.claim
        }
        return attempt
    }

    private func terminal(
        _ attempt: Ledger.Attempt,
        ticket: RuntimeTicket,
        successor: Bool = false
    ) throws
        -> Core.Candidate
    {
        try Core.prepare(
            on: attempt.snapshot,
            next: attempt.outcome,
            requiring: [ticket],
            plan: .init(
                retire: [ticket],
                starts: successor ? [.init(.init(kind: 1, scope: scope), descriptor: 99)] : [],
                finishingClaims: [attempt.claim]
            )
        )
    }

    @Test func duplicateRetentionKeepsFirstEnvelopeAndSinglePreparationClaim() throws {
        var core = try engine()
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let duplicate = try retain(99, ticket: work.ticket, ledger: &ledger, core: &core)
        #expect(duplicate == id)
        #expect(ledger.pending.map(\.outcome) == [42])
        #expect(ledger.pending.first?.status == .awaitingAdmission)
        #expect(ledger.pending.first?.attemptsSaturated == false)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        #expect(attempt.outcome == 42)
        guard case .inProgress = ledger.claim(id, in: &core) else {
            Issue.record("Concurrent preparation acquired the same envelope")
            return
        }
        #expect(ledger.pending.first?.attempts == 1)
        guard
            case .pending(let finishedID, .reconciliationRequired) = ledger.finish(
                attempt,
                preparation: .failure(.preparation(.denied)),
                in: &core
            )
        else {
            Issue.record("Domain rejection did not require reconciliation")
            return
        }
        #expect(finishedID == id)
        #expect(ledger.pending.first?.lastRejection == .preparation(.denied))
        #expect(ledger.pending.map(\.outcome) == [42])
        #expect(core.isActive(work.ticket))
        #expect(core.executionReservations.first?.isPreparing == false)
        #expect(core.acknowledge(work.ticket) == .recorded)
    }

    /// Leaves one envelope in the state a host reaches after its fourth automatic conflict.
    private func scheduledAfterConflict(
        ledger: inout Ledger,
        core: inout Core
    ) throws -> (id: RuntimePendingID, ticket: RuntimeTicket) {
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let stale = try claim(id, ledger: &ledger, core: &core)
        let candidate = try terminal(stale, ticket: work.ticket)
        try accept(&core, model: 2)
        _ = ledger.finish(stale, preparation: .success(candidate), in: &core)
        let decision = try #require(ledger.pending.first?.decision)
        let scheduled = ledger.scheduleRetry(id, after: decision)
        #expect(scheduled)
        #expect(ledger.pending.first?.status == .retryScheduled)
        return (id, work.ticket)
    }

    @Test func aQueuedRetryClaimsWhileItsSchedulingDecisionStands() throws {
        var core = try engine()
        var ledger = Ledger()
        let scheduled = try scheduledAfterConflict(ledger: &ledger, core: &core)
        guard case .claimed(let attempt) = ledger.claim(scheduled.id, in: &core, scheduledRetry: true) else {
            Issue.record("The queued turn lost its own claim")
            return
        }
        let corrected = try terminal(attempt, ticket: scheduled.ticket)
        guard case .committed = ledger.finish(attempt, preparation: .success(corrected), in: &core) else {
            Issue.record("The queued retry did not commit")
            return
        }
    }

    @Test func aQueuedRetryYieldsToANewerDomainRejection() throws {
        var core = try engine()
        var ledger = Ledger()
        let scheduled = try scheduledAfterConflict(ledger: &ledger, core: &core)
        // An explicit attempt finishes between the scheduling decision and the queued turn.
        let explicit = try claim(scheduled.id, ledger: &ledger, core: &core)
        _ = ledger.finish(explicit, preparation: .failure(.preparation(.denied)), in: &core)
        let attempts = ledger.pending.first?.attempts
        guard case .notPending = ledger.claim(scheduled.id, in: &core, scheduledRetry: true) else {
            Issue.record("The queued turn overrode a newer decision")
            return
        }
        #expect(ledger.pending.first?.status == .reconciliationRequired)
        #expect(ledger.pending.first?.lastRejection == .preparation(.denied))
        #expect(ledger.pending.first?.attempts == attempts)
    }

    @Test func aQueuedRetryKeepsANewerCandidateThatWaitsForCapacity() throws {
        var core = try engine(commits: 1)
        var ledger = Ledger()
        let scheduled = try scheduledAfterConflict(ledger: &ledger, core: &core)
        // The queue is full, so the explicit attempt's candidate is retained for an admission-only retry.
        let explicit = try claim(scheduled.id, ledger: &ledger, core: &core)
        let candidate = try terminal(explicit, ticket: scheduled.ticket)
        guard
            case .pending(_, .waitingForCapacity) = ledger.finish(
                explicit,
                preparation: .success(candidate),
                in: &core
            )
        else {
            Issue.record("The explicit attempt did not wait for capacity")
            return
        }
        guard case .notPending = ledger.claim(scheduled.id, in: &core, scheduledRetry: true) else {
            Issue.record("The queued turn discarded a retained candidate")
            return
        }
        #expect(ledger.pending.first?.status == .waitingForCapacity)
        _ = core.drain(limit: 1)
        guard case .committed = ledger.retryAdmission(scheduled.id, in: &core) else {
            Issue.record("The retained candidate was lost")
            return
        }
    }

    /// Prepares the terminal candidate for an attempt, or the plan defect that prevents one.
    private func preparation(_ attempt: Ledger.Attempt, ticket: RuntimeTicket) -> Ledger.Preparation {
        do throws(PlanRejection) {
            return .success(
                try Core.prepare(
                    on: attempt.snapshot,
                    next: attempt.outcome,
                    requiring: [ticket],
                    plan: .init(retire: [ticket], finishingClaims: [attempt.claim])
                )
            )
        } catch { return .failure(.admission(.plan(error))) }
    }

    /// Commits an unrelated change, as a concurrent caller would; an empty plan has no defect.
    private func commitUnrelated(_ core: inout Core, model: Int) {
        if case .candidate(let candidate) = Core.propose(on: core.snapshot, next: model) { _ = core.commit(candidate) }
    }

    /// Claims, prepares, and finishes one explicit attempt, as `reconcile(id:)` does.
    private func explicitAttempt(
        _ id: RuntimePendingID,
        ticket: RuntimeTicket,
        ledger: inout Ledger,
        core: inout Core
    ) -> Ledger.Finish? {
        guard case .claimed(let attempt) = ledger.claim(id, in: &core) else { return nil }
        return ledger.finish(attempt, preparation: preparation(attempt, ticket: ticket), in: &core)
    }

    @Test func anImmediateRetryYieldsToAnExplicitAttemptThatFinishedBeforeIt() throws {
        // One queue slot, so the explicit attempt's candidate waits for capacity.
        var core = try engine(commits: 1)
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        var claims = 0
        var preparations = 0
        var explicit: Ledger.Finish?
        let result = Ledger.reconcile(
            id,
            policy: .retryPure,
            automatic: true,
            claim: { decision in
                claims += 1
                if claims == 2 {
                    // The explicit attempt lands after the automatic one lost its conflict and
                    // before the automatic loop claims again.
                    explicit = explicitAttempt(id, ticket: work.ticket, ledger: &ledger, core: &core)
                }
                return ledger.claim(id, in: &core, continuing: decision)
            },
            prepare: { attempt in
                preparations += 1
                let candidate = preparation(attempt, ticket: work.ticket)
                // Another commit wins the race and takes the only queue slot.
                if preparations == 1 { commitUnrelated(&core, model: 2) }
                return candidate
            },
            finish: { attempt, preparation in
                let finished = ledger.finish(attempt, preparation: preparation, in: &core)
                return (finished, ledger.pending.first)
            },
            scheduleRetry: { ledger.scheduleRetry($0, after: $1) }
        )
        guard case .pending(_, .waitingForCapacity)? = explicit else {
            Issue.record("The explicit attempt did not wait for capacity")
            return
        }
        guard case .notPending = result else {
            Issue.record("The automatic retry overrode the explicit attempt's decision")
            return
        }
        #expect(preparations == 1)
        #expect(ledger.pending.first?.status == .waitingForCapacity)
        #expect(ledger.pending.first?.attempts == 2)
        _ = core.drain(limit: 1)
        guard case .committed(let snapshot) = ledger.retryAdmission(id, in: &core) else {
            Issue.record("The explicit attempt's candidate was lost")
            return
        }
        #expect(snapshot.model == 42)
    }

    @Test func aRetryIsNotScheduledAfterAnExplicitAttemptFinishedFirst() throws {
        // Four conflicting commits fill the queue, so the explicit attempt waits for capacity.
        var core = try engine(commits: 4)
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        var preparations = 0
        var explicit: Ledger.Finish?
        let result = Ledger.reconcile(
            id,
            policy: .retryPure,
            automatic: true,
            claim: { ledger.claim(id, in: &core, continuing: $0) },
            prepare: { attempt in
                preparations += 1
                let candidate = preparation(attempt, ticket: work.ticket)
                commitUnrelated(&core, model: 100 + preparations)
                return candidate
            },
            finish: { attempt, preparation in
                let finished = ledger.finish(attempt, preparation: preparation, in: &core)
                return (finished, ledger.pending.first)
            },
            scheduleRetry: { id, decision in
                // The explicit attempt lands after the fourth conflict and before scheduling.
                explicit = explicitAttempt(id, ticket: work.ticket, ledger: &ledger, core: &core)
                return ledger.scheduleRetry(id, after: decision)
            }
        )
        guard case .pending(_, .waitingForCapacity)? = explicit else {
            Issue.record("The explicit attempt did not wait for capacity")
            return
        }
        #expect(preparations == 4)
        guard case .finished(.pending(_, .reconciliationRequired)) = result else {
            Issue.record("The automatic path reported a retry it did not schedule")
            return
        }
        #expect(ledger.pending.first?.status == .waitingForCapacity)
        // A queued turn cannot claim an envelope whose retry was never scheduled.
        guard case .notPending = ledger.claim(id, in: &core, scheduledRetry: true) else {
            Issue.record("A queued turn discarded the explicit attempt's candidate")
            return
        }
        _ = core.drain(limit: 1)
        guard case .committed(let snapshot) = ledger.retryAdmission(id, in: &core) else {
            Issue.record("The explicit attempt's candidate was lost")
            return
        }
        #expect(snapshot.model == 42)
    }

    @Test func rootConflictRetainsEnvelopeUntilFreshExplicitPreparationCommits() throws {
        var core = try engine()
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let stale = try claim(id, ledger: &ledger, core: &core)
        let candidate = try terminal(stale, ticket: work.ticket)
        try accept(&core, model: 2)
        guard
            case .pending(let retained, .reconciliationRequired) = ledger.finish(
                stale,
                preparation: .success(candidate),
                in: &core
            )
        else {
            Issue.record("Conflict was not retained for manual reconciliation")
            return
        }
        #expect(retained == id)
        #expect(ledger.pending.first?.lastRejection == .admission(.conflict))
        #expect(ledger.pending.first?.outcome == 42)
        #expect(core.snapshot.model == 2)
        #expect(ledger.retryCapacity(in: &core).isEmpty)
        let fresh = try claim(id, ledger: &ledger, core: &core)
        #expect(fresh.outcome == stale.outcome)
        #expect(fresh.snapshot.model == 2)
        #expect(ledger.pending.first?.attempts == 2)
        let corrected = try terminal(fresh, ticket: work.ticket)
        guard case .committed(let snapshot) = ledger.finish(fresh, preparation: .success(corrected), in: &core) else {
            Issue.record("Fresh explicit preparation failed")
            return
        }
        #expect(snapshot.model == 42)
        #expect(ledger.pending.isEmpty)
        #expect(core.executionReservations.isEmpty)
    }

    @Test func queueCapacityRetryReusesCandidateWithoutNewPreparation() throws {
        var core = try engine(commits: 1, executions: 1)
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        try accept(&core, model: 2)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let candidate = try terminal(attempt, ticket: work.ticket, successor: true)
        guard
            case .pending(let retained, .waitingForCapacity) = ledger.finish(
                attempt,
                preparation: .success(candidate),
                in: &core
            )
        else {
            Issue.record("Full queue did not retain prepared candidate")
            return
        }
        #expect(retained == id)
        #expect(ledger.pending.first?.lastRejection == .admission(.capacityExceeded(.commitQueue)))
        #expect(ledger.pending.first?.outcome == 42)
        #expect(core.executionReservations.first?.isPreparing == false)
        let blockedRetry = ledger.retryCapacity(in: &core)
        guard case .pending(let retryID, .waitingForCapacity) = blockedRetry.first else {
            Issue.record("Admission-only retry bypassed queue capacity")
            return
        }
        #expect(retryID == id)
        #expect(ledger.pending.first?.attempts == 1)
        #expect(ledger.pending.first?.outcome == 42)
        #expect(core.snapshot.model == 2)
        #expect(core.drain(limit: 1).map(\.snapshot.model) == [2])
        let retries = ledger.retryCapacity(in: &core)
        guard case .committed(let accepted) = retries.first else {
            Issue.record("Admission-only retry did not commit retained candidate")
            return
        }
        #expect(retries.count == 1)
        #expect(accepted.model == 42)
        #expect(ledger.pending.isEmpty)
        #expect(!core.isActive(work.ticket))
        let successor = core.drain(limit: 1).flatMap(\.commands)
            .compactMap {
                if case .start(let work) = $0 { return work }
                return nil
            }
        #expect(successor.map(\.descriptor) == [99])
        #expect(core.executionReservations.count == 1)
        #expect(core.acknowledge(try #require(successor.first).ticket) == .recorded)
    }

    private enum InvalidationPath: CaseIterable, Sendable {
        case scopeRemoval
        case reset
        case discard
        case close
    }

    @Test(arguments: InvalidationPath.allCases)
    private func invalidationRetainsTerminatedReservationUntilClaimFinishes(path: InvalidationPath) throws {
        var core = try engine(executions: 1)
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        #expect(core.acknowledge(work.ticket) == .recorded)
        switch path {
        case .scopeRemoval:
            try accept(&core, model: 2, plan: .init(scopes: [.remove(scope)]))
        case .reset:
            try accept(&core, model: 2, plan: .init(reset: true))
        case .discard:
            guard case .committed = ledger.discard(id, in: &core) else {
                Issue.record("Explicit discard did not commit")
                return
            }
        case .close:
            _ = core.close()
        }
        #expect(!core.isActive(work.ticket))
        ledger.prune(in: core)
        #expect(ledger.pending.isEmpty)
        #expect(core.executionReservations.count == 1)
        #expect(core.executionReservations.first?.isPreparing == true)
        #expect(core.executionReservations.first?.execution == .terminated)
        #expect(core.executionReservations.first?.delivery == .settled)
        guard case .notPending = ledger.finish(attempt, preparation: .failure(.preparation(.denied)), in: &core) else {
            Issue.record("Invalidated attempt remained pending")
            return
        }
        #expect(core.executionReservations.isEmpty)
        _ = core.drain(limit: 8)
        if case .close = path { #expect(core.isQuiescent) }
    }

    @Test func discardRejectedByFullQueuePreservesEnvelopeAndAuthority() throws {
        var core = try engine(commits: 1)
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        try accept(&core, model: 2)
        let before = core.snapshot
        guard case .rejected(.capacityExceeded(.commitQueue), let current) = ledger.discard(id, in: &core) else {
            Issue.record("Discard bypassed full queue")
            return
        }
        #expect(current.revision == before.revision)
        #expect(current.model == 2)
        #expect(ledger.pending.map(\.outcome) == [42])
        #expect(ledger.pending.first?.id == id)
        #expect(core.isActive(work.ticket))
        #expect(core.executionReservations.first?.delivery == .pending)
        _ = core.drain(limit: 1)
        guard case .committed = ledger.discard(id, in: &core) else {
            Issue.record("Discard failed after draining capacity")
            return
        }
        #expect(ledger.pending.isEmpty)
        #expect(core.executionReservations.isEmpty)
    }

    @Test func finishingOwnClaimAllowsCapacityOneSuccessor() throws {
        var core = try engine(executions: 1)
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let candidate = try terminal(attempt, ticket: work.ticket, successor: true)
        guard case .committed(let snapshot) = ledger.finish(attempt, preparation: .success(candidate), in: &core) else {
            Issue.record("Finishing preparation self-blocked its successor")
            return
        }
        #expect(snapshot.model == 42)
        #expect(ledger.pending.isEmpty)
        #expect(core.executionReservations.count == 1)
        #expect(core.executionReservations.first?.ticket != work.ticket)
        #expect(core.executionReservations.first?.isPreparing == false)
        #expect(core.executionReservations.first?.execution == .queued)
    }

    @Test func finishingOwnClaimCannotReleaseAnotherHeldPreparation() throws {
        var core = try engine(executions: 2)
        var ledger = Ledger()
        let works = try start(&core, kinds: [1, 2])
        #expect(works.count == 2)
        let first = try #require(works.first)
        let other = try #require(works.last)
        #expect(core.acknowledge(first.ticket) == .recorded)
        #expect(core.acknowledge(other.ticket) == .recorded)
        let id = try retain(42, ticket: first.ticket, ledger: &ledger, core: &core)
        let otherID = try retain(99, ticket: other.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let held = try claim(otherID, ledger: &ledger, core: &core)
        let candidate = try Core.prepare(
            on: attempt.snapshot,
            next: 42,
            requiring: works.map(\.ticket),
            plan: .init(
                retire: works.map(\.ticket),
                starts: [
                    .init(.init(kind: 1, scope: scope), descriptor: 10),
                    .init(.init(kind: 2, scope: scope), descriptor: 20),
                ],
                finishingClaims: [attempt.claim]
            )
        )
        guard
            case .pending(_, .waitingForCapacity) = ledger.finish(attempt, preparation: .success(candidate), in: &core)
        else {
            Issue.record("Another live claim was incorrectly credited as available capacity")
            return
        }
        #expect(core.snapshot.model == 1)
        #expect(core.executionReservations.count == 2)
        #expect(core.executionReservations.filter(\.isPreparing).map(\.ticket) == [other.ticket])
        #expect(ledger.pending.first?.lastRejection == .admission(.capacityExceeded(.executionReservations)))
        guard
            case .pending(_, .reconciliationRequired) = ledger.finish(
                held,
                preparation: .failure(.preparation(.denied)),
                in: &core
            )
        else {
            Issue.record("Other claim did not finish")
            return
        }
        let retries = ledger.retryCapacity(in: &core)
        guard case .committed = retries.first else {
            Issue.record("Released claim continued blocking retained candidate")
            return
        }
        #expect(ledger.pending.isEmpty)
        #expect(core.snapshot.model == 42)
        #expect(core.executionReservations.count == 2)
        #expect(core.executionReservations.allSatisfy { $0.execution == .queued && !$0.isPreparing })
    }
    @Test(arguments: [PlanRejection.invalidPlan, .planTooLarge])
    func planPreparationFailureRetainsTypedReasonWithoutAutomaticAttempts(reason: PlanRejection) throws {
        var core = try engine()
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        var preparationCount = 0
        var scheduled: [RuntimePendingID] = []
        let result = Ledger.reconcile(
            id,
            policy: .retryPure,
            automatic: true,
            claim: { ledger.claim(id, in: &core, continuing: $0) },
            prepare: { attempt in
                preparationCount += 1
                do throws(PlanRejection) {
                    return .success(
                        try Core.prepare(
                            on: attempt.snapshot,
                            next: 42,
                            plan: .init(controlCount: reason == .invalidPlan ? -1 : 65)
                        )
                    )
                } catch { return .failure(.admission(.plan(error))) }
            },
            finish: { attempt, preparation in
                let finished = ledger.finish(attempt, preparation: preparation, in: &core)
                return (finished, ledger.pending.first)
            },
            scheduleRetry: { id, _ in
                scheduled.append(id)
                return true
            }
        )
        guard case .finished(.pending(let retained, .reconciliationRequired)) = result else {
            Issue.record("Plan preparation failure was not retained for reconciliation")
            return
        }
        #expect(retained == id)
        #expect(ledger.pending.first?.lastRejection == .admission(.plan(reason)))
        #expect(ledger.pending.first?.outcome == 42)
        #expect(ledger.pending.first?.attempts == 1)
        #expect(ledger.pending.first?.attemptsSaturated == false)
        #expect(preparationCount == 1)
        #expect(scheduled.isEmpty)
        #expect(ledger.retryCapacity(in: &core).isEmpty)
        #expect(core.isActive(work.ticket))
        #expect(core.executionReservations.first?.isPreparing == false)
        #expect(core.snapshot.model == 1)
    }

    @Test func operationPolicyRejectionRetainsEnvelopeForExplicitReconciliation() throws {
        var core = try engine()
        var ledger = Ledger()
        try accept(
            &core,
            model: 1,
            plan: .init(starts: [
                .init(.init(kind: 1, scope: scope), descriptor: 1),
                .init(.init(kind: 2, scope: scope, policy: .rejectWhenActive), descriptor: 2),
            ])
        )
        let issued = core.drain(limit: 1)
            .flatMap { batch in
                batch.commands.compactMap { command -> RuntimeWork<Int>? in
                    if case .start(let work) = command { return work }
                    return nil
                }
            }
        let work = try #require(issued.first)
        #expect(core.acknowledge(work.ticket) == .recorded)
        let id = try retain(42, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let candidate = try Core.prepare(
            on: attempt.snapshot,
            next: 42,
            requiring: [work.ticket],
            plan: .init(
                retire: [work.ticket],
                starts: [.init(.init(kind: 2, scope: scope, policy: .rejectWhenActive), descriptor: 99)],
                finishingClaims: [attempt.claim]
            )
        )
        guard
            case .pending(let retained, .reconciliationRequired) = ledger.finish(
                attempt,
                preparation: .success(candidate),
                in: &core
            )
        else {
            Issue.record("Operation-policy rejection did not require reconciliation")
            return
        }
        #expect(retained == id)
        #expect(ledger.pending.first?.lastRejection == .admission(.operationPolicy(.alreadyActive)))
        #expect(ledger.pending.first?.status == .reconciliationRequired)
        #expect(ledger.pending.first?.outcome == 42)
        #expect(ledger.pending.first?.attempts == 1)
        #expect(ledger.retryCapacity(in: &core).isEmpty)
        #expect(core.snapshot.model == 1)
        #expect(core.isActive(work.ticket))
        #expect(core.isActive(issued[1].ticket))
        #expect(core.executionReservations.count == 2)
        #expect(core.executionReservations.first?.isPreparing == false)
        #expect(!core.hasQueuedBatches)
    }

    @Test func readyQueueDeduplicatesAndRotatesRoundsUnderOneScheduler() throws {
        var core = try engine()
        var ledger = Ledger()
        let works = try start(&core, kinds: [1, 2])
        let first = try retain(42, ticket: #require(works.first).ticket, ledger: &ledger, core: &core)
        let second = try retain(99, ticket: #require(works.last).ticket, ledger: &ledger, core: &core)
        var queue = RuntimeDeliveryReadyQueue()
        #expect(queue.isIdle)
        let firstSchedules = queue.enqueue(first)
        let duplicateSchedules = queue.enqueue(first)
        let secondSchedules = queue.enqueue(second)
        #expect(firstSchedules)
        #expect(!duplicateSchedules)
        #expect(!secondSchedules)
        #expect(!queue.isIdle)
        let firstRound = queue.takeRound()
        #expect(firstRound == [first, second])
        #expect(!queue.isIdle)
        // A retried member rotates behind work requeued earlier in this cohort.
        let otherSchedules = queue.enqueue(second)
        let retrySchedules = queue.enqueue(first)
        let duplicateRetrySchedules = queue.enqueue(second)
        #expect(!otherSchedules)
        #expect(!retrySchedules)
        #expect(!duplicateRetrySchedules)
        let continues = queue.finishRound()
        #expect(continues)
        let secondRound = queue.takeRound()
        #expect(secondRound == [second, first])
        let continuesAgain = queue.finishRound()
        #expect(!continuesAgain)
        #expect(queue.isIdle)
        #expect(ledger.pending.map(\.attempts) == [0, 0])
        #expect(ledger.pending.map(\.status) == [.awaitingAdmission, .awaitingAdmission])
    }

}

extension RuntimeDeliveryLedgerTests {
    /// Generated routers can only select an edge of the delivered operation, so the ledger is the
    /// one place that still has to refuse a substituted candidate.
    @Test func terminalCandidateCannotSubstituteAnInputPlanOrAnotherOperation() throws {
        var core = try engine()
        var ledger = Ledger()
        let works = try start(&core, kinds: [1, 2])
        let fetch = try #require(works.first)
        let audit = try #require(works.last)
        let id = try retain(101, ticket: fetch.ticket, ledger: &ledger, core: &core)
        let inputAttempt = try claim(id, ledger: &ledger, core: &core)
        let inputPlan = try Core.prepare(
            on: inputAttempt.snapshot,
            next: 50,
            plan: .init(finishingClaims: [inputAttempt.claim])
        )
        guard
            case .pending(id, .reconciliationRequired) = ledger.finish(
                inputAttempt,
                preparation: .success(inputPlan),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(ledger.pending.first?.lastRejection == .admission(.plan(.invalidPlan)))
        let otherAttempt = try claim(id, ledger: &ledger, core: &core)
        let otherPlan = try Core.prepare(
            on: otherAttempt.snapshot,
            next: 51,
            requiring: [audit.ticket],
            plan: .init(retire: [audit.ticket], finishingClaims: [otherAttempt.claim])
        )
        guard
            case .pending(id, .reconciliationRequired) = ledger.finish(
                otherAttempt,
                preparation: .success(otherPlan),
                in: &core
            )
        else { throw TestFailure.admission }
        let pending = try #require(ledger.pending.first)
        #expect(pending.lastRejection == .admission(.plan(.invalidPlan)))
        #expect(pending.attempts == 2)
        #expect(pending.outcome == 101)
        // Neither rejected candidate changed the root or consumed the other operation's authority.
        #expect(core.snapshot.model == 1)
        #expect(core.isActive(fetch.ticket))
        #expect(core.isActive(audit.ticket))
        #expect(core.drain(limit: 10).isEmpty)
    }

    @Test(arguments: [false, true])
    func terminalCandidateMustRequireAndRetireItsOwnClaimedTicket(missingRequirement: Bool) throws {
        var core = try engine()
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        let id = try retain(101, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let candidate = try Core.prepare(
            on: attempt.snapshot,
            next: 99,
            requiring: missingRequirement ? [] : [work.ticket],
            plan: .init(
                retire: missingRequirement ? [work.ticket] : [],
                starts: [.init(.init(kind: 2, scope: scope), descriptor: 2)],
                finishingClaims: [attempt.claim]
            )
        )
        guard
            case .pending(id, .reconciliationRequired) = ledger.finish(
                attempt,
                preparation: .success(candidate),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(core.snapshot.revision == 1)
        #expect(core.snapshot.model == 1)
        #expect(core.isActive(work.ticket))
        #expect(core.executionReservations.count == 1)
        #expect(core.executionReservations.first?.isPreparing == false)
        #expect(core.drain(limit: 10).isEmpty)
        let pending = try #require(ledger.pending.first)
        #expect(pending.outcome == 101)
        #expect(pending.lastRejection == .admission(.plan(.invalidPlan)))
        let retry = try claim(id, ledger: &ledger, core: &core)
        let valid = try terminal(retry, ticket: work.ticket)
        guard case .committed = ledger.finish(retry, preparation: .success(valid), in: &core) else {
            throw TestFailure.admission
        }
        #expect(ledger.pending.isEmpty)
        #expect(!core.isActive(work.ticket))
    }

    @Test func terminalAdmissionFinishesOnlyItsOwnClaimAndPreservesOtherRetirements() throws {
        var core = try engine()
        var ledger = Ledger()
        let works = try start(&core, kinds: [1, 2])
        let first = works[0]
        let second = works[1]
        let firstID = try retain(11, ticket: first.ticket, ledger: &ledger, core: &core)
        let secondID = try retain(22, ticket: second.ticket, ledger: &ledger, core: &core)
        let firstAttempt = try claim(firstID, ledger: &ledger, core: &core)
        let secondAttempt = try claim(secondID, ledger: &ledger, core: &core)
        _ = core.acknowledge(first.ticket)
        _ = core.acknowledge(second.ticket)
        let candidate = try Core.prepare(
            on: firstAttempt.snapshot,
            next: 3,
            requiring: [first.ticket, second.ticket],
            plan: .init(retire: [first.ticket, second.ticket], finishingClaims: [secondAttempt.claim])
        )
        guard case .committed = ledger.finish(firstAttempt, preparation: .success(candidate), in: &core) else {
            throw TestFailure.admission
        }
        #expect(!core.isActive(first.ticket))
        #expect(!core.isActive(second.ticket))
        #expect(core.executionReservations.count == 1)
        let held = try #require(core.executionReservations.first)
        #expect(held.ticket == second.ticket)
        #expect(held.preparationClaim == secondAttempt.claim)
        #expect(held.isPreparing)
        #expect(held.delivery == .settled)
        guard case .notPending = ledger.finish(secondAttempt, preparation: .failure(.preparation(.denied)), in: &core)
        else {
            throw TestFailure.admission
        }
        #expect(core.executionReservations.isEmpty)
    }
}

extension RuntimeDeliveryLedgerTests {
    @Test func foreignCandidateContextRetainsAnActuallyLiveEntryAndCanReconcile() throws {
        var core = try engine()
        let foreign = try engine()
        var ledger = Ledger()
        let work = try #require(start(&core).first)
        let id = try retain(101, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let candidate = try Core.prepare(
            on: foreign.snapshot,
            next: 99,
            requiring: [work.ticket],
            plan: .init(retire: [work.ticket], finishingClaims: [attempt.claim])
        )
        guard
            case .pending(let retained, .reconciliationRequired) = ledger.finish(
                attempt,
                preparation: .success(candidate),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(retained == id)
        #expect(core.snapshot.revision == 1)
        #expect(core.snapshot.model == 1)
        #expect(core.isActive(work.ticket))
        #expect(ledger.pending.first?.lastRejection == .admission(.foreignOwner))
        #expect(ledger.pending.first?.outcome == 101)
        #expect(core.executionReservations.first?.isPreparing == false)
        let retry = try claim(id, ledger: &ledger, core: &core)
        guard
            case .committed = ledger.finish(
                retry,
                preparation: .success(try terminal(retry, ticket: work.ticket)),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(ledger.pending.isEmpty)
    }

    @Test func inactiveAdditionalRequirementDoesNotDisposeTheStillLiveEntry() throws {
        var core = try engine()
        var ledger = Ledger()
        let works = try start(&core, kinds: [1, 2])
        let first = works[0]
        let other = works[1]
        let id = try retain(101, ticket: first.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        try accept(&core, model: 2, plan: .init(retire: [other.ticket]))
        #expect(core.isActive(first.ticket))
        #expect(!core.isActive(other.ticket))
        let candidate = try Core.prepare(
            on: core.snapshot,
            next: 99,
            requiring: [first.ticket, other.ticket],
            plan: .init(retire: [first.ticket], finishingClaims: [attempt.claim])
        )
        guard
            case .pending(let retained, .reconciliationRequired) = ledger.finish(
                attempt,
                preparation: .success(candidate),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(retained == id)
        #expect(core.snapshot.revision == 2)
        #expect(core.snapshot.model == 2)
        #expect(core.isActive(first.ticket))
        #expect(ledger.pending.first?.lastRejection == .admission(.inactiveAuthority))
        #expect(ledger.pending.first?.outcome == 101)
        let retry = try claim(id, ledger: &ledger, core: &core)
        guard
            case .committed = ledger.finish(
                retry,
                preparation: .success(try terminal(retry, ticket: first.ticket)),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(ledger.pending.isEmpty)
    }
}

extension RuntimeDeliveryLedgerTests {
    @Test func obsoleteCandidateIncarnationRetainsTheCurrentLiveEntry() throws {
        var core = try engine()
        var ledger = Ledger()
        let prior = core.snapshot
        try accept(&core, model: 0, plan: .init(reset: true))
        _ = core.drain(limit: 1)
        let work = try #require(start(&core).first)
        let id = try retain(101, ticket: work.ticket, ledger: &ledger, core: &core)
        let attempt = try claim(id, ledger: &ledger, core: &core)
        let candidate = try Core.prepare(
            on: prior,
            next: 99,
            requiring: [work.ticket],
            plan: .init(retire: [work.ticket], finishingClaims: [attempt.claim])
        )
        guard
            case .pending(let retained, .reconciliationRequired) = ledger.finish(
                attempt,
                preparation: .success(candidate),
                in: &core
            )
        else { throw TestFailure.admission }
        #expect(retained == id)
        #expect(core.isActive(work.ticket))
        #expect(core.snapshot.revision == 2)
        #expect(ledger.pending.first?.lastRejection == .admission(.obsoleteIncarnation))
        #expect(ledger.pending.first?.outcome == 101)
        let retry = try claim(id, ledger: &ledger, core: &core)
        guard
            case .committed = ledger.finish(
                retry,
                preparation: .success(try terminal(retry, ticket: work.ticket)),
                in: &core
            )
        else { throw TestFailure.admission }
    }
}
