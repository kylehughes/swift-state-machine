import Foundation
import StateMachine
import Testing
import os

// The schedule explorer for the presentation layer. It enumerates every short sequence of events
// over a small alphabet, runs each against the real presentation classes from a fresh state with
// fake one-slot hosts whose cancellations the harness parks and releases, and checks the
// presentations' written invariants after every step and at quiescence. Every step is forced by an
// explicit happens-before edge, whether a synchronous call, a semaphore signaled by a worker, or a
// main-actor job enqueued behind the jobs it waits for. Timeouts only fail a stuck run.
//
// Environment variables:
// - `EXPLORER_FULL=1` runs the exhaustive tier (every slice at its full depth). `EXPLORER_TIER=standard`
//   runs the same slices one step shallower. `EXPLORER_DEPTH` overrides the slices' depths,
//   `EXPLORER_RUNTIME_DEPTH` overrides the raw owner's depth, and `EXPLORER_HASH=1` enables state hashing.
// - `EXPLORER_COVERAGE=path` writes the interruption matrix's reached cells (`Tests/ScheduleExplorer.md`).
// - `EXPLORER_REPLAY="SnapshotObservableObject: observe(A); hostCancel(A); dropMain"` replays one
//   script with a trace. `EXPLORER_FAMILIES` (`core,second,async,combine,reentrant`) selects its alphabet.
// - `EXPLORER_FAILURES=path` appends every violation found to that file.
// - `EXPLORER_SLICES="core,second:5;core,async:4"` replaces the slices and their full depths.
//   `EXPLORER_KIND` limits a run to one class or owner, and `EXPLORER_TEARDOWN_DEPTH` sets the owner depth.
// - `EXPLORER_SMOKE=0` skips the smoke configuration.
// - `EXPLORER_LIST_CONFIGS=1` prints `full()`'s planned configurations without running them, and
//   `EXPLORER_CONFIG_INDEX=N` runs only that single configuration from `full()`.

private let environment = ProcessInfo.processInfo.environment

private func families(_ text: String?) -> ExplorerFamilies {
    guard let text else { return [.core, .second, .async, .combine, .reentrant] }
    var result: ExplorerFamilies = []
    for name in text.split(separator: ",") {
        switch name {
        case "core": result.insert(.core)
        case "second": result.insert(.second)
        case "async": result.insert(.async)
        case "combine": result.insert(.combine)
        case "reentrant": result.insert(.reentrant)
        case "pairs": result.insert(.pairs)
        case "isolated": result.insert(.isolated)
        case "callback": result.insert(.callback)
        case "lease": result.insert(.lease)
        case "triples": result.insert(.triples)
        case "workers": result.insert(.workers)
        case "followers": result.insert(.followers)
        case "cancelDelivery": result.insert(.cancelDelivery)
        case "clocks": result.insert(.clocks)
        case "counts": result.insert(.counts)
        case "reconcile": result.insert(.reconcile)
        case "resume": result.insert(.resume)
        case "demand": result.insert(.demand)
        case "selection": result.insert(.selection)
        case "sites": result.insert(.sites)
        case "copies": result.insert(.copies)
        case "chains": result.insert(.chains)
        case "matrix": result.insert(.matrix)
        case "elsewhere": result.insert(.elsewhere)
        case "images": result.insert(.images)
        default: break
        }
    }
    return result
}

/// Whether the standard tier runs, executing every slice of the exhaustive tier (including
/// full-mode-only slices) one step shallower without dropping below its smoke depth.
private let standardTier = environment["EXPLORER_TIER"] == "standard"
private func tiered(_ deep: Int, smoke: Int) -> Int { standardTier ? max(deep - 1, smoke) : deep }

