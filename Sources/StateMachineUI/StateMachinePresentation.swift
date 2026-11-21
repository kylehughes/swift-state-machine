import Combine
import Observation
import StateMachine

/// An `ObservableObject` that drives one `MainActor` owner and publishes its complete snapshot.
///
/// The Combine counterpart of ``StateMachinePresentation``, with the same driving operations and a
/// publisher of the snapshots it shows, ``presentedSnapshots``, for apps that deploy before iOS 17. It
/// supports every deployment target of the package, including iOS 16. Create it with a generated
/// `MainActorHost`, read ``snapshot`` from a view, and call ``send(_:)`` from its actions. An accepted input
/// is visible in the same turn; snapshots that arrive later through the subscription, such as an
/// operation's result, are published as they are delivered. Released on another thread, it closes its
/// registration's gate at once, which stops a generated owner's delivery, and leaves the rest to a later
/// main-actor turn, which finishes the publisher's subscribers, cancels its subscription, and once that
/// cancellation has returned releases its snapshot and its owner, on the main actor.
@MainActor public final class StateMachineObservableObject<Host: MainActorStateMachineHost>: ObservableObject {
    /// The latest complete snapshot; independently published phase fields cannot diverge.
    ///
    /// `objectWillChange` announces each change before it is made. The presentation keeps the snapshot
    /// in storage that a main-actor turn empties when the presentation is released, so its stored
    /// properties never hold a snapshot of their own.
    public var snapshot: Host.Snapshot { core.snapshot! }
    /// Whether this presentation still holds a live registration with its owner.
    ///
    /// It becomes `true` when a registration that creation or ``resumeObserving()`` made is live, once
    /// the presentation shows the owner's snapshot that the registration delivered. A registration that
    /// ends before that, as one a closed owner finishes inside the registration call, publishes nothing.
    /// It becomes `false` when the owner finishes the registration, by closing or being released, and
    /// when ``stopObserving()`` or ``close()`` ends it, each time once the presentation's cancellation of
    /// the registration's subscription has returned, so a host of your own that frees its slot when its
    /// subscription is cancelled has the slot free by then, also when the host ends the registration from
    /// inside its own cancellation of that subscription.
    @Published public private(set) var isObserving = false
    /// Why the presentation could not register with its owner, or `nil` when it registered.
    ///
    /// A failed registration leaves ``isObserving`` `false`; the presentation still shows the
    /// owner's snapshot at creation and every change made through it. A later ``resumeObserving()``
    /// that registers sets it to `nil`; one that is refused throws and leaves it unchanged.
    @Published public private(set) var observationFailure: SubscriptionFailure?
    /// The owner, for reconciliation and shutdown that the presentation does not wrap.
    public var host: Host { core.host! }
    // The registration, the owner, and the shown snapshot, which a main-actor turn releases when the
    // presentation is released, so its stored properties hold none of them.
    private let core: DrivingCore<StateMachineObservableObject>
    // The subscribers of `presentedSnapshots`. It holds no snapshot.
    private let feed = PresentationFeed<Host.Snapshot>()

    /// Shows the owner's current snapshot and tries to reserve one subscriber slot for updates; this
    /// starts no work.
    ///
    /// Creation never fails. If the owner refuses another registration, ``isObserving`` is
    /// `false`, ``observationFailure`` holds the reason, and the presentation shows the snapshot it read
    /// at creation, even when the owner delivered a newer one before refusing; ``resumeObserving()``
    /// registers again.
    public init(_ host: Host) {
        core = DrivingCore(host)
        core.surface = self
        feed.current = { [weak self] in self?.core.snapshot }
        core.start()
    }

