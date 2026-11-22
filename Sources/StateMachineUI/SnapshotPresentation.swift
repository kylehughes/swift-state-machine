import Combine
import Observation
import StateMachine
import os

/// An `ObservableObject` projection of one complete `MainActor` snapshot across Apple platforms.
///
/// The Combine counterpart of ``SnapshotPresentation``, with the same observation operations and a
/// publisher of the snapshots it shows, ``presentedSnapshots``, for apps that deploy before iOS 17.0.
/// It supports every deployment target of the package, including iOS 16.0. This object owns
/// observation only. The enclosing screen or service owns the live machine and decides when
/// navigating away closes its work scope. Released on another thread, it closes its registration's
/// gate at once to stop a generated owner's delivery, and leaves the rest to a later main-actor turn,
/// which finishes the publisher's subscribers, removes its registration, and releases its snapshot,
/// its closures, and any unread element on the main actor once that removal completes.
@MainActor public final class SnapshotObservableObject<Snapshot>: ObservableObject {
    /// The latest complete snapshot, kept whole so phase fields cannot diverge.
    ///
    /// `objectWillChange` announces each change before it is made. The presentation keeps the snapshot
    /// in storage that a main-actor turn empties when the presentation is released, so its stored
    /// properties never hold a snapshot of their own.
    public var snapshot: Snapshot { core.shownSnapshot }
    /// Whether this presentation currently owns a live registration.
    ///
    /// It becomes `true` once the presentation has shown a new observation's first snapshot, after
    /// every snapshot publication in progress then has returned, if the observation's registration is
    /// still open, and `false` when that observation ends. A registration is open whether or not more
    /// snapshots wait in it, so an observation whose owner delivers without pause is live while it
    /// does. An observation of a sequence that has delivered no element yet is not live until its
    /// first element is shown, and one whose sequence has finished with its final element still
    /// unread is not live. A refused observation, and one whose registration has already ended,
    /// leaves it `false` and publishes nothing. It becomes `false` only once the registrations the
    /// presentation let go have been removed, which is when a custom host frees the slot of a token,
    /// so a host that ends the observation from inside its own cancellation of that token has the
    /// slot free by then. Any change to `true` that follows waits behind it.
    @Published public private(set) var isObserving = false
    private let core: PresentationCore<SnapshotObservableObject>
    /// The work the presentation has spent deciding whether a registration waits for earlier ones, and
    /// adding and removing attempts, which tests read.
    package var examinedRegistrationAttempts: Int { core.examinedAttempts }
    /// The serials and the records of removed serials that the presentation's index of attempts keeps,
    /// which tests read.
    package var retainedRegistrationSerials: Int { core.retainedSerials }
    // The subscribers of `presentedSnapshots`. It holds no snapshot.
    private let feed = PresentationFeed<Snapshot>()

    /// Creates a historical projection without subscribing or starting work.
    public init(_ initial: Snapshot, revision: @escaping @MainActor (Snapshot) -> UInt64) {
        core = PresentationCore(initial, watermark: revision(initial), revision: revision)
        core.surface = self
        feed.current = { [weak self] in self?.snapshot }
    }
    // A presentation can be released on another thread when an object storing it is released there.
    // The registration's gate closes at once to stop delivery and free a generated owner's slot. One
    // later main-actor turn then finishes the publisher's subscribers, removes the registration, and
    // clears its token, releasing the shown snapshot, closures, and every value the observation held
    // on the main actor once that removal completes (which a custom host cancelling the token on
    // another thread can delay). The core holds those values alone, so they are released on the main
    // actor even when that turn runs before this presentation's own storage is destroyed.
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
    /// It follows the same publication rules as ``presentedSnapshots``, emitting the projection of the
    /// snapshot shown when a subscriber attaches and then each newly shown snapshot in the order and
    /// at the times that ``PresentationPublisher`` describes. It stays open across observations and
    /// finishes once the presentation is released.
    public func presentedSnapshots<Projection: Sendable>(
        projecting transform: @escaping @MainActor (Snapshot) -> Projection
    ) -> PresentationPublisher<Projection> {
        PresentationPublisher(feed, transform)
    }
    /// Applies a newer complete snapshot synchronously so delayed delivery cannot regress the model.
    ///
    /// A snapshot applied after an observation starts belongs to that observation, so the
    /// observation's first snapshot does not replace one that is at least as new. A snapshot whose
    /// revision closure starts another observation belongs to the observation it replaced and is not
    /// applied. A snapshot applied from a callback of a publication is shown once that publication's
    /// callbacks return. One that will not be shown then, because its observation ended or the task
    /// following it was cancelled first, holds back no newer snapshot.
    @discardableResult public func apply(_ next: Snapshot) -> Bool { core.apply(next) }
    /// Observes a single-pass snapshot sequence, such as an owner's projected `snapshots(_:)`, from its
    /// first element.
    ///
    /// A sequence's first element is the snapshot current when it registered, or a newer one, so the
    /// presentation shows it at once when it arrives and restarts its revision check from it. The
    /// caller supplies no baseline, and the sequence may come from a different owner than the one
    /// shown so far. ``isObserving`` becomes `true` once that element is shown, so a sequence whose
    /// owner delivers its first element later, such as a shared owner, is live from then.
    ///
    /// Each later element is applied on the main actor through the revision check. At most 32 of the
    /// sequence's elements, including the first, are applied in one main-actor turn, with the rest on
    /// later turns regardless of what an earlier observation applied in that turn, so a sequence that
    /// delivers again from each snapshot shown cannot hold the main actor and stays live while it
    /// does. Snapshots that a replaced observation still delivers are discarded.
    ///
    /// ``isObserving`` becomes `false` when the sequence ends, while ``snapshot`` keeps the last value
    /// applied. A sequence that has already ended, such as a closed owner's, or that ends while its
    /// first element is shown, shows the snapshot it holds while ``isObserving`` stays `false`. A
    /// sequence that another consumer is already iterating belongs to that consumer, so the
    /// presentation shows nothing from it, reports nothing, and never ends it. The presentation owns
    /// any other sequence from the moment of the call, before ending the current observation, so a
    /// callback of that end that stops observing or starts another observation releases the sequence
    /// like any registration it lets go, and ``isObserving`` becomes `false` only once the sequence's
    /// slot is free.
    public func observe(_ snapshots: SnapshotSequence<Snapshot>) where Snapshot: Sendable {
        core.observe(snapshots)
    }
    /// Ends the current observation, then registers a snapshot sequence with `register` and observes
    /// it from its first element.
    ///
    /// Use this method to observe a projection of an owner, such as
    /// `try presentation.observe(snapshotsFrom: { try host.snapshots(project) })`, where `project`
    /// keeps the snapshot's revision for the revision check, as in
    /// `{ TitleSnapshot(revision: $0.revision, title: $0.title) }`. The current observation releases
    /// its registration before `register` runs, so observing the same owner again needs no spare
    /// slot. Calling `observe(try host.snapshots(project))` registers first because Swift evaluates
    /// the argument before the call, which an owner with one slot would refuse.
    ///
    /// The returned sequence is observed as ``observe(_:)-(SnapshotSequence<Snapshot>)`` observes a
    /// sequence. If `register` throws, this method throws, nothing is shown, and ``isObserving`` is
    /// `false`. An observation started from a callback that `register` runs replaces this one,
    /// releasing the returned sequence at once without throwing a refusal. Because this call cannot
    /// wait, `register` runs immediately even while an earlier asynchronous registration of this
    /// presentation is still in flight, and an owner whose only slot that registration holds refuses
    /// this one and throws the refusal.
    public func observe<Failure: Error>(
        snapshotsFrom register: () throws(Failure) -> SnapshotSequence<Snapshot>
    ) throws(Failure) where Snapshot: Sendable {
        try core.observe(snapshotsFrom: register)
    }
    /// Ends the current observation, then registers a snapshot sequence with `register`, which may
    /// await its owner, and observes it from its first element.
    ///
    /// Use this method to observe a projection of an owner that registers across a suspension, such as
    /// `try await presentation.observe(snapshotsFrom: { try await host.snapshots(project) })` for an
    /// actor owner. `register` runs on the main actor once the current observation has released its
    /// registration and once every registration that an earlier observation of this presentation is
    /// still making, through a closure or with an owner, has returned and been installed or released,
    /// so observing the same owner again needs no spare slot even while an earlier `register` still
    /// awaits it.
    ///
    /// An observation or ``stopObserving()`` that replaces this one during that wait makes this call
    /// return without running `register`. The returned sequence is observed as
    /// ``observe(_:)-(SnapshotSequence<Snapshot>)`` observes a sequence, and this call returns once its
    /// first element, if it holds one, is shown (including after any snapshot publication in progress
    /// finishes its callbacks). The observation then belongs to the presentation rather than to the
    /// calling task. If `register` throws, this method throws, nothing is shown, and ``isObserving`` is
    /// `false`. An observation or ``stopObserving()`` that replaces this one while `register` runs
    /// releases the returned sequence at once without throwing a refusal.
    public func observe<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure) where Snapshot: Sendable {
        try await core.observe(snapshotsFrom: register)
    }
    /// Observes a `MainActor` owner from its current snapshot.
    ///
    /// The owner's registration supplies the current snapshot and every later one from one ordering
    /// point. The presentation shows the first at once and restarts its revision check from it, so the
    /// caller supplies no baseline. Deliveries and the finish of a replaced observation are discarded.
    /// If the owner refuses the registration, this throws and ``isObserving`` is `false`. When the
    /// owner finishes the registration by closing or being released, the observation cancels its
    /// subscription before ``isObserving`` becomes `false`, so a custom host that frees its slot only
    /// when its subscription is cancelled has the slot free by then.
    ///
    /// An observation started while an earlier one is still registering, such as from a callback that
    /// registration runs, replaces it. Because this call cannot wait, it registers at once and throws
    /// any refusal immediately, including when the earlier registration or one the owner is still
    /// cancelling holds the owner's only slot. Nothing registers later. To observe again while a
    /// cancellation is in progress, use an asynchronous form that waits for earlier registrations.
    public func observe<Host: MainActorStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try core.observe(host)
    }
    /// Observes an owner confined to the main actor from its current snapshot.
    ///
    /// The owner's registration supplies the current snapshot and every later one from one ordering
    /// point, as for a `MainActor` owner, and an observation started while an earlier one is still
    /// registering replaces it the same way. ``isObserving`` becomes `false` when the owner closes or
    /// is released without closing, once the observation has cancelled its registration on the main actor.
    public func observe<Host: IsolatedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Owner == MainActor, Host.Snapshot == Snapshot {
        try core.observe(host)
    }
    /// Observes a shared owner from its current snapshot.
    ///
    /// The presentation registers the owner's snapshot sequence, then shows the owner's current snapshot
    /// read once the registration exists, restarts its revision check from it, and follows the
    /// sequence, so the caller supplies no baseline. Snapshots that a replaced observation still
    /// delivers are discarded. If the owner refuses the registration, this throws, nothing is shown,
    /// and ``isObserving`` is `false`. An owner that has already closed shows its closed snapshot
    /// while ``isObserving`` stays `false`, as does a sequence that ends while its first snapshot is
    /// shown. The presentation owns the registration before reading the snapshot, so an observation
    /// started from that read releases it. An observation started from inside the owner's registration
    /// call replaces this one, and if the owner refuses it while this one holds the slot, that
    /// refusal throws at once.
    public func observe<Host: SharedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try core.observe(host)
    }
    /// Observes an actor owner from its current snapshot.
    ///
    /// The presentation ends its current observation at once and registers the owner's snapshot
    /// sequence once every earlier registration of this presentation with the same owner, or through
    /// a closure, has returned and been installed or released, so observing the same owner again
    /// needs no spare slot. It owns the registration as soon as the owner returns it to the main
    /// actor, then reads the owner's current snapshot, shows it (or the registration's unread
    /// snapshot when that is at least as new), restarts its revision check from it, and follows the
    /// sequence. A refusal shows nothing, and an owner that has closed by then shows its closed
    /// snapshot while ``isObserving`` stays `false`.
    ///
    /// An observation or ``stopObserving()`` that replaces this one while it awaits the owner
    /// releases what this one registered, at once when the registration has already returned, and
    /// this call returns without throwing. One that replaces it during the wait makes it return
    /// without registering. Cancelling its task ends the wait, and it registers at once. If the owner
    /// refuses the registration, this throws and ``isObserving`` is `false`.
    public func observe<Host: ActorStateMachineHost>(_ host: Host) async throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try await core.observe(host)
    }
    /// Observes an owner confined to another actor from its current snapshot.
    ///
    /// Call this method on the owning actor. The owner's registration and its current snapshot, read
    /// after it, are taken on the owning actor in one turn and then handed to the main actor, where
    /// the presentation shows that snapshot, restarts its revision check from it, and follows the
    /// registration. A refusal shows nothing, and an owner that has already closed shows its closed
    /// snapshot while ``isObserving`` stays `false`. The presentation's current observation ends first,
    /// and the registration is taken once every earlier registration of this presentation with the
    /// same owner, or through a closure, has returned and been installed or released, so observing the
    /// same owner again needs no spare slot. An observation replacing this one during that wait makes
    /// it return without registering, and cancelling its task ends the wait.
    ///
    /// The observation owns the hand-off from its start. An observation started on the main actor
    /// before the hand-off arrives replaces this one, and the owning actor then stops the
    /// registration's delivery as soon as the host returns it without reading a snapshot for it while
    /// the main actor removes it. A replacement that needs its slot registers once that removal
    /// completes. If the owner refuses the registration, this throws, the presentation has stopped
    /// observing, and ``isObserving`` is `false`.
    public func observe<Host: IsolatedStateMachineHost>(
        _ host: Host,
        isolation: isolated Host.Owner = #isolation
    ) async throws(SubscriptionFailure) where Host.Snapshot == Snapshot, Snapshot: Sendable {
        try await core.observe(host, isolation: isolation)
    }
    /// Observes a single-pass snapshot sequence from its first element for as long as the calling task runs.
    ///
    /// The sequence seeds the revision check with its first element, and later elements are applied
    /// and the observation reported live as they are when the sequence is observed without a task.
    /// The observation belongs to the calling task, so this call returns only once the observation
    /// has ended because the sequence ended, the task was cancelled, or ``stopObserving()`` or
    /// another observation replaced it. That includes starting inside a snapshot callback, whose
    /// publication shows the first snapshot after the callback returns and decides then, running no
    /// other client code, whether the observation is live, after which the task applies waiting elements.
    ///
    /// Cancelling the task ends the observation at its next wait, either the wait for an element or
    /// the yield after 32 elements. A cancellation issued by a snapshot callback while the task
    /// applies elements ends the observation before the task shows another element or reports the
    /// observation live, as does a cancellation issued by the revision closure. The element being
    /// evaluated is not shown, nor is an element that a snapshot publication in progress was about to
    /// show once its callbacks return if the task is cancelled before then. This suits SwiftUI's
    /// `task` modifier, which cancels the task when the view disappears. A task that is already
    /// cancelled, or cancelled while the replaced observation ends (such as by host code running when
    /// that registration is released), ends the current observation and releases the sequence without
    /// showing it. A sequence that another consumer is already iterating returns at once and is left
    /// to that consumer.
    public func follow(_ snapshots: SnapshotSequence<Snapshot>) async where Snapshot: Sendable {
        await core.follow(snapshots)
    }
    /// Ends the current observation, then registers a snapshot sequence with `register` and follows
    /// it for as long as the calling task runs.
    ///
    /// `register` runs on the main actor once the current observation has released its registration
    /// and once every registration that an earlier observation of this presentation is still making
    /// has returned and been installed or released, so following the same owner again needs no spare
    /// slot. `register` may await an owner, as `try await host.snapshots(project)` does for an actor
    /// owner. A replacement, a stop, or task cancellation during that wait makes this return without
    /// running `register`. The returned sequence is followed as ``follow(_:)`` follows a sequence,
    /// and this call returns once that observation has ended and any snapshot publication in progress
    /// has shown the snapshot the observation accepted. If `register` throws, this method throws,
    /// nothing is shown, and ``isObserving`` is `false`. No refusal is thrown once another
    /// observation or task cancellation has replaced this one. A task already cancelled ends the
    /// current observation and registers nothing, and one cancelled while `register` runs releases
    /// the returned sequence.
    public func follow<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure) where Snapshot: Sendable {
        try await core.follow(snapshotsFrom: register)
    }
    /// Removes this presentation's registration synchronously.
    ///
    /// A registration that an owner is still making, when a callback of its registration call stops
    /// the presentation, is released as soon as that call returns it.
    public func stopObserving() { core.stopObserving() }
}

