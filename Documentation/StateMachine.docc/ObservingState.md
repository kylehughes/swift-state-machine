# Observing state

Read an owner's snapshots as they change, through Observation, asynchronous sequences, callbacks, or Combine.

Every snapshot is a complete, immutable record of the owner at one revision.
Reading one never blocks a writer, and holding one does not reserve the state
it shows. The managed owners publish each accepted snapshot, and a caller can
receive them through Observation tracking on a `MainActorHost`, a single-pass
asynchronous sequence, a callback registration, or a Combine publisher. A
`Local` owner publishes nothing, so its caller reads `snapshot()` and the
receipts it returns.

The examples in this article observe one search graph.

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

extension Lookup.Snapshot {
    var isSearching: Bool {
        if case .searching = self { true } else { false }
    }
}
```

## Read the current snapshot

`snapshot()` returns the current snapshot, and is `async` on `ActorHost`. A
snapshot has one case per phase, each holding an `Observed<Phase>` whose
`value` is the payload. Its `revision` increases with every accepted change,
`isClosed` reports closure, and `model` is the plain schema value, which a test
can compare when the schema is `Equatable`. An observation also prepares the
edges that leave its phase, as
[Act on the observation a caller saw](<doc:HostingAGraph#Act-on-the-observation-a-caller-saw>)
describes.

## Track a main-actor host with Observation

Every generated `MainActorHost` inherits from ``ObservableMainActorHost``,
which is `Observable` on iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1, and
Mac Catalyst 17 and later. A SwiftUI view reads the host directly, and the view
updates when the snapshot it read changes.

```swift
import SwiftUI

struct SearchStatus: View {
    let host: Lookup.MainActorHost

