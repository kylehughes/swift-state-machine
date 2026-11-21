import Combine
import Dispatch
import Foundation
import ObjectiveC
import Observation
import StateMachine
import StateMachineUI
import os

/// The presentation classes the explorer drives: two passive, two driving.
enum ExplorerPassiveKind: String, CaseIterable, Sendable {
    case combine = "SnapshotObservableObject"
    case observation = "SnapshotPresentation"
    case drivingCombine = "StateMachineObservableObject"
    case drivingObservation = "StateMachinePresentation"
    case teardownMain = "MainActorHost"
    case teardownActor = "ActorHost"
    case teardownShared = "Shared"
    case generatedCombine = "GeneratedOwner.SnapshotObservableObject"
    case generatedObservation = "GeneratedOwner.SnapshotPresentation"
    case sequenceMain = "MainActorSnapshotSequence"
    case sequenceIsolated = "IsolatedSnapshotSequence"
    case publisher = "SnapshotPublisher"
    case runtimeShared = "RuntimeSharedHost"
    case freeSequence = "SnapshotSequence"
    case realDrivingCombine = "GeneratedOwner.StateMachineObservableObject"
    case realDrivingObservation = "GeneratedOwner.StateMachinePresentation"
    case ownerFormsCombine = "OwnerForms.SnapshotObservableObject"
    case ownerFormsObservation = "OwnerForms.SnapshotPresentation"
    case multiCombine = "MultiOwner.SnapshotObservableObject"
    case multiObservation = "MultiOwner.SnapshotPresentation"
    case ingress = "MainActorSnapshotIngress"
    case distinct = "DistinctSnapshotSequence"

    var isDriving: Bool { self == .drivingCombine || self == .drivingObservation }
    var isTeardown: Bool { self == .teardownMain || self == .teardownActor || self == .teardownShared }
    var isGenerated: Bool { self == .generatedCombine || self == .generatedObservation }
    var isSequence: Bool { self == .sequenceMain || self == .sequenceIsolated }
    /// Whether every step of the slice is forced; smoke runs only these.
    var isDeterministic: Bool {
        self != .teardownActor && self != .teardownShared && self != .ownerFormsCombine
            && self != .ownerFormsObservation
            && self != .multiCombine && self != .multiObservation && self != .distinct
    }
    /// Owner-level slices with an alphabet of their own.
    var isOwnerSlice: Bool {
        isTeardown || isGenerated || isSequence || self == .publisher || self == .runtimeShared || self == .freeSequence
            || self == .realDrivingCombine || self == .realDrivingObservation || self == .ownerFormsCombine
            || self == .ownerFormsObservation || self == .multiCombine || self == .multiObservation || self == .ingress
            || self == .distinct
    }
    var isCombine: Bool { self == .combine || self == .drivingCombine }
}

/// Keeps the only strong reference the harness has to a presentation, so dropping it is one event.
@MainActor final class ExplorerHolder<Presentation: AnyObject & Sendable> {
    var strong: Presentation?
    weak var weak: Presentation?
    init(_ presentation: Presentation) {
        strong = presentation
        weak = presentation
    }
    func dropMain() {
        let held = strong
        strong = nil
        _ = consume held
    }
    /// Hands the reference to a worker that releases it while the main actor waits.
    func dropElsewhere() -> Bool {
        guard let held = strong else { return true }
        strong = nil
        let slot = OSAllocatedUnfairLock<Presentation?>(initialState: held)
        _ = consume held
        let dropped = DispatchSemaphore(value: 0)
        DispatchQueue.global()
            .async {
                slot.withLock { $0 = nil }
                dropped.signal()
            }
        return explorerWait(dropped)
    }
    func dropAfterJob() async {
        guard let held = strong else { return }
        strong = nil
        // Consumed, so no reference of this frame outlives the worker's release.
        await explorerDropAfterItsJob(consume held)
    }
}

/// One passive presentation under test, reached through closures so both classes share the harness.
@MainActor struct ExplorerPassiveSubject {
    typealias Register = @MainActor () async throws(SubscriptionFailure) -> SnapshotSequence<ExplorerShot>

