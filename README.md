# State Machine

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Test](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml)

State Machine models a workflow as a graph of phases and generates a typed Swift
API for it. The compiler only offers the edges declared for the current phase,
and an owner only admits a change that was prepared from its current revision. A
completion is admitted only while its operation still has authority.

Two bugs motivate the design. An asynchronous result can arrive after a request
was cancelled or the account changed, and overwrite newer state with stale data.
A value that a transition already consumed can be used a second time. State
Machine closes both: a late result is rejected because the operation that
produced it has lost its authority, and a consumed predecessor cannot be named
again.

The core `StateMachine` and `StateMachineSchema` modules have no UI
dependencies. The same generated workflow runs in services, actors, background
work, command-line tools, and server code, or drives a screen through the
optional `StateMachineUI` module.

## Install

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

## Quick start

A schema is a `nonisolated enum` that declares a graph of phases and the edges
between them. This graph has one legal transition, from a draft to an approved
value:

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

`Approval.owned(_:)` creates an owner in the initial phase. `approve` takes a
`Draft` and returns an `Approved`, so the macro derives an edge from the `draft`
phase to the `approved` phase, with `Input.approve` as its trigger. The generated
`Owned<Draft>` has `approve`, and `Owned<Approved>` does not, so calling the edge
twice or in the wrong phase does not compile. Calling it consumes the draft
owner. `Draft` and `Approved` are ordinary structs: constructing one gives no
one authority to change an owner.

To keep the state where other code can read and observe it, host the same graph.
A graph with no operations needs no drivers:

```swift
@MainActor
func approveInHost() throws {
    let host = Approval.MainActorHost(.init(title: "Launch checklist"))
    let receipt = try host.send(.approve)
    print(receipt)
}
```

`send` routes `Input.approve` to the edge, admits it, and returns a receipt.
Printing a receipt shows the phase and revision, here `approved, revision 1`,
and never the payload.

## Add asynchronous work

An operation is work that the host runs and whose result returns through a
completion edge. This example declares a search workflow with one operation and
runs it in a generated actor host:

```swift
import StateMachine
import StateMachineSchema

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

func runLookup() async throws {
    let lookup = Lookup.ActorHost(
        .init(),
        drivers: .init(fetch: { query in .success("Results for \(query)") })
    )
    let snapshots = try await lookup.snapshots()
    _ = try await lookup.send(.search("swift"))

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
- `Idle`, `Searching`, and `Found` are ordinary structs. Constructing one does
  not give anyone authority to change an owner.

The [schema guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/declaringagraph)
covers typed rejection, failure edges, routers, and the supported syntax.

## Choose an owner

Each schema generates the owners its mode supports. `ActorHost`, `Shared`, and
`MainActorHost` run operation drivers and manage completion delivery; `Local`
and `Owned` are manual owners for callers that run effects themselves.

| Owner | Use it when | Schema modes |
| --- | --- | --- |
| `ActorHost` | One native actor owns mutation and managed work in a service or background coordinator. | `shared` |
| `Shared` | Independent tasks need synchronous access to one shared owner. | `shared` |
| `MainActorHost` | Input and admission belong to one `MainActor` owner, such as a screen's model, with managed work. | `shared`, `isolated` |
| `Local` | The caller owns a noncopyable value, drains commands, and acknowledges work explicitly. | `shared`, `isolated` |
| `Owned<Phase>` | The caller transfers exclusive ownership through consuming edges and handles effects. | `shared`, `isolated`, `ownedOnly` |

Choose `shared` for concurrent access with checked `Sendable` data, `isolated`
for copyable values that stay within their permitted actor, or `ownedOnly` for
noncopyable resources. Every owner except `Owned` accepts input through
`send(_:)`, which returns a `Receipt` or throws `SendRejection`.
`ActorHost.send(_:)` is `async`, and `Local.send(_:)` is `mutating`. A
`.preparation` rejection covers an invalid phase, a router or edge that declines
the input, or a rejected effect plan. A `.commit` rejection means the owner
refused the prepared change. The receipt carries the accepted `revision` and the
snapshot it produced.

`ActorHost` and `MainActorHost` own their state directly, so `send` reads,
prepares, and admits a change in one isolated turn. For asynchronous work, a
driver supplies a `Result` and the host revalidates it when it returns.

The `StateMachineExamples` module holds the examples this guide refers to. Its
`ResourceWorkflow` shows a recoverable resource transition with `Owned`: failure
returns the original owner, and success returns the next owner and every effect
value in order for the caller to handle. Dropping an owner is legal; ownership
does not require completing the workflow.

### Send an input or commit an edge

`send` makes exactly one attempt. It routes the input against whatever the owner
currently holds, prepares the change from the current snapshot, and commits it.
Acceptance atomically installs the complete model, operation authority, and
ordered command batch. `Shared` is the only owner where a competing write can
make the attempt fail with `.commit(.conflict)`; the rejection leaves all three
unchanged. Use `send` for an event that should act on the current state: a timer,
a push notification, or a tap that means "cancel the current search".

Each case of a snapshot holds an `Observed<Phase>`. Its methods are the edges
whose source is that phase, and each returns a `Prepared` proposal. An owner's
`commit(_:)` admits the proposal only if that observation is still the owner's
current revision, and returns a `CommitResult`: `.committed(receipt)` or
`.rejected(reason, current:)`. The result is not discardable. Use this path when
the action belongs to the exact observation the user saw, and handle `.conflict`
if an intervening commit advances the same open owner. Closing the owner takes
precedence and produces `.closed`.

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

The compiler checks the call. If an edge is removed or moves to another phase, a
view that calls it stops compiling, whereas `send(.cancel)` routes at run time
and fails with `.preparation(.invalidPhase)`. An edge prepared this way skips the
schema's routers, so a rule that every caller must obey belongs in the edge or in
a validated argument type. `commit(_:)` is `async` on `ActorHost`, `mutating` on
`Local`, and also available on the presentations in `StateMachineUI`.

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

Each managed owner's snapshot sequence keeps one pending value. The first value
is the snapshot current at registration or a later revision. Revisions strictly
increase, and slow consumers can skip intermediate snapshots. Effects and
execution acknowledgments never coalesce. If closing the owner ends iteration,
the final element is the closed snapshot. Cancelling iteration can end it
earlier. A second iterator ends immediately. The sequence does not keep the
owner alive. If the owner is released without closing, the sequence ends without
a closed snapshot.

### Handle conflicts and capacity explicitly

Managed completion delivery defaults to `manualOnConflict`. A conflict can occur
if another write commits between completion preparation and admission. The owner
retains the first terminal outcome in `pendingCompletions()` with a
reconciliation reason. `reconcile(id:)` authorizes one fresh preparation; a
concurrent attempt reports `inProgress`. Duplicate delivery does not replace the
retained outcome. For a completion issued by the receiving owner, `deliver(_:)`
reports `.stale` if the operation has lost its authority or its outcome has
already settled.

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

Call `subscription.cancel()` to unsubscribe. Cancelling the consuming task ends
iteration and removes the registration. Releasing the sequence and its iterator
also removes the registration. An already claimed callback may finish. Call
`machine.close()` to end admission and revoke work authority; cancellation
remains cooperative. `shutdown()` also waits for actual task termination and
delivery cleanup. On `MainActorHost`, `ActorHost`, and `Shared`,
`shutdownAndWait(deadline:)` returns `.quiescent` once the owner has settled, or
`.timedOut` with `ShutdownDiagnostics` when the deadline passes first; the
closed owner keeps tracking the outstanding work the diagnostics describe.
Releasing an owner without closing it finishes its retained registrations
without a closed snapshot.

`flush(through:)` waits for snapshot offers and effect launch or skip decisions
through an accepted receipt. It does not wait for network completion or observer
callbacks. `ActorHost` and `MainActorHost` process a batch's start commands and
advance the revision tracked by `flush(through:)` before invoking that batch's
observer callbacks. A synchronous `MainActor` callback can delay a driver on the
same actor. Retained snapshots and receipts describe history, not reservations
of the current state.

## Run effects yourself with `Local` and `Owned`

`Local` is a noncopyable value with no background runner. After `send` or
`commit` accepts a change, `drainCommands(limit:)` yields whole batches of
commands such as `.fetch(work)`. Finish the mutating access before running the
work. `work.succeeded(value)` builds a sealed completion. Pass it to
`deliver(_:)` to get a `DeliveryResult`. Call
`acknowledgeExecution(work.execution, disposition:)` separately to record that
execution ended. `DeliveryResult` includes `.stale` and `.foreignOwner`;
`AcknowledgmentResult` is `.recorded`, `.duplicate`, or `.foreignOwner`.

Draining and acknowledging never change the model. If capacity blocks an
otherwise admissible completion, `Local` retains its candidate as
`.pending(id, .waitingForCapacity)`. After freeing capacity, call
`retryAdmission(id:)` to recheck that candidate without preparing it again. An
intervening revision requires reconciliation if the operation is still active.

`Owned<Phase>` carries no runtime at all. If the authored edge returns the
destination payload without throwing, its `Owned` method returns the next owner
directly. If it returns `Change` without throwing, the method returns a `Change`
with the next owner and ordered, inert effects. A typed-throwing edge or one
declared to return `Advance` gives the caller an `Advance`. Each effect's
`effect` property widens it to the schema-wide `Effect`. The
[schema guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/declaringagraph)
has an example of each.

## Present state on MainActor

The optional `StateMachineUI` module adapts owners for SwiftUI and UIKit.
`ObservableStateMachinePresentation` wraps a generated `MainActorHost` as an
`@Observable` model and exposes `snapshot`, `isObserving`, `send(_:)`,
`commit(_:)`, `close()`, `stopObserving()`, and `host`. It requires iOS 17, Mac
Catalyst 17, macOS 14, tvOS 17, watchOS 10, or visionOS 1.

This example presents the `Lookup` workflow from earlier in SwiftUI:

```swift
import StateMachine
import StateMachineUI
import SwiftUI

