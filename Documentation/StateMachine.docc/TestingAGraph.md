# Testing a graph

Test each edge as a function, each admission rule through a scripted `Local` owner, and hosted behavior through controlled drivers.

A graph separates what an edge decides from what an owner admits, and tests can
follow the same line. `Owned` runs an edge with no runtime at all. A `Local`
owner runs routing, completion delivery, and cancellation synchronously, with
no task to wait for. A managed owner runs the same rules with real drivers,
which a test replaces with drivers it controls. The `StateMachineTesting` library supplies the harness for the last two and
measures which declared edges the tests exercised. Its own documentation
describes each helper in detail. This article walks through one graph from edge
to host.

## Add the testing library

`StateMachineTesting` depends only on `StateMachine` and links no test
framework, so it works with Swift Testing and XCTest alike. Add it to the test
target in `Package.swift`.

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/kylehughes/swift-state-machine.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "SearchFeature",
            dependencies: [.product(name: "StateMachine", package: "swift-state-machine")]
        ),
        .testTarget(
            name: "SearchFeatureTests",
            dependencies: [
                "SearchFeature",
                .product(name: "StateMachineTesting", package: "swift-state-machine"),
            ]
        ),
    ]
)
```

A helper that expects an outcome throws `StateMachineTestFailure` when the owner
does something else. Its message names what was expected and what happened, and
it carries the source location of the helper call, so a thrown failure points
at the line of the test that made the call.

## Declare the graph under test

This schema starts two operations when a search begins, lets a caller refine the
query while the fetch runs, records each refined query, and finishes when the
fetch returns. Refining with an empty query abandons the search, and a router
chooses between the two edges that can handle a refinement.

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable, Equatable {
    struct Idle: Sendable, Equatable {}
    struct Searching: Sendable, Equatable { let query: String }
    struct Found: Sendable, Equatable { let answer: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    @Terminal case found(Found)

    enum Input: Sendable, Equatable { case search(String), refine(String), cancel }

    @Operation(activeIn: [Searching.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
    }

    @Operation(activeIn: [Searching.self])
    enum Record { typealias Input = String }

    @Transition(on: Input.search, starts: [Fetch.self, Record.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.record(query), .fetch(query)])
    }

    @Transition(on: Input.refine, starts: [Record.self])
    fileprivate static func narrow(_ source: Searching, _ query: String) -> Change<Searching, Effect.Narrow> {
        Change(Searching(query: query), effects: [.record(query)])
    }

    @Transition(on: Input.refine)
    fileprivate static func abandon(_ source: Searching, _ query: String) -> Idle { Idle() }

    @Route(on: Input.refine)
    fileprivate static func refine(_ source: Searching, _ query: String) -> Route.Refine {
        query.isEmpty ? .abandon : .narrow
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Searching) -> Idle { Idle() }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Searching, _ answer: Fetch.Output) -> Found {
        Found(answer: answer)
    }

    @Transition(onSuccess: Record.self)
    fileprivate static func recorded(_ source: Searching) -> Searching { source }
}
```

The schema's inheritance clause lists `Equatable`, and so do its payloads and
its input. The macro then makes `Effect`, every edge's effect type, and
`Restoration` equatable too, in every module, so a test compares models and
effects with `==`. Synthesizing that conformance requires each operation's input,
and each event's payload, to be `Equatable`.

The generated owners have the schema's access level. A schema that is `internal`
is visible to a test target through `@testable import`, which the examples use.
Every test below is a method or function in a test target that imports
`StateMachine`, `StateMachineTesting`, and `Testing`.

## Test edges through Owned

An `Owned` value holds one phase, and each edge consumes it. A test calls the
edge and reads what comes back, with no host, driver, or task. `Change` carries
the effects an edge describes, in the order the edge wrote them.

```swift
import StateMachine
import Testing

@testable import SearchFeature

@Suite struct LookupEdgeTests {
    @Test func beginningASearchStartsItsEffectsInOrder() {
        let change = Lookup.owned().begin("swift")

        #expect(change.effects == [.record("swift"), .fetch("swift")])
        #expect(change.next.withValue { $0 } == Lookup.Searching(query: "swift"))
    }

    @Test func cancellingReturnsToIdle() {
        let change = Lookup.owned().begin("swift")
        let idle = change.next.cancel()

        #expect(idle.withValue { $0 } == Lookup.Idle())
    }
}
```