    var body: some View {
        switch host.currentSnapshot {
        case .idle:
            Text("Ready")
        case .searching(let searching):
            Text("Searching for \(searching.value.query)")
        case .found(let found):
            Text(found.value.answer)
        }
    }
}
```

`currentSnapshot` and `snapshot()` register a read of the snapshot, and
`runningCount`, `subscriberCount`, and `pendingCompletions()` each register a
read of their own value. A commit therefore invalidates a reader of the
snapshot without invalidating a reader of the running count. The host reports
each change after the admission, delivery, or drain that made it, and tracking
takes no subscriber slot. A registration released on another thread stops
counting at once, before the host removes it, so a reader can see
`subscriberCount` fall early. The host still reports that change, even when an
admission in the same turn brings the count back to the value it last
reported. On earlier systems, observe through a sequence, a callback, or a
presentation from the `StateMachineUI` module.

## Iterate snapshots

`snapshots()` registers an observer and returns a single-pass asynchronous
sequence of complete snapshots. The first element is the snapshot current at
registration, unless a newer one has replaced it, and later elements have
strictly increasing revisions. The sequence keeps one pending snapshot, so a
consumer that reads slowly receives the latest value and never an older one.
It ends after the owner's closed snapshot, when the owner is released without
closing, when its `cancel()` is called, and when a read finds its task
cancelled. Creating it throws ``SubscriptionFailure`` when subscriber
capacity is exhausted, while iterating never throws. `ActorHost.snapshots()` is
`async`.

```swift
@MainActor
func watch(_ host: Lookup.MainActorHost) async throws {
    for await snapshot in try host.snapshots() {
        print(snapshot.revision)
    }
}
```

Only a read observes task cancellation, whether the task was cancelled before
or during the read. A task that stops reading after it is cancelled, and a loop
that leaves early with `break` or `first(where:)`, leave the registration in
place for as long as the sequence is kept. A temporary sequence like the one
above ends when the loop releases it. A consumer that keeps the sequence ends
it explicitly with `cancel()`.

```swift
func waitForAnswer(_ lookup: Lookup.Shared) async throws -> String? {
    let snapshots = try lookup.snapshots()
    defer { snapshots.cancel() }
    for await snapshot in snapshots {
        if case .found(let found) = snapshot { return found.value.answer }
    }
    return nil
}
```

The sequence type depends on the owner and the mode. A `shared` schema's
owners return a ``SnapshotSequence``, which is `Sendable` and works with every
`AsyncSequence` operator. An `isolated` schema's snapshots are not `Sendable`,
so its `MainActorHost` returns a ``MainActorSnapshotSequence`` read on the main
actor, and its `IsolatedHost` returns an ``IsolatedSnapshotSequence`` read on
the owning actor. Each is a noncopyable stream with one consumer. Register it
with `var snapshots = try host.snapshots()`, read it with
`while let snapshot = await snapshots.next()`, and end it early with
`snapshots.cancel()`. These streams do not conform to `AsyncSequence`, because
the standard operators run their closures, and on earlier systems their
iteration, off the caller's actor, which would carry a confined snapshot away
from it. Project to a `Sendable` value with `snapshots(_:)`, as the next
section shows, for `for await`, operators, and generic code. Because every
sequence and stream keeps only the latest value, a loop can skip intermediate
revisions, so wait for the snapshot that matters instead of counting elements.

### Cancellation order

Each of the three sequence types ends with its own form of `cancel`, which
removes the registration and releases any unread snapshot. Every later read
returns `nil`, and calling `cancel` again changes nothing. Every end follows
one order, so a destructor of an unread snapshot that registers again finds the
slot free.

1. The registration's gate closes, so the owner stops beginning callbacks and
   stops counting the registration.
2. The registration is removed.
3. The record of its token is cleared, along with everything the token captured.
4. Only then are the values the registration held released, outside every lock
   and on the actor that owns them.

**``SnapshotSequence/cancel(isolation:)``** can be called from any isolation
domain because the sequence is `Sendable`, and ordinary calls spell it
`cancel()`. The owner stops delivering before it returns, and a generated
owner's subscriber slot is free by then, even when another call is cancelling
the same sequence at that moment. A read waiting for an element returns `nil`,
unless the owner had already handed it an element, in which case that waiting
reader finishes delivery.

A `MainActorStateMachineHost` of your own frees its slot when its subscription
is cancelled, which only the main actor can do. Timing depends on the call's
isolation rather than the thread it runs on. A call isolated to the main actor
cancels the subscription before it returns, while a call from another actor,
from a nonisolated function, or from a destructor leaves it to the next
main-actor turn, even on the main thread. A host registered through
``SnapshotSequence/init(register:)`` frees its slot in its token's `onCancel`,
which the first call runs. Another call made meanwhile can return before that,
and the unread snapshot it discarded waits for that `onCancel` to return. The
same holds when the host cancels a token it kept and ends the sequence from
inside that token's `onCancel`. The call from inside returns at once, and the
snapshot it discarded is released once `onCancel` returns, after the slot is
free. The token releases `onCancel`, and everything it captures, before it
records that its cancellation has returned, so a value captured there that
frees the slot when it is released does so before the discarded snapshot is
released.

An unread snapshot is released before `cancel()` returns, except that it waits
for a removal already in progress, whether started by another call or by the
owner's finish. A `MainActor` owner's removal left to the next main-actor turn
releases the snapshot right after that removal, even when the call that
discards it comes from another thread after the finish queued it. A call
isolated to the main actor keeps the snapshot it discards on the main actor.
When another thread completes the removal, as a host of your own cancelling its
token on a worker does, the snapshot is released on the main-actor turn after
that removal.

**``MainActorSnapshotSequence/cancel()``** is `@MainActor`, where the stream is
read, and removes the registration before it returns. A stream released before
it ends, which can happen on another thread when an object that stores it is
released there, stops delivery and frees its slot at once. A later main-actor
turn removes the registration and then releases the snapshot it held unread,
including the closed snapshot of an owner that has already released its
callbacks.

**``IsolatedSnapshotSequence/cancel(isolation:)``** takes the owning actor as a
non-optional `isolated` parameter, which a call on that actor passes by
default, and removes the registration before it returns. A call from a
nonisolated context, such as an ordinary object's destructor, does not compile,
and neither does passing `nil`. Reading the stream through its end and
cancelling it on the owning actor are the two ways to release its unread
snapshot there deterministically. A stream dropped before it ends stops
delivery and frees its slot at once, and its unread snapshot is released
wherever the last reference to it goes. While the host still holds the
registration's callbacks, the host releases them and the snapshot when it next
sweeps its registrations on the owning actor. Once the host has finished the
registration, as closing does, the stream holds the snapshot alone and releases
it where it is dropped. No destructor can reach a generic actor at this
deployment floor, so a stream stored by an object that can be released on
another thread should end with `cancel(isolation:)` before the object lets it
go. The stream does not keep its owner alive, but an unread projection that
retains the host does, through the callbacks the host holds until its next
sweep. Call `cancel(isolation:)` before dropping the stream to break that
reference cycle.

### Teardown and off-thread release

A host holds client values too, including its root model, retained outcomes,
and the callbacks of its registrations with everything they capture. A
`MainActorHost` released on another thread releases those values on a later
main-actor turn, after it finishes the registrations of an owner released
without closing. The same holds for a presentation from `StateMachineUI`, once
the removal of its registration has completed, and for a
``MainActorSnapshotSubscription`` of your own dropped without being cancelled,
after it runs `onCancel`. Each keeps those values only in storage that the
main-actor turn owns alone, so they are released there whichever finishes
first, that turn or the destruction of the released object on its own thread.

An owner released without closing first processes every batch it accepted,
delivering each to its registrations as usual, and then tears down in one
order. First, it closes one gate that every publisher of the owner reads, so
all of its publishers learn of the release at the same instant. After any of
them can finish for the release, none begins an ordinary delivery, even one
whose notice the releasing thread has not sent yet. Next, it notifies every
registration that learns of the release at once, such as a publisher and every
registration of a `Shared` owner. Then it cancels its drivers, and finally it
releases its registrations' callbacks. A sequence keeps its unread snapshot
across the release, so it reads that snapshot and then ends. A driver's
cancellation handler, or the destructor of a value a callback captured, that
attaches a subscriber to a publisher of that owner therefore receives only the
completion.

A `Shared` owner is released when its last reference goes, even while a
cancellation on another thread is still reading its state. An `IsolatedHost`
has no registration that learns of the release at once. It ends its
registrations by releasing their callbacks before it cancels any driver, and it
releases what it holds where its last reference is released, so release it on
its owning actor when those values must not be destroyed elsewhere. A token of
your own made with
``IsolatedSnapshotSubscription/init(isolation:onCancel:onRelease:)`` and dropped
without being cancelled releases `onCancel` where it is dropped, so capture
what the owning actor must release only weakly there, or cancel the token on
that actor.

A registration's first element, like `snapshot()` and an Observation read,
shows the state the owner has admitted, at once. Event handlers and later
deliveries follow commit order, so a registration made just after an emitting
`send` can see that change before its event handler runs. To act after the
handler, wait with `flush(through:)` on the receipt.

## Project and drop repeated values

`snapshots(_:)` registers a sequence of `Sendable` projections. The transform
runs on the owner's delivery path, outside every lock, executing on the main
actor for `MainActorHost`, on the owning actor for `IsolatedHost`, in the
actor's turn for `ActorHost`, and on the shared host's serial registration path
for `Shared`. The sequence offers every projection, even one equal to the one
before it.

`distinctSnapshots(_:)` takes an `Equatable` projection and omits each value
equal to the one before it, including the projection of the closed snapshot,
after which the sequence ends. The two are separate methods, so generic code
over a hosting protocol delivers the same values as code written against a
concrete host. This loop wakes only when the search starts or stops.

```swift
func watchActivity(_ lookup: Lookup.Shared) async throws {
    for await searching in try lookup.distinctSnapshots({ $0.isSearching }) {
        print(searching ? "Searching" : "Not searching")
    }
}
```

A projection is also how an `isolated` schema's snapshots leave their actor.
The transform runs where the snapshot lives and returns a `Sendable` value, so
the sequence is a ``SnapshotSequence`` whatever the mode.

## Wait for a condition with a deadline

Use ``SnapshotSequence/wait(timeout:where:)``,
``SnapshotSequence/wait(deadline:where:)``, or
``SnapshotSequence/wait(deadline:clock:where:)`` to wait until a snapshot or
projection satisfies a predicate, with an optional deadline. The result is a
``SnapshotWaitResult`` that separates a match (`.matched(value)`), a deadline
expiry (`.timedOut`), caller task cancellation (`.cancelled`), and the sequence
ending before a match (`.ended`, such as when the owner closes or is released).

```swift
@MainActor
func waitUntilIdle(
    _ lookup: Lookup.MainActorHost,
    timeout: Duration
) async throws -> SnapshotWaitResult<Bool> {
    if !lookup.currentSnapshot.isSearching { return .matched(false) }
    let updates = try lookup.distinctSnapshots { $0.isSearching }
    return await updates.wait(timeout: timeout) { !$0 }
}
```

Checking the current snapshot before subscribing avoids taking a subscriber
slot when the state already matches, and on a `Shared` owner guarantees a
synchronous fast path before applying a short or zero deadline (an open `Shared`
owner delivers its registration snapshot asynchronously through its serial
mailbox). On `MainActorHost`, `ActorHost`, `IsolatedHost`, and any closed owner,
registration buffers the initial snapshot synchronously before `snapshots()` or
`distinctSnapshots(_:)` returns, so `wait` tests that buffered element before
checking the deadline and returns `.matched` without starting a timer even when
the deadline has already passed.

`.matched` carries a historical value, and another commit can advance the owner
before the awaiting task resumes. After waiting on a projection such as
`distinctSnapshots(_:)`, check the condition again on a fresh snapshot before
acting, and commit a proposal prepared from that checked snapshot when a racing
writer could intervene. In a `shared` schema, waiting directly on `snapshots()`
yields a full snapshot whose `Observed` value can prepare a proposal right
away, and `commit(_:)` rejects it with `.conflict` if a later ordinary commit
advances the same open incarnation. See
[Act on the observation a caller saw](<doc:HostingAGraph#Act-on-the-observation-a-caller-saw>)
for proposal commits and rejection handling.

`wait` runs on the caller's isolation (`nonisolated(nonsending)`), so the
predicate stays on the caller's actor without needing `@Sendable` or moving a
sequence iterator across task-group boundaries. Avoid iterating a
``SnapshotSequence`` inside a `@MainActor` child task of `withTaskGroup` on
Swift 6.4, which triggers a region-based isolation compiler error, and avoid
standard `AsyncSequence` operators such as `first(where:)` from an actor when
their predicates are `@concurrent` or leave the registration alive until the
sequence is released. In an `isolated` schema, project the condition to a
`Sendable` value with `snapshots(_:)` or `distinctSnapshots(_:)` to obtain a
``SnapshotSequence`` and call `wait` on it.

Every `wait` call follows these rules:

- **Single-pass ownership.** `wait` claims the sequence the same way
  `makeAsyncIterator()` does. A second call on an already-claimed sequence
  returns `.ended` immediately without cancelling the active consumer.
- **Caller cancellation.** If `Task.isCancelled` is already `true` when `wait`
  starts (after claiming), it cancels the sequence and returns `.cancelled`
  without evaluating the predicate or starting a timer. Cancelling the calling
  task while waiting wakes the wait promptly, cancels the timer, and returns
  `.cancelled`.
- **Timeout ties.** An element already buffered in or handed to the sequence
  before the deadline fires is still tested against the predicate and returns
  `.matched` if it matches; once the deadline passes, newer offers are ignored.
  The first terminal cause recorded under the sequence's lock wins, so a late
  timer cannot turn `.ended` into `.timedOut`. If caller task cancellation
  discards an unread buffered element after closure or deadline expiry, `wait`
  reports `.cancelled` rather than claiming that buffered element failed to
  match. An external call to `cancel()` while the calling task is not cancelled
  reports `.ended`.
- **Turn fairness and latest-value coalescing.** Because ``SnapshotSequence``
  keeps only the latest unread value, transitions that enter and leave a
  matching state before `wait` reads them can coalesce. Under continuous
  non-matching offers, `wait` yields the caller's actor after 32 consecutive
  synchronous evaluations so a busy producer cannot monopolize it.
- **Subscription cleanup.** On every exit path after claiming, `wait` cancels
  its timer task and calls `cancel(isolation:)` on the caller's isolation
  before returning. On a `MainActorHost` awaited on the main actor, or on a
  `Shared` owner, the registration is removed before `wait` returns. From
  another actor, or on `ActorHost` and `IsolatedHost`, the registration's gate
  closes before `wait` returns (stopping callbacks and freeing the subscriber
  slot immediately) while callback removal finishes on the owner's next turn or
  sweep.

Pass a custom `Clock` to ``SnapshotSequence/wait(deadline:clock:where:)`` to
test timeout and race behavior deterministically without real sleeps.

## Subscribe with a callback

`subscribe(_:onFinish:)` registers a callback that receives the snapshot
current at registration, then the latest complete snapshot as the owner accepts
changes, then the closed snapshot, and finally calls `onFinish`. Delivery is
latest-value, as for a sequence. A newer snapshot replaces one the callback has
not yet received, so a callback can skip intermediate revisions, though it
never sees one out of order. Calling `subscribe` returns a registration whose
`cancel()` ends it, and releasing the registration ends it too. A callback runs
outside every lock and may read the owner or send it another input.

The callback isolation and registration type depend on the owner. On
`MainActorHost`, the callback runs on the main actor and the registration is a
``MainActorSnapshotSubscription``. On `Shared` and `ActorHost`, the callback is
`@Sendable` and the registration is a ``SnapshotSubscription``. On
`IsolatedHost`, the callback runs on the owning actor and the registration is an
``IsolatedSnapshotSubscription`` that stays in that actor's region. Only that
actor can cancel it, and cancelling removes it before returning so the callback
never begins again. A cancellation made while the host delivers a change
releases the callback once that delivery has reached the other observers.
Dropping it, which can happen on another thread when an object that stores it
is released there, stops delivery and frees the slot at once, and the host
releases the callback when it next sweeps its registrations on the actor, or
when it is destroyed. A `Shared` callback keeps one pending snapshot, so its
first call receives the registration snapshot or a newer one, and a slow
callback receives the latest snapshot when it is ready.

```swift
@MainActor
func logChanges(_ host: Lookup.MainActorHost) throws -> Lookup.MainActorSubscription {
    try host.subscribe({ snapshot in
        print("Now \(snapshot)")
    }, onFinish: {
        print("Closed")
    })
}
```

## Publish snapshots to Combine

Where Combine is available, `MainActorHost` and `Shared` offer
`snapshotPublisher(_:)`, which publishes a `Sendable` projection of each
snapshot, and `ActorHost` offers it `async`. In a `shared` schema they also
offer `snapshotPublisher()`, which publishes the snapshot itself. Each is
`@MainActor` and throws ``SubscriptionFailure``. The ``SnapshotPublisher`` it
returns takes a subscriber slot when it is created and delivers on the main
actor. Its output is `Sendable`, because a pipeline can move values to another
thread, as `receive(on:)` does, so an `isolated` schema publishes only
projections. Its failure type is `Never`, it keeps one pending value that a
newer one replaces until demand allows, and it finishes after the closed
snapshot, which waits for demand like any other value. A unit of demand
reaches the newest value the owner had handed over when the publisher claimed
it, or a newer one, including a closed snapshot still on its way to the main
actor.

An owner released without closing first processes every batch it accepted,
delivering each as usual, including to a subscriber that attaches after the
last reference to the owner is gone. It then finishes the publisher at once and
discards every ordinary value not yet delivered, even while a `Shared` owner's
delivery is still projecting a snapshot, so demand first made after that
receives only the completion. Every publisher of the owner ends at that one
instant, so a subscriber that attaches to one of them after another has
finished receives only the completion too.

A publisher holds its slot until its subscription is cancelled, so an object
that replaces its subscription cancels the old one before creating the new one.
Otherwise an owner with a single slot refuses the replacement.

```swift
import Combine

