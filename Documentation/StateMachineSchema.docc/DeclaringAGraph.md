# Declaring a graph

Keep each phase's data distinct and declare the edges a caller may take.

A schema is a `nonisolated enum` marked with `@StateMachine(mode:)`. Its cases
are phases, and each carries one distinct nested payload type. This graph has
one legal transition, from a draft to an approved value:

```swift
import StateMachine
import StateMachineSchema

@StateMachine(mode: .shared)
nonisolated enum Approval: Sendable {
    struct Draft: Sendable { let title: String }
    struct Approved: Sendable { let title: String }

    @Initial case draft(Draft)
    case approved(Approved)

    enum Input: Sendable { case approve }

    @Transition(on: Input.approve)
    fileprivate static func approve(_ source: Draft) -> Approved {
        Approved(title: source.title)
    }
}

func approveDraft() {
    let approved = Approval.owned(.init(title: "Launch checklist")).approve()
    print(approved.withValue { $0.title })
}
```

The generated `Owned<Draft>` exposes `approve`; `Owned<Approved>` does not.
Calling the edge consumes the draft owner and returns `Owned<Approved>`. An edge
that starts nothing returns its destination payload directly, and the macro
derives the edge's endpoints from its signature: `approve` takes a `Draft` and
returns an `Approved`, so it leads from the `draft` phase to the `approved`
phase. Its trigger, `Input.approve`, is an ordinary reference that the compiler
resolves, so a misspelled case fails to compile at the attribute.

The plain `Draft` and `Approved` values remain ordinary data. Constructing an
`Approved` does not construct an `Owned<Approved>`.

## Name each declaration

| To declare | Write |
| --- | --- |
| The ownership contract | `@StateMachine(mode: .shared)`, `.isolated`, or `.ownedOnly` on a `nonisolated enum` |
| A phase | A `case` with one payload type declared inside the schema |
| The initial phase | `@Initial` on exactly one `case` |
| An input | A case of the nested `enum Input` |
| An edge that starts nothing | `@Transition(on: Input.approve)` on a function returning the destination payload |
| An edge that starts operations | `@Transition(on: Input.begin, starts: [Fetch.self])` on a function returning `Change<Destination, Effect.Begin>` |
| A scope | A case of the nested `enum Scope`, referenced as `Scope.search` |
| Authority an edge revokes | `invalidates: [Scope.search]` |
| An operation | `@Operation(scope:requires:activeIn:admission:)` on an enum with `Input`, `Output`, and `Failure` aliases |
| A completion edge | `@Transition(onSuccess: Fetch.self)` or `@Transition(onFailure: Fetch.self)` |
| Several edges for one source and trigger | `@Route(on:)`, `@Route(onSuccess:)`, or `@Route(onFailure:)` on a selector function |

Write each reference exactly as shown. The macro reads the spelling, so it
rejects qualified and computed forms.

## Start an operation

An operation is work the host runs and whose result returns through a
completion edge. This schema starts a search and handles its result:

```swift
@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Searching: Sendable { let query: String }
    struct Found: Sendable { let answer: String }

    @Initial case idle(Idle)
    case searching(Searching)
    case found(Found)

    enum Scope { case search }
    enum Input: Sendable { case search(String), cancel }

    @Operation(scope: Scope.search, activeIn: [Searching.self], admission: .latest)
    enum Fetch {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }

    @Transition(on: Input.search, invalidates: [Scope.search], starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.fetch(query)])
    }

    @Transition(on: Input.cancel, invalidates: [Scope.search])
    fileprivate static func cancel(_ source: Searching) -> Idle { Idle() }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Searching, _ answer: Fetch.Output) -> Found {
        Found(answer: answer)
    }
}
```

The operation namespace declares exactly three aliases: `Input` (what the work
receives), `Output`, and `Failure`. Its `scope` is the authority it holds,
`requires` lists dependency scopes, `activeIn` lists the phases where it may
run, and `admission` is `.latest`, `.rejectWhenActive`, or `.parallel(limit:)`.
Work receives the post-commit activation of every scope it holds. Invalidating
any of them revokes the work, even if the visible phase stays the same. Here,
`cancel` invalidates `Scope.search`, so a result that returns afterward is stale.

The macro generates the `Effect` type. It has one case per operation, named by
lower-casing the leading capital run of the namespace name, so `Fetch` becomes
`.fetch`. Each edge that lists `starts:` also gets its own effect type named
after the function, so `begin` has `Effect.Begin`. That type contains only the
listed operations, and returning an effect outside `starts:` does not compile.
Two edges with the same `starts:` have distinct effect types.

Each operation needs a success edge or router in every `activeIn` phase, and a
failure edge or router unless `Failure` is `Never`. A completion edge may also
list `starts:` to chain a successor operation.