`Owned` edges run only the authored function. They check nothing that a host
checks, such as operation authority or revision, so they suit rules that live
inside an edge, including which phase it leaves, what it returns, which effects
it describes, and which typed failure it throws. A completion edge is an `Owned`
method too, so `received("Swift.org")` tests the step from `Searching` to
`Found`. `begin` returns its own effect type, `Effect.Begin`, and each value's
`effect` property widens it to the schema-wide `Effect` when a test collects
effects from several edges.

## Script a Local owner

`ManualMachineTest` takes a generated `Local` and offers the same verbs,
including `send`, `commit`, `drainCommands`, `deliver`, `acknowledgeExecution`,
`retryAdmission`, `reconcile`, `discardPending`, every `reset` (including
`reset()` when the schema declares a default initial payload), and `close`. Each
one calls the owner's own method and returns the owner's own result, so the test
sees real receipts, real command batches with real work, and real rejections.
The test plays the runner by draining each batch, supplying each result, and
acknowledging that each execution ended. Every call is synchronous, so a test
needs no waiting.

```swift
import StateMachineTesting

@Suite struct LookupLocalTests {
    @Test func aSearchIsRoutedAndItsFetchCompletes() throws {
        var test = ManualMachineTest(Lookup.Local())

        let receipt = try test.send(.search("swift"))
        #expect(receipt.snapshot.model == .searching(Lookup.Searching(query: "swift")))

        let batch = try test.drainBatch()
        try #require(batch.commands.count == 2)
        guard case .record(let record) = batch.commands[0], case .fetch(let fetch) = batch.commands[1] else {
            Issue.record("the batch did not start the record and then the fetch")
            return
        }
        #expect(fetch.input == "swift")

        guard case .committed = test.deliver(.record(record.succeeded())) else {
            Issue.record("the record completion was not admitted")
            return
        }
        #expect(test.acknowledgeExecution(record.execution) == .recorded)

        guard case .committed(let found) = test.deliver(.fetch(fetch.succeeded("Swift.org"))) else {
            Issue.record("the fetch completion was not admitted")
            return
        }
        #expect(found.snapshot.model == .found(Lookup.Found(answer: "Swift.org")))
        #expect(test.acknowledgeExecution(fetch.execution) == .recorded)
        #expect(test.acknowledgeExecution(fetch.execution) == .duplicate)

        #expect(test.history.map(\.edge) == [nil, "idle.begin", "searching.recorded", "searching.received"])

        test.close()
        _ = test.drainCommands()
        let quiescent = test.isQuiescent
        #expect(quiescent)
    }
}
```

`send` throws a failure that describes the rejection when the owner does not
admit the input, and `drainBatch()` requires exactly one queued batch, which it
counts before transferring any, so a failed expectation leaves every batch
queued in the owner. A
completion is sealed by the work the owner issued and wrapped in the schema's
`Completion` enum, so `.fetch(fetch.succeeded("Swift.org"))` is the only way to
deliver a fetch result. `deliver` returns a `DeliveryResult` of `.committed`,
`.pending`, `.refused`, `.stale`, or `.foreignOwner`. Delivery and
acknowledgment are separate obligations, so the test reports both, and
acknowledging the same execution twice reports `.duplicate`.

Every call the owner accepts appends a step to `history`, beginning with the
owner's state when the harness took it. A step records what produced it, the
phase it left and the phase it holds, the accepted snapshot, and the identifier
of the edge that produced it, `"<phase>.<edge>"`, which the owner's receipt
reports as its `edgeID`.

Read `isQuiescent` into a local before passing it to `#expect`, as the test
does. The harness is noncopyable, and the `#expect` macro cannot evaluate a
property of a noncopyable value in place, so `#expect(test.isQuiescent)` does
not compile.

A completion from work that has lost its authority is stale. Cancelling leaves
`Searching`, the only phase where `Fetch` is active, so the fetch the test
holds cannot move the machine, and a stale delivery adds no step.

