# Present state in a screen

Keep one complete snapshot observable and give its owner an explicit lifetime.

The examples in this article present one small graph. A profile loads by name,
can be cancelled while it loads, and can be retried after it fails. Loading it
ends the workflow.

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Profile: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable { let name: String }
    struct Loaded: Sendable { let name: String }
    struct Failed: Sendable {
        let name: String
        let reason: Reason
    }

    enum Reason: String, Error, Sendable { case unavailable }

    @Initial case idle(Idle = Idle())
    case loading(Loading)
    @Terminal case loaded(Loaded)
    case failed(Failed)

    enum Input: Sendable { case load(String), cancel, retry }

    @Operation(activeIn: [Loading.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
        typealias Failure = Reason
    }

    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ name: String) -> Change<Loading, Effect.Begin> {
        Change(Loading(name: name), effects: [.fetch(name)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Loading) -> Idle { Idle() }

    @Transition(on: Input.retry, starts: [Fetch.self])
    fileprivate static func retry(_ source: Failed) -> Change<Loading, Effect.Retry> {
        Change(Loading(name: source.name), effects: [.fetch(source.name)])
    }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ title: Fetch.Output) -> Loaded {
        Loaded(name: title)
    }

    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Loading, _ reason: Fetch.Failure) -> Failed {
        Failed(name: source.name, reason: reason)
    }
}
```

``StateMachinePresentation`` wraps a generated `MainActorHost` as an
`@Observable` model. It requires iOS 17, Mac Catalyst 17, macOS 14, tvOS 17,
watchOS 10, or visionOS 1. Pass the host to its initializer, read
``StateMachinePresentation/snapshot`` from a view, and call
``StateMachinePresentation/send(_:)`` from actions that act on the
current state. Creating a presentation never throws, so it can initialize the
view's `@State` directly.

```swift
import StateMachineUI
import SwiftUI

@MainActor
struct ProfileScreen: View {
    let name: String
    @State private var presentation = StateMachinePresentation(
        Profile.MainActorHost(fetchDriver: { user in .success("Profile of \(user)") })
    )
    @State private var inputFailure: String?

    var body: some View {
        VStack {
            switch presentation.snapshot {
            case .idle:
                Button("Load profile") { send(.load(name)) }
            case .loading:
                ProgressView("Loading profile")
                Button("Cancel", role: .cancel) { send(.cancel) }
            case .loaded(let loaded):
                Text(loaded.value.name)
            case .failed(let failed):
                ContentUnavailableView {
                    Label("Profile Unavailable", systemImage: "person.slash")
                } description: {
                    Text(failed.value.reason.rawValue)
                } actions: {
                    Button("Retry") { send(.retry) }
                }
            }
            if let inputFailure { Text(inputFailure) }
            if presentation.observationFailure != nil { Text("Updates are unavailable.") }
        }
    }