An edge may use typed `throws(Failure)` to reject its input. The failure becomes
a case of the generated `PreparationRejection`, named after the edge, such as
`.begin(.wrongUser)`.

## Host the graph

Each schema mode generates the owners it supports:

| Generated owner | Available modes | Execution ownership |
| --- | --- | --- |
| `MainActorHost` | `shared`, `isolated` | `MainActor` owns state and manages work. |
| `ActorHost` | `shared` | A native actor owns state and manages work. |
| `Shared` | `shared` | A shared runtime manages work and synchronous admission. |
| `Local` | `shared`, `isolated` | Caller drains batches and acknowledges each execution. |
| `Owned<Phase>` | All | Caller executes the returned inert effects. |

In `shared` mode, phase data, inputs, effects, and operation outcomes must meet
checked `Sendable` requirements as well as the domain's value-semantics
contract. In `isolated` mode, copyable data can remain within its permitted
actor without becoming `Sendable`. In `ownedOnly` mode, phase payloads may be
noncopyable resources; they do not receive copyable snapshots or shared
storage.

A managed owner takes a driver for each operation when it is created. A driver
returns `Result<Output, Failure>`:

```swift
@MainActor
func search() async throws {
    let host = Lookup.MainActorHost(
        .init(),
        drivers: .init(fetch: { query in .success("Results for \(query)") })
    )

    let receipt = try host.send(.search("swift"))
    print("Accepted revision \(receipt.revision)")

    await host.shutdown()
}
```

Every hosted owner has `send(_:) throws(SendRejection) -> Receipt`. It routes,
prepares, and admits the input, and a rejection is one of two cases:
`.preparation(PreparationRejection)` when the input has no edge from the current
phase (`invalidPhase`) or the edge declined it, and `.commit(CommitRejection)`
when the owner refused the prepared change. `Shared.send` makes exactly one
attempt and is the only owner where `.commit(.conflict)` can occur. The
`MainActorHost` and `ActorHost` read, prepare, and admit in one isolated turn.

The receipt carries the accepted `revision` and the complete `Snapshot`. A
snapshot has one case per phase, holding an `Observed<Phase>` whose `value` is
the payload. `Observed<Phase>` also has the edge methods, returning a `Prepared`
proposal that `commit(_:)` consumes and checks against the owner and its current
revision. Use that explicit path when a caller needs to separate preparation
from admission. A rejected commit changes neither model data nor operation
authority.

Each hosted owner except `Local` also offers `snapshots()`, which registers an
observer and returns a single-pass asynchronous sequence of complete snapshots.
Creating it throws `SubscriptionFailure` when subscriber capacity is exhausted;
iterating never throws. `ActorHost.snapshots()` is `async`.

```swift
@MainActor
func watch(_ host: Lookup.MainActorHost) async throws {
    for await snapshot in try host.snapshots() {
        print(snapshot.revision)
    }
}
```

To show a hosted graph in SwiftUI, wrap a `MainActorHost` in
`StateMachinePresentation`, described in the `StateMachineUI` documentation.

The runtime types behind the generated owners are available through aliases
inside the schema: `Subscription`, `MainActorSubscription`,
`SubscriptionFailure`, `MainActorSnapshots`, `Snapshots`, `CompletionPolicy`,
`PendingStatus`, `Configuration`, and `LocalConfiguration`. `Snapshots` exists in
`shared` mode only.

Actor isolation does not prevent two snapshots from sharing a mutable reference.
Use value storage, immutable objects, or detached projections when a graph
promises historical observations. The macro cannot establish business validity,
deep value semantics, or the purity of arbitrary function bodies.

## Choose among edges with a router

When several edges share a source and trigger, a router selects among them. It
is a function marked `@Route` that receives the plain source payload and trigger
payload, and returns a generated enum with one case per candidate edge:

```swift
@StateMachine(mode: .shared)
nonisolated enum Session: Sendable {
    struct Active: Sendable { let name: String }
    struct Ended: Sendable { let name: String }

    @Initial case active(Active)
    case ended(Ended)

    enum Input: Sendable { case refresh(Bool) }

    @Transition(on: Input.refresh)
    fileprivate static func keep(_ source: Active, _ finish: Bool) -> Active { source }

    @Transition(on: Input.refresh)
    fileprivate static func end(_ source: Active, _ finish: Bool) -> Ended {
        Ended(name: source.name)
    }

    @Route(on: Input.refresh)
    fileprivate static func choose(_ source: Active, _ finish: Bool) -> Route.Choose {
        finish ? .end : .keep
    }
}
```

`Route.Choose` has the cases `.keep` and `.end`, one per candidate edge. A
router may use typed throws to decline, and the failure becomes a
`PreparationRejection` case named after the router. A router with no candidate
edge returns `Never` and must throw. A completion router, declared with
`@Route(onSuccess:)` or `@Route(onFailure:)`, must select a terminal edge for
that same operation. Terminal phases and unused edges are legal. Restoration can
enter a phase that is not reachable from the initial factory.