```swift
extension LookupLocalTests {
    @Test func aCompletionAfterCancellationIsStale() throws {
        var test = ManualMachineTest(Lookup.Local())
        try test.send(.search("swift"))
        guard case .fetch(let fetch)? = test.drainFlattenedCommands().last else {
            Issue.record("the search did not start a fetch")
            return
        }

        try test.send(.cancel)

        guard case .stale = test.deliver(.fetch(fetch.succeeded("Swift.org"))) else {
            Issue.record("the late completion was not stale")
            return
        }
        #expect(test.snapshot().model == .idle(Lookup.Idle()))
        #expect(test.history.map(\.edge) == [nil, "idle.begin", "searching.cancel"])
    }
}
```

A change that starts or cancels nothing, such as the record's completion,
queues no batch, and its receipt comes back from `deliver`. When the queue is
full, a completion that is otherwise admissible is retained as
`.pending(id, .waitingForCapacity)`, with its prepared candidate.
`retryAdmission(id:)` retries the retained candidate without preparing it again
and returns a `ReconcileResult`. In this test, draining frees the queue's only
slot and the revision stays current, so the retry commits.

```swift
extension LookupLocalTests {
    @Test func aRetainedCompletionIsAdmittedWhenCapacityFrees() throws {
        var test = ManualMachineTest(Lookup.Local(configuration: try Lookup.LocalConfiguration(commits: 1)))
        try test.send(.search("swift"))
        let commands = test.drainFlattenedCommands()
        guard commands.count == 2, case .record(let record) = commands[0], case .fetch(let fetch) = commands[1]
        else {
            Issue.record("the search did not start the record and the fetch")
            return
        }

        // The record's completion queues nothing; the refinement records the new query, and its batch
        // takes the only slot.
        guard case .committed = test.deliver(.record(record.succeeded())) else {
            Issue.record("the record completion was not admitted")
            return
        }
        try test.send(.refine("swift testing"))
        guard case .pending(let id, .waitingForCapacity) = test.deliver(.fetch(fetch.succeeded("Swift.org"))) else {
            Issue.record("the completion was not retained")
            return
        }
        #expect(test.snapshot().model == .searching(Lookup.Searching(query: "swift testing")))

        _ = test.drainCommands()
        guard case .committed = test.retryAdmission(id: id) else {
            Issue.record("the retained completion was not admitted")
            return
        }
        #expect(test.snapshot().model == .found(Lookup.Found(answer: "Swift.org")))
        #expect(test.history.last?.kind == .retry)
    }
}
```

## Test a routed input

When several edges share a source and an input, a router chooses between them,
and every typed call goes through it. An observation offers one method, named
after the `@Route` function, and none for the candidate edges, and `Owned`
offers the same method. A test can check that `send`, a committed observation,
and an owned value agree, without any way to bypass the rule.

```swift
extension LookupLocalTests {
    @Test func anEmptyRefinementAbandonsTheSearchOnEveryPath() throws {
        var sent = ManualMachineTest(Lookup.Local())
        try sent.send(.search("swift"))
        try sent.send(.refine(""))
        #expect(sent.phase == "idle")

        var committed = ManualMachineTest(Lookup.Local())
        try committed.send(.search("swift"))
        guard case .searching(let searching) = committed.snapshot(),
            case .committed = committed.commit(searching.refine(""))
        else {
            Issue.record("the routed edge was not committed")
            return
        }
        #expect(committed.history.last?.edge == "searching.abandon")

        let change = Lookup.owned().begin("swift")
        switch change.next.refine("") {
        case .abandon(let idle):
            #expect(idle.withValue { $0 } == Lookup.Idle())
        case .narrow:
            Issue.record("an empty refinement narrowed the search")
        }
    }
}
```

The receipt of each accepted change names the edge the router chose, so the
harness records it, and because the two candidates return different phases, the
owned call returns the generated `Route.RefineResult` with one case per
candidate. A router that throws adds a `rejected` case that returns the
unchanged source.

A wrong-phase input is a rejection rather than a compile error, because `send`
routes at run time. `rejection(of:)` sends an input that the owner must reject
and returns the typed rejection, or throws if the owner admits it.

