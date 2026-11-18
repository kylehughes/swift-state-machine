# Present state in a screen

Keep one complete snapshot observable and give its owner an explicit lifetime.

The examples in this article present one small graph. A profile loads by name,
can be cancelled while it loads, and can be retried after it fails:

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
    case loaded(Loaded)
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
view's `@State` directly:

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
value of `@State` each time it rebuilds the view and keeps only the first, so
the copies it discards cost nothing. Keep the presentation for the screen's
lifetime, in `@State` or in the model that owns the feature, and create a new
one when returning after `close()`.

If the host has no room for another observer, creation still succeeds. The
presentation shows the host's snapshot at creation and every change made
through it, `isObserving` is `false`, and `observationFailure` holds the
`SubscriptionFailure`. The same holds for ``StateMachineObservableObject``, the
`ObservableObject` counterpart for the iOS 16 and macOS 13 baseline. It has the
same initializer and members, and a view holds it with `@StateObject` or
`@ObservedObject`.

## Accept input and publish without suspension

`send(_:)` routes, prepares, and admits the input in the current `MainActor`
turn, then publishes the accepted snapshot before it returns. Driver work runs
afterward. When a result returns, the host checks its operation authority,
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
an event that should act on the current state: a push notification, a timer, or
a tap that means "cancel the current load".

Each case of the snapshot holds an `Observed<Phase>`, whose edge methods exist
only for edges whose source is that phase. Calling one prepares a proposal, and
an edge that cannot fail needs no `try`. `commit(_:)` on the presentation admits
the proposal only if that observation is still the owner's current revision,
shows the resulting snapshot before it returns, as `send(_:)` does, and returns
a `CommitResult`: `.committed(receipt)` or `.rejected(reason, current:)`. The
result is not discardable.

Use `commit` when the action belongs to the exact observation the user saw, and
handle `.conflict`, which an unrelated intervening revision causes; a closed
owner reports `.closed` instead. The call is compile-checked: if an edge is
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
A passive presentation, described below, switches owners explicitly.

## Separate observation from running work

``StateMachinePresentation/stopObserving()`` removes only the registration and
leaves the owner open. ``StateMachinePresentation/close()`` stops observing,
closes the owner's work authority, and publishes its terminal snapshot. Closed
historical loading data cannot authorize another request.

Cancellation is cooperative. A driver can continue running after the screen
disappears, and its handle remains tracked until actual termination. Await the
host's `shutdown(deadline:)` through ``StateMachinePresentation/host`` when the
surrounding task needs that termination and delivery cleanup to finish. It
returns `.quiescent`, or `.timedOut` with diagnostics if the deadline passes
first, and it is discardable. A driver that never returns can prevent an
unbounded wait from finishing; `close()` itself is synchronous and discardable.

Releasing an owner without closing it publishes no closed snapshot. It finishes
the registrations the owner retained, so no snapshot has `isClosed == true`;
closing is the only path that publishes one.

## Drive a UIKit view

A view controller can iterate the host's snapshot sequence in a task. Creating
the sequence throws `SubscriptionFailure` when subscriber capacity is
exhausted; iterating never throws. A task created in a `@MainActor` method runs
on the main actor, and cancelling it ends the sequence and removes the
registration. `UIContentUnavailableConfiguration` requires iOS 17, tvOS 17,
Mac Catalyst 17, or visionOS 1:

```swift
import UIKit

@MainActor
final class ProfileViewController: UIViewController {
    private let host: Profile.MainActorHost
    private var observation: Task<Void, Never>?
    private let nameLabel = UILabel()

    init(host: Profile.MainActorHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        observation?.cancel()
        observation = Task {
            do {
                for await snapshot in try self.host.snapshots() {
                    self.render(snapshot)
                }
            } catch {
                self.showUnavailable(retry: nil)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
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

The sequence delivers the latest snapshot, not every snapshot: a loop that is
busy skips intermediate snapshots and sees strictly increasing revisions. If the
owner closes and the task continues iterating, the last element is the closed
snapshot. Cancelling iteration can end the sequence earlier. The sequence also
ends when the host is released without closing; in that case no element has
`isClosed == true`. A loop sees an accepted input on a later turn, so code that
needs the result in the same turn uses the receipt from `send`, or a
presentation.

In a `shared` schema the sequence is a `Snapshots` value, an alias of
`SnapshotSequence<Snapshot>`. It works with `map`, `prefix`, and generic
`AsyncSequence` code on every supported OS, and a `for await` loop over it runs
on the caller's actor.

In an `isolated` schema the sequence is a `MainActorSnapshots` value, an alias
of `MainActorSnapshotSequence<Snapshot>`, iterated on the main actor because its
snapshots are not `Sendable`. Using `for await` works on every supported OS.
Operators need a deployment target of iOS 18, macOS 15, tvOS 18, watchOS 11, or
visionOS 2. For an earlier target, pass a closure that projects each snapshot to
a `Sendable` value, as in `host.snapshots({ $0.revision })`. The closure runs on
the main actor and the result is an ordinary sequence of the projected values.

For Combine, `$snapshot` on a ``StateMachineObservableObject`` is the publisher.
It does not complete; `$isObserving` becoming `false` signals the end. The
runtime's registration types are `SnapshotSubscription` and
`MainActorSnapshotSubscription`, so importing Combine beside State Machine
leaves `Subscription` meaning Combine's protocol:

```swift
import Combine

