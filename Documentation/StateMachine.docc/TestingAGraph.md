# Testing a graph

Test each edge as a function, each rule through a manual owner, and hosted behavior through stub drivers.

A graph separates what an edge decides from what an owner admits, and tests can
follow the same line. `Owned` runs an edge with no runtime at all. `Local` runs
routing, completion delivery, and cancellation synchronously, with no task to
wait for. A hosted owner runs the same rules with real drivers, which a test
replaces with stubs that it controls. The examples here use Swift Testing and
one small graph.

## Declare the graph under test

This schema starts two operations when a search begins, lets a caller refine the
query while the fetch runs, and finishes when the fetch returns. Refining with
an empty query abandons the search, and a router chooses between the two edges
that can handle a refinement:

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable, Equatable {
    struct Idle: Sendable, Equatable {}
    struct Searching: Sendable, Equatable { let query: String }
    struct Found: Sendable, Equatable { let answer: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    case found(Found)

    enum Input: Sendable { case search(String), refine(String), cancel }

    @Operation(activeIn: [Searching.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
    }

    @Operation(activeIn: [Searching.self])
    enum Record {
        typealias Input = String
        typealias Output = Void
    }

    @Transition(on: Input.search, starts: [Fetch.self, Record.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.record(query), .fetch(query)])
    }

    @Transition(on: Input.refine)
    fileprivate static func narrow(_ source: Searching, _ query: String) -> Searching {
        Searching(query: query)
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
    fileprivate static func recorded(_ source: Searching, _ output: Record.Output) -> Searching {
        source
    }
}

extension Lookup.Effect: Equatable {}
```

The schema and its phase payloads conform to `Equatable`, and the last line
makes the generated `Effect` equatable. Both let a test compare values with
`==`. “Compare models and effects” explains where to declare these conformances
for synthesized equality.

The generated owners have the schema's access level. A schema that is `internal`
is visible to a test target through `@testable import`, which the examples use.
Every test below is a method or function in a test target that imports
`StateMachine` and `Testing`.

## Test edges through Owned

An `Owned` value holds one phase, and each edge consumes it. A test calls the
edge and reads what comes back, with no host, driver, or task. `Change` carries
the effects an edge describes, in the order the edge wrote them:

```swift
import StateMachine
import Testing

@testable import SearchFeature

@Suite struct LookupEdgeTests {
    @Test func beginningASearchStartsItsEffectsInOrder() {
        let change = Lookup.owned().begin("swift")

        #expect(change.effects.map(\.effect) == [.record("swift"), .fetch("swift")])
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
checks, such as operation authority or revision, so they suit a rule that lives
in an edge: which phase it leaves, what it returns, which effects it describes,
and which typed failure it throws. A completion edge is an `Owned` method too,
so `received("Swift.org")` tests the step from `Searching` to `Found`.

## Compare models and effects

Every snapshot has a `model`, which is the schema enum itself. When the schema
and its payloads are `Equatable`, a test compares a whole model, as in
`machine.snapshot().model == .found(Lookup.Found(answer: "Swift.org"))`.

The generated `Effect` enum represents every operation in the schema. To
synthesize its `Equatable` conformance, each operation's input must be
`Equatable`. Declare `extension Lookup.Effect: Equatable {}` in the file that
declares the schema. The compiler synthesizes `==` only in the file that
declares the type, so the same extension in another file fails with `extension
outside of file declaring enum 'Effect' prevents automatic synthesis of '==' for
protocol 'Equatable'`. The same rule applies to an extension that makes the
schema itself `Equatable`.

An `Owned` edge returns its own effect type, `Effect.Begin` for `begin`. Its
`effect` property widens each value to the schema-wide `Effect`, so
`change.effects.map(\.effect)` compares against a literal array of `Effect`
cases, as the first test does.

## Test routing and completion through Local

`Local` is a value with no runner. Accepting an input that starts or cancels
work queues a batch of commands, and the test plays the runner: it drains the
batches, supplies each result, and acknowledges that each execution ended.
Every call is synchronous, so a test needs no waiting. Delivery goes through
`Local.deliver` only, because a hosted owner has no `deliver`: its drivers are
the only source of a result.

```swift
@Suite struct LookupLocalTests {
    @Test func aSearchIsRoutedAndItsFetchCompletes() throws {
        var machine = Lookup.Local()

        let receipt = try machine.send(.search("swift"))
        #expect(receipt.revision == 1)
        #expect(receipt.snapshot.model == .searching(Lookup.Searching(query: "swift")))

        let batches = machine.drainCommands(limit: 8)
        let batch = try #require(batches.first)
        try #require(batches.count == 1 && batch.commands.count == 2)
        guard case .record(let record) = batch.commands[0],
            case .fetch(let fetch) = batch.commands[1]
        else {
            Issue.record("the batch did not start the record and then the fetch")
            return
        }
        #expect(record.input == "swift")
        #expect(fetch.input == "swift")

        guard case .committed = machine.deliver(record.succeeded()) else {
            Issue.record("the record completion was not admitted")
            return
        }
        #expect(machine.acknowledgeExecution(record.execution, disposition: .terminated) == .recorded)

        guard case .committed(let completed) = machine.deliver(fetch.succeeded("Swift.org")) else {
            Issue.record("the completion was not admitted")
            return
        }
        #expect(completed.snapshot.model == .found(Lookup.Found(answer: "Swift.org")))
        #expect(machine.acknowledgeExecution(fetch.execution, disposition: .terminated) == .recorded)
        #expect(machine.acknowledgeExecution(fetch.execution, disposition: .terminated) == .duplicate)
    }
}
```

`send` routes the input and admits it, `drainCommands(limit:)` returns whole
batches in commit order, and `work.succeeded(_:)` builds the sealed completion.
`deliver` accepts it and returns a `DeliveryResult`: `.committed`, `.pending`,
`.stale`, or `.foreignOwner`. Delivery and acknowledgment are separate
obligations, so the test reports both. Acknowledging the same execution twice is
harmless and reports `.duplicate`.

A completion from work that has lost its authority is stale. Cancelling leaves
`Searching`, the only phase where `Fetch` is active, so the fetch the test
holds cannot move the machine:

```swift
extension LookupLocalTests {
    @Test func aCompletionAfterCancellationIsStale() throws {
        var machine = Lookup.Local()
        try machine.send(.search("swift"))
        guard case .fetch(let fetch)? = machine.drainCommands(limit: 1).first?.commands.last else {
            Issue.record("the search did not start a fetch")
            return
        }

        try machine.send(.cancel)

        guard case .stale = machine.deliver(fetch.succeeded("Swift.org")) else {
            Issue.record("the late completion was not stale")
            return
        }
        #expect(machine.snapshot().model == .idle(Lookup.Idle()))
    }
}
```

A change that starts or cancels nothing, such as a refinement, queues no batch,
and its receipt is the return value of `send`. Admitting a completion queues
one, because it cancels the operation it finishes. When the queue is full, a
completion that is otherwise admissible is retained as
`.pending(id, .waitingForCapacity)`, with its prepared candidate. Draining and
acknowledging never change the model. `retryAdmission(id:)` retries the retained
candidate without preparing it again and returns a `ReconcileResult`. In this
test, draining frees the queue's only slot and the revision stays current, so
the retry commits. A queue of one batch makes the case easy to build:

```swift
extension LookupLocalTests {
    @Test func aRetainedCompletionIsAdmittedWhenCapacityFrees() throws {
        var machine = Lookup.Local(configuration: try Lookup.LocalConfiguration(commits: 1))
        try machine.send(.search("swift"))
        let commands = machine.drainCommands(limit: 1).first?.commands ?? []
        guard commands.count == 2, case .record(let record) = commands[0], case .fetch(let fetch) = commands[1]
        else {
            Issue.record("the search did not start the record and the fetch")
            return
        }

        // A refinement queues nothing; the record's completion takes the only slot.
        try machine.send(.refine("swift testing"))
        guard case .committed(let recorded) = machine.deliver(record.succeeded()) else {
            Issue.record("the record completion was not admitted")
            return
        }
        guard case .pending(let id, .waitingForCapacity) = machine.deliver(fetch.succeeded("Swift.org")) else {
            Issue.record("the completion was not retained")
            return
        }
        #expect(machine.snapshot().model == .searching(Lookup.Searching(query: "swift testing")))

        let drained = machine.drainCommands(limit: 1)
        #expect(drained.map(\.receipt.revision) == [recorded.revision])
        #expect(machine.snapshot().revision == 3)

        guard case .committed(let receipt) = machine.retryAdmission(id: id) else {
            Issue.record("the retained completion was not admitted")
            return
        }
        #expect(receipt.revision == 4)
        #expect(machine.snapshot().model == .found(Lookup.Found(answer: "Swift.org")))
    }
}
```

## Test a routed input

When several edges share a source and an input, a router chooses between them,
and every typed call goes through it. An observation offers one method, named
after the `@Route` function, and none for the candidate edges. `Owned` offers
the same method. A test can check that `send`, a committed
observation, and an owned value agree, without any way to bypass the rule:

```swift
extension LookupLocalTests {
    @Test func anEmptyRefinementAbandonsTheSearchOnEveryPath() throws {
        var sent = Lookup.Local()
        try sent.send(.search("swift"))
        try sent.send(.refine(""))
        #expect(sent.snapshot().model == .idle(Lookup.Idle()))

        var committed = Lookup.Local()
        try committed.send(.search("swift"))
        guard case .searching(let searching) = committed.snapshot() else {
            Issue.record("the search did not reach the searching phase")
            return
        }
        guard case .committed = committed.commit(searching.refine("")) else {
            Issue.record("the routed edge was not committed")
            return
        }
        #expect(committed.snapshot().model == .idle(Lookup.Idle()))

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

Here the two candidates return different phases, so the owned call returns the
generated `Route.RefineResult` with one case per candidate. A router that throws
adds a `rejected` case that returns the unchanged source.

## Test hosted behavior with gated drivers

A hosted owner runs its drivers itself. A test supplies stub drivers and holds
each one at a gate, so the order of events is the test's choice and no test
sleeps. A driver for an operation that cannot fail returns its output directly,
so a stub is a closure that returns a value. A gate is a value the test opens
once:

```swift
struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }

    func open() { continuation.finish() }

    func wait() async {
        for await _ in stream {}
    }
}

@Suite struct LookupHostTests {
    @Test(.timeLimit(.minutes(1)))
    func aSearchFindsItsAnswerOnceTheDriverReturns() async throws {
        let gate = Gate()
        let drivers = Lookup.Drivers(
            fetch: { query in
                await gate.wait()
                return "Results for \(query)"
            },
            record: { _ in }
        )
        let host = Lookup.ActorHost(drivers: drivers)
        let snapshots = try await host.snapshots()

        let receipt = try await host.send(.search("swift"))
        #expect(receipt.snapshot.model == .searching(Lookup.Searching(query: "swift")))

        gate.open()
        var sawAnswer = false
        for await snapshot in snapshots
        where snapshot.model == .found(Lookup.Found(answer: "Results for swift")) {
            sawAnswer = true
            break
        }
        #expect(sawAnswer)
        await host.shutdown()
    }
}
```

The receipt describes the accepted change at the moment of `send`, so a test
asserts on it directly. The result of the driver arrives later. A snapshot
sequence keeps only the latest pending snapshot, so a slow loop can skip
intermediate revisions, and a test must not count elements. It waits for the
snapshot that matters instead, as the loop does, and the time limit turns a
result that never arrives into a failure. Create the sequence before sending, so
the first element is the snapshot current at registration or a newer one.

`shutdown()` closes the owner and waits for its tasks to terminate, so no driver
outlives the test. A test builds its stubs as one `Drivers` value because the
same value serves every owner: `Shared` takes it and supports the same
assertions. A `MainActorHost` takes a `MainActorDrivers` value, and its test is
marked `@MainActor`. A stub that needs no gate can use the `fetchDriver:` and
`recordDriver:` closures of the initializer directly.

Pass a deadline to `shutdown(deadline:)` to bound the wait. It returns
`.quiescent` after the owner processes its terminal batch and its execution and
delivery obligations settle. On timeout it returns `.timedOut(diagnostics)`, and
the owner stays closed. `diagnostics.outstandingExecutions` identifies the
reservations it still tracks, including any outstanding delivery or preparation.
The diagnostic handles grant no authority. Release the driver, then call
`shutdown()` again to wait without a deadline. The result is discardable, so a
test that does not care ignores it, as the test above does. The test below
waits until the driver has started, because shutdown skips work that never
began. Cancellation is cooperative, so the stub ignores it to stand in for a
driver that does not stop:

```swift
extension LookupHostTests {
    @Test(.timeLimit(.minutes(1)))
    func aDriverThatNeverReturnsTimesShutdownOut() async throws {
        let started = Gate()
        let release = Gate()
        let host = Lookup.ActorHost(
            fetchDriver: { query in
                started.open()
                // A new task does not inherit cancellation, so this driver
                // ignores the host's request to stop, as a stuck call might.
                await Task { await release.wait() }.value
                return query
            },
            recordDriver: { _ in }
        )
        _ = try await host.send(.search("swift"))
        await started.wait()

        let result = await host.shutdown(deadline: .now + .milliseconds(50))
        guard case .timedOut(let diagnostics) = result else {
            Issue.record("shutdown did not time out")
            return
        }
        #expect(!diagnostics.outstandingExecutions.isEmpty)

        release.open()
        #expect(await host.shutdown() == .quiescent)
    }
}
```

## Test a presentation with a test double

A presentation drives and observes any `MainActorStateMachineHost`. A test
double conforms to that protocol, which confers no authority, and lets a test
deliver snapshots in any order and see how the presentation reacts. The protocol
has six associated types, which a double declares as nested types: `Input`,
`Snapshot`, `Receipt`, `SendRejection`, `Prepared`, and `CommitResult`. Its
requirements are `snapshot()`, `send(_:)`, `commit(_:)`,
`subscribe(_:onFinish:)`, and `close()`. The double returns its registration as
a `MainActorSnapshotSubscription`, which `init(onCancel:)` creates. Its action
runs exactly once, whether the presentation calls `cancel()` or releases the
registration. A release runs the action in a later turn on the main actor, while
`cancel()` runs it before returning:

```swift
import StateMachineUI

@MainActor
final class FakeHost: MainActorStateMachineHost {
    struct Snapshot: StateMachineSnapshot {
        let revision: UInt64
        let title: String
    }

    struct Receipt: StateMachineReceipt {
        let snapshot: Snapshot
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

The compiler reports this diagnostic:

```text
instance method 'cancel()' requires the types 'Lookup.Idle' and 'Lookup.Searching' be equivalent
```

A test cannot exercise a call that does not compile, and a test does not need
to. Prefer these typed calls, on `Owned` or on an `Observed` committed to its
owner, wherever the caller knows the phase. If the edge is removed or moved, the
caller stops compiling.

`send(_:)` routes at run time, so a wrong-phase input is a rejection rather than
a compile error. The rejection is `.preparation(.invalidPhase)`, and the owner
is unchanged. Test that once for an input that callers may send at the wrong
time:

```swift
extension LookupLocalTests {
    @Test func cancellingWhileIdleIsRejectedAndChangesNothing() {
        var machine = Lookup.Local()

        do {
            try machine.send(.cancel)
            Issue.record("an input with no edge from idle was admitted")
        } catch {
            guard case .preparation(.invalidPhase) = error else {
                Issue.record("the rejection was \(error)")
                return
            }
        }
        #expect(machine.snapshot().revision == 0)
    }
}
```
