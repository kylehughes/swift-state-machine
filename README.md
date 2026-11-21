# State Machine

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Test](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml)

State Machine models a workflow as a graph of phases and generates a typed Swift
API for it. Each phase holds its own data and exposes only the transitions
declared from it, so calling a transition that does not exist from that phase
does not compile.

State Machine also manages the asynchronous work that a transition starts. It
applies a result only while the work that produced it is still current. If a
request is cancelled, the account changes, or the workflow moves on first, a
late result is rejected instead of overwriting newer state.

The package has three products. `StateMachine` holds the macros and the
runtime and has no UI dependencies, so the same generated workflow runs in
apps, actors, background work, command-line tools, and macOS services. The
runtime builds on Apple's `os` module, so it runs on Apple platforms.
`StateMachineUI` presents a workflow in SwiftUI or UIKit, and
`StateMachineTesting` drives real owners from tests.

## Installation

The package has no tagged release yet, so depend on its `main` branch with
Swift Package Manager:

```swift
.package(url: "https://github.com/kylehughes/swift-state-machine.git", branch: "main")
```

Add the `StateMachine` product to a target that declares a graph. The macros
are part of that module, so `import StateMachine` is the only import a graph
needs:

```swift
.product(name: "StateMachine", package: "swift-state-machine")
```

Add `StateMachineUI` for SwiftUI and UIKit presentation, and add
`StateMachineTesting` to test targets. The repository's
`Sources/StateMachineExamples` holds larger worked examples for the package's
own tests; it is not a product.

### Requirements

Requires Swift 6.4 in Swift 6 language mode. The package declares these
deployment targets:

| Platform | Deployment target |
| --- | --- |
| iOS | 16.0 |
| Mac Catalyst | 16.0 |
| macOS | 13.0 |
| tvOS | 16.0 |
| watchOS | 9.0 |
| visionOS | 1.0 |