    /// Registers with the owner again, after a refused creation or after ``stopObserving()`` or
    /// ``close()``, without replacing the presentation or detaching the subscribers of
    /// ``presentedSnapshots``.
    ///
    /// It registers exactly as creation does. The presentation keeps the snapshot it shows, then shows
    /// the owner's current snapshot that the registration delivers, if it is newer, and ``isObserving``
    /// becomes `true`. A refusal throws at once and changes nothing: the presentation shows the same
    /// snapshot, ``isObserving`` and ``observationFailure`` keep their values, and nothing the owner
    /// delivered while refusing is shown. A closed owner, as after ``close()``, finishes the new
    /// registration inside the call, so it returns with ``isObserving`` `false`. While a registration
    /// is live or still being made, it returns without registering.
    public func resumeObserving() throws(SubscriptionFailure) { try core.register() }

    /// Admits one input and publishes its accepted snapshot.
    ///
    /// A call made outside a snapshot publication publishes the accepted snapshot before it returns. A
    /// call made while the presentation publishes a snapshot, as from a callback of that change,
    /// returns its receipt at once, and the presentation publishes the latest snapshot deferred that way once
    /// the change in progress is complete.
    @discardableResult public func send(_ input: Host.Input) throws(Host.SendRejection) -> Host.Receipt {
        let receipt = try host.send(input)
        core.apply(receipt.snapshot)
        return receipt
    }

    /// Submits a proposal from the rendered snapshot and returns the owner's commit result.
    ///
    /// After either outcome, it reads the owner's snapshot and publishes it only if the revision
    /// advances. A reentrant call defers publication until the current assignment finishes.
    ///
    /// The proposal is checked against the owner's current revision, so an action offered from
    /// a snapshot that has since been replaced is rejected instead of applied to newer state.
    public func commit(_ prepared: consuming Host.Prepared) -> Host.CommitResult {
        let result = host.commit(prepared)
        core.apply(host.snapshot())
        return result
    }

    /// Closes the owner, stops observing, and publishes its terminal snapshot before returning, unless
    /// the call is made during a snapshot publication, which defers it as ``send(_:)`` does.
    ///
    /// The owner is closed before the registration ends, so a callback of that end that resumes
    /// observing finds the owner closed, and no registration is live once this returns.
    @discardableResult public func close() -> Host.Receipt {
        let receipt = host.close()
        core.end()
        core.apply(receipt.snapshot)
        return receipt
    }

    /// Removes this presentation's registration synchronously without closing the owner.
    ///
    /// Nothing the owner delivers through the registration once this begins is shown, including a
    /// snapshot that a host of your own delivers from inside the subscription's cancellation, which the
    /// presentation releases on the main actor once that cancellation has returned, as it does when it
    /// is closed or released. A registration that the owner is still making, when a callback of its
    /// registration call stops the presentation, is cancelled as soon as the call returns it, and what
    /// the owner delivered inside that call is released only once that cancellation has returned.
    public func stopObserving() { core.end() }

    // A presentation can be released on another thread, as when an object that stores it is released
    // there. The registration's gate closes at once, which stops delivery and frees a generated owner's
    // slot; one later main-actor turn then finishes the publisher's subscribers and cancels the
    // subscription, which removes the registration and clears the token, and once every cancellation the
    // presentation started has returned releases the shown snapshot and the owner on the main actor. The
    // core holds those values alone, so they are released there even when that turn runs before this
    // presentation's own storage is destroyed.
    deinit {
        core.gate.close()
        let core = core
        let feed = feed
        Task { @MainActor in
            feed.finish()
            core.dispose()
        }
        DestructorPause.reached()
    }

    /// A Combine publisher of a `Sendable` projection of each snapshot the presentation shows, which
    /// `transform` computes on the main actor, for a snapshot that is not `Sendable`.
    ///
    /// It publishes as ``presentedSnapshots`` does: the projection of the snapshot shown when a
    /// subscriber attaches, then of each newly shown snapshot, in the order and at the times that
    /// ``PresentationPublisher`` describes. It stays open across ``stopObserving()`` and finishes once
    /// the presentation is released.
    public func presentedSnapshots<Projection: Sendable>(
        projecting transform: @escaping @MainActor (Host.Snapshot) -> Projection
    ) -> PresentationPublisher<Projection> {
        PresentationPublisher(feed, transform)
    }
}

