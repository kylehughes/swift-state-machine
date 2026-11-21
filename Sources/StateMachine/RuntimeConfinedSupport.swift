/// A raw managed delivery disposition, without granting a domain facade's authority.
///
/// Support for the code that `@StateMachine` generates; it carries no source-stability promise.
@frozen nonisolated public enum RuntimeHostDelivery<Model, Descriptor> {
    case committed(RuntimeState<Model, Descriptor>.Snapshot)
    case pending(RuntimePendingID, PendingStatus)
    case inProgress
    case notPending
    case stale
    case foreignOwner
    case discarded(RuntimeState<Model, Descriptor>.Snapshot)
    case rejected(RuntimeState<Model, Descriptor>.Rejection)
}

extension RuntimeHostDelivery: Sendable where Model: Sendable, Descriptor: Sendable {}

/// Failure to register another live observer with a managed owner.
nonisolated public enum SubscriptionFailure: Error { case capacityExceeded }

/// Whether one actor-owned registration may still begin callbacks.
///
/// Its token closes it synchronously from any thread, while the actor removes the registration
/// on a later turn. The actor checks it before each callback and ignores a closed registration
/// when it counts or admits registrations.
nonisolated package final class RuntimeRegistrationGate: Sendable {
    private let open = AtomicRecordStorage(true)
    package init() {}
    package var isOpen: Bool { open.load().value }
    package func close() {
        while true {
            let before = open.load()
            guard before.value else { return }
            if open.install(.init(false), replacing: before) { return }
        }
    }
}

nonisolated struct RuntimeConfinedExecution: Sendable {
    let ticket: RuntimeTicket
    let identity: RuntimeIdentity
    let worker: Task<Void, Never>
    var watcher: Task<Void, Never>?
}

/// Ownership of one observer registration with an owner confined to the actor `Owner`.
///
/// It is not `Sendable`, so it stays in the region of the owning actor, where its callbacks run.
/// ``cancel(isolation:)`` takes that actor as an `isolated` parameter, so it runs only there: a call
/// from any other actor, or from a nonisolated context such as the destructor of an ordinary class,
/// does not compile, and a call that receives a different instance of `Owner` stops the program.
/// Cancelling removes the registration before returning, and none of its callbacks begins afterward; a
/// callback that is already running may finish. The callbacks are released before `cancel` returns
/// unless the host is delivering a change at that moment, such as when another observer's callback
/// cancels: the host then keeps the callbacks it selected for that change until it has delivered the
/// change to its other observers, and releases them then.
///
/// An object on the owning actor that stores the token can still be released on another thread, and
/// the token with it, so releasing the token never touches the owner. Dropping it stops delivery and
/// frees the registration's slot at once. The host releases the callbacks when it next sweeps its
/// registrations, on a later turn of the owning actor, or when it is destroyed, wherever that happens;
/// cancel the token on the owning actor to release them synchronously. It does not keep the owner
/// alive.
nonisolated public final class IsolatedSnapshotSubscription<Owner: Actor> {
    private weak var owner: Owner?
    // Both closures are taken together, so whichever ends the registration releases both, and with
    // them everything they capture, as soon as it has run.
    private var action: (() -> Void)?
    private var release: (@Sendable () -> Void)?
    // The continuations of calls made while the action or the release runs, `nil` unless one of them
    // is running now.
    private var waiting: [() -> Void]?
    /// The gate of the registration a managed owner made, which a holder closes from any thread
    /// without touching the token, or `nil` for a host of your own.
    package let gate: RuntimeRegistrationGate?

    package init(
        owner: Owner,
        gate: RuntimeRegistrationGate? = nil,
        cancel: @escaping () -> Void,
        release: @escaping @Sendable () -> Void
    ) {
        self.owner = owner
        self.gate = gate
        action = cancel
        self.release = release
    }
    /// Creates a registration token for a host of your own, such as a test double, owned by `isolation`.
    ///
    /// `onCancel` runs once, on the owning actor, when the token is cancelled. `onRelease` runs
    /// instead when the token is released without being cancelled, on whichever thread releases it,
    /// and `onCancel`, with everything it captures, is then released on that thread too. A value
    /// that must be released on the owning actor is therefore captured by `onCancel` weakly, or the
    /// token is cancelled on that actor. A call that cancels the token from inside `onCancel` returns
    /// at once and changes nothing.
    public convenience init(
        isolation: isolated Owner = #isolation,
        onCancel: @escaping () -> Void,
        onRelease: @escaping @Sendable () -> Void = {}
    ) {
        self.init(owner: isolation, cancel: onCancel, release: onRelease)
    }
    /// Removes the registration before returning; none of its callbacks begins afterward.
    ///
    /// The callbacks are released before this returns, except during a delivery of the host's, which
    /// releases the callbacks it selected once it has delivered that change to its other observers.
    ///
    /// `isolation` is the owning actor, which a call on that actor passes by default. A call that
    /// passes another instance of `Owner` stops the program.
    public func cancel(isolation: isolated Owner = #isolation) {
        precondition(
            owner === isolation,
            "An IsolatedSnapshotSubscription was cancelled on an actor other than its owner."
        )
        end(running: true, then: nil)
    }
    /// Ends the registration from code that the compiler confines to the owning actor without naming
    /// its type, such as a confined stream's `next()`, and runs `completion` once the registration's
    /// end has returned.
    ///
    /// It removes the registration as ``cancel(isolation:)`` does when `isolation` is the owning actor,
    /// and otherwise only stops delivery and frees the slot, as releasing the token does. A call made
    /// while the token's cancellation or release is running, as from inside a host's `onCancel`, never
    /// waits: `completion` runs once that cancellation returns.
    package func end(on isolation: (any Actor)?, then completion: (() -> Void)? = nil) {
        let onOwner = isolation != nil && owner != nil && isolation === owner
        end(running: onOwner, then: completion)
    }
    // Runs the action on the owning actor when `running`, and otherwise the release, after taking both
    // closures and recording that the end is running; releases both before running the continuations
    // of this call and of the calls made while the end ran. A call that finds the end running or done
    // runs nothing.
    private func end(running: Bool, then completion: (() -> Void)?) {
        var taken = (action, release)
        guard taken.0 != nil else {
            if waiting != nil {
                if let completion { waiting?.append(completion) }
            } else {
                completion?()
            }
            return
        }
        action = nil
        release = nil
        waiting = []
        if running { taken.0?() } else { taken.1?() }
        taken = (nil, nil)
        let continuations = waiting ?? []
        waiting = nil
        completion?()
        for next in continuations { next() }
    }
    // A token released without being cancelled runs `onRelease` where it is released. The action it did
    // not run, and everything that action captures, is released there too: no `Sendable` path leads
    // from a destructor to a generic actor, so a value that must be released on the owning actor is
    // released by cancelling the token there, not by dropping it.
    deinit {
        if action != nil { release?() }
    }
}