```swift
extension LookupLocalTests {
    @Test func cancellingWhileIdleIsRejectedAndChangesNothing() throws {
        var test = ManualMachineTest(Lookup.Local())

        guard case .preparation(.invalidPhase) = try test.rejection(of: .cancel) else {
            Issue.record("cancelling while idle was rejected for another reason")
            return
        }
        #expect(test.snapshot().revision == 0)
    }
}
```

## Measure coverage

`GraphCoverage(for:)` measures one owner type and records the history of each
harness run of that owner. A run of another schema does not compile as an
argument, however alike their graphs are. It reports the declared edges no run
took, the phases no run held, and the routers with candidates none of which ran.

A router without candidates exists only to decline an input or a completion, so
no step can exercise it. `unexercisedRejectingRouters` lists each one that no
run saw the real owner decline through, from `rejection(of:)`, a failed `send`,
or a `deliver` or `reconcile(id:)` whose result reports that its own preparation
was refused there. A second delivery of a retained completion prepares nothing,
so it counts nothing.

`requireCoverage()` requires every phase, every edge, and every router with at
least one candidate. It fails for any of them that no run reached, for any
invariant a run violated, for any change made inside `withOwner` that the
harness never observed, and for any owner a `withOwner` closure replaced. By
default it requires nothing of rejections. Pass
`requireCoverage(includingRejectingRouters: true)` to also require every router
without candidates to have declined. `requireCoverage(excluding:)` waives the
edges and routers it names by their `"<phase>.<name>"` identifiers. Every step
comes from a real owner admitting a real change and names the edge from that
change's receipt, so an exercised edge is one that a test actually took.

```swift
@Suite struct LookupCoverageTests {
    @Test func twoRunsExerciseEveryEdge() throws {
        var coverage = GraphCoverage(for: Lookup.Local.self)

        var found = ManualMachineTest(Lookup.Local())
        try found.send(.search("swift"))
        for command in found.drainFlattenedCommands() {
            switch command {
            case .record(let work): _ = found.deliver(.record(work.succeeded()))
            case .fetch(let work): _ = found.deliver(.fetch(work.succeeded("Swift.org")))
            case .cancel: break
            }
        }
        coverage.record(found)

        var abandoned = ManualMachineTest(Lookup.Local())
        try abandoned.send(.search("swift"))
        try abandoned.send(.refine("swift testing"))
        try abandoned.send(.refine(""))
        try abandoned.send(.search("swift"))
        try abandoned.send(.cancel)
        coverage.record(abandoned)

        #expect(coverage.unexercisedEdges.isEmpty)
        try coverage.requireCoverage()
    }
}
```

Even when a router chooses between edges with the same destination, the receipt
still names the edge it chose. A harness can also check named invariants on
every accepted snapshot, which the coverage reports with the rest.

## Test hosted behavior with controlled drivers

A managed owner runs its drivers itself. A `ControlledDriver` stands in for one.
Pass its `run` method as the operation's driver, and each time the host starts
the operation, the call waits until the test finishes it. `nextStarted()`
returns the calls in start order with the input the host passed, so the order
of events is the test's choice and no test sleeps.

```swift
@Suite(.timeLimit(.minutes(1))) struct LookupHostTests {
    @Test func aSearchFindsItsAnswerOnceTheDriverReturns() async throws {
        let fetch = ControlledDriver<String, String, Never>()
        let record = ControlledDriver<String, Void, Never>()
        let host = Lookup.ActorHost(fetchDriver: fetch.run, recordDriver: record.run)
        let snapshots = try await host.snapshots()

        let receipt = try await host.send(.search("swift"))
        #expect(receipt.snapshot.model == .searching(Lookup.Searching(query: "swift")))

        let call = try await fetch.nextStarted()
        #expect(call.input == "swift")
        call.succeed("Results for swift")
        try await record.nextStarted().succeed()

        for await snapshot in snapshots where snapshot.model == .found(Lookup.Found(answer: "Results for swift")) {
            break
        }
        #expect(await host.shutdown() == .quiescent)
    }
}
```

