import Foundation
import os

// The interruption matrix: every interrupting event, armed at every armable callback
// site, during each phase of an observation, for each class and passive form. The `matrix` family's
// alphabet reaches the cells; each run records the cells its armed callbacks actually reached, and
// `EXPLORER_COVERAGE=path` writes the set at the end of a test, which `Scripts/explorer-coverage.py`
// aggregates into the coverage table of `Tests/ScheduleExplorer.md`.

/// The cells reached so far in this process:
/// `class|form|site|interrupt|phase|attempt|registration|origin`.
let explorerCoverage = OSAllocatedUnfairLock<Set<String>>(initialState: [])

/// Where an armed callback ran, read from the registrations before its event: the form and host of the
/// observation it concerns, the lifecycle phase of that observation, whether its attempt is the current
/// one, the registration's state, and the top-level event the callback runs under.
struct ExplorerMatrixCell {
    var form: String
    var host: Int
    var phase: String
    var attempt: String
    var registration: String
    var origin: String

    /// Reads the coordinates from the world.
    ///
    /// The registration a callback concerns is the one being
    /// cancelled at a cancellation site, and otherwise the newest one still holding a slot. Its phase is
    /// ending while a registration of an ended observation still holds its slot or is being cancelled;
    /// registering during a registering call, or while the newest registration is live but not yet
    /// reported, which a deferred registering callback during `turn` is; and steady otherwise.
    static func read(
        _ world: ExplorerWorld,
        site: ExplorerHook,
        top: ExplorerEvent?,
        ended: Set<Int> = [],
        form: (Int?) -> (String, Int)
    ) -> ExplorerMatrixCell {
        let (registrations, latest, letGo, context, lastReport) = world.state.withLock { state in
            (
                Array(state.registrations.values.filter { !$0.withheld }), state.latestAttempt, state.letGo,
                state.context, state.reports.last
            )
        }
        let ending = registrations.filter {
            $0.phase != .freed
                && ($0.phase == .cancelling || $0.hostEnded || letGo.contains($0.attempt ?? -1)
                    || ended.contains($0.id))
        }
        let holding = registrations.filter { $0.phase != .freed }
        let concerned =
            (site == .onCancel ? ending.max { $0.id < $1.id } : nil) ?? holding.max { $0.id < $1.id }
            ?? registrations.max { $0.id < $1.id }
        let registeringCall = if case .call = context { true } else { false }
        let unconfirmed =
            concerned.map {
                $0.phase == .active && !$0.finished && !letGo.contains($0.attempt ?? -1) && !ended.contains($0.id)
                    && lastReport != true
            } ?? false
        let topPhase = explorerPhase(top)
        let phase =
            if site == .onCancel, !ending.isEmpty {
                "ending"
            } else if registeringCall || topPhase == "registering" || unconfirmed {
                "registering"
            } else if topPhase == "ending" || !ending.isEmpty {
                "ending"
            } else {
                "steady"
            }
        let (formName, host) = form(concerned?.attempt)
        return ExplorerMatrixCell(
            form: formName,
            host: host,
            phase: phase,
            attempt: concerned.map { $0.attempt == latest ? "current" : "earlier" } ?? "none",
            registration: concerned.map { "\($0.phase)\($0.hostEnded ? "+hostEnded" : "")" } ?? "none",
            origin: top.map { String($0.description.prefix { $0 != "(" }) } ?? "none"
        )
    }
}

/// Records that an armed callback ran `event` at `site` in `cell`, if `event` interrupts and running it
/// changed what the presentation or its registrations hold.
func explorerCover(
    kind: ExplorerPassiveKind,
    cell: ExplorerMatrixCell,
    site: ExplorerHook,
    event: ExplorerEvent,
    changed: Bool
) {
    guard changed, let interrupt = explorerInterrupt(event, host: cell.host) else { return }
    let line =
        "\(kind.rawValue)|\(cell.form)|\(site.rawValue)|\(interrupt)|\(cell.phase)|\(cell.attempt)|\(cell.registration)|\(cell.origin)"
    explorerCoverage.withLock { _ = $0.insert(line) }
}

