# Scripting a Local owner

Drive a real `Local` owner step by step, read the history of what it accepted, and measure which declared edges the runs exercised.

A generated `Local` owner runs the same admission rules as a managed owner,
synchronously, and leaves every operation to its caller. ``ManualMachineTest``
consumes one and offers the same verbs: `send`, `commit`, `drainCommands`,
`deliver`, `acknowledgeExecution`, `retryAdmission`, `reconcile`,
`discardPending`, `pendingCompletions`, `reset(to:)`, `reset(to:expecting:)`,
`reset()` and `reset(expecting:)` when the schema declares a default initial
payload, the restoring resets of a schema with a `@Restoration` function, and
`close`.
Each calls the owner's own method and returns the owner's own result, so a test
sees real receipts, real command batches with real work, and real rejections.
Along the way, the harness records every change the owner accepts, with the edge
its receipt names, and a ``GraphCoverage`` combines those records into a
coverage report for the owner's graph.

The examples in this article test a transfer list whose downloads are keyed by
file:

```swift
import StateMachine
import StateMachineTesting
import Testing

@StateMachine(mode: .shared)
nonisolated enum Transfers: Sendable, Equatable {
    struct Browsing: Sendable, Equatable {
        var files: [Int: String] = [:]
        var failures: [Int] = []
    }
    struct Offline: Sendable, Equatable { var files: [Int: String] = [:] }

    @Initial case browsing(Browsing = Browsing())
    case offline(Offline)

    enum Input: Sendable, Equatable { case download(Int), cancel(Int), goOffline, goOnline }
    enum TransferFailure: Error, Sendable, Equatable { case unavailable }

    @Operation(activeIn: [Browsing.self])
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
        typealias Failure = TransferFailure
    }

    @Event
    enum Logged { typealias Payload = String }

    @Restoration
    fileprivate static func restore(_ files: [Int: String]) -> Restoration {
        .offline(Offline(files: files))
    }

    @Transition(on: Input.download, starts: [Download.self], emits: [Logged.self])
    fileprivate static func download(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Download> {
        Change(source, effects: [.logged("download \(id)"), .download(key: id, input: "file-\(id)")])
    }

    @Transition(on: Input.cancel, cancels: [Download.self])
    fileprivate static func cancel(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Cancel> {
        Change(source, effects: [.cancelDownload(key: id)])
    }

    @Transition(on: Input.goOffline)
    fileprivate static func goOffline(_ source: Browsing) -> Offline { Offline(files: source.files) }

    @Transition(on: Input.goOnline)
    fileprivate static func goOnline(_ source: Offline) -> Browsing { Browsing(files: source.files) }

    @Transition(onSuccess: Download.self, emits: [Logged.self])
    fileprivate static func downloaded(
        _ source: Browsing,
        _ contents: Download.Output,
        request: DownloadRequest
    ) -> Change<Browsing, Effect.Downloaded> {
        var files = source.files
        files[request.key] = contents
        return Change(
            Browsing(files: files, failures: source.failures),
            effects: [.logged("downloaded \(request.key)")]
        )
    }

    @Transition(onFailure: Download.self)
    fileprivate static func failed(
        _ source: Browsing,
        _ failure: Download.Failure,
        request: DownloadRequest
    ) -> Browsing {
        Browsing(files: source.files, failures: source.failures + [request.key])
    }
}

/// The download work among commands, in order.
func downloads(_ commands: [Transfers.Command]) -> [Transfers.DownloadWork] {
    commands.compactMap { command in
        if case .download(let work) = command { work } else { nil }
    }
}
```

## Drive a run

The test plays the runner. It sends an input, drains the batch the acceptance
queued, executes the commands it holds, delivers each result as a completion
sealed by the work, and acknowledges that each execution ended:

```swift
@Test func aDownloadRunsThroughTheRealDeliveryPath() throws {
    var test = ManualMachineTest(Transfers.Local())

    let accepted = try test.send(.download(1))
    #expect(accepted.revision == 1)

    let started = try test.drainBatch()
    let works = downloads(started.commands)
    #expect(works.map(\.key) == [1])
    #expect(works.map(\.input) == ["file-1"])

    guard case .committed(let receipt) = test.deliver(.download(works[0].succeeded("bytes"))) else {
        Issue.record("the completion of issued work was not admitted")
        return
    }
    #expect(receipt.snapshot.model == .browsing(Transfers.Browsing(files: [1: "bytes"])))
    let finished = test.drainFlattenedCommands()
    guard finished.count == 1, case .logged(let line) = finished[0] else {
        Issue.record("the completion did not log the download")
        return
    }
    #expect(line == "downloaded 1")
    #expect(test.acknowledgeExecution(works[0].execution) == .recorded)

    #expect(test.history.map(\.kind) == [.initial, .send, .delivery])
    #expect(test.history.map(\.edge) == [nil, "browsing.download", "browsing.downloaded"])
    #expect(test.exercisedEdges == ["browsing.download", "browsing.downloaded"])
}
```

``ManualMachineTest/drainBatch(fileID:filePath:line:column:)`` requires exactly
one queued batch, and ``ManualMachineTest/drainFlattenedCommands()`` transfers every
queued batch and returns their commands in order. `drainBatch` counts the
queued batches before it transfers any, so when several are queued it throws
and transfers none: they stay queued in the owner, and the next
`drainCommands()` or `drainFlattenedCommands()`, or the owner that
``ManualMachineTest/finish()`` returns, still holds their work. Admitting the completion
queued a batch of its own for the `logged` event that `downloaded` emits. It
retires the work that returned the result without a cancellation, because that
work has already finished producing it, and the runner acknowledges the
execution once it has actually ended. ``ManualMachineTest/deliver(_:)`` takes the schema's
`Completion` enum, so a completion is always one that the owner's own work
sealed, and ``ManualMachineTest/acknowledgeExecution(_:disposition:)``
records termination as `.terminated` unless told otherwise.

``ManualMachineTest/send(_:fileID:filePath:line:column:)`` throws a
``StateMachineTestFailure`` that describes the rejection, located at the call,
when the owner does not admit the input. To test a rejection itself, use
``ManualMachineTest/rejection(of:fileID:filePath:line:column:)``, which returns
the typed rejection and throws when the owner admits the input instead. Both
record each rejection the owner returned in ``ManualMachineTest/rejections``,
with the phase the owner held and the route the owner names for it:

```swift
@Test func goingOnlineWhileBrowsingIsRejected() throws {
    var test = ManualMachineTest(Transfers.Local())

    guard case .preparation(.invalidPhase) = try test.rejection(of: .goOnline) else {
        Issue.record("going online while browsing was rejected for another reason")
        return
    }
    #expect(test.phase == "browsing")
}
```

## Read the history

``ManualMachineTest/history`` begins with the owner's state when the harness
took it and gains one ``ManualMachineTest/Step`` for every call the owner
accepts. A step records its ``ManualMachineTest/Step/kind``, such as `.send`,
`.delivery`, `.retry`, or `.reset`; its ``ManualMachineTest/Step/trigger``; the
``ManualMachineTest/Step/source`` phase it left and the
``ManualMachineTest/Step/phase`` it holds; the accepted
``ManualMachineTest/Step/snapshot``; and the ``ManualMachineTest/Step/edge``
that produced it. Edges are identified as the graph identifies them,
`"<phase>.<edge>"`. A call that the owner rejects, or a stale delivery, accepts
nothing and adds no step:

```swift
@Test func cancellingOneKeyRevokesOnlyItsWork() throws {
    var test = ManualMachineTest(Transfers.Local())
    try test.send(.download(1))
    try test.send(.download(2))
    let works = downloads(test.drainFlattenedCommands())

    try test.send(.cancel(1))
    _ = test.drainFlattenedCommands()
    guard case .stale = test.deliver(.download(works[0].succeeded("late"))) else {
        Issue.record("the cancelled key's result was not stale")
        return
    }
    guard case .committed = test.deliver(.download(works[1].failed(.unavailable))) else {
        Issue.record("the remaining key's failure was not admitted")
        return
    }

    #expect(test.snapshot().model == .browsing(Transfers.Browsing(failures: [2])))
    #expect(
        test.history.map(\.edge) == [
            nil, "browsing.download", "browsing.download", "browsing.cancel", "browsing.failed",
        ]
    )
}
```