The package supports the deployment targets above. The Observation APIs, which
observe a `MainActorHost` and back the `@Observable` presentations, require iOS
17, macOS 14, tvOS 17, watchOS 10, visionOS 1, or Mac Catalyst 17. A snapshot
sequence's iterator offers `next()` at the deployment targets and also
`next(isolation:)`, which requires iOS 18, macOS 15, tvOS 18, watchOS 11,
visionOS 2, or Mac Catalyst 18. See the
[API documentation](https://kylehughes.github.io/swift-state-machine/documentation/)
for the macros, ownership, restoration, testing, and raw runtime construction.

## A first graph

A schema is a `nonisolated enum` that declares a graph of phases and the edges
between them. This graph has one legal transition, from a draft to an approved
value:

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Approval: Sendable {
    struct Draft: Sendable { let title: String }
    struct Approved: Sendable { let title: String }

    @Initial case draft(Draft)
    @Terminal case approved(Approved)

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

`Approval.owned(_:)` takes the draft and creates an owner in the initial phase.
`approve` takes a `Draft` and returns an `Approved`, so the macro derives an
edge from the `draft` phase to the `approved` phase, with `Input.approve` as its
trigger. `@Terminal` marks `approved` as a phase the workflow ends in; a phase
that no edge leaves must carry it.

The generated `Owned<Draft>` has `approve`, and `Owned<Approved>` does not, so
calling the edge twice or in the wrong phase does not compile. Calling the edge
consumes the `Owned<Draft>` value, so a phase owner that a transition already
consumed cannot be used a second time. `Draft` and `Approved` are ordinary
structs: constructing one gives no one authority to change an owner.

To keep the state where other code can read and observe it, host the same graph.
A graph with no operations needs no drivers:

```swift
@MainActor
func approveInHost() throws {
    let host = Approval.MainActorHost(Approval.Draft(title: "Launch checklist"))
    let receipt = try host.send(.approve)
    print(receipt)
}
```

`send` routes `Input.approve` to the edge, admits it, and returns a receipt.
Printing a receipt shows the phase and revision, here `approved, revision 1`,
and never the payload.

## Choose an owner

Each schema generates the owners its mode supports. The managed hosts,
`MainActorHost`, `ActorHost`, `Shared`, and `IsolatedHost`, run operation
drivers and manage completion delivery. `Local` and `Owned` are manual owners
for callers that run effects themselves.

| Owner | Use it when | Schema modes |
| --- | --- | --- |
| `MainActorHost` | Input and admission belong to the main actor, such as a screen's model. | `shared`, `isolated` |
| `ActorHost` | A service or background coordinator keeps the state behind an actor of its own. | `shared` |
| `Shared` | Independent tasks need synchronous access to one shared owner. | `shared` |
| `IsolatedHost<Owner>` | An actor you already have owns the state, and its drivers should run on that actor, as [Host a graph on your own actor](#host-a-graph-on-your-own-actor) shows. | `shared`, `isolated` |
| `Local` | The caller owns a noncopyable value, drains commands, and acknowledges work explicitly. | `shared`, `isolated` |
| `Owned<Phase>` | The caller transfers exclusive ownership through consuming edges and handles effects. | `shared`, `isolated`, `ownedOnly` |

Choose `shared` for concurrent access with checked `Sendable` data, `isolated`
for copyable values that stay within their actor, or `ownedOnly` for
noncopyable resources. To generate only the owners you use, list them, as in
`@StateMachine(mode: .shared, owners: [.local, .mainActorHost])`. The macro then
generates only the support those owners need, and the names of the others stay
free for your own declarations.

Every owner except `Owned` accepts input through `send(_:)`, which returns a
`Receipt` or throws `SendRejection`. `ActorHost.send(_:)` is `async`, and
`Local.send(_:)` is `mutating`. A `.preparation` rejection covers an invalid
phase or a router or edge that declines the input. A `.commit` rejection means
the owner refused the prepared change, or its effect plan is defective, which is
`.commit(.plan)`. The receipt carries the accepted `revision`, the snapshot it
produced, and `edgeID`, the identifier of the graph edge the change took, such
as `"draft.approve"`; a reset or closure takes no edge and reports `nil`.

`MainActorHost`, `ActorHost`, and `IsolatedHost` own their state directly, so
`send` reads, prepares, and admits a change in one isolated turn. A managed
owner has no `deliver`: the only way a completion reaches it is through its own
drivers. The
[hosting guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/hostingagraph)
covers choosing and creating each managed owner, settling completions, reset,
and shutdown.

Dropping an owner is legal; ownership does not require completing the workflow.
An `ownedOnly` edge that can reject returns the original owner with the
failure, and one that succeeds returns the next owner and every effect value in
order for the caller to handle. `takeValue()` consumes an `Owned` value and
returns its payload, whereas `withValue` borrows it.

### Send an input or commit an edge

`send` makes exactly one attempt. It routes the input against whatever the owner
currently holds, prepares the change from the current snapshot, and commits it.
Acceptance atomically installs the complete model, operation authority, and
ordered command batch. `Shared` is the only owner where a competing write can
make the attempt fail with `.commit(.conflict)`; the rejection leaves all three
unchanged. Use `send` for an event that should act on the current state: a
timer, a push notification, or a tap that means "approve whatever is showing".

Each case of a snapshot holds an `Observed<Phase>`. Its methods are the edges
whose source is that phase, and each returns a `Prepared` proposal. An edge that
cannot fail needs no `try`; an edge that throws a typed failure throws exactly
that failure. A `Prepared` proposal is noncopyable and is consumed when passed
to `commit(_:)`, so it cannot be committed a second time. An owner's
`commit(_:)` admits the proposal only if that observation is still the owner's
current revision, and returns a `CommitResult`: `.committed(receipt)` or
`.rejected(reason, current:)`. A defective effect plan is reported there too, as
`.rejected(.plan(_), current:)`, unless the proposal came from another owner or
the owner has closed, which `commit(_:)` reports first as `.foreignOwner` or
`.closed`. The result is not discardable. Use this path when the action belongs
to the exact observation the user saw, and handle `.conflict` if an intervening
commit advances the same open owner.

```swift
@MainActor
func approve(_ draft: Approval.Observed<Approval.Draft>, on host: Approval.MainActorHost) {
    switch host.commit(draft.approve()) {
    case .committed:
        print("Approved")
    case .rejected(.conflict, let current):
        print("The draft changed first: \(current)")
    case .rejected(let reason, _):
        print("Approval was not accepted: \(reason)")
    }
}
```

The compiler checks the call. If an edge is removed or moves to another phase, a
view that calls it stops compiling, whereas `send(.approve)` routes at run time
and fails with `.preparation(.invalidPhase)`. When several edges share a source
and an input, a `@Route` function chooses among them. `send` and the observed
call both run it: the observed phase offers one method, named after the route
function, and none for the candidate edges, so a rule in a router cannot be
bypassed. `commit(_:)` is `async` on `ActorHost` and `mutating` on `Local`.
`StateMachinePresentation` and `StateMachineObservableObject` also expose
`commit(_:)`.

## Add asynchronous work

An operation is work that the host runs and whose result returns through a
completion edge. This example declares a search workflow with one operation and
runs it in a generated actor host:

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Searching: Sendable { let query: String }
    struct Found: Sendable { let answer: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    case found(Found)

    enum Input: Sendable { case search(String), cancel }

    @Operation(activeIn: [Searching.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
    }

    @Transition(from: [Idle.self, Found.self], on: Input.search, starts: [Fetch.self])
    fileprivate static func begin(_ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.fetch(query)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Searching) -> Idle { Idle() }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Searching, _ answer: Fetch.Output) -> Found {
        Found(answer: answer)
    }
}

func runLookup() async throws {
    let lookup = Lookup.ActorHost(fetchDriver: { query in "Results for \(query)" })
    let snapshots = try await lookup.snapshots()
    try await lookup.send(.search("swift"))

    for await snapshot in snapshots {
        if case .found(let found) = snapshot {
            print(found.value.answer)
            break
        }
    }
    await lookup.shutdown()
}
```

Creating the host starts no work. Sending `.search` admits the `searching`
phase, then runs the `fetch` driver. When the driver returns, the host checks
that `Fetch` still has authority, applies `received`, and delivers the `found`
snapshot to observers.

`@Initial case idle(Idle = Idle())` declares the start, so the host needs no
initial payload. `begin` does not read its source, so it lists its source phases
in `from:` instead of taking a source parameter, and each listed phase gets its
own edge. An operation names the phases where it is active and nothing else: it
holds a private scope of its own, replaces older work with newer work by
default, and cannot fail unless it declares a `Failure`. An omitted `Input` or
`Output` is `Void`, and a success edge of an operation without output takes no
output parameter, as in `static func finished(_ source: Running) -> Ready`. The
driver returns the `Output` directly; a driver for a fallible operation returns
`Result<Output, Failure>` instead.

The schema is the only place the graph is written down, and the compiler
enforces it:

- `begin` returns `Change<Searching, Effect.Begin>`. Its effects can name only
  operations in its `starts:` list. Starting an operation that the edge does not
  list does not compile.
- `Fetch` is active in `Searching`, so the macro requires a success edge from
  `Searching`. Omitting `received` is a compile error.
- `cancel` leaves `Searching`, the only phase where `Fetch` is active, so the
  running fetch loses its authority. If the driver returns after that, its
  completion is stale and cannot move the machine to `found`.
- Sending `.cancel` while idle fails with `.preparation(.invalidPhase)`, and the
  snapshot stays unchanged.

A completion edge has no method on an observation at all; an owner admits a
completion only through its own delivery. An `Owned` phase keeps a method for
each completion edge, except that a router over completion edges replaces its
candidates' methods with one named after the router.

The [declaring guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/declaringagraph)
covers named scopes, failure edges, routers, and the complete declaration
grammar.

## Run operations

### Drivers

A managed host takes one closure for each operation, labelled with the
operation's effect case and `Driver`, as in `fetchDriver:`. The `drivers:` form
takes one value with every driver instead: `Drivers` for `Shared` and
`ActorHost`, `MainActorDrivers` for `MainActorHost`, and
`IsolatedHost<Owner>.Drivers` for `IsolatedHost`. Use it to pass one set of
drivers around, to inject stubs in a test, or when the graph has many
operations.

A driver takes the operation's input and returns its output, or a
`Result<Output, Failure>` when the operation declares a `Failure`. A driver of
an operation without input takes no parameter, a keyed operation's driver takes
the key first, and an `IsolatedHost` driver takes the owning actor first. The
drivers of `Shared` and `ActorHost` are `@Sendable`, and those of
`MainActorHost` run on the main actor.

Cancellation is cooperative. When an edge revokes an operation's authority, the
host cancels the driver's task, and a driver that ignores cancellation keeps
running until it returns. Its result is then stale, and the host discards it.

### Host a graph on your own actor

`IsolatedHost<Owner>` is confined to an actor instance that you choose. It is
not `Sendable`, and every method takes the owning actor as a defaulted
`isolated` parameter, so inside the actor a call reads `host.send(input)`
without `await`, and a call from another actor or a nonisolated context does not
compile. Its drivers and event handlers run on the owning actor and receive it
isolated, so they can read and change its state without capturing it, and its
callbacks run there too:

```swift
actor SearchService {
    private var searches: [String] = []

    private lazy var host = Lookup.IsolatedHost(
        isolation: self,
        fetchDriver: { service, query in service.answer(for: query) }
    )

    func search(_ query: String) throws {
        try host.send(.search(query))
    }

    private func answer(for query: String) -> String {
        searches.append(query)
        return "Results for \(query)"
    }
}
```

The host needs the actor itself as its owner, and an actor's `self` is
available only after every stored property has a value, so the initializer
cannot assign it to a `let`. Declare it `lazy`, as here, so the actor creates it
on first use, or store it in an optional that an `async` initializer or an actor
method assigns.

Storing the host on its actor forms no cycle by itself: the host holds the
actor weakly, and an idle actor is released with its host. A running driver
does keep the actor alive, because it runs on it, so an actor released while a
driver waits stays alive until that driver returns. `close()` or `shutdown()`
requests the drivers' cancellation, and the actor is released after each driver
returns; a driver that ignores cancellation keeps it until then.

Drivers and event handlers receive the actor, so write them without capturing
it, as in `onLogged: { owner, line in owner.messages.append(line) }`. The host
holds its drivers and handlers for its whole lifetime, so one that captures the
actor keeps it alive as long as the host, which the actor stores: a cycle. A
callback that captures the actor keeps it alive while its registration lasts.
Cancelling the registration on the actor closes it and removes it before
`cancel()` returns, so none of its callbacks begins afterward, and only the
actor can cancel it: the token's
`cancel(isolation:)` takes the actor as a defaulted `isolated` parameter, so a
call from an ordinary object's destructor, which can run on any thread, does
not compile. The callbacks themselves are released after `cancel()` returns
when the host is delivering a change at that moment, such as when another
observer's callback cancels the registration: the host keeps the callbacks it
selected for that change until it has delivered the change to the other
observers. Dropping the token stops delivery and frees its slot at once, from
any thread; the host releases the callback when it next sweeps its
registrations on the actor, or when it is destroyed.

`ActorHost` also accepts `isolatedTo:` with any actor, which runs the host's
own actor on that actor's executor so their turns never overlap; calls into the
host still `await`. The host retains that actor for its whole lifetime, since
its executor must outlive every job the host runs, so an actor that stores a
host isolated to itself keeps itself alive until it releases the host. To own a
host from the actor whose turns it shares, use `IsolatedHost`.

### Keyed work and the request

An operation with a `Key` alias runs independent work for each key. Its effect
case carries the key, and admission applies the operation's policy to each key,
so starting a key again replaces only that key's work. An edge that lists the
operation in `cancels:` can cancel one key's work or all of it. A completion
edge can take the operation's generated request as its last parameter, labeled
`request:`, which records the key and input that the work was started with:

```swift
@StateMachine(mode: .shared)
nonisolated enum Library: Sendable {
    struct Browsing: Sendable { var files: [Int: String] = [:] }

    @Initial case browsing(Browsing = Browsing())

    enum Input: Sendable { case open(Int), cancel(Int), cancelAll }

    @Operation(activeIn: [Browsing.self])
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
    }

    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id, input: "files/\(id)")])
    }

    @Transition(on: Input.cancel, cancels: [Download.self])
    fileprivate static func cancel(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Cancel> {
        Change(source, effects: [.cancelDownload(key: id)])
    }

    @Transition(on: Input.cancelAll, cancels: [Download.self])
    fileprivate static func cancelAll(_ source: Browsing) -> Change<Browsing, Effect.CancelAll> {
        Change(source, effects: [.cancelAllDownload])
    }

    @Transition(onSuccess: Download.self)
    fileprivate static func downloaded(
        _ source: Browsing,
        _ contents: Download.Output,
        request: DownloadRequest
    ) -> Browsing {
        var files = source.files
        files[request.key] = contents
        return Browsing(files: files)
    }
}