The receipt describes the accepted change at the moment of `send`, so a test
asserts on it directly. The result of the driver arrives later. A snapshot
sequence keeps only the latest pending snapshot, so a slow loop can skip
intermediate revisions, and a test must not count elements. It waits for the
snapshot that matters instead, as the loop does, and the time limit turns a
result that never arrives into a failure. Create the sequence before sending,
so the first element is the snapshot current at registration or a newer one.

A call ignores cancellation, as a driver that does not check for it would. When
the host cancels the call's task, `isCancelled` becomes `true` and
`waitForCancellation()` returns, and the call keeps running until the test finishes
it. A test can therefore deliver a result after cancellation and observe that
the host discards it.

```swift
extension LookupHostTests {
    @Test func aResultAfterCancellationIsDiscarded() async throws {
        let fetch = ControlledDriver<String, String, Never>()
        let record = ControlledDriver<String, Void, Never>()
        let host = Lookup.Shared(fetchDriver: fetch.run, recordDriver: record.run)

        try host.send(.search("swift"))
        let call = try await fetch.nextStarted()
        let cancelled = try host.send(.cancel)
        try await call.waitForCancellation()

        call.succeed("Too late")
        try await record.nextStarted().succeed()
        #expect(await host.shutdown() == .quiescent)
        #expect(host.snapshot().model == .idle(Lookup.Idle()))
        // Only the closure followed the cancellation.
        #expect(host.snapshot().revision == cancelled.revision + 1)
    }
}
```

A call that the test never finishes never returns, and the host's shutdown waits
for it. Pass a deadline to `shutdown(deadline:)` to bound the wait. It returns
`.quiescent` after the owner processes its terminal batch and its execution and
delivery obligations settle. On timeout it returns `.timedOut(diagnostics)`, and
the owner stays closed. `diagnostics.outstandingExecutions` identifies the
reservations it still tracks, and finishing the call lets a later shutdown
settle.

```swift
extension LookupHostTests {
    @Test func aDriverThatNeverReturnsTimesShutdownOut() async throws {
        let fetch = ControlledDriver<String, String, Never>()
        let host = Lookup.ActorHost(fetchDriver: fetch.run, recordDriver: { _ in })
        try await host.send(.search("swift"))
        let call = try await fetch.nextStarted()

        guard case .timedOut(let diagnostics) = await host.shutdown(deadline: .now + .milliseconds(50)) else {
            Issue.record("shutdown did not time out")
            return
        }
        #expect(!diagnostics.outstandingExecutions.isEmpty)

        call.succeed("Released")
        #expect(await host.shutdown() == .quiescent)
    }
}
```

The same `run` serves every managed host whose values are `Sendable`, an
operation that can fail, whose call ends with `fail(_:)`, and an `IsolatedHost`,
whose driver receives its owning actor. `KeyedControlledDriver` adds the key to
each call, and its `nextStarted(for:)` waits for one key's call, because calls
for different keys can start in either order. For values that are not
`Sendable`, `MainActorControlledDriver` serves a `MainActorHost`, whose values
stay on the main actor, and `KeyedMainActorControlledDriver` does the same for a
keyed operation, as in `downloadDriver: download.run`. `IsolatedControlledDriver`
serves an `IsolatedHost`, whose values stay on its owning actor. That actor
stores the driver, and the test awaits its calls there.
`KeyedIsolatedControlledDriver` does the same for a keyed operation. A key's
equality runs on the main actor or the owning actor, and a comparison that
starts another call or wait, or cancels the waiting task, cannot reorder which
call each wait receives. A confined call's members take the owning
actor by default, which an autoclosure such as the argument of `#expect` does
not pass, so a test on that actor reads their results, and an `IsolatedHost`'s
counts, into locals first.

## Test a presentation with a test double

A presentation from the `StateMachineUI` module drives and observes any
`MainActorStateMachineHost`. A test double conforms to that protocol, which
confers no authority, and lets a test deliver snapshots in any order and see how
the presentation reacts. The protocol has six associated types that a double
declares as nested types (`Input`, `Snapshot`, `Receipt`, `SendRejection`,
`Prepared`, and `CommitResult`). A `Receipt` reports its `snapshot` and the
`edgeID` of the change, which a double can leave `nil`.

