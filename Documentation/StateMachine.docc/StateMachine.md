# ``StateMachine``

Declare a typed graph of phases, own its transitions, and manage the asynchronous work they start.

State Machine models a workflow as a graph of phases and generates a typed Swift
API for it. Each phase holds its own data and exposes only the transitions
declared from it. `import StateMachine` is the only import a graph needs: the
macros that declare it, the generated owners' runtime types, and `Change` and
`Advance` all live in this module.

State Machine separates model data from the authority to change a workflow. A
consuming edge transfers ownership of its phase. A hosted edge prepares a
proposal from an observation; the host checks that observation again when it
commits the proposal. Constructing a model value does not grant either kind of
authority. Domain code decides whether a transition is valid and which inert
effects it describes. The runtime decides whether a hosted proposal, or the
result of work a transition started, still has authority to change the model.

Start with <doc:DeclaringAGraph>, which builds a graph one declaration at a
time. <doc:Ownership> explains the owners it generates, <doc:Persistence>
restores saved data into a graph, and <doc:TestingAGraph> tests each of them.
The raw runtime that generated owners rely on is advanced material at the end.

## Topics

### Declaring a graph

- <doc:DeclaringAGraph>

### The macros

- ``StateMachine(mode:)``
- ``Initial()``
- ``Transition(on:invalidates:starts:)``
- ``Transition(onSuccess:invalidates:starts:)``
- ``Transition(onFailure:invalidates:starts:)``
- ``Operation(scope:requires:activeIn:admission:)``
- ``Route(on:)``
- ``Route(onSuccess:)``
- ``Route(onFailure:)``
- ``Restoration(allows:)``
- ``StateMachineMode``
- ``StateMachineAdmission``

### Owners, edges, and observation

- <doc:Ownership>
- ``Change``
- ``Advance``
- ``PlanRejection``
- ``CommitRejection``
- ``StateMachineSnapshot``
- ``StateMachineReceipt``
- ``MainActorStateMachineHost``
- ``SnapshotSequence``
- ``MainActorSnapshotSequence``
- ``SnapshotSubscription``
- ``MainActorSnapshotSubscription``
- ``SubscriptionFailure``

### Limits, delivery, and shutdown

- ``Limits``
- ``ManagedConfiguration``
- ``PendingStatus``
- ``ShutdownDiagnostics``

### Restoring saved data

- <doc:Persistence>

### Testing a graph

- <doc:TestingAGraph>

### Worked examples

- <doc:Examples>

### Advanced: runtime construction

- <doc:RuntimeConstruction>
- ``RuntimeState``
- ``RuntimeOperation``
- ``RuntimeOperationPolicy``
- ``RuntimeScopeID``
- ``RuntimeIdentity``
- ``RuntimeWork``
- ``RuntimeTicket``
- ``RuntimeSharedHost``
- ``RuntimeMainActorHost``
- ``RuntimeActorHost``
- ``RuntimeDeliveryLedger``
- ``RuntimeDeliveryClaim``
- ``RuntimeCompletionPolicy``
- ``RuntimePendingID``
- ``RuntimeHostDelivery``

### Advanced: atomic records

- <doc:AtomicRecords>
- ``AtomicRecordStorage``
