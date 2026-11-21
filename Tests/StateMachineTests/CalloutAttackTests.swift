import Combine
import Dispatch
import Foundation
import Observation
import StateMachine
import StateMachineUI
import Testing
import os

// Each case runs one action from client code at one point where the library calls out, while a
// presentation replaces an observation, or while a host ends a registration, and then checks what
// must hold whatever the action was: nothing leaks a slot, every token is cancelled once, a value
// released by an end is released after that end frees its slot, shown revisions never fall, and
// nothing is shown or reported live once the following task or the observation has ended. Every wait
// ends on an explicit event: a task's return, an Observation invalidation, or a signal.

/// Where client code runs.
enum Callout: CaseIterable, CustomTestStringConvertible, Sendable {
    /// The presentation's revision closure.
    case revision
    /// A callback of a snapshot publication.
    case publication
    /// A callback of an `isObserving` report.
    case report
    /// The cancellation of the registration that the new observation replaces.
    case predecessorRelease
    /// The closure that registers the new observation.
    case factory
    /// The destructor of a snapshot that a publication or an end released.
    case snapshotRelease

    var testDescription: String {
        switch self {
        case .revision: "revision"
        case .publication: "publication"
        case .report: "report"
        case .predecessorRelease: "predecessor release"
        case .factory: "factory"
        case .snapshotRelease: "snapshot release"
        }
    }
}

/// What the client code does.
enum Action: CaseIterable, CustomTestStringConvertible, Sendable {
    case stop
    case replaceWithSameOwner
    case replaceWithAnotherOwner
    case cancelCurrentTask
    case sendInput
    case drop

    var testDescription: String {
        switch self {
        case .stop: "stop"
        case .replaceWithSameOwner: "replace, same owner"
        case .replaceWithAnotherOwner: "replace, another owner"
        case .cancelCurrentTask: "cancel current task"
        case .sendInput: "send input"
        case .drop: "drop"
        }
    }
}

/// How the new observation is started.
enum Start: CaseIterable, CustomTestStringConvertible, Sendable {
    /// `observe(snapshotsFrom:)`, which the presentation owns.
    case observe
    /// `follow(snapshotsFrom:)`, which the calling task owns.
    case follow

    var testDescription: String {
        switch self {
        case .observe: "observe"
        case .follow: "follow"
        }
    }
}

/// A snapshot whose release on the main actor is a callout.
private final class Mark: Sendable {
    let revision: UInt64
    private let trigger: Trigger?
    init(_ revision: UInt64, _ trigger: Trigger?) {
        self.revision = revision
        self.trigger = trigger
    }
    deinit {
        guard let trigger, Thread.isMainThread else { return }
        MainActor.assumeIsolated { trigger.fire(.snapshotRelease) }
    }
}

private typealias RawHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>

