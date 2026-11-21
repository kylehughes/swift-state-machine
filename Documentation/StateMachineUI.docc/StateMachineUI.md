# ``StateMachineUI``

Present complete state snapshots on `MainActor` with an iOS 16-compatible baseline.

``StateMachinePresentation`` wraps a generated `MainActorHost` as an
`@Observable` model and exposes its latest snapshot. Sending an input publishes
the accepted snapshot in the same actor turn, so a button's input updates the
screen immediately. Snapshots that arrive later, such as an operation's result,
are published as the host delivers them. A revision guard prevents delayed
observations from replacing newer state. It requires iOS 17, macOS 14, or a
matching release, where the generated host is itself `Observable` too.
``StateMachineObservableObject`` has the same driving operations as an
`ObservableObject`, for the iOS 16 and macOS 13 baseline, and publishes the
snapshots it shows to Combine through a ``PresentationPublisher``:
``StateMachineObservableObject/presentedSnapshots`` when the snapshot is
`Sendable`, and ``StateMachineObservableObject/presentedSnapshots(projecting:)``
for a `Sendable` projection of a snapshot confined to the main actor.

Creating a presentation never throws, so a view can initialize its `@State` with
`StateMachinePresentation(host)`. If the host has no room for another
observer, `isObserving` is `false` and `observationFailure` holds the reason,
while the presentation still shows the owner's snapshot and every change made
through it; ``StateMachinePresentation/resumeObserving()`` registers again once
a slot is free. An edge that cannot fail needs no `try`, so a view commits it as
`presentation.commit(loading.cancel())`.

The presentation owns an observation registration. The enclosing screen or
service owns the live machine and decides when its work scope ends. Removing
observation and closing work authority are separate operations.

``SnapshotPresentation`` presents an owner without driving it: a `Shared`
owner, an `ActorHost`, an `IsolatedHost`, or a `MainActorHost` that a view only
reads. `observe(_:)` binds it to a host of any kind, and `observe(_:)` or
`follow(_:)` with a `SnapshotSequence`, such as a `Shared` host's `snapshots()`
or any managed host's projection from `snapshots(_:)`, follows that sequence.
Each new observation shows its first snapshot at once and then applies each
newer one on `MainActor`, so a presentation can move from one owner to another,
and late deliveries from the previous one are discarded. ``SnapshotObservableObject``
has the same observation operations as an `ObservableObject`, and publishes what
it shows through the same two publishers.

Use ``MainActorSnapshotIngress`` as the lower-level bridge when `Sendable`
snapshots arrive from a host outside `MainActor` through a callback. It retains
only the newest pending snapshot and schedules one responsible delivery task per
active group of offers. Effect commands stay with the host and never pass
through this coalescing bridge.

## Topics

### Present a workflow

- <doc:PresentingState>
- ``StateMachinePresentation``
- ``StateMachineObservableObject``

### Present any snapshot or sequence

- ``SnapshotPresentation``
- ``SnapshotObservableObject``

### Publish to Combine

- ``PresentationPublisher``

### Receive background snapshots

- ``MainActorSnapshotIngress``