    let alive: () -> Bool
    let held: () -> Bool
    let snapshot: () -> ExplorerShot?
    let isObserving: () -> Bool?
    let observe: (ExplorerHost) throws(SubscriptionFailure) -> Void
    let observeFrom:
        (() throws(SubscriptionFailure) -> SnapshotSequence<ExplorerShot>) throws(SubscriptionFailure) -> Void
    let observeMain: (ExplorerMainHost) throws(SubscriptionFailure) -> Void
    let observeMainIsolated: (ExplorerMainIsolatedHost) throws(SubscriptionFailure) -> Void
    let observeSeq: (SnapshotSequence<ExplorerShot>) -> Void
    let followSeq: (SnapshotSequence<ExplorerShot>) async -> Void
    let observeAsync: (@escaping Register) async throws(SubscriptionFailure) -> Void
    let followAsync: (@escaping Register) async throws(SubscriptionFailure) -> Void
    let stop: () -> Void
    let apply: (ExplorerShot) -> Bool
    let dropMain: () -> Void
    let dropElsewhere: () -> Bool
    let dropAfterJob: () async -> Void
    /// Attaches a subscriber to `presentedSnapshots`, for the Combine class.
    let subscribe: ((ExplorerSubscriber) -> Void)?
    /// Returns a function that attaches a subscriber to the publisher value read now.
    let save: (() -> (ExplorerSubscriber) -> Void)?
    /// Attaches a subscriber to `presentedSnapshots(projecting:)` with `transform`.
    let subscribeProjected: ((ExplorerSubscriber, @escaping @MainActor (ExplorerShot) -> ExplorerShot) -> Void)?
    /// Calls `observe(host)` of an actor host.
    let observeActor: (ExplorerActorHost) async throws(SubscriptionFailure) -> Void
    /// Calls `observe(host, isolation:)` on the island.
    let observeIsolated: (ExplorerIsland, ExplorerIslandHost) async -> Void
    /// Associates a sentinel with the presentation whose release records its deallocation.
    let watch: (ExplorerWorld) -> Void
    /// Reads `presentedSnapshots(projecting:)` with `transform` now; the result attaches later.
    var saveProjected: ((@escaping @MainActor (ExplorerShot) -> ExplorerShot) -> (ExplorerSubscriber) -> Void)? = nil
    /// Installs the report and change callbacks; the result keeps them installed.
    let install:
        (_ report: @escaping @MainActor (Bool) -> Void, _ change: @escaping @MainActor () -> Void) -> [AnyObject]