@MainActor
func bind(
    _ presentation: StateMachineObservableObject<Profile.MainActorHost>,
    to render: @escaping @MainActor (Profile.Snapshot) -> Void
) -> AnyCancellable {
    presentation.$snapshot.sink { render($0) }
}
```

Retain the returned `AnyCancellable` for as long as the view observes.

## Present an owner without a hosting protocol

``SnapshotPresentation`` and its `ObservableObject` counterpart
``SnapshotObservableObject`` present snapshots of any type. For a generated
snapshot, create it from the owner's current snapshot. For another type, also
pass a closure that reads a snapshot's revision. Register an owner's
subscription with `observe(_:)`, or apply snapshots yourself. Use it for owners
that do not conform to `MainActorStateMachineHost`.
``SnapshotPresentation/apply(_:)`` accepts strictly increasing revisions, and
``SnapshotPresentation/stopObserving()`` removes only the registration.

Each owner counts its own revisions, so a passive presentation that begins
observing a different owner passes that owner's current snapshot as
`startingAt:`. The presentation shows that snapshot at once, restarts its
revision check from it, and ignores any late delivery from the owner it
replaced. Without `startingAt:`, the new registration continues the same owner's
history, and a delivery that is not newer than the snapshot shown is discarded.
Both `observe` forms and `follow` take it. A callback that runs while the
presentation shows the new snapshot, such as a view update, can switch it again;
the later switch wins, and the registration it replaced is cancelled. A closure
literal does not infer a typed throw, so the registration closure spells
`throws(SubscriptionFailure)`:

```swift
@MainActor
func switchOwner(
    _ presentation: SnapshotPresentation<Profile.Snapshot>,
    to other: Profile.Shared
) throws {
    presentation.observe(try other.snapshots(), startingAt: other.snapshot())
}

@MainActor
func switchHost(
    _ presentation: SnapshotPresentation<Profile.Snapshot>,
    to other: Profile.MainActorHost
) throws(SubscriptionFailure) {
    try presentation.observe(startingAt: other.snapshot()) {
        (receive, finish) throws(SubscriptionFailure) in
        try other.subscribe(receive, onFinish: finish)
    }
}
```

## Bridge a shared or actor host

A `Shared` or `ActorHost` owner is not confined to `MainActor`. Create a
``SnapshotPresentation`` from its current snapshot, as in
`SnapshotPresentation(machine.snapshot())`, and follow the owner's
snapshot sequence from the view's task. The presentation applies each snapshot
on `MainActor` through the revision check:

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
        .task {
            guard let snapshots = try? machine.snapshots() else { return }
            await profile.follow(snapshots)
        }
    }
}
```

``SnapshotPresentation/follow(_:startingAt:)`` returns when the
sequence ends, the calling task is cancelled, or the presentation stops or
replaces the observation. SwiftUI cancels the view's task when the view
disappears. ``SnapshotObservableObject`` has the same members at the iOS 16
baseline, and `observe(_:startingAt:)` starts the observation in a task the
presentation owns:

```swift
@MainActor
func present(_ shared: Profile.Shared) throws -> SnapshotObservableObject<Profile.Snapshot> {
    let presentation = SnapshotObservableObject(shared.snapshot())
    presentation.observe(try shared.snapshots())
    return presentation
}
```

Creating the sequence throws `SubscriptionFailure` when subscriber capacity is
exhausted. For an `ActorHost`, use `try await actor.snapshots()`. The snapshot
sequence keeps only the latest pending snapshot, and
``SnapshotObservableObject/isObserving`` becomes `false` when the sequence ends,
after the owner closes or is released. ``SnapshotObservableObject/snapshot``
keeps the last value applied. ``SnapshotObservableObject/stopObserving()`` ends
the observation, and `$snapshot` is the Combine publisher. Observation coalesces
presentation data only; every accepted effect remains the host's responsibility.

``MainActorSnapshotIngress`` is the lower-level option when snapshots arrive
through a subscription callback outside `MainActor`. Pass their `Sendable`
snapshots to ``MainActorSnapshotIngress/offer(_:revision:)`` and select a
`MainActor` callback that applies them to the presentation. Capture the
presentation weakly if the bridge belongs to a separate observation lifetime.
The bridge holds one newest pending snapshot, ignores older or duplicate
revisions, and bounds delivery work per turn. Call
``MainActorSnapshotIngress/cancel()`` and cancel the host subscription when
ending that observation lifetime. An already claimed callback may finish.
