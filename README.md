# State Machine

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Test](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml)

When a workflow keeps state in mutable properties and launches tasks inline,
callers can trigger invalid actions and late responses can overwrite newer
state. State Machine models a workflow as a typed graph of phases generated
from a single Swift enum. Each phase holds only its own data and exposes only
the transitions declared from it, so calling an edge from the wrong phase fails
to compile. `Owned` values advance only through those consuming phase methods,
while `Local` and managed hosts also accept inputs dynamically through
`send(_:)`, routing against the current phase at run time and rejecting invalid
inputs without changing state.

Transitions stay synchronous and return inert effect descriptions rather than
starting tasks directly. A generated host runs those operations and tracks
operation authority. Whenever a request is cancelled, a scope is invalidated, or
the workflow leaves the phases where an operation is active, a late result is
discarded as stale instead of overwriting newer state.

The package ships three products. `StateMachine` contains the macros and runtime
with no UI dependencies, so the same workflow runs in apps, actors, background
services, and command-line tools. The runtime builds on Apple's `os` module and
targets Apple platforms. `StateMachineUI` presents workflows in SwiftUI and
UIKit, and `StateMachineTesting` drives real owners from tests.

## Installation

Add State Machine to your `Package.swift` dependencies.

```swift
.package(url: "https://github.com/kylehughes/swift-state-machine.git", from: "1.1.1")
```

Add the `StateMachine` product to any target that declares a graph. The macros
ship inside that module, so `import StateMachine` is the only import a schema
needs.

```swift
.product(name: "StateMachine", package: "swift-state-machine")
```

Add `StateMachineUI` to targets that present state in SwiftUI or UIKit, and add
`StateMachineTesting` to test targets. The repository's
`Sources/StateMachineExamples` target contains larger worked examples for tests
and probes, and no product publishes it.

### Requirements

State Machine requires Swift 6.4 in Swift 6 language mode and declares these
deployment targets.

| Platform | Deployment target |
| --- | --- |
| iOS | 16.0 |
| Mac Catalyst | 16.0 |
| macOS | 13.0 |
| tvOS | 16.0 |
| watchOS | 9.0 |
| visionOS | 1.0 |

The Observation APIs, which observe a `MainActorHost` directly and back the
`@Observable` presentations in `StateMachineUI`, require iOS 17, macOS 14,
tvOS 17, watchOS 10, visionOS 1, or Mac Catalyst 17. A snapshot sequence's
iterator provides `next()` at the deployment targets and also provides
`next(isolation:)` on iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, and
Mac Catalyst 18. See the
[API documentation](https://kylehughes.github.io/swift-state-machine/documentation/)
for full symbol references and guides.

### Suggested prompt for a coding agent

```text
Identify implicit state machines in this codebase and make them explicit with kylehughes/swift-state-machine.
```

## A first graph

A schema is a `nonisolated enum` annotated with `@StateMachine(mode:)`. This
example declares a search workflow with one asynchronous `Fetch` operation and
runs it inside a generated actor host.

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
    let receipt = try await lookup.send(.search("swift"))
    print(receipt)

    for await snapshot in snapshots {
        if case .found(let found) = snapshot {
            print(found.value.answer)
            break
        }
    }
    await lookup.shutdown()
}

