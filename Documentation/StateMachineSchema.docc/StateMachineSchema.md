# ``StateMachineSchema``

Declare a typed state graph and generate its ownership and admission APIs.

A schema keeps phase payloads, inputs, operations, and transitions in one enum.
The macro generates the effect types, phase-specific methods, and sealed
observations, proposals, and work values. Authored transition functions remain ordinary Swift
functions, so the compiler checks their payload types, ownership, errors, and
isolation.

Start with <doc:DeclaringAGraph>, and read <doc:TestingAGraph> to test a graph
once it is declared. Import `StateMachine` for `Change`, `Advance`,
and the generated owners' runtime types, and `StateMachineSchema` for the
declaration macros. Domain code decides whether
a transition is valid and which inert effects it describes. The runtime decides
whether a hosted proposal still has authority to commit.

## Topics

### Declare a graph

- <doc:DeclaringAGraph>
- ``StateMachine(mode:)``
- ``Initial()``
- ``Restoration()``
- ``StateMachineMode``

### Describe edges and operations

- ``Transition(on:invalidates:starts:)``
- ``Transition(onSuccess:invalidates:starts:)``
- ``Transition(onFailure:invalidates:starts:)``
- ``Operation(scope:requires:activeIn:admission:)``
- ``Route(on:)``
- ``Route(onSuccess:)``
- ``Route(onFailure:)``
- ``StateMachineAdmission``

### Test a graph

- <doc:TestingAGraph>