extension SnapshotObservableObject: PresentationSurface {
    fileprivate func present(_ next: Snapshot, assign: () -> Void) {
        objectWillChange.send()
        feed.send(next)
        assign()
    }
    fileprivate func report(observing: Bool) { isObserving = observing }
}

extension SnapshotObservableObject where Snapshot: Sendable {
    /// A Combine publisher of the snapshots the presentation shows.
    ///
    /// It publishes the snapshot shown when a subscriber attaches, then each newly shown snapshot. A
    /// change the subscriber has demand for arrives after `objectWillChange` and before ``snapshot``
    /// returns it, while a buffered one arrives once the subscriber has demand again, as
    /// ``PresentationPublisher`` describes.
    ///
    /// It belongs to the presentation rather than to one observation, so it stays open across
    /// ``stopObserving()`` and every later observation, and ``isObserving`` reports whether an
    /// observation is live. Once the presentation is released, it finishes, and any subscriber
    /// attaching afterward receives `.finished` at once. Publish a non-`Sendable` snapshot through
    /// ``presentedSnapshots(projecting:)``.
    public var presentedSnapshots: PresentationPublisher<Snapshot> { PresentationPublisher(feed) { $0 } }
}

extension SnapshotObservableObject where Snapshot: StateMachineSnapshot {
    /// Creates a historical projection of a generated snapshot without subscribing or starting work.
    public convenience init(_ initial: Snapshot) { self.init(initial, revision: { $0.revision }) }
}

/// An `@Observable` projection of one complete `MainActor` snapshot.
///
/// Only ``snapshot`` and ``isObserving`` are tracked. This object owns observation only. The
/// enclosing screen or service owns the live machine and decides when navigating away closes its work
/// scope. Requires iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, or Mac Catalyst 17.0
/// and later. Use ``SnapshotObservableObject`` for earlier OS releases. Released on another thread,
/// it closes its registration's gate at once to stop a generated owner's delivery, and leaves the
/// rest to a later main-actor turn, which removes its registration and releases its snapshot, its
/// closures, and any unread element on the main actor once that removal completes.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
@MainActor @Observable public final class SnapshotPresentation<Snapshot> {
    /// The latest complete snapshot, kept whole so observed phase fields cannot diverge.
    ///
    /// The model keeps the snapshot in storage that a main-actor turn empties when the model is
    /// released, so its stored properties never hold a snapshot of their own.
    public var snapshot: Snapshot {
        access(keyPath: \.snapshot)
        return core.shownSnapshot
    }
    /// Whether this model currently owns a live registration.
    ///
    /// It becomes `true` once the model has shown a new observation's first snapshot, after every
    /// snapshot change in progress then has been made, if the observation's registration is still
    /// open, and `false` when that observation ends. A registration is open whether or not more
    /// snapshots wait in it, so an observation whose owner delivers without pause is live while it
    /// does. An observation of a sequence that has delivered no element yet is not live until its
    /// first element is shown, and one whose sequence has finished with its final element still
    /// unread is not live. A refused observation, and one whose registration has already ended,
    /// leaves it `false` and changes nothing. It becomes `false` only once the registrations the model
    /// let go have been removed, which is when a custom host frees the slot of a token, so a host
    /// that ends the observation from inside its own cancellation of that token has the slot free by
    /// then. Any change to `true` that follows waits behind it.
    public private(set) var isObserving = false
    @ObservationIgnored private let core: PresentationCore<SnapshotPresentation>
    /// The work the model has spent deciding whether a registration waits for earlier ones, and adding
    /// and removing attempts, which tests read.
    package var examinedRegistrationAttempts: Int { core.examinedAttempts }
    /// The serials and the records of removed serials that the presentation's index of attempts keeps,
    /// which tests read.
    package var retainedRegistrationSerials: Int { core.retainedSerials }

    /// Creates a historical projection without subscribing or starting work.
    public init(_ initial: Snapshot, revision: @escaping @MainActor (Snapshot) -> UInt64) {
        core = PresentationCore(initial, watermark: revision(initial), revision: revision)
        core.surface = self
    }
    // A presentation can be released on another thread when an object storing it is released there.
    // The registration's gate closes at once to stop delivery and free a generated owner's slot. One
    // later main-actor turn then removes the registration and clears its token, releasing the shown
    // snapshot, closures, and every value the observation held on the main actor once that removal
    // completes (which a custom host cancelling the token on another thread can delay). The core
    // holds those values alone, so they are released on the main actor even when that turn runs
    // before this model's own storage is destroyed.
    deinit {
        core.gate.close()
        let core = core
        Task { @MainActor in core.dispose() }
        DestructorPause.reached()
    }
    /// Applies a newer complete snapshot synchronously so delayed delivery cannot regress the model.
    ///
    /// A snapshot applied after an observation starts belongs to that observation, so the
    /// observation's first snapshot does not replace one that is at least as new. A snapshot whose
    /// revision closure starts another observation belongs to the observation it replaced and is not
    /// applied. A snapshot applied from a callback of a publication is shown once that publication's
    /// callbacks return. One that will not be shown then, because its observation ended or the task
    /// following it was cancelled first, holds back no newer snapshot.
    @discardableResult public func apply(_ next: Snapshot) -> Bool { core.apply(next) }
    /// Observes a single-pass snapshot sequence, such as an owner's projected `snapshots(_:)`, from its
    /// first element.
    ///
    /// A sequence's first element is the snapshot current when it registered, or a newer one, so the
    /// model shows it at once when it arrives and restarts its revision check from it. The caller
    /// supplies no baseline, and the sequence may come from a different owner than the one shown so
    /// far. ``isObserving`` becomes `true` once that element is shown, so a sequence whose owner
    /// delivers its first element later, such as a shared owner, is live from then.
    ///
    /// Each later element is applied on the main actor through the revision check. At most 32 of the
    /// sequence's elements, including the first, are applied in one main-actor turn, with the rest on
    /// later turns regardless of what an earlier observation applied in that turn, so a sequence that
    /// delivers again from each snapshot shown cannot hold the main actor and stays live while it
    /// does. Snapshots that a replaced observation still delivers are discarded.
    ///
    /// ``isObserving`` becomes `false` when the sequence ends, while ``snapshot`` keeps the last value
    /// applied. A sequence that has already ended, such as a closed owner's, or that ends while its
    /// first element is shown, shows the snapshot it holds while ``isObserving`` stays `false`. A
    /// sequence that another consumer is already iterating belongs to that consumer, so the model
    /// shows nothing from it, reports nothing, and never ends it. The model owns any other sequence
    /// from the moment of the call, before ending the current observation, so a callback of that end
    /// that stops observing or starts another observation releases the sequence like any registration
    /// it lets go, and ``isObserving`` becomes `false` only once the sequence's slot is free.
    public func observe(_ snapshots: SnapshotSequence<Snapshot>) where Snapshot: Sendable {
        core.observe(snapshots)
    }
    /// Ends the current observation, then registers a snapshot sequence with `register` and observes
    /// it from its first element.
    ///
    /// Use this method to observe a projection of an owner, such as
    /// `try model.observe(snapshotsFrom: { try host.snapshots(project) })`, where `project` keeps
    /// the snapshot's revision for the revision check, as in
    /// `{ TitleSnapshot(revision: $0.revision, title: $0.title) }`. The current observation releases
    /// its registration before `register` runs, so observing the same owner again needs no spare
    /// slot. Calling `observe(try host.snapshots(project))` registers first because Swift evaluates
    /// the argument before the call, which an owner with one slot would refuse.
    ///
    /// The returned sequence is observed as ``observe(_:)-(SnapshotSequence<Snapshot>)`` observes a
    /// sequence. If `register` throws, this method throws, nothing is shown, and ``isObserving`` is
    /// `false`. An observation started from a callback that `register` runs replaces this one,
    /// releasing the returned sequence at once without throwing a refusal. Because this call cannot
    /// wait, `register` runs immediately even while an earlier asynchronous registration of this model
    /// is still in flight, and an owner whose only slot that registration holds refuses this one and
    /// throws the refusal.
    public func observe<Failure: Error>(
        snapshotsFrom register: () throws(Failure) -> SnapshotSequence<Snapshot>
    ) throws(Failure) where Snapshot: Sendable {
        try core.observe(snapshotsFrom: register)
    }
    /// Ends the current observation, then registers a snapshot sequence with `register`, which may
    /// await its owner, and observes it from its first element.
    ///
    /// Use this method to observe a projection of an owner that registers across a suspension, such as
    /// `try await model.observe(snapshotsFrom: { try await host.snapshots(project) })` for an actor
    /// owner. `register` runs on the main actor once the current observation has released its
    /// registration and once every registration that an earlier observation of this model is still
    /// making, through a closure or with an owner, has returned and been installed or released, so
    /// observing the same owner again needs no spare slot even while an earlier `register` still
    /// awaits it.
    ///
    /// An observation or ``stopObserving()`` that replaces this one during that wait makes this call
    /// return without running `register`. The returned sequence is observed as
    /// ``observe(_:)-(SnapshotSequence<Snapshot>)`` observes a sequence, and this call returns once its
    /// first element, if it holds one, is shown (including after any snapshot publication in progress
    /// finishes its callbacks). The observation then belongs to the model rather than to the calling
    /// task. If `register` throws, this method throws, nothing is shown, and ``isObserving`` is
    /// `false`. An observation or ``stopObserving()`` that replaces this one while `register` runs
    /// releases the returned sequence at once without throwing a refusal.
    public func observe<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure) where Snapshot: Sendable {
        try await core.observe(snapshotsFrom: register)
    }
    /// Observes a `MainActor` owner from its current snapshot.
    ///
    /// The owner's registration supplies the current snapshot and every later one from one ordering
    /// point. The model shows the first at once and restarts its revision check from it, so the caller
    /// supplies no baseline. Deliveries and the finish of a replaced observation are discarded. If
    /// the owner refuses the registration, this throws and ``isObserving`` is `false`. When the owner
    /// finishes the registration by closing or being released, the observation cancels its
    /// subscription before ``isObserving`` becomes `false`, so a custom host that frees its slot only
    /// when its subscription is cancelled has the slot free by then.
    ///
    /// An observation started while an earlier one is still registering, such as from a callback that
    /// registration runs, replaces it. Because this call cannot wait, it registers at once and throws
    /// any refusal immediately, including when the earlier registration or one the owner is still
    /// cancelling holds the owner's only slot. Nothing registers later. To observe again while a
    /// cancellation is in progress, use an asynchronous form that waits for earlier registrations.
    public func observe<Host: MainActorStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try core.observe(host)
    }
    /// Observes an owner confined to the main actor from its current snapshot.
    ///
    /// The owner's registration supplies the current snapshot and every later one from one ordering
    /// point, as for a `MainActor` owner, and an observation started while an earlier one is still
    /// registering replaces it the same way. ``isObserving`` becomes `false` when the owner closes or
    /// is released without closing, once the observation has cancelled its registration on the main actor.
    public func observe<Host: IsolatedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Owner == MainActor, Host.Snapshot == Snapshot {
        try core.observe(host)
    }
    /// Observes a shared owner from its current snapshot.
    ///
    /// The model registers the owner's snapshot sequence, then shows the owner's current snapshot read
    /// once the registration exists, restarts its revision check from it, and follows the sequence, so
    /// the caller supplies no baseline. Snapshots that a replaced observation still delivers are
    /// discarded. If the owner refuses the registration, this throws, nothing is shown, and
    /// ``isObserving`` is `false`. An owner that has already closed shows its closed snapshot while
    /// ``isObserving`` stays `false`, as does a sequence that ends while its first snapshot is shown.
    /// The model owns the registration before reading the snapshot, so an observation started from
    /// that read releases it. An observation started from inside the owner's registration call
    /// replaces this one, and if the owner refuses it while this one holds the slot, that refusal
    /// throws at once.
    public func observe<Host: SharedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try core.observe(host)
    }
    /// Observes an actor owner from its current snapshot.
    ///
    /// The model ends its current observation at once and registers the owner's snapshot sequence once
    /// every earlier registration of this model with the same owner, or through a closure, has
    /// returned and been installed or released, so observing the same owner again needs no spare
    /// slot. It owns the registration as soon as the owner returns it to the main actor, then reads
    /// the owner's current snapshot, shows it (or the registration's unread snapshot when that is at
    /// least as new), restarts its revision check from it, and follows the sequence. A refusal shows
    /// nothing, and an owner that has closed by then shows its closed snapshot while ``isObserving``
    /// stays `false`.
    ///
    /// An observation or ``stopObserving()`` that replaces this one while it awaits the owner
    /// releases what this one registered, at once when the registration has already returned, and
    /// this call returns without throwing. One that replaces it during the wait makes it return
    /// without registering. Cancelling its task ends the wait, and it registers at once. If the owner
    /// refuses the registration, this throws and ``isObserving`` is `false`.
    public func observe<Host: ActorStateMachineHost>(_ host: Host) async throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try await core.observe(host)
    }
    /// Observes an owner confined to another actor from its current snapshot.
    ///
    /// Call this method on the owning actor. The owner's registration and its current snapshot, read
    /// after it, are taken on the owning actor in one turn and then handed to the main actor, where
    /// the model shows that snapshot, restarts its revision check from it, and follows the
    /// registration. A refusal shows nothing, and an owner that has already closed shows its closed
    /// snapshot while ``isObserving`` stays `false`. The model's current observation ends first, and
    /// the registration is taken once every earlier registration of this model with the same owner, or
    /// through a closure, has returned and been installed or released, so observing the same owner
    /// again needs no spare slot. An observation replacing this one during that wait makes it return
    /// without registering, and cancelling its task ends the wait.
    ///
    /// The observation owns the hand-off from its start. An observation started on the main actor
    /// before the hand-off arrives replaces this one, and the owning actor then stops the
    /// registration's delivery as soon as the host returns it without reading a snapshot for it while
    /// the main actor removes it. A replacement that needs its slot registers once that removal
    /// completes. If the owner refuses the registration, this throws, the model has stopped
    /// observing, and ``isObserving`` is `false`.
    public func observe<Host: IsolatedStateMachineHost>(
        _ host: Host,
        isolation: isolated Host.Owner = #isolation
    ) async throws(SubscriptionFailure) where Host.Snapshot == Snapshot, Snapshot: Sendable {
        try await core.observe(host, isolation: isolation)
    }
    /// Observes a single-pass snapshot sequence from its first element for as long as the calling task runs.
    ///
    /// The sequence seeds the revision check with its first element, and later elements are applied
    /// and the observation reported live as they are when the sequence is observed without a task.
    /// The observation belongs to the calling task, so this call returns only once the observation
    /// has ended because the sequence ended, the task was cancelled, or ``stopObserving()`` or
    /// another observation replaced it. That includes starting inside a snapshot callback, whose
    /// publication shows the first snapshot after the callback returns and decides then, running no
    /// other client code, whether the observation is live, after which the task applies waiting elements.
    ///
    /// Cancelling the task ends the observation at its next wait, either the wait for an element or
    /// the yield after 32 elements. A cancellation issued by a snapshot callback while the task
    /// applies elements ends the observation before the task shows another element or reports the
    /// observation live, as does a cancellation issued by the revision closure. The element being
    /// evaluated is not shown, nor is an element that a snapshot publication in progress was about to
    /// show once its callbacks return if the task is cancelled before then. This suits SwiftUI's
    /// `task` modifier, which cancels the task when the view disappears. A task that is already
    /// cancelled, or cancelled while the replaced observation ends (such as by host code running when
    /// that registration is released), ends the current observation and releases the sequence without
    /// showing it. A sequence that another consumer is already iterating returns at once and is left
    /// to that consumer.
    public func follow(_ snapshots: SnapshotSequence<Snapshot>) async where Snapshot: Sendable {
        await core.follow(snapshots)
    }
    /// Ends the current observation, then registers a snapshot sequence with `register` and follows
    /// it for as long as the calling task runs.
    ///
    /// `register` runs on the main actor once the current observation has released its registration
    /// and once every registration that an earlier observation of this model is still making has
    /// returned and been installed or released, so following the same owner again needs no spare
    /// slot. `register` may await an owner, as `try await host.snapshots(project)` does for an actor
    /// owner. A replacement, a stop, or task cancellation during that wait makes this return without
    /// running `register`. The returned sequence is followed as ``follow(_:)`` follows a sequence,
    /// and this call returns once that observation has ended and any snapshot publication in progress
    /// has shown the snapshot the observation accepted. If `register` throws, this method throws,
    /// nothing is shown, and ``isObserving`` is `false`. No refusal is thrown once another
    /// observation or task cancellation has replaced this one. A task already cancelled ends the
    /// current observation and registers nothing, and one cancelled while `register` runs releases
    /// the returned sequence.
    public func follow<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure) where Snapshot: Sendable {
        try await core.follow(snapshotsFrom: register)
    }
    /// Removes this model's registration synchronously.
    ///
    /// A registration that an owner is still making, when a callback of its registration call stops
    /// the model, is released as soon as that call returns it.
    public func stopObserving() { core.stopObserving() }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