    private func send(_ input: Profile.Input) {
        do {
            try presentation.send(input)
            inputFailure = nil
        } catch {
            inputFailure = "Input was not accepted: \(error)"
        }
    }
}
```

Creating the presentation starts no request. SwiftUI evaluates the initial
value of `@State` each time it creates the view's value and keeps only the
first, so each later evaluation builds a host and a presentation that it then
discards. Each discarded presentation subscribes to its own discarded host and
receives that host's current snapshot, and releasing it removes the registration
in a later main-actor turn. No driver runs and no input is sent. For a view that
its parent recreates often, avoid that work by creating the presentation in the
model that owns the feature and passing it in, or by declaring the `@State`
property optional and creating the presentation in the view's `task` modifier
while the property is still `nil`, because that modifier runs each time the view
appears. Keep the presentation for the screen's lifetime, and create a new one
when returning after `close()`.

If the host has no room for another observer, creation still succeeds. The
presentation shows the host's snapshot at creation and every change made
through it, `isObserving` is `false`, and `observationFailure` holds the
`SubscriptionFailure`. A snapshot that a host of your own delivers inside a
registration call that it then refuses is not shown. The presentation shows what
the owner delivers during that call only once the owner returns the
registration. The same holds for ``StateMachineObservableObject``, the
`ObservableObject` counterpart for the iOS 16 and macOS 13 baseline. It has the
same initializer and members, and a view holds it with `@StateObject` or
`@ObservedObject`.

`resumeObserving()` registers with the same host again, through the same
registration the initializer makes, so a view can keep its `@State`
presentation after another observer frees the slot, or after `stopObserving()`.
The presentation keeps the snapshot it shows, then shows the host's current
snapshot if it is newer, `isObserving` becomes `true`, `observationFailure`
becomes `nil`, and subscribers of `presentedSnapshots` stay attached throughout.
`isObserving` first reports `true` only once that snapshot, or a newer one, is
shown. A call made from a callback of a change the presentation is still
assigning reports `true` once that assignment has completed.
A refusal throws `SubscriptionFailure` at once and changes nothing, keeping the
current snapshot, `isObserving`, and `observationFailure`. While a registration
is live or still being made, the call returns without registering. After
`close()`, the closed host finishes the new registration inside the call, so it
returns without throwing and `isObserving` stays `false`. A host of your own
that refuses a closed owner's registration throws its failure instead.

```swift
@MainActor
func retryUpdates(_ presentation: StateMachinePresentation<Profile.MainActorHost>) {
    do {
        try presentation.resumeObserving()
    } catch {
        print("Updates are still unavailable: \(error)")
    }
}
```

On iOS 17 and later a generated `MainActorHost` is itself `Observable`, so a view
can also hold the host and read its `currentSnapshot` directly. A presentation
gives the same screen an `ObservableObject` form for the iOS 16 baseline, and it
drives any `MainActorStateMachineHost`, so a preview or a test can substitute a
host of its own.

## Accept input and publish without suspension

`send(_:)` routes, prepares, and admits the input in the current `MainActor`
turn, then publishes the accepted snapshot before it returns. A call made during
a publication, as from a callback of a snapshot change, returns its receipt at
once instead, and the presentation publishes the latest snapshot deferred that
way after the current callback returns. Driver work runs afterward. When a result returns, the host checks its operation authority,
prepares the completion from a fresh snapshot, and checks that snapshot's
revision at commit. Snapshots that arrive later, such as an operation's result,
reach the presentation through the host's subscription. Cancelling a load or
changing the account can revoke operation authority and make a late response
stale.

`send(_:)` throws `SendRejection`. The `.preparation` case covers a missing
route or an edge or router that declines the input. The `.commit` case means the
owner refused the prepared change, for example because it is closed, or because
its effect plan is defective, which is `.commit(.plan)`.

## Act on the snapshot a view rendered

`send(_:)` routes an input against whatever the host currently holds. Use it for
an event that should act on the current state, such as a push notification, a
timer, or a tap that means "cancel the current load".

Each case of the snapshot holds an `Observed<Phase>`, whose edge methods exist
only for edges whose source is that phase. Calling one prepares a proposal, and
an edge that cannot fail needs no `try`. `commit(_:)` on the presentation admits
the proposal only if that observation is still the owner's current revision,
shows the resulting snapshot before it returns, as `send(_:)` does, and returns
a `CommitResult` of `.committed(receipt)` or `.rejected(reason, current:)`. The
result is not discardable.

Use `commit` when the action belongs to the exact observation the user saw, and
handle `.conflict`, which an unrelated intervening revision causes, whereas a
closed owner reports `.closed`. The call is compile-checked. If an edge is
removed or moved to another phase, the view that calls it stops compiling,
whereas `send(_:)` routes a declared input at run time. It reports
`.preparation(.invalidPhase)` if the current phase has no edge or router for
that input. An edge that declares a typed throw is prepared with `try`, and it
throws exactly that failure.

```swift
@MainActor
struct ProfileActions: View {
    let presentation: StateMachinePresentation<Profile.MainActorHost>
    @State private var notice: String?

    var body: some View {
        VStack {
            switch presentation.snapshot {
            case .loading(let loading):
                Button("Cancel", role: .cancel) { show(presentation.commit(loading.cancel())) }
            case .failed(let failed):
                Button("Retry") { show(presentation.commit(failed.retry())) }
            case .idle, .loaded:
                EmptyView()
            }
            if let notice { Text(notice) }
        }
    }

