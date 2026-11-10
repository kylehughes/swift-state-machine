# ``StateMachineExamples``

Explore typed profile loading, screen lifetimes, validated data, and consuming resources.

The examples expose ordinary model values alongside sealed ownership and
observation types. Use them to study the distinction between constructing data,
preparing a transition, accepting it, and executing its effects.

``ReferenceProfile`` models idle, loading, loaded, and failed phases. Its
requests contain a validated ``UserID`` and retry budget. A presentation edit
can preserve an active fetch, while authentication invalidation revokes the
fetch's dependency authority. A late result cannot regain that authority merely
because the visible request looks the same.

``GeneratedProfile`` declares that graph with the schema macro. ``ProfileEditor``
wraps a `StateMachinePresentation` over its `MainActor` host for synchronous
screen input and managed results. The presentation observes complete snapshots; disposal ends observation
and the screen's work authority, while shutdown also waits for driver termination.

``ResourceWorkflow`` carries a noncopyable resource through a consuming edge.
An empty label returns the original owner. Success returns the complete
successor and two ordered effect descriptions; neither description runs during
the transition. ``ValueWorkflow`` demonstrates the same preservation of effects
with ordinary value data.

``IsolatedNote`` uses `String` and array value storage in explicitly non-`Sendable`
payloads, with owned, manual local, and managed `MainActor` forms. ``GeneratedNote``
declares an isolated schema with non-`Sendable` input and result values. Both keep
those values within their permitted actor while preserving historical data.

## Topics

### Profile loading

- ``ReferenceProfile``
- ``GeneratedProfile``
- ``ProfileEditor``
- ``UserID``
- ``ProfileRequest``
- ``Profile``
- ``ProfileFailure``

### Validated persistence

- <doc:Persistence>
- ``ReferenceProfile/Archive``
- ``ReferenceProfile/RestoreRejection``

### Exclusive ownership

- ``ResourceWorkflow``
- ``ValueWorkflow``

### Isolated values

- ``IsolatedNote``
- ``GeneratedNote``