extension SnapshotPresentation: PresentationSurface {
    fileprivate func present(_ next: Snapshot, assign: () -> Void) { withMutation(keyPath: \.snapshot, assign) }
    fileprivate func report(observing: Bool) { isObserving = observing }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
extension SnapshotPresentation where Snapshot: StateMachineSnapshot {
    /// Creates a historical projection of a generated snapshot without subscribing or starting work.
    public convenience init(_ initial: Snapshot) { self.init(initial, revision: { $0.revision }) }
}

/// The two published values of a snapshot presentation, which its observation core keeps and assigns.
@MainActor private protocol PresentationSurface: AnyObject, SendableMetatype {
    associatedtype Snapshot
    var isObserving: Bool { get }
    /// Announces that the published snapshot changes to `next`, around `assign`, which stores it in
    /// the core.
    func present(_ next: Snapshot, assign: () -> Void)
    /// Assigns the published observation state.
    func report(observing: Bool)
}

/// The observation core shared by both snapshot presentations, managing which source a presentation
/// follows, which deliveries it applies, and when it reports that observation started or ended.
///
/// Each observation claims a generation, and every callback carries the generation it was registered
/// for, so a replaced observation's deliveries and finish are discarded.
///
/// Every registration with an owner, synchronous or across suspensions, is one attempt. An attempt is
/// in `registering` exactly while it is inside the owner's registration call or while the release of
/// the registration it obtained has not returned, which are the only times it may hold a slot the
/// presentation cannot count as free. `adopt` alone decides whether an answered attempt installs or
/// releases its registration, while `withdraw` handles a refusal. The presentation owns a
/// registration from the moment the owner returns it, before reading a snapshot or running any other
/// code, so a stop or newer observation can always release it. A synchronous observation registers at
/// once and throws any refusal at once. An asynchronous one first waits until no related attempt that
/// began before it is in `registering`, ordered by attempt serial, so it never registers while an
/// earlier attempt of its own holds the slot, and then throws any refusal at once.
///
/// What an observation shows and whether it reports itself live come from its registration. A
/// sequence's unread element outranks an older snapshot read separately, and the registration's state
/// is checked again after every callout so a registration that ended meanwhile, such as a closed
/// owner's, shows its last snapshot without reporting an observation.
@MainActor private final class PresentationCore<Surface: PresentationSurface> {
    typealias Snapshot = Surface.Snapshot

    /// A registration that waits for the attempts that were registering when it began.
    private struct RegistrationWait {
        let generation: UInt64
        // The attempts it waits for are the related ones in `registering` whose serial is below this.
        let boundary: UInt64
        let source: ObjectIdentifier?
        /// The cancellation of the calling task, when that ends the wait, or `nil` when it does not.
        let cancellation: WaitCancellation?
        let continuation: CheckedContinuation<Void, Never>
    }

    /// A value accepted for display while a snapshot publication was in progress, which that
    /// publication shows after its callbacks return, if the observation it belongs to is still current
    /// then and, for a value accepted while a task followed that observation, that task has not been
    /// cancelled since.
    private struct Deferred {
        let value: Snapshot
        let revision: UInt64
        let generation: UInt64
        let cancellation: WaitCancellation?
        // The count of accepted values once this one was accepted, so a value skipped before any later
        // one was accepted gives its revision back.
        let accepted: UInt64
    }
    /// The task that follows an observation, by the observation's generation and the record of that
    /// task's cancellation, which its cancellation handler sets on whichever thread cancels it.
    private struct Follower {
        let generation: UInt64
        let cancellation: WaitCancellation
    }

    weak var surface: Surface?
    // Replaced by a closure that captures nothing when a released presentation is disposed of, so the
    // client's closure is released on the main actor.
    private var revision: @MainActor (Snapshot) -> UInt64
    // The snapshot the surface shows, which the surface reads from here. A presentation released on
    // another thread destroys its own storage there, so this core, held by the main-actor turn that
    // disposes of it, keeps the snapshot's only reference until that turn.
    private var shown: Snapshot?
    // The revision of `shown`, or of the snapshot a publication in progress is assigning, whose
    // assignment follows its announcement's callbacks whatever they do. A deferred value that will not
    // be shown gives the watermark back to it.
    private var shownRevision: UInt64
    /// The gate of the registration the current observation holds, which a presentation's destructor
    /// closes on whatever thread releases it.
    nonisolated let gate = PresentationGate()
    private var watermark: UInt64
    // Counts the values accepted for display, and the count when the current observation claimed its
    // generation, so a restart of the revision check can tell that this observation already accepted a
    // value, through `apply`, before its first snapshot arrived.
    private var accepted: UInt64 = 0
    private var acceptedAtClaim: UInt64 = 0
    // The snapshot publication in progress, or `nil` when none is.
    private var publication: Publication?
    /// A snapshot publication in progress and what waits for it to return.
    private struct Publication {
        // A value accepted while it runs, which it shows after its callbacks return.
        var deferred: Deferred?
        // Deferred values that it will not show, because their observation ended or the task that
        // follows it was cancelled, released with the snapshots it displaces.
        var abandoned: [Snapshot] = []
        // The step that decides whether the current observation is live, deferred because the
        // observation's first snapshot is assigned only once this publication's callbacks return, and
        // liveness is never reported before the snapshot it is about. It runs at the end, or is dropped
        // when its observation has ended by then.
        var step: DeferredStep?
        // What waits for it to return, as an asynchronous observation whose first snapshot it shows does.
        var ends: [@MainActor () -> Void] = []
    }
    // The task that follows the current observation, if a task follows it.
    private var follower: Follower?
    // The registration the current observation holds, whose gate is the one a destructor closes.
    private var held = HeldRegistration.none {
        didSet { gate.current = held.gate }
    }
    private var observation: Task<Void, Never>?
    // The owner of the current observation's registration, or `nil` for one registered through a
    // closure or handed over as a sequence, which may belong to any owner.
    private var source: ObjectIdentifier?
    // The releases of registrations this presentation has let go whose cancellations have not returned
    // yet, as when a host of your own cancels a token and ends the observation from inside that
    // cancellation. Each is also in `registering`, as an attempt that holds its slot, and a report that
    // an observation ended waits until none is left.
    private var releasing = 0
    private var generation: UInt64 = 0
    // The observation whose first delivery restarts the revision check, because it comes from a new source.
    private var seeding: UInt64?
    // The attempts inside an owner's registration call now, and the release records whose release has
    // not returned. One that a newer observation supersedes there still holds its slot until that call
    // returns its registration.
    private var registering = RegisteringAttempts<Snapshot>()
    /// How many attempts and serial positions the presentation has examined, and serials it has moved,
    /// to decide whether a registration waits and to add and remove attempts, which tests read as that
    /// work.
    var examinedAttempts: Int { registering.examined }
    /// How many serials, and records of removed ones, the index of attempts keeps.
    var retainedSerials: Int { registering.retained }
    // The serial of the next attempt or release record, which orders them against the waits.
    private var nextSerial: UInt64 = 0
    // The asynchronous registrations through a closure that wait for earlier attempts to settle before
    // they run their closures.
    private var registrationWaits: [RegistrationWait] = []
    // Whether an observation is live. `isObserving` reports it.
    private var live = false
    // The changes of `live` that `isObserving` has not reported yet, oldest first, and whether a report
    // is being assigned. A callback of that assignment can start or end an observation, and its change
    // waits here and is assigned after the one in progress.
    private var reports = PendingReports()
    private var reporting = false
    // The disposal state of a released presentation (not begun, waiting until no registration it made
    // or let go is still being made or removed, or done). While waiting, the core retains itself here
    // so releases find it when they return, and releases its client values only then.
    private var disposal = Disposal.none
    private enum Disposal {
        case none
        case waiting(keeping: PresentationCore)
        case done
    }