extension StateMachineObservableObject: DrivingSurface {
    fileprivate func present(_ next: Host.Snapshot, assign: () -> Void) {
        objectWillChange.send()
        feed.send(next)
        assign()
    }
    fileprivate func report(observing: Bool) { isObserving = observing }
    fileprivate func record(_ failure: SubscriptionFailure?) {
        guard observationFailure != failure else { return }
        observationFailure = failure
    }
}

extension StateMachineObservableObject where Host.Snapshot: Sendable {
    /// A Combine publisher of the snapshots the presentation shows.
    ///
    /// It publishes the snapshot shown when a subscriber attaches, then each newly shown snapshot. A
    /// change the subscriber has demand for
    /// arrives after `objectWillChange` and before ``snapshot`` returns it; a buffered one arrives once
    /// the subscriber has demand again, as ``PresentationPublisher`` describes.
    ///
    /// It belongs to the presentation, not to its registration, so it stays open after
    /// ``stopObserving()``, and ``isObserving`` reports whether the registration is live. Once the
    /// presentation is released, it finishes, and a subscriber that attaches after that receives
    /// `.finished` at once. A snapshot that is not `Sendable` is published through
    /// ``presentedSnapshots(projecting:)``.
    public var presentedSnapshots: PresentationPublisher<Host.Snapshot> { PresentationPublisher(feed) { $0 } }
}

/// An `@Observable` model that drives one `MainActor` owner and exposes its complete snapshot.
///
/// Create it with a generated `MainActorHost`, read ``snapshot`` from a view, and call ``send(_:)`` from its
/// actions. An accepted input is visible in the same turn; snapshots that arrive later through the
/// subscription, such as an operation's result, are exposed as they are delivered. Only ``snapshot``,
/// ``isObserving``, and ``observationFailure`` are tracked; the owner and its authority are excluded from
/// observation. It requires iOS 17 or a matching release; ``StateMachineObservableObject`` has the same
/// driving operations for earlier ones. Released on another thread, it closes its registration's gate at
/// once, which stops a generated owner's delivery, and leaves the rest to a later main-actor turn, which
/// cancels its subscription and once that cancellation has returned releases its snapshot and its owner,
/// on the main actor.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
@MainActor @Observable public final class StateMachinePresentation<Host: MainActorStateMachineHost> {
    /// The latest complete snapshot; independently observed phase fields cannot diverge.
    ///
    /// The model keeps the snapshot in storage that a main-actor turn empties when the model is
    /// released, so its stored properties never hold a snapshot of their own.
    public var snapshot: Host.Snapshot {
        access(keyPath: \.snapshot)
        return core.snapshot!
    }
    /// Whether this model still holds a live registration with its owner.
    ///
    /// It becomes `true` when a registration that creation or ``resumeObserving()`` made is live, once
    /// the model exposes the owner's snapshot that the registration delivered. A registration that ends
    /// before that, as one a closed owner finishes inside the registration call, changes nothing. It
    /// becomes `false` when the owner finishes the registration, by closing or being released, and when
    /// ``stopObserving()`` or ``close()`` ends it, each time once the model's cancellation of the
    /// registration's subscription has returned, so a host of your own that frees its slot when its
    /// subscription is cancelled has the slot free by then, also when the host ends the registration from
    /// inside its own cancellation of that subscription.
    public private(set) var isObserving = false
    /// Why the model could not register with its owner, or `nil` when it registered.
    ///
    /// A failed registration leaves ``isObserving`` `false`; the model still exposes the
    /// owner's snapshot at creation and every change made through it. A later ``resumeObserving()``
    /// that registers sets it to `nil`; one that is refused throws and leaves it unchanged.
    public private(set) var observationFailure: SubscriptionFailure?
    /// The owner, for reconciliation and shutdown that the model does not wrap.
    public var host: Host { core.host! }
    // The registration, the owner, and the exposed snapshot, which a main-actor turn releases when the
    // model is released, so its stored properties hold none of them.
    @ObservationIgnored private let core: DrivingCore<StateMachinePresentation>