/// Builds the configurations for a run, pairing each class with tractable slices of the alphabet.
private func configurations(full: Bool) -> [ExplorerConfiguration] {
    let override = environment["EXPLORER_DEPTH"].flatMap(Int.init)
    let hashing = environment["EXPLORER_HASH"] == "1"
    var slices: [(ExplorerFamilies, smoke: Int, full: Int)] = [
        ([.core], 3, 6),
        ([.core, .second], 3, 5),
        ([.core, .async], 2, 4),
        ([.core, .combine], 2, 5),
        ([.core, .reentrant], 2, 4),
        ([.core, .second, .async, .reentrant], 2, 3),
        ([.core, .combine, .reentrant], 2, 4),
        ([.core, .async, .reentrant, .pairs], 1, 2),
        // Not fully forced (the island and actor-host calls run on the cooperative pool): full mode only.
        ([.core, .async, .isolated], 0, 3),
        ([.core, .callback, .reentrant], 2, 4),
        ([.core, .lease, .reentrant], 2, 4),
        ([.core, .second, .workers], 2, 5),
        // Three events in one callback (the `triples` family).
        ([.core, .async, .reentrant, .pairs, .triples], 1, 2),
        // The follower hand-off slice to depth 6 (the `followers` family).
        ([.core, .async, .second, .reentrant, .pairs, .followers], 3, 6),
        // Driving: a host that delivers from inside each cancellation, the disposal path's included, with
        // a smoke depth of zero; passive hosts offer the event in `core`.
        ([.core, .cancelDelivery], 0, 6),
        // Independent revision clocks per host, equal-revision offers (E1).
        ([.core, .second, .clocks], 3, 5),
        ([.core, .second, .clocks, .combine], 3, 5),
        // Driving: refused, occupied and closed creation, and `resumeObserving()` (E2).
        ([.core, .resume], 3, 6),
        ([.core, .combine, .resume], 2, 4),
        ([.core, .reentrant, .resume], 2, 4),
        // Combine demand: zero, finite, returned from the callback, an older subscription (E9).
        ([.core, .combine, .demand], 2, 4),
        ([.core, .combine, .demand, .reentrant], 1, 3),
        // Out-of-order closure resumption, the oldest follower, a direct call's task (E5, E6).
        ([.core, .async, .selection], 2, 4),
        ([.core, .second, .async, .selection], 2, 3),
        // Client callback sites: host calls, subscription before demand, completion, destructors.
        ([.core, .reentrant, .sites], 2, 3),
        ([.core, .combine, .reentrant, .sites], 1, 3),
        ([.core, .reentrant, .resume, .sites], 1, 3),
        // Two armed hooks, and a hook that arms another (E15).
        ([.core, .reentrant, .chains], 1, 3),
        // Driving: a hook inside a hook and the same hook revisited, beside `resumeObserving()`.
        ([.core, .reentrant, .resume, .chains], 1, 4),
        // Demand and cancellation off the main actor, and the publisher's delivery decision (E10).
        ([.elsewhere], 3, 5),
        // The interruption matrix (`Tests/ScheduleExplorer.md`, "Interruption matrix coverage").
        ([.matrix], 2, 4),
    ]
    // `EXPLORER_SLICES="core,second:5;core,async:4"` replaces the slices and their full depths.
    if let text = environment["EXPLORER_SLICES"] {
        slices = text.split(separator: ";")
            .compactMap { entry in
                let parts = entry.split(separator: ":")
                guard parts.count == 2, let depth = Int(parts[1]) else { return nil }
                return (families(String(parts[0])), depth, depth)
            }
    }
    let kinds =
        environment["EXPLORER_KIND"].flatMap(ExplorerPassiveKind.init(rawValue:)).map { [$0] }
        ?? ExplorerPassiveKind.allCases
    var result: [ExplorerConfiguration] = []
    for kind in kinds where kind.isOwnerSlice {
        // Owners whose deliveries cross executors the harness does not order are full-mode only.
        if !full, !kind.isDeterministic { continue }
        if kind == .runtimeShared {
            // Counts to depth 3 reach two registrations and a read with four changes inside it;
            // reconciliation runs to depth 5 in the deeper tiers (depth 6 with `emit` is 487,000 sequences
            // and 12 minutes: `EXPLORER_RUNTIME_DEPTH=6`).
            let depths = environment["EXPLORER_RUNTIME_DEPTH"].flatMap(Int.init)
            result.append(ExplorerConfiguration(kind: kind, families: [.counts], depth: depths ?? 3))
            // A stage and up to three events after it in the exhaustive tier, two in the standard one.
            result.append(
                ExplorerConfiguration(
                    kind: kind,
                    families: [.reconcile],
                    depth: full ? (depths ?? tiered(4, smoke: 2)) : 2
                )
            )
            result.append(
                ExplorerConfiguration(
                    kind: kind,
                    families: [.copies],
                    depth: full ? (depths ?? tiered(6, smoke: 4)) : 4
                )
            )
            // Completions behind a held report handler: their admission runs on the owner's workers, which
            // turns do not order, so the deeper tiers only.
            if full {
                result.append(
                    ExplorerConfiguration(kind: kind, families: [.images], depth: depths ?? tiered(5, smoke: 3))
                )
            }
            continue
        }
        let depth = full ? (environment["EXPLORER_TEARDOWN_DEPTH"].flatMap(Int.init) ?? tiered(5, smoke: 3)) : 3
        result.append(ExplorerConfiguration(kind: kind, families: [.core], depth: depth))
    }
    for kind in kinds where !kind.isOwnerSlice {
        for (slice, smoke, deep) in slices {
            if slice.contains(.combine), !kind.isCombine { continue }
            let passiveOnly: ExplorerFamilies = [
                .second, .async, .isolated, .callback, .lease, .workers, .followers, .clocks, .selection,
            ]
            if kind.isDriving, !slice.isDisjoint(with: passiveOnly) { continue }
            if !kind.isDriving, slice.contains(.cancelDelivery) || slice.contains(.resume) { continue }
            // Only the driving Combine class publishes through a presentation publisher the fake host drives.
            if slice.contains(.elsewhere), kind != .drivingCombine { continue }
            if slice.contains(.combine), slice.contains(.sites), !kind.isCombine { continue }
            let depth = full ? (override ?? tiered(deep, smoke: smoke)) : smoke
            if depth == 0 { continue }
            result.append(
                ExplorerConfiguration(kind: kind, families: slice, depth: depth, stateHashing: full && hashing)
            )
        }
    }
    return result
}

