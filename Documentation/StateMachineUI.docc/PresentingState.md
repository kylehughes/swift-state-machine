# Present state in a screen

Keep one complete snapshot observable and give its owner an explicit lifetime.

``ObservableStateMachinePresentation`` wraps a generated `MainActorHost` as an
`@Observable` model. It requires iOS 17, Mac Catalyst 17, macOS 14, tvOS 17,
watchOS 10, or visionOS 1. Pass the host to its initializer, read
``ObservableStateMachinePresentation/snapshot`` from a view, and call
``ObservableStateMachinePresentation/send(_:)`` from actions that act on the
current state:

```swift
import StateMachine
import StateMachineExamples
import StateMachineUI
import SwiftUI

@MainActor
func makePresentation() throws -> ObservableStateMachinePresentation<GeneratedProfile.MainActorHost> {
    let user = try UserID("taylor")
    let host = GeneratedProfile.MainActorHost(
        GeneratedProfile.Idle(userID: user),
        fetchDriver: { request in
            .success(Profile(userID: request.userID, name: "Taylor"))
        },
        auditDriver: { _ in .failure(.unavailable) }
    )
    return try ObservableStateMachinePresentation(host)
}

@MainActor
struct ProfileScreen: View {
    let presentation: ObservableStateMachinePresentation<GeneratedProfile.MainActorHost>
    let request: ProfileRequest
    @State private var inputFailure: String?

    var body: some View {
        VStack {
            switch presentation.snapshot {
            case .idle:
                Button("Load profile") { send(.load(request)) }
            case .loading:
                ProgressView("Loading profile")
                Button("Cancel", role: .cancel) { send(.cancel) }
            case .loaded(let loaded):
                Text(loaded.value.profile.name)
            case .failed(let failed):
                ContentUnavailableView {
                    Label("Profile Unavailable", systemImage: "person.slash")
                } description: {
                    Text(failed.value.failure.rawValue)
                } actions: {
                    Button("Retry") { send(.retry) }
                }
            }
            if let inputFailure { Text(inputFailure) }
        }
        .onDisappear { presentation.close() }
    }

    private func send(_ input: GeneratedProfile.Input) {
        do {
            try presentation.send(input)
            inputFailure = nil
        } catch {
            inputFailure = "Input was not accepted: \(error)"
        }
    }
}
```

Creating the presentation starts no request. Keep it for the screen's lifetime,
for example in `@State` or in the model that owns the feature, and
create a new one when returning after `close()`. This example ends that
lifetime in `onDisappear`; an application that keeps work alive across
navigation should put ownership in the longer-lived feature instead.

``StateMachinePresentation`` is the `ObservableObject` counterpart for the
iOS 16 and macOS 13 baseline. It has the same initializer and members, and a
view holds it with `@StateObject` or `@ObservedObject`.

The `ProfileEditor` example in `StateMachineExamples` wraps a
``StateMachinePresentation`` in a screen-scoped object with named actions such as `load()`, `retry()`, and
`cancel()`.

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
route, an edge or router that declines the input, or an invalid or oversized
effect plan. The `.commit` case means the owner refused the prepared change, for
example because it is closed.

## Act on the snapshot a view rendered

`send(_:)` routes an input against whatever the host currently holds. Use it for an
event that should act on the current state: a push notification, a timer, or a
tap that means "cancel the current load".

Each case of the snapshot holds an `Observed<Phase>`, whose edge methods exist
only for edges whose source is that phase. Calling one prepares a proposal.
`commit(_:)` on the presentation admits the proposal only if that observation is
still the owner's current revision, shows the resulting snapshot before it
returns, as `send(_:)` does, and returns a `CommitResult`: `.committed(receipt)`
or `.rejected(reason, current:)`. The result is not discardable.

Use `commit` when the action belongs to the exact observation the user saw, and
handle `.conflict`, which an unrelated intervening revision causes; a closed
owner reports `.closed` instead. The call is compile-checked: if an edge is
removed or moved to another phase, the view that calls it stops compiling,
whereas `send(_:)` routes a declared input at run time. It reports
`.preparation(.invalidPhase)` if the current phase has no edge or router for
that input.