    /// Shows the owner's current snapshot and tries to reserve one subscriber slot for updates; this
    /// starts no work.
    ///
    /// Creation never fails, so the model can initialize a view's `@State`. If the owner refuses another registration, ``isObserving`` is
    /// `false`, ``observationFailure`` holds the reason, and the model exposes the snapshot it read
    /// at creation, even when the owner delivered a newer one before refusing; ``resumeObserving()``
    /// registers again.
    public init(_ host: Host) {
        core = DrivingCore(host)
        core.surface = self
        core.start()
    }

    /// Registers with the owner again, after a refused creation or after ``stopObserving()`` or
    /// ``close()``, without replacing the model.
    ///
    /// It registers exactly as creation does. The model keeps the snapshot it exposes, then exposes
    /// the owner's current snapshot that the registration delivers, if it is newer, and ``isObserving``
    /// becomes `true`. A refusal throws at once and changes nothing: the model exposes the same
    /// snapshot, ``isObserving`` and ``observationFailure`` keep their values, and nothing the owner
    /// delivered while refusing is exposed. A closed owner, as after ``close()``, finishes the new
    /// registration inside the call, so it returns with ``isObserving`` `false`. While a registration
    /// is live or still being made, it returns without registering.
    public func resumeObserving() throws(SubscriptionFailure) { try core.register() }

    /// Admits one input and exposes its accepted snapshot.
    ///
    /// A call made outside a snapshot publication exposes the accepted snapshot before it returns. A
    /// call made while the model exposes a snapshot, as from a callback of that change,
    /// returns its receipt at once, and the model exposes the latest snapshot deferred that way once
    /// the change in progress is complete.
    @discardableResult public func send(_ input: Host.Input) throws(Host.SendRejection) -> Host.Receipt {
        let receipt = try host.send(input)
        core.apply(receipt.snapshot)
        return receipt
    }

    /// Submits a proposal from the rendered snapshot and returns the owner's commit result.
    ///
    /// After either outcome, it reads the owner's snapshot and updates `snapshot` with it only if the revision
    /// advances. A reentrant call defers the update until the current assignment finishes.
    ///
    /// The proposal is checked against the owner's current revision, so an action offered from
    /// a snapshot that has since been replaced is rejected instead of applied to newer state.
    public func commit(_ prepared: consuming Host.Prepared) -> Host.CommitResult {
        let result = host.commit(prepared)
        core.apply(host.snapshot())
        return result
    }

    /// Closes the owner, stops observing, and exposes its terminal snapshot before returning, unless
    /// the call is made during a snapshot change, which defers it as ``send(_:)`` does.
    ///
    /// The owner is closed before the registration ends, so a callback of that end that resumes
    /// observing finds the owner closed, and no registration is live once this returns.
    @discardableResult public func close() -> Host.Receipt {
        let receipt = host.close()
        core.end()
        core.apply(receipt.snapshot)
        return receipt
    }

    /// Removes this model's registration synchronously without closing the owner.
    ///
    /// Nothing the owner delivers through the registration once this begins is exposed, including a
    /// snapshot that a host of your own delivers from inside the subscription's cancellation, which the
    /// model releases on the main actor once that cancellation has returned, as it does when it is
    /// closed or released. A registration that the owner is still making, when a callback of its
    /// registration call stops the model, is cancelled as soon as the call returns it, and what the
    /// owner delivered inside that call is released only once that cancellation has returned.
    public func stopObserving() { core.end() }