/// Writes the recorded cells to the file `EXPLORER_COVERAGE` names, one per line, if set.
func explorerWriteCoverage() {
    let windows = explorerL1Windows.withLock { $0 }
    if windows > 0 { print("EXPLORER capacity-conflict report windows reached: \(windows)") }
    guard let path = ProcessInfo.processInfo.environment["EXPLORER_COVERAGE"] else { return }
    let lines = explorerCoverage.withLock { $0.sorted() }.joined(separator: "\n") + "\n"
    try? lines.write(toFile: path, atomically: true, encoding: .utf8)
}

/// I51's expected invalidation trace of one tracked property across a step.
///
/// A presentation publishes a property only when its value changes (UI-004), so a property-precise
/// observer sees a chain: an Observation tracker reads the value about to be replaced, a Combine
/// `$isObserving` sink the value about to be set. The first invalidation of a step continues the value
/// at the step's start, each one differs from the one before it, and the last one leads to the value at
/// the step's end; a step without one leaves the value unchanged. An extra invalidation, a missing one,
/// and an invalidation of a property whose value did not change all break the chain.
@MainActor final class ExplorerPropertyTrace<Value: Equatable> {
    let name: String
    /// Whether the observer reads the value about to be replaced (Observation) rather than the new one.
    var readsOld = true
    private var start: Value?
    private var chain: [Value] = []
    private var open = false
    init(_ name: String) { self.name = name }

    func begin(_ value: Value?) {
        start = value
        chain = []
        open = value != nil
    }
    func invalidated(_ value: Value, _ world: ExplorerWorld) {
        guard open else { return }
        if let last = chain.last ?? (readsOld ? nil : start), last == value {
            world.violate(
                .propertyInvalidation,
                "\(name) was invalidated without a change: \(chain.map { "\($0)" } + ["\(value)"])"
            )
            open = false
            return
        }
        if readsOld, chain.isEmpty, let start, start != value {
            world.violate(
                .propertyInvalidation,
                "\(name) changed from \(start) to \(value) without an invalidation before its first one this step"
            )
            open = false
            return
        }
        chain.append(value)
    }
    func end(_ value: Value?, _ world: ExplorerWorld) {
        defer { open = false }
        guard open, let value, let start else { return }
        if let last = chain.last {
            if readsOld ? last == value : last != value {
                world.violate(
                    .propertyInvalidation,
                    "\(name) ends the step at \(value) after the invalidations \(chain.map { "\($0)" })"
                )
            }
        } else if value != start {
            world.violate(.propertyInvalidation, "\(name) changed from \(start) to \(value) without an invalidation")
        }
    }
}

/// The traces of a presentation's two tracked properties (I51).
///
/// They are `isObserving` (the `$isObserving` sink, or an Observation tracker of it alone) and, for an
/// Observation class, `snapshot`'s identity.
@MainActor final class ExplorerTraces {
    let observing = ExplorerPropertyTrace<Bool>("isObserving")
    let snapshot = ExplorerPropertyTrace<Int>("snapshot")
    /// Whether the class tracks `snapshot` on its own (Observation); `objectWillChange` does not.
    var tracksSnapshot = false

    func begin(observing value: Bool?, shown: Int?) {
        observing.begin(value)
        snapshot.begin(tracksSnapshot ? shown : nil)
    }
    /// A report: the sink's new value, or for an Observation tracker the negation of the value it read.
    func report(_ value: Bool, _ world: ExplorerWorld, observation: Bool) {
        observing.readsOld = observation
        observing.invalidated(observation ? !value : value, world)
    }
    func end(observing value: Bool?, shown: Int?, _ world: ExplorerWorld) {
        observing.end(value, world)
        snapshot.end(shown, world)
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
