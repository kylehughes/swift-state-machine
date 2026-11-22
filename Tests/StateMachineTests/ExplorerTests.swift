import Foundation
import Testing

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
        for configuration in configurations(full: true) {
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