Each step names the edge from the receipt of the change, whose
`edgeID` is the identifier of the edge that prepared it. A router's choice is
therefore exact even between edges that share a destination, and a change that
takes no edge, such as a reset or closure, names none.

## Check invariants

A ``ManualMachineTest/Invariant`` names a condition that every accepted snapshot
must satisfy. The harness checks each invariant against the owner's state when
it takes the owner and against every snapshot the owner accepts afterward, and
records each failure in ``ManualMachineTest/violations`` without stopping the
run. ``ManualMachineTest/requireInvariants(fileID:filePath:line:column:)``
throws if any was violated:

```swift
@Test func anInvariantReportsTheSnapshotThatBrokeIt() throws {
    let single = ManualMachineTest<Transfers.Local>.Invariant("at most one file") { snapshot in
        guard case .browsing(let browsing) = snapshot else { return true }
        return browsing.value.files.count <= 1
    }
    var test = ManualMachineTest(Transfers.Local(), invariants: [single])
    try test.send(.download(1))
    try test.send(.download(2))
    for work in downloads(test.drainFlattenedCommands()) {
        _ = test.deliver(.download(work.succeeded("file \(work.key)")))
    }

    #expect(test.violations.map(\.invariant) == ["at most one file"])
    #expect(throws: StateMachineTestFailure.self) { try test.requireInvariants() }
}
```

## Reset and reach the rest of the owner

Every reset of the owner is a verb of the harness, recorded as a
``ManualMachineTest/Step/Kind/reset`` step without an edge. A schema whose
`@Initial` case declares a default, as `Transfers` does, gives the harness
`reset()` and `reset(expecting:)`, which install that default as the owner's
own do; for a schema without one, `test.reset()` does not compile. The
restoring resets of a schema with a `@Restoration` function are verbs as well.
``ManualMachineTest/finish()`` ends the harness and returns the owner it drove.
The harness holds no work of its own, so every batch the test has not drained
is still queued in that owner:

```swift
@Test func aResetAndARestoredOwnerAreRecordedAndReturned() throws {
    var test = ManualMachineTest(Transfers.Local())

    try test.send(.goOffline)
    try test.reset()
    #expect(test.phase == "browsing")

    try test.reset(restoring: [7: "kept"])
    #expect(test.history.last?.kind == .reset)
    #expect(test.phase == "offline")

    var owner = test.finish()
    try owner.send(.goOnline)
    #expect(owner.snapshot().model == .browsing(Transfers.Browsing(files: [7: "kept"])))
}
```

``ManualMachineTest/withOwner(_:)`` lends the owner to a closure, for a member
the harness does not offer. The owner reports no receipt to the harness there,
so a change accepted inside it is recorded as an
``ManualMachineTest/Step/Kind/unattributed`` step with no edge, and when the
closure makes several changes the harness sees only the last. The others count
toward ``ManualMachineTest/unobservedChanges``, the history is no longer
complete, and ``ManualMachineTest/requireInvariants(fileID:filePath:line:column:)``
and ``GraphCoverage/requireCoverage(excluding:includingRejectingRouters:fileID:filePath:line:column:)``
fail rather than vouch for snapshots no invariant checked. The harness also
compares the owner the closure leaves with the one it lent, so a closure that
assigns another owner, even a fresh one with an equal model at the same
revision, counts toward ``ManualMachineTest/replacedOwners`` and leaves the
history incomplete in the same way:

```swift
@Test func changesInsideWithOwnerAreNotVouchedFor() throws {
    var test = ManualMachineTest(Transfers.Local())

    try test.withOwner { owner throws(Transfers.SendRejection) in
        try owner.send(.goOffline)
        try owner.send(.goOnline)
    }
    #expect(test.unobservedChanges == 1)
    #expect(throws: StateMachineTestFailure.self) { try test.requireInvariants() }
}
```