    static func make(
        _ kind: ExplorerPassiveKind,
        initial: ExplorerShot,
        revision: @escaping @MainActor (ExplorerShot) -> UInt64
    ) -> ExplorerPassiveSubject? {
        switch kind {
        case .drivingCombine, .drivingObservation, .teardownMain, .teardownActor, .teardownShared, .generatedCombine,
            .generatedObservation, .sequenceMain, .sequenceIsolated, .publisher, .runtimeShared, .freeSequence,
            .realDrivingCombine, .realDrivingObservation, .ownerFormsCombine, .ownerFormsObservation, .multiCombine,
            .multiObservation, .ingress, .distinct:
            return nil
        case .combine:
            let holder = ExplorerHolder(SnapshotObservableObject(initial, revision: revision))
            return ExplorerPassiveSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                snapshot: { holder.weak?.snapshot },
                isObserving: { holder.weak?.isObserving },
                observe: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeFrom: { (register) throws(SubscriptionFailure) in
                    try holder.weak?.observe(snapshotsFrom: register)
                },
                observeMain: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeMainIsolated: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeSeq: { holder.weak?.observe($0) },
                followSeq: { sequence in
                    guard let presentation = holder.weak else { return }
                    await presentation.follow(sequence)
                },
                observeAsync: { (register) async throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try await presentation.observe(snapshotsFrom: register)
                },
                followAsync: { (register) async throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try await presentation.follow(snapshotsFrom: register)
                },
                stop: { holder.weak?.stopObserving() },
                apply: { holder.weak?.apply($0) ?? false },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() },
                subscribe: { subscriber in
                    guard let presentation = holder.weak else { return }
                    explorerSubscribe(presentation, subscriber)
                },
                save: {
                    guard let presentation = holder.weak else { return { _ in } }
                    return explorerSave(presentation)
                },
                subscribeProjected: explorerHasProjection
                    ? { subscriber, transform in
                        guard let presentation = holder.weak else { return }
                        explorerSubscribeProjected(presentation, subscriber, transform)
                    } : nil,
                observeActor: { (host) async throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try await presentation.observe(host)
                },
                observeIsolated: { island, host in
                    guard let presentation = holder.weak else { return }
                    await island.observe(presentation, host)
                },
                watch: { world in holder.weak.map { explorerAssociate($0, ExplorerReleaseSentinel(world)) } },
                saveProjected: { transform in
                    guard let presentation = holder.weak else { return { _ in } }
                    return explorerSaveProjected(presentation, transform)
                },
                install: { report, change in
                    guard let presentation = holder.weak else { return [] }
                    let reports = presentation.$isObserving.dropFirst().sink { report($0) }
                    let changes = presentation.objectWillChange.sink { _ in change() }
                    return [ExplorerKeep((reports, changes))]
                }
            )
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
            let holder = ExplorerHolder(SnapshotPresentation(initial, revision: revision))
            return ExplorerPassiveSubject(
                alive: { holder.weak != nil },
                held: { holder.strong != nil },
                snapshot: { holder.weak?.snapshot },
                isObserving: { holder.weak?.isObserving },
                observe: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeFrom: { (register) throws(SubscriptionFailure) in
                    try holder.weak?.observe(snapshotsFrom: register)
                },
                observeMain: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeMainIsolated: { (host) throws(SubscriptionFailure) in try holder.weak?.observe(host) },
                observeSeq: { holder.weak?.observe($0) },
                followSeq: { sequence in
                    guard let presentation = holder.weak else { return }
                    await presentation.follow(sequence)
                },
                observeAsync: { (register) async throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try await presentation.observe(snapshotsFrom: register)
                },
                followAsync: { (register) async throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try await presentation.follow(snapshotsFrom: register)
                },
                stop: { holder.weak?.stopObserving() },
                apply: { holder.weak?.apply($0) ?? false },
                dropMain: { holder.dropMain() },
                dropElsewhere: { holder.dropElsewhere() },
                dropAfterJob: { await holder.dropAfterJob() },
                subscribe: nil,
                save: nil,
                subscribeProjected: nil,
                observeActor: { (host) async throws(SubscriptionFailure) in
                    guard let presentation = holder.weak else { return }
                    try await presentation.observe(host)
                },
                observeIsolated: { island, host in
                    guard let presentation = holder.weak else { return }
                    await island.observe(presentation, host)
                },
                watch: { world in holder.weak.map { explorerAssociate($0, ExplorerReleaseSentinel(world)) } },
                install: { report, change in
                    let installed = ExplorerKeep(())
                    // Observation reports a change before it is made: the value read then is the old one.
                    explorerTrack({ [weak presentation = holder.weak] in presentation?.isObserving }, installed) {
                        report(!$0)
                    }
                    explorerTrack({ [weak presentation = holder.weak] in presentation?.snapshot.id }, installed) { _ in
                        change()
                    }
                    return [installed]
                }
            )
        }
    }
}

/// Keeps `sentinel` alive exactly as long as `object`, which releases it when it is deallocated.
@MainActor func explorerAssociate(_ object: AnyObject, _ sentinel: ExplorerReleaseSentinel) {
    // The sentinel class's metadata address is a stable key no other code uses.
    let key = unsafeBitCast(ExplorerReleaseSentinel.self, to: UnsafeRawPointer.self)
    objc_setAssociatedObject(object, key, sentinel, .OBJC_ASSOCIATION_RETAIN)
}

/// Keeps a value alive while the harness holds it.
@MainActor final class ExplorerKeep {
    let kept: Any
    init(_ kept: Any) { self.kept = kept }
}