## Handle fallible edges

An edge may use typed `throws(Failure)`. The generated `Owned` edge returns an
`Advance` that gives back the original owner on rejection, and hosted
preparation reports the failure as a `PreparationRejection` case.

An `ownedOnly` edge consumes its source with `consuming`. If it can fail, it
returns `Advance<Source, Destination, Effect, Failure>`, where the effect
argument is `Never` or `Effect.<Edge>`, so a rejection can return the original
resource. An infallible `ownedOnly` edge returns the destination or a `Change`.
A consuming function that throws after losing its predecessor cannot provide
that recovery contract.

Inputs have zero or one unlabeled payload. Every phase case has one unlabeled
payload, whose distinct struct or enum is declared directly inside the schema.
Fields can use imported types and nested generic containers. Phase aliases,
reusing a payload type for several phases, generic schema or phase payload
declarations, async edges, untyped throws, `inout` sources, and generic edge
functions are unsupported. Keep declarations inside the schema; the macro does
not discover extensions or scan other files.

Generated member names and the support types used by expansion are reserved.
For example, a value graph cannot name a phase case `model`, `record`,
`revision`, or `isClosed`, because its snapshot already uses those members.
Diagnostics identify the conflicting declaration and ask for a distinct name.

## Run effects with `Local` and `Owned`

`Local` and `Owned` leave execution to the caller. `Local` is a noncopyable
value with no automatic runner or observation subscription. Its caller drains
whole batches after acceptance, then releases mutating access before executing
any work. This synchronous example sends the input, prints the message, seals
that execution's result, and acknowledges that the print has finished:

```swift
@StateMachine(mode: .shared)
nonisolated enum MessageFlow: Sendable {
    struct Ready: Sendable { let message: String }
    struct Sent: Sendable { let message: String }
    @Initial case ready(Ready)
    case sent(Sent)

    enum Scope { case publication }
    enum Input: Sendable { case send }

    @Operation(scope: Scope.publication, activeIn: [Ready.self], admission: .latest)
    enum Publication {
        typealias Input = String
        typealias Output = Void
        typealias Failure = Never
    }

    @Transition(on: Input.send, starts: [Publication.self])
    fileprivate static func send(_ source: Ready) -> Change<Ready, Effect.Send> {
        Change(source, effects: [.publication(source.message)])
    }

    @Transition(onSuccess: Publication.self)
    fileprivate static func published(_ source: Ready, _ output: Publication.Output) -> Sent {
        Sent(message: source.message)
    }
}

func publishLocally() throws {
    var machine = MessageFlow.Local(.init(message: "Approved"))
    try machine.send(.send)

    for batch in machine.drainCommands(limit: 8) {
        for command in batch.commands {
            switch command {
            case .publication(let work):
                print(work.input)
                let delivery = machine.deliver(work.succeeded())
                let acknowledgment = machine.acknowledgeExecution(work.execution, disposition: .terminated)
                print("Delivery: \(delivery); execution: \(acknowledgment)")
            case .cancel:
                // An asynchronous runner requests cancellation here and
                // acknowledges only after its task actually terminates.
                break
            }
        }
    }

    // Closure also produces a batch, even with no new work.
    _ = machine.close()
    _ = machine.drainCommands(limit: 8)
    print("Settled: \(machine.isQuiescent)")
}
```

Each owner's `deliver` accepts one operation's sealed completion directly.
`work.succeeded(value)` and `work.failed(value)` build it, and an operation
whose `Output` is `Void` has `succeeded()`. An ordinary output value cannot stand
in for that authority. Copying a valid completion permits repeated delivery
attempts, while successful terminal admission retires the operation at most
once.

Returning a completion and acknowledging termination are separate obligations.
`DeliveryResult` includes `.stale`, when the operation's authority is no longer
active or its outcome already settled, and `.foreignOwner`, when a different
owner issued the completion. `AcknowledgmentResult` is `.recorded`, `.duplicate`,
or `.foreignOwner`. An asynchronous runner must retain its execution handles
until the tasks terminate, and a cancellation request alone does not acknowledge
termination. A retained delivery may still need admission or explicit
reconciliation after execution has ended.

`Owned` runs nothing. An edge that starts nothing returns the next `Owned`
directly. An edge that starts operations returns a `Change` carrying the
schema-wide `Effect` values in authored order, and the caller decides when to
run them:

```swift
func ownedSearch() {
    let change = Lookup.owned(.init()).begin("swift")
    print(change.effects.count)

    let idle = change.next.cancel()
    idle.withValue { _ in }
}
```

`Owned<Searching>` offers `cancel()` and `received(_:)`, and `Owned<Idle>`
offers only `begin(_:)`. To compare effects in a test, declare
`extension Lookup.Effect: Equatable {}`.
