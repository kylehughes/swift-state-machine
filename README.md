# State Machine

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Test](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml)

State Machine models a workflow as a graph of phases and generates a typed Swift
API for it. The compiler only offers the edges that leave the current phase, and
the runtime only accepts a change from an owner that still has authority to make
it.

Two bugs motivate the design. An asynchronous result can arrive after the user
cancelled or the account changed, and overwrite newer state with stale data. A
value that a transition already consumed can be used a second time. State
Machine closes both: a late result is rejected because the operation that
produced it has lost its authority, and a consumed predecessor cannot be named
again.

## Quick start

This example declares a search with one operation, hosts it on `MainActor` with
a driver, and presents it in SwiftUI:

```swift
import StateMachine
import StateMachineSchema
import StateMachineUI
import SwiftUI

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

@MainActor
func makeLookup() throws -> StateMachinePresentation<Lookup.MainActorHost> {
    try StateMachinePresentation(
        Lookup.MainActorHost(.init(), drivers: .init(fetch: { query in .success("Results for \(query)") }))
    )
}

@MainActor
struct LookupView: View {
    @ObservedObject var lookup: StateMachinePresentation<Lookup.MainActorHost>

    var body: some View {
        switch lookup.snapshot {
        case .idle:
            Button("Search") { _ = try? lookup.send(.search("swift")) }
        case .searching:
            Button("Cancel") { _ = try? lookup.send(.cancel) }
        case .found(let found):
            Text(found.value.answer)
        }
    }
}
```

Create the presentation once, for example in a `@StateObject` or in the object
that owns the feature, and pass it to `LookupView`. Creating it starts no work.
Sending `.search` publishes the `searching` snapshot before `send` returns, then
runs the driver. The driver's result arrives through the host's subscription
and moves the view to `found`.

The schema is the only place the graph is written down, and the compiler
enforces it:

- `begin` can return only `Effect.Begin`, which contains just the operations in
  its `starts:` list. Starting an operation that the edge does not list does not
  compile.
- `Fetch` is active in `Searching`, so the macro requires a success edge from
  `Searching`. Omitting `received` is a compile error.
- `cancel` invalidates `Scope.search`. If the driver returns after that, its
  completion is stale and cannot move the machine to `found`.
- Sending `.cancel` while idle fails with `.preparation(.invalidPhase)`, and the
  snapshot stays unchanged.
- `Idle`, `Searching`, and `Found` are ordinary structs. Constructing one does
  not give anyone authority to change an owner.

`ObservableStateMachinePresentation` is the `@Observable` counterpart for apps
that target iOS 17, macOS 14, or later. It has the same initializer and members.
The [schema guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/declaringagraph)
covers typed rejection, failure edges, routers, and the supported syntax.

### Choose an owner

Each schema generates the owners its mode supports. Most apps use
`MainActorHost`. `Local` and `Owned` are manual owners for callers that run
effects themselves.

| Owner | Use it when | Schema modes |
| --- | --- | --- |
| `MainActorHost` | UI input and admission belong to one MainActor owner, with managed work. | `shared`, `isolated` |
| `ActorHost` | One native actor owns mutation and managed work. | `shared` |
| `Shared` | Independent tasks need synchronous access to one shared owner. | `shared` |
| `Local` | The caller owns a noncopyable value, drains commands, and acknowledges work explicitly. | `shared`, `isolated` |
| `Owned<Phase>` | The caller transfers exclusive ownership through consuming edges and handles effects. | `shared`, `isolated`, `ownedOnly` |

Choose `shared` for concurrent access with checked `Sendable` data, `isolated`
for copyable values that stay within their permitted actor, or `ownedOnly` for
noncopyable resources. Every owner except `Owned` has
`send(_:) throws(SendRejection) -> Receipt`. A rejection is either
`.preparation` (the input has no edge from the current phase, or the edge
declined it) or `.commit` (the owner refused the prepared change). The receipt
carries the accepted `revision` and the snapshot it produced.

`ActorHost` and `MainActorHost` own their state directly, so `send` reads,
prepares, and admits a change in one isolated turn. For asynchronous work, a
driver supplies a `Result` and the host revalidates it when it returns.