func openFiles() throws {
    let library = Library.Shared(downloadDriver: { id, path in "Contents of \(path)" })
    try library.send(.open(1))
    try library.send(.open(2))
    try library.send(.cancel(1))
}
```

The request is also on the work a `Local` issues, on the sealed completion, and
on each retained `PendingCompletion` outcome. It is plain data, so constructing
one grants nothing.

### Admission and scopes

An operation admits work by one of three policies. `.latest`, the default,
replaces the older work of its group with the newer. `.rejectWhenActive`
rejects a start while earlier work is still active, and `.parallel(limit:)`
admits up to that many at once. A rejected start rejects the whole change that
emitted it.

An operation's authority lasts while the owner stays in its active phases. To
share authority between operations, or to revoke it without leaving a phase,
declare named scopes. Each case of a nested `Scope` enum is a scope, active in
the phases its `@Active(in:)` lists, or in every phase without one. An operation
then names its scope and the scopes it requires instead of `activeIn:`, as in
`@Operation(scope: Scope.load, requires: [Scope.session])`, and an edge that
lists a scope in `invalidates:` revokes every operation that holds it. The
[declaring guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/declaringagraph)
shows each of these.

### Completion policy

Another write can commit between a completion's preparation and its admission.
A managed host settles that race according to its `completionPolicy:`, which is
one of four values:

- `.retry` prepares the completion again against the newer state, at most four
  times per turn before yielding. After sixteen turns that each lose a race,
  the completion stays pending for an explicit decision.
- `.retry(onReconciliationRequired:)` retries the same way and passes every
  completion that still needs reconciliation to a handler.
- `.manual` never prepares a completion again on its own. Every completion that
  needs reconciliation, including one that lost a race, stays pending.
- `.manual(onReconciliationRequired:)` behaves as `.manual` and passes each of
  those completions to a handler.

`.retry` is the default, because preparing a completion again is the same as
its result arriving a moment later, when its edge would run against the newer
phase anyway. Work that must not survive a change is revoked with
`invalidates:` instead. When a completion can refuse an outcome, because a
completion edge or router throws or a completion edge starts a
`.rejectWhenActive` or `.parallel(limit:)` operation, the initializers have no
default and you choose.

Every edge and router must be deterministic and free of side effects, whatever
the policy, because preparation can run again: `.retry` reevaluates it, and an
explicit `reconcile(id:)` prepares it again under `.manual` too. Capture network
responses, decoded values, time, and other external inputs once, before they
reach an edge; the compiler does not check this. Use `.manual` when the
application must decide whether a result still applies to a newer state, such as
an answer to a question the user has since changed, instead of letting the edge
reinterpret it.

### Settle pending completions

A completion needs reconciliation when its completion edge or router threw, its
effect plan is defective, the owner refused its admission, it used its last
retry, or an explicit `reconcile(id:)` did not commit. Until it is settled, the
owner retains the first terminal outcome, and a duplicate delivery never
replaces it. `pendingCompletions()` lists the retained completions, and
`pendingCompletionUpdates()` follows them. Each element is the whole pending
collection. A slow reader can skip intermediate collections. Closing delivers a
final empty collection:

```swift
func discardUnsettled(in library: Library.Shared) async throws {
    for await pending in try library.pendingCompletionUpdates() {
        for completion in pending where completion.status == .reconciliationRequired {
            _ = library.discardPending(id: completion.id)
        }
    }
}
```

The sequence keeps one pending value, so a newer collection replaces one not yet
read, and it ends after the final, empty one. `pendingCompletionUpdates(_:)`
projects each collection to a
`Sendable` value, as `snapshots(_:)` does for snapshots; it is how an
`isolated` schema's retained completions reach `for await` and sequence
operators. Settle a completion with `reconcile(id:)`, which authorizes one fresh
preparation and reports `.inProgress` if another attempt holds the claim, or
with `discardPending(id:)`, which revokes its operation. A reconciliation that
loses a race stays pending for another explicit decision. The policy's handler
runs outside the owner's critical section with the `PendingCompletion`.

An occupied queue or execution bound produces `capacityExceeded`. Managed
delivery retains the prepared candidate and retries admission when capacity
changes, without rerunning preparation. A plan that cannot fit by itself
produces `planTooLarge` and needs an application decision.

### Reset an owner

`reset(to:)` replaces the model with a fresh initial phase, as a new owner
starts, while keeping the owner's identity and subscribers. Every outstanding
operation is revoked and every retained completion is dropped, so a late result
is stale, and the revision advances. The argument is optional when the initial
phase declares a default:

```swift
@MainActor
func startOver(_ host: Lookup.MainActorHost) throws {
    let receipt = try host.reset()
    print("Reset at revision \(receipt.revision)")
}
```

A reset expects no revision, so no concurrent commit can make it conflict. It
throws when the owner is closed, its revisions are exhausted, or it must queue
a batch while its commit queue is full, and then changes nothing. A managed
host queues every reset; a `Local` queues one only to cancel revoked work. A
schema with a `@Restoration` function also has `reset(restoring:)`, which
validates saved data first.

To reset because of a decision made on a particular snapshot, such as a user
confirming that they want to discard the draft they are looking at, pass that
snapshot as `expecting:`. The owner resets only if it still holds that root, and
otherwise changes nothing and throws as a commit prepared on it would:
`.conflict` after another change, `.obsoleteIncarnation` after another reset, or
`.foreignOwner` for another owner's snapshot:

```swift
@MainActor
func discardReviewed(_ reviewed: Lookup.Snapshot, on host: Lookup.MainActorHost) {
    do {
        try host.reset(expecting: reviewed)
    } catch .conflict {
        print("The search changed after the review; nothing was discarded")
    } catch {
        print("Not reset: \(error)")
    }
}
```

Every owner except `Owned` offers `reset(to:)`, `reset(to:expecting:)`, and,
with a `@Restoration` function, `reset(restoring:)` and
`reset(restoring:expecting:)`; on `ActorHost` they are `async`.

### End a lifetime

Call `close()` to end admission and revoke work authority; cancellation remains
cooperative, and the result is discardable. `shutdown(deadline:)` is the one
verb that also waits for actual task termination and delivery cleanup. It
returns a discardable `ShutdownResult`: `.quiescent` once the owner has settled,
or `.timedOut(ShutdownDiagnostics)` when the deadline passes first. A timed-out
owner stays closed and keeps tracking the outstanding work the diagnostics
describe. `runningCount` reports how many drivers are still running,
`subscriberCount` how many registrations are live, and `isQuiescent` whether
everything has settled. They are `async` on `ActorHost`, and on `IsolatedHost`
they are methods, `runningCount()`, `subscriberCount()`, and `isQuiescent()`,
that take the owning actor like every other member. An owner of a graph without
operations has no drivers and no `runningCount`.

`flush(through:)` waits for snapshot offers and effect launch or skip decisions
through an accepted receipt, and returns `.processed`, or `.foreignOwner` for a
receipt that another owner issued. It does not wait for network completion or
observer callbacks. Retained snapshots and receipts describe history, not
reservations of the current state.

## Run effects yourself with `Local` and `Owned`

`Local` is a noncopyable value with no background runner. After `send` or
`commit` accepts a change, `drainCommands()` yields whole batches of commands
such as `.fetch(work)`; pass `limit:` to take fewer. Finish the mutating access
before running the work. `work.succeeded(value)` builds a sealed completion.
Pass it to `deliver(_:)` to get a `DeliveryResult`: `.committed`, `.pending`,
`.refused`, `.stale`, or `.foreignOwner`. `.refused(id, reason, routeID:)`
means this call prepared the outcome and its router or completion edge threw
`reason`; `routeID` names that router or edge, and the outcome stays retained.
A second delivery of a retained outcome prepares nothing and reports
`.pending`. Call `acknowledgeExecution(work.execution)`
separately to record that execution ended, or pass
`disposition: .skippedBeforeStart` for work you never began.
`AcknowledgmentResult` is `.recorded`, `.duplicate`, or `.foreignOwner`. A
start whose authority was revoked before its batch was drained is left out of
the batch and recorded as skipped, so it needs no acknowledgment.
`Local` queues a batch only for a change that starts work, cancels work, or
emits an event, and for closure. Any other accepted change queues nothing and
its receipt is the return value of `send` or `commit`, so a run of plain edits
never waits for a drain.

Draining and acknowledging never change the model. If capacity blocks an
otherwise admissible completion, `Local` retains its candidate as
`.pending(id, .waitingForCapacity)`. After freeing capacity, call
`retryAdmission(id:)` to recheck that candidate without preparing it again. An
intervening revision requires `reconcile(id:)` if the operation is still
active. Both return a `ReconcileResult`, which reports a refusal of its own
preparation as `.refused` too, and `discardPending(id:)` returns a
`DiscardResult`.

`Owned<Phase>` carries no runtime at all. If the authored edge returns the
destination payload without throwing, its `Owned` method returns the next owner
directly. If it returns `Change` without throwing, the method returns a `Change`
with the next owner and ordered, inert effects. A typed-throwing edge or one
declared to return `Advance` gives the caller an `Advance`. Each effect's
`effect` property widens it to the schema-wide `Effect`. The
[declaring guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/declaringagraph)
has an example of each, and the
[guide to running effects yourself](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/runningeffectsyourself)
walks through taking edges with `Owned` and driving a `Local` owner step by
step.

## Emit events

An event is an inert emission with an optional payload, such as a line for a log
or an analytics record. It has no driver, result, or authority. An edge lists
the events it may emit in `emits:` and returns them among its effects:

```swift
@StateMachine(mode: .shared)
nonisolated enum Checkout: Sendable {
    struct Cart: Sendable { var items: [String] = [] }

    @Initial case cart(Cart = Cart())

    enum Input: Sendable { case add(String) }

    @Event
    enum Added { typealias Payload = String }

    @Transition(on: Input.add, emits: [Added.self])
    fileprivate static func add(_ source: Cart, _ item: String) -> Change<Cart, Effect.Add> {
        Change(Cart(items: source.items + [item]), effects: [.added(item)])
    }
}

