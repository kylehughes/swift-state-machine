import Dispatch
import Foundation
import StateMachine
import os

// The shared record of one explored sequence: every registration a fake host admitted, every client
// value the harness created, the reports a presentation made, and the violations found. Destructors
// and worker threads write to it, so it lives behind one lock; nothing it holds is a client value,
// and nothing is released while the lock is held.

/// An invariant the explorer checks. `Tests/ScheduleExplorer.md` lists them with their sources.
enum ExplorerInvariant: String, CaseIterable, Sendable {
    case offMain = "I1"
    case unreadBeforeSlotFree = "I2"
    case shownBeforeSlotFree = "I3"
    case captureBeforeSlotFree = "I4"
    case falseWhileOccupied = "I5"
    case reportsAlternate = "I6"
    case reportMismatch = "I7"
    case lateAdmission = "I8"
    case factoryWhileOccupied = "I9"
    case shownAfterEnd = "I10"
    case revisionRegressed = "I11"
    case applyLost = "I12"
    case refusalChangedState = "I13"
    case finalState = "I14"
    case leak = "I15"
    case stuck = "I16"
    case combineDuplicate = "I17"
    case combineDemand = "I18"
    case combineSeed = "I19"
    case combineAfterCancel = "I20"
    case combineFinish = "I21"
    case combineLatest = "I22"
    case combineUnshown = "I23"
    case hostReleaseOrder = "I24"
    case twoRegistrations = "I25"
    case returnedBeforeShown = "I26"
    case refusedApplyLost = "I27"
    case ownerReleasedDelivery = "I28"
    case ownerReleasedPending = "I29"
    case ownerReleasedUnfinished = "I30"
    case gateNotClosed = "I31"
    case publisherTurnBound = "I32"
    case sequenceOrder = "I33"
    case completionBeforeCustody = "I34"
    case stopLeftRegistration = "I35"
    case presentationTurnBound = "I36"
    case trueBeforeLive = "I37"
    case replacedAttemptActed = "I38"
    case publishedAfterRelease = "I39"
    case cancelKeptUnread = "I40"
    case finishLostFinal = "I41"
    case claimedTouched = "I42"
    case countHeld = "I43"
    case attemptOrder = "I44"
    case drivingResult = "I45"
    case resumeContract = "I46"
    case subscriptionProtocol = "I47"
    case callbackOrder = "I48"
    case ownerCopies = "I49"
    case ingressDelivery = "I50"
    case propertyInvalidation = "I51"
    case distinctProjection = "I52"
    case flushBoundary = "I53"
}

struct ExplorerViolation: Sendable, CustomStringConvertible {
    let invariant: ExplorerInvariant
    let detail: String
    var description: String { "\(invariant.rawValue) \(invariant): \(detail)" }
}

/// Where a client value came from, and the observation attempt it belongs to.
enum ExplorerOrigin: Sendable, Equatable {
    case initial
    /// Applied with `apply(_:)` while `attempt` was the current observation, if any.
    case applied(attempt: Int?)
    /// Read with a host's `snapshot()` for `attempt`.
    case hostRead(host: Int)
    /// Delivered into registration `registration`.
    case delivered(registration: Int)
}

/// What the harness is doing when a host admits a registration.
enum ExplorerAdmissionContext: Sendable, Equatable {
    /// No harness call that registers is running: a registration admitted now was retried or started
    /// by the presentation on its own.
    case spontaneous
    /// A harness call that registers for `attempt` is running.
    case call(attempt: Int)
}