The `StateMachineExamples` module holds the examples this guide refers to. Its
`ResourceWorkflow` shows a recoverable resource transition with `Owned`: failure
returns the original owner, and success returns the next owner and every effect
value in order for the caller to handle. Dropping an owner is legal; ownership
does not require completing the workflow.

### Present state on MainActor

`StateMachinePresentation` is an `ObservableObject` that works at the iOS 16
baseline. It wraps a generated `MainActorHost` and exposes `snapshot`,
`isObserving`, `send(_:)`, `close()`, `stopObserving()`, and `host`. A snapshot
accepted by `send` is visible in the same turn as the button's input, and a
delayed observation cannot replace it with an older revision.

The `ProfileEditor` example wraps a `StateMachinePresentation` over a generated
`MainActorHost`. Its load, retry, cancel, and account-change actions use the
same profile graph as the other examples. Disposing the editor removes
observation and closes its work authority. The [UI guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineui/presentingstate)
shows a SwiftUI screen and explains the separate lifetime of a running driver.

#### Observe from UIKit

A UIKit screen can iterate the host's snapshot sequence in a task. The task
inherits `MainActor` from the method that creates it, and cancelling it ends the
sequence and removes the registration. Creating the sequence throws, so the task
catches:

```swift
@MainActor
final class ProfileViewController: UIViewController {
    private let host: GeneratedProfile.MainActorHost
    private var observation: Task<Void, Never>?

    // init(host:) omitted

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observation = Task {
            do {
                for await snapshot in try self.host.snapshots() {
                    self.render(snapshot)
                }
            } catch {
                // Subscriber capacity is exhausted.
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.cancel()
        observation = nil
    }

    private func render(_ snapshot: GeneratedProfile.Snapshot) { /* update views */ }
}
```

A loop sees an accepted input on a later turn. Code that needs the result in the
same turn uses the receipt from `send`, or a presentation.

For Combine, `$snapshot` on `StateMachinePresentation` is the publisher:

```swift
let cancellable = presentation.$snapshot.sink { render($0) }
```

`$snapshot` does not complete. `$isObserving` becoming `false` signals the end.

In a `shared` schema every owner returns the same `Snapshots` type. It works
with `map`, `prefix`, and generic `AsyncSequence` code on every supported OS, and
a `for await` loop over it runs on the caller's actor:

```swift
for await revision in try host.snapshots().map(\.revision) { /* ... */ }
```

In an `isolated` schema, `MainActorHost.snapshots()` returns a
`MainActorSnapshots`, which is iterated on the main actor and carries snapshots
that are not `Sendable`. `for await` works on every supported OS. Operators on
it need a deployment target of iOS 18, macOS 15, tvOS 18, watchOS 11, or
visionOS 2. For an earlier target, project each snapshot to a `Sendable` value;
the result is an ordinary sequence:

```swift
for await revision in try host.snapshots({ $0.revision }).prefix(3) { /* ... */ }
```

## Manage shared state and asynchronous work

`GeneratedProfile` demonstrates a managed `Shared` owner. A driver supplies a
typed result, while the owner controls whether that result still has authority
to change the model. This driver returns an in-memory profile:

```swift
import StateMachineExamples

let user = try UserID("taylor")
let machine = GeneratedProfile.Shared(
    .init(userID: user),
    drivers: .init(
        fetch: { request in
            .success(Profile(userID: request.userID, name: "Taylor"))
        },
        audit: { _ in .failure(.unavailable) }
    )
)
let subscription = try machine.subscribe { snapshot in
    if case .loaded(let loaded) = snapshot {
        print(loaded.value.profile.name)
    }
}

let request = try ProfileRequest(userID: user)
do {
    let receipt = try machine.send(.load(request))
    print("Accepted revision \(receipt.revision)")
} catch .commit(.conflict) {
    print("Another write committed first; read the snapshot and decide again")
} catch {
    print("Load was not accepted: \(error)")
}
```