func fillCart() throws {
    let checkout = Checkout.Shared(onAdded: { item in print("Added \(item)") })
    try checkout.send(.add("Notebook"))
}
```

A managed host takes one required handler per event, labelled `on<Event>:`, and
calls it once per emission, in commit order, after the commit and outside every
lock, so a handler may read the owner or send another input. `Local` carries
each event in its command batch, and an `Owned` edge returns it among its
effects. An event without a `Payload` alias carries nothing.

## Rely on graph checks

The macro checks the graph's structure on every build and reports an error on
the declaration at fault. It rejects:

- a phase that no path from the initial phase, or from a phase that
  `@Restoration` can restore, reaches;
- a phase that no edge leaves and that is not marked `@Terminal`, and a
  `@Terminal` phase that an edge leaves or where an operation can be active;
- an operation that no reachable edge starts;
- an operation that can start but whose success, or, for an operation that can
  fail, whose failure, no completion edge accepts in any phase where it can be
  active;
- a completion edge or router that no path reaches with its operation's work
  still outstanding.

An edge back to its own phase counts as leaving it. Every phase where an
operation can be active also needs a completion edge or router for each of its
outcomes, and only for those: the macro rejects a failure edge of an operation
that cannot fail, or a success edge of one whose `Output` is `Never`, because it
could never run. A router there that never chooses an edge, `throws(...) -> Never`,
refuses the outcome in that phase: `Local` or a managed host retains it as a
pending completion that needs reconciliation, until `reconcile(id:)` admits it
in a phase that accepts it or `discardPending(id:)` drops it.

The checks read declared structure only: they assume that every declared edge
can fire, because the macro cannot know whether an authored function throws or
which edge a router chooses. They follow each path with the outstanding work of
every operation together, so a completion edge counts only on a path that
started its operation's work and has not yet retired it, and work that one path
starts never counts on another. They count that work where the declarations
bound it: one execution of a `.latest` or `.rejectWhenActive` operation, and up
to the limit of `.parallel(limit:)`, each completion retiring one. A keyed
operation's keys hold independent work, so the completion of one key never ends
another's.

Three approximations can only accept more graphs. A keyed operation and a
`.parallel(limit:)` above 32 count as unbounded, so no completion retires their
last execution, even when the key type or the limit allows fewer executions than
the graph's completions need. A graph whose paths combine into more work states
than the macro explores within a fixed budget is checked per operation instead,
which tracks each operation's work apart from the others' and so can credit one
path with work another path started. A schema that generates only `Owned` holds
no work, because its completion methods need only their source phase, so its
checks cover phase paths and routing without counting work. Passing the checks
shows that each phase and operation has a declared path under these rules, not
that a run takes it, or that every outcome an accepting edge names can arrive
there.

## Export the graph

Every schema has a static `graph`, a `StateMachineGraph` that describes its
data mode, the owners it generates, and its phases, inputs, scopes, operations,
events, edges, and routers in declaration order. It holds names and type
spellings, never a payload or authority, and it is `Sendable`, `Hashable`, and
`Codable`. Its encoded form records a `formatVersion`, and decoding a graph of
another version throws. It renders Mermaid and Graphviz text:

```swift
func printLookupDiagram() {
    print(Lookup.graph.mermaid())
    print(Lookup.graph.dot())
}
```

The Mermaid rendering of `Lookup` is:

```text
stateDiagram-v2
    state "idle" as p0
    state "searching" as p1
    state "found" as p2
    [*] --> p0
    p0 --> p1 : begin
    p2 --> p1 : begin
    p1 --> p0 : cancel
    p1 --> p2 : received
