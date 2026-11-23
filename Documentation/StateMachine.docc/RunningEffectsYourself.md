# Running effects yourself

Take each edge with `Owned`, or drive a `Local` owner step by step, and execute the work it describes.

`Owned` and `Local` leave execution to the caller. `Owned` runs an authored
edge and hands back its effects as inert values, with no runtime at all.
`Local` runs the same admission rules as a managed owner, synchronously, and
queues the work it accepts as commands for the caller to execute. Neither
starts a task, so a test or a custom runner decides exactly when each step
happens.

This article uses one search graph. Its inheritance clause lists `Equatable`,
which makes its effects comparable.

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
error that `withValue` rethrows.

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
and queues nothing, so a run of plain edits never waits for a drain. The caller drains whole batches, releases mutating access, executes the
commands, and then reports back.

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
default. Each batch holds its acceptance's receipt, its `terminal` flag, and its
commands, ordered with cancellations first and then starts and events in the
order the edge wrote them. A start carries the operation's work, with its
`input`, its `key` for a keyed operation, its `request`, and its `execution`
handle. Cancelling a key and revoking a scope each produce `.cancel(execution)`
for the work they end. Admitting a completion, or discarding a retained one with
`discardPending(id:)`, retires the work that returned it without a
cancellation, because that work has already finished producing its result. A
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
`deliver(_:)` returns a `DeliveryResult` with five outcomes.

- `.committed(receipt)` when the completion was admitted.
- `.pending(id, status)` when the outcome is retained.
- `.refused(id, reason, routeID:)` when this call prepared the outcome and its
  router or completion edge threw `reason`, retaining the outcome for
  reconciliation and naming that router or edge.
- `.stale` when the operation has lost its authority or its outcome already
  settled.
- `.foreignOwner` when a different owner issued the completion.

`acknowledgeExecution(_:disposition:)` records that the execution ended, using
`.terminated` by default or `.skippedBeforeStart` for work the caller never
began, and returns an `AcknowledgmentResult` of `.recorded`, `.duplicate`, or
`.foreignOwner`. An asynchronous runner must retain its execution handles until
the tasks terminate, and a cancellation request alone does not acknowledge
termination.