@MainActor private func makeRawHost() throws -> RawHost {
    RawHost(
        0,
        scopes: [],
        configuration: try ManagedConfiguration(subscribers: 1),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

/// The members of both snapshot presentation classes that the attack uses.
@MainActor private protocol Attacked: AnyObject {
    var isObserving: Bool { get }
    func observe(_ snapshots: SnapshotSequence<Mark>)
    func observe<Failure: Error>(snapshotsFrom register: () throws(Failure) -> SnapshotSequence<Mark>) throws(Failure)
    func follow<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Mark>
    ) async throws(Failure)
    func stopObserving()
}

extension SnapshotObservableObject: Attacked where Snapshot == Mark {}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
extension SnapshotPresentation: Attacked where Snapshot == Mark {}

/// Runs the action once, at the first armed callout of its kind, and records what follows it.
@MainActor private final class Trigger {
    let callout: Callout
    let action: Action
    var armed = false
    private(set) var fired = false
    /// Publications begun and live reports made after an action or a stop that ends every observation,
    /// or a cancellation of the task that follows the observation.
    private(set) var shownAfterEnd = 0
    private(set) var liveAfterEnd = 0
    private(set) var ended = false
    /// The revisions shown, where the presentation reports them.
    private(set) var revisions: [UInt64] = []

    weak var presentation: (any Attacked)?
    var strong: (any Attacked)?
    var first: RawHost?
    var second: RawHost?
    var sent = 0

    init(_ callout: Callout, _ action: Action) {
        self.callout = callout
        self.action = action
    }

    func fire(_ at: Callout) {
        guard armed, !fired, at == callout else { return }
        fired = true
        switch action {
        case .stop:
            presentation?.stopObserving()
            ended = true
        case .replaceWithSameOwner:
            if let first { try? presentation?.observe(snapshotsFrom: { try project(first, from: 10) }) }
        case .replaceWithAnotherOwner:
            if let second { try? presentation?.observe(snapshotsFrom: { try project(second, from: 100) }) }
        case .cancelCurrentTask:
            withUnsafeCurrentTask { $0?.cancel() }
            if Role.following { ended = true }
        case .sendInput:
            send()
        case .drop:
            strong = nil
        }
    }
    func send() {
        guard let first else { return }
        sent += 1
        _ = first.commit(try! RawHost.Engine.prepare(on: first.snapshot(), next: sent))
    }
    func project(_ host: RawHost, from base: UInt64) throws(SubscriptionFailure) -> SnapshotSequence<Mark> {
        try host.sendableSnapshots { [weak self] snapshot in Mark(base + snapshot.revision, self) }
    }
    /// Stops every observation; nothing may be shown or reported live afterward.
    func stopAll() {
        presentation?.stopObserving()
        ended = true
    }
    func shown(_ revision: UInt64?) {
        if ended { shownAfterEnd += 1 }
        if let revision { revisions.append(revision) }
        fire(.publication)
    }
    func reported(_ live: Bool) {
        if ended, live { liveAfterEnd += 1 }
        fire(.report)
    }
}

/// Creates a presentation of `kind` whose revision closure is a callout, or `nil` where that class is
/// unavailable, with its publication and report callbacks installed.
@MainActor private func attacked(_ kind: PresentationClass, _ trigger: Trigger) -> (any Attacked, AnyObject)? {
    let revision: @MainActor (Mark) -> UInt64 = { [weak trigger] mark in
        trigger?.fire(.revision)
        return mark.revision
    }
    switch kind {
    case .combine:
        let presentation = SnapshotObservableObject(Mark(0, nil), revision: revision)
        let hooks = [
            presentation.presentedSnapshots.dropFirst().sink { [weak trigger] mark in trigger?.shown(mark.revision) },
            presentation.$isObserving.dropFirst().sink { [weak trigger] live in trigger?.reported(live) },
        ]
        return (presentation, hooks as AnyObject)
    case .observation:
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
        let presentation = SnapshotPresentation(Mark(0, nil), revision: revision)
        let hooks = AttackHooks(trigger)
        trackShown(presentation, hooks)
        trackLive(presentation, hooks)
        return (presentation, hooks)
    }
}

/// Makes the trigger the only strong holder of a new presentation of `kind`, and returns its hooks.
@MainActor private func install(_ kind: PresentationClass, _ trigger: Trigger) -> AnyObject? {
    guard let (made, hooks) = attacked(kind, trigger) else { return nil }
    trigger.strong = made
    trigger.presentation = made
    return hooks
}

/// The trigger an Observation presentation's tracking reports to.
@MainActor private final class AttackHooks {
    weak var trigger: Trigger?
    init(_ trigger: Trigger) { self.trigger = trigger }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private func trackShown(_ model: SnapshotPresentation<Mark>, _ hooks: AttackHooks) {
    withObservationTracking {
        _ = model.snapshot
    } onChange: { [weak model, weak hooks] in
        MainActor.assumeIsolated {
            guard let model, let hooks else { return }
            trackShown(model, hooks)
            hooks.trigger?.shown(nil)
        }
    }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor private func trackLive(_ model: SnapshotPresentation<Mark>, _ hooks: AttackHooks) {
    withObservationTracking {
        _ = model.isObserving
    } onChange: { [weak model, weak hooks] in
        MainActor.assumeIsolated {
            guard let model, let hooks else { return }
            let live = !model.isObserving
            trackLive(model, hooks)
            hooks.trigger?.reported(live)
        }
    }
}

/// A predecessor registration of the test's own, whose cancellation is a callout.
///
/// It keeps the sequence's callbacks, since releasing them would end the sequence at once.
private final class Predecessor: Sendable {
    private let cancellations = OSAllocatedUnfairLock(initialState: 0)
    private let callbacks = OSAllocatedUnfairLock<(@Sendable (Mark) -> Void, @Sendable () -> Void)?>(
        initialState: nil
    )
    var cancelled: Int { cancellations.withLock { $0 } }

    @MainActor func sequence(_ trigger: Trigger) throws -> SnapshotSequence<Mark> {
        try SnapshotSequence<Mark> { receive, finish in
            callbacks.withLock { $0 = (receive, finish) }
            receive(Mark(1, trigger))
            return SnapshotSubscription { [cancellations] in
                cancellations.withLock { $0 += 1 }
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { [weak trigger] in trigger?.fire(.predecessorRelease) }
            }
        }
    }
}

/// Whether client code runs on the task that follows the observation.
private enum Role {
    @TaskLocal static var following = false
}

/// Returns once `host` holds no registration, reading its count through Observation.
@MainActor private func untilUnsubscribed(_ host: RawHost) async {
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
    while true {
        let changed = Signal()
        let count = withObservationTracking {
            host.subscriberCount
        } onChange: {
            changed.raise()
        }
        guard count > 0 else { return }
        await changed.wait()
    }
}

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationCalloutAttackTests {
    @Test(arguments: Callout.allCases, Action.allCases)
    func observeAttack(_ callout: Callout, _ action: Action) async throws {
        for kind in PresentationClass.allCases { try await attack(kind, .observe, callout, action) }
    }
    @Test(arguments: Callout.allCases, Action.allCases)
    func followAttack(_ callout: Callout, _ action: Action) async throws {
        for kind in PresentationClass.allCases { try await attack(kind, .follow, callout, action) }
    }

    // The presentation observes a predecessor registration of the test's own, then starts a new
    // observation of `first`; the trigger runs `action` at the first `callout` after that. The test
    // then sends an input, flushes it, stops the presentation, cancels a following task, and checks.
    private func attack(_ kind: PresentationClass, _ start: Start, _ callout: Callout, _ action: Action) async throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        let trigger = Trigger(callout, action)
        // Only the trigger holds the presentation strongly, so the drop action releases it.
        guard let hooks = install(kind, trigger) else { return }
        let first = try makeRawHost()
        let second = try makeRawHost()
        trigger.first = first
        trigger.second = second
        let predecessor = Predecessor()
        trigger.presentation?.observe(try predecessor.sequence(trigger))
        trigger.armed = true
        // Each start runs in a task of its own, which a callout may cancel.
        let scenario = Task.immediate { @MainActor in
            switch start {
            case .observe:
                try? trigger.presentation?
                    .observe(snapshotsFrom: {
                        trigger.fire(.factory)
                        return try trigger.project(first, from: 10)
                    })
            case .follow:
                await Role.$following.withValue(true) {
                    let shown = trigger.presentation
                    try? await shown?
                        .follow(snapshotsFrom: {
                            trigger.fire(.factory)
                            return try trigger.project(first, from: 10)
                        })
                }
            }
        }
        trigger.send()
        let receipt = first.snapshot()
        _ = await first.flush(through: receipt)
        trigger.stopAll()
        scenario.cancel()
        await scenario.value
        trigger.strong = nil
        await untilUnsubscribed(first)
        await untilUnsubscribed(second)
        #expect(trigger.fired, "\(kind), \(start): the callout never ran")
        #expect(predecessor.cancelled == 1, "\(kind), \(start)")
        #expect(trigger.presentation == nil, "\(kind), \(start): the presentation outlived its last reference")
        #expect(trigger.shownAfterEnd == 0, "\(kind), \(start): shown after the end")
        #expect(trigger.liveAfterEnd == 0, "\(kind), \(start): live after the end")
        #expect(trigger.revisions == trigger.revisions.sorted(), "\(kind), \(start): \(trigger.revisions)")
        withExtendedLifetime(hooks) {}
    }
}

// MARK: Registrations

/// Where a registration runs client code.
enum RegistrationCallout: CaseIterable, CustomTestStringConvertible, Sendable {
    /// A host's `onCancel`, during a cancellation the host itself starts.
    case tokenCancel
    /// The destructor of an unread element that the sequence's end discarded.
    case elementRelease

    var testDescription: String {
        switch self {
        case .tokenCancel: "token cancellation"
        case .elementRelease: "element release"
        }
    }
}

/// The form of a registration.
enum RegistrationForm: CaseIterable, CustomTestStringConvertible, Sendable {
    /// `SnapshotSequence(register:)` with a host of the test's own.
    case shared
    /// `snapshots(_:)` of a `MainActorStateMachineHost` of the test's own.
    case mainActor

    var testDescription: String {
        switch self {
        case .shared: "shared"
        case .mainActor: "main actor"
        }
    }
}

/// An element whose release is recorded and may be a callout.
private final class Item: Sendable {
    let tag: String
    private let log: RegistrationLog
    private let callout: Bool
    init(_ tag: String, _ log: RegistrationLog, callout: Bool = false) {
        self.tag = tag
        self.log = log
        self.callout = callout
    }
    deinit {
        log.record("\(tag) released")
        if callout { log.fire(.elementRelease) }
    }
}

/// The events of a registration attack, and the action it runs once at its callout.
private final class RegistrationLog: Sendable {
    private struct State {
        var events: [String] = []
        var armed = false
        var fired = false
        var reregistered: Bool?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let callout: RegistrationCallout
    let action: Action
    /// Runs the action; set once the hosts exist.
    let perform = OSAllocatedUnfairLock<(@Sendable (Action) -> Bool?)?>(initialState: nil)

    init(_ callout: RegistrationCallout, _ action: Action) {
        self.callout = callout
        self.action = action
    }
    var events: [String] { state.withLock { $0.events } }
    var fired: Bool { state.withLock { $0.fired } }
    var reregistered: Bool? { state.withLock { $0.reregistered } }
    func record(_ event: String) { state.withLock { $0.events.append(event) } }
    func arm() { state.withLock { $0.armed = true } }
    func fire(_ at: RegistrationCallout) {
        let runs = state.withLock { state in
            guard state.armed, !state.fired, at == callout else { return false }
            state.fired = true
            return true
        }
        guard runs, let perform = perform.withLock({ $0 }) else { return }
        let result = perform(action)
        state.withLock { $0.reregistered = result }
    }
}

/// A host of the test's own with one slot, freed when its token's `onCancel` returns, which records
/// when the slot is freed and can cancel its token itself.
private final class SlotHost: Sendable {
    private struct State {
        var occupied = false
        var receive: (@Sendable (Item) -> Void)?
        var token: SnapshotSubscription?
        var registrations = 0
    }
    let name: String
    private let log: RegistrationLog
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ name: String, _ log: RegistrationLog) {
        self.name = name
        self.log = log
    }
    var occupied: Bool { state.withLock { $0.occupied } }
    func sequence() throws(SubscriptionFailure) -> SnapshotSequence<Item> {
        try SnapshotSequence<Item> { (receive, _) throws(SubscriptionFailure) in
            let number: Int? = state.withLock { state in
                guard !state.occupied else { return nil }
                state.occupied = true
                state.registrations += 1
                state.receive = receive
                return state.registrations
            }
            guard let number else { throw .capacityExceeded }
            let label = "\(name)#\(number)"
            let token = SnapshotSubscription { [log, state] in
                log.record("\(label) entered")
                log.fire(.tokenCancel)
                state.withLock {
                    $0.occupied = false
                    $0.receive = nil
                }
                log.record("\(label) freed")
            }
            state.withLock { $0.token = token }
            return token
        }
    }
    func offer(_ item: Item) { state.withLock { $0.receive }?(item) }
    /// Cancels the token of the current registration, as a host that evicts an observer does.
    func evict() { state.withLock { $0.token }?.cancel() }
}

/// The sequence under attack, which any thread can end, replace, or drop.
private final class Held: Sendable {
    private let stored = OSAllocatedUnfairLock<SnapshotSequence<Item>?>(initialState: nil)
    func fill(_ sequence: SnapshotSequence<Item>?) {
        let displaced = stored.withLock { stored in
            let displaced = stored
            stored = sequence
            return displaced
        }
        withExtendedLifetime(displaced) {}
    }
    /// Cancels from no actor, which leaves a main-actor owner's removal to a later main-actor turn.
    func cancel() { stored.withLock { $0 }?.cancel(isolation: nil) }
    /// Cancels from the main actor, which removes a main-actor owner's registration before returning.
    @MainActor func cancelOnMainActor() { stored.withLock { $0 }?.cancel() }
}

/// A `MainActor` host of the test's own with one slot, freed when its token's `onCancel` returns.
@MainActor private final class MainSlotHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Tick
    struct Receipt: StateMachineReceipt {
        let snapshot: Tick
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    let name: String
    private let log: RegistrationLog
    private(set) var occupied = false
    private var registrations = 0
    private var receive: (@MainActor (Tick) -> Void)?
    private var token: MainActorSnapshotSubscription?
    private var freed: [CheckedContinuation<Void, Never>] = []

    /// Returns once no registration holds the slot.
    func untilFree() async {
        while occupied { await withCheckedContinuation { freed.append($0) } }
    }

    init(_ name: String, _ log: RegistrationLog) {
        self.name = name
        self.log = log
    }
    func snapshot() -> Tick { Tick(revision: 0) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Tick) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard !occupied else { throw .capacityExceeded }
        occupied = true
        registrations += 1
        self.receive = receive
        let label = "\(name)#\(registrations)"
        let made = MainActorSnapshotSubscription { [weak self, log] in
            log.record("\(label) entered")
            log.fire(.tokenCancel)
            self?.occupied = false
            self?.receive = nil
            log.record("\(label) freed")
            let waiting = self?.freed ?? []
            self?.freed = []
            for continuation in waiting { continuation.resume() }
        }
        token = made
        return made
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Tick(revision: 0)) }
    func offer(_ revision: UInt64) { receive?(Tick(revision: revision)) }
    func evict() { token?.cancel() }
}

