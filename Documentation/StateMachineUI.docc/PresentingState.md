# Present state in a screen

Keep one complete snapshot observable and give its owner an explicit lifetime.

The `ProfileEditor` example in `StateMachineExamples` combines a generated
`MainActorHost` with ``SnapshotPresentation``. It owns its drivers and observation
registration. Creating it starts no request:

```swift
import StateMachineExamples
import StateMachineUI
import SwiftUI

@MainActor
func makeProfileEditor() throws -> ProfileEditor {
    let user = try UserID("taylor")
    return try ProfileEditor(
        request: ProfileRequest(userID: user),
        drivers: .init(
            fetch: { request in
                .success(Profile(userID: request.userID, name: "Taylor"))
            },
            audit: { _ in .failure(.unavailable) }
        )
    )
}

@MainActor
struct ProfileScreen: View {
    let editor: ProfileEditor
    @ObservedObject private var presentation: SnapshotPresentation<GeneratedProfile.Snapshot>
    @State private var inputFailure: String?

    init(editor: ProfileEditor) {
        self.editor = editor
        presentation = editor.presentation
    }

    var body: some View {
        VStack {
            switch presentation.snapshot {
            case .idle:
                Button("Load profile") { send { try editor.load() } }
            case .loading:
                ProgressView("Loading profile")
                Button("Cancel") { send { try editor.cancel() } }
            case .loaded(let loaded):
                Text(loaded.value.profile.name)
            case .failed(let failed):
                Text("Request failed: \(failed.value.failure.rawValue)")
                Button("Retry") { send { try editor.retry() } }
            }
            if let inputFailure { Text(inputFailure) }
        }
        .onDisappear { editor.dispose() }
    }

    private func send(_ action: () throws -> GeneratedProfile.CommitResult) {
        do {
            switch try action() {
            case .committed:
                inputFailure = nil
            case .rejected(let reason, _):
                inputFailure = "Input was not accepted: \(reason)"
            }
        } catch {
            inputFailure = "Input was rejected: \(error)"
        }
    }
}
```

Retain the editor for this screen's lifetime and construct a new one when
returning after disposal. This example ends that lifetime in `onDisappear`;
an application that keeps work alive across navigation should put ownership
in the longer-lived feature instead.

## Accept input and publish without suspension

`ProfileEditor.load()` synchronously sends the input and applies the accepted
receipt to its presentation. Driver work runs afterward. When a result returns,
the host checks its operation authority, prepares the completion from a fresh
snapshot, and checks that snapshot's revision at commit. Cancelling or changing
the account can revoke operation authority and make a late response stale.

Observe the complete `snapshot` instead of maintaining independently published
phase fields. ``SnapshotPresentation/apply(_:)`` accepts strictly increasing
ordinals. It can therefore apply an immediate receipt before asynchronous
observation reaches the same revision, without regressing when that delayed
observation arrives.

One presentation belongs to one owner history. A restored or forked owner starts
at ordinal zero, so create a new presentation for it rather than feeding those
revisions into the original presentation's watermark.

## Separate observation from running work

``SnapshotPresentation/stopObserving()`` removes only the registration.
`ProfileEditor.dispose()` also closes the screen's work authority and applies
its terminal snapshot. Closed historical loading data cannot authorize another
request.

Cancellation is cooperative. A driver can continue running after the screen
disappears, and its handle remains tracked until actual termination. Await
`ProfileEditor.shutdown()` when the surrounding task needs that termination
and delivery cleanup to finish. A driver that never returns can prevent the
wait from finishing; disposal itself is synchronous.

## Bridge a shared host

Shared-host callbacks may arrive outside `MainActor`. Pass their `Sendable`
snapshots to ``MainActorSnapshotIngress/offer(_:ordinal:)`` and select a
`MainActor` callback that applies them to the presentation. Capture the
presentation weakly if the bridge belongs to a separate observation lifetime.

The bridge holds one newest pending snapshot. It ignores older or duplicate
ordinals, bounds delivery work per turn, and does not allocate a new delivery
task for each offer. Call ``MainActorSnapshotIngress/cancel()`` and cancel the
host subscription when ending that observation lifetime. An already claimed
callback may finish. This bridge coalesces presentation data only; every
accepted effect remains the host's responsibility.
