import Foundation

// The explorer's event alphabet and the readable script form of a sequence.
//
// Hosts are numbered: 0 is host A, 1 is host B. A script is the events' descriptions joined by
// "; ", for example `observe(A); hostCancel(A); observe(B); hostCancel(B); observe(A)`.

/// A callback in which an armed event runs once, the next time the callback runs.
enum ExplorerHook: String, CaseIterable, Hashable, Sendable {
    /// The `isObserving` report: the `$isObserving` sink, or the Observation change handler.
    case report
    /// The snapshot change callback: `objectWillChange`, or the Observation change handler of `snapshot`.
    case change
    /// A fake host's token `onCancel`, when it runs on the main thread.
    case onCancel
    /// The presentation's revision closure.
    case revision
    /// An asynchronous registration closure, when the presentation invokes it.
    case factory
    /// A Combine subscriber's `receive(subscription:)`.
    case subscription
    /// A Combine subscriber's `receive(_:)`.
    case value
    /// The transform of `presentedSnapshots(projecting:)`, including the seed projection.
    case projection
    /// A raw owner's reconciliation handler, when it runs for a completion other than the armed event's.
    case reconciliation
    /// A raw owner's emission handler for emission 8, on the drainer's thread.
    case emission
    /// A distinct projection's `==`, wherever the owner evaluates it.
    case equality
    /// `sites` family: a host's `snapshot()` on the main thread, before it returns.
    case hostRead
    /// A driving host's `send`, after it delivered the change, before it returns the receipt.
    case hostSend
    /// A host's registration call on the main thread, after its provisional delivery, before it returns
    /// or throws.
    case hostSubscribe
    /// A driving host's `close`, after it finished its subscriber, before it returns.
    case hostClose
    /// A Combine subscriber's `receive(subscription:)`, before it requests anything.
    case subscriptionBefore
    /// A Combine subscriber's `receive(completion:)`.
    case completion
    /// The destructor of a client value (snapshot, unread or displaced element), on the main thread.
    case destroy
    /// A presentation publisher's delivery of a buffered value, between its demand claim and its lifetime
    /// read (H10, `PresentationDeliveryPause`).
    case decision
}

