# State Machine

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2Fswift-state-machine%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/swift-state-machine)
[![Test](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/swift-state-machine/actions/workflows/ci.yml)

Declare a state graph once and generate its typed Swift API. Phase types
determine which edges a caller can take. Consuming ownership prevents reuse of
a predecessor; hosted transitions check identity and freshness before accepting
a prepared change.

## Quick start

Define phase data and an ordinary transition function inside a schema:

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
    enum Effect: Sendable {}

    @Transition(on: Input.approve)
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

approveDraft()
```

Nothing in the schema is named by a string. `@Initial` marks the starting
phase, the edge's source and destination are the payload types in its
signature, and `Input.approve` is a reference the compiler resolves.

The macro generates `approve()` on `Owned<Draft>` and consumes that owner when
called. `Owned<Approved>` has no `approve()` method. Plain phase structs remain
ordinary data: constructing `Approved(title:)` does not create an
`Owned<Approved>` or an `Observed<Approved>` from a host.

The same schema also generates owners for hosted state. A hosted edge prepares
a proposal from a snapshot. Committing consumes the proposal and checks that
it still matches the owner and current revision. The
[schema guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineschema/declaringagraph)
covers typed rejection, operations, completion routing, and supported syntax.

### Choose an owner

| Owner | Use it when | Schema modes |
| --- | --- | --- |
| `Owned<Phase>` | The caller transfers exclusive ownership through consuming edges and handles effects. | `shared`, `isolated`, `ownedOnly` |
| `Local` | The caller owns a noncopyable value, drains commands, and acknowledges work explicitly. | `shared`, `isolated` |
| `MainActorHost` | UI input and admission belong to one MainActor owner, with managed work. | `shared`, `isolated` |
| `ActorHost` | One native actor owns mutation and managed work. | `shared` |
| `Shared` | Independent tasks need synchronous access to one shared owner. | `shared` |

Choose `shared` for concurrent access with checked `Sendable` data, `isolated`
for copyable values that stay within their permitted actor, or `ownedOnly` for
noncopyable resources. `ActorHost` and `MainActorHost` own their state directly;
synchronous input handling reads, prepares, and admits a change in one isolated
turn. For asynchronous work, a driver supplies the result and the host
revalidates it when it returns.

The bundled `ResourceWorkflow` shows
a recoverable resource transition: failure returns its original owner, and
success returns the next owner and every effect value in order for the caller
to handle. Dropping an owner is legal; ownership does not require completing
the workflow.

### Present state on MainActor

`StateMachineUI.SnapshotPresentation` publishes one complete snapshot through
`ObservableObject`, using the iOS 16 baseline. A newer receipt can update the
presentation in the same turn as a button's input. Delayed observations cannot
replace it with an older revision.

The bundled `ProfileEditor` owns a generated `MainActorHost` and its screen
subscription. Its load, retry, cancel, and account-change actions use the same
profile graph as the local and shared examples. Disposing the editor removes
observation and closes its work authority. The [UI guide](https://kylehughes.github.io/swift-state-machine/documentation/statemachineui/presentingstate)
shows a SwiftUI screen and explains the separate lifetime of a running driver.

## Manage shared state and asynchronous work

`ReferenceProfile` demonstrates a managed host. A driver supplies a typed
result, while the host controls whether that result still has authority to
change the model. This driver returns an in-memory profile:

```swift
import StateMachineExamples

let user = try UserID("taylor")
let machine = ReferenceProfile.Shared(
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

if case .idle(let idle) = machine.snapshot() {
    let request = try ProfileRequest(userID: user)
    let prepared = try idle.load(request)
    switch machine.commit(consume prepared) {
    case .committed(let receipt):
        print("Accepted revision \(receipt.ordinal)")
    case .rejected(let reason, _):
        print("Load was not accepted: \(reason)")
    }
}
```

Retain `machine` and `subscription` for the feature's lifetime. Copies of
`Shared` refer to the same owner. Shared callbacks run outside the storage lock
and are not confined to `MainActor`. A subscription delivers increasing revisions
and coalesces pending snapshots to the latest value. Effects and execution
acknowledgments do not coalesce.

Preparing a transition with `idle.load(request)` starts no work. Calling
`machine.commit(consume prepared)` checks whether the proposal is still current.
Acceptance atomically installs the complete model, operation authority, and
ordered command batch. If a competing write makes the proposal stale, rejection
returns the current observation without applying any part of the proposal.

### Handle conflicts and capacity explicitly

Managed completion delivery defaults to `manualOnConflict`. A conflict can occur
if another write commits between completion preparation and admission. The host
retains the first terminal outcome in `pendingCompletions()` with a reconciliation
reason. `reconcile(id:)` authorizes one fresh preparation; a concurrent attempt
reports `inProgress`. Duplicate delivery does not replace the retained outcome.

Select `completionPolicy: .retryPure` only when completion preparation is
deterministic and effect-free. It permits reevaluation against a newer root,
with at most four preparations per turn before yielding. Capture network
responses, decoded values, time, and other external inputs once. The compiler
does not prove purity.

An occupied queue or execution bound produces `capacityExceeded`. Managed
delivery retains the prepared candidate and retries admission when capacity
changes, without rerunning preparation. A plan that cannot fit by itself
produces `planTooLarge` and needs an application decision.

### End a lifetime

Call `subscription.cancel()` to unsubscribe. An already claimed callback may
finish. Call `machine.close()` to end admission and revoke work authority;
cancellation remains cooperative. `shutdownAndWait(deadline:)` also waits for
actual task termination and delivery cleanup. A deadline can return outstanding
execution and preparation diagnostics while the closed owner keeps tracking
that work.

`flush(through:)` waits for snapshot offers and effect launch or skip decisions
through an accepted receipt. It does not wait for network completion or observer
callbacks. Retained snapshots and receipts describe history, not reservations
of the current state.

## Keep data separate from authority

Model values are ordinary data. Observations carry private provenance, prepared
transitions are noncopyable, and work descriptors carry sealed operation
authority. Constructing a payload cannot mint any of those proofs. Public raw
runtime types have a separate, weaker contract. Sealed facades, including the
macro-generated owners, keep their raw storage private.

Shared payloads need semantic value behavior as well as `Sendable`. Actor
confinement does not make a mutable reference into an independent historical
value. Use immutable data, value storage, or detached projections.

`Local` provides manual execution under exclusive value ownership. Drain whole
command batches, finish the mutating access, then execute work and reenter with
a completion and a separate termination acknowledgment. It has no background
runner capturing the noncopyable owner.

Restoration accepts validated data and creates fresh authority; live tickets,
tasks, and prepared transitions are not persistence formats. The profile
example's versioned `Archive` validates decoded data, migrates its
legacy format, and rejects interrupted loading. See
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

Add `StateMachineUI` for observable presentation and background snapshot ingress.
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