Retain `machine` and `subscription` for the feature's lifetime. Copies of
`Shared` refer to the same owner. Shared callbacks run outside the storage lock
and are not confined to `MainActor`.

The same snapshots are available as an asynchronous sequence. Creating it
registers one observer, and iterating never throws:

```swift
for await snapshot in try machine.snapshots() {
    if case .loaded(let loaded) = snapshot {
        print(loaded.value.profile.name)
    }
}
```

`ActorHost` uses `try await actor.snapshots()`. Creating a sequence or
subscription throws `SubscriptionFailure.capacityExceeded` when subscriber
capacity is exhausted.

Observation is latest-value for every owner. The sequence keeps one pending
snapshot. The first element is the snapshot current at registration unless a
newer one replaced it, revisions strictly increase, and a slow consumer skips
intermediate snapshots. This is state observation, not an event log. Effects and
execution acknowledgments never coalesce. The closed snapshot is always
delivered before the sequence ends, and a sequence is single-pass: a second
iterator ends immediately. The sequence does not keep the owner alive. If the
owner is released without closing, the sequence ends and no element has
`isClosed == true`.

To show a shared or actor owner on `MainActor`, create a `SnapshotPresentation`
from its current snapshot and observe the sequence:

```swift
@MainActor
func present(_ machine: GeneratedProfile.Shared) throws -> SnapshotPresentation<GeneratedProfile.Snapshot> {
    let presentation = SnapshotPresentation(machine.snapshot())
    presentation.observe(try machine.snapshots())
    return presentation
}
```

The presentation applies each snapshot on `MainActor`, sets `isObserving` to
`false` when the sequence ends, and publishes through `$snapshot`.
`stopObserving()` ends the observation. `MainActorSnapshotIngress` is the
lower-level piece for owners that deliver `Sendable` snapshots through a
callback.

`send` makes exactly one attempt. It prepares the change from the current
snapshot and commits it, and acceptance atomically installs the complete model,
operation authority, and ordered command batch. `Shared` is the only owner where
a competing write can make the attempt fail with `.commit(.conflict)`; the
rejection leaves all three unchanged. The explicit two-step path is also
available: each case of a snapshot holds an `Observed<Phase>`, whose edge
methods return a `Prepared` proposal, and `commit(_:)` returns a `CommitResult`.

### Handle conflicts and capacity explicitly

Managed completion delivery defaults to `manualOnConflict`. A conflict can occur
if another write commits between completion preparation and admission. The owner
retains the first terminal outcome in `pendingCompletions()` with a reconciliation
reason. `reconcile(id:)` authorizes one fresh preparation; a concurrent attempt
reports `inProgress`. Duplicate delivery does not replace the retained outcome.
A completion whose operation no longer has authority, or whose outcome was
already settled, reports `.stale`.

Pass `completionPolicy: .retryPure` to the owner's initializer only when
completion preparation is deterministic and effect-free. It permits reevaluation
against a newer root, with at most four preparations per turn before yielding.
Capture network responses, decoded values, time, and other external inputs once.
The compiler does not prove purity.

An occupied queue or execution bound produces `capacityExceeded`. Managed
delivery retains the prepared candidate and retries admission when capacity
changes, without rerunning preparation. A plan that cannot fit by itself
produces `planTooLarge` and needs an application decision.

### End a lifetime

Call `subscription.cancel()` to unsubscribe. Cancelling the task that consumes
a snapshot sequence ends the sequence and removes its registration; releasing the
sequence does the same. An already claimed callback may finish. Call
`machine.close()` to end admission and revoke work authority;
cancellation remains cooperative. `shutdown()` also waits for actual task
termination and delivery cleanup. On `MainActorHost` and `ActorHost`,
`shutdownAndWait(deadline:)` stops waiting at its deadline and reports whether
the owner settled; the closed owner keeps tracking outstanding work.

`flush(through:)` waits for snapshot offers and effect launch or skip decisions
through an accepted receipt. It does not wait for network completion or observer
callbacks. Retained snapshots and receipts describe history, not reservations
of the current state.

## Run effects yourself with `Local` and `Owned`

