# ``StateMachineUI``

Present complete state snapshots on `MainActor` with an iOS 16-compatible baseline.

``StateMachinePresentation`` wraps a generated `MainActorHost` as an
`@Observable` model and exposes its latest snapshot. Sending an input publishes
the accepted snapshot in the same actor turn, so a button's input updates the
screen immediately. Snapshots that arrive later, such as an operation's result,
are published as the host delivers them. A revision guard prevents delayed
observations from replacing newer state. It requires iOS 17, macOS 14, or a
matching release. ``StateMachineObservableObject`` has the same members as an
`ObservableObject` with `@Published` properties, for the iOS 16 and macOS 13
baseline.

Creating a presentation never throws, so a view can initialize its `@State` with
`StateMachinePresentation(host)`. If the host has no room for another
observer, `isObserving` is `false` and `observationFailure` holds the reason,
while the presentation still shows the owner's snapshot and every change made
through it. An edge that cannot fail needs no `try`, so a view commits it as
`presentation.commit(loading.cancel())`.

The presentation owns an observation registration. The enclosing screen or
service owns the live machine and decides when its work scope ends. Removing
observation and closing work authority are separate operations.

``SnapshotPresentation`` presents shared and actor owners, and any other owner
that does not conform to `MainActorStateMachineHost`. It observes the owner's
snapshot sequence and applies each snapshot on `MainActor`. Passing
`startingAt:` to `observe` or `follow` switches it to a different owner: it
shows that owner's snapshot at once and ignores late deliveries from the
previous one. ``SnapshotObservableObject`` has the same members as an
`ObservableObject`. Use ``MainActorSnapshotIngress`` as the lower-level bridge
when `Sendable` snapshots arrive from a host outside `MainActor` through a
callback. It retains only the newest pending snapshot and schedules one
responsible delivery task per active group of offers. Effect commands stay with
the host and never pass through this coalescing bridge.

## Topics

### Present a workflow

- <doc:PresentingState>
- ``StateMachinePresentation``
- ``StateMachineObservableObject``

### Present any snapshot or sequence

- ``SnapshotPresentation``
- ``SnapshotObservableObject``

### Receive background snapshots

- ``MainActorSnapshotIngress``