indirect enum ExplorerEvent: Hashable, Sendable, CustomStringConvertible {
    /// Synchronous `observe(host)` of a one-slot shared host.
    case observe(Int)
    /// Synchronous `observe(snapshotsFrom:)` with a closure that registers with the host.
    case observeFrom(Int)
    /// Asynchronous `observe(snapshotsFrom:)`; its closure parks once invoked, until `factoryReturn`.
    case observeAsync(Int)
    /// `follow(snapshotsFrom:)` on a task of its own; its closure parks once invoked.
    case followAsync(Int)
    /// Asynchronous `observe(snapshotsFrom:)` whose closure registers with the host as soon as it is
    /// invoked and parks before returning the sequence.
    case observeAsyncHeld(Int)
    /// Asynchronous `observe(snapshotsFrom:)` whose closure registers and returns at once.
    case observeAsyncNow(Int)
    /// As `observeAsyncNow`, but the host finishes the registration, seed still unread, before the
    /// closure returns it, so the seed is the final, unread element.
    case observeAsyncFinished(Int)
    /// Driving: a `MainActorSnapshotSubscription` of the harness's own, whose action captures a value,
    /// released on a worker in the job-first schedule.
    case tokenDropAfterJob
    /// Registers a sequence with the host, then `observe(_:)` of that sequence.
    case observeSeq(Int)
    /// Registers a sequence with the host, then `follow(_:)` of it on a task of its own.
    case followSeq(Int)
    /// As `followSeq`, with a registration that delivers no seed, so the follower waits for its first element.
    case followUnseeded(Int)
    /// The oldest parked registration closure registers with its host and returns.
    case factoryReturn
    /// The oldest parked registration closure throws a refusal.
    case factoryThrow
    /// Cancels the newest follower task that is not cancelled.
    case cancelFollower
    case stop
    /// `stopObserving()` with the removal-observation pause (H1) bound: the parked cancellations of
    /// host A return just before the end registers its removal observer.
    case stopRacingRemoval
    /// The client registers a sequence with the host and claims it as its own consumer, then
    /// `observe(_:)` of it: the presentation must leave it alone.
    case observeClaimed(Int)
    /// `follow(_:)` of a newly registered sequence on a task that is already cancelled.
    case followCancelled(Int)
    /// From now on, each snapshot the presentation shows makes the host deliver another value to the
    /// registration holding its slot, up to 100 (a source that delivers from each snapshot shown).
    case echo(Int)
    /// The host offers a new value from a worker thread while the main actor waits.
    case deliverElsewhere(Int)
    /// From now on, each cancellation of the host's token delivers a new value to its registration from
    /// inside that cancellation, before the slot is free, wherever the cancellation runs.
    case deliverInCancel(Int)
    /// The queue of the subscribers attached through `receive(on:)` runs what it holds while the main actor
    /// waits: their values arrive, the demand each returns is requested there, and a subscriber that takes
    /// one value cancels there.
    case requestElsewhere
    /// Unused: a subscriber that takes one value cancels from the queue in `requestElsewhere`.
    case cancelElsewhere
    /// Attaches a subscriber through `receive(on:)` of the harness's queue; with `once`, through
    /// `prefix(1)` as well, so it cancels its subscription from the queue after its first value.
    case subscribeElsewhere(once: Bool)
    /// `apply(_:)` of a newer snapshot on a passive presentation; `send(_:)` on a driving one.
    case apply
    /// `close()` on a driving presentation.
    case close
    /// The host offers a new value to the registration holding its slot, from the main thread.
    case deliver(Int)
    /// The host finishes the registration holding its slot.
    case finish(Int)
    /// The host begins cancelling that registration's token on a worker, which parks inside `onCancel`.
    case hostCancel(Int)
    /// The parked cancellation on that host frees the slot and returns.
    case hostCancelReturn(Int)
    /// The host cancels that registration's token on the main thread, so `onCancel` runs there.
    case hostCancelMain(Int)
    /// `apply(_:)` of a snapshot newer than the one shown and older than every value applied or
    /// delivered so far.
    case applyBelow
    /// Two events in order, as one callback runs them.
    case then(ExplorerEvent, ExplorerEvent)
    /// Asynchronous `observe(host, isolation:)` of an isolated host sharing host A's slot, called on its
    /// actor; the host's registration call registers and parks until `isolatedReturn`.
    case observeIsolated
    /// The parked isolated registration call returns its sequence.
    case isolatedReturn
    /// Asynchronous `observe(host)` of an actor host sharing host A's slot; its registration call
    /// registers (or throws a refusal at once) and suspends until `actorReturn`.
    case observeActor
    /// The oldest suspended actor-host registration call returns its sequence, then one turn.
    case actorReturn
    /// Teardown: saves owner publisher `k` (`snapshotPublisher { $0.revision }`).
    case save(Int)
    /// Teardown: attaches a subscriber with unlimited demand to saved publisher `k`.
    case attach(Int)
    /// Teardown: registers a callback whose capture attaches to publisher `k` from its destructor.
    case capture(Int)
    /// Teardown: starts the fetch driver, whose cancellation handler attaches to publisher `k`.
    case driver(Int)
    /// Teardown, `ActorHost` and `Shared`: sends `.load` with the driver-start pause (H2) bound, and
    /// returns once the launched driver task is parked before its driver runs.
    case driverParked(Int)
    /// Teardown: the parked driver task goes on and its driver starts.
    case driverGo
    /// Teardown: releases the harness's only reference to the owner, here or on a worker.
    case releaseOwner(elsewhere: Bool)
    /// Teardown: a registration whose capture drops the owner is cancelled on a worker, which parks
    /// after the drop while it still holds the owner's state.
    case workerDrop
    /// Teardown: the parked worker returns.
    case workerReturn
    /// Teardown, `Shared`: saves publisher `k` with the hand-off pause (H3) bound. Inside its first
    /// hand-off, after the value is taken and before the delivery is decided, a subscriber attaches and
    /// the owner is released on a worker until its teardown has begun.
    case releaseInHandOff(Int)
    /// Teardown, `Shared`: attaches a subscriber to saved publisher `k` that releases the owner on a
    /// worker, until its teardown has begun, from inside its first value, after the delivery was decided.
    case releaseInDelivery(Int)
    /// The harness releases its only reference to the presentation on the main actor.
    case dropMain
    /// The harness hands its only reference to a worker that releases it while the main actor waits.
    case dropElsewhere
    /// As `dropElsewhere`, in the schedule where the destructor's main-actor job finishes first.
    case dropAfterJob
    /// One main-actor turn: the main-actor jobs enqueued so far run.
    case turn
    /// Keeps the publisher value `presentedSnapshots` returns now, for a later `subscribe(saved:)`.
    case savePublisher
    /// Attaches a Combine subscriber to `presentedSnapshots` (or the saved publisher); it requests
    /// one value, or unlimited demand, from `receive(subscription:)`.
    case subscribe(saved: Bool, unlimited: Bool)
    /// Attaches a subscriber with unlimited demand to `presentedSnapshots(projecting:)`.
    case subscribeProjected
    /// The newest subscriber requests one more value.
    case request
    /// The newest subscriber that is not cancelled cancels its subscription.
    case cancelSubscription
    /// Arms `event` to run once inside the next run of `hook`.
    case arm(ExplorerHook, ExplorerEvent)

    // E11, teardown of `Shared` and `ActorHost`.
    /// Releases the owner on a worker held by the release-notice pause (H4) right after the owner
    /// notified the first saved publisher, once that publisher's subscribers have finished.
    case releaseNotice
    /// The held release goes on, notifies the rest, and returns.
    case noticeGo

    // E8, the raw owner's `counts` family.
    /// Registers a callback with the raw owner.
    case register
    /// Registers a pending-completion observer, which shares the callbacks' capacity.
    case registerPending
    /// Cancels the oldest live registration.
    case cancelOldest
    /// Cancels the newest live registration.
    case cancelNewest
    /// Reads `subscriberCount`.
    case count
    /// Reads `subscriberCount` with the count-read pause (H5) bound: `event`, a chain of registrations and
    /// cancellations, runs inside the read after it loaded a version of the state.
    case countDuring(ExplorerEvent)

    // E4 and E13, the raw owner's `reconcile` family; works are numbered 1 and 2.
    /// Delivers work `k`'s outcome, which its completion's preparation refuses.
    case refuse(Int)
    /// Delivers work `k`'s outcome, whose candidate starts two more works.
    case accept(Int)
    /// Admits an emission whose handler holds the batch drainer until `releaseDrainer`.
    case holdDrainer
    /// The held drainer goes on; the harness awaits `flush(through:)` of the current root.
    case releaseDrainer
    /// Admits an unrelated edit that advances the root.
    case edit
    /// Reconciles work `k`'s retained completion.
    case reconcile(Int)
    /// The held drivers return; the step ends once none runs and the drainer has caught up.
    case releaseDrivers
    /// Admits an emission whose handler runs the action armed at the `emission` site.
    case emit
    /// Teardown: attaches to saved publisher `k` with the decided-delivery pause (H7) bound, which releases
    /// the owner on a worker after the delivery's last source check and before `receive`.
    case releaseDecided(Int)
    /// Passive: `stopObserving()` with the removal-completion pause (H8) bound, which checks custody between
    /// the discarded element's release and the removal's completion.
    case stopCustody
    /// Discards work `k`'s retained completion.
    case discard(Int)
    /// Work `k`'s driver returns its outcome, which its preparation may accept or refuses; the owner's
    /// coordinator delivers it from the worker.
    case returnWork(Int, accepts: Bool)
    /// Runs `event` once, inside the next report of work `k`'s retained completion.
    case onReport(Int, ExplorerEvent)
    /// Puts the works in a starting arrangement; first event only.
    case stage(String)
    /// Starts `flush(through:)` of the receipt the held drainer's batch returned, which must not return until
    /// that batch is processed.
    case flushHeld

    // E9, `demand` family of the `ObservableObject` classes.
    /// Attaches a subscriber to `presentedSnapshots` that requests no value from `receive(subscription:)`.
    case subscribeZero
    /// Attaches a subscriber that requests one value and returns one more from each `receive(_:)`.
    case subscribeReturning
    /// The oldest open limited subscriber requests one more value.
    case requestOldest
    /// The oldest open subscriber cancels.
    case cancelFirstSubscriber
    /// Keeps the publisher `presentedSnapshots(projecting:)` returns now.
    case saveProjected
    /// Attaches an unlimited subscriber to the saved projected publisher.
    case subscribeSavedProjected

    // E5 and E6, passive `selection` family.
    /// The newest parked registration closure registers with its host and returns, out of order.
    case factoryReturnNewest
    /// The newest parked registration closure throws a refusal, out of order.
    case factoryThrowNewest
    /// Cancels the oldest follower task that is not cancelled.
    case cancelFollowerOldest
    /// Cancels the task of the newest direct asynchronous observation that is not cancelled.
    case cancelCall

    // E7, the free-standing `SnapshotSequence` slice.
    /// Registers a sequence whose host delivers no seed.
    case observeUnseeded
    /// Claims an iterator of the kept sequence; a second claim must end at once.
    case claim
    /// Starts a read of the claimed iterator on the main actor, which returns at once or waits.
    case read
    /// Cancels the task of the waiting read.
    case cancelReader

    // E3, the real-owner driving slice.
    /// `send(.cancel)` through the presentation.
    case sendCancel
    /// The owner admits a change without the presentation.
    case ownerSend
    /// Commits a proposal made from the snapshot shown.
    case commitCurrent
    /// Keeps a proposal made from the snapshot shown.
    case saveProposal
    /// Commits the kept proposal.
    case commitSaved
    /// Commits a proposal made from another owner's snapshot.
    case commitForeign
    /// The owner resets to its initial phase without the presentation (E14).
    case resetOwner

    // The raw owner's `copies` family.
    /// Keeps a copy of the raw owner.
    case copyOwner
    /// Releases the kept copy on a worker.
    case dropCopy

    // E8, the multi-owner slice.
    /// Presentation `p` observes owner `k`.
    case present(Int, Int)
    /// Presentation `p` stops observing.
    case stopP(Int)
    /// The harness releases presentation `p` on the main actor.
    case dropP(Int)
    /// A pending-completion registration on owner `k`.
    case pending(Int)
    /// A read of distinct sequence `k` on the main actor, which returns at once or waits.
    case readSeq(Int)

    // E1, passive `clocks` family.
    /// The host offers a value with the revision of its latest one and different data.
    case deliverEqual(Int)

    // E2 and `resumeObserving()`, driving `resume` family.
    /// The presentation is created while the host's `subscribe` delivers a newer snapshot and then
    /// refuses; first event only.
    case createRefusing
    /// The presentation is created while another registration holds the host's only slot; first event
    /// only.
    case createOccupied
    /// The presentation is created after the host closed; first event only.
    case createClosed
    /// `resumeObserving()`.
    case resume
    /// The host's next `subscribe` delivers a newer snapshot and then refuses.
    case refuseNext
    /// A registration of the harness's own takes the host's slot.
    case occupy
    /// The harness's own registration ends, freeing the slot.
    case vacate

    var description: String {
        switch self {
        case .observe(let host): "observe(\(Self.name(host)))"
        case .observeFrom(let host): "observeFrom(\(Self.name(host)))"
        case .observeAsync(let host): "observeAsync(\(Self.name(host)))"
        case .followAsync(let host): "followAsync(\(Self.name(host)))"
        case .observeAsyncHeld(let host): "observeAsyncHeld(\(Self.name(host)))"
        case .observeAsyncNow(let host): "observeAsyncNow(\(Self.name(host)))"
        case .observeAsyncFinished(let host): "observeAsyncFinished(\(Self.name(host)))"
        case .tokenDropAfterJob: "tokenDropAfterJob"
        case .observeSeq(let host): "observeSeq(\(Self.name(host)))"
        case .followSeq(let host): "followSeq(\(Self.name(host)))"
        case .followUnseeded(let host): "followUnseeded(\(Self.name(host)))"
        case .hostCancelMain(let host): "hostCancelMain(\(Self.name(host)))"
        case .applyBelow: "applyBelow"
        case .then(let first, let second): "\(first)+\(second)"
        case .observeIsolated: "observeIsolated"
        case .isolatedReturn: "isolatedReturn"
        case .observeActor: "observeActor"
        case .actorReturn: "actorReturn"
        case .save(let index): "save(\(index))"
        case .attach(let index): "attach(\(index))"
        case .capture(let index): "capture(\(index))"
        case .driver(let index): "driver(\(index))"
        case .releaseOwner(let elsewhere): elsewhere ? "releaseOwnerElsewhere" : "releaseOwner"
        case .workerDrop: "workerDrop"
        case .driverParked(let index): "driverParked(\(index))"
        case .driverGo: "driverGo"
        case .workerReturn: "workerReturn"
        case .releaseInHandOff(let index): "releaseInHandOff(\(index))"
        case .releaseInDelivery(let index): "releaseInDelivery(\(index))"
        case .factoryReturn: "factoryReturn"
        case .factoryThrow: "factoryThrow"
        case .cancelFollower: "cancelFollower"
        case .stop: "stop"
        case .stopRacingRemoval: "stopRacingRemoval"
        case .observeClaimed(let host): "observeClaimed(\(Self.name(host)))"
        case .followCancelled(let host): "followCancelled(\(Self.name(host)))"
        case .echo(let host): "echo(\(Self.name(host)))"
        case .deliverElsewhere(let host): "deliverElsewhere(\(Self.name(host)))"
        case .deliverInCancel(let host): "deliverInCancel(\(Self.name(host)))"
        case .requestElsewhere: "requestElsewhere"
        case .cancelElsewhere: "cancelElsewhere"
        case .subscribeElsewhere(let once): once ? "subscribe(elsewhere,once)" : "subscribe(elsewhere,1+)"
        case .apply: "apply"
        case .close: "close"
        case .deliver(let host): "deliver(\(Self.name(host)))"
        case .finish(let host): "finish(\(Self.name(host)))"
        case .hostCancel(let host): "hostCancel(\(Self.name(host)))"
        case .hostCancelReturn(let host): "hostCancelReturn(\(Self.name(host)))"
        case .dropMain: "dropMain"
        case .dropElsewhere: "dropElsewhere"
        case .dropAfterJob: "dropAfterJob"
        case .turn: "turn"
        case .savePublisher: "savePublisher"
        case .subscribe(let saved, let unlimited): "subscribe(\(saved ? "saved" : "fresh"),\(unlimited ? "max" : "1"))"
        case .subscribeProjected: "subscribeProjected"
        case .request: "request"
        case .cancelSubscription: "cancelSubscription"
        case .arm(let hook, let event): "arm(\(hook.rawValue),\(event))"
        case .releaseNotice: "releaseNotice"
        case .noticeGo: "noticeGo"
        case .register: "register"
        case .registerPending: "registerPending"
        case .cancelOldest: "cancelOldest"
        case .cancelNewest: "cancelNewest"
        case .count: "count"
        case .countDuring(let event): "countDuring(\(event))"
        case .refuse(let work): "refuse(\(work))"
        case .accept(let work): "accept(\(work))"
        case .holdDrainer: "holdDrainer"
        case .releaseDrainer: "releaseDrainer"
        case .edit: "edit"
        case .reconcile(let work): "reconcile(\(work))"
        case .discard(let work): "discard(\(work))"
        case .returnWork(let work, let accepts): accepts ? "returnAccept(\(work))" : "returnRefuse(\(work))"
        case .onReport(let work, let event): "onReport(\(work),\(event))"
        case .stage(let text): "stage(\(text))"
        case .flushHeld: "flushHeld"
        case .releaseDrivers: "releaseDrivers"
        case .emit: "emit"
        case .releaseDecided(let index): "releaseDecided(\(index))"
        case .stopCustody: "stopCustody"
        case .deliverEqual(let host): "deliverEqual(\(Self.name(host)))"
        case .present(let index, let owner): "present(\(index),\(Self.name(owner)))"
        case .stopP(let index): "stopP(\(index))"
        case .dropP(let index): "dropP(\(index))"
        case .pending(let owner): "pending(\(Self.name(owner)))"
        case .readSeq(let index): "readSeq(\(index))"
        case .copyOwner: "copyOwner"
        case .dropCopy: "dropCopy"
        case .sendCancel: "sendCancel"
        case .ownerSend: "ownerSend"
        case .commitCurrent: "commitCurrent"
        case .saveProposal: "saveProposal"
        case .commitSaved: "commitSaved"
        case .commitForeign: "commitForeign"
        case .resetOwner: "resetOwner"
        case .observeUnseeded: "observeUnseeded"
        case .claim: "claim"
        case .read: "read"
        case .cancelReader: "cancelReader"
        case .factoryReturnNewest: "factoryReturnNewest"
        case .factoryThrowNewest: "factoryThrowNewest"
        case .cancelFollowerOldest: "cancelFollowerOldest"
        case .cancelCall: "cancelCall"
        case .subscribeZero: "subscribe(fresh,0)"
        case .subscribeReturning: "subscribe(fresh,1+)"
        case .requestOldest: "requestOldest"
        case .cancelFirstSubscriber: "cancelFirstSubscriber"
        case .saveProjected: "saveProjected"
        case .subscribeSavedProjected: "subscribe(savedProjected,max)"
        case .createRefusing: "createRefusing"
        case .createOccupied: "createOccupied"
        case .createClosed: "createClosed"
        case .resume: "resume"
        case .refuseNext: "refuseNext"
        case .occupy: "occupy"
        case .vacate: "vacate"
        }
    }
    static func name(_ host: Int) -> String { ["A", "B", "M", "I"][host] }

    /// Whether this event and `other`, run back to back in either order, leave the same production and
    /// harness state, so the explorer runs only one order (an adjacent-transposition sleep set).
    ///
    /// Only pairs of `hostCancel(X)` with `hostCancel(Y)` or `deliver(Y)`, for shared hosts X ≠ Y:
    /// `hostCancel` parks a worker inside host X's token and runs no main-actor code, creates no value,
    /// and touches only X's token and X's bookkeeping; `deliver(Y)` offers to Y's mailbox, which at most
    /// enqueues a resumption and releases the value it displaces, touching only Y. Neither runs a hook.
    func commutes(with other: ExplorerEvent) -> Bool {
        switch (self, other) {
        case (.hostCancel(let x), .hostCancel(let y)), (.hostCancel(let x), .deliver(let y)),
            (.deliver(let x), .hostCancel(let y)):
            x != y && x < 2 && y < 2
        default:
            false
        }
    }
    /// Whether this event arms a callback, which may still be pending in a later step.
    var arms: Bool {
        switch self {
        case .arm, .onReport: true
        case .then(let first, let second): first.arms || second.arms
        default: false
        }
    }
    /// The hosts this event names.
    var hosts: [Int] {

        switch self {
        case .observe(let host), .observeFrom(let host), .observeAsync(let host), .followAsync(let host),
            .deliver(let host), .deliverElsewhere(let host), .deliverInCancel(let host), .finish(let host),
            .observeClaimed(let host),
            .followCancelled(let host), .echo(let host), .hostCancel(let host),
            .hostCancelReturn(let host),
            .observeAsyncHeld(let host), .observeAsyncNow(let host), .observeAsyncFinished(let host),
            .observeSeq(let host), .followSeq(let host), .followUnseeded(let host), .hostCancelMain(let host),
            .deliverEqual(let host):
            [host]
        case .observeIsolated, .isolatedReturn, .observeActor, .actorReturn: [0]
        case .arm(_, let event): event.hosts
        case .then(let first, let second): first.hosts + second.hosts
        default: []
        }
    }

    /// The raw owner's works this event names.
    var works: [Int] {
        switch self {
        case .refuse(let work), .accept(let work), .reconcile(let work), .discard(let work),
            .returnWork(let work, _):
            [work]
        case .onReport(let work, let event): [work] + event.works
        case .arm(_, let event): event.works
        default: []
        }
    }

    /// Parses one event from its description.
    init?(parsing text: Substring) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("arm("), text.hasSuffix(")") {
            let body = text.dropFirst(4).dropLast()
            guard let comma = body.firstIndex(of: ","), let hook = ExplorerHook(rawValue: String(body[..<comma])),
                let inner = ExplorerEvent(parsing: body[body.index(after: comma)...])
            else { return nil }
            self = .arm(hook, inner)
            return
        }
        if text.hasPrefix("onReport("), text.hasSuffix(")") {
            let body = text.dropFirst(9).dropLast()
            guard let comma = body.firstIndex(of: ","), let work = Int(body[..<comma]),
                let inner = ExplorerEvent(parsing: body[body.index(after: comma)...])
            else { return nil }
            self = .onReport(work, inner)
            return
        }
        if text.hasPrefix("stage("), text.hasSuffix(")") {
            self = .stage(String(text.dropFirst(6).dropLast()))
            return
        }
        if text.hasPrefix("countDuring("), text.hasSuffix(")") {
            guard let inner = ExplorerEvent(parsing: text.dropFirst(12).dropLast()) else { return nil }
            self = .countDuring(inner)
            return
        }
        if let plus = Self.split(text, on: "+") {
            guard let first = ExplorerEvent(parsing: Substring(plus.0)),
                let second = ExplorerEvent(parsing: Substring(plus.1))
            else { return nil }
            self = .then(first, second)
            return
        }
        for candidate in Self.atoms where candidate.description == text {
            self = candidate
            return
        }
        return nil
    }
    // Splits `text` at the first `separator` at parenthesis depth zero.
    private static func split(_ text: String, on separator: Character) -> (String, String)? {
        var depth = 0
        for index in text.indices {
            let character = text[index]
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == separator, depth == 0 {
                return (String(text[..<index]), String(text[text.index(after: index)...]))
            }
        }
        return nil
    }
    /// Every event without an armed hook.
    static var atoms: [ExplorerEvent] {
        var all: [ExplorerEvent] = [
            .factoryReturn, .factoryThrow, .cancelFollower, .stop, .apply, .dropMain, .dropElsewhere,
            .dropAfterJob, .turn, .savePublisher, .subscribeProjected, .request, .cancelSubscription, .applyBelow,
            .close, .tokenDropAfterJob, .stopRacingRemoval, .requestElsewhere, .cancelElsewhere, .observeIsolated,
            .isolatedReturn, .observeActor, .actorReturn, .releaseOwner(elsewhere: false),
            .releaseOwner(elsewhere: true),
            .workerDrop, .workerReturn,
        ]
        all += [
            .driverGo, .releaseNotice, .noticeGo, .register, .registerPending, .cancelOldest, .cancelNewest, .count,
            .holdDrainer, .releaseDrainer, .edit, .createRefusing, .createOccupied, .createClosed, .resume,
            .refuseNext, .occupy, .vacate, .subscribeZero, .subscribeReturning, .requestOldest, .cancelFirstSubscriber,
            .saveProjected, .subscribeSavedProjected, .factoryReturnNewest, .factoryThrowNewest, .cancelFollowerOldest,
            .cancelCall, .observeUnseeded, .claim, .read, .cancelReader, .sendCancel, .ownerSend, .commitCurrent,
            .saveProposal, .commitSaved, .commitForeign, .copyOwner, .dropCopy, .releaseDrivers, .resetOwner, .emit,
            .stopCustody, .flushHeld,
            .releaseDecided(0), .releaseDecided(1),
        ]
        all += [.subscribeElsewhere(once: false), .subscribeElsewhere(once: true)]
        for work in 1 ... 3 {
            all += [
                .refuse(work), .accept(work), .reconcile(work), .discard(work), .returnWork(work, accepts: false),
                .returnWork(work, accepts: true),
            ]
        }
        for index in 0 ..< 3 {
            all += [.stopP(index), .dropP(index), .pending(index), .readSeq(index)]
            for owner in 0 ..< 3 { all.append(.present(index, owner)) }
        }
        for index in 0 ..< 2 {
            all += [
                .save(index), .attach(index), .capture(index), .driver(index), .driverParked(index),
                .releaseInHandOff(index), .releaseInDelivery(index),
            ]
        }
        for host in 0 ..< 2 {
            all += [
                .observe(host), .observeFrom(host), .observeAsync(host), .followAsync(host), .deliver(host),
                .finish(host), .hostCancel(host), .hostCancelReturn(host), .observeAsyncHeld(host), .observeSeq(host),
                .observeAsyncNow(host), .observeAsyncFinished(host), .deliverElsewhere(host), .observeClaimed(host),
                .followCancelled(host), .echo(host), .deliverInCancel(host),
                .followSeq(host), .followUnseeded(host), .hostCancelMain(host), .deliverEqual(host),
            ]
        }
        for host in 2 ..< 4 {
            all += [.observe(host), .deliver(host), .finish(host), .hostCancelMain(host), .deliverInCancel(host)]
        }
        for saved in [false, true] {
            for unlimited in [false, true] { all.append(.subscribe(saved: saved, unlimited: unlimited)) }
        }
        return all
    }
}

/// A sequence in its script form.
func explorerScript(_ events: [ExplorerEvent]) -> String { events.map(\.description).joined(separator: "; ") }

/// Parses a script; `nil` when an event is not recognized.
func explorerParse(_ script: String) -> [ExplorerEvent]? {
    var events: [ExplorerEvent] = []
    // Split on "; " at nesting depth zero.
    var depth = 0
    var current = ""
    for character in script {
        if character == "(" { depth += 1 }
        if character == ")" { depth -= 1 }
        if character == ";", depth == 0 {
            guard let event = ExplorerEvent(parsing: Substring(current)) else { return nil }
            events.append(event)
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty {
        guard let event = ExplorerEvent(parsing: Substring(current)) else { return nil }
        events.append(event)
    }
    return events
}