    private func show(_ result: Profile.CommitResult) {
        switch result {
        case .committed:
            notice = nil
        case .rejected(.conflict, _):
            notice = "The profile changed. Try again."
        case .rejected(let reason, _):
            notice = "The change was not accepted: \(reason)"
        }
    }
}
```

Each button prepares its edge from the observation it was rendered from. If
another ordinary commit advances the same open owner before the tap, the
proposal is rejected with `.conflict`. If the owner closes first, the rejection
is `.closed`.

Observe the complete `snapshot` rather than maintaining independently published
phase fields. The presentation applies only strictly increasing revisions, so it
can show an immediate receipt before asynchronous observation reaches the same
revision, without regressing when that delayed observation arrives.

A presentation over a host observes that one host for its lifetime. A restored
or forked owner starts at revision zero, so create a new presentation for it
rather than feeding those revisions into the original presentation's watermark.
A passive presentation, described below, can move to another owner by observing
it.

## Separate observation from running work

``StateMachinePresentation/stopObserving()`` removes only the registration and
leaves the owner open. ``StateMachinePresentation/close()`` closes the owner's
work authority, stops observing, and publishes its terminal snapshot. Because
the owner is closed first, a callback of that end that resumes observing finds
it closed, and no registration is live once `close()` returns. Closed
historical loading data cannot authorize another request.

Once either `stopObserving()` or `close()` has begun to end the registration,
the presentation shows nothing the owner delivers through it, including a
snapshot that a host of your own delivers from inside the subscription's
cancellation. What `send(_:)`, `commit(_:)`, and `close()` return is still
shown. Stopping discards any observation value whose publication has not been
announced. A snapshot the registration delivered while another snapshot was
being assigned, which was waiting for that assignment, is not shown, and
neither is one whose own `revision` stops the presentation when it is read.
Each waiting value belongs to the registration that delivered it, so a
registration resumed from a callback of the stop keeps the snapshot it delivers,
and the presentation becomes live showing it or a newer one. A change admitted
through the presentation still publishes its receipt, even when it waited the
same way.

One rule covers every end a driving presentation makes, whether by
`stopObserving()`, `close()`, the owner's finish, or the presentation's
release. Any snapshot delivered through a registration that is no longer the
presentation's is kept in the presentation's storage and released on the main
actor only once every cancellation the presentation started has returned, so
its destructor finds the slot free. Once no cancellation is running, a snapshot
that a host of your own delivers through a callback whose cancellation has
already returned is released at once on the main actor. The same holds for a
registration that the presentation lets go while the owner is still making it,
such as when a host of your own stops the presentation from inside its
`subscribe`. The presentation cancels that registration as soon as the owner
returns it, and what the owner delivered inside that call is released once that
cancellation has returned.

`isObserving` becomes `true` only for a registration that became live, so a
registration that ends first, as a closed owner's does inside the call, changes
nothing, even when a callback of its cancellation stops the presentation. When
the owner finishes the registration itself, by closing or being released, the
presentation cancels the registration's subscription before `isObserving`
becomes `false`, so a host of your own that frees its slot when its
subscription is cancelled has it free by then. When a host cancels the
subscription itself and ends the registration from inside that cancellation, by
finishing it or by stopping the presentation, the presentation reports `false`
once that cancellation has returned.

A presentation can be released on another thread, as when an object that stores
it is released there. It then stops delivery at once, and a later main-actor
turn finishes the subscribers of its Combine publisher and removes its
registration, which frees the slot of a host of your own. An installed
generated registration frees its slot when the presentation is released. If an
owner on another actor is still handing the registration back, the turn that
disposes of the presentation frees it. Only once that removal has completed
does the presentation release the snapshot it showed, any element still unread,
its revision closure, a driving presentation's owner, and any snapshot that a
host of your own delivered from inside that removal's cancellation, all on the
main actor. A host of your own that is cancelling the registration's token on
another thread at that moment completes the removal when its cancellation
returns, and the presentation keeps those values until then. Stopping or
replacing an observation releases any element it left unread on the main actor
in the same way, once the removal has completed.

Cancellation is cooperative. A driver can continue running after the screen
disappears, and its handle remains tracked until actual termination. Await the
host's `shutdown(deadline:)` through ``StateMachinePresentation/host`` when the
surrounding task needs that termination and delivery cleanup to finish. It
returns `.quiescent`, or `.timedOut` with diagnostics if the deadline passes
first, and it is discardable. A driver that never returns can prevent an
unbounded wait from finishing, whereas `close()` itself is synchronous and
discardable.

Releasing an owner without closing it publishes no closed snapshot. It finishes
the registrations the owner retained, so no snapshot has `isClosed == true`.
Closing is the only path that publishes one.

## Drive a UIKit view

A view controller can iterate the host's snapshot sequence in a task. Creating
the sequence throws `SubscriptionFailure` when subscriber capacity is
exhausted, while iterating never throws. A task created in a `@MainActor`
method runs on the main actor. The controller keeps the sequence and cancels it
before it registers a replacement and when it disappears. Calling `cancel()`
frees the subscriber slot before it returns, so the replacement registers even
when the owner allows one subscriber, while cancelling only the task ends the
old sequence when its loop next reads. A read that the sequence had already
handed a snapshot when `cancel()` ran still returns it, so the loop checks its
task's cancellation immediately before it renders. The check and the render run
in the same main-actor turn, so a cancelled loop never renders. This screen
shows its states with `UIContentUnavailableConfiguration`, which exists from
iOS 17, tvOS 17, Mac Catalyst 17, and visionOS 1, so the class is marked
available from those releases. An app whose deployment target is earlier
creates it behind `if #available`.

