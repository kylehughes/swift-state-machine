# Hosting a graph

Choose the owner that runs a graph's work, then drive it with inputs and observations.

A schema generates the owners that hold its state. `Owned` and `Local` leave
every operation to the caller, as <doc:RunningEffectsYourself> describes. The
four managed owners, `MainActorHost`, `Shared`, `ActorHost`, and
`IsolatedHost`, run their operations through drivers, deliver the results to
their own completion edges, and publish each accepted snapshot. They differ in
where their state lives and how a caller reaches it.

The examples in this article host one search graph.

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

    enum Input: Sendable { case search(String), cancel, clear }

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

    @Transition(on: Input.clear)
    fileprivate static func clear(_ source: Found) -> Idle { Idle() }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Searching, _ answer: Fetch.Output) -> Found {
        Found(answer: answer)
    }
}
```

## Choose an owner

| Owner | Modes | Where its state lives | Who runs its work |
| --- | --- | --- | --- |
| `Owned<Phase>` | All | A noncopyable value the caller holds | The caller, from inert effects |
| `Local` | `shared`, `isolated` | A noncopyable value with `mutating` methods | The caller, from drained commands |
| `MainActorHost` | `shared`, `isolated` | The main actor | Its drivers, on the main actor |
| `Shared` | `shared` | A `Sendable` class with synchronous methods | Its drivers, outside its lock |
| `ActorHost` | `shared` | An actor of its own | Its drivers |
| `IsolatedHost<Owner>` | `shared`, `isolated` | An actor instance its creator chooses | Its drivers, on that actor |

Start from the code that reads and changes the state.

- A screen or a view model works on the main actor, so use `MainActorHost`. It
  is `Observable` on iOS 17, macOS 14, and later, and the `StateMachineUI`
  presentations wrap it on earlier systems.
- A service that is already an actor uses `IsolatedHost`, created with that
  actor. Every call is a synchronous call within the actor, and drivers run on
  it and can change its state directly.
- Work that needs its own serial context, away from the main actor, uses
  `ActorHost`. Every call awaits.
- State that several isolation domains change synchronously, such as a cache
  read from a background queue and from the UI, uses `Shared`. Its `send` makes
  one attempt and reports a conflict when another commit wins.
- A test, a deterministic simulation, or a custom runner—such as serializing
  synchronous work that outlives cancellation in
  [Serialize uncooperative work on Local](<doc:RunningEffectsYourself#Serialize-uncooperative-work-on-Local>)—uses
  `Local`, and logic that holds a unique resource uses `Owned`.

An `isolated` schema's values need not be `Sendable`, so it generates only the
owners that keep them on one actor: `MainActorHost`, `IsolatedHost`, `Local`,
and `Owned`. A schema that needs fewer owners lists them, as
[Choose the owners to generate](<doc:DeclaringAGraph#Choose-the-owners-to-generate>)
describes.

## Create a managed owner

A managed owner takes a driver for each operation when it is created and keeps
that selection for its lifetime. Pass each driver as its own closure, labeled
with the operation's effect case followed by `Driver`, so `Fetch` takes
`fetchDriver:`. The closures follow the order the operations are declared, and
each is required. With the default that `Lookup` declares, the host also needs
no initial payload.

```swift
@MainActor
func search() async throws {
    let host = Lookup.MainActorHost(fetchDriver: { query in "Results for \(query)" })

    let receipt = try host.send(.search("swift"))
    print("Accepted revision \(receipt.revision)")

    await host.shutdown()
}
```

A driver for an operation that cannot fail returns the `Output` directly, and a
fallible operation's driver returns `Result<Output, Failure>`. A driver of a
keyed operation takes the key before the input, and an operation without input
has a driver that takes no argument. Drivers are `@Sendable` for `Shared` and
`ActorHost` and `@MainActor` for `MainActorHost`, and an `IsolatedHost` driver
receives its owning actor first.

The same owner also takes a `Drivers` value through `drivers:`, a
`MainActorDrivers` value for `MainActorHost`, or its own nested `Drivers` for
`IsolatedHost`. Prefer the value when one set of
drivers serves several owners, when a test injects stubs, and when a graph has
many operations, where one value is easier to read and pass than a long list of
closures.

```swift
func makeOwners(drivers: Lookup.Drivers) -> (Lookup.Shared, Lookup.ActorHost) {
    (Lookup.Shared(drivers: drivers), Lookup.ActorHost(drivers: drivers))
}
```

After the drivers, a schema with events takes one required handler per event,
labeled `on` followed by the event's name. `configuration:` bounds the owner's
capacity with a `Configuration`, the schema's name for
``ManagedConfiguration``. Its defaults allow 256 queued batches, 64 effects per
plan, 256 execution reservations, and 128 subscribers, and its initializer
throws for a bound that is not positive. `completionPolicy:` chooses how the
owner settles a completion that does not commit, as
[Settle completions that do not commit](<doc:HostingAGraph#Settle-completions-that-do-not-commit>)
explains. A graph with no operations has no drivers, `runningCount`, delivery,
reconciliation, or completion-policy surface on any owner.

## Send an input

Every owner except `Owned` routes, prepares, and attempts to admit an `Input`
through `send(_:)`. It returns a `Receipt` or throws `SendRejection`.
`ActorHost.send(_:)` is `async`, and `Local.send(_:)` is `mutating`.
`.preparation(PreparationRejection)` covers a missing route (`.invalidPhase`)
and a router or edge that declines the input. `.commit(CommitRejection)` means
the owner refused the prepared change, including `.commit(.plan(_))` for a
defective effect plan. A closed owner reports `.commit(.closed)` before any plan
defect, because closing removes the scopes that a plan's work needs.
`CommitRejection` and the `Capacity` and `PolicyFailure` values it carries are
types of the `StateMachine` module, shared by every graph. `Shared.send` makes
exactly one attempt and is the only owner where a concurrent write can cause
`.commit(.conflict)`. The other managed owners read, prepare, and admit in one
isolated turn.

The receipt carries the accepted `revision` and the complete `Snapshot`. A
snapshot has one case per phase, holding an `Observed<Phase>` whose `value` is
the payload. A `Snapshot` and a `Receipt` print the phase, the revision, and
`closed` when they record closure, as in `searching, revision 1`. An `Observed`
prints its payload type in place of the phase, as in `Searching, revision 1`.
None of them prints payload contents. <doc:ObservingState> covers reading
snapshots as they change.

## Act on the observation a caller saw

`send(_:)` acts on whatever the owner currently holds. Use it for an event that
should apply to the current state, such as a tap that means "cancel the current
search", a push notification, or a timer.

`Observed<Phase>` also has one method for each edge whose source is that phase.
Each returns a `Prepared` proposal, which an owner's `commit(_:)` consumes and
admits only if that observation is still the owner's current revision. An edge
that cannot fail needs no `try`, and an edge that throws a typed failure throws
exactly that failure from the observed method. `commit` returns a
`CommitResult`, either `.committed(receipt)` or `.rejected(reason, current:)`,
and the result is not discardable. A defective effect plan is carried inside
`Prepared` with the snapshot it was prepared from, and `commit` reports it as
`.rejected(.plan(_), current:)` unless that snapshot belongs to another owner or
the owner has closed, which it reports first. A rejected commit changes neither
model data nor operation authority. `ActorHost.commit(_:)` is `async`, and
`Local.commit(_:)` is `mutating`.

Use this path when the action belongs to the exact observation the user saw, and
handle `.conflict` if an intervening commit advances the same open owner.
Closing the owner takes precedence and produces `.closed`.

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

The compiler checks the call. If `cancel` is removed from the schema or moves to
another phase, this function stops compiling, whereas `send(.cancel)` routes at
run time and fails with `.preparation(.invalidPhase)`. A completion edge has no
method on an observation, because an owner admits a completion only through its
own delivery and a caller cannot commit a result the driver never produced.
`prepare(_:on:)` routes an input against a snapshot the way `send` does, throws
`PreparationRejection`, and returns a `Prepared` proposal for `commit(_:)`.

## Host on the main actor

`MainActorHost` keeps its state on the main actor, and its methods are
synchronous there. Its drivers are `@MainActor` closures, so they can read
main-actor state without awaiting. It is the only managed owner of an
`isolated` schema that the main actor reaches directly, and its payloads stay
there without becoming `Sendable`.

```swift
@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Draft: ~Sendable { let text: String }
    struct Saved: ~Sendable { let text: String }

    @Initial case draft(Draft)
    @Terminal case saved(Saved)

    enum Input: ~Sendable { case save }

    @Transition(on: Input.save)
    fileprivate static func save(_ source: Draft) -> Saved { Saved(text: source.text) }
}