```

An edge or router is identified as `"<phase>.<name>"`, such as `idle.begin`,
so edges of one name that leave different phases stay distinct. The
[export guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/exportingagraph)
covers the rendered diagrams and reading the structure as data.

## Observe state

A snapshot is complete and carries its revision, and an owner's revisions
strictly increase. Managed hosts report their snapshots through callbacks,
asynchronous sequences, Combine, and, for `MainActorHost`, Observation, and
`StateMachineUI` builds presentations on them. The
[observation guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/observingstate)
covers each of these and how to budget subscriber slots.

### Observation and SwiftUI

On iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, and Mac Catalyst 17 and
later, a generated `MainActorHost` is `Observable`, so a SwiftUI view can hold
and read it directly. `currentSnapshot`, `runningCount`, `subscriberCount`, and
`pendingCompletions()` are each tracked separately, so a commit invalidates a
reader of the snapshot without invalidating a reader of the running count, and
tracking takes no subscriber slot:

```swift
import StateMachine
import SwiftUI

@MainActor
struct LookupView: View {
    @State private var lookup = Lookup.MainActorHost(fetchDriver: { query in "Results for \(query)" })

    var body: some View {
        switch lookup.currentSnapshot {
        case .idle:
            Button("Search") { _ = try? lookup.send(.search("swift")) }
        case .searching(let searching):
            ProgressView("Searching for \(searching.value.query)")
            Button("Cancel", role: .cancel) { _ = try? lookup.send(.cancel) }
        case .found(let found):
            Text(found.value.answer)
            Button("Search again") { _ = try? lookup.send(.search("swift")) }
        }
    }
}
```

Creating the host starts no work. Sending `.search` changes `currentSnapshot` in
the same turn, before `send` returns, then runs the driver. The driver's result
moves the view to `found`.

### Subscriptions and snapshot sequences

`subscribe` registers a callback, and `snapshots()` registers an asynchronous
sequence. Creating either takes one subscriber slot and throws
`SubscriptionFailure.capacityExceeded` when none is free; iterating never
throws. Every member that registers takes its slot when it is called, before
anything reads the result: `subscribe`, `snapshots()`, `snapshots(_:)`,
`distinctSnapshots(_:)`, `snapshotPublisher()` and `snapshotPublisher(_:)` even
when nothing subscribes, and `pendingCompletionUpdates()`. Each holds the slot
until it ends or is released:

```swift
func observe(_ lookup: Lookup.Shared) throws -> SnapshotSubscription {
    try lookup.subscribe { snapshot in
        if case .found(let found) = snapshot {
            print(found.value.answer)
        }
    }
}

func printAnswers(from lookup: Lookup.Shared) async throws {
    for await snapshot in try lookup.snapshots() {
        if case .found(let found) = snapshot {
            print(found.value.answer)
        }
    }
}
```

Retain the owner and the subscription for the feature's lifetime. Copies of
`Shared` refer to the same owner. Shared callbacks run outside the storage lock
and are not confined to the main actor. A `Shared` callback keeps one pending
snapshot too, so its first call receives the registration snapshot or a newer
one. `ActorHost` uses `try await actor.snapshots()`.

A snapshot sequence keeps one pending value. The first value is the snapshot
current at registration or a later revision, and slow consumers skip
intermediate snapshots. Effects and execution acknowledgments never coalesce.
If closing the owner ends iteration, the final element is the closed snapshot.
A read in a cancelled task ends it earlier, and `cancel()` ends it at once: a
`SnapshotSequence` from any isolation domain, and a confined stream on the
actor that owns it. A consumer that keeps a sequence after it stops reading, as
`defer { snapshots.cancel() }` does, frees the slot that way, because a task
that no longer reads observes no cancellation. A second iterator ends
immediately. The
sequence does not keep the owner alive; if the owner is released without
closing, the sequence ends without a closed snapshot. Releasing an owner right
after it accepted a change, or a close, still delivers them: the owner stays
alive until it has processed every batch it accepted, delivering each to every
registration, publishers included, though not while its drivers run. A loop sees an accepted input on a later turn, so code that needs
the result in the same turn uses the receipt from `send`.

Registration samples the state the owner has already admitted, as `snapshot()`
and an Observation read do. A `Shared` host delivers asynchronously, so a newer
snapshot can replace that first sample before your callback runs. Event handlers and later deliveries
follow commit order, so a subscription made just after an emitting `send` can
see that change before its event handler runs; `flush(through:)` waits for the
handler.

`snapshots(_:)` projects each snapshot to a `Sendable` value and offers every
projection, even one equal to the one before it. `distinctSnapshots(_:)` takes
an `Equatable` projection and omits each value equal to the one before it, so a
loop runs only when the part it reads changes:

```swift
func printFileCounts(from library: Library.Shared) async throws {
    let counts = try library.distinctSnapshots { snapshot in
        if case .browsing(let browsing) = snapshot { browsing.value.files.count } else { 0 }
    }
    for await count in counts {
        print("\(count) files")
    }
}
```

In a `shared` schema, every host's `snapshots()` returns `Snapshots`, an alias
of `SnapshotSequence<Snapshot>`, which works with `map`, `prefix`, and generic
`AsyncSequence` code on every supported OS. In an `isolated` schema, whose
snapshots are not `Sendable`, `MainActorHost.snapshots()` returns
`MainActorSnapshots`, read on the main actor, and `IsolatedHost.snapshots()`
returns `IsolatedSnapshots`, read on the owning actor. Each is a noncopyable
stream with one consumer: `var snapshots = try host.snapshots()` registers it,
and `while let snapshot = await snapshots.next()` reads it. These streams are not `AsyncSequence`s, because the standard operators run
their closures, and on earlier systems their iteration, off the caller's actor,
which would carry a confined snapshot away from it. For `for await`, operators,
or generic code, project each snapshot to a `Sendable` value with
`snapshots(_:)`, whose result is an ordinary `SnapshotSequence`.

### Combine

`MainActorHost` and `Shared` offer `snapshotPublisher(_:)`, which publishes a
`Sendable` projection of each snapshot, and `ActorHost` offers it `async`. In a
`shared` schema they also offer `snapshotPublisher()`, which publishes the
snapshot itself. A publisher's output is always `Sendable`, because a pipeline
can move it to another thread, as `receive(on:)` does, so an `isolated` schema
publishes only projections. The publisher delivers on the main actor and never
fails. It takes a subscriber slot when it is created and frees it when its
subscription is cancelled, keeps the latest value until demand allows, and
finishes after the closed snapshot, which also waits for demand. Demand reaches
the newest value the owner has handed over. An owner released without closing
first processes every batch it accepted, as every owner does, and then
finishes the publisher at once and discards every ordinary value not yet
delivered, so demand made after that receives only the completion. It accepts one
subscriber:

```swift
import Combine