@MainActor
func makeLookup() throws -> ObservableStateMachinePresentation<Lookup.MainActorHost> {
    try ObservableStateMachinePresentation(
        Lookup.MainActorHost(.init(), drivers: .init(fetch: { query in .success("Results for \(query)") }))
    )
}

@MainActor
struct LookupView: View {
    let lookup: ObservableStateMachinePresentation<Lookup.MainActorHost>

    var body: some View {
        switch lookup.snapshot {
        case .idle:
            Button("Search") { _ = try? lookup.send(.search("swift")) }
        case .searching(let searching):
            ProgressView("Searching for \(searching.value.query)")
            Button("Cancel", role: .cancel) { _ = try? lookup.send(.cancel) }
        case .found(let found):
            Text(found.value.answer)
        }
    }
}
```

Create the presentation once, for example in `@State` or in the model that owns
the feature, and pass it to `LookupView`. Creating it starts no work. Sending
`.search` publishes the `searching` snapshot in the same turn before `send`
returns, then runs the driver. The driver's result arrives through the host's
subscription and moves the view to `found`, and a delayed observation cannot
replace a newer revision.

`StateMachinePresentation` is the `ObservableObject` counterpart that works at
the iOS 16 and macOS 13 baseline with `@StateObject` and `@ObservedObject`. It
has the same initializer and members.

The `ProfileEditor` example wraps a `StateMachinePresentation` over a generated
`MainActorHost`. Its load, retry, cancel, and account-change actions use the
same profile graph as the other examples. Disposing the editor removes
observation and closes its work authority. The
[UI guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineui/presentingstate)
shows a SwiftUI screen, commits an edge of the snapshot that the view rendered,
and explains the separate lifetime of a running driver.

To show a shared or actor owner on `MainActor`, create an
`ObservableSnapshotPresentation` from its current snapshot, as in
`ObservableSnapshotPresentation(machine.snapshot())`, and follow the owner's
sequence from the view's task:

```swift
@MainActor
struct ProfileName: View {
    let machine: GeneratedProfile.Shared
    let profile: ObservableSnapshotPresentation<GeneratedProfile.Snapshot>

    var body: some View {
        Group {
            if case .loaded(let loaded) = profile.snapshot {
                Text(loaded.value.profile.name)
            } else {
                ProgressView()
            }
        }
        .task {
            guard let snapshots = try? machine.snapshots() else { return }
            await profile.follow(snapshots)
        }
    }
}
```

`follow(_:)` applies snapshots with increasing revisions on `MainActor`. It
returns when the sequence ends, the calling task is cancelled, or the
presentation stops or replaces the observation. SwiftUI cancels the view's task
when the view disappears. `observe(_:)` starts the same observation in a task
the presentation owns, until `stopObserving()`. `isObserving` becomes `false`
when the sequence ends. `SnapshotPresentation` is the `ObservableObject`
counterpart for the iOS 16 and macOS 13 baseline, with the same members and
`$snapshot` as its publisher. `MainActorSnapshotIngress` is the lower-level
piece for owners that deliver `Sendable` snapshots through a callback.

### Observe from UIKit

A UIKit screen can iterate the host's snapshot sequence in a task. The task
inherits `MainActor` from the method that creates it, and cancelling it ends the
sequence and removes the registration. Creating the sequence throws, so the task
catches. `UIContentUnavailableConfiguration` requires iOS 17, tvOS 17, Mac
Catalyst 17, or visionOS 1:

```swift
import StateMachine
import StateMachineExamples
import UIKit

@MainActor
final class ProfileViewController: UIViewController {
    private let host: GeneratedProfile.MainActorHost
    private var observation: Task<Void, Never>?
    private let nameLabel = UILabel()

    // init(host:) and view layout omitted

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        observation?.cancel()
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

