import Foundation
import StateMachine
import StateMachineExamples
import Testing

extension ExplorerTests {
    // MARK: - Distinct I52 oracle regression controls

    @Test func distinctHistoryPreservesTransientReceiptBeforeAsyncPoll() {
        // Simulates the exact I52 race: owner moves idle (rev 0) -> loading (rev 1, sync send receipt)
        // -> failed (rev 2, async fetchDriver commit) before MainActor polls `owner.snapshot()`.
        var receiptHistory = ExplorerDistinctHistory()
        receiptHistory.record(revision: 0, projection: "idle")
        // Even if the polled async state (rev 2) were observed before the sync receipt (rev 1),
        // revision ordering places "loading" strictly between "idle" and "failed".
        receiptHistory.record(revision: 2, projection: "failed")
        receiptHistory.record(revision: 1, projection: "loading")

        let readIdle = receiptHistory.checkRead("idle", reads: [], since: 0, lastReadRevision: nil)
        #expect(!readIdle.duplicate)
        #expect(readIdle.problem == nil)
        #expect(readIdle.nextAnchorRevision == 0)

        let readLoading = receiptHistory.checkRead(
            "loading",
            reads: ["idle"],
            since: 0,
            lastReadRevision: readIdle.nextAnchorRevision
        )
        #expect(!readLoading.duplicate)
        #expect(readLoading.problem == nil)
        #expect(readLoading.nextAnchorRevision == 1)

        let readFailed = receiptHistory.checkRead(
            "failed",
            reads: ["idle", "loading"],
            since: 0,
            lastReadRevision: readLoading.nextAnchorRevision
        )
        #expect(!readFailed.duplicate)
        #expect(readFailed.problem == nil)
        #expect(readFailed.nextAnchorRevision == 2)

        // Contrast old polling-only behavior: without the rev-1 receipt, history is ["idle", "failed"],
        // which falsely rejects the legitimate transient "loading" read.
        let pollingOnly = explorerDistinctReadProblem(
            "loading",
            reads: ["idle"],
            history: ["idle", "failed"],
            lastRead: 0
        )
        #expect(pollingOnly.problem != nil)
    }

