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
    let draft = Approval.Draft(title: "Launch checklist")
    let approved = Approval.owned(draft).approve()
    print(approved.withValue { $0.title })
}
```

`Approval.owned(_:)` takes the draft and creates an owner in the initial phase,
and `withValue` reads the payload an owner holds. The generated `Owned<Draft>`
exposes `approve`; `Owned<Approved>` does not.
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
| A default initial payload | A default on the initial case, as in `@Initial case idle(Idle = Idle())` |
| An input | A case of the nested `enum Input` |
| An edge that starts nothing | `@Transition(on: Input.approve)` on a function returning the destination payload |
| An edge that starts operations | `@Transition(on: Input.begin, starts: [Fetch.self])` on a function returning `Change<Destination, Effect.Begin>` |
| A scope | A case of the nested `enum Scope`, referenced as `Scope.search` |
| Authority an edge revokes without leaving the active phases | `invalidates: [Scope.search]` |
| An operation | `@Operation(scope:requires:activeIn:admission:)` on an enum with `Input`, `Output`, and `Failure` aliases |
| A completion edge | `@Transition(onSuccess: Fetch.self)` or `@Transition(onFailure: Fetch.self)` |
| Several edges for one source and trigger | `@Route(on:)`, `@Route(onSuccess:)`, or `@Route(onFailure:)` on a selector function |
| Validation of saved data | `@Restoration` on one function returning `Restoration` |

Write each reference in an attribute exactly as shown: `Input.approve`,
`Scope.search`, `Fetch.self`, and `.shared`. The macro reads the spelling, so it
rejects qualified forms such as `Lookup.Input.approve`, implicit members such as
`.approve`, and computed expressions. An attribute may include its module name,
as in `@StateMachineSchema.Transition`. A phase payload in an edge signature may
be written `Draft`, `Self.Draft`, or `Approval.Draft`. An operation can spell
its infallible `Failure` as `Never` or `Swift.Never`. An `Input` case can also
carry a type declared inside `Input`.

The `@Initial` case, and only that case, may give its payload a default. Every
fresh entry point then takes the initial payload as an optional argument:
`Local`, `Shared`, `ActorHost`, `MainActorHost`, and `owned(_:)`. An
`init(restoring:)` is unaffected, because saved data is always explicit. The
default is a call with no arguments. It either constructs the payload, as in
`Idle()`, or calls a static function of the schema that returns the payload, as
in `makeIdle()` or `Lookup.makeIdle()`. An owner created without the payload
evaluates the call once. The macro rejects any other expression, so to default
to something more involved, put the construction in a static function that
returns the payload and name that function. Swift checks the call itself: a
public schema needs a public initializer or function, and a payload whose
construction can throw or fail has no default. Declare one only when an empty
start is true to the domain. A payload that carries required data, such as a
user identifier, is passed explicitly.

## Start an operation

An operation is work the host runs and whose result returns through a
completion edge. This schema starts a search and handles its result:

```swift
@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Searching: Sendable { let query: String }
    struct Found: Sendable { let answer: String }

    @Initial case idle(Idle = Idle())
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

    @Transition(on: Input.search, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.fetch(query)])
    }

    @Transition(on: Input.cancel)
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
Work receives the post-commit activation of every scope it holds. An edge that
leaves the operation's `activeIn` phases revokes the work: here, `cancel` returns
to `Idle`, so a result that arrives afterward is stale. To revoke work while
staying in an active phase, list its scope in `invalidates:`, as in
`@Transition(on: Input.accountChanged, invalidates: [Scope.account])`.

The macro generates the `Effect` type. It has one case per operation, named in
lower camel case. For example, `Fetch` becomes `.fetch`, and `URLFetch` becomes
`.urlFetch`. Each edge that lists `starts:` also gets its own effect type named
after the function, so `begin` has `Effect.Begin`. That type contains only the
listed operations, and returning an effect outside `starts:` does not compile.
Two edges with the same `starts:` have distinct effect types.

Each operation needs a success edge or router in every `activeIn` phase, and a
failure edge or router unless `Failure` is `Never`. A completion edge may also
list `starts:` to chain a successor operation.

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

An `isolated` schema is declared the same way. The enum stays `nonisolated`, and
its payloads and inputs do not need to be `Sendable`; this example says so with
`~Sendable`. The owner confines the values, so a `MainActorHost` keeps them on
the main actor:

```swift
@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Draft: ~Sendable { let text: String }
    struct Saved: ~Sendable { let text: String }

    @Initial case draft(Draft)
    case saved(Saved)

    enum Input: ~Sendable { case save }

    @Transition(on: Input.save)
    fileprivate static func save(_ source: Draft) -> Saved { Saved(text: source.text) }
}

@MainActor
func saveNote() throws {
    let host = Note.MainActorHost(Note.Draft(text: "Outline"))
    try host.send(.save)
}
```