/// Explicit MainActor ownership of one observer registration.
///
/// Cancelling it removes the registration at once. Releasing it without cancelling stops delivery and
/// frees the registration's slot at once, from any thread, and removes the registration on a later
/// main-actor turn.
@MainActor public final class MainActorSnapshotSubscription {
    // Taken by the cancellation that runs it, so the token keeps nothing it captured once it has run.
    private var action: (@MainActor @Sendable () -> Void)?
    // The continuations of calls made while the action runs, `nil` unless it is running now.
    private var waiting: [@MainActor () -> Void]?
    /// The gate of the registration a managed owner made, which a holder closes from any thread
    /// without touching the token, or `nil` for a host of your own.
    nonisolated package let gate: RuntimeRegistrationGate?

    package init(_ action: @escaping @MainActor @Sendable () -> Void, gate: RuntimeRegistrationGate? = nil) {
        self.action = action
        self.gate = gate
    }
    /// Creates a registration token for a host of your own, such as a test double.
    ///
    /// `onCancel` runs exactly once, on the main actor, when the token is cancelled or released. The
    /// token releases `onCancel`, and everything it captures, once it has run, on the main actor.
    public convenience init(onCancel: @escaping @MainActor @Sendable () -> Void) { self.init(onCancel) }
    /// Stops delivery and frees the registration's slot from any thread, when the owner admits
    /// through the registration's gate; the main actor removes the registration when it cancels the
    /// token.
    nonisolated package func close() { gate?.close() }
    /// Removes the registration synchronously; an already-claimed callback may finish.
    ///
    /// A call made while the token's cancellation is running, as from inside a host's `onCancel`,
    /// returns at once and changes nothing.
    public func cancel() { cancel(then: nil) }
    /// Cancels the token and runs `completion` once its cancellation has returned.
    ///
    /// `completion` runs right after the action when this call runs it, after the action that an outer
    /// call is running returns, or at once when the cancellation has already returned. A call from
    /// inside the action never waits.
    package func cancel(then completion: (@MainActor () -> Void)?) {
        var taken = action
        guard taken != nil else {
            if waiting != nil {
                if let completion { waiting?.append(completion) }
            } else {
                completion?()
            }
            return
        }
        action = nil
        waiting = []
        gate?.close()
        taken?()
        taken = nil
        let continuations = waiting ?? []
        waiting = nil
        completion?()
        for next in continuations { next() }
    }
    // A token released without being cancelled, possibly on another thread, closes its gate at once
    // and hands its action to a later main-actor turn, which runs it and then releases it, with
    // everything it captures, there. The job owns the action alone before it can run: the token's
    // own storage, which the releasing thread destroys after this returns, no longer holds it.
    deinit {
        guard action != nil else { return }
        gate?.close()
        let job = MainActorJob(taking: &action)
        Task { @MainActor in job.run() }
        DestructorPause.reached()
    }
}