@MainActor
func saveNote() throws {
    let host = Note.MainActorHost(Note.Draft(text: "Outline"))
    try host.send(.save)
}
```

A SwiftUI view reads a `MainActorHost` directly on systems with Observation,
and through `StateMachinePresentation` or `StateMachineObservableObject` from
the `StateMachineUI` module otherwise.

## Share an owner across isolation domains

`Shared` is a `Sendable` final class whose methods are synchronous from any
isolation. It reads the current state, prepares outside its lock, and installs
the result only if no other commit intervened, so `send` reports
`.commit(.conflict)` instead of preparing again. Retry a conflict by sending
again when the input still applies to the newer state. `runningCount`,
`subscriberCount`, `isQuiescent`, and `pendingCompletions()` are synchronous
reads.

```swift
func searchFromAnywhere(_ lookup: Lookup.Shared) {
    do {
        try lookup.send(.search("swift"))
    } catch .commit(.conflict) {
        print("Another change came first")
    } catch {
        print("Search was not accepted: \(error)")
    }
    print("\(lookup.runningCount) fetches running")
}
```

## Give the owner its own actor

`ActorHost` is an owner isolated to an actor of its own, so every method is
`async` from outside it, including `snapshot()`, `runningCount`, and
`subscriberCount`. It reads, prepares, and admits each input in one turn of
that actor.

Pass an actor to `isolatedTo:` to run the owner's actor on that actor's serial
executor. Their turns then never overlap, which suits an owner that works
alongside the state of an existing actor, although calls into the owner still
await.

```swift
actor SearchIndex {
    func record(_ query: String) {}
}