```swift
import UIKit

@available(iOS 17, tvOS 17, *)
@MainActor
final class ProfileViewController: UIViewController {
    private let host: Profile.MainActorHost
    private var snapshots: Profile.Snapshots?
    private var observation: Task<Void, Never>?
    private let nameLabel = UILabel()

    init(host: Profile.MainActorHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        stopObserving()
        do {
            let snapshots = try host.snapshots()
            self.snapshots = snapshots
            observation = Task {
                for await snapshot in snapshots {
                    guard !Task.isCancelled else { break }
                    self.render(snapshot)
                }
            }
        } catch {
            showUnavailable(retry: nil)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObserving()
    }

    private func stopObserving() {
        snapshots?.cancel()
        snapshots = nil
        observation?.cancel()
        observation = nil
    }

    private func render(_ snapshot: Profile.Snapshot) {
        switch snapshot {
        case .idle:
            nameLabel.text = nil
            contentUnavailableConfiguration = nil
        case .loading:
            nameLabel.text = nil
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .loaded(let loaded):
            nameLabel.text = loaded.value.name
            contentUnavailableConfiguration = nil
        case .failed:
            let retry = UIAction(title: "Retry") { [weak self] _ in
                _ = try? self?.host.send(.retry)
            }
            showUnavailable(retry: retry)
        }
    }

    private func showUnavailable(retry: UIAction?) {
        nameLabel.text = nil
        var unavailable = UIContentUnavailableConfiguration.empty()
        unavailable.text = "Profile Unavailable"
        if let retry {
            unavailable.button = .plain()
            unavailable.buttonProperties.primaryAction = retry
        }
        contentUnavailableConfiguration = unavailable
    }
}
```

The sequence delivers only the latest snapshot, so a loop that is busy skips
intermediate snapshots and sees strictly increasing revisions. If the owner
closes and the task continues iterating, the last element is the closed
snapshot. Cancelling the task ends the sequence at the loop's next read, and
`cancel()` ends it at once. The sequence also ends when the host is released
without closing, in which case no element has `isClosed == true`. A loop sees
an accepted input on a later turn, so code that needs the result in the same
turn uses the receipt from `send`, or a presentation.

In a `shared` schema the sequence is a `Snapshots` value, an alias of
`SnapshotSequence<Snapshot>`. It works with `map`, `prefix`, and generic
`AsyncSequence` code on every supported OS, and a `for await` loop over it runs
on the caller's actor.

In an `isolated` schema `snapshots()` returns a `MainActorSnapshots` value, an
alias of `MainActorSnapshotSequence<Snapshot>`, read on the main actor because
its snapshots are not `Sendable`. It is a noncopyable stream with one consumer,
read with `while let snapshot = await snapshots.next()` rather than `for await`,
and it has no sequence operators, because those run their closures off the main
actor. For `for await` or operators, pass a closure that projects each snapshot
to a `Sendable` value, as in `host.snapshots({ $0.revision })`. The closure runs
on the main actor and the result is an ordinary sequence of the projected values.