    init(_ shown: Snapshot, watermark: UInt64, revision: @escaping @MainActor (Snapshot) -> UInt64) {
        self.shown = shown
        shownRevision = watermark
        self.watermark = watermark
        self.revision = revision
    }
    /// The snapshot the surface shows.
    var shownSnapshot: Snapshot { shown! }
    deinit { observation?.cancel() }

    /// Disposes of the core of a released presentation, on the main actor.
    ///
    /// The presentation's destructor closed the current registration's gate where it ran. This ends the
    /// observation as `stopObserving()` does, removing the registration and clearing its token, and
    /// releases the client values the core holds (the shown snapshot, any deferred snapshot, the
    /// attempts' seeds, and the revision closure) once no registration this presentation made is still
    /// inside an owner's registration call or being removed. A custom host cancelling a token on
    /// another thread delays that until its cancellation returns, and an owner still inside a
    /// registration call delays it until that call returns and the presentation removes what it
    /// returned. The core keeps itself alive until then.
    func dispose() {
        _ = endObservation()
        guard case .none = disposal else { return }
        guard registering.isEmpty else {
            disposal = .waiting(keeping: self)
            return
        }
        completeDisposal()
    }
    // Releases the client values of a disposed core, once the registrations it let go are removed.
    private func completeDisposal() {
        var released = (
            shown, publication?.deferred, registering.attempts, revision, publication?.abandoned ?? [],
            exchange(&disposal, with: .done)
        )
        shown = nil
        publication?.deferred = nil
        registering.removeAll()
        publication?.abandoned = []
        follower = nil
        revision = { _ in 0 }
        let ends = publication?.ends ?? []
        publication?.ends = []
        for end in ends { end() }
        released = (nil, nil, [], { _ in 0 }, [], .done)
        withExtendedLifetime(released) {}
    }
    // The registration of a claimed sequence, which a destructor closes through its gate, or none for a
    // sequence that another consumer claimed.
    private static func registration(_ consumer: SnapshotSequence<Snapshot>.Consumer?) -> HeldRegistration
    where Snapshot: Sendable {
        guard let consumer else { return .none }
        return .release({ done in consumer.cancelOnMainActor(then: done) }, gate: consumer.gate)
    }

    // A callback of `revision` that starts another observation makes `next` a snapshot of the
    // observation it replaced, so `next` is applied only if the observation is unchanged afterward.
    func apply(_ next: Snapshot) -> Bool {
        let observing = generation
        let nextRevision = revision(next)
        guard generation == observing else { return false }
        settleDeferred()
        guard nextRevision > watermark else { return false }
        accept(next, revision: nextRevision)
        return true
    }

    // MARK: Observing sources

