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
query while the fetch runs, and finishes when the fetch returns:

```swift
import StateMachine
import StateMachineSchema

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable, Equatable {
    struct Idle: Sendable, Equatable {}
    struct Searching: Sendable, Equatable { let query: String }
    struct Found: Sendable, Equatable { let answer: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    case found(Found)

    enum Scope { case search, history }
    enum Input: Sendable { case search(String), refine(String), cancel }

    @Operation(scope: Scope.search, activeIn: [Searching.self], admission: .latest)
    enum Fetch {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }

    @Operation(scope: Scope.history, activeIn: [Searching.self], admission: .latest)
    enum Record {
        typealias Input = String
        typealias Output = Void
        typealias Failure = Never
    }

    @Transition(on: Input.search, starts: [Fetch.self, Record.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.record(query), .fetch(query)])
    }

    @Transition(on: Input.refine)
    fileprivate static func refine(_ source: Searching, _ query: String) -> Searching {
        Searching(query: query)
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
and which typed failure it throws.

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

`Local` is a value with no runner. Accepting an input queues a batch of
commands, and the test plays the runner: it drains the batches, supplies each
result, and acknowledges that each execution ended. Every call is synchronous,
so a test needs no waiting:

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
`deliver` accepts it and returns a `DeliveryResult`. Delivery and acknowledgment
are separate obligations, so the test reports both. Acknowledging the same
execution twice is harmless and reports `.duplicate`.

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

Each accepted change queues one batch, including a change that starts nothing.
When the queue is full, a completion that is otherwise admissible is retained as
`.pending(id, .waitingForCapacity)`, with its prepared candidate. Draining and
acknowledging never change the model. `retryAdmission(id:)` retries the retained
candidate without preparing it again. In this test, draining frees the queue's
only slot and the revision stays current, so the retry commits. A queue of one
batch makes the case easy to build:

```swift
extension LookupLocalTests {
    @Test func aRetainedCompletionIsAdmittedWhenCapacityFrees() throws {
        var machine = Lookup.Local(configuration: try Lookup.LocalConfiguration(commits: 1))
        try machine.send(.search("swift"))
        guard case .fetch(let fetch)? = machine.drainCommands(limit: 1).first?.commands.last else {
            Issue.record("the search did not start a fetch")
            return
        }
        try machine.send(.refine("swift testing"))

        // The queue still holds the refinement's batch, so the completion waits.
        guard case .pending(let id, .waitingForCapacity) = machine.deliver(fetch.succeeded("Swift.org")) else {
            Issue.record("the completion was not retained")
            return
        }
        #expect(machine.snapshot().model == .searching(Lookup.Searching(query: "swift testing")))

        let drained = machine.drainCommands(limit: 1)
        #expect(drained.map(\.receipt.revision) == [2])
        #expect(machine.snapshot().revision == 2)

        guard case .committed(let receipt) = machine.retryAdmission(id: id) else {
            Issue.record("the retained completion was not admitted")
            return
        }
        #expect(receipt.revision == 3)
        #expect(machine.snapshot().model == .found(Lookup.Found(answer: "Swift.org")))
    }
}
```

## Test hosted behavior with gated drivers

A hosted owner runs its drivers itself. A test supplies stub drivers and holds
each one at a gate, so the order of events is the test's choice and no test
sleeps. A gate is a value the test opens once:

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
                return .success("Results for \(query)")
            },
            record: { _ in .success(()) }
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

Pass a deadline to `shutdownAndWait(deadline:)` to bound the wait. It returns
`.quiescent` after the owner processes its terminal batch and its execution and
delivery obligations settle. On timeout it returns `.timedOut(diagnostics)`. The
owner stays closed. `diagnostics.outstandingExecutions` identifies the
reservations it still tracks, including any outstanding delivery or preparation.
The diagnostic handles grant no authority. Release the driver, then call
`shutdownAndWait()` again to wait without a deadline.

## Test a presentation with a test double

A presentation drives and observes any `MainActorStateMachineHost`. A test double
conforms to that protocol, which confers no authority, and lets a test deliver
snapshots in any order and see how the presentation reacts. The double returns
its registration as a `RuntimeMainActorSubscription`, which `init(onCancel:)`
creates. Its action runs exactly once, whether the presentation calls `cancel()`
or releases the registration. A release runs the action in a later turn on the
main actor, while `cancel()` runs it before returning:

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
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription {
        guard self.receive == nil else { throw .capacityExceeded }
        self.receive = receive
        return RuntimeMainActorSubscription(onCancel: { [weak self] in
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
    @Test func aPresentationKeepsTheNewestSnapshotAndReleasesItsRegistrationOnce() throws {
        let host = FakeHost()
        let presentation = try ObservableStateMachinePresentation(host)

        host.deliver(FakeHost.Snapshot(revision: 2, title: "Second"))
        host.deliver(FakeHost.Snapshot(revision: 1, title: "First"))
        #expect(presentation.snapshot.title == "Second")

        presentation.stopObserving()
        presentation.stopObserving()
        #expect(host.cancellations == 1)
    }

    @Test func aCommittedProposalIsShownBeforeCommitReturns() throws {
        let host = FakeHost()
        let presentation = try ObservableStateMachinePresentation(host)

        guard case .committed = presentation.commit(FakeHost.Prepared(title: "Renamed")) else {
            Issue.record("the proposal was not committed")
            return
        }
        #expect(presentation.snapshot.title == "Renamed")
    }
}
```

The first test delivers revision 1 after revision 2 and expects the
presentation to keep the newer snapshot. The second sends a proposal through the
presentation and reads the result in the same turn.

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

The compiler reports `instance method 'cancel()' requires the types 'Lookup.Idle'
and 'Lookup.Searching' be equivalent`. A test cannot exercise a call that does
not compile, and a test does not need to. Prefer these typed calls, on `Owned`
or on an `Observed` committed to its owner, wherever the caller knows the phase.
If the edge is removed or moved, the caller stops compiling.

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