func makeIndexedLookup(index: SearchIndex) -> Lookup.ActorHost {
    Lookup.ActorHost(
        fetchDriver: { query in
            await index.record(query)
            return "Results for \(query)"
        },
        isolatedTo: index
    )
}
```

The owner retains that actor for its whole lifetime, because its executor must
outlive every job the owner runs. An actor that stores an owner isolated to
itself therefore keeps itself alive until it releases the owner. To own a host
from the actor whose turns it shares, confine it with `IsolatedHost` instead.

## Confine the owner to an actor you own

`IsolatedHost<Owner>` lives inside one actor instance that its creator chooses.
It is not `Sendable`, and its initializer places it in the region of the actor
passed as `isolation:`, so the compiler keeps it there. Every method ends with an
`isolation: isolated Owner = #isolation` parameter, which the actor fills in by
itself, so inside the actor a call is plain and synchronous. Each driver
receives the actor, isolated, before its input, so it can read and change the
actor's state without awaiting.

```swift
actor SearchSession {
    private(set) var queries: [String] = []

    private lazy var host = Lookup.IsolatedHost(
        isolation: self,
        fetchDriver: { session, query in
            session.queries.append(query)
            return "Results for \(query)"
        }
    )

    func search(_ query: String) throws -> UInt64 {
        try host.send(.search(query)).revision
    }

    func close() async {
        await host.shutdown()
    }
}
```

The host needs `self` as its owner, and an actor's `self` is available only
after every stored property has a value, so the initializer cannot assign it to
a `let`. Declare it `lazy`, as here, so the actor creates it on first use, or
store it in an optional that an `async` initializer or an actor method assigns.