A retained delivery may still need admission or explicit reconciliation after
execution has ended. Draining and acknowledging never admit a retained
completion. For a completion pending on capacity, `retryAdmission(id:)` rechecks
the prepared candidate and commits if capacity is available and the candidate is
still current. An intervening revision requires `reconcile(id:)` while the
operation remains active. Both return a `ReconcileResult` of `.committed`,
`.pending`, `.refused` (when the call's own preparation was refused),
`.inProgress`, or `.notPending`. Because `retryAdmission(id:)` prepares nothing,
it never reports `.refused`. `discardPending(id:)` returns a `DiscardResult` of
`.discarded`, `.rejected`, or `.notPending`, and `pendingCompletions()` reads
the retained completions. A `Local` never prepares a completion again on its
own.

`isQuiescent` is `true` once the owner is closed, its terminal batch is drained,
and every execution and delivery obligation has settled. `Local` also has
`reset(to:)`, which revokes all work and queues its cancellations,
`reset(to:expecting:)`, which does so only while the owner holds a given
snapshot's root, and `LocalConfiguration`, the schema's name for ``Limits``,
which bounds its queue, plan size, and execution reservations. A graph with no
operations or events has no commands at all, so its `Local` needs no draining.

Every generated `Local` conforms to ``LocalStateMachine``, to
``DrainingLocalStateMachine`` and ``DeliveringLocalStateMachine`` when it has
commands and operations, to ``DefaultingLocalStateMachine`` when its `@Initial`
case declares a default payload, and to ``RestoringLocalStateMachine`` when its
schema declares a `@Restoration` function. These protocols let a harness such as
`ManualMachineTest` in `StateMachineTesting` drive any graph's `Local`, and
conforming confers no authority. Besides the owner's own verbs, they read only
graph metadata and the receipt a result already holds.

## Serialize uncooperative work on Local

Managed hosts start each admitted operation in its own task right away. When a
new transition supersedes earlier work, the host cancels the old task and can
launch the replacement while that superseded task is still running. That default
fits cooperative async work. Synchronous work off `@MainActor`, such as Core
Graphics rendering or Vision detection, often ignores Swift task cancellation
until the call returns. Launching a replacement immediately would overlap two
heavy calls in memory even though the older call's completion will be `.stale`.

To reflect the newest input synchronously while running at most one heavy call
at a time, drive a caller-owned `Schema.Local` with one `running` slot and one
`pending` slot. Each generated schema exposes the types that runner stores.

- `Schema.ExecutionHandle` is `Equatable` and `Sendable` and matches the handle
  carried by `work.execution` and `.cancel(handle)`.
- `Schema.<Operation>Work`, such as `SerializedPipeline.DetectWork` or
  `SerializedPipeline.RenderWork`, holds the work attached to a start command
  and can also sit in a separate out-of-band slot outside the lane.
- `Schema.Completion` wraps `work.succeeded(_:)` or `work.failed(_:)`, so
  heterogeneous operations can share one
  `@MainActor () async -> Schema.Completion` pending closure.

```swift
struct Running: Sendable {
    let handle: SerializedPipeline.ExecutionHandle
    let task: Task<Void, Never>
}

struct Pending {
    let handle: SerializedPipeline.ExecutionHandle
    let work: @MainActor () async -> SerializedPipeline.Completion
}

func makePendingWork(
    for command: SerializedPipeline.Command,
    detect: @escaping @MainActor (SerializedPipeline.Item) async -> [String],
    render: @escaping @MainActor (SerializedPipeline.RenderJob) async -> String
) -> Pending? {
    switch command {
    case .detect(let work):
        return Pending(handle: work.execution) {
            .detect(work.succeeded(await detect(work.input)))
        }
    case .render(let work):
        return Pending(handle: work.execution) {
            .render(work.succeeded(await render(work.input)))
        }
    case .cancel, .notice:
        return nil
    }
}
```

Apply five rules to that two-slot runner.

- **Match `.cancel(handle)` by exact handle.** When `handle` matches `pending`,
  clear `pending = nil` immediately to release captured inputs and call
  `acknowledgeExecution(handle, disposition: .skippedBeforeStart)`. When it
  matches `running`, call `task.cancel()`, keep `running` occupied, and wait
  until the driver returns before acknowledging termination. Leave any unrelated
  live handle untouched, such as an out-of-band operation stored outside the
  lane.
- **Guard the single pending slot.** Require `pending == nil` before installing
  new work so a graph change that admits two concurrent lane operations cannot
  silently overwrite an uncancelled ticket.
- **Settle scheduling state before pumping outward callbacks.** A batch lists
  cancellations first and then starts and events in authored order, so an
  `@Event` can precede a start in the same batch. Process every cancellation and
  start across all drained batches and start pending work before pumping outward
  callbacks (`onEvent`, `onChange`, or test hooks) from a FIFO queue under a
  reentrancy guard. A callback that synchronously calls `send` then sees
  installed handles and preserves observer order.
- **Separate pre-start cancellation from physical termination.** Inside the
  launched task, check `Task.isCancelled` before calling the driver. If already
  cancelled, clear `running`, acknowledge `.skippedBeforeStart`, start any
  pending work, and pump queued notifications. Otherwise await the driver to
  physical return while holding only a weak reference to the runner across the
  suspension. Then clear `running`, acknowledge `.terminated`, call
  `deliver(completion)` (draining and enqueueing any committed change), start
  `pending` only if `running` is still `nil` because a committed delivery can
  chain a successor into `running`, and pump notifications.
- **Close and tear down cleanly.** On `close()`, drain the terminal batch,
  acknowledge skipped pending work, and cancel the running task without early
  acknowledgment. `isQuiescent` becomes `true` only after the running call
  returns and is acknowledged. Cancel the running task in `deinit`.

This pattern keeps at most one call physically in flight and one pending closure
queued. Synchronous C or Core Graphics calls still run to completion, and total
process memory and completion latency remain unbounded. Read
[`SerializedPipeline.swift`](https://github.com/kylehughes/swift-state-machine/blob/main/Sources/StateMachineExamples/SerializedPipeline.swift)
for a complete, tested implementation.