For Combine, ``StateMachineObservableObject/presentedSnapshots`` publishes a
`Sendable` snapshot, delivering the snapshot shown when a subscriber attaches
and then each newly shown one. A change that the subscriber has demand for
arrives after `objectWillChange` and before `snapshot` returns it. A change
that waits for demand arrives once the subscriber asks again and its previous
callback has returned, when `snapshot` may already return it, so render the
value delivered rather than reading `snapshot`. The presentation keeps the
snapshot in storage that a main-actor turn empties when the presentation is
released, so `snapshot` is not a `@Published` property. The runtime's
registration types are `SnapshotSubscription`, `MainActorSnapshotSubscription`,
and `IsolatedSnapshotSubscription`, so importing Combine beside State Machine
leaves `Subscription` meaning Combine's protocol.

```swift
import Combine

@MainActor
func bind(
    _ presentation: StateMachineObservableObject<Profile.MainActorHost>,
    to render: @escaping @MainActor (Profile.Snapshot) -> Void
) -> AnyCancellable {
    presentation.presentedSnapshots.sink { render($0) }
}
```

Retain the returned `AnyCancellable` for as long as the view observes.

A pipeline can move each value to another thread, as `receive(on:)` does, so a
snapshot that is not `Sendable`, such as that of an `isolated` schema like
`Note`, has no `presentedSnapshots`. Publish a `Sendable` projection of it
instead, which the presentation computes on the main actor.

```swift
@MainActor
func titles(
    of presentation: StateMachineObservableObject<Note.MainActorHost>
) -> PresentationPublisher<String> {
    presentation.presentedSnapshots(projecting: { snapshot in
        if case .draft(let draft) = snapshot { draft.value.text } else { "" }
    })
}
```

Either publisher keeps one pending value for each subscriber and delivers it as
the subscriber's demand allows, so a subscriber that requests slowly receives
the latest snapshot and never an older one. A subscriber receives publications
in the order the presentation shows them, and revision order belongs to one
observation. Within a single observation, each value has a higher revision than
the one before and no revision arrives twice. A passive presentation that
observes another owner shows that owner's current snapshot as a new baseline,
so a subscriber that received revision 9 from one owner can next receive
revision 0 from another, or two snapshots at revision 0 from two fresh owners.
The publisher registers a subscriber before it reads the snapshot that
subscriber receives first, so a snapshot shown from inside the subscription, or
from the subscriber's first value, reaches the subscriber next.

The publisher belongs to the presentation rather than to one observation. It
stays open across `stopObserving()`, `close()`, and every new observation, and
`isObserving` reports whether an observation is live. It does not keep the
presentation alive. Once the presentation is released, it delivers no further
value. A later main-actor turn finishes every subscriber, discarding any value
its demand had not reached by the release, even when demand arrives before that
turn. A subscriber that attaches after the release, to a publisher kept from
before it, receives `.finished` at once. A client that keeps the publisher can
therefore tell a presentation that is not observing now from one that can never
publish again.

Without a presentation, a `MainActorHost` or `Shared` owner offers
`snapshotPublisher(_:)`, which publishes a `Sendable` projection of each
snapshot, and an `ActorHost` offers it `async`. In a `shared` schema,
`snapshotPublisher()` publishes the snapshot itself. A publisher's output is
always `Sendable`, because a pipeline can move it to another thread. It
delivers on the main actor, accepts one subscriber, holds a subscriber slot
until its subscription is cancelled, and finishes after the closed snapshot.

## Present an owner passively

``SnapshotPresentation`` and its `ObservableObject` counterpart
``SnapshotObservableObject`` present an owner's snapshots without driving it.
Use them for owners that are not confined to the main actor, for a view that
only reads, and for snapshots of any other type. Create one from a generated
snapshot, as in `SnapshotPresentation(host.snapshot())`. For another type, also
pass a closure that reads a snapshot's revision.

`observe(_:)` binds the presentation to a host of any kind. It registers with
the host, shows the host's current snapshot, read once the registration exists,
restarts its revision check from it, and then applies each later snapshot on the
main actor. The presentation owns the registration from the moment the host
returns it, before it reads that snapshot, so `stopObserving()` or another
observation that starts during the read releases the registration at once. When
the read returns, a newer snapshot that the registration already holds wins,
such as the closed snapshot of an owner that closed meanwhile.