A call from anywhere else does not compile. From another actor, the default
argument cannot become an `Owner`, and the compiler reports this diagnostic.

```text
call to actor-isolated instance method 'send(_:isolation:)' in a synchronous actor-isolated context
```

From the main actor the message ends in `in a synchronous main actor-isolated
context`, and from a nonisolated function, where there is no actor to pass, in
`in a synchronous nonisolated context`. Handing the host to another instance of
the same actor type is reported as sending a value that `risks causing data
races`.
Another actor calls the owning actor instead, as it would for any of the
actor's state. A method that receives an explicit instance other than the
owner stops the program, so no path changes the host from two actors.

Event handlers receive the actor, isolated, before their payload, as drivers
do, so a handler such as `onLogged: { owner, line in owner.messages.append(line) }`
reaches the actor's state without capturing it. Write drivers and handlers that
way because the host holds them for its whole lifetime, and one that captures
the actor creates a retain cycle that keeps the actor alive as long as the host
it stores.

Subscription callbacks, the completion policy's handler, and snapshot
projections are plain closures that run on the owning actor. A registration from
`subscribe` stays in that actor's region, and cancelling it there removes it
before returning, so none of its callbacks begins afterward. A cancellation made
while the host delivers a change, such as from another observer's callback,
releases the callbacks once the host has delivered that change to its other
observers. Only the owning actor can cancel a registration. Its
`cancel(isolation:)` takes that actor as a defaulted `isolated` parameter, so a
call from another actor or from an ordinary object's destructor does not
compile. Dropping the registration instead, which can happen on another thread
when an object that stores it is released there, stops delivery and frees its
slot at once. The host then releases its callbacks when it next sweeps its
registrations on the actor, or when it is destroyed. The host's counts are
methods for the same reason, so `runningCount()`, `subscriberCount()`, and
`isQuiescent()` take the owning actor like every other member. In an `isolated`
schema, `snapshots()` returns an `IsolatedSnapshots` stream that the actor reads
with `next()`. It has no Combine publisher, because its callbacks belong to an
actor that Combine cannot be confined to.

The host holds its owner weakly, so an actor that stores its host is released
with it once idle. Because a running driver executes on the actor, it retains
the actor while it waits, keeping an otherwise released actor alive until the
driver returns. `close()` or `shutdown()` requests the drivers' cancellation,
and the actor is released after each driver returns. A driver that ignores
cancellation keeps the actor alive until it returns. A closure that captures the
actor also keeps it alive for as long as the host or registration holds that
closure. A released host first processes every batch it has already accepted,
then ends its registrations without calling them, and only then cancels its
workers, so a driver's cancellation handler finds every registration ended.

## Settle completions that do not commit

When an operation's driver returns, the host prepares the completion edge from
the current state and tries to admit it. A completion that does not commit is
retained with its first outcome until it is settled. A managed owner's
`completionPolicy:` decides what happens next.

- `.retry` prepares the completion again when another commit wins the race, at
  most four times per turn before yielding to other work. A completion that
  still loses after sixteen turns stays retained and needs reconciliation.
  `.retry` notifies no one.
- `.retry(onReconciliationRequired:)` retries the same way and passes the
  handler every completion that needs reconciliation.
- `.manual` never prepares a completion again on its own and notifies no one.
- `.manual(onReconciliationRequired:)` never prepares again either, and passes
  the handler every completion that needs reconciliation, including one that
  lost a race.

A completion needs reconciliation when its completion edge or router threw, its
effect plan is defective, the owner refused its admission, an explicit
`reconcile(id:)` did not commit, or, under a `.manual` policy, its preparation
lost a race. The handler runs outside the owner's critical section, in the
owner's isolation, each time a retained completion's status becomes
`.reconciliationRequired`.