@MainActor
final class SearchBadge {
    private var cancellable: AnyCancellable?

    func watch(_ lookup: Lookup.Shared) throws {
        cancellable?.cancel()
        cancellable = nil
        cancellable = try lookup.snapshotPublisher()
            .map(\.isSearching)
            .removeDuplicates()
            .sink { searching in print(searching ? "Searching" : "Idle") }
    }
}
```

A publisher has one subscriber, and any later subscriber receives `.finished`
at once. Cancelling the subscription frees the slot before it returns, from any
thread, and so does releasing a publisher that was never subscribed. Nothing is
delivered after a cancellation that returned before the publisher decided the
delivery, including a cancellation from the destructor of a value the publisher
released. Only a cancellation on another thread that races a delivery already
decided can return before it.

A publisher delivers at most 32 values in one main-actor turn, counting every
delivery of that turn, whether the subscription, a value the owner hands over,
or a request for demand starts it. It continues on a later turn with the
demand, the pending value, and the finish it has not delivered, so neither a
subscriber that makes the owner hand over another value from each one it
receives nor an owner that hands over many values in one turn can hold the main
actor. A cancellation between those turns delivers nothing more. Subscribing
off the main actor stops the program instead of racing, because Combine does
not check isolation. `IsolatedHost` has no publisher, because its snapshots
belong to an actor that Combine cannot be confined to.

## Budget subscriber slots

Each sequence, publisher, callback registration, and pending-completion
registration takes one of the owner's subscriber slots until it ends. The slot
is taken when the member is called, before anything reads the result, covering
`subscribe`, `snapshots()`, `snapshots(_:)`, `distinctSnapshots(_:)`,
`snapshotPublisher()` and `snapshotPublisher(_:)` (even when nothing ever
subscribes), and `pendingCompletionUpdates()`. `subscriberCount` reports how
many are live, as a count that held while it was read, even while other
threads register and cancel. The default `Configuration` allows 128.
Observation tracking on a `MainActorHost` takes none.

The `StateMachineUI` module builds on these mechanisms for SwiftUI and UIKit. Its
driving presentations send and commit through a `MainActorHost`, and its
passive presentations observe any managed host. A presentation lives on the
main actor, so observing an owner confined to another actor needs a value that
can cross to it, either a `Sendable` snapshot or a `Sendable` projection from
`snapshots(_:)`.