- For a `MainActorHost`, a `Shared` owner, or an `IsolatedHost` confined to the
  main actor, it is synchronous.
- For an `ActorHost`, it is `async`, because registering and reading the host's
  snapshot await.
- For an `IsolatedHost` confined to another actor, call it on that actor with
  `await`. It ends the presentation's current observation on the main actor
  first, then takes the registration and the snapshot in one turn of the
  owning actor and hands both to the main actor. The snapshot must be
  `Sendable`, because it crosses to the main actor. An observation that
  replaces this one before the hand-off arrives makes the owning actor release
  the registration as soon as the host returns it.

Every form releases the observation it replaces before it registers, so
observing a host again, even one with a single subscriber slot, reuses the
slot. `isObserving` becomes `true` once the presentation has shown the new
registration's snapshot, after every snapshot publication in progress then has
returned, and the registration is still open, and `false` when the observed
owner closes or is released. The presentation cancels the ended registration
before it reports `false`, so a host of your own that frees its slot only when
its subscription is cancelled has the slot free by then. It throws
`SubscriptionFailure` when the host has no room for another registration.
`isObserving` is then `false`, and the refused observation shows no snapshot
and publishes no change of its own. Observing a host that has already closed
shows its closed snapshot, and `isObserving` stays `false`, because a closed
host holds no registration. The same holds for a registration that ends while
its first snapshot is shown, such as one whose host finishes it from a callback
of that publication.

```swift
@MainActor
func showProfile(
    _ presentation: SnapshotPresentation<Profile.Snapshot>,
    from shared: Profile.Shared
) throws {
    try presentation.observe(shared)
}

@MainActor
func showProfile(
    _ presentation: SnapshotPresentation<Profile.Snapshot>,
    from actorHost: Profile.ActorHost
) async throws {
    try await presentation.observe(actorHost)
}

actor ProfileStore {
    private var host: Profile.IsolatedHost<ProfileStore>?

    func present(in presentation: SnapshotPresentation<Profile.Snapshot>) async throws {
        let host = self.host ?? Profile.IsolatedHost(
            isolation: self,
            fetchDriver: { _, user in .success("Profile of \(user)") }
        )
        self.host = host
        try await presentation.observe(host)
    }
}
```

Each owner counts its own revisions, so every new observation starts from the
snapshot it shows first, and a presentation can move from one owner to another
by observing it. Deliveries that the replaced observation still makes are
discarded. A callback that runs while the presentation shows the new snapshot,
such as a view update, can start another observation. The later observation
wins, and the registration it replaced is cancelled.

### Reentrant registration and observation status

A callback that runs while a host is still registering an observation, such as
an Observation reader of the host's `subscriberCount` or a `Shared` host of
your own that calls back before it returns its sequence, can start another
observation too. The earlier observation still holds its slot until the host
returns its registration, and a registration that a host of your own is still
cancelling holds its slot until that cancellation returns. A synchronous
`observe(_:)` cannot wait for either. It registers at once, and when a host
with a single slot refuses it, the refusal throws at once and nothing registers
later.

The `async` forms wait instead. An `async` observation of an `ActorHost`, or of
an `IsolatedHost` on another actor, asks the host only once every earlier
registration of the presentation with that host, or through a registration
closure whose host the presentation cannot know, has returned and been
installed or released, and every such registration it let go has been removed.
It then registers once, and a refusal throws. Another observation or
`stopObserving()` that replaces a waiting observation makes it return at once
without registering or throwing, and cancelling its task ends the wait, so it
registers at once. An observation that a later one replaced ends without
throwing, even when its host refused it. Each registration attempt keeps its
own first snapshot and finish until the presentation owns its registration, so
a finish that one host delivers while it registers never ends another host's
observation, and the callbacks of a refused attempt, which a host may call or
release later, never end a later observation.

`isObserving` changes only when observation starts or ends, and each change is
published once and in order. A change to `false` is published once every
registration the presentation has let go has been removed, which is when a host
of your own frees the slot of a token it is cancelling, and the changes after
it wait behind it. A callback of the change that starts or ends another
observation publishes each of its own changes after the change in progress, so
a callback of `true` that stops and then starts another observation publishes
`false` and then `true`. A subscriber that reacts to `false` by observing a
fallback therefore sees `false` and then `true`, and when the fallback's host
refuses it, sees only the `false` that started it, so a fallback cannot call
itself again. A synchronous observation of the same host started while that
slot is still being removed, as one started from inside the host's own
cancellation of the registration, throws the host's refusal. A subscriber that
observes the host again from `false` finds the slot free.