/// One main-actor action that a destructor leaves to a later main-actor turn, which runs it and then
/// releases it, with everything it captures, on the main actor.
@MainActor package final class MainActorJob {
    private var action: (@MainActor @Sendable () -> Void)?

    /// Takes the action out of `slot`, which holds no reference to it afterward, so the job holds the
    /// action's only reference from before it can run.
    nonisolated package init(taking slot: inout (@MainActor @Sendable () -> Void)?) {
        action = slot.take()
    }

    /// Runs the action once and releases it before returning.
    package func run() {
        var taken = action
        action = nil
        taken?()
        taken = nil
    }
}

/// A pause that a test inserts into a destructor that hands main-actor values to a later main-actor
/// job, on the destroying thread, after that job can run and before the destructor returns and the
/// destroyed object's stored properties are released.
///
/// Tests bind it for the task that drops an object, so the job can complete first, which is the
/// schedule that shows whether the job owns those values alone. It is `nil` everywhere else.
nonisolated package enum DestructorPause {
    @TaskLocal package static var afterScheduling: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { afterScheduling?() }
}

/// A pause that a test inserts into the main-actor hand-off of a publisher of a `Sendable` owner, after the
/// hand-off has taken the value and finish the owner handed over and before the publisher absorbs them,
/// so the owner can be released between the two.
///
/// The hand-off runs on a task that the owner's delivery
/// path starts, which inherits the task-local values of the task that registered the publisher, so a
/// test binds it around that registration. It is `nil` everywhere else.
nonisolated package enum HandOffPause {
    @TaskLocal package static var afterTaking: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { afterTaking?() }
}

/// A pause that a test inserts into a main-actor end of a snapshot sequence, after the end has released
/// the registration and before it asks to be told of the removal, so a removal that another thread
/// completes can complete first.
///
/// It is `nil` everywhere else.
nonisolated package enum RemovalObservationPause {
    @TaskLocal package static var beforeObserving: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { beforeObserving?() }
}

/// A pause that a test inserts into a publisher's delivery of a value on the main actor, once the
/// delivery is decided.
///
/// It runs after the delivery's last check of the owner's release and before the subscriber receives
/// the value, so the owner can be released on another thread between the two.
///
/// It runs on the main actor in the job that delivers, which inherits the task-local values as
/// ``HandOffPause`` describes, or in the call that attaches a subscriber or requests demand. It is `nil`
/// everywhere else.
nonisolated package enum DecidedDeliveryPause {
    @TaskLocal package static var beforeReceive: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { beforeReceive?() }
}

/// A pause that a test inserts into a main-actor end of a snapshot sequence that waits for the
/// registration's removal, once that removal has completed and the end has released the discarded
/// element, and before the end's completion runs.
///
/// The end reads it once, when it begins on the main actor, and the removal runs that value on
/// whichever main-actor turn completes it. It is `nil` everywhere else.
nonisolated package enum RemovalCompletionPause {
    @TaskLocal package static var afterCustody: (@Sendable () -> Void)?
}

/// A pause that a test inserts into the destructor of a `Sendable` owner released without closing,
/// after it has notified one registration of the release and before it notifies the next, on the
/// releasing thread.
///
/// Tests bind it for the task that drops the owner's last reference, so the main actor can finish one
/// publisher of the owner and attach to another while the rest are still unnotified. It is `nil`
/// everywhere else.
nonisolated package enum ReleaseNoticePause {
    @TaskLocal package static var afterNotice: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { afterNotice?() }
}

/// A pause that a test inserts before the reconciliation reports of a batch of capacity conflicts,
/// after the owner has captured the batch and before it calls any handler, with the batch's pending
/// identities in report order.
///
/// It runs where the owner found the conflicts: on the task of an explicit reconciliation, a delivery,
/// or a termination, or, for a `Shared` owner, on its batch drainer, which inherits the task-local
/// values of the task that scheduled it. It is `nil` everywhere else.
nonisolated package enum CapacityConflictPause {
    @TaskLocal package static var beforeReports: (@Sendable ([RuntimePendingID]) -> Void)?

    /// Runs the pause bound for the current task, if any, with the identities of `batch`.
    package static func reached<Entry>(_ batch: [Entry], _ id: (Entry) -> RuntimePendingID) {
        guard let pause = beforeReports, !batch.isEmpty else { return }
        pause(batch.map(id))
    }
}

/// A pause that a test inserts into a `Shared` owner's subscriber count, after the count has loaded
/// one version of the owner's state and before it reads that version's registrations, so other
/// registrations can be made and ended in between.
///
/// It runs on the reading task. It is `nil` everywhere else.
nonisolated package enum CountReadPause {
    @TaskLocal package static var afterLoading: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { afterLoading?() }
}

/// A pause that a test inserts into a read of a `Sendable` snapshot sequence that waits, after the read
/// has installed its continuation and before it suspends, so another thread can hand it an element
/// first.
///
/// It runs on the reading task. It is `nil` everywhere else.
nonisolated package enum SnapshotWaitPause {
    @TaskLocal package static var beforeSuspending: (@Sendable () -> Void)?

    /// Runs the pause bound for the current task, if any.
    package static func reached() { beforeSuspending?() }
}