`Local` is a noncopyable value with no background runner. After `send` or
`commit` accepts a change, `drainCommands(limit:)` yields whole batches of
commands such as `.fetch(work)`. Finish the mutating access, run the work, then
report two separate obligations: `deliver(work.succeeded(value))` returns the
sealed completion, and `acknowledgeExecution(work.execution, disposition:)`
records that the execution actually ended. `DeliveryResult` includes `.stale`
and `.foreignOwner`; `AcknowledgmentResult` is `.recorded`, `.duplicate`, or
`.foreignOwner`.

`Owned<Phase>` carries no runtime at all. An edge that starts nothing returns
the next `Owned` directly. An edge that starts operations returns a `Change`
with the ordered, inert effects for the caller to run. The
[schema guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/declaringagraph)
has an example of each.

## Keep data separate from authority

Model values are ordinary data. Observations carry private provenance, prepared
transitions are noncopyable, and work descriptors carry sealed operation
authority. Constructing a payload cannot mint any of those proofs. Public raw
runtime types have a separate, weaker contract. Sealed facades, including the
macro-generated owners, keep their raw storage private.

Shared payloads need semantic value behavior as well as `Sendable`. Actor
confinement does not make a mutable reference into an independent historical
value. Use immutable data, value storage, or detached projections.

Restoration accepts validated data and creates fresh authority; live tickets,
tasks, and prepared transitions are not persistence formats. `ReferenceProfile`,
the handwritten form of the profile graph, has a versioned `Archive` that
validates decoded data, migrates its legacy format, and rejects interrupted
loading. See
[Save and restore profile data](https://kylehughes.github.io/swift-state-machine/documentation/statemachineexamples/persistence)
for the format and the distinct restore, reset, and fork lifetimes.

## Install and build

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/kylehughes/swift-state-machine.git", from: "1.0.0")
```

Add the core and schema products to a target that declares a graph:

```swift
.product(name: "StateMachine", package: "swift-state-machine"),
.product(name: "StateMachineSchema", package: "swift-state-machine")
```

Add `StateMachineUI` for SwiftUI presentation and background snapshot ingress.
Add `StateMachineExamples` to use the bundled profile editor, persistence, network,
and resource workflows.

Build with Swift 6.4 in Swift 6 language mode. The selected Apple toolchain is
Xcode 27.1. The package declares these deployment targets:

| Platform | Deployment target |
| --- | --- |
| iOS | 16.0 |
| Mac Catalyst | 16.0 |
| macOS | 13.0 |
| tvOS | 16.0 |
| watchOS | 9.0 |
| visionOS | 1.0 |

See the [API documentation](https://kylehughes.github.io/swift-state-machine/documentation/)
for ownership, raw runtime construction, and the example domains.

### Maintain the package

Run the test suites, external compiler fixtures, and formatter:

```sh
python3 Scripts/check-tests.py --configuration debug
python3 Scripts/check-tests.py --configuration release
python3 Scripts/check-tests.py --macro-implementation
python3 Scripts/check-compiler-fixtures.py
python3 Scripts/check-macro-expansions.py --output /tmp/state-machine-expansions
python3 Scripts/check-macro-fixtures.py --output /tmp/state-machine-graph
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
`python3 Scripts/docs.py --output PATH` creates a static DocC site at a fresh
output path. These helpers use the installed toolchain and do not require the
software factory.

## Contributions

State Machine is not accepting source contributions at this time.
[Bug reports](https://github.com/kylehughes/swift-state-machine/issues) will be considered.

## Provenance

State Machine was produced with the Swift Package Factory from a specification
supplied by Kyle Hughes.

## Author

[Kyle Hughes](https://kylehugh.es)

[![Bluesky](https://img.shields.io/badge/Bluesky-0285FF?logo=bluesky&logoColor=fff)](https://bsky.app/profile/kylehugh.es)<br>
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=fff)](https://www.linkedin.com/in/kyle-hughes)<br>
[![Mastodon](https://img.shields.io/mastodon/follow/109356914477272810?domain=https%3A%2F%2Fmister.computer&style=social)](https://mister.computer/@kyle)

## License

State Machine is available under the [MIT license](LICENSE).