### Following a snapshot sequence

A presentation can also follow a snapshot sequence. `observe(_:)` with a
`SnapshotSequence` follows it in a task the presentation owns, and
``SnapshotPresentation/follow(_:)`` follows it for as long as the calling task
runs. Either shows the sequence's first element, which is the snapshot current
when the sequence registered or a newer one, and then applies later elements
through the revision check. `isObserving` becomes `true` once the first element
is shown, so a sequence that has delivered nothing yet, such as a `Shared`
owner's whose first element is still on its delivery task, is live only once
that element arrives. The presentation applies at most 32 elements of one
registration in one main-actor turn, including the first element and regardless
of what an earlier observation applied in that turn, and continues on a later
turn, so a sequence that delivers again from each snapshot shown cannot hold
the main actor.

The observation is live while its registration is open, however many elements
still wait in it, so a screen whose owner delivers without pause reports `true`
while it renders. A sequence that has finished with its final element still
unread is not live, and the presentation shows that element on a later turn and
ends. A sequence that has already ended, as a closed owner's has, shows the
closed snapshot it holds, and `isObserving` stays `false`, as it does when the
presentation observes the closed owner itself. A sequence that another consumer
is already iterating belongs to that consumer, so the presentation shows
nothing from it, reports nothing, and leaves its registration alone, while
`follow(_:)` returns at once. `follow(_:)` in a task that is already cancelled
ends the current observation and releases the sequence without showing it. The
presentation owns the sequence from the moment either call receives it, before
it ends the observation the sequence replaces, so a callback of that end that
stops the presentation or starts another observation lets the sequence go like
any other registration. A change of `isObserving` to `false` waits until the
sequence's slot is free, and an `async` observation waits until the sequence
has been released.

To observe a projection, give it the owner's revision, which the presentation
reads to order what it shows, and pass a closure that registers it.

```swift
nonisolated struct NameSnapshot: Sendable {
    let revision: UInt64
    let name: String?
}

@MainActor
func presentName(of machine: Profile.Shared) throws -> SnapshotPresentation<NameSnapshot> {
    let names = SnapshotPresentation(NameSnapshot(revision: 0, name: nil), revision: { $0.revision })
    try names.observe(snapshotsFrom: {
        try machine.snapshots { snapshot in
            if case .loaded(let loaded) = snapshot {
                NameSnapshot(revision: snapshot.revision, name: loaded.value.name)
            } else {
                NameSnapshot(revision: snapshot.revision, name: nil)
            }
        }
    })
    return names
}
```

`observe(snapshotsFrom:)` ends the current observation before the closure runs,
so observing the same owner again needs no spare slot, while
`names.observe(try machine.snapshots(project))` registers first, because Swift
evaluates the argument before the call, and an owner with one slot refuses it.
Its `async` form takes a closure that may await, as
`try await names.observe(snapshotsFrom: { try await actor.snapshots(project) })`
does for an `ActorHost`, and returns once the sequence's first element, if it
holds one, is shown, including when the call starts inside a snapshot callback
and that publication shows the element after the callback returns. The
observation then belongs to the presentation.
``SnapshotPresentation/follow(snapshotsFrom:)`` does the same for the calling
task. A refusal is thrown with the closure's error, and an observation that
another observation or ``SnapshotPresentation/stopObserving()`` replaced while
the closure ran releases the sequence the closure returns and throws nothing.

The closure of either `async` form runs only once every registration that an
earlier observation of the presentation is still making, through a closure or
with a host, has returned and been installed or released. On a host with one
slot, an observation that replaces one whose closure is still awaiting the host
therefore waits for that closure, and then finds the slot free, instead of
being refused. The wait ends without running the closure when another
observation or `stopObserving()` replaces the waiting one, and, for
`follow(snapshotsFrom:)`, when its task is cancelled. A closure that never
returns keeps the observations that replace it waiting. The synchronous form
cannot wait and runs its closure at once, so while an earlier `async`
registration holds a host's only slot, that host refuses it and the refusal is
thrown. An `async` observation of a host itself waits for a registration
through a closure that is in flight as it waits for an earlier registration
with the same host, because the presentation cannot know which host a closure
registers with.

