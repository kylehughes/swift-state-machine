import StateMachine
import StateMachineExamples
import StateMachineTesting
import Testing

private typealias Transfers = ManualMachineTest<GeneratedTransfers.Local>

/// The download work among commands, in order.
private func downloads(_ commands: [GeneratedTransfers.Command]) -> [GeneratedTransfers.DownloadWork] {
    commands.compactMap { if case .download(let work) = $0 { work } else { nil } }
}

/// The cancelled executions among commands, in order.
private func cancellations(_ commands: [GeneratedTransfers.Command]) -> [GeneratedTransfers.ExecutionHandle] {
    commands.compactMap { if case .cancel(let execution) = $0 { execution } else { nil } }
}

/// The logged lines among commands, in order.
private func logged(_ commands: [GeneratedTransfers.Command]) -> [String] {
    commands.compactMap { if case .logged(let line) = $0 { line } else { nil } }
}

@Suite struct ManualMachineTestTests {
    private static func user() throws -> UserID { try UserID("manual") }
    private static func request() throws -> ProfileRequest { try ProfileRequest(userID: user()) }

    @Test func aKeyedDownloadAndItsEventsRunThroughTheRealDeliveryPath() throws {
        var test = Transfers(GeneratedTransfers.Local())
        let accepted = try test.send(.download(1))
        #expect(accepted.revision == 1)
        let started = try test.drainBatch()
        #expect(logged(started.commands) == ["download 1"])
        let works = downloads(started.commands)
        #expect(works.map(\.key) == [1])
        #expect(works.map(\.input) == ["file-1"])
        guard case .committed(let receipt) = test.deliver(.download(works[0].succeeded("bytes"))) else {
            Issue.record("the completion of issued work was not admitted")
            return
        }
        #expect(receipt.snapshot.model == .browsing(GeneratedTransfers.Browsing(files: [1: "bytes"])))
        #expect(logged(test.drainFlattenedCommands()) == ["downloaded 1"])
        #expect(test.acknowledgeExecution(works[0].execution) == .recorded)
        #expect(test.acknowledgeExecution(works[0].execution) == .duplicate)
        #expect(test.history.map(\.kind) == [.initial, .send, .delivery])
        #expect(test.history.map(\.edge) == [nil, "browsing.download", "browsing.downloaded"])
        #expect(test.history.map(\.revision) == [0, 1, 2])
        #expect(test.history.last?.trigger == .success("Download"))
        #expect(test.exercisedEdges == ["browsing.download", "browsing.downloaded"])
    }