@MainActor
func printRevisions(of lookup: Lookup.Shared) throws -> AnyCancellable {
    try lookup.snapshotPublisher().sink { snapshot in print(snapshot.revision) }
}
```

`IsolatedHost` has no publisher, because its snapshots belong to an actor that
Combine cannot be confined to. The runtime's registration types are
`SnapshotSubscription`, `MainActorSnapshotSubscription`, and
`IsolatedSnapshotSubscription`, so importing Combine beside State Machine leaves
`Subscription` meaning Combine's protocol.

### Presentations in `StateMachineUI`

The optional `StateMachineUI` module adapts owners for SwiftUI and UIKit, with
an `@Observable` type for iOS 17 and later and an `ObservableObject`
counterpart with the same observation and driving operations for the iOS 16
baseline. An `ObservableObject` presentation also publishes the snapshots it
shows to Combine, through `presentedSnapshots` when they are `Sendable` and
`presentedSnapshots(projecting:)` otherwise; the publisher stays open across
observations and finishes once the presentation is released.

`StateMachinePresentation` and `StateMachineObservableObject` drive a
`MainActorHost`: they expose `snapshot`, `send(_:)`, `commit(_:)`, `close()`,
and the `host`. A top-level call shows its accepted snapshot before it returns.
A call made during a publication, as from a callback of a snapshot change,
returns its receipt at once, and the presentation shows the latest snapshot
deferred that way after the current callback returns. Creating one never throws, so it can initialize `@State` or `@StateObject`
directly; if the host has no room for another observer, `isObserving` is
`false`, `observationFailure` holds the reason, and the presentation shows the
snapshot it read at creation. `resumeObserving()` registers with the same host
again, through the same registration creation makes, once a slot is free or
after `stopObserving()`: it keeps the snapshot shown, then shows the host's
current snapshot, and keeps `presentedSnapshots` subscribers attached. A refusal
throws and changes nothing.

`SnapshotPresentation` and `SnapshotObservableObject` present the snapshots of
any managed host without driving it. `observe(_:)` binds one to a host,
registers, and shows the host's current snapshot; a refused registration shows
nothing, and the refusal throws. A synchronous `observe(_:)` registers at once,
so it throws while an earlier registration of the same host is still being
cancelled and holds its only slot. The `async` forms wait for earlier
registrations first, so use one to observe a host again while a cancellation
may still be running. A presentation lives on the main actor, so an owner confined to another
actor is observed through a `Sendable` snapshot or a
`Sendable` projection from `snapshots(_:)`. `follow(snapshotsFrom:)` ends the
current observation, registers a `SnapshotSequence` with its closure, such as a
`Shared` host's `snapshots()` or any managed host's projection from
`snapshots(_:)`, and follows it for as long as the calling task runs, which
suits SwiftUI's `task` modifier. A refusal throws, and `try?` leaves the
presentation not observing:

```swift
import StateMachineUI
import SwiftUI

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@MainActor
struct LookupAnswer: View {
    let machine: Lookup.Shared
    let lookup: SnapshotPresentation<Lookup.Snapshot>

    var body: some View {
        Group {
            if case .found(let found) = lookup.snapshot {
                Text(found.value.answer)
            } else {
                ProgressView()
            }
        }
        .task(id: [ObjectIdentifier(machine), ObjectIdentifier(lookup)]) {
            try? await lookup.follow(snapshotsFrom: { try machine.snapshots() })
        }
    }
}
```

The task is keyed to both objects, so a view that SwiftUI keeps while it is
given another machine, or another presentation, cancels the task that follows
the old pair and starts another.
The closure runs only once the presentation has released its current
registration, so a replacement view task observes a host with one subscriber
slot as well; `follow(try machine.snapshots())` would register first, because
Swift evaluates the argument before the call.

A presentation shows the first element of each new observation and then
applies only newer revisions, so a delayed delivery never replaces newer state,
and observing a different owner needs no extra step. A projection therefore
carries the owner's revision, which the presentation reads to order what it
shows. `observe(snapshotsFrom:)` registers the projection once the current
observation has ended and keeps observing it until `stopObserving()`:

```swift
nonisolated struct AnswerSnapshot: Sendable {
    let revision: UInt64
    let answer: String?
}

@MainActor
func presentAnswers(of machine: Lookup.Shared) throws -> SnapshotObservableObject<AnswerSnapshot> {
    let answers = SnapshotObservableObject(
        AnswerSnapshot(revision: 0, answer: nil),
        revision: { $0.revision }
    )
    try answers.observe(snapshotsFrom: {
        try machine.snapshots { snapshot in
            if case .found(let found) = snapshot {
                AnswerSnapshot(revision: snapshot.revision, answer: found.value.answer)
            } else {
                AnswerSnapshot(revision: snapshot.revision, answer: nil)
            }
        }
    })
    return answers
}
```

Its `async` form takes a closure that may await, as an `ActorHost`'s
`snapshots(_:)` does. The
[UI guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineui/presentingstate)
shows a complete SwiftUI screen, commits an edge of the snapshot that the view
rendered, and explains the separate lifetime of a running driver.

### UIKit

A UIKit screen can iterate the host's snapshot sequence in a task. The task
inherits the main actor from the method that creates it. The screen keeps the
sequence and cancels it before it registers a replacement and when it
disappears: `cancel()` frees the subscriber slot before it returns, so the
replacement registers even when the owner allows one subscriber. Cancelling only
the task would end the old sequence when its loop next reads, which can happen
after the replacement asks for the slot. A read that the sequence had already
handed a snapshot when `cancel()` ran still returns it, so the loop checks its
task's cancellation before it renders: the check and the render run in the same
main-actor turn, and a loop that `stopObserving()` cancelled never renders after
the screen disappears or over its replacement. The screen runs at the iOS 16
deployment target and shows a loading placeholder only where
`UIContentUnavailableConfiguration` exists, on iOS 17, tvOS 17, Mac Catalyst 17,
and visionOS 1:

```swift
import StateMachine
import UIKit