    // A model can be released on another thread, as when an object that stores it is released
    // there. The registration's gate closes at once, which stops delivery and frees a generated owner's
    // slot; one later main-actor turn then cancels the subscription, which removes the registration and
    // clears the token, and once every cancellation the model started has returned releases the exposed
    // snapshot and the owner on the main actor. The core holds those values alone, so they are released
    // there even when that turn runs before this model's own storage is destroyed.
    deinit {
        core.gate.close()
        let core = core
        Task { @MainActor in core.dispose() }
        DestructorPause.reached()
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
extension StateMachinePresentation: DrivingSurface {
    fileprivate func present(_ next: Host.Snapshot, assign: () -> Void) { withMutation(keyPath: \.snapshot, assign) }
    fileprivate func report(observing: Bool) { isObserving = observing }
    fileprivate func record(_ failure: SubscriptionFailure?) {
        guard observationFailure != failure else { return }
        observationFailure = failure
    }
}

/// The published values of a driving presentation, which its core keeps and assigns.
@MainActor private protocol DrivingSurface: AnyObject, SendableMetatype {
    associatedtype Host: MainActorStateMachineHost
    /// Announces that the shown snapshot changes to `next`, around `assign`, which stores it in the core.
    func present(_ next: Host.Snapshot, assign: () -> Void)
    /// Assigns whether a registration is live.
    func report(observing: Bool)
    /// Assigns why the presentation could not register, when that changes.
    func record(_ failure: SubscriptionFailure?)
}

/// The registration, the owner, and the shown snapshot of a driving presentation.
///
/// Both driving presentations share it. The core holds their only references, so a presentation
/// released on another thread leaves them to the main-actor turn that disposes of the core.
///
/// The presentation registers through ``register()`` alone, at creation and in `resumeObserving()`, and
/// lets a registration go through ``end()`` alone, for `stopObserving()`, `close()`, the owner's finish,
/// and the disposal of a released presentation. `registration` is in exactly one state, and every event
/// that can arrive while a registration is being made, from any callback of the owner or of the client,
/// reads that state in one switch:
///
/// - `idle`: no registration is being made or held.
/// - `registering(attempt)`: the owner is inside the registration call, and `attempt` stages what it
///   delivers and whether it finishes. Ending it leaves the call to cancel the token the owner returns.
/// - `installed(attempt, token, live:)`: the presentation holds the token and its gate, and the
///   registration is `live` once its first snapshot is shown.
///
/// Every cancellation of a registration the presentation let go is counted in `cancelling` until it
/// has returned, from the moment the presentation let it go, also when that is inside the registration
/// call, before the owner returned a token. A snapshot the presentation will not show, as one delivered
/// through a registration that is no longer the presentation's or staged by a registration it let go
/// or the owner refused, is kept until `cancelling` is zero and then released, so its destructor finds
/// the slot free; the shown snapshot and the owner of a released presentation are released then too.
/// `isObserving` is `true` while a registration is live; once published `true`, it stays `true` until
/// every cancellation the presentation started has returned, but a cancellation alone never makes it
/// `true`. An installed registration becomes live only once no assignment is in progress, so the
/// snapshot it delivered, or a newer one, is already shown when the presentation first reports it.
///
/// A snapshot that arrives while another is being assigned waits for that assignment, tagged by where
/// it came from: a receipt of a change made through the presentation, or a delivery of one registration.
/// Ending a registration detaches its waiting delivery, whose publication was never announced, before
/// any callout, and keeps it until the cancellation has returned, while a waiting receipt is still
/// shown. A delivery is shown only while its registration is the presentation's, which is read again
/// after its revision is, since reading it can run a snapshot's own code.
@MainActor private final class DrivingCore<Surface: DrivingSurface> {
    typealias Host = Surface.Host
    typealias Snapshot = Host.Snapshot
    typealias Attempt = RegistrationStaging<Snapshot>

    private enum Registration {
        case idle
        case registering(Attempt)
        case installed(Attempt, MainActorSnapshotSubscription, live: Bool)
    }
    /// A snapshot waiting for the assignment in progress, with the revision read when it arrived and,
    /// for a delivery, the registration that delivered it.
    private struct Waiting {
        let snapshot: Snapshot
        let revision: UInt64
        var attempt: Attempt? = nil
    }
    /// Where a snapshot to show came from.
    enum Origin {
        /// The receipt of a change admitted through the presentation, which it always shows.
        case presentation
        /// A delivery of one registration, which ending that registration discards unless its
        /// publication has been announced.
        case observation(Attempt)
    }

    weak var surface: Surface?
    /// The gate of the installed registration, which a presentation's destructor closes on whatever
    /// thread releases it.
    nonisolated let gate = PresentationGate()
    private(set) var host: Host?
    private(set) var snapshot: Snapshot?
    // The snapshots that arrived during an assignment and wait for it, each with its revision: the
    // newest receipt, and a delivery newer than it, if one arrived after it.
    private var deferredReceipt: Waiting?
    private var deferredDelivery: Waiting?
    // The revision of the newest snapshot admitted for showing, and of the newest whose publication
    // has been announced.
    private var watermark: UInt64
    private var announced: UInt64
    private var publishing = false
    private var registration = Registration.idle
    // The cancellations of registrations the presentation let go that have not returned yet.
    private var cancelling = 0
    // The snapshots the presentation will not show, which it holds only while a cancellation is running
    // or the disposal of a released presentation is still to come, and releases when that settles.
    private var discarded: [Snapshot] = []
    // The value `isObserving` was last given, or is being given now, and whether it is being given now.
    private var reported = false
    private var reporting = false
    // Whether the presentation was released, so the core releases everything once no cancellation runs.
    private var disposing = false

    init(_ host: Host) {
        let initial = host.snapshot()
        self.host = host
        snapshot = initial
        watermark = initial.revision
        announced = initial.revision
    }

    /// Makes the creation's registration, recording a refusal instead of throwing it.
    func start() {
        do { try register() } catch { surface?.record(error) }
    }

    /// Registers with the owner, unless a registration is being made or held.
    ///
    /// What the owner delivers inside the registration call is staged, and shown only once the owner
    /// returns the registration and it is still the presentation's, so a refusal shows nothing and
    /// changes nothing. A finish inside the call, as a closed owner's, ends the registration once the
    /// owner returns it, without making it live.
    func register() throws(SubscriptionFailure) {
        guard case .idle = registration, !disposing, let host else { return }
        let attempt = Attempt()
        registration = .registering(attempt)
        let token: MainActorSnapshotSubscription
        do {
            token = try host.subscribe(
                { [weak self] next in self?.receive(next, from: attempt) },
                onFinish: { [weak self] in self?.finish(attempt) }
            )
        } catch {
            refuse(attempt)
            throw error
        }
        install(token, for: attempt)
    }

    /// Lets the registration go: cancels the token the presentation holds, or, inside the registration
    /// call, leaves that call to cancel the token the owner returns, and reports the end once every
    /// cancellation has returned.
    //
    // Everything the ending registration owns is detached, and its cancellation counted, before the
    // cancellation's callout, which can register again and stage the next registration's seed.
    func end() {
        var ending: Attempt?
        var token: MainActorSnapshotSubscription?
        switch exchange(&registration, with: .idle) {
        case .idle:
            break
        case .registering(let attempt):
            ending = attempt
            cancelling += 1
        case .installed(let attempt, let installed, _):
            ending = attempt
            token = installed
            cancelling += 1
            gate.current = nil
        }
        let staged = ending?.end()
        // A delivery waiting for the assignment in progress was never announced, so it is not shown; the
        // receipt of a change made through the presentation still is. Without a registration to end, a
        // waiting delivery is the seed of one the owner finished.
        var delivery: Waiting?
        if let waiting = deferredDelivery, ending == nil || waiting.attempt === ending {
            deferredDelivery = nil
            delivery = waiting
            watermark = max(announced, deferredReceipt?.revision ?? 0)
        }
        discard(staged)
        discard(delivery?.snapshot)
        if let token { cancel(token, counted: true) }
        report()
    }

    /// Shows a snapshot only when it is newer, so a delayed delivery cannot regress the model.
    //
    // The revision is read once, before the watermark: reading it can run a snapshot's own code, which
    // can send another input and apply a newer snapshot, which the comparison then sees.
    func apply(_ next: Snapshot, from origin: Origin = .presentation) {
        let revision = next.revision
        var attempt: Attempt?
        if case .observation(let delivering) = origin {
            guard delivering.isInstalled else { return discard(next) }
            attempt = delivering
        }
        if case .presentation = origin, publishing, deferredDelivery != nil,
            revision > max(announced, deferredReceipt?.revision ?? 0)
        {
            // A receipt that a waiting delivery already covers waits too, so it is still shown if the
            // observation ends before the assignment completes.
            let replaced = exchange(&deferredReceipt, with: Waiting(snapshot: next, revision: revision))
            guard revision > watermark else { return release(replaced.map { [$0.snapshot] } ?? []) }
            watermark = revision
            release([replaced, deferredDelivery.take()].compactMap { $0?.snapshot })
            return
        }
        guard revision > watermark else { return }
        watermark = revision
        guard !publishing else {
            // Each arrival is newer than every snapshot waiting. A receipt replaces both; a delivery
            // replaces only a waiting delivery, so the receipt is still shown if the observation ends.
            let waiting = Waiting(snapshot: next, revision: revision, attempt: attempt)
            var replaced: [Waiting?] = [exchange(&deferredDelivery, with: nil)]
            switch origin {
            case .presentation: replaced.append(exchange(&deferredReceipt, with: waiting))
            case .observation: deferredDelivery = waiting
            }
            release(replaced.compactMap { $0?.snapshot })
            return
        }
        publishing = true
        // A replaced snapshot is released after the assignments, so a destructor that reads the
        // presentation finds the newest one in place.
        var displaced: [Snapshot] = []
        show(next, revision: revision, displacing: &displaced)
        // An observer that applied a newer snapshot during the assignment deferred it here, so the outer
        // assignment cannot overwrite the newer value.
        while let newer = deferredDelivery.take() ?? deferredReceipt.take() {
            // A waiting delivery is newer than the waiting receipt, which it then replaces.
            if let older = deferredReceipt.take() { displaced.append(older.snapshot) }
            show(newer.snapshot, revision: newer.revision, displacing: &displaced)
        }
        publishing = false
        becomeLive()
        release(displaced)
    }

    /// Disposes of the core of a released presentation, on the main actor: lets its registration go,
    /// and once every cancellation has returned, including one inside which a host of your own delivers
    /// a snapshot, releases the snapshots and the owner.
    func dispose() {
        disposing = true
        end()
        settle()
    }

    // The owner refused `attempt`, which took no slot. One that the presentation let go inside the
    // registration call no longer counts as cancelling.
    private func refuse(_ attempt: Attempt) {
        if isRegistering(attempt) { registration = .idle } else { cancelling -= 1 }
        discard(attempt.end())
        settle()
    }
    // The owner returned `token` for `attempt`. Each change is made before the callouts that follow it,
    // and the state is read again after each.
    private func install(_ token: MainActorSnapshotSubscription, for attempt: Attempt) {
        guard isRegistering(attempt) else {
            // Let go inside the registration call, and counted as cancelling since then.
            discard(attempt.end())
            return cancel(token, counted: true)
        }
        let (seed, finished) = attempt.install()
        if finished {
            registration = .idle
            cancel(token)
            surface?.record(nil)
            if let seed { apply(seed, from: .observation(attempt)) }
            return
        }
        registration = .installed(attempt, token, live: false)
        gate.current = token.gate
        surface?.record(nil)
        guard isInstalled(attempt) else {
            discard(seed)
            return settle()
        }
        if let seed { apply(seed, from: .observation(attempt)) }
        becomeLive()
    }
    // Makes the installed registration live, unless an assignment is in progress: the seed it delivered,
    // or a newer snapshot, is then shown, and the assignment makes it live once it completes.
    private func becomeLive() {
        guard !publishing, case .installed(let attempt, let token, live: false) = registration else { return }
        registration = .installed(attempt, token, live: true)
        report()
    }
    // Stages a delivery while the owner is still making the registration, shows one of the installed
    // registration, and keeps any other until no cancellation is running: a host of your own can deliver
    // from inside the cancellation that ends the registration, and after the presentation was released.
    private func receive(_ next: Snapshot, from attempt: Attempt) {
        switch registration {
        case .registering(let current) where current === attempt:
            _ = attempt.admit(next)
        case .installed(let current, _, _) where current === attempt && surface != nil:
            apply(next, from: .observation(attempt))
        default:
            // A delivery through a registration the presentation let go waits for the cancellations still
            // running. Once none runs, as when a host of your own calls a callback whose cancellation
            // has returned, nothing more can depend on it, so it is released at once.
            discard(next)
        }
    }
    // Stages a finish while the owner is still making the registration, and ends the installed one.
    private func finish(_ attempt: Attempt) {
        switch registration {
        case .registering(let current) where current === attempt:
            _ = attempt.admitFinish()
        case .installed(let current, _, _) where current === attempt:
            end()
        default:
            break
        }
    }
    private func isRegistering(_ attempt: Attempt) -> Bool {
        guard case .registering(let current) = registration else { return false }
        return current === attempt
    }
    private func isInstalled(_ attempt: Attempt) -> Bool {
        guard case .installed(let current, _, _) = registration else { return false }
        return current === attempt
    }
    // Cancels a token and counts the cancellation until it has returned, unless it was counted when the
    // presentation let its registration go inside the registration call.
    private func cancel(_ token: MainActorSnapshotSubscription, counted: Bool = false) {
        if !counted { cancelling += 1 }
        token.cancel { [self] in
            cancelling -= 1
            settle()
        }
    }
    // Keeps a snapshot the presentation will not show while a cancellation is running, or while the
    // disposal of a released presentation is still to come, and otherwise releases it as it returns, so
    // nothing is kept that no settlement will release.
    private func discard(_ snapshot: Snapshot?) {
        guard let snapshot, cancelling > 0 || (surface == nil && !disposing) else { return }
        discarded.append(snapshot)
    }
    // Releases snapshots the presentation replaced. A callback of the publication can release the
    // presentation, whose disposal then waits for its cancellations, so they wait with the rest.
    private func release(_ replaced: [Snapshot]) {
        guard surface == nil else { return withExtendedLifetime(replaced) {} }
        for snapshot in replaced { discard(snapshot) }
    }
    // Reports, and once no cancellation is running releases the discarded snapshots, and everything when
    // the presentation was released.
    private func settle() {
        report()
        guard cancelling == 0 else { return }
        let released = exchange(&discarded, with: [])
        guard disposing else { return withExtendedLifetime(released) {} }
        let owned = (
            exchange(&snapshot, with: nil), exchange(&deferredReceipt, with: nil),
            exchange(&deferredDelivery, with: nil), exchange(&host, with: nil)
        )
        withExtendedLifetime((released, owned)) {}
    }
    // Reports whether a registration is live, or one that was reported live is still being cancelled,
    // when that changed. An observer of the assignment runs before the property changes and can end or
    // resume the observation, so a report made meanwhile waits: the assignment in progress finishes, and
    // then this reads the state again and reports it if it differs from what was assigned.
    private func report() {
        guard !reporting, let surface else { return }
        reporting = true
        defer { reporting = false }
        while true {
            let live = if case .installed(_, _, live: true) = registration { true } else { false }
            let observing = live || (reported && cancelling > 0)
            guard observing != reported else { return }
            reported = observing
            surface.report(observing: observing)
        }
    }
    private func show(_ next: Snapshot, revision: UInt64, displacing displaced: inout [Snapshot]) {
        announced = revision
        guard let surface else {
            if let replaced = exchange(&snapshot, with: next) { displaced.append(replaced) }
            return
        }
        surface.present(next) {
            if let replaced = exchange(&snapshot, with: next) { displaced.append(replaced) }
        }
    }
}