A managed owner takes a driver for each operation when it is created. A graph
with no operations takes no drivers, as `Note.MainActorHost` shows above. A
driver returns `Result<Output, Failure>`. Pass each driver as its own closure,
labelled with the operation's effect case followed by `Driver`, so `Fetch` takes
`fetchDriver:`. The closures follow the order the operations are declared, and
each is required. With the default that `Lookup` declares, the host also needs
no initial payload:

```swift
@MainActor
func search() async throws {
    let host = Lookup.MainActorHost(fetchDriver: { query in .success("Results for \(query)") })

    let receipt = try host.send(.search("swift"))
    print("Accepted revision \(receipt.revision)")

    await host.shutdown()
}
```

The same owner also takes a `Drivers` value through `drivers:`, or a
`MainActorDrivers` value for `MainActorHost`. Prefer the value when one set of
drivers serves several owners, when a test injects stubs, and when a graph has
many operations, where one value is easier to read and pass than a long list of
closures:

```swift
func makeOwners(drivers: Lookup.Drivers) -> (Lookup.Shared, Lookup.ActorHost) {
    (Lookup.Shared(drivers: drivers), Lookup.ActorHost(drivers: drivers))
}
```

Every owner except `Owned` routes, prepares, and attempts to admit an `Input`
through `send(_:)`. It returns a `Receipt` or throws `SendRejection`.
`ActorHost.send(_:)` is `async`, and `Local.send(_:)` is `mutating`.
`.preparation(PreparationRejection)` covers a missing route (`.invalidPhase`), a
router or edge that declines the input, or a rejected effect plan.
`.commit(CommitRejection)` means the owner refused the prepared change.
`Shared.send` makes exactly one attempt and is the only owner where a
concurrent write can cause `.commit(.conflict)`. The `MainActorHost` and `ActorHost` read,
prepare, and admit in one isolated turn.

The receipt carries the accepted `revision` and the complete `Snapshot`. A
snapshot has one case per phase, holding an `Observed<Phase>` whose `value` is
the payload. A `Snapshot` and a `Receipt` print the phase, the revision, and
`closed` when they record closure, as in `searching, revision 1`. An `Observed`
prints its payload type in place of the phase, as in `Searching, revision 1`.
None of them prints payload contents.

`MainActorHost`, `ActorHost`, and `Shared` also offer `snapshots()`, which
registers an observer and returns a single-pass asynchronous sequence of
complete snapshots. Creating it throws `SubscriptionFailure` when subscriber
capacity is exhausted; iterating never throws. `ActorHost.snapshots()` is
`async`.

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
`shared` mode and `MainActorSnapshots` in `isolated` mode.

Actor isolation does not prevent two snapshots from sharing a mutable reference.
Use value storage, immutable objects, or detached projections when a graph
promises historical observations. The macro cannot establish business validity,
deep value semantics, or the purity of arbitrary function bodies.

## Act on the observation a caller saw

`send(_:)` acts on whatever the owner currently holds. Use it for an event that
should apply to the current state: a tap that means "cancel the current
search", a push notification, or a timer.

`Observed<Phase>` also has one method for each edge whose source is that phase.
Each returns a `Prepared` proposal, which an owner's `commit(_:)` consumes and
admits only if that observation is still the owner's current revision. `commit`
returns a `CommitResult`, either `.committed(receipt)` or
`.rejected(reason, current:)`, and the result is not discardable. A rejected
commit changes neither model data nor operation authority. Every owner except
`Owned`, and both `StateMachinePresentation` and
`ObservableStateMachinePresentation` in `StateMachineUI`, have `commit(_:)`.
`ActorHost.commit(_:)` is `async`, and `Local.commit(_:)` is `mutating`. A
presentation shows the result in the same turn.

Use this path when the action belongs to the exact observation the user saw, and
handle `.conflict` if an intervening commit advances the same open owner.
Closing the owner takes precedence and produces `.closed`.

```swift
@MainActor
func cancel(_ searching: Lookup.Observed<Lookup.Searching>, on host: Lookup.MainActorHost) {
    do {
        switch host.commit(try searching.cancel()) {
        case .committed:
            print("Cancelled")
        case .rejected(.conflict, let current):
            print("The search changed first: \(current)")
        case .rejected(let reason, _):
            print("Cancel was not accepted: \(reason)")
        }
    } catch {
        print("Cancel could not be prepared: \(error)")
    }
}
```

The compiler checks the call. If `cancel` is removed from the schema or moves to
another phase, this function stops compiling, whereas `send(.cancel)` routes at
run time and fails with `.preparation(.invalidPhase)`. Preparing an edge from an
observation does not run a router, as the next section explains.

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
edge returns `Never` and must throw. If a completion router declared with
`@Route(onSuccess:)` or `@Route(onFailure:)` selects an edge, the edge must
match its source phase, operation, and success or failure trigger. Terminal
phases and unused edges are legal. Restoration can enter a phase unreachable
from the initial phase.