    func observe(_ snapshots: SnapshotSequence<Snapshot>) where Snapshot: Sendable {
        let consumer = snapshots.claim()
        let observing = endObservation(handing: Self.registration(consumer))
        guard let consumer, generation == observing else { return }
        schedule(consumer, observing: observing, present(consumer, current: nil, observing: observing))
    }
    func observe<Failure: Error>(
        snapshotsFrom register: () throws(Failure) -> SnapshotSequence<Snapshot>
    ) throws(Failure) where Snapshot: Sendable {
        // The current observation ends before the registration, so its slot is free for it. A
        // registration that an earlier asynchronous call is still making is not waited for: this call
        // runs `register` at once.
        let observing = endObservation()
        guard generation == observing else { return }
        let attempt = beginAttempt(observing, source: nil)
        let snapshots: SnapshotSequence<Snapshot>
        do throws(Failure) {
            snapshots = try register()
        } catch {
            withdraw(attempt)
            // A refusal of an observation that a callback of the registration replaced is not reported.
            guard generation == observing else { return }
            throw error
        }
        guard let (consumer, next) = begin(snapshots, observing: observing, attempt: attempt) else { return }
        schedule(consumer, observing: observing, next)
    }
    func observe<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure) where Snapshot: Sendable {
        // The current observation ends before the registration, so its slot is free for it, and
        // `register` runs only once every registration an earlier observation was still making has
        // returned and been released. An observation that replaces this one meanwhile owns the
        // presentation then: this one runs nothing, `begin` releases what `register` returns, and a
        // refusal is not reported.
        let observing = endObservation()
        guard generation == observing, await awaitEarlierRegistrations(observing, source: nil, cancellable: false)
        else { return }
        let attempt = beginAttempt(observing, source: nil)
        let snapshots: SnapshotSequence<Snapshot>
        do throws(Failure) {
            snapshots = try await register()
        } catch {
            withdraw(attempt)
            guard generation == observing else { return }
            throw error
        }
        guard let (consumer, next) = begin(snapshots, observing: observing, attempt: attempt) else { return }
        await scheduleShowingFirst(consumer, observing: observing, next)
    }
    func observe<Host: MainActorStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        try bind(source: ObjectIdentifier(host)) { [weak self] observing, attempt in
            do throws(SubscriptionFailure) {
                return .success(
                    .mainActor(
                        try host.subscribe(
                            { self?.receive($0, observing: observing, attempt: attempt) },
                            onFinish: { self?.finish(observing, attempt: attempt) }
                        )
                    )
                )
            } catch {
                return .failure(error)
            }
        }
    }
    func observe<Host: IsolatedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Owner == MainActor, Host.Snapshot == Snapshot {
        try bind(source: ObjectIdentifier(host)) { [weak self] observing, attempt in
            // The host releases its callbacks without calling them when it is released, so the receive
            // callback holds the signal that ends this observation then. The signal belongs to this
            // attempt, so the release of a refused attempt's callbacks ends nothing.
            let released = ObservationRelease { [weak self] in
                Task { @MainActor in self?.finish(observing, attempt: attempt) }
            }
            do throws(SubscriptionFailure) {
                return .success(
                    .isolated(
                        try host.subscribe(
                            { next in
                                withExtendedLifetime(released) {}
                                MainActor.assumeIsolated {
                                    self?.receive(next, observing: observing, attempt: attempt)
                                }
                            },
                            onFinish: { MainActor.assumeIsolated { self?.finish(observing, attempt: attempt) } },
                            isolation: MainActor.shared
                        )
                    )
                )
            } catch {
                return .failure(error)
            }
        }
    }
    func observe<Host: SharedStateMachineHost>(_ host: Host) throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        // The registration call is the attempt; the snapshot is read only once the presentation owns
        // the registration it returned, so an observation started from that read can release it.
        try bind(source: ObjectIdentifier(host)) { [weak self] _, _ in
            do throws(SubscriptionFailure) {
                let snapshots = try host.snapshots()
                guard let self else {
                    snapshots.claim()?.cancelOnMainActor()
                    return .success(.sequence(HeldSequence(registration: .none, present: { _ in })))
                }
                return .success(self.hold(snapshots) { host.snapshot() })
            } catch {
                return .failure(error)
            }
        }
    }
    func observe<Host: ActorStateMachineHost>(_ host: Host) async throws(SubscriptionFailure)
    where Host.Snapshot == Snapshot {
        // The current observation ends first, and this one registers once every earlier registration
        // with this owner, or through a closure, that the presentation is still making or removing has
        // returned, so observing the same owner again needs no spare slot.
        let observing = endObservation()
        let source = ObjectIdentifier(host)
        guard generation == observing, await awaitEarlierRegistrations(observing, source: source, cancellable: true)
        else { return }
        let attempt = beginAttempt(observing, source: source)
        let snapshots: SnapshotSequence<Snapshot>
        do throws(SubscriptionFailure) {
            snapshots = try await host.snapshots()
        } catch {
            withdraw(attempt)
            guard generation == observing else { return }
            throw error
        }
        // Back on the main actor, before any other await: the presentation takes the registration
        // now, so a stop or a newer observation during the snapshot read releases it.
        let consumer = snapshots.claim()
        guard adopt(Self.registration(consumer), of: attempt), let consumer else { return }
        let current = await host.snapshot()
        guard generation == observing else { return }
        await scheduleShowingFirst(
            consumer,
            observing: observing,
            present(consumer, current: current, observing: observing)
        )
    }
    func observe<Host: IsolatedStateMachineHost>(
        _ host: Host,
        isolation: isolated Host.Owner
    ) async throws(SubscriptionFailure) where Host.Snapshot == Snapshot, Snapshot: Sendable {
        // The current observation ends first, so a registration it holds no longer occupies a slot, and
        // this one registers once every earlier registration with this owner, or through a closure,
        // that the presentation is still making or removing has returned. The owning actor registers in
        // the turn that follows, without returning to the main actor first, so the attempt counts as
        // registering from here, and its hand-off is the observation's registration: a stop or a newer
        // observation releases what the owner returns, on whichever side comes second.
        guard let attempt = await beginHandoff(source: ObjectIdentifier(host)) else { return }
        let outcome: Result<Registered<Snapshot>, SubscriptionFailure>
        do {
            let snapshots = try host.snapshots({ $0 }, isolation: isolation)
            let claimed = snapshots.claim()
            if let claimed, attempt.handoff.hold({ done in claimed.cancelOnMainActor(then: done) }) {
                outcome = .success(
                    Registered(claimed: true, consumer: claimed, current: host.snapshot(isolation: isolation))
                )
            } else {
                // The presentation let the registration go before the host returned it: delivery stops
                // here at once, and the main actor removes the registration, settling the attempt only
                // once that removal has completed, so the slot is free before a replacement registers.
                claimed?.gate?.close()
                outcome = .success(Registered(claimed: claimed != nil, consumer: claimed, current: nil))
            }
        } catch {
            outcome = .failure(error)
        }
        if let refusal = await conclude(attempt, outcome) { throw refusal }
    }
    func follow(_ snapshots: SnapshotSequence<Snapshot>) async where Snapshot: Sendable {
        let cancellation = WaitCancellation()
        await withTaskCancellationHandler {
            await follow(snapshots, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }
    private func follow(_ snapshots: SnapshotSequence<Snapshot>, cancellation: WaitCancellation) async
    where Snapshot: Sendable {
        // A task that is already cancelled follows nothing, and neither does one that a host's code
        // cancels while the observation it replaces ends: the sequence is released without being shown,
        // before the end is reported. One that a callback of that report cancels releases it then.
        let consumer = snapshots.claim()
        let observing = endObservation(handing: Self.registration(consumer), unless: { Task.isCancelled })
        guard let consumer, generation == observing else { return }
        guard !Task.isCancelled else {
            _ = endObservation()
            return
        }
        follower = Follower(generation: observing, cancellation: cancellation)
        let next = present(consumer, current: nil, observing: observing, following: true)
        await Self.follow({ [weak self] in self }, consumer, observing: observing, from: next)
        await awaitOwnPublication(observing)
        endFollowing(observing)
    }
    func follow<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure) where Snapshot: Sendable {
        let cancellation = WaitCancellation()
        let followed: Result<Void, Failure> = await withTaskCancellationHandler {
            do throws(Failure) {
                try await follow(snapshotsFrom: register, cancellation: cancellation)
                return .success(())
            } catch {
                return .failure(error)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try followed.get()
    }
    private func follow<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>,
        cancellation: WaitCancellation
    ) async throws(Failure) where Snapshot: Sendable {
        let observing = endObservation()
        guard generation == observing, !Task.isCancelled,
            await awaitEarlierRegistrations(observing, source: nil, cancellable: true), !Task.isCancelled
        else { return }
        let attempt = beginAttempt(observing, source: nil)
        let snapshots: SnapshotSequence<Snapshot>
        do throws(Failure) {
            snapshots = try await register()
        } catch {
            withdraw(attempt)
            guard generation == observing, !Task.isCancelled else { return }
            throw error
        }
        guard
            let (consumer, next) = begin(snapshots, observing: observing, attempt: attempt, following: cancellation)
        else { return }
        await Self.follow({ [weak self] in self }, consumer, observing: observing, from: next)
        await awaitOwnPublication(observing)
        endFollowing(observing)
    }
    func stopObserving() { _ = endObservation() }
    // Clears the record of the task that followed the observation `observing`, which has returned; a
    // newer observation's record stays.
    private func endFollowing(_ observing: UInt64) {
        if follower?.generation == observing { follower = nil }
    }

    // MARK: Attempts

    // Records that the current observation `observing` is about to ask `source` for a registration,
    // or, when `source` is `nil`, a closure that may register with any owner.
    private func beginAttempt(_ observing: UInt64, source: ObjectIdentifier?) -> PresentationAttempt<Snapshot> {
        let attempt = PresentationAttempt<Snapshot>(generation: observing, source: source, serial: claimSerial())
        registering.insert(attempt)
        return attempt
    }
    private func claimSerial() -> UInt64 {
        defer { nextSerial += 1 }
        return nextSerial
    }
    // A record of the release of a registration with `source`, or with any owner when `source` is `nil`.
    private func releaseRecord(_ source: ObjectIdentifier?) -> PresentationAttempt<Snapshot> {
        PresentationAttempt(releasing: source, serial: claimSerial())
    }
    // Waits on the main actor until no registration that this presentation was making or removing
    // when this call began, with `source` or through a closure, or with any owner when `source` is
    // `nil`, is still in its owner's registration call or being removed, so the slot that registration
    // held is free again: each such attempt returns and is installed or released, and each release
    // returns, before the wait ends. Returns whether the observation `observing` is still current then.
    //
    // The wait ends then, when a newer observation or a stop replaces this one, or, when `cancellable`,
    // when the calling task is cancelled; the caller reads the cancellation. Only an asynchronous
    // registration waits; a synchronous one registers at once.
    private func awaitEarlierRegistrations(
        _ observing: UInt64,
        source: ObjectIdentifier?,
        cancellable: Bool
    ) async -> Bool {
        let boundary = nextSerial
        guard registering.holdsSlot(below: boundary, relatedTo: source) else { return true }
        let cancellation = WaitCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                registrationWaits.append(
                    RegistrationWait(
                        generation: observing,
                        boundary: boundary,
                        source: source,
                        cancellation: cancellable ? cancellation : nil,
                        continuation: continuation
                    )
                )
                resumeRegistrationWaits()
            }
        } onCancel: {
            guard cancellable else { return }
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.resumeRegistrationWaits() }
        }
        return generation == observing
    }
    // Ends every wait whose earlier registrations have all settled, whose observation was replaced, or
    // whose calling task was cancelled.
    private func resumeRegistrationWaits() {
        guard !registrationWaits.isEmpty else { return }
        var remaining: [RegistrationWait] = []
        var ended: [RegistrationWait] = []
        for wait in registrationWaits {
            let settled = !registering.holdsSlot(below: wait.boundary, relatedTo: wait.source)
            if settled || wait.generation != generation || wait.cancellation?.isCancelled == true {
                ended.append(wait)
            } else {
                remaining.append(wait)
            }
        }
        registrationWaits = remaining
        for wait in ended { wait.continuation.resume() }
    }
    // Ends the current observation for one that registers on another actor, waits as
    // `awaitEarlierRegistrations` does, and returns its attempt, whose hand-off is the observation's
    // registration, so ending the observation releases whatever the owner returns. Returns `nil` when a
    // newer observation replaced this one first, so this one asks the owner nothing.
    private func beginHandoff(source: ObjectIdentifier) async -> PresentationAttempt<Snapshot>? {
        let observing = endObservation()
        guard generation == observing, await awaitEarlierRegistrations(observing, source: source, cancellable: true)
        else { return nil }
        let attempt = beginAttempt(observing, source: source)
        let handoff = attempt.handoff
        self.source = source
        held = .release({ done in handoff.release(then: done) }, gate: nil)
        return attempt
    }
    // The one way a registration becomes the presentation's, whatever form obtained it: `attempt`, which
    // counted it in `registering` while it was being made, leaves `registering`, and the registration
    // becomes the current observation's when `keeping` and that attempt's observation is still current.
    // Otherwise it is released under the attempt's record, which keeps counting it until the release has
    // returned, so a registration that waits for it goes on, and a report of an end is made, only once
    // the slot is free. The seed the attempt held is released last, once the slot is free, so its
    // destructor can register again. Returns whether the registration is the current observation's.
    private func adopt(
        _ registration: HeldRegistration,
        of attempt: PresentationAttempt<Snapshot>,
        keeping: Bool = true
    ) -> Bool {
        registering.remove(attempt)
        attempt.answer()
        guard keeping, generation == attempt.generation else {
            let seed = attempt.end()
            attempt.handoff.release()
            guard let handle = registration.release else {
                attemptsSettled()
                withExtendedLifetime(seed) {}
                return false
            }
            attempt.keep(seed)
            release([handle], record: attempt)
            return false
        }
        held = registration
        source = attempt.source
        attemptsSettled()
        return true
    }
    // Releases a claimed sequence that no observation holds.
    private func release(unheld consumer: SnapshotSequence<Snapshot>.Consumer?) where Snapshot: Sendable {
        guard let consumer else { return }
        release([{ done in consumer.cancelOnMainActor(then: done) }], record: releaseRecord(nil))
    }
    // Runs the releases of a registration this presentation let go, and keeps `record`, an attempt that
    // held the registration's slot, in `registering` until each release has returned, so a registration
    // that waits for it goes on only once the slot is free, and a report that an observation ended
    // waits for it too. A release returns at once unless its host is
    // cancelling the registration's token at that moment, as a host of your own that ends the
    // observation from inside its `onCancel` does; it then returns once that cancellation has.
    private func release(_ releases: [PresentationRelease], record: PresentationAttempt<Snapshot>) {
        guard !releases.isEmpty else { return }
        let pending = record.isReleasing
        record.beginRelease(releases.count)
        if !pending {
            registering.insert(record)
            releasing += 1
        }
        for release in releases { release { [weak self] in self?.returned(record) } }
    }
    // Records that one release of `record` has returned. Once the last has, the slot is free: the
    // record leaves `registering`, the reports it held back are made, what waited for it goes on, and
    // the seed it kept is released last. A registration that waited for it resumes on a later
    // main-actor turn, after these reports.
    private func returned(_ record: PresentationAttempt<Snapshot>) {
        guard record.releaseReturned() else { return }
        let seed = record.keep(nil)
        registering.remove(record)
        releasing -= 1
        flushReports()
        attemptsSettled()
        withExtendedLifetime(seed) {}
    }
    // Withdraws an attempt that the owner refused or whose closure threw, which frees nothing but may let
    // a waiting registration go on.
    private func withdraw(_ attempt: PresentationAttempt<Snapshot>) {
        registering.remove(attempt)
        attempt.answer()
        attempt.end()
        attempt.handoff.release()
        attemptsSettled()
    }
    // Lets the registrations that wait for earlier ones go on once those have settled, and completes the
    // disposal of a released presentation once no registration it made or let go is still being made
    // or removed. It runs whenever an attempt or a release may have left `registering`.
    private func attemptsSettled() {
        resumeRegistrationWaits()
        if case .waiting = disposal, registering.isEmpty { completeDisposal() }
    }

    // MARK: Registering synchronously

    // Starts an observation whose owner registers it before returning, and may deliver its first
    // snapshot, and finish, before that. The attempt holds the seed and finish that arrive before the
    // owner returns the registration, so an observation started from inside the owner's registration
    // call cannot inherit them. A refusal of the current observation is thrown at once.
    private func bind(
        source: ObjectIdentifier,
        _ register: PresentationRegister<Snapshot>
    ) throws(SubscriptionFailure) {
        let observing = endObservation()
        guard generation == observing else { return }
        seeding = observing
        let attempt = beginAttempt(observing, source: source)
        switch register(observing, attempt) {
        case .success(let registration):
            install(registration, of: attempt)
        case .failure(let error):
            withdraw(attempt)
            // A refusal of an observation that a callback of the registration replaced is not reported.
            guard generation == observing else { return }
            throw error
        }
    }

    // MARK: Registering across suspensions

    // Settles an attempt whose owner answered on another actor, on the main actor, and returns the
    // refusal of an observation that is still current. A call whose first snapshot a publication in
    // progress shows returns once that publication has shown it, or dropped it.
    private func conclude(
        _ attempt: PresentationAttempt<Snapshot>,
        _ outcome: Result<Registered<Snapshot>, SubscriptionFailure>
    ) async -> SubscriptionFailure? where Snapshot: Sendable {
        let observing = attempt.generation
        let registered: Registered<Snapshot>
        switch outcome {
        case .failure(let error):
            withdraw(attempt)
            return generation == observing ? error : nil
        case .success(let answer): registered = answer
        }
        // A registration the presentation let go before the owner returned it, which comes without a
        // snapshot, is released.
        let adopted = adopt(
            Self.registration(registered.consumer),
            of: attempt,
            keeping: registered.current != nil
        )
        attempt.end()
        guard adopted, let consumer = registered.consumer, let current = registered.current else { return nil }
        let next = present(consumer, current: current, observing: observing)
        await scheduleShowingFirst(consumer, observing: observing, next)
        return nil
    }

    // MARK: Installing

    // Installs a registration for the current observation: its handle first, so a callback of the
    // first publication that stops observing cancels it, then the snapshot, then the report, which
    // follows only once that snapshot is published and if the registration is still installed then.
    private func install(_ registration: PresentationRegistration, of attempt: PresentationAttempt<Snapshot>) {
        let observing = attempt.generation
        switch registration {
        case .mainActor(let token):
            guard adopt(.token(token), of: attempt) else { return }
        case .isolated(let token):
            guard adopt(.isolated(token), of: attempt) else { return }
        case .sequence(let sequence):
            let adopted = adopt(sequence.registration, of: attempt)
            attempt.end()
            if adopted { sequence.present(observing) }
            return
        }
        let (seed, finished) = attempt.install()
        if let seed { receive(seed, observing: observing) }
        guard generation == observing, attempt.isInstalled else { return }
        if finished {
            finish(observing, attempt: attempt)
        } else {
            announce(attempt)
        }
    }
    // Reports a callback registration live once its first snapshot is shown and published, if the
    // registration is still installed then. An owner that delivers its first snapshot after the
    // registration returned announces it from that delivery.
    private func announce(_ attempt: PresentationAttempt<Snapshot>) {
        let observing = attempt.generation
        guard generation == observing, attempt.isInstalled, seeding != observing else { return }
        guard publication == nil else {
            afterPublishing(DeferredStep(generation: observing) { [weak self] in self?.announce(attempt) })
            return
        }
        setObserving(true)
    }
    // Runs `step` once the outermost snapshot publication in progress has assigned its snapshots and
    // released the ones it replaced, if its observation is still current then, and drops it otherwise.
    // Only a publication in progress defers a step; one that finds none decides at once.
    private func afterPublishing(_ step: DeferredStep) {
        guard publication != nil else {
            if step.generation == generation { step.run() } else { step.drop() }
            return
        }
        let displaced = publication?.step
        publication?.step = step
        displaced?.drop()
    }
    // Claims a sequence an owner returned and wraps it for installation, which takes the registration
    // first and only then reads the owner's snapshot with `current`. A sequence that another consumer
    // has claimed is not the presentation's to end.
    private func hold(
        _ snapshots: SnapshotSequence<Snapshot>,
        current: @escaping @MainActor () -> Snapshot
    ) -> PresentationRegistration where Snapshot: Sendable {
        let consumer = snapshots.claim()
        return .sequence(
            HeldSequence(
                registration: Self.registration(consumer),
                present: { [weak self] observing in
                    guard let self, let consumer else { return }
                    let shown = current()
                    guard self.generation == observing else { return }
                    self.schedule(
                        consumer,
                        observing: observing,
                        self.present(consumer, current: shown, observing: observing)
                    )
                }
            )
        )
    }

    // MARK: Following a sequence

    // Claims the sequence that a registration through a closure returned for the observation
    // `observing`, settles the closure's attempt, makes the sequence the observation's registration, and
    // shows what it holds. Returns `nil` when the presentation follows nothing: another consumer has
    // claimed the sequence, or a newer observation replaced this one while the closure ran, and the
    // sequence is then released before the attempts waiting for it go on. `following` reports that the
    // calling task follows the observation, so its cancellation ends it.
    //
    // `cancellation` is the record of the task that follows the observation, which becomes the
    // presentation's only once the observation is known to be current and to hold its sequence, and
    // before any client code runs, so an observation that lost its generation never overwrites the record
    // of the one that replaced it.
    private func begin(
        _ snapshots: SnapshotSequence<Snapshot>,
        observing: UInt64,
        attempt: PresentationAttempt<Snapshot>,
        following cancellation: WaitCancellation? = nil
    ) -> (SnapshotSequence<Snapshot>.Consumer, Continuation)? where Snapshot: Sendable {
        let following = cancellation != nil
        let consumer = snapshots.claim()
        // A task cancelled while its owner registered follows nothing: the registration is released,
        // and the observation ends unless another one replaced it.
        let cancelled = following && Task.isCancelled
        let adopted = adopt(Self.registration(consumer), of: attempt, keeping: !cancelled)
        attempt.end()
        if cancelled, generation == observing { _ = endObservation() }
        guard adopted, let consumer else { return nil }
        if let cancellation { follower = Follower(generation: observing, cancellation: cancellation) }
        return (consumer, present(consumer, current: nil, observing: observing, following: following))
    }
    /// How the observation of a sequence registration continues after a step on the main actor.
    private enum Continuation {
        /// Nothing follows because a newer observation replaced it or its registration ended.
        case done
        /// It continues on the task that follows it, which applies what the registration delivers.
        ///
        /// `live` reports whether it is live already. One that is not applies the elements waiting in
        /// the registration on later turns until it is. `applied` counts the elements applied in the
        /// current main-actor turn.
        case follow(live: Bool, applied: Int)
        /// Its liveness decision waits for the snapshot publication in progress, after `applied`
        /// elements were applied in this turn.
        case deferred(applied: Int)
        /// The task that follows it was cancelled before the decision.
        case cancelled
    }
    // Shows what an installed sequence registration holds and decides from the registration whether
    // the observation is live; the registration is already the observation's.
    //
    // The registration's unread element outranks `current`, the owner's snapshot read separately,
    // when it is at least as new, and counts against the elements of this turn. Then the elements that
    // arrived meanwhile are applied, and the registration's state decides, as `proceed` describes.
    // Each step runs only while the observation is current, re-read after every callout.
    private func present(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        current: Snapshot?,
        observing: UInt64,
        following: Bool = false
    ) -> Continuation where Snapshot: Sendable {
        seeding = current == nil ? observing : nil
        // Reading the end releases the registration, which can run a host's code, and releasing a
        // record the read retained can run a displaced element's destructor; either can end or replace
        // the observation, or cancel the task that follows it.
        let found = consumer.poll()
        guard admits(observing, following: following) else { return stopped(observing) }
        switch found {
        case .element(let unread):
            if let current {
                guard restart(newer: current, unread, observing: observing, following: following) else {
                    return stopped(observing)
                }
            } else {
                guard restart(unread, observing: observing, following: following) else { return stopped(observing) }
            }
            return proceed(consumer, observing: observing, applied: 1, following: following)
        case .empty, .ended:
            if let current {
                guard restart(current, observing: observing, following: following) else { return stopped(observing) }
            }
            return proceed(consumer, observing: observing, applied: 0, following: following)
        }
    }
    // Whether the observation `observing` may still show a value: it is current and, when `following`,
    // the task that follows it has not been cancelled. Every step reads it after each callout and before
    // it changes the presentation again.
    private func admits(_ observing: UInt64, following: Bool) -> Bool {
        generation == observing && !(following && Task.isCancelled)
    }
    // How an observation continues after a step that `admits` stopped: a replaced one has nothing to
    // follow, and a current one stopped by its task's cancellation ends.
    private func stopped(_ observing: UInt64) -> Continuation {
        generation == observing ? .cancelled : .done
    }
    // Applies what a sequence registration holds, within this turn's elements, and decides whether
    // the observation is live: once its first snapshot is shown, no snapshot publication is in
    // progress, and the registration, read then, is open, whether or not more elements wait in it. A
    // publication in progress defers the decision to its end. A registration that has finished with
    // its final element still unread is not live: a later turn applies that element and ends it.
    //
    // On the task that follows the observation, `following` is `true`: the task's cancellation, which a
    // callout of this step can issue, is read after each callout, and once more right before the
    // decision, with no callout in between, so a cancelled task never reports the observation live.
    private func proceed(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        applied: Int,
        following: Bool = false
    ) -> Continuation where Snapshot: Sendable {
        switch drain(consumer, observing: observing, applied: applied, following: following) {
        case .replaced, .ended:
            return .done
        case .cancelled:
            return .cancelled
        case .unshown(let applied):
            return .follow(live: false, applied: applied)
        case .shown(let applied):
            guard publication == nil else { return .deferred(applied: applied) }
            return decide(consumer, observing: observing, applied: applied) { following && Task.isCancelled }
        }
    }
    // Reports a shown observation live when its registration is open, which it reads without retaining
    // an element, so without a callout. The observation is validated right before the report: it is
    // still current, and `cancelled`, the cancellation of a task that follows it, is still unset.
    private func decide(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        applied: Int,
        cancelled: () -> Bool
    ) -> Continuation where Snapshot: Sendable {
        let open = consumer.isOpen
        guard generation == observing else { return .done }
        guard !cancelled() else { return .cancelled }
        guard open else { return .follow(live: false, applied: applied) }
        setObserving(true)
        // A callback of the report that ends or replaces the observation leaves nothing to follow.
        return generation == observing ? .follow(live: true, applied: applied) : .done
    }
    // Continues an observation that `observe(_:)` started on the main actor: on a task the
    // presentation owns and cancels when the observation ends, or once the snapshot publication in
    // progress has returned.
    private func schedule(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        _ next: Continuation
    ) where Snapshot: Sendable {
        switch next {
        case .done, .cancelled:
            return
        case .deferred(let applied):
            scheduleAfterPublication(consumer, observing: observing, applied: applied)
        case .follow:
            guard generation == observing else { return }
            observation = Task { [weak self] in
                await Self.follow({ self }, consumer, observing: observing, from: next)
            }
        }
    }
    // Continues an observation as `schedule` does, from an asynchronous call that returns only once the
    // observation's first snapshot is shown: when a snapshot publication in progress defers that, the
    // call waits until the publication has assigned it and decided, or until a newer observation or a
    // stop replaces this one. The step registers before the call suspends, so the publication cannot end
    // first.
    private func scheduleShowingFirst(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        _ next: Continuation
    ) async where Snapshot: Sendable {
        guard case .deferred(let applied) = next else {
            schedule(consumer, observing: observing, next)
            // A first snapshot that a publication in progress shows after its callbacks return is shown
            // then, whether or not the sequence can still deliver.
            await awaitOwnPublication(observing)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduleAfterPublication(consumer, observing: observing, applied: applied) { continuation.resume() }
        }
    }
    // Whether a value that the observation `observing` accepted waits for the snapshot publication in
    // progress to show it.
    private func ownPublicationPending(_ observing: UInt64) -> Bool {
        publication?.deferred?.generation == observing
    }
    // Waits until the snapshot publication in progress has returned, when it holds a value the
    // observation `observing` accepted, which it shows then unless the observation has ended.
    private func awaitOwnPublication(_ observing: UInt64) async {
        guard ownPublicationPending(observing) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            publication?.ends.append { continuation.resume() }
        }
    }
    // Defers the decision of an observation the presentation owns to the end of the snapshot
    // publication in progress, then continues it as `schedule` does, and runs `then` once the
    // publication has run or dropped the step.
    private func scheduleAfterPublication(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        applied: Int,
        then: @escaping @MainActor () -> Void = {}
    ) where Snapshot: Sendable {
        afterPublishing(
            DeferredStep(
                generation: observing,
                run: { [weak self] in
                    if let self {
                        self.schedule(
                            consumer,
                            observing: observing,
                            self.proceed(consumer, observing: observing, applied: applied)
                        )
                    }
                    then()
                },
                drop: then
            )
        )
    }
    /// What a sequence registration holds once the presentation has applied the elements waiting in
    /// it, within one turn's elements.
    private enum Drained {
        /// A newer observation replaced this one.
        case replaced
        /// The registration ended and was released, so the observation reports nothing.
        case ended
        /// The task that follows the observation was cancelled by a callout of the step.
        case cancelled
        /// The registration has delivered nothing yet.
        case unshown(applied: Int)
        /// The observation's first snapshot is shown.
        ///
        /// `applied` elements were applied in this turn, and more may wait once that reaches the
        /// turn's limit.
        case shown(applied: Int)
    }
    // Applies the elements a sequence registration holds until it holds none, it ends, or `applied`
    // reaches the elements of one turn, and, on the task that follows the observation, until a callout
    // cancels that task.
    private func drain(
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        applied: Int,
        following: Bool
    ) -> Drained where Snapshot: Sendable {
        var applied = applied
        while true {
            guard generation == observing else { return .replaced }
            if following, Task.isCancelled { return .cancelled }
            if applied >= Self.deliveriesPerTurn {
                return seeding == observing ? .unshown(applied: applied) : .shown(applied: applied)
            }
            switch consumer.poll() {
            case .element(let next):
                receive(next, observing: observing, following: following)
                applied += 1
            case .ended:
                guard generation == observing else { return .replaced }
                held = .none
                awaitRemoval(of: consumer)
                return .ended
            case .empty:
                return seeding == observing ? .unshown(applied: applied) : .shown(applied: applied)
            }
        }
    }
    /// The number of sequence elements an observation applies in one main-actor turn, counting the
    /// first, before it lets other work run, so a source that delivers again from every snapshot it
    /// delivers cannot hold the actor.
    private static var deliveriesPerTurn: Int { 32 }

    // Follows a sequence registration on the task that runs it until the registration ends, a newer
    // observation or a stop replaces the observation, or the task is cancelled, and returns only
    // then. `follow(_:)` runs it on the caller's task, and `observe(_:)` on a task the presentation
    // cancels when the observation ends.
    //
    // Every suspension is one of four: the read of the next element, which a cancellation of the task
    // or the release of the registration ends; the yield after a turn's elements, after which the task
    // reads its cancellation; the wait for a publication in progress, which the publication ends in
    // the same main-actor turn, or the end of the observation drops; and the hop that starts the task.
    // The task holds the presentation only between its suspensions, through `core`.
    private static func follow(
        _ core: () -> PresentationCore?,
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        from start: Continuation
    ) async where Snapshot: Sendable {
        var next = start
        while true {
            // Each step reads the presentation afresh and keeps no reference to it across a suspension.
            guard let standing = core()?.standing(of: observing) else {
                consumer.cancelOnMainActor()
                return
            }
            guard case .current(let unshown) = standing else { return }
            if Task.isCancelled { next = .cancelled }
            switch next {
            case .done:
                return
            case .cancelled:
                core()?.abandon(consumer, observing: observing)
                return
            case .deferred(let applied):
                next = await awaitPublication(core, consumer, observing: observing, applied: applied)
            case .follow(live: false, _) where unshown:
                // Nothing is shown yet: the first element is the observation's first snapshot. A read
                // that the sequence handed an element before the task was cancelled shows nothing.
                guard let first = await consumer.next(), !Task.isCancelled else {
                    core()?.readEnded(consumer, observing: observing)
                    return
                }
                next = core()?.present(first: first, consumer, observing: observing) ?? .done
            case .follow(live: false, _):
                // The elements still waiting are applied on a later turn, if the task is not cancelled
                // by then.
                await Task.yield()
                next =
                    Task.isCancelled
                    ? .cancelled
                    : core()?.proceed(consumer, observing: observing, applied: 0, following: true) ?? .done
            case .follow(live: true, let applied):
                if applied >= deliveriesPerTurn {
                    await Task.yield()
                    next = .follow(live: true, applied: 0)
                    continue
                }
                guard let element = await consumer.next(), !Task.isCancelled else {
                    core()?.readEnded(consumer, observing: observing)
                    return
                }
                // A replaced observation's element in flight is discarded by the generation check, and one
                // whose revision closure cancels the task is not shown.
                core()?.receive(element, observing: observing, following: true)
                next = .follow(live: true, applied: applied + 1)
            }
        }
    }
    /// Where an observation stands for the task that follows it.
    private enum Standing {
        /// A newer observation or a stop replaced it.
        case replaced
        /// The observation is current, with `unshown` reporting whether it has shown nothing yet.
        case current(unshown: Bool)
    }
    private func standing(of observing: UInt64) -> Standing {
        generation == observing ? .current(unshown: seeding == observing) : .replaced
    }
    // Shows a following task's first element and decides how the observation continues.
    private func present(
        first: Snapshot,
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64
    ) -> Continuation where Snapshot: Sendable {
        receive(first, observing: observing, following: true)
        return proceed(consumer, observing: observing, applied: 1, following: true)
    }
    // Waits on the following task for the end of the snapshot publication in progress, which makes the
    // deferred liveness decision in the same main-actor turn, or drops it when the observation ends.
    // A cancellation of the task during the wait is recorded where it happens, so the decision, which
    // runs on whichever task publishes, sees it and decides nothing. The decision reads that record and
    // then the registration's state, with no callout in between, and runs no other client code: the
    // following task applies whatever else waits once it resumes, with this turn's count of elements.
    private static func awaitPublication(
        _ core: () -> PresentationCore?,
        _ consumer: SnapshotSequence<Snapshot>.Consumer,
        observing: UInt64,
        applied: Int
    ) async -> Continuation where Snapshot: Sendable {
        let cancellation = WaitCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Continuation, Never>) in
                guard let presentation = core(), presentation.generation == observing else {
                    continuation.resume(returning: .done)
                    return
                }
                presentation.afterPublishing(
                    DeferredStep(
                        generation: observing,
                        run: { [weak presentation] in
                            guard let presentation, !cancellation.isCancelled else {
                                continuation.resume(returning: .cancelled)
                                return
                            }
                            continuation.resume(
                                returning: presentation.decide(consumer, observing: observing, applied: applied) {
                                    cancellation.isCancelled
                                }
                            )
                        },
                        drop: { continuation.resume(returning: .done) }
                    )
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    // Ends the observation `observing` whose following task was cancelled, and releases its
    // registration; a newer observation, which already released it, is left alone.
    private func abandon(_ consumer: SnapshotSequence<Snapshot>.Consumer, observing: UInt64) where Snapshot: Sendable {
        if generation == observing {
            _ = endObservation()
        } else {
            release(unheld: consumer)
        }
    }
    // Ends the observation `observing` whose registration a read found ended: by its owner, when it
    // reports the end, or by the cancellation of the task that read it, which ends the observation,
    // also when the read returned an element the sequence had handed it first.
    private func readEnded(_ consumer: SnapshotSequence<Snapshot>.Consumer, observing: UInt64)
    where Snapshot: Sendable {
        guard !Task.isCancelled else {
            abandon(consumer, observing: observing)
            return
        }
        guard generation == observing else { return }
        held = .none
        awaitRemoval(of: consumer)
        setObserving(false)
    }
    // Keeps the removal of a registration that ended itself, as reading its end does, in progress
    // until it has returned, so the report of the end waits for the slot to be free.
    private func awaitRemoval(of consumer: SnapshotSequence<Snapshot>.Consumer) where Snapshot: Sendable {
        release([{ done in consumer.afterRemoval(done) }], record: releaseRecord(source))
    }

    // MARK: Delivery and publication

    // Applies a delivery only while its observation is current, checked again after the revision
    // projection, which can start a newer observation. The first delivery of an observation that seeds
    // itself restarts the revision check. A delivery that arrives while its owner is still registering
    // waits in that attempt until the presentation owns the registration, and a delivery to an attempt
    // that ended is discarded.
    //
    // On the task that follows the observation, `following` is `true`, and a value is shown only while
    // that task is not cancelled, read again after the revision projection, which can cancel it.
    private func receive(
        _ next: Snapshot,
        observing: UInt64,
        attempt: PresentationAttempt<Snapshot>? = nil,
        following: Bool = false
    ) {
        guard admits(observing, following: following) else { return }
        if let attempt, !attempt.admit(next) { return }
        if seeding == observing {
            guard restart(next, observing: observing, following: following) else { return }
            if let attempt { announce(attempt) }
            return
        }
        let nextRevision = revision(next)
        guard admits(observing, following: following) else { return }
        settleDeferred()
        guard nextRevision > watermark else { return }
        accept(next, revision: nextRevision)
    }
    // Shows a new source's first snapshot and restarts the revision check from it, reporting whether
    // the observation is still current afterward. A value that this observation accepted since it
    // claimed its generation, through `apply` or a delivery, including one accepted while `revision`
    // ran, stays when it is at least as new: the restart then shows nothing.
    private func restart(_ value: Snapshot, observing: UInt64, following: Bool = false) -> Bool {
        let restarted = revision(value)
        guard admits(observing, following: following) else { return false }
        return complete(restart: value, revision: restarted, observing: observing)
    }
    // Restarts from the newer of two snapshots of the same owner; the second wins a tie.
    private func restart(newer first: Snapshot, _ second: Snapshot, observing: UInt64, following: Bool = false) -> Bool
    {
        let firstRevision = revision(first)
        guard admits(observing, following: following) else { return false }
        let secondRevision = revision(second)
        guard admits(observing, following: following) else { return false }
        return secondRevision >= firstRevision
            ? complete(restart: second, revision: secondRevision, observing: observing)
            : complete(restart: first, revision: firstRevision, observing: observing)
    }
    private func complete(restart value: Snapshot, revision restarted: UInt64, observing: UInt64) -> Bool {
        if seeding == observing { seeding = nil }
        settleDeferred()
        guard accepted == acceptedAtClaim || watermark < restarted else { return true }
        accept(value, revision: restarted)
        return generation == observing
    }
    private func accept(_ value: Snapshot, revision accepted: UInt64) {
        watermark = accepted
        self.accepted &+= 1
        publish(value, revision: accepted)
    }
    // Assigns in arrival order. An observer that applies a newer snapshot while one is being
    // assigned defers it, so the outer assignment cannot overwrite the newer value.
    //
    // A deferred value is validated right before it is assigned, with no client code in between: it is
    // shown only if the observation that accepted it is still current and the task that follows that
    // observation, if one does, has not been cancelled, since the callbacks that ran meanwhile can have
    // ended either. Every comparison with the watermark validates it the same way first, and so does
    // the end of an observation, so a value that will not be shown never holds back a newer one: a value
    // skipped before any later one was accepted gives the watermark back to the revision of the snapshot
    // shown or being assigned, so the next value is compared with that.
    //
    // A replaced snapshot, and a skipped one, is released after the assignments, so a destructor that
    // reads the presentation finds the newest one in place.
    private func publish(_ next: Snapshot, revision: UInt64) {
        guard let surface else { return }
        guard publication == nil else {
            // A value accepted while the task that follows the observation runs belongs to that task's
            // observation, and its cancellation withdraws it; one accepted after that cancellation, as
            // an `apply` from the callback that cancelled the task makes, is shown.
            let following = follower.flatMap { $0.generation == generation ? $0.cancellation : nil }
            let displaced = publication?.deferred
            publication?.deferred = Deferred(
                value: next,
                revision: revision,
                generation: generation,
                cancellation: following?.isCancelled == false ? following : nil,
                accepted: accepted
            )
            withExtendedLifetime(displaced) {}
            return
        }
        publication = Publication()
        var displaced: [Snapshot] = []
        show(next, revision: revision, on: surface, displacing: &displaced)
        while true {
            settleDeferred()
            guard let newer = publication?.deferred.take() else { break }
            show(newer.value, revision: newer.revision, on: surface, displacing: &displaced)
        }
        var finished = publication.take()
        displaced += finished?.abandoned ?? []
        finished?.abandoned = []
        displaced.removeAll()
        for end in finished?.ends ?? [] { end() }
        // The step reads the observation again, since the destructors of the replaced snapshots ran.
        guard let waiting = finished?.step else { return }
        if waiting.generation == generation { waiting.run() } else { waiting.drop() }
    }
    private func show(_ next: Snapshot, revision: UInt64, on surface: Surface, displacing displaced: inout [Snapshot]) {
        shownRevision = revision
        surface.present(next) {
            if let replaced = shown { displaced.append(replaced) }
            shown = next
        }
    }
    // Drops the deferred value when the publication in progress will not show it, because its
    // observation ended or the task that follows it was cancelled, and, when nothing was accepted after
    // it, gives the watermark back to the snapshot shown or being assigned. The value is kept for the
    // publication to release with the snapshots it displaces, so no client code runs here.
    private func settleDeferred() {
        guard let pending = publication?.deferred,
            pending.generation != generation || pending.cancellation?.isCancelled == true
        else { return }
        publication?.deferred = nil
        if accepted == pending.accepted { watermark = shownRevision }
        publication?.abandoned.append(pending.value)
    }
    // Ends the current observation and claims a new generation before anything is published, so a
    // callback that starts another observation during the publication claims a later one. A deferred
    // refusal belongs to the observation that ends, so its wait ends too.
    //
    // The old handles are detached before any of them is cancelled. Cancelling one can run a
    // callback that starts a newer observation, which installs handles this call must not touch.
    //
    // The old registration is released before `isObserving` reports the change, so a callback of that
    // report that observes the same owner again finds its slot free.
    //
    // `handed`, the registration of a sequence that `observe(_:)` or `follow(_:)` received, becomes the
    // new observation's through `adopt`, as every registration does, before the old one is released. A
    // callback of that release or of the report that ends the new observation too lets the sequence go
    // as it lets any registration go, and so does `abandoned` when it holds once the old registration
    // is released: a report of that end waits until the sequence's slot is free, and an asynchronous
    // registration waits until the sequence has been released.
    private func endObservation(
        handing handed: HeldRegistration? = nil,
        unless abandoned: () -> Bool = { false }
    ) -> UInt64 {
        generation &+= 1
        settleDeferred()
        acceptedAtClaim = accepted
        let claimed = generation
        let releases = detachRegistration()
        let ended = source
        if let handed {
            let attempt = beginAttempt(claimed, source: nil)
            _ = adopt(handed, of: attempt)
            attempt.end()
        }
        let observation = observation
        let waiting = publication?.step
        source = nil
        self.observation = nil
        publication?.step = nil
        release(releases, record: releaseRecord(ended))
        if handed != nil, generation == claimed, abandoned() {
            release(detachRegistration(), record: releaseRecord(nil))
        }
        observation?.cancel()
        waiting?.drop()
        withExtendedLifetime(waiting) {}
        resumeRegistrationWaits()
        if generation == claimed { setObserving(false) }
        return claimed
    }
    // Ends an observation whose source finished or was released, unless a newer one replaced it. A
    // finish that arrives while its attempt is still registering waits in that attempt, and the finish
    // of an attempt that ended is discarded.
    //
    // The ended registration's handles are detached and cancelled before the report, as ending an
    // observation releases them, because a host of your own may free its slot only when its token is
    // cancelled: a callback of the report that observes the same owner again finds the slot free. The
    // cancellation can run a host's code, which can start another observation, so the report follows
    // only if this observation is still current afterward.
    private func finish(_ observing: UInt64, attempt: PresentationAttempt<Snapshot>? = nil) {
        guard generation == observing else { return }
        if let attempt, !attempt.admitFinish() { return }
        release(detachRegistration(), record: releaseRecord(source))
        guard generation == observing else { return }
        setObserving(false)
    }
    // Detaches the registration the current observation holds and returns its release.
    private func detachRegistration() -> [PresentationRelease] {
        exchange(&held, with: .none).release.map { [$0] } ?? []
    }
    // Records a change of whether an observation is live and assigns `isObserving` for every change
    // not yet assigned, oldest first. A callback of an assignment that changes it again queues that
    // change behind the one in progress, so each change is assigned once and in order.
    private func setObserving(_ value: Bool) {
        guard live != value else { return }
        live = value
        reports.append(value)
        flushReports()
    }
    // Assigns the reports not yet assigned, oldest first. A report that an observation ended waits
    // while a release of this presentation has not returned, and the reports after it wait behind it,
    // so `isObserving` becomes `false` only once every registration that ended has freed its slot.
    private func flushReports() {
        guard !reporting else { return }
        guard let surface else {
            reports = PendingReports()
            return
        }
        reporting = true
        while let next = reports.first, next || releasing == 0 {
            reports.removeFirst()
            surface.report(observing: next)
        }
        reporting = false
    }
}

