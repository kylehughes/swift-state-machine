# ``StateMachine``

Declare a typed graph of phases, own its transitions, and manage the asynchronous work they start.

State Machine models a workflow as a graph of phases and generates a typed Swift
API for it. Each phase holds its own data and exposes only the transitions
declared from it. A graph needs only `import StateMachine`, because the macros
that declare it, the generated owners' runtime types, and `Change` and `Advance`
all live in this module.

State Machine separates model data from the authority to change a workflow. A
consuming edge transfers ownership of its phase. A hosted edge prepares a
proposal from an observation, and the host checks that observation again when it
commits the proposal. Constructing a model value does not grant either kind of
authority. Domain code decides whether a transition is valid and which inert
effects it describes. The runtime decides whether a hosted proposal, or the
result of work a transition started, still has authority to change the model.

Start with <doc:DeclaringAGraph> to build a graph one declaration at a time and
learn the structural checks every graph passes. Next, read <doc:HostingAGraph>
to choose and drive an owner, <doc:ObservingState> to read snapshots as they
change, and <doc:RunningEffectsYourself> to execute `Owned` and `Local` work by
hand. <doc:Persistence> covers restoring saved data into a graph, and
<doc:TestingAGraph> walks through testing each part with the companion
`StateMachineTesting` library. The raw runtime that generated owners rely on
appears in the advanced topics at the end.

## Topics

### Essentials

- <doc:DeclaringAGraph>
- <doc:HostingAGraph>
- <doc:ObservingState>
- <doc:RunningEffectsYourself>
- <doc:Ownership>

### Declaring a graph

- ``StateMachine(mode:)``
- ``StateMachine(mode:owners:)``
- ``StateMachineMode``
- ``StateMachineOwner``
- ``Initial()``
- ``Terminal()``

### Declaring transitions

- ``PhaseSet(_:)``
- ``Transition(on:invalidates:starts:cancels:emits:)``
- ``Transition(from:on:invalidates:starts:cancels:emits:)-([~.Type],_,_,_,_,_)``
- ``Transition(from:on:invalidates:starts:cancels:emits:)-(~.Type,_,_,_,_,_)``
- ``Transition(onSuccess:invalidates:starts:cancels:emits:)``
- ``Transition(onFailure:invalidates:starts:cancels:emits:)``
- ``Transition(invalidates:starts:cancels:emits:)``
- ``Transition(from:invalidates:starts:cancels:emits:)-([~.Type],_,_,_,_)``
- ``Transition(from:invalidates:starts:cancels:emits:)-(~.Type,_,_,_,_)``
- ``Route(on:)``
- ``Route(on:failure:)``
- ``Route(onSuccess:)``
- ``Route(onFailure:)``
- ``Change``
- ``Advance``

### Declaring operations, scopes, and events

- ``Operation(requires:activeIn:admission:)``
- ``Operation(scope:requires:admission:)``
- ``StateMachineAdmission``
- ``Active(in:)``
- ``Event()``

### Exporting a graph

- <doc:ExportingAGraph>
- ``StateMachineGraph``

### Admitting changes

- ``PlanRejection``
- ``CommitRejection``
- ``StateMachineSnapshot``
- ``StateMachineReceipt``

### Observing owners

- ``ObservableMainActorHost``
- ``SnapshotSequence``
- ``MainActorSnapshotSequence``
- ``IsolatedSnapshotSequence``
- ``SnapshotPublisher``
- ``SnapshotSubscription``
- ``MainActorSnapshotSubscription``
- ``IsolatedSnapshotSubscription``
- ``SubscriptionFailure``

### Executing work and settling delivery

- ``OperationRequest``
- ``KeyedOperationRequest``
- ``ExecutionDisposition``
- ``AcknowledgmentResult``
- ``PendingStatus``
- ``FlushResult``
- ``ShutdownDiagnostics``

### Bounding capacity

- ``Limits``
- ``ManagedConfiguration``

### Owner protocols

- ``MainActorStateMachineHost``
- ``SharedStateMachineHost``
- ``ActorStateMachineHost``
- ``IsolatedStateMachineHost``
- ``LocalStateMachine``
- ``DrainingLocalStateMachine``
- ``DeliveringLocalStateMachine``
- ``DefaultingLocalStateMachine``
- ``RestoringLocalStateMachine``
- ``LocalCommandBatch``

### Restoring saved data

- <doc:Persistence>
- ``Restoration(allows:)``
- ``Restoration(only:)``

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
- ``RuntimeKey``
- ``RuntimeIdentity``
- ``RuntimeWork``
- ``RuntimeTicket``
- ``RuntimeSharedHost``
- ``RuntimeMainActorHost``
- ``RuntimeActorHost``
- ``RuntimeIsolatedHost``
- ``RuntimeDeliveryLedger``
- ``RuntimeDeliveryClaim``
- ``RuntimeCompletionPolicy``
- ``RuntimePendingID``
- ``RuntimeHostDelivery``

### Advanced: atomic records

- <doc:AtomicRecords>
- ``AtomicRecordStorage``