The handler receives reports one at a time, in the order the owner made the
decisions. A handler that reconciles a completion synchronously sees that
attempt reported after every report decided before it, including the rest of
the batch its own report came from. A call that would report while the handler
runs, from inside it or, on `Shared`, from another thread, leaves its report to
that delivery and returns. A call that finds no delivery in progress delivers
the reports itself, so it has reported its own attempt before it returns.

Retrying is the same as the result arriving a moment later, when its edge would
run against the newer phase anyway. Every completion edge and router must be
deterministic and free of side effects under either policy, because an explicit
`reconcile(id:)` prepares it again too. Capture network responses, decoded
values, time, and other external inputs once, before they reach an edge. The
compiler does not check this. Work that must not survive a change is revoked
with `invalidates:` instead. Choose `.manual` when the application, rather than
the edge, must decide whether a result still applies to a newer state.

`.retry` is the default unless one of the schema's completions can refuse its
outcome, which happens when a completion edge or router throws or when a
completion edge starts an operation whose admission is `.rejectWhenActive` or
`.parallel(limit:)`. A refusal is a decision about the newer state that the
caller may need to settle, so every managed initializer of such a schema takes
`completionPolicy:` without a default. This intake refuses negative values in
its completion edge.

```swift
@StateMachine(mode: .shared)
nonisolated enum Intake: Sendable {
    struct Ready: Sendable { var accepted: [Int] = [] }

    @Initial case ready(Ready = Ready())

    enum Input: Sendable { case check(Int) }
    enum Refusal: Error, Sendable { case negative }

    @Operation(activeIn: [Ready.self], admission: .parallel(limit: 8))
    enum Check {
        typealias Input = Int
        typealias Output = Int
    }

    @Transition(on: Input.check, starts: [Check.self])
    fileprivate static func check(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Check> {
        Change(source, effects: [.check(value)])
    }

    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Ready {
        guard value >= 0 else { throw .negative }
        return Ready(accepted: source.accepted + [value])
    }
}

func makeIntake() -> Intake.Shared {
    Intake.Shared(
        checkDriver: { value in value },
        completionPolicy: .manual(onReconciliationRequired: { pending in
            print("Needs reconciliation: \(pending.id), \(pending.status)")
        })
    )
}
```

`pendingCompletions()` reads every retained completion without claiming it. A
`PendingCompletion` holds an opaque `id`, the `outcome` with one case per
operation, its `status`, the `lastRejection`, and the number of `attempts`. Its
outcome is plain data holding the output for an operation that cannot fail, or a
`Result` for one that can, along with the request the work was started with. A
caller can read it without any authority to apply it. Settle a retained
completion with `reconcile(id:)`, which authorizes one fresh preparation and
reports `.inProgress` if another attempt holds the claim, or end it with
`discardPending(id:)`, which revokes the operation in an authority-only commit.
`PendingCompletionID` is specific to the graph, so an identifier from another
graph does not type-check.

```swift
func settle(_ intake: Intake.Shared) {
    for pending in intake.pendingCompletions() {
        switch pending.outcome {
        case .check(let value, _) where value < 0:
            _ = intake.discardPending(id: pending.id)
        case .check:
            if case .committed(let receipt) = intake.reconcile(id: pending.id) {
                print("Applied at revision \(receipt.revision)")
            }
        }
    }
}
```

To follow the retained completions as they change, iterate
`pendingCompletionUpdates()`. Each element is the whole collection, starting
with the one current at registration and continuing with the collection after
each change, with a newer collection replacing one not yet read. Closing the
owner delivers a final, empty collection, and the sequence ends. Each
registration takes one subscriber slot, and on `ActorHost` the call is `async`.
`pendingCompletionUpdates(_:)` projects each collection to a `Sendable` value
instead. In an `isolated` schema, whose `pendingCompletionUpdates()` is a stream
read on the owner's actor, that projection is how the collection reaches
`for await` and sequence operators.

```swift
func watchPending(_ intake: Intake.Shared) async throws {
    for await pending in try intake.pendingCompletionUpdates() {
        print("\(pending.count) completions need attention")
    }
}
```

A managed owner has no `deliver` method, because a caller never holds a work
value there and completions reach the owner only through its own drivers.