A double implements `snapshot()`, `send(_:)`, `commit(_:)`,
`subscribe(_:onFinish:)`, and `close()`. The protocol's projecting sequences,
`snapshots(_:)` and `distinctSnapshots(_:)`, come from its
`subscribe(_:onFinish:)` unless it implements them. The double returns its
registration as a `MainActorSnapshotSubscription`, which `init(onCancel:)`
creates. Its action runs exactly once, whether the presentation calls `cancel()`
or releases the registration. A release runs the action in a later turn on the
main actor, while `cancel()` runs it before returning.

```swift
import StateMachine
import StateMachineUI
import Testing

@MainActor
final class FakeHost: MainActorStateMachineHost {
    struct Snapshot: StateMachineSnapshot {
        let revision: UInt64
        let title: String
    }

    struct Receipt: StateMachineReceipt {
        let snapshot: Snapshot
        var edgeID: String? { nil }
    }

    struct Prepared: ~Copyable {
        let title: String
    }

    enum Input { case rename(String) }
    enum SendRejection: Error { case refused }
    enum CommitResult {
        case committed(Receipt)
        case rejected(current: Snapshot)
    }

    private var current = Snapshot(revision: 0, title: "Draft")
    private var receive: (@MainActor (Snapshot) -> Void)?
    private(set) var cancellations = 0

    func snapshot() -> Snapshot { current }

    func send(_ input: Input) throws(SendRejection) -> Receipt {
        guard case .rename(let title) = input, !title.isEmpty else { throw .refused }
        return Receipt(snapshot: publish(title))
    }

    func commit(_ prepared: consuming Prepared) -> CommitResult {
        .committed(Receipt(snapshot: publish(prepared.title)))
    }

    func subscribe(
        _ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard self.receive == nil else { throw .capacityExceeded }
        self.receive = receive
        return MainActorSnapshotSubscription(onCancel: { [weak self] in
            self?.receive = nil
            self?.cancellations += 1
        })
    }

    func close() -> Receipt { Receipt(snapshot: current) }

    /// Delivers a snapshot as a real host would, outside any call from the presentation.
    func deliver(_ snapshot: Snapshot) { receive?(snapshot) }

    private func publish(_ title: String) -> Snapshot {
        current = Snapshot(revision: current.revision + 1, title: title)
        return current
    }
}

@MainActor
@Suite struct PresentationTests {
    @Test func aPresentationKeepsTheNewestSnapshotAndReleasesItsRegistrationOnce() {
        let host = FakeHost()
        let presentation = StateMachinePresentation(host)

        host.deliver(FakeHost.Snapshot(revision: 2, title: "Second"))
        host.deliver(FakeHost.Snapshot(revision: 1, title: "First"))
        #expect(presentation.snapshot.title == "Second")

        presentation.stopObserving()
        presentation.stopObserving()
        #expect(host.cancellations == 1)
    }

    @Test func aCommittedProposalIsShownBeforeCommitReturns() {
        let host = FakeHost()
        let presentation = StateMachinePresentation(host)

        guard case .committed = presentation.commit(FakeHost.Prepared(title: "Renamed")) else {
            Issue.record("the proposal was not committed")
            return
        }
        #expect(presentation.snapshot.title == "Renamed")
    }

    @Test func aRefusedRegistrationLeavesThePresentationUnobserving() {
        let host = FakeHost()
        let first = StateMachinePresentation(host)
        let second = StateMachinePresentation(host)

        #expect(first.isObserving)
        #expect(!second.isObserving)
        #expect(second.observationFailure == .capacityExceeded)
        #expect(second.snapshot.title == "Draft")
    }
}
```

The first test delivers revision 1 after revision 2 and expects the
presentation to keep the newer snapshot. The second sends a proposal through the
presentation and reads the result in the same turn. The third registers a second
presentation with a double that has room for one observer. Creating a
presentation never throws, so the failed registration appears as
`isObserving == false` and an `observationFailure`, while `snapshot` still shows
the double's snapshot at creation.