`send(_:)` and `prepare(_:on:)` use input routers. Completion delivery uses
success or failure routers. `send(.refresh(true))` goes through `choose`, which
selects `end`. An edge method on an observation, or on an `Owned` value, calls
that edge directly.

```swift
func keepActive(_ active: Session.Observed<Session.Active>) throws -> Session.Prepared {
    try active.keep(true)
}
```

Put a rule that every caller must obey in the edge or in a validated argument
type. Direct edge calls bypass rules that live only in a router.

## Handle fallible edges

An edge may use typed `throws(Failure)`. The generated `Owned` edge returns an
`Advance` that gives back the original owner on rejection, and hosted
preparation reports the failure as a `PreparationRejection` case named after the
edge:

```swift
@StateMachine(mode: .shared)
nonisolated enum Rename: Sendable {
    struct Draft: Sendable { let title: String }

    @Initial case draft(Draft)

    enum Input: Sendable { case rename(String) }
    enum RenameFailure: Error, Sendable { case empty }

    @Transition(on: Input.rename)
    fileprivate static func rename(
        _ source: Draft,
        _ title: String
    ) throws(RenameFailure) -> Draft {
        guard !title.isEmpty else { throw .empty }
        return Draft(title: title)
    }
}

@MainActor
func renameDraft() {
    let host = Rename.MainActorHost(Rename.Draft(title: "Notes"))
    do {
        try host.send(.rename(""))
    } catch .preparation(.rename(.empty)) {
        print("A title cannot be empty")
    } catch {
        print("Rename was not accepted: \(error)")
    }
}
```

An `ownedOnly` edge consumes its source with `consuming`. If it can fail, it
returns `Advance<Source, Destination, Effect, Failure>`, where the effect
argument is `Never` or `Effect.<Edge>`, so a rejection can return the original
resource. An infallible `ownedOnly` edge returns the destination or a `Change`.
A consuming function that throws after losing its predecessor cannot provide
that recovery contract.

```swift
@StateMachine(mode: .ownedOnly)
nonisolated enum Upload: ~Copyable {
    struct Open: ~Copyable { let handle: Int32 }
    struct Sealed: ~Copyable { let handle: Int32 }

    @Initial case open(Open)
    case sealed(Sealed)

    enum Input { case seal(Bool) }
    enum SealFailure: Error { case incomplete }

    @Transition(on: Input.seal)
    fileprivate static func seal(
        _ source: consuming Open,
        _ complete: Bool
    ) -> Advance<Open, Sealed, Never, SealFailure> {
        guard complete else { return .rejected(.incomplete, source) }
        return .advanced(Sealed(handle: source.handle), effects: [])
    }
}

func sealUpload() {
    switch Upload.owned(Upload.Open(handle: 3)).seal(false) {
    case .advanced(let sealed, _):
        sealed.withValue { print("Sealed \($0.handle)") }
    case .rejected(let failure, let open):
        // The original owner comes back and can be advanced again.
        open.withValue { print("\(failure): still holding \($0.handle)") }
    }
}
```

Inputs have zero or one unlabeled payload. Every phase case has one unlabeled
payload, whose distinct struct or enum is declared directly inside the schema.
Fields can use imported types and nested generic containers. Phase aliases,
reusing a payload type for several phases, generic schema or phase payload
declarations, async edges, untyped throws, `inout` sources, and generic edge
functions are unsupported. Keep declarations inside the schema; the macro does
not discover extensions or scan other files.

The package compiles three stress graphs of 128 phases on every change: one
with 512 edges over four inputs, one where each of 512 edges has its own input,
and one with 32 operations. Larger graphs are not measured.

Generated member names and the support types used by expansion are reserved.
For example, a value graph cannot name a phase case `model`, `record`,
`revision`, `isClosed`, or `description`, because its snapshot already uses those
members, and `Restoration`, `ShutdownResult`, and `ShutdownDiagnostics` are
reserved type names.
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
    var machine = MessageFlow.Local(MessageFlow.Ready(message: "Approved"))
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
`DeliveryResult` includes `.stale`, when the operation has lost its authority or
its outcome already settled, and `.foreignOwner`, when a different owner issued
the completion. `AcknowledgmentResult` is `.recorded`, `.duplicate`, or
`.foreignOwner`. An asynchronous runner must retain its execution handles until
the tasks terminate, and a cancellation request alone does not acknowledge
termination. A retained delivery may still need admission or explicit
reconciliation after execution has ended. Draining and acknowledging never admit
a retained completion. For a completion pending on capacity,
`retryAdmission(id:)` rechecks the prepared candidate. It commits if capacity is
available and the candidate is still current. An intervening revision requires
reconciliation while the operation remains active.

