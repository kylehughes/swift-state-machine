# Declaring a graph

Keep each phase's data distinct and declare the edges a caller may take.

This graph has one legal transition, from a draft to an approved value:

```swift
import StateMachine
import StateMachineSchema

@StateMachine(mode: .shared, initial: "draft")
nonisolated enum Approval: Sendable {
    struct Draft: Sendable { let title: String }
    struct Approved: Sendable { let title: String }

    case draft(Draft)
    case approved(Approved)

    enum Input: Sendable { case approve }
    enum Effect: Sendable {}

    @Transition(from: "draft", to: "approved", on: .input("approve"))
    fileprivate static func approve(
        _ source: borrowing Draft
    ) -> Change<Approved, Effect> {
        Change(Approved(title: source.title))
    }
}

func approveDraft() {
    let draft = Approval.owned(.init(title: "Launch checklist"))
    let change = draft.approve()
    print(change.next.withValue { $0.title })
}
```

The generated `Owned<Draft>` exposes `approve`; `Owned<Approved>` does not.
Calling the edge consumes the draft owner and returns the complete successor
with its ordered effect descriptions. This graph has no effects to execute.
Its plain `Draft` and `Approved` values remain ordinary data. Constructing an
`Approved` does not construct an `Owned<Approved>`.

## Choose the ownership contract

Choose a mode explicitly. In `shared` mode, phase data, inputs, effects, and
operation outcomes must meet checked `Sendable` requirements as well as the
domain's value-semantics contract. In `isolated` mode, copyable data can remain
within its permitted actor without becoming `Sendable`. In `ownedOnly` mode,
phase payloads may be noncopyable resources; they do not receive copyable
snapshots or shared storage.

| Generated owner | Available modes | Execution ownership |
| --- | --- | --- |
| `Owned<Phase>` | All | Caller executes the returned inert effects. |
| `Local` | `shared`, `isolated` | Caller drains batches and acknowledges each execution. |
| `MainActorHost` | `shared`, `isolated` | `MainActor` owns state and manages work. |
| `ActorHost` | `shared` | A native actor owns state and manages work. |
| `Shared` | `shared` | A shared runtime manages work and synchronous admission. |

The confined hosts own the only mutation capability. Their synchronous `send`
operation reads, routes, prepares, and admits without suspension. Asynchronous
driver work may suspend, so its eventual result still needs current authority.
Supply immutable `MainActorDrivers` to a `MainActorHost`, and `Drivers` to an
`ActorHost` or `Shared`. A `Local` owner has no automatic runner or observation
subscription.

Actor isolation does not prevent two snapshots from sharing a mutable reference.
Use value storage, immutable objects, or detached projections when a graph
promises historical observations. The macro cannot establish business validity,
deep value semantics, or the purity of arbitrary function bodies.

## Describe transitions with ordinary functions

For a copyable value graph, an edge borrows its source and returns
`Change<Destination, Effect>`. It can use typed throws for domain rejection.
The generated owned edge preserves the predecessor on recoverable failure;
hosted preparation separates that domain failure from an invalid effect plan.

An `ownedOnly` edge instead consumes its source and returns
`Advance<Source, Destination, Effect, Failure>`. On rejection, the authored
function must return the original resource. A consuming function that throws
after losing its predecessor cannot provide that recovery contract.

Inputs have zero or one unlabeled payload. Every phase case has one unlabeled
payload, whose distinct struct or enum is declared directly inside the schema.
Fields can use imported types and nested generic containers. Phase aliases,
reusing a payload type for several phases, generic schema or phase payload
declarations, async edges, untyped throws, `inout` sources, and generic edge
functions are unsupported.
Keep declarations inside the schema; the macro does not discover extensions or
scan other files.

Generated member names and the support types used by expansion are reserved.
For example, a value graph cannot name a phase case `model`, `record`,
`ordinal`, or `isClosed`, because its snapshot already uses those members.
Diagnostics identify the conflicting declaration and ask for a distinct name.

## Prepare a hosted transition

A historical observation exposes only its phase's preparation methods:

```swift
func approveLocally() throws {
    var machine = Approval.Local(.init(title: "Launch checklist"))
    guard case .draft(let draft) = machine.snapshot() else { return }

    let proposal = try draft.approve()
    switch machine.commit(consume proposal) {
    case .committed(let receipt):
        print("Accepted revision \(receipt.ordinal)")
    case .rejected(let reason, _):
        print("Approval was rejected: \(reason)")
    }

    let batches = machine.drainCommands(limit: 1)
    print("Drained \(batches.count) accepted batch")
}
```

