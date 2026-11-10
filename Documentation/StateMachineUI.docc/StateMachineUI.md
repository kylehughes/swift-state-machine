# ``StateMachineUI``

Present complete state snapshots on `MainActor` with an iOS 16-compatible baseline.

``SnapshotPresentation`` exposes the latest snapshot through `ObservableObject`
and `@Published`. Applying an accepted receipt is synchronous, so a button's
input can update the screen in the same actor turn. Its revision guard prevents
delayed observations from replacing newer state.

The presentation owns an observation registration. The enclosing screen or
service owns the live machine and decides when its work scope ends. Removing
observation and closing work authority are separate operations.

Use ``MainActorSnapshotIngress`` when `Sendable` snapshots arrive from a shared
host outside `MainActor`. It retains only the newest pending snapshot and
schedules one responsible delivery task per active group of offers. Effect
commands stay with the host and never pass through this coalescing bridge.

## Topics

### Present a workflow

- <doc:PresentingState>
- ``SnapshotPresentation``

### Receive background snapshots

- ``MainActorSnapshotIngress``
