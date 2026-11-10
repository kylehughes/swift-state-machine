# ``StateMachineUI``

Present complete state snapshots on `MainActor` with an iOS 16-compatible baseline.

``StateMachinePresentation`` wraps a generated `MainActorHost` and exposes its
latest snapshot through `ObservableObject` and `@Published`. Sending an input
publishes the accepted snapshot in the same actor turn, so a button's input
updates the screen immediately. Snapshots that arrive later, such as an
operation's result, are published as the host delivers them. A revision guard
prevents delayed observations from replacing newer state.
``ObservableStateMachinePresentation`` offers the same members as an
`@Observable` class for apps that target iOS 17, macOS 14, or later.

The presentation owns an observation registration. The enclosing screen or
service owns the live machine and decides when its work scope ends. Removing
observation and closing work authority are separate operations.

``SnapshotPresentation`` is the lower-level piece for owners that do not conform
to `MainActorStateMachineHost`. Use ``MainActorSnapshotIngress`` when
`Sendable` snapshots arrive from a shared host outside `MainActor`. It retains
only the newest pending snapshot and schedules one responsible delivery task per
active group of offers. Effect commands stay with the host and never pass
through this coalescing bridge.

## Topics

### Present a workflow

- <doc:PresentingState>
- ``StateMachinePresentation``
- ``ObservableStateMachinePresentation``

### Present any snapshot

- ``SnapshotPresentation``

### Receive background snapshots

- ``MainActorSnapshotIngress``