A double of a `SharedStateMachineHost`, an `ActorStateMachineHost`, or an
`IsolatedStateMachineHost` returns its registrations as `SnapshotSequence`
values, which `SnapshotSequence(register:)` builds from callbacks of the
double's own. The closure receives a `receive` callback, which offers an
element, and a `finish` callback, which ends the sequence, and returns the
registration's token, a `SnapshotSubscription` from `init(onCancel:)`.
Releasing both callbacks ends the sequence, as releasing an owner does.

The sequence cancels the token exactly once, even when the double keeps its own
reference to it. That cancellation runs when `finish` runs or the callbacks are
released (even before `register` returns and with an element still unread, which
stays readable), when a read reaches the end or finds its task cancelled, when
`cancel()` is called, or when both the sequence and its iterator are released. A
double offers the snapshot current at registration first, as a real owner does.
An isolated double's `subscribe(_:onFinish:isolation:)` returns an
`IsolatedSnapshotSubscription` from `init(isolation:onCancel:onRelease:)`.

This preview feed keeps each registration's callbacks, as an owner does.
Cancelling a registration removes its callbacks by identifier, through a weak
reference, so the token does not keep the feed alive. Releasing the feed
releases every callback it keeps, which ends each sequence it registered, so the
preview stays live for exactly as long as the code that created the feed keeps
it.

```swift
import StateMachine
import StateMachineUI
import Testing
import os

final class PreviewFeed: SharedStateMachineHost {
    struct Snapshot: StateMachineSnapshot, Sendable {
        let revision: UInt64
        let headline: String
    }

    private struct Registration {
        let receive: @Sendable (Snapshot) -> Void
        let finish: @Sendable () -> Void
    }
    private struct Registry {
        var nextID = 0
        var registrations: [Int: Registration] = [:]
    }

    private let registry = OSAllocatedUnfairLock(initialState: Registry())
    let current = Snapshot(revision: 1, headline: "Preview")

    /// How many registrations the feed is keeping.
    var registrationCount: Int { registry.withLock { $0.registrations.count } }

    func snapshot() -> Snapshot { current }

    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> {
        try snapshots { $0 }
    }

    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let current = current
        return try SnapshotSequence { receive, finish in
            receive(transform(current))
            let registration = Registration(receive: { receive(transform($0)) }, finish: finish)
            let id = registry.withLock { registry in
                defer { registry.nextID += 1 }
                registry.registrations[registry.nextID] = registration
                return registry.nextID
            }
            return SnapshotSubscription { [weak self] in
                _ = self?.registry.withLock { $0.registrations.removeValue(forKey: id) }
            }
        }
    }

    // A feed with one snapshot never repeats a projection.
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try snapshots(transform)
    }
}

@MainActor
@Test func aPresentationShowsThePreviewFeedForTheFeedsLifetime() async throws {
    var feed: PreviewFeed? = PreviewFeed()
    let presentation = SnapshotObservableObject(PreviewFeed.Snapshot(revision: 0, headline: ""))

    try presentation.observe(try #require(feed))
    #expect(presentation.snapshot.headline == "Preview")
    #expect(presentation.isObserving)
    presentation.stopObserving()
    #expect(feed?.registrationCount == 0)

    // Releasing the feed ends the sequence it registered; the unread headline stays readable.
    let snapshots = try #require(feed).snapshots()
    feed = nil
    await presentation.follow(snapshots)
    #expect(presentation.snapshot.headline == "Preview")
    #expect(!presentation.isObserving)
}
```

## Keep a wrong-phase call out of the codebase

A phase offers only the edges that leave it. Neither `Owned<Idle>` nor the
`Observed<Idle>` in an idle snapshot offers `cancel()`. Uncomment the call below
to see the compiler diagnostic.

```swift
func beginFromIdle() {
    let idle = Lookup.owned()
    // _ = idle.cancel()
    _ = idle.begin("swift")
}
```

The compiler reports this diagnostic.

```text
instance method 'cancel()' requires the types 'Lookup.Idle' and 'Lookup.Searching' be equivalent
```

A test cannot exercise a call that does not compile, and a test does not need
to. Prefer these typed calls, on `Owned` or on an `Observed` committed to its
owner, wherever the caller knows the phase. If the edge is removed or moved, the
caller stops compiling.
