# Running effects yourself

Take each edge with `Owned`, or drive a `Local` owner step by step, and execute the work it describes.

`Owned` and `Local` leave execution to the caller. `Owned` runs an authored
edge and hands back its effects as inert values, with no runtime at all.
`Local` runs the same admission rules as a managed owner, synchronously, and
queues the work it accepts as commands for the caller to execute. Neither
starts a task, so a test or a custom runner decides exactly when each step
happens.

This article uses one search graph. Its inheritance clause lists `Equatable`,
which makes its effects comparable:

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

    enum Input: Sendable, Equatable { case search(String), cancel }

    @Operation(activeIn: [Searching.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
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

## Take edges with Owned

`Owned` runs the authored edge and leaves its effects to the caller. If the edge
returns the destination payload without throwing, the consuming method returns
the next `Owned` directly. If it returns `Change` without throwing, the method
returns `Change<Owned<Next>, Effect.<Edge>>` with ordered effects. An edge that
uses typed throws or returns `Advance` produces
`Advance<Owned<Source>, Owned<Next>, Intent, Failure>`, with `Never` for
`Intent` when the edge starts and emits nothing and `Effect.<Edge>` otherwise.
The `effect` property on each value widens it to the schema-wide `Effect`.
`takeValue()` consumes an owner and returns its payload, whereas `withValue`
borrows it for a closure, which can return a noncopyable value or throw a typed
error that `withValue` rethrows:

```swift
func ownedSearch() {
    let change = Lookup.owned().begin("swift")
    print(change.effects == [.fetch("swift")])
    print(change.effects.map(\.effect))

    let idle = change.next.cancel()
    idle.withValue { _ in }
}

func ownedFound() {
    let change = Lookup.owned().begin("swift")
    let found = change.next.received("Swift.org")
    print(found.takeValue().answer)
}
```

`Owned<Searching>` offers `cancel()` and `received(_:)`, and `Owned<Idle>`
offers only `begin(_:)`. A completion edge is an `Owned` method that takes the
operation's `Output` or `Failure`, and a `request:` argument when the edge takes
the request, which `Owned` callers construct as plain data. A success edge of
an operation whose `Output` is `Void` takes no output argument. When a
completion router chooses among a phase's completion edges, `Owned` offers the
router's method instead.

`Owned` checks nothing that a host checks, such as operation authority or
revision. Its completion methods take ordinary values because the caller owns
the whole workflow, and its effects never become hosted work.

## Drive a Local owner

`Local` is a noncopyable value with no automatic runner or observation
subscription. Its methods are `mutating` and synchronous. An acceptance that
starts or cancels work, or emits an event, queues a batch of commands, and so
does closure. Any other acceptance returns its receipt from `send` or `commit`
and queues nothing, so a run of plain edits never waits for a drain. The caller
drains whole batches, releases mutating access, executes the commands, and
then reports back:

```swift
@StateMachine(mode: .shared)
nonisolated enum MessageFlow: Sendable {
    struct Ready: Sendable { let message: String }
    struct Sent: Sendable { let message: String }

    @Initial case ready(Ready)
    @Terminal case sent(Sent)

    enum Input: Sendable { case send }

    @Operation(activeIn: [Ready.self])
    enum Publication { typealias Input = String }

    @Event
    enum Logged { typealias Payload = String }

    @Transition(on: Input.send, starts: [Publication.self], emits: [Logged.self])
    fileprivate static func send(_ source: Ready) -> Change<Ready, Effect.Send> {
        Change(source, effects: [.logged("publishing"), .publication(source.message)])
    }

    @Transition(onSuccess: Publication.self)
    fileprivate static func published(_ source: Ready) -> Sent {
        Sent(message: source.message)
    }
}

func publishLocally() throws {
    var machine = MessageFlow.Local(MessageFlow.Ready(message: "Approved"))
    try machine.send(.send)

    for batch in machine.drainCommands() {
        for command in batch.commands {
            switch command {
            case .logged(let line):
                print(line)
            case .publication(let work):
                print(work.input)
                let delivery = machine.deliver(work.succeeded())
                let acknowledgment = machine.acknowledgeExecution(work.execution)
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
    _ = machine.drainCommands()
    print("Settled: \(machine.isQuiescent)")
}
```

`drainCommands(limit:)` transfers whole batches in commit order, all of them by
default. A batch holds its acceptance's receipt, its `terminal` flag, and its
commands: cancellations first, then starts and events in the order the edge
wrote them. A start carries the operation's work, with its `input`, its `key`
for a keyed operation, its `request`, and its `execution` handle. Cancelling a
key and revoking a scope each produce `.cancel(execution)` for the work they
end. Admitting a completion, or discarding a retained one with
`discardPending(id:)`, retires the work that returned it without a
cancellation, because that work has already finished producing its result; a
completion edge still cancels any other work it revokes. The caller
acknowledges the retired work's execution as usual.

## Deliver completions and acknowledge executions

`Local.deliver` accepts one operation's sealed completion, or the schema's
`Completion` enum that wraps it. `work.succeeded(value)` and
`work.failed(value)` build it, and an operation whose `Output` is `Void` has
`succeeded()`. An operation that cannot fail has no `failed`, and its
completion's `value` is the output itself, where a fallible operation's
completion holds a `result`. An ordinary output value cannot stand in for that
authority. Copying a valid completion permits repeated delivery attempts, while
successful terminal admission retires the operation at most once.

Returning a completion and acknowledging termination are separate obligations.
`deliver(_:)` returns a `DeliveryResult`: `.committed(receipt)`,
`.pending(id, status)` when the outcome is retained, `.refused(id, reason,
routeID:)` when this call prepared the outcome and its router or completion
edge threw `reason`, which retains it for reconciliation and names that router
or edge, `.stale` when the operation
has lost its authority or its outcome already settled, and `.foreignOwner` when
a different owner issued the completion. `acknowledgeExecution(_:disposition:)`
records that the execution ended, `.terminated` by default or
`.skippedBeforeStart` for work the caller never began, and returns
`AcknowledgmentResult`: `.recorded`, `.duplicate`, or `.foreignOwner`. An
asynchronous runner must retain its execution handles until the tasks
terminate, and a cancellation request alone does not acknowledge termination.

A retained delivery may still need admission or explicit reconciliation after
execution has ended. Draining and acknowledging never admit a retained
completion. For a completion pending on capacity, `retryAdmission(id:)` rechecks
the prepared candidate. It commits if capacity is available and the candidate
is still current. An intervening revision requires `reconcile(id:)` while the
operation remains active. Both return a `ReconcileResult`: `.committed`,
`.pending`, `.refused` when the call's own preparation was refused,
`.inProgress`, or `.notPending`; `retryAdmission(id:)` prepares nothing, so it
never reports `.refused`. `discardPending(id:)` returns a
`DiscardResult`: `.discarded`, `.rejected`, or `.notPending`, and
`pendingCompletions()` reads the retained completions. A `Local` never prepares
a completion again on its own.

`isQuiescent` is `true` once the owner is closed, its terminal batch is drained,
and every execution and delivery obligation has settled. `Local` also has
`reset(to:)`, which revokes all work and queues its cancellations,
`reset(to:expecting:)`, which does so only while the owner holds a given
snapshot's root, and
`LocalConfiguration`, the schema's name for ``Limits``, bounds its queue, plan
size, and execution reservations. A graph with no operations or events has no
commands at all, so its `Local` needs no draining.

Every generated `Local` conforms to ``LocalStateMachine``, to
``DrainingLocalStateMachine`` and ``DeliveringLocalStateMachine`` when it has
commands and operations, to ``DefaultingLocalStateMachine`` when its `@Initial`
case declares a default payload, and to ``RestoringLocalStateMachine`` when its
schema declares a `@Restoration` function. These protocols let a harness such as
`ManualMachineTest` in `StateMachineTesting` drive any graph's `Local`, and
conforming confers no authority: besides the owner's own verbs, they read graph
metadata and the receipt a result already holds.