`Owned` runs the authored edge and leaves its effects to the caller. If the edge
returns the destination payload without throwing, the consuming method returns
the next `Owned` directly. If it returns `Change` without throwing, the method
returns `Change<Owned<Next>, Effect.<Edge>>` with ordered effects. An edge that
uses typed throws or returns `Advance` produces
`Advance<Owned<Source>, Owned<Next>, Intent, Failure>`, with `Never` for
`Intent` when `starts:` is empty and `Effect.<Edge>` otherwise. The `effect`
property on each value widens it to the schema-wide `Effect`:

```swift
func ownedSearch() {
    let change = Lookup.owned().begin("swift")
    print(change.effects.map(\.effect))

    let idle = change.next.cancel()
    idle.withValue { _ in }
}
```

`Owned<Searching>` offers `cancel()` and `received(_:)`, and `Owned<Idle>`
offers only `begin(_:)`.

To compare effects in a test, declare `extension Lookup.Effect: Equatable {}` in
the file that declares the schema. The compiler synthesizes `==` only in the
file that declares the type, so the extension fails to compile anywhere else.
Then compare `change.effects.map(\.effect)` with an array of `Lookup.Effect`
values. The [testing guide](<doc:TestingAGraph>) shows this in a test.

## Restore saved data

A `shared` or `isolated` schema generates `Restoration`, an enum with one case
for each phase in which no operation is active. A schema may declare one
function marked `@Restoration` that validates saved data into one of those
cases:

```swift
@StateMachine(mode: .shared)
nonisolated enum Download: Sendable {
    struct Idle: Sendable { let name: String }
    struct Running: Sendable { let name: String }
    struct Finished: Sendable {
        let name: String
        let bytes: Int
    }

    @Initial case idle(Idle)
    case running(Running)
    case finished(Finished)

    enum Scope { case transfer }
    enum Input: Sendable { case start, cancel }

    @Operation(scope: Scope.transfer, activeIn: [Running.self], admission: .latest)
    enum Transfer {
        typealias Input = String
        typealias Output = Int
        typealias Failure = Never
    }

    enum RestoreRejection: Error, Sendable { case emptyName }

    @Restoration
    fileprivate static func restore(_ saved: Self) throws(RestoreRejection) -> Restoration {
        switch saved {
        case .idle(let idle):
            guard !idle.name.isEmpty else { throw .emptyName }
            return .idle(idle)
        case .running(let running):
            // Saved work has no task to resume, so start over from the resting phase.
            return .idle(Idle(name: running.name))
        case .finished(let finished):
            return .finished(finished)
        }
    }

    @Transition(on: Input.start, starts: [Transfer.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(name: source.name), effects: [.transfer(source.name)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Running) -> Idle { Idle(name: source.name) }

    @Transition(onSuccess: Transfer.self)
    fileprivate static func received(_ source: Running, _ bytes: Transfer.Output) -> Finished {
        Finished(name: source.name, bytes: bytes)
    }
}

@MainActor
func resume(_ saved: Download) async throws {
    let host = try Download.MainActorHost(
        restoring: saved,
        transferDriver: { name in .success(name.count) }
    )
    print(host.snapshot().revision)

    try host.send(.start)
    await host.shutdown()
}
```

The function takes the saved data as its one parameter, which can be any type
that the application defines, and returns `Restoration`. It may use typed
`throws`. Declaring it gives every owner except `Owned` an `init(restoring:)`
that mirrors the ordinary initializer, takes the saved data in place of the
initial payload, and throws exactly when the function does. A managed owner's
`init(restoring:)` also has the form with one closure per operation, as
`transferDriver:` does here. A restored owner
starts at revision zero with fresh authority. It adopts no ticket, task, or
pending completion from any other owner.

A phase in which an operation is active has no `Restoration` case, so saved data
cannot resume running work. Returning `.running(...)` from
`restore` does not compile: the compiler reports that `Download.Restoration` has
no member `running`. The author either rejects that saved shape or maps it to a
resting phase, as `restore` does for `.running`, and then sends an input to start
fresh work. A schema with no operations has a case for every phase.

Forking is restoring a saved copy of `snapshot.model`. Because `restore` takes
the schema itself, a fork of a running owner is one initializer call:

```swift
func fork(_ original: Download.Shared) throws -> Download.Shared {
    try Download.Shared(
        restoring: original.snapshot().model,
        transferDriver: { name in .success(name.count) }
    )
}
```

The `StateMachineExamples` module shows the other common shape. `GeneratedProfile`
declares its own `Archive` enum and a validator that rejects an interrupted load,
and the persistence guide uses it.