Preparation executes no effects. Commit consumes the proposal and checks its
hidden owner, incarnation (which changes on reset), and complete root revision.
A rejected commit changes neither model data nor operation authority. Dynamic
input routing through `Approval.prepare(_:on:)` reports `invalidPhase` when the
current phase has no matching edge.

`Local` is a noncopyable value. Its caller drains whole batches after acceptance,
then releases mutating access before executing any work. For graphs with effects,
the caller returns a sealed completion and separately acknowledges actual
execution termination or a definite skip before start. A cancellation request
alone does not acknowledge termination.

## Declare effects and branching

Each effect case binds to one `Operation` namespace with explicit `Input`,
`Output`, and `Failure` aliases. The operation declares its primary scope,
dependency scopes, eligible phases, and admission policy. Work receives the
post-commit activation identities of all those scopes. Invalidating any bound
scope revokes that work, even if the visible phase remains the same.

For example, this graph publishes a message and enters its final phase when
publication succeeds:

```swift
@StateMachine(mode: .shared, initial: "ready", scopes: ["publication"])
nonisolated enum MessageFlow: Sendable {
    struct Ready: Sendable { let message: String }
    struct Sent: Sendable { let message: String }
    case ready(Ready)
    case sent(Sent)

    enum Input: Sendable { case send }
    enum Effect: Sendable { case publish(Publication.Input) }

    @Operation(effect: "publish", scope: "publication", activeIn: ["ready"], admission: .latest)
    enum Publication {
        typealias Input = String
        typealias Output = Void
        typealias Failure = Never
    }

    @Transition(from: "ready", to: "ready", on: .input("send"), starts: ["publish"])
    fileprivate static func send(_ source: borrowing Ready) -> Change<Ready, Effect> {
        Change(Ready(message: source.message), effects: [.publish(source.message)])
    }

    @Transition(from: "ready", to: "sent", on: .success("publish"))
    fileprivate static func published(_ source: borrowing Ready, _ output: Publication.Output) -> Change<Sent, Effect> {
        Change(Sent(message: source.message))
    }
}
```

The trigger names the effect case, `publish`, rather than its `Publication`
namespace. Each operation needs a success edge or router in every eligible
phase, and a failure edge or router when its failure type is not `Never`.
These declarations also apply when you use only the generated owned API.

A transition's `starts` list permits effect kinds; it does not execute them or
guarantee that the function emits them. Preparation checks the actual returned
array and preserves its order. Commit checks authority, operation policy, and
capacity before publishing the model and its command batch together.
Preparation also rejects a batch that emits more new instances of one
operation than its declared policy allows, without constructing a proposal.

Hosted completion methods require the appropriate operation's sealed success
or failure value. An ordinary output value cannot stand in for that authority.
Copying a valid completion permits repeated delivery attempts, while successful
terminal admission retires the operation at most once.

With a `Local` owner, execute work only after draining an accepted batch. This
synchronous example prints the message, seals that execution's result, and
acknowledges that the print has finished:

```swift
func publishLocally() throws {
    var machine = MessageFlow.Local(.init(message: "Approved"))
    guard case .ready(let ready) = machine.snapshot() else { return }
    guard case .committed = machine.commit(try ready.send()) else { return }

    for batch in machine.drainCommands(limit: 8) {
        for command in batch.commands {
            switch command {
            case .publish(let work):
                print(work.input)
                let delivery = machine.deliver(.publish(work.succeeded(())))
                let acknowledgment = machine.acknowledgeExecution(work.execution, disposition: .terminated)
                print("Delivery: \(delivery); execution: \(acknowledgment)")
            case .cancel:
                // An asynchronous runner requests cancellation here and
                // acknowledges only after its task actually terminates.
                break
            }
        }
    }

    // Completion and closure also produce batches, even with no new work.
    _ = machine.close()
    _ = machine.drainCommands(limit: 8)
    print("Settled: \(machine.isQuiescent)")
}
```

This graph's printing operation is synchronous and cannot fail. An asynchronous
runner must retain its execution handles until the tasks terminate. Returning a
completion and acknowledging termination are separate obligations; a retained
delivery may still need admission or explicit reconciliation after execution
has ended.

When several edges share a source and trigger, declare an explicit `Route` to
select among them. A router returns a prepared transition or a typed rejection;
returning a plain destination value cannot authorize installation. A completion
router must select a terminal edge for that same operation. Returning an input
edge or another operation's edge is an invalid plan, and leaves the retained
outcome available for reconciliation. Terminal phases and unused edges are
legal. Restoration can enter a phase that is not reachable from the initial
factory.