A closure that throws infers its error as `any Error` unless it names the
failure type, as `owner throws(Transfers.SendRejection) in` does here. Without
the annotation, `withOwner` throws `any Error`, which a function with typed
throws cannot propagate and which loses the owner's typed rejection.

The harness is noncopyable, because it holds the noncopyable owner, and the
`#expect` macro cannot read a property of a noncopyable value in place. Read
``ManualMachineTest/isQuiescent`` into a local first:

```swift
@Test func aClosedRunSettles() throws {
    var test = ManualMachineTest(Transfers.Local())
    try test.send(.goOffline)
    test.close()
    _ = test.drainCommands()

    let quiescent = test.isQuiescent
    #expect(quiescent)
}
```

## Measure coverage

``GraphCoverage`` measures one owner type, so only runs of that owner count: a
run of another schema, even one with the same declared structure, does not
compile as an argument. Record the history of each run with
``GraphCoverage/record(_:)``, and then read ``GraphCoverage/unexercisedEdges``,
``GraphCoverage/unvisitedPhases``, ``GraphCoverage/unexercisedRouters``, and
``GraphCoverage/unexercisedRejectingRouters``.
Every step comes from a real owner admitting a real change and names the edge
from that change's receipt, so an exercised edge is one that a test actually
took, even when a router chooses between edges with the same destination:

```swift
@Test func twoRunsExerciseEveryDeclaredEdge() throws {
    var coverage = GraphCoverage(for: Transfers.Local.self)

    var transfers = ManualMachineTest(Transfers.Local())
    try transfers.send(.download(1))
    try transfers.send(.download(2))
    let works = downloads(transfers.drainFlattenedCommands())
    _ = transfers.deliver(.download(works[0].succeeded("one")))
    _ = transfers.deliver(.download(works[1].failed(.unavailable)))
    for work in works {
        #expect(transfers.acknowledgeExecution(work.execution) == .recorded)
    }
    coverage.record(transfers)
    #expect(coverage.unexercisedEdges.map(\.id) == ["browsing.cancel", "browsing.goOffline", "offline.goOnline"])

    var travel = ManualMachineTest(Transfers.Local())
    try travel.send(.cancel(3))
    try travel.send(.goOffline)
    try travel.send(.goOnline)
    coverage.record(travel)

    #expect(coverage.unexercisedEdges.isEmpty)
    #expect(coverage.unvisitedPhases.isEmpty)
    try coverage.requireCoverage()
}
```

``GraphCoverage/requireCoverage(excluding:includingRejectingRouters:fileID:filePath:line:column:)``
throws a failure that lists each unexercised edge and router, each unvisited
phase, each invariant violation that a recorded run reported, and the number of
changes made inside `withOwner` that the harness never observed. Pass the
identifiers of the edges and routers that no test is meant to reach in
`excluding:`; both are spelled `"<phase>.<name>"`. A router counts as exercised
once a step takes one of its candidates. A router without candidates exists
only to decline an input or a completion, so no step can exercise it: coverage
requires it only with `includingRejectingRouters: true`, and
``GraphCoverage/unexercisedRejectingRouters`` lists each one that no recorded
run saw decline. A rejection counts only when it comes from
the real owner, and only for the route the owner names: an input router's
through `rejection(of:)` or a `send` that failed, which
``ManualMachineTest/rejections`` records with the owner's typed
``ManualMachineTest/Rejection/reason``, and a completion router's or completion
edge's through a `deliver` or `reconcile(id:)` whose own preparation it refused,
as that call's result reports, which ``ManualMachineTest/completionRejections``
records. A second delivery of a completion the owner already retains prepares
nothing, so its result reports no refusal and it counts nothing. A completion that a
router refuses while `Loading` and that `reconcile(id:)` admits in `Paused`
therefore counts the router as declining. Beyond routers without candidates,
coverage requires nothing of rejections: neither that a router that chooses an
edge has also declined, nor that a function that can throw has thrown.