``SnapshotPresentation/apply(_:)`` applies one snapshot yourself and accepts
only a newer revision. A snapshot applied after an observation starts belongs
to that observation, so its first snapshot does not replace one that is at
least as new, and a snapshot whose revision closure starts another observation
belongs to the one it replaced and is not applied. A snapshot applied from a
callback of a publication waits for that publication to show it. When its
observation ends or the task that follows it is cancelled first, it is never
shown, and a later snapshot is compared with the one shown or being shown
instead, so a snapshot that will not appear never holds back a newer one.
``SnapshotPresentation/stopObserving()`` removes the registration without
closing the owner, before it returns. A registration that the host is still
making, when a callback that its registration call runs stops the presentation,
is released as soon as that call returns it.

## Bridge a shared or actor host

A `Shared` or `ActorHost` owner is not confined to `MainActor`. In a SwiftUI
view, follow the owner's snapshot sequence from the view's task, so the
observation ends when the view disappears.

```swift
@MainActor
struct ProfileName: View {
    let machine: Profile.Shared
    let profile: SnapshotPresentation<Profile.Snapshot>

    var body: some View {
        Group {
            if case .loaded(let loaded) = profile.snapshot {
                Text(loaded.value.name)
            } else {
                ProgressView()
            }
        }
        .task(id: [ObjectIdentifier(machine), ObjectIdentifier(profile)]) {
            try? await profile.follow(snapshotsFrom: { try machine.snapshots() })
        }
    }
}
```

The task is keyed to both objects, so a view that SwiftUI keeps while it is
given another machine, or another presentation, cancels the task that follows
the old pair and starts another.

``SnapshotPresentation/follow(snapshotsFrom:)`` registers the sequence only once
the presentation has released its current registration, so the task of a
replacement view observes a host with one slot too, and it returns when the
sequence ends, the calling task is cancelled, or the presentation stops or
replaces the observation, and only once the observation has ended, so the
observation belongs to the task even when it starts inside a snapshot callback.
That callback's publication decides whether the observation is live once it
returns, without running other client code, and the task applies whatever
waits after that. Each wait of the task checks its cancellation, both when
reading the next element and on the turn the presentation gives up after 32
elements. A cancellation that a snapshot callback issues while the task applies
elements ends the observation before the task shows another one or reports it
live, and withdraws any snapshot applied during that publication before the
cancellation that the publication was to show once its callbacks returned. A
snapshot that the callback applies after the cancellation is shown. SwiftUI
cancels the view's task when the view disappears.

``SnapshotObservableObject`` has the same observation operations at the iOS 16
baseline. Its `observe(_:)` keeps observing until
``SnapshotObservableObject/stopObserving()`` or until the owner's sequence ends.

```swift
@MainActor
func present(_ shared: Profile.Shared) throws -> SnapshotObservableObject<Profile.Snapshot> {
    let presentation = SnapshotObservableObject(shared.snapshot())
    try presentation.observe(shared)
    return presentation
}
```

The snapshot sequence keeps only the latest pending snapshot, and
``SnapshotObservableObject/isObserving`` becomes `false` when the sequence ends,
after the owner closes or is released. ``SnapshotObservableObject/snapshot``
keeps the last value applied, and
``SnapshotObservableObject/presentedSnapshots`` and
``SnapshotObservableObject/presentedSnapshots(projecting:)`` are its Combine
publishers, which behave as a driving presentation's do.
Observation coalesces presentation data only, while every accepted effect
remains the host's responsibility.

``MainActorSnapshotIngress`` is the lower-level option when snapshots arrive
through a subscription callback outside `MainActor`. Pass their `Sendable`
snapshots to ``MainActorSnapshotIngress/offer(_:revision:)`` and select a
`MainActor` callback that applies them to the presentation. Capture the
presentation weakly if the bridge belongs to a separate observation lifetime.
The bridge holds one newest pending snapshot, ignores older or duplicate
revisions, and bounds delivery work per turn. Call
``MainActorSnapshotIngress/cancel()`` and cancel the host subscription when
ending that observation lifetime. An already claimed callback may finish.