/// The changes of whether an observation is live that a presentation has not reported yet, oldest first.
///
/// A callback of a report can queue many more before it returns. Each report is taken from the queue
/// once, by its position, and the storage of the reports taken is reclaimed only once they outnumber
/// those still waiting, so reporting a queue of any length takes time linear in that length.
package struct PendingReports {
    private var values: [Bool] = []
    // The position of the oldest report not yet taken.
    private var start = 0
    /// The saturating number of reports that reclaiming storage has moved so far, which tests read as
    /// the work that reclaiming takes.
    package private(set) var moved = 0 { didSet { if moved < oldValue { moved = .max } } }

    package init() {}

    /// The number of reports not yet taken.
    package var count: Int { values.count - start }
    /// The oldest report not yet taken, or `nil` when none waits.
    package var first: Bool? { start < values.count ? values[start] : nil }
    /// Queues a report behind the others.
    package mutating func append(_ report: Bool) { values.append(report) }
    /// Takes the oldest report, which must exist.
    package mutating func removeFirst() {
        precondition(start < values.count, "No report is waiting.")
        start += 1
        guard start * 2 >= values.count else { return }
        moved &+= values.count - start
        values.removeFirst(start)
        start = 0
    }
}

/// A step deferred to the end of the outermost snapshot publication in progress, for one observation.
///
/// The publication runs it when its observation is still current then, and otherwise, like the end of
/// that observation or a later step that displaces it, drops it. Exactly one of the two happens once.
@MainActor private final class DeferredStep {
    let generation: UInt64
    private var actions: (run: @MainActor () -> Void, drop: @MainActor () -> Void)?