nonisolated final class ExplorerWorld: Sendable {
    enum Phase: Sendable, Equatable { case active, cancelling, freed }

    struct Registration: Sendable {
        let id: Int
        let host: Int
        var attempt: Int?
        var phase: Phase = .active
        /// The host finished the registration, or began cancelling its token.
        var hostEnded = false
        /// The host finished it, which the presentation learns at once.
        var finished = false
        /// The presentation's read may be waiting, so the next delivery may be handed to it directly.
        var readerMayWait = false
        /// Made by a registration closure that has not handed it to the presentation, or never did.
        ///
        /// The presentation does not own it, so no ownership invariant counts it.
        var withheld = false
        var latestOffer: Int?
        var firstOffer: UInt64?
        var parked = false
    }
    struct Value: Sendable {
        let revision: UInt64
        let origin: ExplorerOrigin
        let attempt: Int?
        var considered = false
        /// Delivered while the presentation's read may have been waiting: handed to the read, not left unread.
        var handed = false
        var offeredAfterEnd = false
        /// Delivered by its host from inside a cancellation of the registration's token.
        var inCancellation = false
        /// Offered with the revision of the registration's previous offer and different data (E1).
        var equalOffer = false
        var shownAt: Int?
        var destroyed = false
    }
    struct State: Sendable {
        var registrations: [Int: Registration] = [:]
        var values: [Int: Value] = [:]
        var slots: [Int: Int] = [:]
        var refusals: [Int: Int] = [:]
        var nextRegistration = 1
        var nextValue = 1
        var revision: UInt64 = 0
        var violations: [ExplorerViolation] = []
        var reports: [Bool] = []
        var context: ExplorerAdmissionContext = .spontaneous
        var letGo: Set<Int> = []
        var trace: [String] = []
        /// Whether the presentation has been deallocated.
        var presentationGone = false
        var captures = 0
        var hostsAlive = 0
        var factoryInvocations = 0
        var latestAttempt: Int?
        /// Set when a documented exception lets an element be destroyed off the main actor.
        var offMainExempt = false
        /// The owner under teardown has begun its teardown (a driver cancelled, callbacks released).
        var ownerTeardown = false
        /// The value a worker's offer displaces, which latest-value delivery releases on that worker.
        var workerDisplaced: Int?
        /// Values a host is dropping its own reference to, after the call that delivered them returned.
        var hostReleasing: Set<Int> = []
        /// E1: every host keeps a revision clock of its own, and applied values continue the clock of the
        /// host that admitted the newest registration.
        var independentClocks = false
        var clocks: [Int: UInt64] = [:]
        var lineageHost = 0
        /// Runs after a client value's destructor on the main thread (the `destroy` site).
        var destroyHook: (@Sendable () -> Void)?
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    /// Whether every event is also printed as it happens, for replay.
    let verbose: Bool

    init(verbose: Bool = false) { self.verbose = verbose }

    func violate(_ invariant: ExplorerInvariant, _ detail: String) {
        state.withLock { $0.violations.append(ExplorerViolation(invariant: invariant, detail: detail)) }
        if verbose { print("    !! \(invariant.rawValue): \(detail)") }
    }
    func note(_ line: String) {
        state.withLock { $0.trace.append(line) }
        if verbose { print("    . \(line)") }
    }
    var violations: [ExplorerViolation] { state.withLock { $0.violations } }

    // MARK: Values

    func nextRevision() -> UInt64 {
        state.withLock {
            $0.revision += 1
            return $0.revision
        }
    }
    /// A new client value; revisions advance by 10, which leaves room for `applyBelow`.
    func makeValue(_ origin: ExplorerOrigin, attempt: Int?, revision fixed: UInt64? = nil) -> ExplorerShot {
        let (id, revision) = state.withLock { state -> (Int, UInt64) in
            let revision: UInt64
            if let fixed {
                revision = fixed
            } else if state.independentClocks, let host = Self.clockHost(origin, state) {
                let next = state.clocks[host, default: 0] + 10
                state.clocks[host] = next
                revision = next
                state.revision = max(state.revision, next)
            } else {
                state.revision += 10
                revision = state.revision
            }
            let id = state.nextValue
            state.nextValue += 1
            state.values[id] = Value(revision: revision, origin: origin, attempt: attempt)
            return (id, revision)
        }
        return ExplorerShot(id: id, revision: revision, world: self)
    }
    // The host whose clock a new value continues under independent clocks; `nil` for the initial value.
    private static func clockHost(_ origin: ExplorerOrigin, _ state: State) -> Int? {
        switch origin {
        case .initial: nil
        case .applied: state.lineageHost
        case .hostRead(let host): host
        case .delivered(let registration): state.registrations[registration]?.host ?? state.lineageHost
        }
    }
    /// The observation a value belongs to: its attempt, or the presentation's first generation.
    func observation(of id: Int) -> Int { state.withLock { $0.values[id]?.attempt ?? 0 } }

    /// Why `next` cannot be a publication after `previous`, or `nil` when it can (I11, I17, I19).
    ///
    /// Revision order belongs to one observation: within one, revisions increase (strictly when `strict`,
    /// and always for a value offered with an equal revision); a host's snapshot of a newer observation
    /// is a new baseline at any revision; a value of an older observation never follows a newer one.
    /// Under `EXPLORER_SCALAR_REVISIONS=1` one revision order across every observation applies instead,
    /// for replays against a tree whose presentations compare revisions across observations.
    func publicationProblem(next: Int, previous: Int, strict: Bool) -> String? {
        state.withLock { state in
            guard let value = state.values[next], let before = state.values[previous] else { return nil }
            if explorerScalarRevisions {
                let regressed = strict ? value.revision <= before.revision : value.revision < before.revision
                return regressed ? "r\(value.revision) after r\(before.revision)" : nil
            }
            let observation = value.attempt ?? 0
            let earlier = before.attempt ?? 0
            let baseline: Bool
            switch value.origin {
            case .delivered, .hostRead: baseline = observation != earlier
            case .applied, .initial: baseline = false
            }
            if baseline {
                return observation < earlier
                    ? "r\(value.revision) of observation \(observation) after r\(before.revision) of the later observation \(earlier)"
                    : nil
            }
            let regressed =
                strict || value.equalOffer ? value.revision <= before.revision : value.revision < before.revision
            return regressed ? "r\(value.revision) after r\(before.revision) within observation \(observation)" : nil
        }
    }
    func markEqualOffer(_ id: Int) { state.withLock { $0.values[id]?.equalOffer = true } }
    func useIndependentClocks() { state.withLock { $0.independentClocks = true } }
    func setDestroyHook(_ hook: (@Sendable () -> Void)?) { state.withLock { $0.destroyHook = hook } }

    func initialValue() -> ExplorerShot {
        let id = state.withLock { state -> Int in
            let id = state.nextValue
            state.nextValue += 1
            state.values[id] = Value(revision: 0, origin: .initial, attempt: nil)
            return id
        }
        return ExplorerShot(id: id, revision: 0, world: self)
    }
    /// The presentation's revision closure read `id`: the presentation took it out of its registration.
    func considered(_ id: Int) { state.withLock { $0.values[id]?.considered = true } }
    func liveValues() -> [Int] { state.withLock { $0.values.filter { !$0.value.destroyed }.keys.sorted() } }
    func revision(of id: Int) -> UInt64 { state.withLock { $0.values[id]?.revision ?? 0 } }
    func attempt(of id: Int) -> Int? { state.withLock { $0.values[id]?.attempt } }

    /// A client value's destructor ran.
    func destroyed(_ id: Int, revision: UInt64) {
        let onMain = Thread.isMainThread
        let (found, byHost) = state.withLock { state -> ([ExplorerViolation], Bool) in
            var found: [ExplorerViolation] = []
            guard var value = state.values[id] else { return ([], false) }
            value.destroyed = true
            state.values[id] = value
            // A value delivered from inside a token's cancellation that no presentation kept goes with its
            // host's own reference, on the host's thread, before the slot is free.
            let ownRelease = value.inCancellation && state.hostReleasing.contains(id)
            if !onMain, !state.offMainExempt, state.workerDisplaced != id, !ownRelease {
                found.append(.init(invariant: .offMain, detail: "value r\(revision) destroyed off the main thread"))
            }
            let occupied = state.registrations.values.filter { $0.phase != .freed && !$0.withheld }.map(\.id).sorted()
            if value.inCancellation, !ownRelease, case .delivered(let registration) = value.origin,
                let record = state.registrations[registration], record.phase != .freed
            {
                // One a presentation kept is released only once that cancellation has returned and the
                // slot is free (the I2 slot rule).
                found.append(
                    .init(
                        invariant: .unreadBeforeSlotFree,
                        detail:
                            "r\(revision), delivered inside the cancellation of registration #\(registration), destroyed while its slot is occupied"
                    )
                )
            } else if case .delivered(let registration) = value.origin, let record = state.registrations[registration],
                record.phase != .freed, !record.withheld, record.latestOffer == id, !value.considered,
                !value.offeredAfterEnd,
                !value.handed, !ownRelease,
                state.letGo.contains(record.attempt ?? -1) || record.hostEnded
            {
                found.append(
                    .init(
                        invariant: .unreadBeforeSlotFree,
                        detail:
                            "unread r\(revision) of registration #\(registration) destroyed while its slot is occupied"
                    )
                )
            }
            if state.presentationGone, value.shownAt != nil, !occupied.isEmpty {
                found.append(
                    .init(
                        invariant: .shownBeforeSlotFree,
                        detail:
                            "shown r\(revision) of a released presentation destroyed while registrations \(occupied) hold slots"
                    )
                )
            }
            state.violations += found
            state.trace.append("destroyed r\(revision)\(onMain ? "" : " off main")\(ownRelease ? " by its host" : "")")
            return (found, ownRelease)
        }
        if verbose {
            print("    . destroyed r\(revision)\(onMain ? "" : " OFF MAIN")\(byHost ? " by its host" : "")")
            for violation in found { print("    !! \(violation)") }
        }
        if onMain, let hook = state.withLock({ $0.destroyHook }) { hook() }
    }
    /// The capture of the presentation's revision closure was destroyed.
    func captureDestroyed() {
        let onMain = Thread.isMainThread
        state.withLock { state in
            state.captures -= 1
            if !onMain {
                state.violations.append(
                    .init(invariant: .offMain, detail: "revision closure capture destroyed off main")
                )
            }
            let occupied = state.registrations.values.filter { $0.phase != .freed && !$0.withheld }.map(\.id).sorted()
            if !occupied.isEmpty {
                state.violations.append(
                    .init(
                        invariant: .captureBeforeSlotFree,
                        detail: "revision closure capture destroyed while registrations \(occupied) hold slots"
                    )
                )
            }
        }
    }

    // MARK: Registrations

    /// Admits a registration on `host` unless its one slot is taken.
    func admit(host: Int) -> Int? {
        let (id, found) = state.withLock { state -> (Int?, ExplorerViolation?) in
            var found: ExplorerViolation?
            if let holder = state.slots[host] {
                state.refusals[host, default: 0] += 1
                state.trace.append("host \(host) refused (slot held by #\(holder))")
                return (nil, nil)
            }
            let id = state.nextRegistration
            state.nextRegistration += 1
            var attempt: Int?
            switch state.context {
            case .call(let current): attempt = current
            case .spontaneous:
                let lastReport = state.reports.last
                let unfreed = state.registrations.values.filter {
                    $0.phase != .freed && !$0.withheld && (state.letGo.contains($0.attempt ?? -1) || $0.finished)
                }
                if lastReport == true || !unfreed.isEmpty {
                    found = .init(
                        invariant: .lateAdmission,
                        detail:
                            "registration #\(id) on host \(host) admitted outside a registering call while the last report is \(lastReport.map(String.init) ?? "none") and \(unfreed.map(\.id)) still hold slots"
                    )
                }
                attempt = state.latestAttempt
            }
            state.slots[host] = id
            state.registrations[id] = Registration(id: id, host: host, attempt: attempt)
            state.lineageHost = host
            if let attempt, state.letGo.contains(attempt) {
                state.trace.append("#\(id) admitted for let-go attempt \(attempt)")
            }
            state.trace.append("host \(host) admitted #\(id)")
            return (id, found)
        }
        if let found { violate(found.invariant, found.detail) }
        if verbose, let id { print("    . host \(host) admitted #\(id)") }
        return id
    }
    func cancelling(_ registration: Int) {
        state.withLock { state in
            if state.registrations[registration]?.phase == .active {
                state.registrations[registration]?.phase = .cancelling
            }
        }
    }
    func freed(_ registration: Int) {
        state.withLock { state in
            guard var record = state.registrations[registration] else { return }
            record.phase = .freed
            record.parked = false
            state.registrations[registration] = record
            if state.slots[record.host] == registration { state.slots[record.host] = nil }
            state.trace.append("#\(registration) freed")
        }
        if verbose { print("    . #\(registration) freed") }
    }
    func offered(_ value: Int, into registration: Int) {
        state.withLock { state in
            guard var record = state.registrations[registration] else { return }
            record.latestOffer = value
            if record.firstOffer == nil { record.firstOffer = state.values[value]?.revision }
            if record.readerMayWait { state.values[value]?.handed = true }
            record.readerMayWait = false
            // Offered to a mailbox that has ended, which drops it at once. A host's cancellation still in
            // progress leaves the sequence open, so a value offered then is kept unread.
            if state.letGo.contains(record.attempt ?? -1) || record.finished || record.phase == .freed {
                state.values[value]?.offeredAfterEnd = true
            }
            state.registrations[registration] = record
        }
    }
    /// Marks `value` as delivered from inside a cancellation of its registration's token.
    func deliveredInCancellation(_ value: Int) {
        state.withLock { $0.values[value]?.inCancellation = true }
        note("r\(revision(of: value)) delivered inside a cancellation")
    }
    /// Whether `value` was delivered from inside a cancellation of its registration's token.
    func isInCancellation(_ value: Int) -> Bool { state.withLock { $0.values[value]?.inCancellation ?? false } }
    /// Brackets a host's release of its own reference to `value`.
    func hostReleasing(_ value: Int, _ releasing: Bool) {
        state.withLock { state in
            if releasing { state.hostReleasing.insert(value) } else { state.hostReleasing.remove(value) }
        }
    }
    func hostEnded(_ registration: Int, finished: Bool = false) {
        state.withLock { state in
            state.registrations[registration]?.hostEnded = true
            if finished { state.registrations[registration]?.finished = true }
        }
    }
    /// The main actor ran a turn, or a follower started reading: every registration's read may wait now.
    func readersMayWait() {
        state.withLock { state in
            for id in state.registrations.keys { state.registrations[id]?.readerMayWait = true }
        }
    }
    func setParked(_ registration: Int, _ parked: Bool) {
        state.withLock { $0.registrations[registration]?.parked = parked }
    }
    func setContext(_ context: ExplorerAdmissionContext) { state.withLock { $0.context = context } }
    func setLatestAttempt(_ attempt: Int) { state.withLock { $0.latestAttempt = attempt } }
    func letGo(_ attempts: [Int]) { state.withLock { $0.letGo.formUnion(attempts) } }
    func isLetGo(_ attempt: Int) -> Bool { state.withLock { $0.letGo.contains(attempt) } }

    /// Registrations that are not yet freed, apart from those a closure withholds.
    var unfreed: [Registration] {
        state.withLock { $0.registrations.values.filter { $0.phase != .freed && !$0.withheld } }
    }
    /// Every registration that is not yet freed.
    var allUnfreed: [Registration] { state.withLock { $0.registrations.values.filter { $0.phase != .freed } } }
    /// Registrations that the presentation let go, or that their host finished, and still hold a slot.
    ///
    /// A host's cancellation in progress elsewhere is not among them: the presentation learns of it
    /// only once the cancellation returns, and the slot is free by then.
    var unfreedEnded: [Registration] {
        state.withLock { state in
            state.registrations.values.filter {
                $0.phase != .freed && !$0.withheld && (state.letGo.contains($0.attempt ?? -1) || $0.finished)
            }
        }
    }
    /// Marks a registration as made but not handed to the presentation, or as handed to it.
    func withhold(_ registration: Int, _ withheld: Bool) {
        state.withLock { $0.registrations[registration]?.withheld = withheld }
    }
    /// The registration that `attempt` made most recently.
    func registration(of attempt: Int) -> Int? {
        state.withLock { $0.registrations.values.filter { $0.attempt == attempt }.map(\.id).max() }
    }
    func registration(_ id: Int) -> Registration? { state.withLock { $0.registrations[id] } }
    func slot(of host: Int) -> Int? { state.withLock { $0.slots[host] } }
}

/// Whether the revision invariants check one revision order across every observation instead (I11).
let explorerScalarRevisions = ProcessInfo.processInfo.environment["EXPLORER_SCALAR_REVISIONS"] == "1"

/// A `Sendable` client value whose destruction the explorer checks.
nonisolated final class ExplorerShot: StateMachineSnapshot, Sendable, CustomStringConvertible {
    let id: Int
    let revision: UInt64
    private let world: ExplorerWorld
    init(id: Int, revision: UInt64, world: ExplorerWorld) {
        self.id = id
        self.revision = revision
        self.world = world
    }
    deinit { world.destroyed(id, revision: revision) }
    var description: String { "r\(revision)" }
}

/// An object associated with the presentation, so its release marks the presentation's deallocation.
nonisolated final class ExplorerReleaseSentinel: Sendable {
    private let world: ExplorerWorld
    init(_ world: ExplorerWorld) { self.world = world }
    deinit {
        world.state.withLock { $0.presentationGone = true }
        world.note("presentation deallocated\(Thread.isMainThread ? "" : " off main")")
    }
}

/// A value the presentation's revision closure captures, whose destruction the explorer checks.
nonisolated final class ExplorerCapture: Sendable {
    private let world: ExplorerWorld
    init(_ world: ExplorerWorld) {
        self.world = world
        world.state.withLock { $0.captures += 1 }
    }
    deinit { world.captureDestroyed() }
    func read(_ shot: ExplorerShot) -> UInt64 {
        world.considered(shot.id)
        return shot.revision
    }
}

/// Waits on a semaphore for at most a safety-net interval; `false` means the schedule is stuck.
nonisolated func explorerWait(_ semaphore: DispatchSemaphore, seconds: Int = 5) -> Bool {
    semaphore.wait(timeout: .now() + .seconds(seconds)) == .success
}