// Re-arms an Observation tracking of `read` for as long as `installed` lives, and calls
// `changed` with the value `read` returns when a change is reported, which is the value before the change.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor func explorerTrack<Value>(
    _ read: @escaping @MainActor () -> Value?,
    _ installed: ExplorerKeep,
    _ changed: @escaping @MainActor (Value) -> Void
) {
    withObservationTracking {
        _ = read()
    } onChange: { [weak installed] in
        MainActor.assumeIsolated {
            guard let installed, let value = read() else { return }
            changed(value)
            explorerTrack(read, installed, changed)
        }
    }
}

/// A Combine subscriber whose deliveries the explorer checks.
@MainActor final class ExplorerSubscriber {
    let index: Int
    let unlimited: Bool
    /// The revision shown when the subscriber attached.
    let shownAtAttach: UInt64
    /// The value shown when the subscriber attached.
    var shownAtAttachID: Int?
    /// Whether the presentation was already gone when the subscriber attached.
    let attachedAfterRelease: Bool
    var subscription: (any Subscription)?
    var demand: Int = 0
    var received: [(id: Int, revision: UInt64)] = []
    var cancelled = false
    var finished = false
    var onSubscription: (@MainActor (ExplorerSubscriber) -> Void)?
    var onValue: (@MainActor (ExplorerSubscriber, ExplorerShot) -> Void)?
    var onFinish: (@MainActor (ExplorerSubscriber) -> Void)?
    /// I47: invocations of each downstream call, counted rather than flagged, and the downstream calls in
    /// progress, with the subscriber's own demand or cancellation calls in progress inside them.
    var world: ExplorerWorld?
    private(set) var subscriptions = 0
    private(set) var completions = 0
    private var depth = 0
    private var ownCalls = 0
    /// I48: the presentation's `objectWillChange` count at the subscriber's last newly published value.
    var willChangeAtLastNew: Int?
    /// E9: the demand a limited subscriber requests from `receive(subscription:)`, zero included, and
    /// whether each `receive(_:)` returns one more.
    var initialDemand = 1
    var returnsDemand = false
    /// The `subscriptionBefore` and `completion` sites.
    var onSubscriptionBefore: (@MainActor (ExplorerSubscriber) -> Void)?
    var onCompletion: (@MainActor (ExplorerSubscriber) -> Void)?

    init(index: Int, unlimited: Bool, shownAtAttach: UInt64, attachedAfterRelease: Bool) {
        self.index = index
        self.unlimited = unlimited
        self.shownAtAttach = shownAtAttach
        self.attachedAfterRelease = attachedAfterRelease
    }
    func request() {
        demand += 1
        ownCalls += 1
        subscription?.request(.max(1))
        ownCalls -= 1
    }
    func cancel() {
        cancelled = true
        let subscription = subscription
        self.subscription = nil
        ownCalls += 1
        subscription?.cancel()
        ownCalls -= 1
    }
    // A downstream call begins: none may overlap another of this subscriber's, unless the subscriber's
    // own request or cancellation, made inside the call in progress, caused it.
    private func enter(_ call: String) {
        if depth > 0, ownCalls == 0 {
            world?
                .violate(
                    .subscriptionProtocol,
                    "subscriber \(index)'s \(call) began inside another of its downstream calls"
                )
        }
        depth += 1
    }
    /// The subscriber's protocol at quiescence: exactly one subscription.
    func checkHandshake() {
        if subscriptions != 1 {
            world?.violate(.subscriptionProtocol, "subscriber \(index) received \(subscriptions) subscriptions")
        }
    }

    /// Whether the subscriber can still take a value now.
    var wantsMore: Bool { !cancelled && !finished && (unlimited || received.count < demand) }
}

extension ExplorerSubscriber: @MainActor Subscriber {
    typealias Input = ExplorerShot
    typealias Failure = Never

