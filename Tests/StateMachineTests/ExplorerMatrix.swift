import Foundation
import os

// The interruption matrix: every interrupting event, armed at every armable callback
// site, during each phase of an observation, for each class and passive form. The `matrix` family's
// alphabet reaches the cells; each run records the cells its armed callbacks actually reached, and
// `EXPLORER_COVERAGE=path` writes the set at the end of a test, which `Scripts/explorer-coverage.py`
// aggregates into the coverage table of `Tests/ScheduleExplorer.md`.

/// The cells reached so far in this process: `class|form|site|interrupt|phase`.
let explorerCoverage = OSAllocatedUnfairLock<Set<String>>(initialState: [])

/// Records that an armed callback at `site` ran `event` during `phase`, if `event` interrupts.
func explorerCover(
    kind: ExplorerPassiveKind,
    form: String,
    host: Int,
    site: ExplorerHook,
    event: ExplorerEvent,
    phase: String
) {
    guard let interrupt = explorerInterrupt(event, host: host) else { return }
    let cell = "\(kind.rawValue)|\(form)|\(site.rawValue)|\(interrupt)|\(phase)"
    explorerCoverage.withLock { _ = $0.insert(cell) }
}

/// Writes the recorded cells to the file `EXPLORER_COVERAGE` names, one per line, if set.
func explorerWriteCoverage() {
    let windows = explorerL1Windows.withLock { $0 }
    if windows > 0 { print("EXPLORER capacity-conflict report windows reached: \(windows)") }
    guard let path = ProcessInfo.processInfo.environment["EXPLORER_COVERAGE"] else { return }
    let lines = explorerCoverage.withLock { $0.sorted() }.joined(separator: "\n") + "\n"
    try? lines.write(toFile: path, atomically: true, encoding: .utf8)
}

/// I51: a presentation publishes `isObserving` only when its observing state changes (UI-004), so a
/// property-precise observer, the `$isObserving` sink or an Observation tracker of `isObserving` alone,
/// is called an odd number of times in a step exactly when the step changed the value.
@MainActor func explorerCheckReportParity(_ world: ExplorerWorld, before: Bool?, after: Bool?, reports: Int) {
    guard let before, let after else { return }
    if (reports % 2 == 1) != (before != after) {
        world.violate(
            .propertyInvalidation,
            "isObserving went from \(before) to \(after) across a step that reported \(reports) changes of it"
        )
    }
}

/// The interruption an armed event makes, or `nil` for an event that interrupts nothing: observing the
/// host the current observation registered with again, or another source, replaces it.
func explorerInterrupt(_ event: ExplorerEvent, host: Int) -> String? {
    switch event {
    case .stop: "stop"
    case .close: "close"
    case .dropMain: "drop on main"
    case .dropElsewhere: "drop off main"
    case .resume: "resume"
    case .observe(let other): other == host ? "observe again" : "replace"
    case .then(let first, _): explorerInterrupt(first, host: host)
    default: nil
    }
}

/// The passive form a host's synchronous observation uses.
func explorerForm(host: Int) -> String {
    switch host {
    case 0, 1: "shared host"
    case 2: "MainActor host"
    default: "isolated host"
    }
}

/// The phase a top-level event puts the presentation in while its callbacks run.
func explorerPhase(_ event: ExplorerEvent?) -> String {
    switch event {
    case .observe, .observeFrom, .observeAsync, .observeAsyncNow, .observeAsyncHeld, .observeAsyncFinished,
        .observeSeq, .followSeq, .followAsync, .observeClaimed, .resume, .factoryReturn:
        "registering"
    case .stop, .close, .dropMain, .dropElsewhere, .dropAfterJob, .finish, .hostCancel, .hostCancelMain,
        .hostCancelReturn:
        "ending"
    case .createRefusing, .createOccupied, .createClosed:
        "creation"
    default:
        "steady"
    }
}
