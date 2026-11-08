# ``StateMachine``

Represent consuming transitions and install immutable shared records.

State Machine separates model data from the authority to change a workflow. A
consuming edge transfers ownership of its phase. A hosted edge prepares a
proposal from an observation; the host checks that observation again when it
commits the proposal. Constructing a model value does not grant either kind of
authority.

Use ``Change`` for a successful transition and its ordered, inert effects. Use
``Advance`` when a transition can reject its input and return the original
owner. ``PreparationFailure`` separates domain rejection from a permanently
invalid effect plan.

``AtomicRecordStorage`` provides the lower-level atomic record primitive used
by shared runtimes. It checks record identity, not legal domain transitions.
``RuntimeState`` supplies the value engine for admission, operation authority,
and whole FIFO batches. ``RuntimeDeliveryLedger`` retains terminal results and
grants one preparation claim at a time. ``RuntimeSharedHost`` combines those
algorithms with managed execution and observation. Domain facades keep their
host, storage, and provenance private.

``RuntimeMainActorHost`` and ``RuntimeActorHost`` provide managed execution
while confining the engine and ledger to one actor. The `MainActor` host also
supports non-`Sendable` copyable value data within that actor.

## Topics

### Ownership and preparation

- <doc:Ownership>
- ``Change``
- ``Advance``
- ``PreparationFailure``
- ``PlanRejection``

### Atomic records

- <doc:AtomicRecords>
- ``AtomicRecordStorage``

### Runtime construction

- <doc:RuntimeConstruction>
- ``RuntimeState``
- ``RuntimeLimits``
- ``RuntimeOperation``
- ``RuntimeOperationPolicy``
- ``RuntimeScopeID``
- ``RuntimeIdentity``
- ``RuntimeWork``
- ``RuntimeTicket``

### Managed delivery

- ``RuntimeSharedHost``
- ``RuntimeMainActorHost``
- ``RuntimeActorHost``
- ``RuntimeManagedConfiguration``
- ``RuntimeDeliveryLedger``
- ``RuntimeCompletionPolicy``
- ``RuntimePendingID``
- ``RuntimePendingStatus``
- ``RuntimeSubscription``