// A sequence can park a cooperative-pool thread. `explore` takes turns at the process-wide exclusion of
// such tests between sequences, while replays run their scripts directly and hold it throughout.
@MainActor @Suite(.serialized) struct ExplorerTests {
    // Bounded enough for every debug run. `EXPLORER_SMOKE=0` skips it. The opt-in configurations below
    // return at once without their variable, so a plain run reports no skipped test.
    @Test(.timeLimit(.minutes(2))) func smoke() async {
        guard environment["EXPLORER_SMOKE"] != "0" else { return }
        for configuration in configurations(full: false) {
            let report = await explore(configuration)
            print("EXPLORER \(report.summary)")
            for finding in report.findings {
                Issue.record(
                    "\(configuration.kind.rawValue): \(finding.violation) after \(explorerScript(finding.sequence))"
                )
            }
        }
        explorerWriteCoverage()
    }

    // I36's count catches an overrun and counts each registration on its own: a fake that
    // applies 33 elements of one registration in one turn trips it, 32 of one registration and then 32
    // of another in the same turn do not, and a turn's end or a read on another task starts a new count.
    @Test func turnBoundSelfCheck() {
        var budget = ExplorerTurnBudget()
        let allowance = ExplorerTurnBudget.allowance
        var trips = 0
        var opened: Int?
        for index in 0 ..< allowance + 1 {
            let read = budget.read(registration: 1, task: 7)
            if index == 0 { opened = read.opened }
            if read.exceeded { trips += 1 }
        }
        #expect(trips == 1)

        var separate = ExplorerTurnBudget()
        for registration in [2, 3] {
            for _ in 0 ..< allowance { #expect(!separate.read(registration: registration, task: 7).exceeded) }
        }
        #expect(separate.read(registration: 3, task: 7).exceeded)

        #expect(opened != nil)
        budget.endTurn(registration: 1, batch: opened ?? 0)
        for _ in 0 ..< allowance { #expect(!budget.read(registration: 1, task: 7).exceeded) }
        for _ in 0 ..< allowance { #expect(!budget.read(registration: 1, task: 8).exceeded) }
        #expect(budget.read(registration: 1, task: 8).exceeded)
    }

    @Test func reportsDistinguishSuccessorTickets() throws {
        let scope = RuntimeScopeID(kind: 1)
        var engine = ExplorerRuntimeEngine(0, scopes: [scope], limits: try Limits())
        let candidate = try ExplorerRuntimeEngine.prepare(
            on: engine.snapshot,
            next: 1,
            plan: .init(starts: [
                .init(.init(kind: 5, scope: scope), descriptor: 5),
                .init(.init(kind: 6, scope: scope), descriptor: 6),
            ])
        )
        _ = engine.commit(candidate)
        let batch = try #require(engine.drain(limit: 1).first)
        let log = ExplorerReportsLog()
        var ledger = ExplorerReportsHost.Ledger()
        for command in batch.commands {
            guard case .start(let work) = command else { continue }
            let outcome = ExplorerReportsOutcome(ticket: work.ticket, accepts: false, serial: work.descriptor)
            log.offered(outcome)
            guard case .pending(let id) = ledger.retain(outcome, for: work.ticket, in: &engine),
                case .claimed(let attempt) = ledger.claim(id, in: &engine)
            else {
                Issue.record("Expected each successor outcome to be retained and claimed")
                return
            }
            _ = log.prepare(attempt.outcome, model: attempt.snapshot.model)
            log.left()
            _ = ledger.finish(attempt, preparation: .failure(.preparation(ExplorerRefusal())), in: &engine)
        }
        #expect(ledger.pending.map(\.outcome.serial) == [5, 6])
        for pending in ledger.pending.reversed() { log.report(pending) }
        log.checkSettled(ledger.pending)
        #expect(log.state.withLock { $0.violations }.isEmpty)
    }

    @Test func reportsWaitForReleasedExecutionsAndTheirDeliveries() throws {
        let scope = RuntimeScopeID(kind: 1)
        let log = ExplorerReportsLog()
        let owner = ExplorerReportsHost(
            manual: 0,
            scopes: [scope],
            limits: .default,
            ticket: { $0.ticket },
            prepare: { attempt in
                _ = log.prepare(attempt.outcome, model: attempt.snapshot.model)
                log.left()
                return .failure(.preparation(ExplorerRefusal()))
            }
        )
        let candidate = try ExplorerRuntimeEngine.prepare(
            on: owner.snapshot(),
            next: 1,
            plan: .init(starts: [.init(.init(kind: 5, scope: scope), descriptor: 5)])
        )
        _ = owner.commit(candidate)
        func settlement(drainerHeld: Bool = false, driversReleased: Bool = true) -> ExplorerReportsLog.Settlement {
            log.settlement(of: owner, drainerHeld: drainerHeld, driversReleased: driversReleased)
        }
        #expect(settlement(drainerHeld: true) == .settled)
        #expect(settlement() == .working)
        guard case .start(let work) = owner.drainCommands(limit: 1).first?.commands.first else {
            Issue.record("Expected a drained start command")
            return
        }
        #expect(settlement(driversReleased: false) == .settled)
        #expect(settlement() == .working)
        _ = owner.acknowledge(work.ticket, skipped: false)
        #expect(settlement() == .working)
        let outcome = ExplorerReportsOutcome(ticket: work.ticket, accepts: false, serial: 1)
        log.offered(outcome)
        _ = owner.deliver(outcome)
        #expect(settlement() == .awaitingReports)
        let pending = try #require(owner.pendingCompletions().first)
        _ = owner.discardPending(id: pending.id)
        #expect(owner.pendingCompletions().isEmpty)
        #expect(settlement() == .awaitingReports)
        log.report(pending)
        #expect(settlement() == .settled)
    }

    @Test(.parksCooperativeThread) func refusedApplyBeforeClosedSourceHandoff() async throws {
        var kinds: [ExplorerPassiveKind] = [.combine]
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            kinds.append(.observation)
        }
        for kind in kinds {
            let configuration = ExplorerConfiguration(kind: kind, families: [.core, .callback, .reentrant], depth: 4)
            let outcome = try #require(
                await explorerRun(configuration, [.observe(0), .applyBelow, .close, .observe(2)])
            )
            #expect(outcome.violations.isEmpty)
        }
    }

    // I35 regression and controls:
    // 1. After `observeAsyncHeld(A); factoryReturn; dropElsewhere`, the async observation has returned
    //    on the main actor and the presentation is deallocated, so `stopCustody` is not enabled and
    //    replaying it does not falsely attribute an uninvoked stop to `stopObserving()`.
    // 2. While an async call still retains the presentation after `dropElsewhere`, `stopCustody` stays
    //    enabled, runs `stopObserving()` against that live receiver, and immediately checks I35.
    @Test(.parksCooperativeThread) func passiveStopCustodyAndWeakReceiverSchedules() async throws {
        var kinds: [ExplorerPassiveKind] = [.combine]
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            kinds.append(.observation)
        }
        for kind in kinds {
            let configuration = ExplorerConfiguration(kind: kind, families: [.core, .async], depth: 4)
            let afterDrop = try #require(
                await explorerRun(configuration, [.observeAsyncHeld(0), .factoryReturn, .dropElsewhere])
            )
            #expect(afterDrop.violations.isEmpty, "\(afterDrop.violations)")
            #expect(!afterDrop.enabled.contains(.stopCustody))

            let replayDroppedStop = try #require(
                await explorerRun(configuration, [.observeAsyncHeld(0), .factoryReturn, .dropElsewhere, .stopCustody])
            )
            #expect(replayDroppedStop.violations.isEmpty, "\(replayDroppedStop.violations)")
            #expect(!replayDroppedStop.trace.contains("custody window"))