/// A snapshot of `MainSlotHost`.
private struct Tick: StateMachineSnapshot, Sendable {
    let revision: UInt64
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct RegistrationCalloutAttackTests {
    // A host ends a registration that still holds an unread element, by cancelling its own token or
    // through the sequence's cancellation; the callout runs `action`. Whatever it does, the element is
    // released only after its registration's slot is free, every slot is free at the end, and a
    // destructor that registers with the same host again finds the slot free.
    @Test(arguments: RegistrationCallout.allCases, Action.allCases)
    func registrationAttack(_ callout: RegistrationCallout, _ action: Action) async throws {
        for form in RegistrationForm.allCases { try await attack(form, callout, action) }
    }

    private func attack(_ form: RegistrationForm, _ callout: RegistrationCallout, _ action: Action) async throws {
        let log = RegistrationLog(callout, action)
        let held = Held()
        switch form {
        case .shared:
            let first = SlotHost("first", log)
            let second = SlotHost("second", log)
            log.perform.withLock {
                $0 = { action in
                    switch action {
                    case .stop: held.cancel()
                    case .replaceWithSameOwner:
                        let next = try? first.sequence()
                        held.fill(next)
                        return next != nil
                    case .replaceWithAnotherOwner: held.fill(try? second.sequence())
                    case .cancelCurrentTask: withUnsafeCurrentTask { $0?.cancel() }
                    case .sendInput: first.offer(Item("late", log))
                    case .drop: held.fill(nil)
                    }
                    return nil
                }
            }
            held.fill(try first.sequence())
            first.offer(Item("unread", log, callout: callout == .elementRelease))
            log.arm()
            switch callout {
            case .tokenCancel: first.evict()
            case .elementRelease: held.cancel()
            }
            held.cancel()
            held.fill(nil)
            #expect(!first.occupied)
            #expect(!second.occupied)
        case .mainActor:
            let first = MainSlotHost("first", log)
            let second = MainSlotHost("second", log)
            let project: @MainActor (Tick) -> Item = { tick in
                Item(
                    tick.revision == 1 ? "unread" : "late",
                    log,
                    callout: tick.revision == 1 && callout == .elementRelease
                )
            }
            log.perform.withLock {
                $0 = { action in
                    MainActor.assumeIsolated {
                        switch action {
                        case .stop: held.cancel()
                        case .replaceWithSameOwner:
                            let next = try? first.snapshots(project)
                            held.fill(next)
                            return next != nil
                        case .replaceWithAnotherOwner: held.fill(try? second.snapshots(project))
                        case .cancelCurrentTask: withUnsafeCurrentTask { $0?.cancel() }
                        case .sendInput: first.offer(2)
                        case .drop: held.fill(nil)
                        }
                        return nil
                    }
                }
            }
            held.fill(try first.snapshots(project))
            first.offer(1)
            log.arm()
            switch callout {
            case .tokenCancel: first.evict()
            case .elementRelease: held.cancelOnMainActor()
            }
            held.cancelOnMainActor()
            held.fill(nil)
            // A release from no actor, as from a destructor, leaves the main-actor removal to a later
            // turn, which frees the slot.
            await first.untilFree()
            await second.untilFree()
        }
        let events = log.events
        #expect(log.fired, "\(events)")
        // The element an end discards is the last one offered to the first registration: it is released
        // only once that registration's slot is free. An element an offer displaces is released then.
        let discarded = action == .sendInput && callout == .tokenCancel ? "late" : "unread"
        if let released = events.firstIndex(of: "\(discarded) released") {
            let freed = events.firstIndex(of: "first#1 freed")
            #expect(freed.map { $0 < released } == true, "\(events)")
        }
        if callout == .elementRelease, action == .replaceWithSameOwner {
            #expect(log.reregistered == true, "\(events)")
        }
    }
}