    @Test func cancellingOneKeyRevokesOnlyItsWorkAndItsLateResultIsStale() throws {
        var test = Transfers(GeneratedTransfers.Local())
        try test.send(.download(1))
        try test.send(.download(2))
        let works = downloads(test.drainFlattenedCommands())
        #expect(works.map(\.key) == [1, 2])
        try test.send(.cancel(1))
        #expect(cancellations(test.drainFlattenedCommands()) == [works[0].execution])
        guard case .stale = test.deliver(.download(works[0].succeeded("late"))) else {
            Issue.record("the cancelled key's result was not stale")
            return
        }
        guard case .committed = test.deliver(.download(works[1].failed(.unavailable))) else {
            Issue.record("the remaining key's failure was not admitted")
            return
        }
        #expect(test.snapshot().model == .browsing(GeneratedTransfers.Browsing(failures: [2])))
        // A stale delivery accepts nothing, so it adds no step.
        #expect(
            test.history.map(\.edge) == [
                nil, "browsing.download", "browsing.download", "browsing.cancel", "browsing.failed",
            ]
        )
    }

    @Test func aRejectedSendFailsAtTheCallAndARequiredRejectionIsTyped() throws {
        var test = Transfers(GeneratedTransfers.Local())
        let rejection = try test.rejection(of: .goOnline)
        guard case .preparation(.invalidPhase) = rejection else {
            Issue.record("the rejection was \(rejection)")
            return
        }
        let line = #line + 2
        do {
            try test.send(.goOnline)
            Issue.record("an input with no edge from browsing was admitted")
        } catch {
            #expect(error.fileID.hasSuffix("ManualMachineTestTests.swift"))
            #expect(error.line == line)
            #expect(error.message.contains("goOnline"))
            #expect(error.description.hasPrefix(error.fileID + ":\(line):"))
        }
        do {
            _ = try test.rejection(of: .goOffline)
            Issue.record("an admitted input was reported as a rejection")
        } catch {
            #expect(error.message.contains("admitted"))
        }
        // The admitted input is recorded even though the expectation failed.
        #expect(test.history.map(\.edge) == [nil, "browsing.goOffline"])
        #expect(test.phase == "offline")
    }

    @Test func aTypedCommitNamesItsEdgeAmongEdgesWithTheSameEndpoints() throws {
        var test = ManualMachineTest(GeneratedProfile.Local(GeneratedProfile.Idle(userID: try Self.user())))
        try test.send(.load(Self.request()))
        guard case .loading(let loading) = test.snapshot() else {
            Issue.record("the load did not reach loading")
            return
        }
        guard case .committed = test.commit(loading.authenticationChanged()) else {
            Issue.record("the typed edge was not committed")
            return
        }
        guard case .loading(let again) = test.snapshot() else {
            Issue.record("the self-edge left loading")
            return
        }
        guard case .committed = test.commit(again.audit("check")) else {
            Issue.record("the audit was not committed")
            return
        }
        // A stale proposal is rejected and adds no step.
        guard case .rejected(.conflict, _) = test.commit(loading.authenticationChanged()) else {
            Issue.record("a proposal from an old observation was admitted")
            return
        }
        #expect(test.history.map(\.edge) == [nil, "idle.begin", "loading.authenticationChanged", "loading.audit"])
        #expect(test.history.map(\.kind) == [.initial, .send, .commit, .commit])
        #expect(test.history.last?.trigger == .input("audit"))
    }

    @Test func resetRevokesOutstandingWorkAndRecordsAStepWithoutAnEdge() throws {
        var test = Transfers(GeneratedTransfers.Local())
        try test.send(.download(5))
        let works = downloads(test.drainFlattenedCommands())
        let receipt = try test.reset(to: GeneratedTransfers.Browsing(files: [9: "kept"]))
        #expect(receipt.snapshot.model == .browsing(GeneratedTransfers.Browsing(files: [9: "kept"])))
        #expect(cancellations(test.drainFlattenedCommands()) == works.map(\.execution))
        guard case .stale = test.deliver(.download(works[0].succeeded("old"))) else {
            Issue.record("work from before the reset was not stale")
            return
        }
        #expect(test.acknowledgeExecution(works[0].execution) == .recorded)
        #expect(test.history.last?.kind == .reset)
        #expect(test.history.last?.edge == nil)
        #expect(receipt.edgeID == nil)
        test.close()
        _ = test.drainCommands()
        let quiescent = test.isQuiescent
        #expect(quiescent)
        #expect(test.history.last?.kind == .close)
    }

    /// A schema that declares its initial default lets the harness reset to it, as the owner's own
    /// `reset()` and `reset(expecting:)` do.
    @Test func resetWithoutAnInitialInstallsTheSchemaDefault() throws {
        var test = Transfers(GeneratedTransfers.Local())
        try test.send(.download(5))
        let works = downloads(test.drainFlattenedCommands())
        let receipt = try test.reset()
        #expect(receipt.snapshot.model == .browsing(GeneratedTransfers.Browsing()))
        #expect(GeneratedTransfers.Local.defaultInitialPhase() == GeneratedTransfers.Browsing())
        #expect(cancellations(test.drainFlattenedCommands()) == works.map(\.execution))
        #expect(test.history.map(\.kind) == [.initial, .send, .reset])
        // An expected reset refuses a snapshot that is no longer current and changes nothing.
        let stale = test.snapshot()
        try test.send(.download(6))
        #expect(throws: CommitRejection.conflict) { try test.reset(expecting: stale) }
        let current = test.snapshot()
        let expected = try test.reset(expecting: current)
        #expect(expected.snapshot.model == .browsing(GeneratedTransfers.Browsing()))
        #expect(test.history.map(\.kind) == [.initial, .send, .reset, .send, .reset])
        #expect(test.history.last?.edge == nil)
    }

    @Test func aRetainedCompletionIsAdmittedByRetryAndByReconciliation() throws {
        var test = Transfers(
            GeneratedTransfers.Local(configuration: try GeneratedTransfers.LocalConfiguration(commits: 1))
        )
        try test.send(.download(1))
        let first = downloads(test.drainFlattenedCommands())
        try test.send(.download(2))
        // The queue's only slot holds the second download, so the first completion waits for capacity.
        guard case .pending(let waiting, .waitingForCapacity) = test.deliver(.download(first[0].succeeded("one")))
        else {
            Issue.record("the completion was not retained for capacity")
            return
        }
        let second = downloads(test.drainFlattenedCommands())
        guard case .committed = test.retryAdmission(id: waiting) else {
            Issue.record("the retained candidate was not admitted")
            return
        }
        #expect(test.history.last?.kind == .retry)
        #expect(test.history.last?.edge == "browsing.downloaded")
        guard case .pending(let conflicted, .waitingForCapacity) = test.deliver(.download(second[0].succeeded("two")))
        else {
            Issue.record("the second completion was not retained for capacity")
            return
        }
        _ = test.drainFlattenedCommands()
        // An unrelated change between retention and retry makes the candidate stale.
        try test.send(.cancel(9))
        guard case .pending(_, .reconciliationRequired) = test.retryAdmission(id: conflicted) else {
            Issue.record("a candidate prepared on an old revision was admitted")
            return
        }
        guard case .committed = test.reconcile(id: conflicted) else {
            Issue.record("reconciliation did not admit the completion")
            return
        }
        #expect(test.history.last?.kind == .reconciliation)
        #expect(test.history.last?.edge == "browsing.downloaded")
        #expect(test.snapshot().model == .browsing(GeneratedTransfers.Browsing(files: [1: "one", 2: "two"])))
    }

    @Test func aDiscardedCompletionRecordsAStepAndARefusedReconciliationRecordsNone() throws {
        var test = ManualMachineTest(GeneratedScreen.Local())
        try test.send(.measure)
        let works = test.drainFlattenedCommands().compactMap { if case .measure(let work) = $0 { work } else { nil } }
        guard case .refused(let id, _, _) = test.deliver(.measure(works[0].succeeded(-1))) else {
            Issue.record("the router did not refuse a negative reading")
            return
        }
        let before = test.history.count
        guard case .refused = test.reconcile(id: id) else {
            Issue.record("the router admitted a negative reading")
            return
        }
        #expect(test.history.count == before)
        guard case .discarded = test.discardPending(id: id) else {
            Issue.record("the retained completion was not discarded")
            return
        }
        #expect(test.history.last?.kind == .discard)
        #expect(test.pendingCompletions().isEmpty)
    }

    @Test func invariantsAreCheckedOnEveryAcceptedSnapshot() throws {
        let single = Transfers.Invariant("at most one file") { snapshot in
            guard case .browsing(let browsing) = snapshot else { return true }
            return browsing.value.files.count <= 1
        }
        var test = Transfers(GeneratedTransfers.Local(), invariants: [single])
        try test.send(.download(1))
        try test.send(.download(2))
        for work in downloads(test.drainFlattenedCommands()) {
            _ = test.deliver(.download(work.succeeded("file \(work.key)")))
        }
        #expect(test.violations.map(\.invariant) == ["at most one file"])
        #expect(test.violations.map(\.step.revision) == [4])
        do {
            try test.requireInvariants()
            Issue.record("a violated invariant was not reported")
        } catch {
            #expect(error.message.contains("at most one file at revision 4"))
        }
    }

    @Test func aRestoringResetIsAVerbOfTheHarness() throws {
        var test = ManualMachineTest(GeneratedProfile.Local(GeneratedProfile.Idle(userID: try Self.user())))
        let profile = Profile(userID: try Self.user(), name: "Restored")
        let reviewed = test.snapshot()
        try test.send(.load(Self.request()))
        // The snapshot the reset was decided on is no longer current.
        do {
            try test.reset(restoring: .loaded(profile), expecting: reviewed)
            Issue.record("a reset decided on an old snapshot was admitted")
        } catch {
            guard case .commit(.conflict) = error else {
                Issue.record("the stale reset failed with \(error)")
                return
            }
        }
        let receipt = try test.reset(restoring: .loaded(profile), expecting: test.snapshot())
        #expect(receipt.edgeID == nil)
        #expect(test.history.last?.kind == .reset)
        #expect(test.history.last?.phase == "loaded")
        try test.reset(to: GeneratedProfile.Idle(userID: try Self.user()), expecting: receipt.snapshot)
        let phase = test.phase
        let complete = test.isHistoryComplete
        #expect(phase == "idle")
        #expect(complete)
        try test.requireInvariants()
    }

    @Test func anUnwrappedMemberRecordsAnUnattributedStepAndFinishReturnsTheOwner() throws {
        var test = ManualMachineTest(GeneratedProfile.Local(GeneratedProfile.Idle(userID: try Self.user())))
        let profile = Profile(userID: try Self.user(), name: "Restored")
        try test.withOwner { (owner: inout GeneratedProfile.Local) throws(GeneratedProfile.ResetRejection) in
            _ = try owner.reset(restoring: .loaded(profile))
        }
        #expect(test.history.last?.kind == .unattributed)
        #expect(test.history.last?.phase == "loaded")
        #expect(test.history.last?.edge == nil)
        // One change is fully observed, so the history stays complete.
        let complete = test.isHistoryComplete
        #expect(complete)
        var owner = test.finish()
        try owner.send(.refresh(Self.request()))
        guard case .loading = owner.snapshot() else {
            Issue.record("the returned owner did not keep its state")
            return
        }
    }

    @Test func severalChangesInsideWithOwnerLeaveTheHistoryIncomplete() throws {
        let browsing = Transfers.Invariant("always browsing") { snapshot in
            if case .browsing = snapshot { true } else { false }
        }
        var test = Transfers(GeneratedTransfers.Local(), invariants: [browsing])
        test.withOwner { (owner: inout GeneratedTransfers.Local) in
            _ = try? owner.send(.goOffline)
            _ = try? owner.send(.goOnline)
        }
        // The harness saw only the final browsing snapshot, not the offline one between.
        #expect(test.violations.isEmpty)
        #expect(test.unobservedChanges == 1)
        let complete = test.isHistoryComplete
        #expect(!complete)
        do {
            try test.requireInvariants()
            Issue.record("the harness vouched for a snapshot it never observed")
        } catch {
            #expect(error.message.contains("1 accepted changes made inside withOwner were never observed"))
        }
    }

    @Test func aFailedBatchExpectationTransfersNoBatch() throws {
        var test = Transfers(GeneratedTransfers.Local())
        try test.send(.download(1))
        try test.send(.download(2))
        do {
            _ = try test.drainBatch()
            Issue.record("two queued batches satisfied a one-batch expectation")
        } catch {
            #expect(error.message.contains("found 2"))
        }
        // The expectation counted the batches before transferring any, so both stay queued.
        let queued = test.queuedBatchCount
        #expect(queued == 2)
        let settled = test.isQuiescent
        #expect(!settled)
        let works = downloads(test.drainFlattenedCommands())
        #expect(works.map(\.key) == [1, 2])
        for work in works {
            _ = test.deliver(.download(work.succeeded("file")))
            #expect(test.acknowledgeExecution(work.execution) == .recorded)
        }
        _ = test.drainFlattenedCommands()
        test.close()
        _ = test.drainCommands()
        let quiescent = test.isQuiescent
        #expect(quiescent)
    }

    @Test func finishingAfterAFailedBatchExpectationReturnsEveryIssuedStart() throws {
        var test = Transfers(GeneratedTransfers.Local())
        try test.send(.download(1))
        try test.send(.download(2))
        #expect(throws: StateMachineTestFailure.self) { _ = try test.drainBatch() }
        // The finished owner still queues both starts, so their executions can be settled.
        var owner = test.finish()
        let queued = owner.queuedBatchCount
        #expect(queued == 2)
        let works = downloads(owner.drainCommands().flatMap(\.commands))
        #expect(works.map(\.key) == [1, 2])
        for work in works {
            _ = owner.deliver(.download(work.succeeded("file")))
            #expect(owner.acknowledgeExecution(work.execution) == .recorded)
        }
        _ = owner.drainCommands()
        owner.close()
        _ = owner.drainCommands()
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }

    @Test func replacingTheOwnerInsideWithOwnerLeavesTheHistoryIncomplete() throws {
        let browsing = Transfers.Invariant("always browsing") { snapshot in
            if case .browsing = snapshot { true } else { false }
        }
        var test = Transfers(GeneratedTransfers.Local(), invariants: [browsing])
        // A fresh owner at the same revision hides the offline snapshot the lent owner accepted.
        test.withOwner { (owner: inout GeneratedTransfers.Local) in
            _ = try? owner.send(.goOffline)
            owner = GeneratedTransfers.Local()
        }
        #expect(test.replacedOwners == 1)
        #expect(test.history.last?.kind == .unattributed)
        #expect(test.history.last?.revision == 0)
        let complete = test.isHistoryComplete
        #expect(!complete)
        do {
            try test.requireInvariants()
            Issue.record("the harness vouched for a history of two owners")
        } catch {
            #expect(error.message.contains("withOwner replaced the owner 1 times"))
        }
        // A replacement with different model data at the same revision is caught too.
        var other = Transfers(GeneratedTransfers.Local())
        other.withOwner { (owner: inout GeneratedTransfers.Local) in
            owner = GeneratedTransfers.Local(GeneratedTransfers.Browsing(files: [1: "planted"]))
        }
        #expect(other.replacedOwners == 1)
        #expect(other.history.last?.snapshot.model == .browsing(GeneratedTransfers.Browsing(files: [1: "planted"])))
        var coverage = GraphCoverage(for: GeneratedTransfers.Local.self)
        coverage.record(other)
        #expect(coverage.replacedOwners == 1)
        do {
            try coverage.requireCoverage(excluding: Set(GeneratedTransfers.graph.edges.map(\.id)))
            Issue.record("coverage vouched for a run whose owner was replaced")
        } catch {
            #expect(error.message.contains("owners replaced inside withOwner: 1"))
        }
    }

    @Test func aResetInsideWithOwnerKeepsTheOwner() throws {
        var test = Transfers(GeneratedTransfers.Local())
        try test.withOwner { (owner: inout GeneratedTransfers.Local) throws(CommitRejection) in
            _ = try owner.reset(to: GeneratedTransfers.Browsing(files: [2: "reset"]))
        }
        #expect(test.replacedOwners == 0)
        let complete = test.isHistoryComplete
        #expect(complete)
        try test.requireInvariants()
    }

    @Test func theConformanceDescribesValuesWithGraphMetadata() throws {
        #expect(GeneratedTransfers.Local.graph == GeneratedTransfers.graph)
        var local = GeneratedTransfers.Local()
        #expect(GeneratedTransfers.Local.phase(of: local.snapshot()) == "browsing")
        try local.send(.download(3))
        let work = try #require(downloads(local.drainCommands().flatMap(\.commands)).first)
        let delivered = local.deliver(.download(work.failed(.unavailable)))
        #expect(GeneratedTransfers.Local.receipt(of: delivered)?.edgeID == "browsing.failed")
        guard case .browsing(let browsing) = local.snapshot() else { return }
        let committed = local.commit(browsing.goOffline())
        #expect(GeneratedTransfers.Local.receipt(of: committed)?.edgeID == "browsing.goOffline")
        guard case .offline(let offline) = local.snapshot() else { return }
        _ = local.commit(offline.goOnline())
        // A stale proposal is rejected, so its result carries no receipt.
        #expect(GeneratedTransfers.Local.receipt(of: local.commit(browsing.goOffline())) == nil)
    }
}