    func receive(subscription: any Subscription) {
        subscriptions += 1
        if subscriptions > 1 {
            world?.violate(.subscriptionProtocol, "subscriber \(index) received a second subscription")
        }
        enter("receive(subscription:)")
        defer { depth -= 1 }
        self.subscription = subscription
        onSubscriptionBefore?(self)
        ownCalls += 1
        if unlimited {
            subscription.request(.unlimited)
        } else if initialDemand > 0 {
            demand += initialDemand
            subscription.request(.max(initialDemand))
        }
        ownCalls -= 1
        onSubscription?(self)
    }
    func receive(_ input: ExplorerShot) -> Subscribers.Demand {
        if subscriptions == 0 {
            world?
                .violate(
                    .subscriptionProtocol,
                    "subscriber \(index) received r\(input.revision) before its subscription"
                )
        }
        enter("receive(_:)")
        defer { depth -= 1 }
        onValue?(self, input)
        // Demand returned from the callback is demand too (I18 counts it).
        guard returnsDemand, !unlimited, !cancelled else { return .none }
        demand += 1
        return .max(1)
    }
    func receive(completion: Subscribers.Completion<Never>) {
        completions += 1
        if completions > 1 {
            world?.violate(.subscriptionProtocol, "subscriber \(index) received \(completions) completions")
        }
        enter("receive(completion:)")
        defer { depth -= 1 }
        finished = true
        onFinish?(self)
        onCompletion?(self)
    }
}

/// I48: a newly published value that is not yet the presentation's snapshot is an immediately
/// deliverable change, so it arrives after `objectWillChange` announced it and before the assignment.
///
/// `willChange` is the number of `objectWillChange` callbacks so far, `shownNow` the snapshot the
/// presentation returns now, and `shownBefore` whether the value was ever shown.
@MainActor func explorerCheckOrder(
    _ world: ExplorerWorld,
    _ subscriber: ExplorerSubscriber,
    _ value: ExplorerShot,
    willChange: Int,
    shownNow: Int?,
    shownBefore: Bool
) {
    guard !shownBefore, value.id != shownNow else { return }
    defer { subscriber.willChangeAtLastNew = willChange }
    if let last = subscriber.willChangeAtLastNew, willChange <= last {
        world.violate(
            .callbackOrder,
            "subscriber \(subscriber.index) received r\(value.revision) before objectWillChange announced it"
        )
    }
}

/// Checks one value a Combine subscriber receives against invariants I17 to I21, and records it.
@MainActor func explorerCheckReceived(_ world: ExplorerWorld, _ subscriber: ExplorerSubscriber, _ value: ExplorerShot) {
    let name = "subscriber \(subscriber.index)"
    if subscriber.cancelled {
        world.violate(.combineAfterCancel, "\(name) received r\(value.revision) after cancelling")
    }
    if subscriber.finished { world.violate(.combineFinish, "\(name) received r\(value.revision) after finishing") }
    // Publication order across observations; revision order within one (I17).
    if let last = subscriber.received.last {
        if last.id == value.id {
            world.violate(.combineDuplicate, "\(name) received r\(value.revision) twice")
        } else if let problem = world.publicationProblem(next: value.id, previous: last.id, strict: true) {
            world.violate(
                .combineDuplicate,
                "\(name) received \(problem): \(subscriber.received.map(\.revision) + [value.revision])"
            )
        }
    }
    // The first value is the one shown at the attach or a later publication (I19).
    if subscriber.received.isEmpty, let shown = subscriber.shownAtAttachID, shown != value.id,
        let problem = world.publicationProblem(next: value.id, previous: shown, strict: false)
    {
        world.violate(
            .combineSeed,
            "\(name) first received \(problem), older than r\(subscriber.shownAtAttach) shown when it attached"
        )
    }
    if !subscriber.unlimited, subscriber.received.count >= subscriber.demand {
        world.violate(.combineDemand, "\(name) received r\(value.revision) beyond its demand of \(subscriber.demand)")
    }
    if subscriber.attachedAfterRelease {
        world.violate(.combineFinish, "\(name) attached after the release and received r\(value.revision)")
    }
    if world.state.withLock({ $0.presentationGone }) {
        world.violate(
            .publishedAfterRelease,
            "\(name) received r\(value.revision) after the presentation was deallocated"
        )
    }
    subscriber.received.append((value.id, value.revision))
}