    init(generation: UInt64, run: @escaping @MainActor () -> Void, drop: @escaping @MainActor () -> Void = {}) {
        self.generation = generation
        actions = (run, drop)
    }

    func run() {
        let taken = actions
        actions = nil
        taken?.run()
    }
    func drop() {
        let taken = actions
        actions = nil
        taken?.drop()
    }
}

/// Whether the task of an observation waiting on a refusal or a publication was cancelled, recorded by
/// its cancellation handler on whichever thread cancels it.
nonisolated private final class WaitCancellation: Sendable {
    private let cancelled = AtomicRecordStorage(false)
    var isCancelled: Bool { cancelled.load().value }
    func cancel() {
        while true {
            let before = cancelled.load()
            guard !before.value else { return }
            if cancelled.install(.init(true), replacing: before) { return }
        }
    }
}

/// Runs its action when the registration callbacks that hold it are released.
nonisolated private final class ObservationRelease: Sendable {
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    deinit { action() }
}

/// Carries the release of a registration that an owner confined to another actor returns there,
/// between that actor and the main actor.
///
/// The presentation can let the registration go before the owner has returned it, and the owning actor
/// can hold it after the presentation let it go, with whichever comes second seeing the other. A hold
/// that comes second keeps nothing and reports it, and the owning actor hands the registration to the
/// main actor to remove. The stage sits behind a lock, and the call that releases a held registration
/// takes the release out of it, so no other call ever holds it.
nonisolated private final class RegistrationHandoff: Sendable {
    /// Removes the registration on the main actor and runs its argument once the removal has completed.
    typealias Release = @MainActor @Sendable (_ done: @escaping @MainActor @Sendable () -> Void) -> Void
    private enum Stage: Sendable {
        case awaiting
        case holding(Release)
        case released
    }
    private let stage = OSAllocatedUnfairLock(initialState: Stage.awaiting)

    /// Keeps `release` for the presentation and returns `true`, or returns `false`, keeping nothing,
    /// when the presentation has already let the registration go.
    func hold(_ release: @escaping Release) -> Bool {
        stage.withLock { stage -> Bool in
            guard case .awaiting = stage else { return false }
            stage = .holding(release)
            return true
        }
    }
    /// Lets the registration go: releases one already held, once, and runs `done` once its removal
    /// has completed, or makes a later `hold` keep nothing and runs `done` at once.
    @MainActor func release(then done: @escaping @MainActor @Sendable () -> Void = {}) {
        var held = stage.withLock { stage -> Release? in
            guard case .holding(let release) = exchange(&stage, with: .released) else { return nil }
            return release
        }
        guard let release = held.take() else {
            done()
            return
        }
        release(done)
    }
}

/// What the owning actor hands to the main actor for one registration: whether the presentation
/// claimed the sequence, and the consumer, with the snapshot read after it when the presentation still
/// holds it.
nonisolated private struct Registered<Element: Sendable>: Sendable {
    let claimed: Bool
    let consumer: SnapshotSequence<Element>.Consumer?
    let current: Element?
}

/// Ends one registration that a presentation let go and runs its argument once that has returned:
/// at once, or, when the registration's host is cancelling its token at that moment, once that
/// cancellation has returned.
private typealias PresentationRelease = @MainActor (_ done: @escaping @MainActor @Sendable () -> Void) -> Void

/// A sequence registration an owner returned, ready to install.
@MainActor private struct HeldSequence {
    /// The claimed sequence, or none when another consumer had claimed it.
    let registration: HeldRegistration
    /// Reads the owner's snapshot for the observation that holds the registration, and shows it.
    let present: @MainActor (UInt64) -> Void
}

/// The registration an owner returned to a presentation.
@MainActor private enum PresentationRegistration {
    case mainActor(MainActorSnapshotSubscription)
    case isolated(IsolatedSnapshotSubscription<MainActor>)
    case sequence(HeldSequence)
}

/// Registers one attempt of an observation synchronously, given the observation's generation.
private typealias PresentationRegister<Snapshot> =
    @MainActor (UInt64, PresentationAttempt<Snapshot>) -> Result<
        PresentationRegistration, SubscriptionFailure
    >

/// The seed and finish that a main-actor owner delivers to one registration before it returns that
/// registration, held until the presentation owns it.
///
/// Every presentation registers through one: the passive presentations' attempts are its subclass, and
/// a driving presentation stages each registration it makes in one, so a registration the owner
/// refuses, or that the presentation lets go before the owner returns it, never shows what the owner
/// delivered meanwhile.
@MainActor class RegistrationStaging<Snapshot> {
    private enum Stage {
        case registering(seed: Snapshot?, finished: Bool)
        case installed
        case ended
    }
    private var stage: Stage