## Start over with reset

`reset(to:)` replaces the model with a fresh initial payload in a new
incarnation, as a fresh owner starts. It keeps the owner's identity and
subscribers, advances the revision, revokes every outstanding operation,
publishing its cancellation in the reset's batch, and disposes of every
retained completion, so a late result is stale. Observations and proposals from
before the reset can no longer commit. Its argument defaults exactly when the
initial phase declares a default.

```swift
@MainActor
func startOver(_ host: Lookup.MainActorHost) throws {
    let receipt = try host.reset()
    print("Started over at revision \(receipt.revision)")
}
```

A reset expects no revision, so no concurrent commit can make it conflict. It
throws `.closed` once the owner is closed, `.revisionExhausted` when no
ordinary revision remains, and `.capacityExceeded(.commitQueue)` when it must
queue a batch while the commit queue is full, and then changes nothing. A
managed owner queues every reset, because it publishes each accepted snapshot
from its queue. A `Local` queues one only to cancel the work the reset revokes.
Work that is still running keeps its execution reservation and counts in
`runningCount` until it terminates, because revoking authority does not stop a
driver. A schema with a `@Restoration` function also has `reset(restoring:)`,
which validates saved data and resets into the phase it restores.

A reset that follows from a decision about one snapshot, such as discarding the
draft a user just reviewed, takes that snapshot as `expecting:`. The owner
resets only while it still holds that root, and otherwise changes nothing and
throws as a commit prepared on it would, reporting `.foreignOwner` for another
owner's snapshot, then `.closed`, `.obsoleteIncarnation` after another reset,
or `.conflict` after any other change.

```swift
@MainActor
func discard(_ reviewed: Lookup.Snapshot, on host: Lookup.MainActorHost) throws {
    try host.reset(expecting: reviewed)
}
```

`reset(to:expecting:)` and, with a `@Restoration` function,
`reset(restoring:expecting:)` accompany the unconditional forms on every owner
except `Owned`. Every owner resets synchronously except `ActorHost`, whose
resets are `async`, and `Local`'s resets are `mutating`.

## Close and shut down

`close()` ends admission and returns a receipt of the closed snapshot, while
keeping read access to the final state. `flush(through:)` waits until the owner
has processed every batch through a receipt, including the cancellation and
launch decisions of a graph with operations. It returns ``FlushResult/processed``,
or ``FlushResult/foreignOwner`` for a receipt another owner issued.

`shutdown()` closes the owner and waits for its tasks to terminate and its
delivery and preparation obligations to settle, then returns `.quiescent`. Pass a
deadline to `shutdown(deadline:)` to bound the wait. On timeout it returns
`.timedOut(diagnostics)`, and the owner stays closed with that work still
tracked. `diagnostics.outstandingExecutions` identifies the reservations it
still tracks, and `pendingCompletions` the retained completions, and none of
them grants authority. The result is discardable.

```swift
func stop(_ lookup: Lookup.Shared) async {
    switch await lookup.shutdown(deadline: .now + .seconds(2)) {
    case .quiescent:
        print("Stopped")
    case .timedOut(let diagnostics):
        print("\(diagnostics.outstandingExecutions.count) executions still running")
        await lookup.shutdown()
    }
}
```

Cancellation is cooperative, so a driver that ignores it keeps running until it
returns and keeps a shutdown waiting. Managed hosts also launch a replacement
task as soon as prior authority is revoked; to admit new inputs immediately
while keeping at most one uncooperative synchronous call in flight, follow
[Serialize uncooperative work on Local](<doc:RunningEffectsYourself#Serialize-uncooperative-work-on-Local>)
and the tested `SerializedPipeline.swift` example listed in <doc:Examples>.
`runningCount` counts the workers whose termination has not been
processed, `subscriberCount` counts the live registrations, and `isQuiescent`
reports whether closure and every obligation have settled. All three are `async`
on `ActorHost`, and on `IsolatedHost` they are methods that take the owning
actor.