@MainActor
final class LookupViewController: UIViewController {
    private let host: Lookup.MainActorHost
    private var snapshots: Lookup.Snapshots?
    private var observation: Task<Void, Never>?
    private let answerLabel = UILabel()

    // init(host:) and view layout omitted

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        stopObserving()
        do {
            let snapshots = try host.snapshots()
            self.snapshots = snapshots
            observation = Task {
                for await snapshot in snapshots {
                    guard !Task.isCancelled else { break }
                    self.render(snapshot)
                }
            }
        } catch {
            // Subscriber capacity is exhausted.
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObserving()
    }

    private func stopObserving() {
        snapshots?.cancel()
        snapshots = nil
        observation?.cancel()
        observation = nil
    }

    private func render(_ snapshot: Lookup.Snapshot) {
        switch snapshot {
        case .idle:
            answerLabel.text = nil
            showLoading(false)
        case .searching:
            answerLabel.text = nil
            showLoading(true)
        case .found(let found):
            answerLabel.text = found.value.answer
            showLoading(false)
        }
    }

    private func showLoading(_ loading: Bool) {
        guard #available(iOS 17, tvOS 17, *) else { return }
        contentUnavailableConfiguration = loading ? UIContentUnavailableConfiguration.loading() : nil
    }
}
```

## Test a graph

An edge is a function, so an `Owned` test needs no runtime and makes plain
assertions:

```swift
import Testing

@testable import MyApp

@Test func approvingADraftReachesApproved() {
    let draft = Approval.Draft(title: "Launch checklist")
    let approved = Approval.owned(draft).approve()

    #expect(approved.withValue { $0.title } == "Launch checklist")
}
```

The `StateMachineTesting` product drives real owners. It depends only on
`StateMachine` and links no test framework, and a helper that expects an
outcome throws a `StateMachineTestFailure` at the caller's location. No helper
can construct a ticket, an observation, or a completion, so a test exercises the
same authority checks as the app. Its
[documentation](https://kylehughes.github.io/swift-state-machine/documentation/statemachinetesting)
covers scripting a `Local` owner and controlling drivers in detail.

A `ControlledDriver` stands in for an operation's driver in any managed host
whose operation input and output are `Sendable`. Each call suspends until the
test finishes it, so a test orders every step without sleeps:

```swift
import StateMachineTesting
import Testing

@testable import MyApp

@Test func aCancelledSearchShutsDownWithoutItsLateAnswer() async throws {
    let fetch = ControlledDriver<String, String, Never>()
    let lookup = Lookup.Shared(fetchDriver: fetch.run)

    try lookup.send(.search("swift"))
    let call = try await fetch.nextStarted()
    #expect(call.input == "swift")

    try lookup.send(.cancel)
    try await call.waitForCancellation()
    call.succeed("Too late")

    #expect(await lookup.shutdown() == .quiescent)
    guard case .idle = lookup.snapshot() else {
        Issue.record("The late answer replaced the cancelled search")
        return
    }
}
```

Cancelling the search revokes its authority, and `shutdown()` closes admission
and waits for the driver call to return, so this test checks that the cancelled
search ends with nothing applied and nothing running, whether its late answer
reached the owner before closure or after. The `Local` example below delivers a
late answer to an open owner and checks that the owner refuses it as stale.

The same `run` serves fallible operations, operations without input, and
`IsolatedHost` drivers; `KeyedControlledDriver` adds the key to each call and
waits for one key's call with `nextStarted(for:)`. For values that are not
`Sendable`, `MainActorControlledDriver` serves a `MainActorHost`, as
`KeyedMainActorControlledDriver` does for a keyed operation with
`downloadDriver: download.run`, and
`IsolatedControlledDriver<Owner, Input, Output, Failure>` serves an
`IsolatedHost<Owner>`, as `KeyedIsolatedControlledDriver` does for a keyed
operation. The owning actor stores the driver, the driver closure reaches it
through the actor it receives, as in
`saveDriver: { editor, draft in await editor.save.run(editor, draft) }`, and the
test awaits `nextStarted()` on that actor. Each member that reaches a call, such
as `call.input()` and `call.succeed(_:)`, takes the owning actor by default, so
another actor or an ordinary object's destructor cannot finish the call, and the
result stays on the actor, so it may share state with the input. A call ignores
cancellation, as a driver that does not check for it would, so the test decides
when it returns.

`ManualMachineTest` consumes a `Local`, offers its verbs, including `reset()`
when the schema declares a default initial payload, and records every accepted
change with the edge its receipt names. `GraphCoverage(for:)` measures
one owner type, so only runs of that owner count, combines recorded runs, and
reports the edges, routers, and phases that no test exercised.
`requireCoverage(excluding:)` requires every phase, every nonexcluded edge, and
every nonexcluded router with at least one candidate, and fails for an
invariant a run violated. A router without candidates always declines, so no
step can exercise it; `unexercisedRejectingRouters` lists each one that no run
saw the real owner decline through, an input router in a `send` and a
completion router in a `deliver` or `reconcile(id:)` whose own preparation it
refused, and `requireCoverage(includingRejectingRouters: true)` requires them
too. A test that ends a lifetime acknowledges
each execution the owner issued, closes the owner, and drains the closing
batch:

```swift
import StateMachineTesting
import Testing

@testable import MyApp

private func fetches(_ commands: [Lookup.Command]) -> [Lookup.FetchWork] {
    commands.compactMap { command in
        if case .fetch(let work) = command { work } else { nil }
    }
}

@Test func aCancelledSearchIsStaleAndEveryEdgeIsExercised() throws {
    var test = ManualMachineTest(Lookup.Local())
    try test.send(.search("swift"))
    let cancelled = fetches(test.drainFlattenedCommands())
    try test.send(.cancel)
    try test.send(.search("swift"))
    let current = fetches(test.drainFlattenedCommands())

    guard case .stale = test.deliver(.fetch(cancelled[0].succeeded("Old"))),
        case .committed = test.deliver(.fetch(current[0].succeeded("Results")))
    else {
        Issue.record("Delivery did not follow the cancelled search")
        return
    }
    #expect(test.acknowledgeExecution(cancelled[0].execution) == .recorded)
    #expect(test.acknowledgeExecution(current[0].execution) == .recorded)

    try test.send(.search("more"))
    let last = fetches(test.drainFlattenedCommands())
    test.close()
    _ = test.drainFlattenedCommands()
    #expect(test.acknowledgeExecution(last[0].execution, disposition: .skippedBeforeStart) == .recorded)
    let quiescent = test.isQuiescent
    #expect(quiescent)

    var coverage = GraphCoverage(for: Lookup.Local.self)
    coverage.record(test)
    try coverage.requireCoverage()
}
```

Closing revokes the last search, so the close batch cancels it. The test never
ran that search, so it acknowledges the execution as skipped before it started;
work that ran is acknowledged once it has ended. The harness is noncopyable,
and `#expect` copies the base of a bare property read, so
`#expect(test.isQuiescent)` does not compile; read the property into a local
first. The same holds on an actor that owns an `IsolatedHost`: an autoclosure,
such as the argument of `#expect` or the right side of `&&`, is not isolated to
that actor, so the host's `runningCount()`, `subscriberCount()`, and
`isQuiescent()`, and the members of a confined controlled driver's call, do not
compile there. Read each into a local first.