    /// A registration that is being made, or, when `ended`, one that already ended.
    init(ended: Bool = false) { stage = ended ? .ended : .registering(seed: nil, finished: false) }

    /// Whether the presentation owns the registration and its owner has not finished it.
    final var isInstalled: Bool {
        if case .installed = stage { return true }
        return false
    }

    /// Reports whether a delivery applies now, holding one that arrives while registering instead.
    final func admit(_ next: Snapshot) -> Bool {
        switch stage {
        case .registering(let displaced, let finished):
            stage = .registering(seed: next, finished: finished)
            withExtendedLifetime(displaced) {}
            return false
        case .installed: return true
        case .ended: return false
        }
    }
    /// Reports whether a finish applies now and ends the registration, holding one that arrives while
    /// registering instead.
    final func admitFinish() -> Bool {
        switch stage {
        case .registering(let seed, _):
            stage = .registering(seed: seed, finished: true)
            return false
        case .installed:
            stage = .ended
            return true
        case .ended: return false
        }
    }
    /// Marks the registration as the presentation's and returns what arrived while it registered.
    final func install() -> (seed: Snapshot?, finished: Bool) {
        guard case .registering(let seed, let finished) = stage else { return (nil, false) }
        stage = .installed
        return (seed, finished)
    }
    /// Ends a registration that was refused, replaced, or ended so its later callbacks change nothing.
    ///
    /// Returns the seed it held, for the caller to release once the registration it ends is released.
    @discardableResult final func end() -> Snapshot? {
        let released = stage
        stage = .ended
        guard case .registering(let seed, _) = released else { return nil }
        return seed
    }
}

/// The attempts of one presentation that may hold a slot it cannot count as free, indexed by owner and
/// serial, so a registration that waits asks about the attempts related to it, and an attempt joins
/// and leaves them, without examining the others.
///
/// A registration that waits with an owner waits for that owner's earlier attempts and for every
/// earlier one through a closure, which may hold any owner's slot. One through a closure waits for
/// every earlier attempt. Each set of serials is kept in ascending order, so each question reads its
/// smallest serial.
@MainActor private struct RegisteringAttempts<Snapshot> {
    private var members: [ObjectIdentifier: PresentationAttempt<Snapshot>] = [:]
    private var all = SerialOrder()
    private var throughClosures = SerialOrder()
    private var byOwner: [ObjectIdentifier: SerialOrder] = [:]
    /// The attempts and serial positions examined, and the serials moved, so far.
    ///
    /// It saturates instead of overflowing.
    private(set) var examined = 0 { didSet { if examined < oldValue { examined = .max } } }

    var isEmpty: Bool { members.isEmpty }
    /// How many serials, and records of removed ones, the orders keep.
    var retained: Int { ([all, throughClosures] + byOwner.values).reduce(0) { $0 + $1.retained } }
    /// The attempts, in no particular order.
    var attempts: [PresentationAttempt<Snapshot>] { Array(members.values) }

    /// Adds an attempt that is not yet a member.
    mutating func insert(_ attempt: PresentationAttempt<Snapshot>) {
        guard members.updateValue(attempt, forKey: ObjectIdentifier(attempt)) == nil else { return }
        examined &+= all.insert(attempt.serial)
        if let owner = attempt.source {
            examined &+= byOwner[owner, default: SerialOrder()].insert(attempt.serial)
        } else {
            examined &+= throughClosures.insert(attempt.serial)
        }
    }
    /// Removes an attempt, if it is a member.
    mutating func remove(_ attempt: PresentationAttempt<Snapshot>) {
        guard members.removeValue(forKey: ObjectIdentifier(attempt)) != nil else { return }
        examined &+= all.remove(attempt.serial)
        if let owner = attempt.source {
            examined &+= byOwner[owner]?.remove(attempt.serial) ?? 0
            if byOwner[owner]?.isEmpty == true { byOwner[owner] = nil }
        } else {
            examined &+= throughClosures.remove(attempt.serial)
        }
    }
    mutating func removeAll() { self = RegisteringAttempts() }
    /// Whether a member that began before `boundary` holds a slot that a registration with `source`, or
    /// through a closure when `source` is `nil`, must wait for.
    mutating func holdsSlot(below boundary: UInt64, relatedTo source: ObjectIdentifier?) -> Bool {
        examined &+= 1
        guard let source else { return all.first.map { $0 < boundary } ?? false }
        let owner = byOwner[source]?.first ?? .max
        let closure = throughClosures.first ?? .max
        return min(owner, closure) < boundary
    }
}

/// Distinct serials in ascending order.
///
/// Serials are made in ascending order, so an insertion normally appends. Removing the first serial
/// advances a head past it and past every later serial already removed. Removing any other serial
/// records it to be skipped when the head reaches it. The slots before the head are reclaimed once they
/// make up half of the storage, and the removed serials after it once they outnumber the serials still
/// present, so a first serial that stays while many later ones come and go keeps storage proportional
/// to the serials present. Returning attempts oldest first, newest first, or in any order costs
/// amortized constant work each, besides a binary search. Each operation reports the positions it
/// examined and the elements it moved.
private struct SerialOrder {
    private var serials: [UInt64] = []
    private var head = 0
    // Serials at or after the head that were removed and are still stored.
    private var removed: Set<UInt64> = []

    var first: UInt64? { head < serials.count ? serials[head] : nil }
    var isEmpty: Bool { head == serials.count }
    /// How many serials, and records of removed ones, the order keeps.
    var retained: Int { serials.count + removed.count }

    /// Inserts `serial` in order and returns how many positions it examined and elements it moved.
    mutating func insert(_ serial: UInt64) -> Int {
        if removed.remove(serial) != nil { return 1 }
        guard let last = serials.last, head < serials.count, serial <= last else {
            serials.append(serial)
            return 1
        }
        let (index, examined) = position(of: serial)
        if serials[index] == serial { return examined }
        serials.insert(serial, at: index)
        return examined + serials.count - index - 1
    }
    /// Removes `serial` if present and returns how many positions it examined and elements it moved.
    mutating func remove(_ serial: UInt64) -> Int {
        guard head < serials.count else { return 1 }
        guard serials[head] == serial else {
            let (index, examined) = position(of: serial)
            guard index < serials.count, serials[index] == serial, removed.insert(serial).inserted else {
                return examined
            }
            return examined + compact()
        }
        head += 1
        var examined = 1
        while head < serials.count, removed.remove(serials[head]) != nil {
            head += 1
            examined += 1
        }
        return examined + reclaim()
    }
    // Drops the removed serials once they outnumber the serials still present, and returns how many
    // elements that moved.
    private mutating func compact() -> Int {
        let stored = serials.count - head
        guard removed.count >= 16, removed.count * 2 >= stored else { return 0 }
        serials = serials[head...].filter { !removed.contains($0) }
        head = 0
        removed = []
        return stored
    }
    // Reclaims the slots before the head once they make up half of the storage, and returns how many
    // elements that moved.
    private mutating func reclaim() -> Int {
        if head == serials.count {
            serials.removeAll(keepingCapacity: true)
            head = 0
            return 0
        }
        guard head >= 16, head * 2 >= serials.count else { return 0 }
        let moved = serials.count - head
        serials.removeFirst(head)
        head = 0
        return moved
    }
    // The first index at or after the head whose serial is not below `serial`, and the number of
    // positions examined.
    private func position(of serial: UInt64) -> (Int, Int) {
        var low = head
        var high = serials.count
        var examined = 0
        while low < high {
            let middle = (low + high) / 2
            examined += 1
            if serials[middle] < serial { low = middle + 1 } else { high = middle }
        }
        return (low, examined)
    }
}

/// One registration attempt of one observation, which stages the seed and finish that a main-actor
/// owner delivers to it before it returns the registration.
@MainActor private final class PresentationAttempt<Snapshot>: RegistrationStaging<Snapshot> {
    /// The observation the attempt registers.
    let generation: UInt64
    /// The owner the attempt registers with, whose capacity it can consume, or `nil` for an attempt that
    /// registers through a closure, which can consume any owner's capacity.
    let source: ObjectIdentifier?
    /// The order in which the presentation began the attempt or the release.
    let serial: UInt64
    /// The release of a registration that the owner returns on another actor.
    nonisolated let handoff = RegistrationHandoff()
    /// Whether the owner has answered the attempt.
    private var answered = false

    // The releases of the registration the attempt obtained that have not returned yet, and the seed
    // it keeps until they have.
    private var unreturned = 0
    private var kept: Snapshot?

    init(generation: UInt64, source: ObjectIdentifier?, serial: UInt64) {
        self.generation = generation
        self.source = source
        self.serial = serial
        super.init()
    }
    /// A record of the release of a registration with `source`, or with any owner when `source` is
    /// `nil`, which holds the registration's slot until the release has returned.
    init(releasing source: ObjectIdentifier?, serial: UInt64) {
        generation = 0
        self.source = source
        self.serial = serial
        answered = true
        super.init(ended: true)
    }

    /// Whether the attempt may still hold a slot that the presentation cannot count as free: it is
    /// inside its owner's registration call, or the release of the registration it obtained has not
    /// returned.
    var isRegistering: Bool { !answered || unreturned > 0 }
    /// Whether a release of the attempt's registration has not returned yet.
    var isReleasing: Bool { unreturned > 0 }
    /// Records that `count` releases of the attempt's registration have begun.
    func beginRelease(_ count: Int) { unreturned += count }
    /// Records that one release has returned, and reports whether it was the last.
    func releaseReturned() -> Bool {
        unreturned -= 1
        return unreturned == 0
    }
    /// Keeps `seed` until the releases have returned, and returns the seed kept before.
    @discardableResult func keep(_ seed: Snapshot?) -> Snapshot? { exchange(&kept, with: seed) }
    /// Records that the owner has answered, with a registration or a refusal.
    func answer() { answered = true }
}

/// A capacity-one bridge from `Sendable` background snapshots to `MainActor` presentation.
///
/// Offers replace pending UI data, never effect commands. Exactly one responsible
/// delivery task exists per active cohort, regardless of the number of offered updates.
nonisolated public final class MainActorSnapshotIngress<Snapshot: Sendable>: Sendable {
    private struct Envelope: Sendable {
        let value: Snapshot
        let revision: UInt64
    }
    private struct State: Sendable {
        var pending: Envelope?
        var watermark: UInt64?
        var scheduled = false
        var closed = false
    }
    // Protected by one lock. Each change takes any replaced envelope out of the state and releases it
    // after unlocking, so a call checking whether the bridge is closed never holds a snapshot.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let receive: @MainActor @Sendable (Snapshot) -> Void
    /// Selects the isolated presentation callback without retaining a live machine.
    public init(_ receive: @escaping @MainActor @Sendable (Snapshot) -> Void) { self.receive = receive }
    /// Stages only a newer revision and schedules at most one responsible delivery task.
    public func offer(_ snapshot: Snapshot, revision: UInt64) {
        var changed = state.withLock { state -> (wake: Bool, replaced: Envelope?)? in
            guard !state.closed, state.watermark.map({ revision > $0 }) ?? true else { return nil }
            let replaced = exchange(&state.pending, with: Envelope(value: snapshot, revision: revision))
            state.watermark = revision
            let wake = !state.scheduled
            state.scheduled = true
            return (wake, replaced)
        }
        guard let wake = changed?.wake else { return }
        changed = nil
        if wake { Task { @MainActor in self.deliver() } }
    }
    /// Stops future application, permitting an already-claimed callback to finish.
    public func cancel() {
        let discarded = state.withLock { state -> Envelope? in
            state.closed = true
            return state.pending.take()
        }
        withExtendedLifetime(discarded) {}
    }
    @MainActor private func deliver() {
        var count = 0
        while true {
            let claimed = state.withLock { state -> Envelope? in
                guard !state.closed, let envelope = state.pending.take() else {
                    state.scheduled = false
                    return nil
                }
                return envelope
            }
            guard let envelope = claimed else { return }
            receive(envelope.value)
            count += 1
            if count == 32 {
                Task { @MainActor in
                    await Task.yield()
                    self.deliver()
                }
                return
            }
        }
    }
}

/// The gate of a presentation's current registration, which its destructor closes from any thread.
///
/// It is the registration's own flag, which holds no snapshot, token, or closure, so closing it, on
/// whichever thread releases the presentation, runs no client code and releases nothing the main
/// actor must release.
nonisolated final class PresentationGate: Sendable {
    private let gate = OSAllocatedUnfairLock<RuntimeRegistrationGate?>(initialState: nil)

    var current: RuntimeRegistrationGate? {
        get { gate.withLock { $0 } }
        set { gate.withLock { $0 = newValue } }
    }
    /// Closes the gate recorded now, leaving the registration for the main actor to remove.
    func close() { current?.close() }
}

/// The registration held by a presentation's current observation, either a callback registration's
/// token or the release of a sequence registration or cross-actor hand-off that runs its argument
/// once removal returns, along with the gate of any claimed sequence.
@MainActor private enum HeldRegistration {
    case none
    case token(MainActorSnapshotSubscription)
    case isolated(IsolatedSnapshotSubscription<MainActor>)
    case release(PresentationRelease, gate: RuntimeRegistrationGate?)

    var gate: RuntimeRegistrationGate? {
        switch self {
        case .none: nil
        case .token(let token): token.gate
        case .isolated(let token): token.gate
        case .release(_, let gate): gate
        }
    }
    var release: PresentationRelease? {
        switch self {
        case .none: nil
        case .token(let token): { done in token.cancel(then: done) }
        case .isolated(let token): { done in token.end(on: MainActor.shared, then: done) }
        case .release(let release, _): release
        }
    }
}