```swift
@MainActor
struct ProfileActions: View {
    let presentation: ObservableStateMachinePresentation<GeneratedProfile.MainActorHost>
    @State private var notice: String?

    var body: some View {
        VStack {
            switch presentation.snapshot {
            case .loading(let loading):
                Button("Cancel", role: .cancel) { commit { try loading.cancel() } }
            case .failed(let failed):
                Button("Retry") { commit { try failed.retry() } }
            case .idle, .loaded:
                EmptyView()
            }
            if let notice { Text(notice) }
        }
    }

    private func commit(_ prepare: () throws -> GeneratedProfile.Prepared) {
        do {
            switch presentation.commit(try prepare()) {
            case .committed:
                notice = nil
            case .rejected(.conflict, _):
                notice = "The profile changed. Try again."
            case .rejected(let reason, _):
                notice = "The change was not accepted: \(reason)"
            }
        } catch {
            notice = "The change is not available: \(error)"
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

One presentation belongs to one owner history. A restored or forked owner starts
at revision zero, so create a new presentation for it rather than feeding those
revisions into the original presentation's watermark.

## Separate observation from running work

``StateMachinePresentation/stopObserving()`` removes only the registration and
leaves the owner open. ``StateMachinePresentation/close()`` stops observing,
closes the owner's work authority, and publishes its terminal snapshot. Closed
historical loading data cannot authorize another request.

Cancellation is cooperative. A driver can continue running after the screen
disappears, and its handle remains tracked until actual termination. Await the
host's `shutdown()` through ``StateMachinePresentation/host`` when the
surrounding task needs that termination and delivery cleanup to finish. A driver
that never returns can prevent the wait from finishing; `close()` itself is
synchronous.

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
import StateMachine
import StateMachineExamples
import UIKit

@MainActor
final class ProfileViewController: UIViewController {
    private let host: GeneratedProfile.MainActorHost
    private var observation: Task<Void, Never>?
    private let nameLabel = UILabel()

    init(host: GeneratedProfile.MainActorHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    private func render(_ snapshot: GeneratedProfile.Snapshot) {
        switch snapshot {
        case .idle:
            nameLabel.text = nil
            contentUnavailableConfiguration = nil
        case .loading:
            nameLabel.text = nil
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .loaded(let loaded):
            nameLabel.text = loaded.value.profile.name
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

In a `shared` schema the sequence is a `Snapshots` value. It works with `map`,
`prefix`, and generic `AsyncSequence` code on every supported OS, and a
`for await` loop over it runs on the caller's actor.

In an `isolated` schema the sequence is a `MainActorSnapshots` value, iterated
on the main actor because its snapshots are not `Sendable`. Using `for await`
works on every supported OS. Operators need a deployment target of iOS 18,
macOS 15, tvOS 18, watchOS 11, or visionOS 2. For an earlier target, pass a
closure that projects each snapshot to a `Sendable` value, as in
`host.snapshots({ $0.revision })`. The closure runs on the main actor and the
result is an ordinary sequence of the projected values.

For Combine, `$snapshot` on a ``StateMachinePresentation`` is the publisher.
It does not complete; `$isObserving` becoming `false` signals the end:

```swift
import Combine

@MainActor
func bind(
    _ presentation: StateMachinePresentation<GeneratedProfile.MainActorHost>,
    to render: @escaping @MainActor (GeneratedProfile.Snapshot) -> Void
) -> AnyCancellable {
    presentation.$snapshot.sink { render($0) }
}
```

Retain the returned `AnyCancellable` for as long as the view observes.

## Present an owner without a hosting protocol

``ObservableSnapshotPresentation`` and its `ObservableObject` counterpart
``SnapshotPresentation`` present snapshots of any type. For a generated
snapshot, create it from the owner's current snapshot. For another type, also
pass a closure that reads a snapshot's revision. Register an owner's
subscription with `observe(_:)`, or apply snapshots
yourself. Use it for owners that do not conform to
`MainActorStateMachineHost`. ``SnapshotPresentation/apply(_:)`` accepts
strictly increasing revisions, and ``SnapshotPresentation/stopObserving()``
removes only the registration.

## Bridge a shared or actor host

A `Shared` or `ActorHost` owner is not confined to `MainActor`. Create an
``ObservableSnapshotPresentation`` from its current snapshot, as in
`ObservableSnapshotPresentation(machine.snapshot())`, and follow the owner's
snapshot sequence from the view's task. The presentation applies each snapshot
on `MainActor` through the revision check:

```swift
import StateMachine
import StateMachineExamples
import StateMachineUI
import SwiftUI

@MainActor
struct ProfileName: View {
    let machine: GeneratedProfile.Shared
    let profile: ObservableSnapshotPresentation<GeneratedProfile.Snapshot>

    var body: some View {
        Group {
            if case .loaded(let loaded) = profile.snapshot {
                Text(loaded.value.profile.name)
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

``ObservableSnapshotPresentation/follow(_:)`` returns when the sequence ends,
the calling task is cancelled, or the presentation stops or replaces the
observation. SwiftUI cancels the view's task when the view disappears.
``SnapshotPresentation`` has the same members at the iOS 16 baseline, and
`observe(_:)` starts the observation in a task the presentation owns:

```swift
@MainActor
func present(
    _ shared: GeneratedProfile.Shared
) throws -> SnapshotPresentation<GeneratedProfile.Snapshot> {
    let presentation = SnapshotPresentation(shared.snapshot())
    presentation.observe(try shared.snapshots())
    return presentation
}
```

Creating the sequence throws `SubscriptionFailure` when subscriber capacity is
exhausted. For an `ActorHost`, use `try await actor.snapshots()`. The snapshot
sequence keeps only the latest pending snapshot, and
``SnapshotPresentation/isObserving`` becomes `false` when the sequence ends,
after the owner closes or is released. ``SnapshotPresentation/snapshot`` keeps
the last value applied. ``SnapshotPresentation/stopObserving()`` ends the
observation, and `$snapshot` is the Combine publisher. Observation coalesces
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