`withOwner(_:)` lends the owner for a member the harness does not offer. The
owner reports no receipt to the harness there, so a change made inside it has no
edge, and when the closure makes several changes the harness sees only the last.
A closure that assigns another owner, even a fresh one at the same revision, is
detected too. Either way the run's history is incomplete, and
`requireInvariants()` and `requireCoverage(excluding:)` fail rather than vouch
for snapshots no one checked. A closure literal does not infer a typed throw, so a throwing closure
passed to it throws `any Error` unless it spells its failure, as in
`{ (owner: inout Lookup.Local) throws(Lookup.SendRejection) in … }`. The
[testing guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/testingagraph)
covers each helper, invariants, keyed drivers, and how to test a presentation.

## Restore saved data

Restoration accepts validated data and creates fresh authority; live tickets,
tasks, and prepared transitions are not persistence formats. A `shared` or
`isolated` schema declares the validation once, with a function marked
`@Restoration`, and every owner except `Owned` gains an `init(restoring:)` that
mirrors its ordinary initializer and a `reset(restoring:)`. This graph restores
a saved `Upload` and rejects a saved empty name:

```swift
@StateMachine(mode: .shared)
nonisolated enum Upload: Sendable {
    struct Idle: Sendable { let name: String }
    struct Running: Sendable { let name: String }
    struct Finished: Sendable {
        let name: String
        let bytes: Int
    }

    @Initial case idle(Idle)
    case running(Running)
    @Terminal case finished(Finished)

    enum Input: Sendable { case start }
    enum RestoreRejection: Error, Sendable { case emptyName }

    @Operation(activeIn: [Running.self])
    enum Transfer {
        typealias Input = String
        typealias Output = Int
    }

    @Restoration
    fileprivate static func restore(_ saved: Self) throws(RestoreRejection) -> Restoration {
        switch saved {
        case .idle(let idle):
            guard !idle.name.isEmpty else { throw .emptyName }
            return .idle(idle)
        case .running(let running):
            guard !running.name.isEmpty else { throw .emptyName }
            return .idle(Idle(name: running.name))
        case .finished(let finished):
            guard !finished.name.isEmpty else { throw .emptyName }
            return .finished(finished)
        }
    }

    @Transition(on: Input.start, starts: [Transfer.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(name: source.name), effects: [.transfer(source.name)])
    }

    @Transition(onSuccess: Transfer.self)
    fileprivate static func received(_ source: Running, _ bytes: Transfer.Output) -> Finished {
        Finished(name: source.name, bytes: bytes)
    }
}

func restoreUploads() {
    let finished = Upload.finished(Upload.Finished(name: "Report", bytes: 2_048))
    if let restored = try? Upload.Local(restoring: finished) {
        print(restored.snapshot())
    }

    do {
        _ = try Upload.Local(restoring: .idle(Upload.Idle(name: "")))
    } catch {
        print("Not restored: \(error)")
    }
}
```

The restored owner starts at revision zero with fresh authority. The generated
`Restoration` return type has one case for each phase in which no operation is
active, so a validator cannot return a phase with running work, and naming one
does not compile. The validator either rejects that saved shape or maps it to a
resting phase, as `restore` does for `.running`, and the caller sends an input
afterward to start fresh work. `@Restoration(allows: [Running.self])` adds a
phase where an operation can be active to the cases the validator may return,
so the owner restores into it with no work outstanding, and
`@Restoration(only: [Idle.self])` names exactly the restorable phases. Forking
is restoring a saved copy of `snapshot.model`. The
[persistence guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/persistence)
covers versioned archives and migration.

## Keep data separate from authority

Model values are ordinary data. Observations carry private provenance, prepared
transitions are noncopyable, and work descriptors carry sealed operation
authority. Constructing a payload cannot mint any of those proofs. The public
`Runtime*` types are support for generated code with no source-stability
promise, and they have a separate, weaker contract. Sealed facades, including
the macro-generated owners, keep their raw storage private.

Shared payloads need semantic value behavior as well as `Sendable`. Actor
confinement does not make a mutable reference into an independent historical
value. Use immutable data, value storage, or detached projections.

## Maintain the package

Run the test suites, external compiler fixtures, macro checks, and formatter:

```sh
python3 Scripts/check-tests.py --configuration debug
python3 Scripts/check-tests.py --configuration release
python3 Scripts/check-tests.py --macro-implementation
python3 Scripts/check-compiler-fixtures.py
python3 Scripts/check-macro-expansions.py --output /tmp/state-machine-expansions
python3 Scripts/check-macro-fixtures.py --output /tmp/state-machine-graph
python3 Scripts/check-macro-fixtures.py --variant sparse-input --output /tmp/state-machine-graph-sparse
python3 Scripts/check-macro-fixtures.py --variant operation-heavy --output /tmp/state-machine-graph-operations
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
```

The macro checks use the existing Debug build. Repeat with
`--configuration release` after building Release, and choose fresh external
output directories for each run.

For Thread Sanitizer or production coverage, give the test helper a separate
`--scratch-path` and select `--sanitize thread` or `--enable-code-coverage`.
Use `--output PATH` to retain the expected and executed test selection, xUnit
results, and coverage export path in a fresh directory.

`Scripts/check-platforms.py` builds and links public calls at the declared
deployment targets; `--interfaces` repeats the consumer check through text
interfaces, and `--device` selects mobile device architectures.
`Scripts/check-ios.py --output PATH` runs an app that imports the public
products on its own Simulator, iOS 17.5 by default, and requires every check
the app reports. `python3 Scripts/docs.py --output PATH` creates a static DocC
site at a fresh output path. These helpers use the installed toolchain and do
not require the software factory. `AGENTS.md` records the maintenance rules in
full.

## Contributions

State Machine is not accepting source contributions at this time.
[Bug reports](https://github.com/kylehughes/swift-state-machine/issues) will be considered.

## Provenance

State Machine was produced with the Swift Package Factory from a specification
supplied by Kyle Hughes.

## "Author"

[Kyle Hughes](https://kylehugh.es)

[![Bluesky](https://img.shields.io/badge/Bluesky-0285FF?logo=bluesky&logoColor=fff)](https://bsky.app/profile/kylehugh.es)<br>
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=fff)](https://www.linkedin.com/in/kyle-hughes)<br>
[![Mastodon](https://img.shields.io/mastodon/follow/109356914477272810?domain=https%3A%2F%2Fmister.computer&style=social)](https://mister.computer/@kyle)

## License

State Machine is available under the [MIT license](LICENSE).