            let weakHeldParked = try #require(
                await explorerRun(configuration, [.observeAsyncHeld(0), .dropElsewhere])
            )
            #expect(weakHeldParked.violations.isEmpty, "\(weakHeldParked.violations)")
            #expect(weakHeldParked.enabled.contains(.stopCustody))

            let weakHeldStop = try #require(
                await explorerRun(configuration, [.observeAsyncHeld(0), .dropElsewhere, .stopCustody])
            )
            #expect(weakHeldStop.violations.isEmpty, "\(weakHeldStop.violations)")

            let weakFollower = try #require(
                await explorerRun(configuration, [.followSeq(0), .dropElsewhere])
            )
            #expect(weakFollower.violations.isEmpty, "\(weakFollower.violations)")
            #expect(weakFollower.enabled.contains(.stopCustody))

            let weakFollowerStop = try #require(
                await explorerRun(configuration, [.followSeq(0), .dropElsewhere, .stopCustody])
            )
            #expect(weakFollowerStop.violations.isEmpty, "\(weakFollowerStop.violations)")
            // Verify `stopCustody` genuinely ran `stopObserving()` on the weakly retained receiver,
            // entered H8's custody window, and freed registration #1 synchronously before quiesce.
            let custodyIndex = try #require(weakFollowerStop.trace.firstIndex(of: "custody window"))
            let freedIndex = try #require(weakFollowerStop.trace.firstIndex(of: "#1 freed"))
            let quiesceIndex = try #require(weakFollowerStop.trace.firstIndex(of: "quiesce"))
            #expect(freedIndex < custodyIndex)
            #expect(custodyIndex < quiesceIndex)
        }
    }

    // I14 regression and controls:
    // 1. Replaying `observe(A); observe(A); deliver(A); turn; turn; finish(A)` settles cleanly.
    // 2. A continuation/off-actor completion released strictly after the 30-turn fast-path budget still
    //    settles within the bounded watchdog (guaranteeing the fallback path is exercised).
    // 3. A permanent disagreement expires cleanly at the bounded watchdog so genuine I14 defects fail.
    @Test(.parksCooperativeThread) func passiveSettlementWatchdogAndTerminalFinishSchedule() async throws {
        var kinds: [ExplorerPassiveKind] = [.combine]
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            kinds.append(.observation)
        }
        for kind in kinds {
            let configuration = ExplorerConfiguration(kind: kind, families: [.core], depth: 6)
            let outcome = try #require(
                await explorerRun(configuration, [.observe(0), .observe(0), .deliver(0), .turn, .turn, .finish(0)])
            )
            #expect(outcome.violations.isEmpty, "\(outcome.violations)")
        }

        // Delayed settlement control: launch the detached completion only on the first fallback step
        // (`fastHops + 1`), after every fast-path turn and check has returned false, with no timer.
        let gate = OSAllocatedUnfairLock(initialState: false)
        var steps = 0
        let fastHops = 30
        let settledDelayed = await explorerAwaitSettled(
            fastHops: fastHops,
            timeout: .seconds(2),
            step: {
                steps += 1
                await Task { @MainActor in }.value
                if steps == fastHops + 1 {
                    Task.detached { gate.withLock { $0 = true } }
                }
            },
            until: { gate.withLock { $0 } }
        )
        #expect(settledDelayed)
        #expect(steps > fastHops)

        // Permanent disagreement negative control: watchdog must expire and return false.
        let started = ContinuousClock.now
        let settledPermanent = await explorerAwaitSettled(
            fastHops: 5,
            timeout: .milliseconds(40),
            step: { await Task { @MainActor in }.value },
            until: { false }
        )
        #expect(!settledPermanent)
        #expect(started.duration(to: .now) >= .milliseconds(35))
    }

    // Scoped deterministic schedules for `SnapshotSequence.wait(deadline:clock:where:)` against
    // the explorer's one-slot fake host (`ExplorerHost`) and `ExplorerShot` lifetime/slot checks
    // (I2, I15, I41): deadline firing while a host cancellation is parked on a worker, a final
    // offer and closure delivered synchronously inside the initial non-matching predicate with an
    // expired deadline, and a final offer racing with deadline expiry.
    @Test(.parksCooperativeThread) func boundedWaitRegistrationAndFinalOfferSchedules() async throws {
        // 1. Deadline expires while a host cancellation is parked on a worker (I2, I15).
        do {
            let world = ExplorerWorld()
            world.state.withLock { $0.offMainExempt = true }
            let host = ExplorerHost(0, world)
            let clock = ManualTestClock()
            world.setLatestAttempt(1)
            world.setContext(.call(attempt: 1))
            let sequence = try host.sequence(seeded: true)
            world.setContext(.spontaneous)
            let id = try #require(world.slot(of: 0))

            let waitTask = Task { @MainActor in
                await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { _ in false }
            }
            await clock.waitUntilSleeping()
            // Park host cancellation on a worker so the slot stays occupied while the deadline
            // triggers `cancel()` on exit; any unread value waits for the slot to free (I2).
            #expect(host.beginCancelling(id))
            clock.advance(by: .seconds(5))
            let result = await waitTask.value
            if case .timedOut = result {} else { Issue.record("Expected .timedOut, got \(result)") }
            #expect(host.finishCancelling(id))
            host.forget()
            for _ in 0 ..< 2000 where !world.allUnfreed.isEmpty || !world.liveValues().isEmpty {
                await Task { @MainActor in }.value
            }
            #expect(world.violations.isEmpty, "\(world.violations)")
            #expect(world.allUnfreed.isEmpty)
            #expect(world.liveValues().isEmpty)
        }

        // 2. Initial non-matching predicate delivers a final offer and finishes before the deadline
        // expires: the final offer must still be evaluated and matched (I41), and the slot freed.
        do {
            let world = ExplorerWorld()
            world.state.withLock { $0.offMainExempt = true }
            let host = ExplorerHost(0, world)
            let clock = ManualTestClock()
            world.setLatestAttempt(1)
            world.setContext(.call(attempt: 1))
            let sequence = try host.sequence(seeded: true)
            world.setContext(.spontaneous)
            let id = try #require(world.slot(of: 0))

            var firstRevision: UInt64?
            var finalRevision: UInt64?
            let matchedRevision: UInt64? = await {
                let result = await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { shot in
                    if firstRevision == nil {
                        firstRevision = shot.revision
                        host.deliver(to: id)
                        finalRevision = world.state.withLock { $0.revision }
                        host.finish(id)
                        clock.advance(by: .seconds(5))
                        return false
                    }
                    return shot.revision == finalRevision
                }
                if case .matched(let matched) = result { return matched.revision }
                return nil
            }()
            #expect(matchedRevision != nil && matchedRevision == finalRevision)
            #expect(clock.totalSleepsStarted == 0)
            host.forget()
            for _ in 0 ..< 2000 where !world.allUnfreed.isEmpty || !world.liveValues().isEmpty {
                await Task { @MainActor in }.value
            }
            #expect(world.violations.isEmpty, "\(world.violations)")
            #expect(world.allUnfreed.isEmpty)
            #expect(world.liveValues().isEmpty)
        }

        // 3. Host finishes with a non-matching final offer before the deadline fires: `.ended`
        // wins over `.timedOut`, the final element is still read (I41), and cleanup frees the slot.
        do {
            let world = ExplorerWorld()
            world.state.withLock { $0.offMainExempt = true }
            let host = ExplorerHost(0, world)
            let clock = ManualTestClock()
            world.setLatestAttempt(1)
            world.setContext(.call(attempt: 1))
            let sequence = try host.sequence(seeded: true)
            world.setContext(.spontaneous)
            let id = try #require(world.slot(of: 0))

            var seen: [UInt64] = []
            let waitTask = Task { @MainActor in
                await sequence.wait(deadline: clock.now.advanced(by: .seconds(5)), clock: clock) { shot in
                    seen.append(shot.revision)
                    return false
                }
            }
            await clock.waitUntilSleeping()
            host.deliver(to: id)
            let deliveredRevision = world.state.withLock { $0.revision }
            host.finish(id)
            clock.advance(by: .seconds(5))
            let result = await waitTask.value
            if case .ended = result {} else { Issue.record("Expected .ended, got \(result)") }
            #expect(seen.contains(deliveredRevision))
            host.forget()
            for _ in 0 ..< 2000 where !world.allUnfreed.isEmpty || !world.liveValues().isEmpty {
                await Task { @MainActor in }.value
            }
            #expect(world.violations.isEmpty, "\(world.violations)")
            #expect(world.allUnfreed.isEmpty)
            #expect(world.liveValues().isEmpty)
        }
    }

    // Each invariant that guards a past defect class reports a planted defect and accepts its control
    // (`ExplorerSelfCheck.swift`).
    @Test func selfCheck() {
        let checks = explorerSelfChecks()
        for check in checks where !check.trusted {
            Issue.record(
                "\(check.invariant.rawValue) is not trusted: \(check.defect) (planted reported \(check.planted), control accepted \(check.control))"
            )
        }
        print("EXPLORER self-check: \(checks.count) planted defects, \(checks.filter(\.trusted).count) trusted")
    }

    // The exhaustive tier (`EXPLORER_FULL=1`), or the standard tier (`EXPLORER_TIER=standard`).
    @Test func full() async {
        guard environment["EXPLORER_FULL"] == "1" || standardTier else { return }
        let planned = configurations(full: true)
        if let listFlag = environment["EXPLORER_LIST_CONFIGS"] {
            guard listFlag == "1", environment["EXPLORER_CONFIG_INDEX"] == nil else {
                Issue.record("Invalid EXPLORER_LIST_CONFIGS=\(listFlag) or conflicting EXPLORER_CONFIG_INDEX")
                return
            }
            print("EXPLORER PLAN count=\(planned.count)")
            for (index, configuration) in planned.enumerated() {
                print("EXPLORER PLAN \(index) \(configuration)")
            }
            return
        }
        let selected: [ExplorerConfiguration]
        if let rawIndex = environment["EXPLORER_CONFIG_INDEX"] {
            guard let index = Int(rawIndex), String(index) == rawIndex, planned.indices.contains(index) else {
                Issue.record("Invalid EXPLORER_CONFIG_INDEX=\(rawIndex) for \(planned.count) configurations")
                return
            }
            selected = [planned[index]]
        } else {
            selected = planned
        }
        for configuration in selected {
            let report = await explore(configuration)
            print("EXPLORER \(report.summary)")
            for finding in report.findings {
                Issue.record(
                    "\(configuration.kind.rawValue): \(finding.violation) after \(explorerScript(finding.sequence))"
                )
            }
        }
        explorerWriteCoverage()
    }

    // `EXPLORER_REPLAY_FILE=path` replays every `id|Class: script` line of that file in one process and
    // prints one result line per script. Violations are expected there, so none fails the test.
    @Test(.parksCooperativeThread) func replayFile() async throws {
        guard let path = environment["EXPLORER_REPLAY_FILE"] else { return }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        for line in lines where line.contains("|") {
            let fields = line.split(separator: "|", maxSplits: 1)
            let parts = fields[1].split(separator: ":", maxSplits: 1)
            // `Class[family,family]: script` selects the families, while plain `Class: script` takes the default.
            let head = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let named = head.split(separator: "[", maxSplits: 1)
            let chosen = named.count == 2 ? families(String(named[1].dropLast())) : families(nil)
            guard parts.count == 2, let kind = ExplorerPassiveKind(rawValue: String(named[0])),
                let events = explorerParse(String(parts[1]))
            else {
                print("EXPLORER CALIBRATION \(fields[0]) | unparsed: \(fields[1])")
                continue
            }
            let configuration = ExplorerConfiguration(kind: kind, families: chosen, depth: events.count)
            guard let outcome = await explorerRun(configuration, events) else { continue }
            let found = outcome.violations.map { "\($0.invariant.rawValue) \($0.detail)" }.joined(separator: "; ")
            print("EXPLORER CALIBRATION \(fields[0]) | \(fields[1]) | \(found.isEmpty ? "clean" : found)")
        }
    }

    @Test(.parksCooperativeThread) func replay() async throws {
        guard let text = environment["EXPLORER_REPLAY"] else { return }
        let parts = text.split(separator: ":", maxSplits: 1)
        let kind = try #require(ExplorerPassiveKind(rawValue: String(parts[0]).trimmingCharacters(in: .whitespaces)))
        let script = parts.count > 1 ? String(parts[1]) : ""
        let events = try #require(explorerParse(script), "unrecognized event in \(script)")
        let configuration = ExplorerConfiguration(
            kind: kind,
            families: families(environment["EXPLORER_FAMILIES"]),
            depth: events.count
        )
        print("EXPLORER replay \(kind.rawValue): \(explorerScript(events))")
        let outcome = try #require(await explorerRun(configuration, events, verbose: true))
        for violation in outcome.violations { print("EXPLORER violation \(violation)") }
        #expect(outcome.violations.isEmpty, "\(outcome.violations)")
    }
}