try await runLookup()
```

Creating `Lookup.ActorHost` starts no work. Sending `.search("swift")` admits
the `searching` phase, returns its receipt, and launches `fetchDriver`.
`runLookup()` prints that receipt, then waits for the host to verify `Fetch`'s
authority, apply `received`, and deliver the `found` snapshot. Running this
file in a Swift executable target prints this output.

```text
searching, revision 1
Results for swift
```

Four guarantees follow directly from the schema.

- **Compile-checked edges and effects.** `begin` returns
  `Change<Searching, Effect.Begin>`, whose effect type contains only operations
  listed in `starts:`. Returning an unlisted effect fails to compile, and
  calling `Lookup.owned().cancel()` on an idle owner fails to compile because
  `cancel` leaves only `Searching`.
- **Separated data and authority.** `Idle`, `Searching`, and `Found` are plain
  value structs, so constructing `Lookup.Found(answer: "...")` grants no
  authority to change a host. Completion edges expose no method on `Observed`,
  so callers cannot bypass the host's own driver delivery.
- **Automatic stale-result rejection.** `Fetch` is active only in `Searching`.
  Sending `.cancel` moves the host to `idle` and revokes `Fetch`'s authority, so
  a late driver completion is discarded as stale.
- **Build-time structural verification.** Because `Fetch` is active in
  `Searching`, omitting `received` fails to compile. Any phase with no outgoing
  edge must carry `@Terminal`, while `found` omits it because `begin` leaves
  both `Idle` and `Found`.

In `Lookup`, `@Initial case idle(Idle = Idle())` gives hosts a default initial
payload while still requiring drivers such as `fetchDriver:`, and
`from: [Idle.self, Found.self]` declares the same edge from both phases without
a source parameter. When several edges share the same source phases, name the
list once with
[`@PhaseSet`](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/phaseset(_:))
on an empty nested enum and pass `from: <Set>.self`; omitted phases stay
unavailable until listed. Multi-source `from:` transitions also accept a single
generic `<Source>` parameter when edges read shared protocol fields or return
`Source` for a same-phase update that retains phase-specific data, and a
candidate `@Transition` selected by `@Route` can declare a final `routed:`
parameter to receive a typed computed value from the router without
recomputation or fallback branches. Omitted `Input` or `Output` aliases default
to `Void`, and omitting `Failure` marks the operation infallible so its driver
returns `Output` directly instead of `Result<Output, Failure>`. Read the
[declaring guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/declaringagraph)
for `@Terminal`, `@PhaseSet`, generic `from:`, routed handoffs (`routed:`),
failure edges, named scopes, reserved names, and the full macro grammar.

## Choose an owner

Each schema generates the owners its mode supports. The four managed hosts run
operation drivers and deliver completions, while `Local` and `Owned` leave
effect execution to the caller.

| Owner | Use it when | Schema modes |
| --- | --- | --- |
| `MainActorHost` | Input and admission belong to the main actor, such as a screen model. | `shared`, `isolated` |
| `ActorHost` | A service or background coordinator keeps state behind its own actor. | `shared` |
| `Shared` | Independent tasks need synchronous access to one shared owner. | `shared` |
| `IsolatedHost<Owner>` | An actor you already own holds the state, calls the host synchronously, and runs its drivers on that actor. | `shared`, `isolated` |
| `Local` | The caller owns a noncopyable value, drains command batches, and acknowledges work explicitly. | `shared`, `isolated` |
| `Owned<Phase>` | The caller transfers exclusive ownership through consuming edges with no runtime. | `shared`, `isolated`, `ownedOnly` |

Choose `.shared` for concurrent access with checked `Sendable` data, `.isolated`
for copyable values confined to one actor, or `.ownedOnly` for noncopyable
resources. To generate only the owners you need and keep other type names free,
list them explicitly as in
`@StateMachine(mode: .shared, owners: [.local, .mainActorHost])`.

### Send an input or commit an edge

Every owner except `Owned` accepts input through `send(_:)`, which routes
against whatever phase the owner currently holds, prepares the change, and
attempts one atomic admission. Acceptance installs the new model, operation
authority, and ordered command batch together, returning a `Receipt` with the
accepted `revision`, `snapshot`, and `edgeID`. `send(_:)` throws
`SendRejection`, reporting a missing route or declined transition as
`.preparation` and a refused commit or defective effect plan as `.commit`.
`Shared` is the only owner where a competing write can cause
`.commit(.conflict)`, while `MainActorHost`, `ActorHost`, and `IsolatedHost`
read, prepare, and admit in one isolated turn. `ActorHost.send(_:)` is `async`,
and `Local.send(_:)` is `mutating`.

Use `send(_:)` when an event should apply to whatever state is current, such as
a timer or push notification. When an action belongs to the exact observation a
caller rendered, prepare it from the snapshot's `Observed<Phase>` value instead.
Each observed phase exposes only the input edges leaving that phase and returns
a noncopyable `Prepared` proposal. Calling `commit(_:)` consumes the proposal
and admits it only if that observation is still the owner's current revision,
returning a non-discardable `CommitResult`.

```swift
@MainActor
func cancel(_ searching: Lookup.Observed<Lookup.Searching>, on host: Lookup.MainActorHost) {
    switch host.commit(searching.cancel()) {
    case .committed:
        print("Cancelled")
    case .rejected(.conflict, let current):
        print("The search changed first: \(current)")
    case .rejected(let reason, _):
        print("Cancel was not accepted: \(reason)")
    }
}
```

The compiler checks the observed call, so removing `cancel` or moving it to
another phase stops this function from compiling. An edge that cannot fail needs
no `try`, and an edge with typed throws propagates that exact failure. When a
`@Route` function chooses among several edges for one phase and input, `Observed`
exposes one method named after the router and hides the candidate edges so
routing rules cannot be bypassed. Read the
[hosting guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/hostingagraph)
for full details on creating and driving each host, including confining an
`IsolatedHost` to an actor you own and sharing an executor with
`ActorHost(..., isolatedTo:)`.

## Run operations

Managed hosts take one required driver closure per operation, labeled with the
operation's effect case and `Driver` (such as `fetchDriver:`), or a single
`drivers:` bundle (`Drivers`, `MainActorDrivers`, or
`IsolatedHost<Owner>.Drivers`). Drivers for `Shared` and `ActorHost` are
`@Sendable`, drivers for `MainActorHost` run on the main actor, and drivers for
`IsolatedHost` receive their owning actor isolated as their first argument so
they can access actor state without capturing `self` in a retain cycle.
Cancellation is cooperative. When an edge revokes an operation's authority, the
host cancels the driver's task and launches any replacement right away, so a
driver that ignores cancellation runs to completion before the host discards its
stale result. When synchronous work such as Core Graphics rendering or Vision
detection must not overlap in memory while new inputs still commit immediately,
drive a `Local` owner using
[Serialize uncooperative work on Local](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/runningeffectsyourself#Serialize-uncooperative-work-on-Local)
and its tested example in
[`Sources/StateMachineExamples/SerializedPipeline.swift`](Sources/StateMachineExamples/SerializedPipeline.swift).

Operations, scopes, keys, and events control concurrency, cancellation
boundaries, and side-effect announcements.

- **Admission policies.** An operation defaults to `.latest`, which replaces
  older work in its group. `.rejectWhenActive` rejects the entire transition
  while earlier work is active, and `.parallel(limit:)` admits up to `limit`
  concurrent executions.
- **Named scopes.** Cases of a nested `enum Scope`, annotated with `@Active(in:)`
  (or active in all phases without it), let multiple operations share authority
  through `scope:` and `requires:`. Listing a scope in an edge's `invalidates:`
  revokes every operation holding it without leaving the current phase.
- **Keyed operations and requests.** Adding `typealias Key` runs independent
  work per key and applies admission policies per key. Edges listing the
  operation in `cancels:` can cancel one key or all keys, and completion edges
  can accept the generated `<Operation>Request` as a final `request:` parameter
  holding the key and input captured at start.
- **Events.** An `@Event` enum with an optional `Payload` alias models an inert
  announcement listed in an edge's `emits:`. Events have no driver, result, or
  authority. Managed hosts take a required `on<Event>:` handler and call it once
  per emission in commit order during post-commit batch draining, outside every
  lock (never guaranteed before `send` returns). Inspect the returned `Receipt`
  for synchronous post-commit work (on `Shared`, the receipt captures that exact
  commit even if another writer advances `snapshot()` next), or
  `await flush(through: receipt)` to wait for event handlers to return.

### Completion policy

Another write can commit between a completion's preparation and its admission. A
managed host settles that race using its `completionPolicy:` (`.retry`,
`.retry(onReconciliationRequired:)`, `.manual`, or
`.manual(onReconciliationRequired:)`). `.retry` prepares the completion again up
to a bounded budget before requiring reconciliation, and is the default unless a
completion can refuse its outcome (through a throwing completion edge or router,
or a bounded admission policy), in which case you choose explicitly.

Every edge and router must be deterministic and free of side effects under any
policy because `.retry` and explicit `reconcile(id:)` prepare completions again
against newer state. Capture network responses, decoded values, timestamps, and
other external inputs before they reach an edge. The compiler cannot verify
purity.

When a completion cannot commit, the owner retains its first terminal outcome
until it is settled, and duplicate deliveries never replace it. Inspect retained
completions with `pendingCompletions()` or `pendingCompletionUpdates()`, and
settle each with `reconcile(id:)` or `discardPending(id:)`. Capacity retries
reuse the already prepared candidate when queue or execution space frees up
without running preparation again.

### End a lifetime

To start over while keeping owner identity and subscribers, call `reset(to:)`
(or `reset(to:expecting:)` to fail with `.conflict` if the owner moved past a
reviewed snapshot). Resetting revokes all active work and drops retained
completions. Call `close()` to end admission and revoke authority synchronously,
`flush(through:)` to wait for launch and cancellation decisions through a
receipt, or `shutdown(deadline:)` to close the host and wait for driver
termination and delivery cleanup, returning `.quiescent` or
`.timedOut(ShutdownDiagnostics)`. The
[hosting guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/hostingagraph)
covers completion reconciliation, reset, and shutdown diagnostics in full.

## Run effects yourself with `Local` and `Owned`

`Local` is a noncopyable value with no background runner or subscription
surface. Its methods are synchronous and `mutating`. Accepted changes that start
or cancel work, emit events, or close the owner queue whole command batches for
`drainCommands(limit:)`. Plain state changes queue nothing and return their
receipt directly from `send` or `commit`. Finish mutating access before running
drained work, build sealed completions with `work.succeeded(_:)` or
`work.failed(_:)`, pass them to `deliver(_:)`, and record task termination
separately with `acknowledgeExecution(_:disposition:)`.

`Owned<Phase>` carries no runtime at all. Dropping an owner is valid and does
not require completing the workflow. Consuming an edge returns the next `Owned`
directly when no effects or failures are declared, a `Change` carrying ordered
inert effects when operations or events are declared, or an `Advance` that
returns the original owner alongside a typed failure on rejection. Use
`withValue` to borrow the payload or `takeValue()` to consume the owner and
extract it. Read the
[guide to running effects yourself](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/runningeffectsyourself)
for complete `Owned` and `Local` walkthroughs, including
[serializing uncooperative work on `Local`](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/runningeffectsyourself#Serialize-uncooperative-work-on-Local).

## Rely on graph checks

The macro checks the declared graph structure on every build and diagnoses each
violation at the declaration at fault. It rejects schemas containing any of
these defects.

- A phase unreachable from the initial phase or from a phase that `@Restoration`
  can restore.
- A phase with no outgoing edge that lacks `@Terminal`, or a `@Terminal` phase
  with an outgoing edge or an active operation.
- An operation that no reachable edge starts.
- An operation whose success (or failure, when fallible) is never accepted in
  any phase where it can be active.
- A completion edge or router that no path reaches while its operation still has
  work outstanding.

A self-loop counts as an outgoing edge. Because the checks inspect declared
structure only and cannot evaluate runtime throws or router branches, passing
them proves a declared path exists rather than guaranteeing that a given run
will take it. See the
[declaring guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/declaringagraph)
for the complete diagnostic table and macro limits.

## Export the graph

Every schema exposes a static `graph` property of type `StateMachineGraph`, a
`Sendable`, `Hashable`, and `Codable` value holding the declared phases,
inputs, scopes, operations, events, edges, and routers in declaration order. It
stores names and authored type spellings with no payloads or authority.

`graph.mermaid()` and `graph.dot()` render Mermaid and Graphviz text directly
from the schema. Calling `print(Lookup.graph.mermaid())` outputs this diagram.

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

Read the
[export guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/exportingagraph)
for DOT output and programmatic graph inspection.

## Observe state

Snapshots are complete, immutable records with strictly increasing revisions.
Managed hosts publish them through Observation on `MainActorHost`, asynchronous
sequences, callbacks, Combine, and `StateMachineUI` presentations. Slow
consumers skip intermediate snapshots to receive the latest revision, while
effects and execution acknowledgments never coalesce.

### Observation and SwiftUI

On iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, and Mac Catalyst 17 and
later, a generated `MainActorHost` conforms to `Observable`. SwiftUI views can
read it directly. `currentSnapshot`, `runningCount`, `subscriberCount`, and
`pendingCompletions()` track independently, and Observation takes no subscriber
slot.

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

Creating the host starts no work. Sending `.search` updates `currentSnapshot`
before `send` returns, then runs the driver and moves the view to `found`. For
SwiftUI `#Preview` blocks in the same module as a schema on Swift 6.4, construct
`MainActorHost` in a `@MainActor` factory helper outside `#Preview` or import
the schema from a separate module. See the
[hosting guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/hostingagraph#SwiftUI-Preview-macros-in-the-same-module).

Choose among the other observation APIs based on platform target and isolation.

- **Sequences and callbacks.** `snapshots()`, `snapshots(_:)`,
  `distinctSnapshots(_:)`, and `subscribe(_:onFinish:)` each claim one
  subscriber slot when called and release it when ended or cancelled with
  `cancel()`. `SnapshotSequence.wait(...)` awaits a condition with an optional
  deadline and frees its subscriber slot on every exit path. In an `.isolated`
  schema, `snapshots()` returns a noncopyable actor-confined stream read with
  `next()`, while `snapshots(_:)` projects `Sendable` values into a
  `SnapshotSequence` for `for await` and sequence operators.
- **Combine.** `snapshotPublisher()` and `snapshotPublisher(_:)` deliver
  `Sendable` values on the main actor, claim one subscriber slot on creation,
  and accept one subscriber. `IsolatedHost` omits publishers because Combine
  cannot be confined to an arbitrary actor, and subscription types use
  `SnapshotSubscription`-prefixed names so importing Combine leaves
  `Subscription` unambiguous.
- **SwiftUI and UIKit presentations (`StateMachineUI`).**
  `StateMachinePresentation` (`@Observable`, iOS 17+) and
  `StateMachineObservableObject` (`ObservableObject`, iOS 16+ baseline, with
  `presentedSnapshots` Combine publishers) drive a `MainActorHost` without
  throwing at initialization. `SnapshotPresentation` and
  `SnapshotObservableObject` passively observe any managed host. UIKit view
  controllers can bind presentations or iterate `snapshots()` in a main-actor
  `Task`, calling `cancel()` before replacing an observation or disappearing.

Read the
[observation guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/observingstate)
for subscriber budgeting and teardown semantics, and read the
[UI guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineui/presentingstate)
for complete SwiftUI and UIKit screens.

## Test a graph

`StateMachineTesting` depends only on `StateMachine` and links no test
framework, so it works with both Swift Testing and XCTest. Its helpers drive
real owners and never construct tickets, observations, proposals, or
completions, ensuring tests run through the same authority checks as production
code.

`ControlledDriver` stands in for an operation's driver on any managed host with
`Sendable` inputs and outputs. Each call suspends until the test finishes it, so
tests verify races and cancellation deterministically without sleeps.

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

Use the matching helper for each layer you want to verify.

- **Pure edge tests.** Call methods on `Owned` values directly with no runtime
  or host setup.
- **Keyed and actor-confined controlled drivers.** Use `KeyedControlledDriver`,
  `MainActorControlledDriver`, `KeyedMainActorControlledDriver`,
  `IsolatedControlledDriver`, and `KeyedIsolatedControlledDriver` for keyed
  operations or non-`Sendable` values.
- **Synchronous scripting and graph coverage.** `ManualMachineTest` drives a
  `Local` owner synchronously, records every accepted step, and checks snapshot
  invariants. `GraphCoverage` combines runs of one owner type to report any
  declared phases, edges, or routers that tests did not exercise.

See the
[testing guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/testingagraph),
[controlling drivers](https://kylehughes.github.io/swift-state-machine/documentation/statemachinetesting/controllingdrivers),
and
[scripting a Local owner](https://kylehughes.github.io/swift-state-machine/documentation/statemachinetesting/scriptingalocalowner).

## Restore saved data

Saved data consists of ordinary values and never carries live tickets, tasks, or
prepared transitions. Declaring one `@Restoration` validator on a `.shared` or
`.isolated` schema adds `init(restoring:)`, `reset(restoring:)`, and
`reset(restoring:expecting:)` to every generated owner except `Owned`.
`init(restoring:)` creates a new owner at revision zero with fresh authority and
no running work. `reset(restoring:)` replaces an existing owner's model in a
fresh incarnation while keeping its identity and subscribers, revoking active
operations, dropping retained completions, and advancing its revision.

The generated `Restoration` return enum includes only phases where no operation
can be active, so returning a phase with running work fails to compile unless
you opt it in with `@Restoration(allows:)` or fix the exact list with
`@Restoration(only:)`. Forking an owner restores a saved copy of
`snapshot.model`. See the
[persistence guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/persistence)
for versioned archives, migration, and restoration examples.

## Keep data separate from authority

Model values are ordinary data. Observations carry private provenance, prepared
transitions are noncopyable, and work descriptors carry sealed operation
authority. Constructing a payload never mints any of those proofs. Sealed
facades, including macro-generated owners, keep their raw storage private. The
public `Runtime*` types exist to support generated code, carry no
source-stability promise, and expose a weaker contract.

Shared and actor-confined payloads require semantic value behavior in addition
to `Sendable` or actor isolation. Actor confinement prevents cross-thread data
races, yet a mutable reference type still aliases across historical snapshots.
Store immutable data, value types, or detached projections. Read
[data, ownership, and observations](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/ownership)
and
[constructing a runtime behind a facade](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/runtimeconstruction)
for the complete trust boundary.

## Documentation

All three products publish DocC guides and API references on the
[documentation site](https://kylehughes.github.io/swift-state-machine/documentation/).

- [`StateMachine`](https://kylehughes.github.io/swift-state-machine/documentation/statemachine) covers declaring, hosting, observing, persisting, exporting, and testing graphs.
- [`StateMachineUI`](https://kylehughes.github.io/swift-state-machine/documentation/statemachineui) covers SwiftUI and UIKit presentations.
- [`StateMachineTesting`](https://kylehughes.github.io/swift-state-machine/documentation/statemachinetesting) covers controlled drivers, scripted `Local` tests, and graph coverage.
- [Worked examples](https://kylehughes.github.io/swift-state-machine/documentation/statemachine/examples) lists the larger workflows in `Sources/StateMachineExamples`.

## Maintain the package

Run the test suites, external compiler fixtures, macro checks, and formatter
from the repository root.

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

The macro checks use the existing Debug build. Repeat them with
`--configuration release` after building Release, and choose fresh external
output directories for each run.

For Thread Sanitizer or production coverage, pass a separate `--scratch-path` to
`Scripts/check-tests.py` along with `--sanitize thread` or
`--enable-code-coverage`. Use `--output PATH` to retain the expected and
executed test selection, xUnit results, and coverage export path in a fresh
directory.

`Scripts/check-platforms.py` builds and links public calls at the declared
deployment targets, with `--interfaces` repeating the consumer check through
text interfaces and `--device` selecting mobile device architectures.
`Scripts/check-ios.py --output PATH` runs a smoke app importing the public
products on its own Simulator (iOS 17.5 by default) and requires every check the
app reports. `python3 Scripts/docs.py --output PATH` builds the static DocC site
at a fresh output path. These helpers use the installed toolchain and do not
require the software factory. [`AGENTS.md`](AGENTS.md) records the full
maintenance rules.

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
