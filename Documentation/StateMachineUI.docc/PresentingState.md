# Present state in a screen

Keep one complete snapshot observable and give its owner an explicit lifetime.

``StateMachinePresentation`` wraps a generated `MainActorHost`. It is an
`ObservableObject`, so it works at the iOS 16 baseline. Pass the host to its
initializer, read ``StateMachinePresentation/snapshot`` from a view, and call
``StateMachinePresentation/send(_:)`` from actions:

```swift
import StateMachine
import StateMachineExamples
import StateMachineUI
import SwiftUI

@MainActor
func makePresentation() throws -> StateMachinePresentation<GeneratedProfile.MainActorHost> {
    let user = try UserID("taylor")
    let host = GeneratedProfile.MainActorHost(
        .init(userID: user),
        drivers: .init(
            fetch: { request in
                .success(Profile(userID: request.userID, name: "Taylor"))
            },
            audit: { _ in .failure(.unavailable) }
        )
    )
    return try StateMachinePresentation(host)
}

@MainActor
struct ProfileScreen: View {
    @ObservedObject var presentation: StateMachinePresentation<GeneratedProfile.MainActorHost>
    let request: ProfileRequest
    @State private var inputFailure: String?

    var body: some View {
        VStack {
            switch presentation.snapshot {
            case .idle:
                Button("Load profile") { send(.load(request)) }
            case .loading:
                ProgressView("Loading profile")
                Button("Cancel") { send(.cancel) }
            case .loaded(let loaded):
                Text(loaded.value.profile.name)
            case .failed(let failed):
                Text("Request failed: \(failed.value.failure.rawValue)")
                Button("Retry") { send(.retry) }
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
for example in a `@StateObject` or in the object that owns the feature, and
create a new one when returning after `close()`. This example ends that
lifetime in `onDisappear`; an application that keeps work alive across
navigation should put ownership in the longer-lived feature instead.

``ObservableStateMachinePresentation`` is the `@Observable` counterpart for apps
that target iOS 17, macOS 14, or later. It has the same initializer and members,
and a view reads its `snapshot` without `@ObservedObject`.

The `ProfileEditor` example in `StateMachineExamples` wraps this pattern in a
screen-scoped object with named actions such as `load()`, `retry()`, and
`cancel()`.

## Accept input and publish without suspension

`send(_:)` routes, prepares, and admits the input in the current `MainActor`
turn, then publishes the accepted snapshot before it returns. Driver work runs
afterward. When a result returns, the host checks its operation authority,
prepares the completion from a fresh snapshot, and checks that snapshot's
revision at commit. Snapshots that arrive later, such as an operation's result,
reach the presentation through the host's subscription. Cancelling or changing
the account can revoke operation authority and make a late response stale.

`send(_:)` throws `SendRejection`. The `.preparation` case means the input has
no edge from the current phase or the edge declined it. The `.commit` case means
the owner refused the prepared change, for example because it is closed.

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

## Present an owner without a hosting protocol

``SnapshotPresentation`` is the lower-level piece. It publishes snapshots of any
type, given a closure that reads a snapshot's revision. Register an owner's
subscription with ``SnapshotPresentation/observe(_:)``, or apply snapshots
yourself. Use it for owners that do not conform to
`MainActorStateMachineHost`. ``SnapshotPresentation/apply(_:)`` accepts
strictly increasing revisions, and ``SnapshotPresentation/stopObserving()``
removes only the registration.

## Bridge a shared host

Shared-host callbacks may arrive outside `MainActor`. Pass their `Sendable`
snapshots to ``MainActorSnapshotIngress/offer(_:revision:)`` and select a
`MainActor` callback that applies them to the presentation. Capture the
presentation weakly if the bridge belongs to a separate observation lifetime.

The bridge holds one newest pending snapshot. It ignores older or duplicate
revisions, bounds delivery work per turn, and does not allocate a new delivery
task for each offer. Call ``MainActorSnapshotIngress/cancel()`` and cancel the
host subscription when ending that observation lifetime. An already claimed
callback may finish. This bridge coalesces presentation data only; every
accepted effect remains the host's responsibility.