    @Test func distinctHistoryPreservesRealReceiptsAndCatchesStaleOrDuplicateReads() throws {
        let user = try UserID("explorer")
        let request = try ProfileRequest(userID: user)
        // Driver stays suspended while we drive synchronous commits (load, auth edit, cancel, close).
        let owner = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in
                try? await Task.sleep(for: .seconds(10))
                return .failure(.unavailable)
            },
            auditDriver: { _ in .failure(.unavailable) }
        )

        var history = ExplorerDistinctHistory()
        let initial = owner.snapshot()
        history.record(revision: initial.revision, projection: ExplorerDistinctRun.phase(initial))

        // 1. Load commits transient `.loading` (rev 1).
        let loadReceipt = try owner.send(.load(request))
        history.record(
            revision: loadReceipt.snapshot.revision,
            projection: ExplorerDistinctRun.phase(loadReceipt.snapshot)
        )

        // 2. Authentication rotation commits `.loading` at a newer revision (rev 2, same phase).
        let authReceipt = try owner.send(.authenticationChanged)
        #expect(authReceipt.snapshot.revision > loadReceipt.snapshot.revision)
        #expect(ExplorerDistinctRun.phase(authReceipt.snapshot) == "loading")
        history.record(
            revision: authReceipt.snapshot.revision,
            projection: ExplorerDistinctRun.phase(authReceipt.snapshot)
        )

        // 3. Cancel returns to `.idle` (rev 3) and close seals `.idle` (rev 4).
        let cancelReceipt = try owner.send(.cancel)
        history.record(
            revision: cancelReceipt.snapshot.revision,
            projection: ExplorerDistinctRun.phase(cancelReceipt.snapshot)
        )
        let closeReceipt = owner.close()
        history.record(
            revision: closeReceipt.snapshot.revision,
            projection: ExplorerDistinctRun.phase(closeReceipt.snapshot)
        )

        // Consecutive equal projections (load + auth, and cancel + close) collapse to distinct runs.
        let runs = history.runs(since: initial.revision)
        #expect(runs.map(\.projection) == ["idle", "loading", "idle"])
        #expect(
            runs.map(\.revision) == [initial.revision, loadReceipt.snapshot.revision, cancelReceipt.snapshot.revision]
        )

        // Valid reads through the transient loading state and back to idle pass.
        let r0 = history.checkRead("idle", reads: [], since: initial.revision, lastReadRevision: nil)
        #expect(!r0.duplicate && r0.problem == nil)
        let r1 = history.checkRead(
            "loading",
            reads: ["idle"],
            since: initial.revision,
            lastReadRevision: r0.nextAnchorRevision
        )
        #expect(!r1.duplicate && r1.problem == nil)
        let r2 = history.checkRead(
            "idle",
            reads: ["idle", "loading"],
            since: initial.revision,
            lastReadRevision: r1.nextAnchorRevision
        )
        #expect(!r2.duplicate && r2.problem == nil)

        // Planted invalid order 1: returning to "loading" after already advancing to rev 3 "idle" fails.
        let staleLoading = history.checkRead(
            "loading",
            reads: ["idle", "loading", "idle"],
            since: initial.revision,
            lastReadRevision: r2.nextAnchorRevision
        )
        #expect(staleLoading.problem != nil)

        // Planted invalid order 2: fabricated phase never held by the owner fails (and does not seed history).
        let fabricated = history.checkRead(
            "loaded",
            reads: ["idle"],
            since: initial.revision,
            lastReadRevision: r0.nextAnchorRevision
        )
        #expect(fabricated.problem != nil)
        #expect(!history.runs(since: initial.revision).map(\.projection).contains("loaded"))

        // Planted invalid order 3: a sequence registered at authReceipt's revision cannot emit earlier "idle".
        let staleBeforeRegister = history.checkRead(
            "idle",
            reads: [],
            since: authReceipt.snapshot.revision,
            lastReadRevision: nil
        )
        // "idle" IS held later at cancelReceipt, so check registration at cancelReceipt instead for strict pre-reg stale check.
        let preRegisterStale = history.checkRead(
            "loading",
            reads: [],
            since: cancelReceipt.snapshot.revision,
            lastReadRevision: nil
        )
        #expect(staleBeforeRegister.problem == nil)
        #expect(preRegisterStale.problem != nil)

        // Planted duplicate across same-phase auth receipt (before cancel happened): must fail I52.
        var authOnlyHistory = ExplorerDistinctHistory()
        authOnlyHistory.record(revision: initial.revision, projection: "idle")
        authOnlyHistory.record(revision: loadReceipt.snapshot.revision, projection: "loading")
        authOnlyHistory.record(revision: authReceipt.snapshot.revision, projection: "loading")
        let dupLoading = authOnlyHistory.checkRead(
            "loading",
            reads: ["idle", "loading"],
            since: initial.revision,
            lastReadRevision: loadReceipt.snapshot.revision
        )
        #expect(dupLoading.duplicate)
        #expect(dupLoading.problem != nil)
    }

    @Test func distinctReceiptBeatsFastFailingDriverBeforePolling() async throws {
        let user = try UserID("explorer")
        let request = try ProfileRequest(userID: user)
        let owner = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )

        var receiptHistory = ExplorerDistinctHistory()
        var polledOnlyHistory = ExplorerDistinctHistory()

        let start = owner.snapshot()
        receiptHistory.record(revision: start.revision, projection: ExplorerDistinctRun.phase(start))
        polledOnlyHistory.record(revision: start.revision, projection: ExplorerDistinctRun.phase(start))

        let receipt = try owner.send(.load(request))
        receiptHistory.record(
            revision: receipt.snapshot.revision,
            projection: ExplorerDistinctRun.phase(receipt.snapshot)
        )

        // Wait until the fast-failing driver has committed `.failed` BEFORE polling `owner.snapshot()`,
        // deterministically reproducing the exact race window from `i52.md`.
        for _ in 0 ..< 2000 where ExplorerDistinctRun.phase(owner.snapshot()) != "failed" {
            await Task { @MainActor in }.value
        }
        let afterFail = owner.snapshot()
        #expect(ExplorerDistinctRun.phase(afterFail) == "failed")

        receiptHistory.record(revision: afterFail.revision, projection: ExplorerDistinctRun.phase(afterFail))
        polledOnlyHistory.record(revision: afterFail.revision, projection: ExplorerDistinctRun.phase(afterFail))

        // Receipt-backed oracle accepts transient "loading" and rejects stale "loading" after "failed".
        let validLoading = receiptHistory.checkRead("loading", reads: ["idle"], since: 0, lastReadRevision: 0)
        #expect(!validLoading.duplicate && validLoading.problem == nil)
        let staleAfterFailed = receiptHistory.checkRead(
            "loading",
            reads: ["idle", "failed"],
            since: 0,
            lastReadRevision: afterFail.revision
        )
        #expect(staleAfterFailed.problem != nil)

        // Old polling-only oracle missed rev 1 and falsely rejects "loading".
        let missedTransient = polledOnlyHistory.checkRead("loading", reads: ["idle"], since: 0, lastReadRevision: 0)
        #expect(missedTransient.problem != nil)

        _ = owner.close()
    }

    @Test(.parksCooperativeThread) func distinctRunnerHandlesReproAndAuthCloseScripts() async throws {
        let scripts: [[ExplorerEvent]] = [
            [.readSeq(0), .readSeq(0), .turn, .apply],
            [.readSeq(0), .readSeq(0), .apply],
            [.apply, .edit, .finish(0), .readSeq(0)],
        ]
        for script in scripts {
            let runner = try #require(ExplorerDistinctRun())
            let outcome = await runner.run(script)
            #expect(outcome.violations.isEmpty, "script \(explorerScript(script)) violated: \(outcome.violations)")
        }
    }

    // MARK: - Reports generator & pruning regression controls

    @Test(.parksCooperativeThread) func reportsGeneratorRetainsBothNoncommutingArmOrders() async throws {
        // At depth 0, only work 1 is nameable; neither work-2 arm is enabled yet.
        let root = try #require(ExplorerReportsRun(pruning: true))
        let rootOutcome = await root.run([])
        #expect(!rootOutcome.redundant)
        #expect(rootOutcome.violations.isEmpty)
        #expect(rootOutcome.enabled.contains(.onReport(1, .reconcile(1))))
        #expect(rootOutcome.enabled.contains(.arm(.emission, .reconcile(1))))
        #expect(!rootOutcome.enabled.contains(.onReport(2, .reconcile(1))))
        #expect(!rootOutcome.enabled.contains(.arm(.emission, .reconcile(2))))

        // Order 1 (onReport -> arm(emission)): naming work 1 via `onReport` unlocks `arm(emission, reconcile(2))`.
        // The swapped sequence `arm(emission, reconcile(2)); onReport(1, reconcile(1))` is never generated.
        let afterReport = try #require(ExplorerReportsRun(pruning: true))
        let afterReportOutcome = await afterReport.run([.onReport(1, .reconcile(1))])
        #expect(!afterReportOutcome.redundant)
        #expect(afterReportOutcome.violations.isEmpty)
        #expect(afterReportOutcome.enabled.contains(.arm(.emission, .reconcile(2))))

        let orderA = try #require(ExplorerReportsRun(pruning: true))
        let orderAOutcome = await orderA.run([.onReport(1, .reconcile(1)), .arm(.emission, .reconcile(2))])
        #expect(!orderAOutcome.redundant)
        #expect(orderAOutcome.violations.isEmpty)

        // Order 2 (arm(emission) -> onReport): naming work 1 via `arm(emission)` unlocks `onReport(2, reconcile(1))`.
        // The swapped sequence `onReport(2, reconcile(1)); arm(emission, reconcile(1))` is never generated.
        let afterEmission = try #require(ExplorerReportsRun(pruning: true))
        let afterEmissionOutcome = await afterEmission.run([.arm(.emission, .reconcile(1))])
        #expect(!afterEmissionOutcome.redundant)
        #expect(afterEmissionOutcome.violations.isEmpty)
        #expect(afterEmissionOutcome.enabled.contains(.onReport(2, .reconcile(1))))

        let orderB = try #require(ExplorerReportsRun(pruning: true))
        let orderBOutcome = await orderB.run([.arm(.emission, .reconcile(1)), .onReport(2, .reconcile(1))])
        #expect(!orderBOutcome.redundant)
        #expect(orderBOutcome.violations.isEmpty)
    }

    @Test(.parksCooperativeThread) func reportsPruningRetainsBothSimultaneousFireOrdersAndKeepsIdlePruning()
        async throws
    {
        // Both depth-4 simultaneous-fire orders must be retained under `pruning: true` and run cleanly.
        let simultaneousOrders: [[ExplorerEvent]] = [
            [.stage("rD,run,run"), .onReport(1, .reconcile(1)), .arm(.emission, .reconcile(1)), .emit],
            [.stage("rD,run,run"), .arm(.emission, .reconcile(1)), .onReport(1, .reconcile(1)), .emit],
        ]
        for script in simultaneousOrders {
            let runner = try #require(ExplorerReportsRun(pruning: true))
            let outcome = await runner.run(script)
            #expect(!outcome.redundant, "simultaneous-fire script should not be pruned: \(explorerScript(script))")
            #expect(outcome.violations.isEmpty, "violations: \(outcome.violations)")
            // Stage produces report 1.1; emit fires emission->reconcile(1) (report 1.2) -> onReport->reconcile(1) (report 1.3).
            let reportTrace = outcome.trace.first { $0.hasPrefix("reports ") } ?? ""
            #expect(
                reportTrace.contains("1.1") && reportTrace.contains("1.2") && reportTrace.contains("1.3"),
                "\(outcome.trace)"
            )
        }

        // Existing idle-arm pruning contract: an arm (or adjacent arms) followed by a non-arm event that
        // fires neither hook is still pruned under `pruning: true`.
        let idlePrunedScripts: [[ExplorerEvent]] = [
            [.onReport(1, .reconcile(1)), .edit],
            [.arm(.emission, .edit), .edit],
            [.onReport(1, .reconcile(1)), .arm(.emission, .edit), .edit],
        ]
        for script in idlePrunedScripts {
            let runner = try #require(ExplorerReportsRun(pruning: true))
            let outcome = await runner.run(script)
            #expect(outcome.redundant, "idle arm script should still prune: \(explorerScript(script))")
        }

        // Firing events after an arm are never pruned, and replays (`pruning: false`) never prune.
        let firingEmission = try #require(ExplorerReportsRun(pruning: true))
        let firingEmissionOutcome = await firingEmission.run([.arm(.emission, .edit), .emit])
        #expect(!firingEmissionOutcome.redundant)
        #expect(firingEmissionOutcome.violations.isEmpty)

        let firingReport = try #require(ExplorerReportsRun(pruning: true))
        let firingReportOutcome = await firingReport.run([.onReport(1, .reconcile(1)), .refuse(1)])
        #expect(!firingReportOutcome.redundant)
        #expect(firingReportOutcome.violations.isEmpty)

        let replayIdle = try #require(ExplorerReportsRun(pruning: false))
        let replayIdleOutcome = await replayIdle.run([.onReport(1, .reconcile(1)), .edit])
        #expect(!replayIdleOutcome.redundant)
        #expect(replayIdleOutcome.violations.isEmpty)
    }
}