    private func render(_ snapshot: GeneratedProfile.Snapshot) {
        switch snapshot {
        case .idle:
            nameLabel.text = nil
            contentUnavailableConfiguration = nil
        case .loading:
            nameLabel.text = nil
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .loaded(let loaded):
            nameLabel.text = loaded.value.profile.name
            contentUnavailableConfiguration = nil
        case .failed(let failed):
            nameLabel.text = nil
            var unavailable = UIContentUnavailableConfiguration.empty()
            unavailable.text = "Profile Unavailable"
            unavailable.secondaryText = failed.value.failure.rawValue
            unavailable.button = .plain()
            unavailable.buttonProperties.primaryAction = UIAction(title: "Retry") { [weak self] _ in
                _ = try? self?.host.send(.retry)
            }
            contentUnavailableConfiguration = unavailable
        }
    }
}
```

A loop sees an accepted input on a later turn. Code that needs the result in the
same turn uses the receipt from `send`, or a presentation.

For Combine, `$snapshot` on `StateMachinePresentation` or `SnapshotPresentation`
is the publisher:

```swift
let cancellable = presentation.$snapshot.sink { render($0) }
```

`$snapshot` does not complete. `$isObserving` becoming `false` signals the end.

In a `shared` schema, `MainActorHost`, `ActorHost`, and `Shared` return the same
`Snapshots` type. It works with `map`, `prefix`, and generic `AsyncSequence`
code on every supported OS, and a `for await` loop over it runs on the caller's
actor:

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

## Keep data separate from authority

Model values are ordinary data. Observations carry private provenance, prepared
transitions are noncopyable, and work descriptors carry sealed operation
authority. Constructing a payload cannot mint any of those proofs. Public raw
runtime types have a separate, weaker contract. Sealed facades, including the
macro-generated owners, keep their raw storage private.

Shared payloads need semantic value behavior as well as `Sendable`. Actor
confinement does not make a mutable reference into an independent historical
value. Use immutable data, value storage, or detached projections.

### Restore saved data

Restoration accepts validated data and creates fresh authority; live tickets,
tasks, and prepared transitions are not persistence formats. A `shared` or
`isolated` schema declares the validation once, with a function marked
`@Restoration`, and every owner except `Owned` gains an `init(restoring:)` that
mirrors its ordinary initializer. `GeneratedProfile` restores a saved `Archive`
and rejects a saved interrupted load:

```swift
let profile = Profile(userID: user, name: "Taylor")
let restored = try GeneratedProfile.Local(restoring: .loaded(profile))
print(restored.snapshot())

do {
    _ = try GeneratedProfile.Local(restoring: .loading(request))
} catch {
    print("Not restored: \(error)")
}
```

The restored owner starts at revision zero with fresh authority. The generated
`Restoration` return type has one case for each phase in which no operation is
active, so a validator cannot return a phase with running work, and naming one
does not compile. The validator either rejects that saved shape, as
`GeneratedProfile` does for `.loading`, or maps it to a resting phase, and the
caller sends an input afterward to start fresh work. Forking is restoring a
saved copy of `snapshot.model`. The
[schema guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/declaringagraph)
declares a validator and forks an owner.

`ReferenceProfile`, the handwritten form of the profile graph, is the fuller
example. Its versioned `Archive` validates decoded data, migrates its legacy
format, and rejects interrupted loading. See
[Save and restore profile data](https://kylehughes.github.io/swift-state-machine/documentation/statemachineexamples/persistence)
for both forms and the distinct restore, reset, and fork lifetimes.

## Test a graph

Test an edge as a function, a rule through `Local`, and hosted behavior through
stub drivers. `Owned` runs an edge with no runtime, so its tests are plain
assertions:

```swift
import Testing

@testable import Approvals

@Test func approvingADraftReachesApproved() {
    let approved = Approval.owned(.init(title: "Launch checklist")).approve()

    #expect(approved.withValue { $0.title } == "Launch checklist")
}
```

`Local` runs routing, completion delivery, and cancellation synchronously, so a
test drains the commands, delivers a result, and asserts that a late result is
stale without waiting for a task. A hosted test holds each stub driver at a gate
and asserts on receipts or on the snapshot sequence. The
[testing guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/testingagraph)
shows each of these, how to compare models and effects, how to test a
presentation against a test double, and why a call into the wrong phase never
reaches a test.

## Maintain the package

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

## "Author"

[Kyle Hughes](https://kylehugh.es)

[![Bluesky](https://img.shields.io/badge/Bluesky-0285FF?logo=bluesky&logoColor=fff)](https://bsky.app/profile/kylehugh.es)<br>
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=fff)](https://www.linkedin.com/in/kyle-hughes)<br>
[![Mastodon](https://img.shields.io/mastodon/follow/109356914477272810?domain=https%3A%2F%2Fmister.computer&style=social)](https://mister.computer/@kyle)

## License

State Machine is available under the [MIT license](LICENSE).
