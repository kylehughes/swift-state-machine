# Schedule explorer

The schedule explorer (`Tests/StateMachineTests/Explorer*.swift`) is a bounded model checker for the presentation,
publisher, registration, and owner-teardown layers. It enumerates every short sequence of events over a small
alphabet, runs each sequence from a fresh state, and checks a set of numbered invariants after every step and at
quiescence. Every step is forced by an explicit happens-before edge, whether a synchronous call, a semaphore signaled
by a background thread, or a main-actor job enqueued behind the jobs it waits for. Timeouts only fail a stuck run.
This document lists what the explorer can do (the alphabet), what it checks (the invariants), how it forces each step,
and what it prunes. A missing event or invariant is a gap in what the explorer can find.

The explorer runs against the real production types, covering the four presentation classes of `StateMachineUI`, the
owners that the macro generates for the profile example graph, a raw `RuntimeSharedHost`, `SnapshotSequence`,
`SnapshotPublisher`, `MainActorSnapshotIngress`, and `distinctSnapshots`. Where a test needs control over a host,
it uses fake one-slot hosts built from the public conformer API, whose cancellations the harness parks and
releases. A run prints one summary line per configuration, `EXPLORER <configuration>: N sequences run, M pruned
(sleep set, idle arms, state hashing), deepest D, S s`, followed for each violated invariant by
`VIOLATION I<n> (<count> sequences), minimal: <script>` and a detail line. The test records one issue per
invariant, `<Class>: I<n> <name>: <detail> after <script>`, where the script is the shortest violating sequence
found, in the notation that a replay accepts.

## Running and replaying

The smoke tier runs in the normal test suite. Run the other tiers from the package root, each in its own scratch
path and one at a time:

```sh
swift test --build-system native --scratch-path /tmp/state-machine-explorer --filter ExplorerTests/smoke
EXPLORER_SMOKE=0 EXPLORER_TIER=standard swift test --build-system native --scratch-path /tmp/state-machine-explorer --filter ExplorerTests/full
EXPLORER_SMOKE=0 EXPLORER_FULL=1 swift test --build-system native --scratch-path /tmp/state-machine-explorer --filter ExplorerTests/full
```

Replay one script with a step-by-step trace:

```sh
EXPLORER_SMOKE=0 EXPLORER_REPLAY="SnapshotObservableObject: observe(A); hostCancel(A); dropMain" swift test --build-system native --scratch-path /tmp/state-machine-explorer --filter ExplorerTests/replay
```

The text before the colon is a class or slice name (`SnapshotObservableObject`, `SnapshotPresentation`,
`StateMachineObservableObject`, `StateMachinePresentation`, `MainActorHost`, `ActorHost`, `Shared`,
`GeneratedOwner.*`, `MainActorSnapshotSequence`, `IsolatedSnapshotSequence`, `SnapshotPublisher`,
`RuntimeSharedHost`, `SnapshotSequence`, `OwnerForms.*`, `MultiOwner.*`, `MainActorSnapshotIngress`,
`DistinctSnapshotSequence`). A family changes the harness's behavior as well as its alphabet (the `clocks`,
`lease`, `workers`, and `cancelDelivery` families change the hosts), so a script found in a configuration with
other families replays with the same families in `EXPLORER_FAMILIES` (default `core,second,async,combine,reentrant`).

Environment variables:

| Variable | Effect |
|---|---|
| `EXPLORER_SMOKE=0` | Skips the smoke configuration. |
| `EXPLORER_TIER=standard` | Runs the standard tier in `ExplorerTests/full`. |
| `EXPLORER_FULL=1` | Runs the exhaustive tier in `ExplorerTests/full`. |
| `EXPLORER_DEPTH` | Overrides the slices' depths. |
| `EXPLORER_RUNTIME_DEPTH` | Overrides the raw owner's depths. |
| `EXPLORER_TEARDOWN_DEPTH` | Overrides the owner-teardown depth. |
| `EXPLORER_SLICES="core,second:5;core,async:4"` | Replaces the slices and their full depths. |
| `EXPLORER_KIND` | Limits a run to one class or owner, by the names above. |
| `EXPLORER_HASH=1` | Enables state hashing (unsound, see [Enumeration and pruning](#enumeration-and-pruning)). |
| `EXPLORER_FAILURES=PATH` | Appends every violation found to `PATH`, one Markdown line each. |
| `EXPLORER_ALL=PATH` | Appends every violating sequence, `Class\|script\|violations`, including masked ones. |
| `EXPLORER_COVERAGE=PATH` | Writes the interruption matrix's reached cells, one per line. |
| `EXPLORER_REPLAY="Class: script"` | Replays one script with a trace (`ExplorerTests/replay`). |
| `EXPLORER_FAMILIES` | Selects the replay's families. |
| `EXPLORER_REPLAY_FILE=PATH` | Replays every `id\|Class[families]: script` line (`ExplorerTests/replayFile`). |
| `EXPLORER_SCALAR_REVISIONS=1` | Checks one global revision order instead of per-observation order (I11). |

`replayFile` prints one `EXPLORER CALIBRATION id | script | result` line per script and fails nothing, because
violations are expected there. `Class[family,family]: script` selects the families, while plain `Class: script` takes
the default.

## Maintaining the explorer

Every event and every invariant enters the explorer together with a defect it detects, either a planted defect in a
copy of the production code or a historical defect on an older tree. The new check must report that defect,
and the unmodified tree must run clean. A check that has never failed has not been shown to check anything.

`ExplorerShim.swift` is the only file that adapts the explorer to one tree's presentation API. It reports which
pause hooks and verbs the tree has and binds them. To replay a script against a modified tree, copy the package,
apply the modification, replace the copy's `ExplorerShim.swift` if the tree's API differs, and run the copy's
`ExplorerTests/replay` or `ExplorerTests/replayFile` in a scratch path of its own. `EXPLORER_ALL` collects every
violating sequence, so a defect that another one masks at its shortest sequence can still be found.

A change to presentation, registration, or owner-teardown behavior updates this file and the explorer together.

## Harness

- **Classes.** `SnapshotObservableObject` and `SnapshotPresentation` (passive, "P" below),
  `StateMachineObservableObject` and `StateMachinePresentation` (driving, "D"). Combine events apply to the two
  `ObservableObject` classes. Owner teardown ("T") drives the generated `GeneratedProfile.MainActorHost`,
  `.ActorHost`, and `.Shared` with their `SnapshotPublisher`s.
- **Hosts.** Passive slices use two one-slot `SharedStateMachineHost` fakes, A and B (`ExplorerHost`). Each
  registration is a public `SnapshotSequence(register:)` with a `SnapshotSubscription` token. A registration delivers
  a seed at once. The token's `onCancel` frees the slot when it returns, then releases the registration's callbacks,
  which ends the sequence for its consumer. When the host cancels a token on a background thread, that thread parks
  inside `onCancel`, before the slot is free, until the harness releases it. Driving slices use one one-slot
  `MainActorStateMachineHost` fake (`ExplorerMainHost`) whose `MainActorSnapshotSubscription` frees the slot when
  its action returns. The harness holds this host only weakly, so the presentation's storage is its only owner.
- **Client values.** Every snapshot is a fresh `ExplorerShot` whose destructor records its thread, the slots
  occupied then, and whether the presentation had read it (its revision closure saw it). Neither the hosts nor the
  harness keep one. Its `revision` is a computed witness. The harness reads a stored stamp, and on a driving host
  the presentation's first read of the next value the host hands over (a delivery, a seed, or a receipt) runs the
  event armed at `revision` first. In the `chains` family, a value that a callback's event makes the driving host
  hand over holds the presentation strongly until the harness sees it shown, so a presentation that keeps a value
  it never shows can never be released. The passive revision closure captures an `ExplorerCapture` with the same
  checks. An associated object marks the presentation's deallocation.
- **Revisions.** One counter for the whole run advances by 10 for each new value, so revisions are unique and
  increase in creation order. `applyBelow` uses the gaps. In the `clocks` family (E1), every host keeps a clock of
  its own instead. A host's values advance its clock by 10, and an applied value continues the clock of the host
  that admitted the newest registration. Two fresh hosts therefore both deliver revision 10, and a host observed
  after a busier one delivers a lower revision.
- **Raw owner (R).** The `RuntimeSharedHost` slice drives one raw `RuntimeSharedHost<Int, Int, …>` through its own
  verbs, with no presentation. The `counts` family uses subscriber capacity 3. The `images` family
  (`ExplorerImages.swift`) uses the manual completion policy, three commit slots, two descriptor and execution
  slots, and drivers that return at once. Work A's outcome is refused by every preparation and stays retained, while
  every other work's outcome is accepted. Each payload is a client object the harness tracks by a weak identity. The
  `reconcile` family (`ExplorerReports.swift`) uses the manual completion policy, three executions, and three works
  running (1, 2, and 3) on drivers the harness returns one at a time, with an emission whose handler can hold the
  batch drainer. Its preparation is revision-sensitive. An accepting outcome yields a candidate that starts two more
  works than are free on its first preparation, and again only while the model is the one that first preparation saw.
  Every other preparation refuses. Each outcome carries a serial, so two payloads under one ticket stay distinct.
- **Free-standing sequence (S).** The `SnapshotSequence` slice keeps a `SnapshotSequence(register:)` of host A and
  reads it itself on the main actor.
- **Forcing.** Each event is a synchronous call on the main actor, or `turn`, which awaits one main-actor job
  enqueued behind every job enqueued so far (the FIFO edge that `dropAfterItsJob` and the presentation tests rely
  on). Background steps use semaphores, so the harness waits until the thread is inside `onCancel` or has returned.
  Asynchronous calls start with `Task.immediate`, so they run synchronously to their first suspension.
  Registration closures park on a continuation that only `factoryReturn` or `factoryThrow` resumes. Because Swift's
  `withCheckedContinuation` resumes through the cooperative pool before switching back to the main actor, passive
  settled-state, subscriber-completion, and top-level factory-resumption waits run 30 immediate main-actor turns first
  and then back off with 1 ms sleeps up to a 5 s wall-clock safety net. Safety nets fail the run as I14, I15, I16, or
  I30 rather than drive it, with limits of 5 s per semaphore wait or cooperative-pool settlement wait, 30 turns for
  pure main-actor driving settlement, and 2,000 turns for teardown. The teardown cap covers work on the cooperative
  pool, which turns do not order.
- **Quiescence.** After the last event the harness runs 3 turns, releases every parked cancellation in admission
  order (3 turns after each), checks the settled-state invariants, and then tears down. Teardown cancels every call,
  throws from every parked closure, releases the presentation on the main actor, waits for the presentation to go and
  every slot to free, waits for Combine subscribers to finish, releases what the harness kept (subscribers, a
  saved publisher), and waits for every client value to go. With a driving host that delivers inside its
  cancellations (47a), the release at quiescence stops observing first, so only the drop events reach the disposal
  path, and a defect on that path does not end every sequence at its root.
- **Determinism.** Every passive, driving, generated-owner, confined-stream, publisher, and `MainActorHost` slice
  is fully forced, so replays reproduce each result. The smoke tier runs only these. Four run only in the standard
  and exhaustive tiers:
  - In the `isolated` family, the island's and the actor host's registration calls run on the cooperative pool. The
    harness waits for each call's own signal, with a 2,000-turn safety net. Treat its sightings as leads to replay.
  - In the `ActorHost` teardown slice, H2 orders the driver's start, but the owner hands snapshots to the main actor
    through its own executor, which nothing orders. Treat its sightings as leads to replay.
  - In the `Shared` teardown slice, its delivery task hands each snapshot to the main actor unordered. Before
    every release (`releaseOwner`, `releaseOwnerElsewhere`, `dropAfterJob`, `workerDrop`, and the forced
    releases), the harness waits with a 2,000-turn safety net until every attached subscriber has received the
    owner's current revision or finished. No hand-off is then in flight when the owner goes, and the two orders of
    a release against a delivery the main actor is making are forced by `releaseInHandOff` and
    `releaseInDelivery` (49a). Its runs are reproducible.
  - The driving `cancelDelivery` slice is deterministic, with a smoke depth of zero.
- **Release between notices (E11).** H4 holds the releasing thread right after the owner's notice to the first
  saved publisher. The step first waits until every saved publisher's seed reached the main actor (H3 counts each
  hand-off) and every subscriber has the current revision, and returns once every subscriber of publisher 0 has
  finished. The releasing thread is then still held before its next notice, so later events run on fresh
  main-actor turns between two notices.
- **Pauses inside a call.** H5 runs the registrations and cancellations of `countDuring` on the reading thread,
  after the count loaded a version of the state, guarded to the read's first pass. The emission handler holds the
  drainer on a semaphore. The step awaits the handler's arrival, and `releaseDrainer` awaits `flush(through:)` of
  the current root. In the `reconcile` family, every step ends with `flush(through:)` of the current root unless
  the drainer is held, because the drainer reports capacity conflicts on a task of its own. Without that wait, a
  conflict reported after the step ended would make a sighting irreproducible. Because that handler parks a
  cooperative-pool thread, an exploration runs under the process-wide exclusion that every `.parksCooperativeThread`
  test takes, and gives it up between two sequences every quarter of a second so that the tests waiting for it run.
  Replays carry `.parksCooperativeThread` and hold it throughout.

### Pause hooks

The production code declares package-visible pauses that only the explorer and the tests bind. Each is a
task-local closure that runs at one point of a production path.

| Hook | Declaration | Runs |
|---|---|---|
| H1 | `RemovalObservationPause.$beforeObserving` | Before a presentation's end registers its removal observer. |
| H2, H6 | `DriverStartPause.$beforeStarting` | Before a launched driver runs. H6 is its task-local binding around one `send`. |
| H3 | `HandOffPause.$afterTaking` | In a publisher's hand-off, after it took the value, before the delivery is decided. |
| H4 | `ReleaseNoticePause.$afterNotice` | After each of a releasing owner's notices to its registrations. |
| H5 | `CountReadPause` | Inside `subscriberCount`, after the read loaded a version of the state. |
| H7 | `DecidedDeliveryPause.$beforeReceive` | In a publisher's delivery, after its last source check, before `receive`. |
| H8 | `RemovalCompletionPause.$afterCustody` | After a main-actor end released the discarded element, before completion. |
| H9 | `CapacityConflictPause.$beforeReports` | When a batch of capacity conflicts is found, before any handler runs. |
| H10 | `PresentationDeliveryPause.$betweenReads` | In a presentation publisher's delivery of a buffered value, between its demand claim and its lifetime read. |
| — | `DestructorPause` | In `dropAfterItsJob`, after a destructor made its job runnable. |

## Alphabet

Hosts are A and B. "When enabled" is the validity filter. Event numbers label events for cross-reference, grouped by
subject and not contiguous.

### Observation (P)

- **1** `observe(H)` — synchronous `observe(host)` of shared host H.
- **2** `observeFrom(H)` — synchronous `observe(snapshotsFrom:)` whose closure registers with H.
- **3** `observeSeq(H)` — the client registers a sequence with H (`try host.snapshots()`), then `observe(_:)` of
  it. Nothing happens if H refuses (the client's `try` throws first).
- **4** `followSeq(H)` — as `observeSeq`, then `follow(_:)` of it on a task of its own. `followUnseeded(H)` does so
  with a registration that delivers no seed, so the follower waits for its first element, where `cancelFollower`
  can reach it.
- **5** `observeAsync(H)` — asynchronous `observe(snapshotsFrom:)`. Its closure parks when invoked and registers
  with H only on `factoryReturn`.
- **6** `observeAsyncHeld(H)` — asynchronous `observe(snapshotsFrom:)` whose closure registers with H as soon as
  it is invoked and parks before returning the sequence.
- **7** `followAsync(H)` — `follow(snapshotsFrom:)` on a task of its own. Its closure parks like 5.
- **8** `factoryReturn` — the oldest parked closure returns (registering first for 5 and 7), then one turn.
- **9** `factoryThrow` — the oldest parked closure throws `capacityExceeded`, then one turn. A closure of 6 that
  registered cancels its sequence on the main actor first.
- **10** `cancelFollower` — cancels the newest follower task not yet cancelled (4 or 7).
- **10a** `observeIsolated` — after one turn, asynchronous `observe(host, isolation:)` of a one-slot
  `IsolatedStateMachineHost` confined to an actor of the harness (`ExplorerIsland`). It shares host A's slot and
  registrations. The call runs on that actor. The host's registration call registers with A and parks the actor's
  thread until `isolatedReturn`. The step waits, up to 2,000 turns as a safety net, until the call has registered
  or has returned.
- **10b** `isolatedReturn` — the parked registration call returns its sequence. The step waits, up to 2,000 turns,
  until the call returns. A call still waiting then is waiting for main-actor work.
- **10c** `observeActor` — asynchronous `observe(host)` of a one-slot `ActorStateMachineHost` that shares host A's
  slot. Its registration call registers with A, or throws the refusal at once, and then suspends until
  `actorReturn`. The presentation calls the requirement off the main actor, so the step waits, up to 2,000 turns,
  until the call has suspended or thrown, or the observation finished. An attempt's first call counts as a
  registering call. A later call for the same attempt, a deferred refusal's retry, is checked by I8.
- **10d** `actorReturn` — the oldest suspended actor-host call returns its sequence. The step waits until it has
  returned and the observation call has finished or called again.
- **11** `stop` — `stopObserving()`. Enabled when an attempt is current.
- **12** `apply` — P calls `apply(_:)` with a newer value. D calls `send(_:)`, and the host admits a change and
  delivers it.
- **13** `applyBelow` — P calls `apply(_:)` with a value 5 revisions below the newest value made so far, so it sits
  above every older one, below a deferred value, and above the one being assigned.
- **14** `close` — D calls `close()`.

### Host

- **15** `deliver(H)` — the host offers a new value to the registration holding its slot, from the main thread.
- **16** `finish(H)` — the host finishes that registration (`finish()` on P, `onFinish` on D).
- **17** `hostCancel(H)` — P: the host begins cancelling that registration's token on a background thread, which
  parks inside `onCancel`. Enabled when the registration is active and not parked.
- **18** `hostCancelReturn(H)` — P: the parked cancellation frees the slot and returns. Enabled when parked.
- **19** `hostCancelMain(H)` — the host cancels the token on the main thread, so `onCancel` runs there and an armed
  `onCancel` callback fires. On D, the host calls `onFinish` from inside that cancellation before freeing the slot,
  as a host that removes its subscriber does.

### Lifetime and scheduling

- **20** `dropMain` — the harness releases its only reference to the presentation on the main actor.
- **21** `dropElsewhere` — the harness hands it to a background thread that releases it while the main actor
  waits, so the destructor's main-actor job runs after the release returns.
- **22** `dropAfterJob` — after one turn, runs `dropAfterItsJob`. The releasing thread pauses after the destructor
  made its job runnable until that job has run (`DestructorPause`), the job-first schedule. The harness's own
  reference is consumed into that thread, so its release is the last one.
- **23** `turn` — one main-actor turn. At most two in a row.

### Combine (`ObservableObject` classes)

- **24** `savePublisher` — keeps the value `presentedSnapshots` returns at that point.
- **25** `subscribe(fresh|saved, 1|max)` — attaches a subscriber to `presentedSnapshots`, or to the saved
  publisher, which requests one value or unlimited demand from `receive(subscription:)`. A fresh subscription
  needs the presentation alive, while a saved one can attach after its release.
- **26** `subscribeProjected` — attaches an unlimited subscriber to `presentedSnapshots(projecting:)`.
- **27** `request` — the newest limited subscriber requests one more value.
- **28** `cancelSubscription` — the newest open subscriber cancels.

### Reentry

- **29** `arm(hook, event)` — runs `event` once, synchronously, inside the next run of `hook`, at most one arm per
  sequence. Hooks are `report` (`$isObserving` sink or Observation change handler), `change` (`objectWillChange` or
  Observation change of `snapshot`), `onCancel` (a fake host's token action on the main thread), `revision` (P
  revision closure), `factory` (when the presentation invokes a parked closure), `subscription`
  (`receive(subscription:)`, after it requests), `value` (`receive(_:)`), and `projection` (the transform of
  `presentedSnapshots(projecting:)`, including the seed). On a driving presentation, `revision` is the snapshot's
  `revision` witness at the presentation's first read of the next value the host hands over. Armed events are `stop`,
  `apply`, `observe(A)`, `observe(B)`, `dropMain`, `finish(A)`, `observeAsync(A)`, `followSeq(A)`, `cancelFollower`,
  `subscribe(fresh,max)`, `cancelSubscription`, and `request`. D adds `close` and `deliver(A)`. A replayed script
  may arm several hooks and nest `+` (for example `arm(change,apply+stop+applyBelow)`). Enumeration arms one hook
  with one or two events.
- **30** `arm(hook, e1+e2)` — the `pairs` family, where two distinct events from `stop`, `apply`, `applyBelow`,
  `observe(A)`, `followSeq(A)`, and `cancelFollower` run in order in one callback.

### Owner teardown (T; owners `MainActorHost`, `ActorHost`, `Shared` of the profile example graph)

- **31** `save(k)` — saves owner publisher k ∈ {0, 1} via `snapshotPublisher { $0.revision }`. Publisher 1 is saved
  only after publisher 0.
- **32** `attach(k)` — attaches a subscriber with unlimited demand to saved publisher k.
- **33** `capture(k)` — registers a callback (`subscribe`) whose capture, when destroyed on the main thread,
  attaches a subscriber to publisher k. Publisher k may be saved later.
- **34** `driver(k)` — sends `.load`, which launches the fetch driver, and waits until it has started. The
  driver's cancellation handler, on the main thread, attaches a subscriber to publisher k.
- **35** `apply` — `MainActorHost` only. Sends `.load` without waiting for the driver to start. The driver is a
  main-actor job, so this stays deterministic.
- **36** `releaseOwner`, `releaseOwnerElsewhere` — releases the harness's only reference to the owner on the main
  actor, or on a background thread while the main actor waits.
- **37** `workerDrop` — `Shared` only. Registers a callback whose capture drops the owner, cancels it on a
  background thread, and returns once that thread has dropped the owner and parked, still holding the owner's
  state.
- **38** `workerReturn` — the parked thread returns.
- **39** `turn` — as 23.

### Further sources and events

- **40** `observeAsyncNow(H)`, `observeAsyncFinished(H)` — asynchronous `observe(snapshotsFrom:)` whose closure
  registers and returns at once. In the second form the host first finishes the registration, so its seed is the
  final, unread element. Both are offered as armed events too, so one can start inside a publication.
- **41** `observeClaimed(H)` — the client registers a sequence, makes its iterator (another consumer owns it), then
  calls `observe(_:)` on it.
- **42** `followCancelled(H)` — `follow(_:)` of a newly registered sequence on a task cancelled before the call.
- **43** `observe(M)`, `observe(I)` and `deliver`/`finish`/`hostCancelMain` of M and I — the `callback` family,
  using a `MainActorStateMachineHost` (M) and an `IsolatedStateMachineHost<MainActor>` (I) of the harness's own,
  observed through the synchronous callback overloads. A host-side cancellation calls `onFinish` from inside
  `onCancel` before freeing the slot. `close` closes M. It finishes its subscriber, and a later registration receives
  the closed snapshot and finishes inside `subscribe`.
- **44** `lease` family — hosts A and B free a slot from the destructor of a lease that their token's action
  captures rather than from the action itself.
- **45** `stopRacingRemoval` — `stopObserving()` with H1 bound. Host A's parked cancellations return inside the
  pause, just before the end registers its removal observer. Enabled when a cancellation of A is parked.
- **46** `deliverElsewhere(H)` — `workers` family. The host offers a value from a background thread while the main
  actor waits. A value that offer displaces may be released on that thread (latest-value delivery), and I1
  exempts it.
- **47** `echo(H)` — `workers` family. From that event on, every snapshot shown makes the host deliver another
  value, up to 100 (a source that delivers from each snapshot shown, checked by I36).
- **47a** `deliverInCancel(H)` — a host of the client's own that, from that event on, delivers a new value to its
  registration from inside every cancellation of its token, on the cancelling thread, before it frees the slot.
  The host's own reference to the value goes right after the delivery returns. Offered only as the first event,
  since the mode holds for the whole sequence. It covers host A in `core` (P), hosts M and I in `callback` (P), and
  the driving host in `cancelDelivery` (D), where it exercises stop, close, the host's own cancellation, and the
  disposal turn of a released presentation.
- **48** `tokenDropAfterJob` — driving slices. A `MainActorSnapshotSubscription(onCancel:)` of the harness's own,
  whose action holds the only reference to a tracked value, released on a background thread in the job-first
  schedule.
- **49** `driverParked(k)`, `driverGo` — `ActorHost` and `Shared` teardown. `driverParked(k)` calls `send(.load)`
  with the driver-start pause bound (H6, the task-local `DriverStartPause.$beforeStarting` around the `send` that
  launches the work, so the pause belongs to that owner's batch), returning once the launched driver task is parked
  before its driver runs. `driverGo` lets it start and waits until it has. A `MainActorHost` runs the pause on the
  main actor, where the harness cannot wait, and keeps `apply` (send without waiting), which is deterministic there.
- **49a** `releaseInHandOff(k)`, `releaseInDelivery(k)` — `Shared` teardown, covering the two forced orders of a
  release against a delivery (the `SnapshotPublisher` delivery step of `API-120`). Each first settles the deliveries,
  records the accepted bound, and registers a sentinel callback whose capture signals when the owner's teardown
  releases it, which it does only after every publisher's source has closed. `releaseInHandOff(k)` saves publisher k
  with H3 bound. Inside its first hand-off, after the value is taken and before the delivery is decided, a subscriber
  attaches and the owner is released on a background thread while the main actor waits until the sentinel goes.
  `releaseInDelivery(k)` attaches a subscriber to saved publisher k (one without a subscriber) that releases the
  owner the same way from inside its first value, after the delivery was decided. Each is enabled once per sequence,
  before the release.
- **50** Generated-owner slice (`GeneratedOwner.*`) — a passive presentation of the profile graph's generated
  `IsolatedHost<MainActor>` (owner A) and `MainActorHost` (owner B), through their synchronous overloads, with events
  `observe(A|B)`, `stop`, `dropMain`, `dropElsewhere`, `dropAfterJob`, and `turn`.
- **51** Confined-stream slices (`MainActorSnapshotSequence`, `IsolatedSnapshotSequence`) — a stream registered with
  M or I and kept by an object the harness releases, with events `observe` (register), `apply` (read, enabled only
  while an element is pending), `stop` (`cancel()`), `deliver`, `finish`, `hostCancelMain`, `dropMain`,
  `dropElsewhere`, `dropAfterJob`, and `turn`. At quiescence the fake I host sweeps the callbacks of a stream dropped
  without cancellation, as a real host does on its next sweep.
- **52** Publisher slice (`SnapshotPublisher`) — uses the `MainActorHost` teardown alphabet plus `request`, a burst
  of 40 `.authenticationChanged` changes in one step, and `subscribeProjected`, an echoing subscriber of publisher 0
  that changes the owner from every value it receives, up to 100. For E9 on that saved owner publisher,
  `subscribe(fresh,0)` attaches a subscriber with zero initial demand, `subscribe(fresh,1+)` attaches one that
  requests one value and returns one from each, `requestOldest` (before or after the release) has the oldest limited
  one request one more, and `cancelFirstSubscriber` cancels the oldest open one, which is owed no completion. Its
  recorder checks I18 and I20 for each.
- **53** `elsewhere` family (E10), driving Combine class — `subscribe(elsewhere,1+)` and `subscribe(elsewhere,once)`
  attach a `Sendable` subscriber through `map(\.revision).receive(on:)` of a serial queue the harness keeps
  suspended between steps, so no `Subscription` crosses threads and no client value leaves the main actor. Combine
  then requests the demand each value returns, and `prefix(1)` cancels, on that queue. `requestElsewhere` runs what
  the queue holds while the main actor waits. `arm(decision, e)` runs `e` inside H10, between a buffered delivery's
  demand claim and its lifetime read, for `e` in `dropElsewhere`, `requestElsewhere`, and their pairs with
  `dropMain`. The slice's own alphabet adds `apply`, `stop`, `dropMain`, `dropElsewhere`, `deliver(A)`, and `turn`.

### Scenario families

The labels E1 to E15 name the scenarios that the families below cover. The code's comments use them too.

| Label | Scenario | Events |
|---|---|---|
| E1 | Independent revision clocks per host, equal-revision offers | 62 |
| E2 | Refused, occupied, and closed creation of a driving presentation, `resumeObserving()` | 63–65 |
| E3 | A driving presentation of a real generated owner | 70 |
| E4 | A held batch drainer and unrelated edits | 58, 59 |
| E5, E6 | Out-of-order closure resumption, the oldest follower, a direct call's task | 67 |
| E7 | A free-standing `SnapshotSequence` read on the main actor | 68 |
| E8 | Subscriber capacity above one, shared by pending and ordinary registrations | 55, 56, 75 |
| E9 | Combine demand: zero, finite, returned from the callback, an older subscription | 66 |
| E10 | Combine `request` or `cancel` from another thread, inside a buffered delivery's decision | 53 |
| E11 | A release held between two of the owner's notices | 54 |
| E12 | `MainActorSnapshotIngress`, distinct projections, per-property invalidation | 76, 77, I51 |
| E13 | Reconciliation of retained completions on a raw owner | 57, 59a, 60, 61 |
| E14 | Proposals across a reset and across owners | 70, 78 |
| E15 | Two armed hooks, a hook that arms another, reconciliation from a handler | 61, 72 |

- **54** `releaseNotice`, `noticeGo` — E11, `Shared` and `ActorHost` teardown. `releaseNotice` releases the owner
  on a background thread held by H4 after its notice to saved publisher 0 (the harness tracks the order of the
  owner's registrations, which is the order of its notices). Enabled when publisher 0 has an open subscriber and
  the owner accepted no change. An owner with work to process tears down on its drainer's thread after the drain,
  where a pause bound for the releasing task does not run. `noticeGo` lets the releasing thread notify the rest
  and return.
- **55** `register`, `registerPending`, `cancelOldest`, `cancelNewest`, `count` — E8, raw owner `counts` family.
  Covers a callback registration, a pending-completion registration (which share the capacity of 3), cancellation of
  the oldest or newest live registration, and a plain `subscriberCount` read.
- **56** `countDuring(chain)` — E8. Calls `subscriberCount` with H5 bound, where `chain` is every sequence of one to
  four `register`/`cancelOldest` steps run inside the read after it loaded a version. Once per sequence.
- **57** `refuse(k)`, `accept(k)` — E13, raw owner `reconcile` family. Work k's outcome is delivered explicitly, and
  the completion's preparation either refuses it or accepts it with a candidate that starts two more works than the
  executions free. `returnRefuse(k)` and `returnAccept(k)` return work k's own driver with that outcome, which the
  owner's coordinator delivers from the worker. The step waits until the work's execution is gone and its outcome is
  past admission and preparation. Each work runs once. Works are alike until an event names one, so only the lowest
  unnamed work is offered.
- **57a** `stage(…)` — first event only. Puts the three works in a starting arrangement, each running, refused, or
  waiting for capacity, reached by an explicit delivery (`rD`, `aD`) or its driver's return (`rR`, `aR`), with the
  drainer held (`held`) after the refusals and before the acceptances, and the root edited afterward (`edit`).
  Works are listed by starting state, so one arrangement stands for every permutation, giving 140 arrangements.
- **58** `holdDrainer`, `releaseDrainer` — E4. An emission whose handler holds the batch drainer (once per
  sequence), and its release, after which the harness awaits `flush(through:)` of the current root.
- **59** `edit` — E4. An unrelated edit that advances the root.
- **59a** `releaseDrivers` — E13. The held drivers return, and the step settles once their executions,
  deliveries, and reports finish. Once per sequence.
- **60** `reconcile(k)`, `discard(k)` — E13. Explicit `reconcile(id:)` or `discardPending(id:)` of work k's
  retained completion, enabled while one is retained. `redeliver(k)` (once per sequence while work k's completion is
  retained) delivers another payload under the same ticket explicitly. It must prepare nothing (I44), and every
  later report still carries the first payload.
- **61** `onReport(j, reconcile(k))`, `onReport(j, discard(k))` — E13/E15. Inside the next report of work j's
  completion, whichever path makes it (the explicit attempt's own report, a conflict of a batch, a worker return's
  report, or the entry's own report when j = k), reconcile or discard work k once. Once per sequence.
- **61a** `flushHeld` — `flush(through:)` of the receipt the held drainer's batch returned, started on a task of its
  own while the drainer is held (I53).

- **62** `deliverEqual(H)` — E1, passive `clocks` family. Host H offers a new value whose revision equals its
  latest offer's.
- **63** `createRefusing`, `createOccupied`, `createClosed` — E2, driving `resume` family, first event only. The
  presentation is created while the host's `subscribe` delivers a newer snapshot and then throws, while a
  registration of the harness's own holds the only slot, or after the host closed.
- **64** `resume` — `resumeObserving()`, at top level or armed in a callback.
- **65** `refuseNext`, `occupy`, `vacate` — E2. `refuseNext` makes the host's next `subscribe` deliver a newer
  snapshot and then refuse. `occupy` takes the free slot with a registration of the harness's own, keeping the host
  alive as another client would, and `vacate` ends it. The harness's registration is withheld, so no ownership
  invariant counts it.
- **66** `subscribe(fresh,0)`, `subscribe(fresh,1+)`, `requestOldest`, `cancelFirstSubscriber`, `saveProjected`,
  `subscribe(savedProjected,max)` — E9, `demand` family. Covers a subscriber with zero initial demand, one that
  requests one value and returns `.max(1)` from each `receive(_:)`, the oldest open limited subscriber requesting one
  more, the oldest open subscriber cancelling, a saved `presentedSnapshots(projecting:)` publisher, and a subscriber
  attached to it later.
- **67** `factoryReturnNewest`, `factoryThrowNewest`, `cancelFollowerOldest`, `cancelCall` — E5/E6, passive
  `selection` family. The newest parked registration closure returns or throws out of order, the oldest uncancelled
  follower is cancelled, or the task of the newest direct asynchronous observation is cancelled.
- **68** Free-standing sequence slice (`SnapshotSequence`), E7 — events `observe(A)` (seeded) or `observeUnseeded`,
  `claim` (the first claim makes the iterator, and a second claim must end at once), `read` (a read on the main actor
  that returns a pending element at once or waits), `cancelReader` (cancels the waiting read's task), `stop`
  (`cancel()`), `deliver(A)`, `finish(A)`, `hostCancel(A)`, `hostCancelReturn(A)`, `hostCancelMain(A)`,
  `dropMain`, `dropElsewhere`, and `turn`. After every event that completes a waiting read, the step waits for that
  read's return, with a 2,000-turn safety net that fails the run as I16. One read runs after the end.
  `ExplorerTests/boundedWaitRegistrationAndFinalOfferSchedules` adds scoped deterministic schedules over the same
  one-slot fake host (`ExplorerHost`) and manual clock for `SnapshotSequence.wait(deadline:clock:where:)`: a deadline
  releasing a claimed registration while a worker's `hostCancel` is parked (I2, I15), a final offer and `finish`
  arriving synchronously during the initial non-matching predicate right as the deadline expires (I41, I15), and a
  host `finish` with a final offer racing ahead of deadline expiry (`.ended` preserved over `.timedOut`, I41, I2,
  I15).
- **69** `arm(h, e)` at the client callback sites of the `sites` family — `hostRead` (a host's `snapshot()` on the
  main thread), `hostSend` (the driving host's `send`, after it delivered the change, before it returns),
  `hostSubscribe` (a registration call on the main thread, after its provisional delivery, before it returns or
  throws, including the refusing `subscribe` of 65), `hostClose` (the driving host's `close`, after it finished
  its subscriber), `subscriptionBefore` (`receive(subscription:)` before it requests anything), `completion`
  (`receive(completion:)`), and `destroy` (the destructor of a client value, whether a shown, unread, displaced, or
  applied snapshot, on the main thread). Each runs the slice's ordinary armed events.
- **70** Real-owner driving slice (`GeneratedOwner.StateMachineObservableObject`,
  `GeneratedOwner.StateMachinePresentation`), E3 — a driving presentation of the profile graph's generated
  `MainActorHost`, whose drivers fail at once, so a load returns to the failed phase on a later turn through the
  owner's own subscription. Events are `apply` (`send(.load)`), `sendCancel`, `ownerSend` (the owner admits `cancel`
  and `load` without the presentation), `commitCurrent` (a proposal from the snapshot shown: begin, cancel, or
  retry), `saveProposal` and `commitSaved` (a proposal kept across later events, stale once the owner moved),
  `commitForeign` (a proposal from another owner), `close`, `stop`, `resume`, `dropMain`, `dropElsewhere`,
  `subscribe(fresh,max)` (Combine class), `turn`, and one armed callback per sequence (`arm(change, e)` for `e` in
  `stop`, `resume`, `ownerSend+resume+stop`, and `arm(report, e)` for `e` in `stop`, `resume`).

- **71** `register`, `edit`, `copyOwner`, `dropCopy`, `releaseOwner`, `releaseOwnerElsewhere`, `turn` — the raw
  owner's `copies` family, driving a manual `RuntimeSharedHost` held only in two slots of the harness (the owner and
  one copy). `register` makes a callback registration that records its finish, `copyOwner` keeps a copy, `dropCopy`
  releases it on a background thread, and the releases empty the owner's slot here or on a background thread.
- **72** `chains` family (E15) — two arms per sequence, enumerated independently, plus the inner events `arm(h2, e)`.
  On passive classes, `h2` is in `report`, `change`, `onCancel` and `e` is in `stop`, `apply`, `observe(A)`. A hook
  so armed fires on its own later run, never inside another hook's run. On driving classes, `h2` is in `report`,
  `change`, `onCancel` and `e` is in `stop`, `resume`, `apply`, beside `deliver(A)+resume+stop`, `deliver(A)+stop`,
  `apply+stop`, and a callback that arms a second callback and then stops before it returns (`arm(h2, e)+stop` for
  `e` in `resume`, `apply`). A hook armed from inside a callback may fire inside that callback's own run (a hook
  inside a hook, or the same hook revisited), at most two deep.
- **73** `matrix` family — uses an alphabet of its own. Passive slices include the forms `observe(A)`, `observe(B)`,
  `observe(M)`, `observe(I)`, `observeAsyncNow(A)`, and `observeSeq(A)`, plus `apply`, `stop`, `dropMain`,
  `dropElsewhere`, `subscribe(fresh,max)`, the hosts' `deliver`/`finish`/`hostCancelMain`, and `turn`. The arms are
  `arm(h, e)` for every site h in `change`, `report`, `hostSubscribe`, `hostRead`, `onCancel`, `destroy` (plus
  `subscriptionBefore`, `value`, and `completion` for the Combine class), and every interrupt e in `stop`, `dropMain`,
  `dropElsewhere`, and `observe(A|B|M|I)`. Driving slices include `apply`, `close`, `stop`, `dropMain`,
  `dropElsewhere`, `resume`, `subscribe(fresh,max)`, the host's events, and arms of every site (adding `hostSend` and
  `hostClose`) with `stop`, `close`, `dropMain`, `dropElsewhere`, and `resume`. The host's sites do not fire inside
  the client's own registration of a sequence, which precedes the presentation's call. The coverage table is below.
- **74** Owner-forms slice (`OwnerForms.SnapshotObservableObject`, `OwnerForms.SnapshotPresentation`), standard and
  exhaustive tiers — a passive presentation of four real generated owners. A is a `Shared`, B an `ActorHost`, M an
  `ActorHost(isolatedTo:)` that shares a harness actor's executor, and I an `IsolatedHost` confined to that actor,
  created there, observed from there, and torn down there at its release. Events are `observe(k)`, `stop`, `dropMain`,
  `dropElsewhere`, `deliver(k)` (owner k admits `cancel` and `load` on its own), `finish(k)` (owner k closes),
  `hostCancelMain(k)` (the harness releases its only reference to owner k, on its actor for I), and `turn`. Each step
  waits, with a safety net, for the settled state.
- **75** Multi-owner slice (`MultiOwner.*`), E8, standard and exhaustive tiers — three presentations of one class
  and three generated `Shared` owners (A and B with two subscriber slots, C with one). Events are `present(p,K)`
  (presentation p observes owner K), `stopP(p)`, `dropP(p)`, `pending(K)` (a `pendingCompletionUpdates()`
  registration on K, which shares the slots), `cancelOldest`, `deliver(K)`, and `turn`.
- **76** Ingress slice (`MainActorSnapshotIngress`), E12, deterministic — events `apply` (an offer of a newer
  revision on the main thread), `deliverElsewhere(A)` (an offer from a background thread while the main actor waits),
  `applyBelow` (a revision below the newest offered), `request` (40 offers in one step), `echo(A)` (every delivery
  offers a newer value from inside the callback, up to 100), `stop` (`cancel()`), and `turn`.
- **77** Distinct-projection slice (`DistinctSnapshotSequence`), E12, standard and exhaustive tiers —
  `distinctSnapshots` sequences of a generated `Shared`, projected to the phase's name. Sequence 0 is registered at
  the start and sequence 1 by `observe(B)`. Events are `apply`, `sendCancel`, `edit` (`authenticationChanged`, a
  change within the phase), `finish(A)` (close), `readSeq(k)`, `stop` (cancels sequence 0), and `turn`.
- **78** `resetOwner` — E14, real-owner driving slice (70). The owner resets to its initial phase without the
  presentation.
- **79** `emit`, `arm(emission, e)` — raw owner `reconcile` family. An emission whose handler, on the drainer's
  thread, runs the armed `reconcile(k)` or `edit` (an admission from inside an emission handler).
- **80** `arm(equality, edit)` — distinct-projection slice (77). The next `==` the owner evaluates for a projection
  reads the owner and admits a change from inside the witness, wherever the comparison runs. A comparison inside a
  lock would deadlock, which fails the step as I16.
- **81** `releaseDecided(k)` — `Shared` and `ActorHost` teardown, H7. Attaches to saved publisher k with the pause
  bound. Inside the first delivery, after its last source check and before `receive`, the owner is released on a
  background thread until its teardown has begun. Not enabled on a `MainActorHost`, which tears down on the main actor
  that the forced release waits on.
- **82** `stopCustody` — passive `core`, H8. Calls `stopObserving()` with the pause bound. Inside the window between
  the discarded element's release and the removal's completion, no unread element of a removed registration may be
  alive (I34, forced).
- **84** `registerPending`, `cancelNewest`, `holdReport`, `releaseReport`, `completeOthers`, `turn` — the raw
  owner's `images` family. Covers a pending-completion registration whose callback keeps nothing (at most two),
  cancelling the newest one, an explicit `reconcile(id:)` of A on a thread of its own whose report the handler holds
  on a gate until `releaseReport` (once per sequence), and four further works started and completed one at a time,
  with the step waiting until each is admitted and no longer retained (at most twice). Its completions run on the
  owner's workers, which turns do not order, so the family runs in the standard and exhaustive tiers only.
- **83** H9 is bound around every `reconcile` step. It counts the batches of two or more capacity conflicts
  reported while an `onReport` is armed, the window in which a handler of one conflict can reconcile another,
  and the count is printed at the end of a run (`EXPLORER capacity-conflict report windows reached: n`). Conflicts a
  returning worker's coordinator finds run on a detached task, which the task-local pause does not reach.

### Families (alphabet slices)

`matrix` (73), `chains` (72), `copies` (71), `images` (84), `sites` (69, with `reentrant`), `clocks` (62, with `core`
and `second`, and `applyBelow` off), `counts` (55–56), `reconcile` (57–61a, 79), `elsewhere` (53, driving Combine),
`resume` (63–65, driving), `demand` (66, `ObservableObject` classes), `selection` (67, with `async`), `core` (1,
11–23 except 14 for P, and 47a for host A, plus 12, 14–16, and 19–23 for D), `second` (host B), `async` (2–10),
`isolated` (10a–10d), `combine` (24–28), `reentrant` (29), `pairs` (30), `triples` (three events per callback),
`callback` (43, and 47a for M and I), `lease` (44), `workers` (43–47), `cancelDelivery` (D only, 47a), and
`followers` (the follower hand-off events only: `followAsync`, `followSeq`, `factoryReturn`, `factoryThrow`,
`cancelFollower`, `deliver`, `turn`, and `arm(change, …)` of `apply`/`cancelFollower` alone or paired). A
configuration is one class and a set of families. The teardown owners use 31–39 as one alphabet.

## Invariants

Each invariant is checked where it can first fail, whether in a destructor, in a callback, at the boundary after
each harness action (each event and each hook's start and end), or at quiescence (Q). The identifiers match
`ExplorerInvariant` in `ExplorerWorld.swift`.

"Let go" means the presentation ended that observation through a later observation, `stop`, or the presentation's
deallocation, which a running `async` call can postpone after the harness drops its reference. A `follow(_:)` on
a cancelled task ends the observation it began before the sequence's release. A follower's cancellation lets go
its deliveries and the values applied inside a callback while it was current, which a publication defers. A
top-level `apply` is shown at once and stays exempt. A registration that a closure has made but not returned (6),
or that it gave up (9), is "withheld" and is not the presentation's, so no ownership invariant counts it.

- **I1** Every client value (snapshot, unread element, revision closure capture) is destroyed on the main thread.
  Source: class reference ("releases … on the main actor"), `PresentingState.md` disposal, OBS-005. Exempt values are
  a value displaced by an offer from a background thread (46, and 47a's offer from a cancellation on a background
  thread) and, for the passive hosts of 47a, a value delivered inside a cancellation whose destructor runs in the
  host's own release of it, which happens only when the presentation did not keep it because an ended sequence
  refuses an element and the value stays the host's.
- **I2** An element still unread in a registration that has ended (let go or ended by its host) is destroyed only
  after that registration's slot is free. Exempt values are an element displaced by a later offer, one offered after
  the end, and one that may have been handed to a waiting read (delivered after the reader had a turn to start
  waiting). Source: `cancelOnMainActor(then:)`, `RemovalCompletionTests`. A value delivered from inside a
  cancellation of the token (47a), if a presentation kept it, is destroyed only after the slot is free. The passive
  hosts' own release of one the presentation did not keep is exempt, whereas the driving host's is not. A driving
  presentation takes such a snapshot and releases it on a later main-actor turn, once the slot is free
  (`stopObserving()` reference, `PresentingState.md` "Separate observation from running work"), so a destructor that
  registers again finds the slot free. The disposal turn of a released driving presentation does not keep it either.
- **I3** The snapshot the presentation still holds at teardown, identified by object identity rather than revision
  alone, is destroyed only once no registration of the presentation holds a slot. An already displaced earlier
  snapshot may be released later by a client frame without violating this rule. Because a change callback reads the
  outgoing snapshot, the held identity is uncertain during an unsampled assignment until a later read observes a
  different identity or reaches a settled read (in Combine, a liveness report accounts for one `objectWillChange`
  announcement without clearing another in-flight change). Source: class reference ("only once that removal has
  completed releases its snapshot").
- **I4** The revision closure's capture is destroyed only once no registration holds a slot. Source: as I3 ("its
  closures").
- **I5** `isObserving` is never reported `false` while a registration that the presentation let go, or that its
  host finished, still holds a slot. A host's cancellation still parked elsewhere is not counted because the
  presentation learns of it only when it returns. On D, no registration may hold the slot at `false`. When `resume`
  is in the alphabet, no registration that has ended (by the presentation's stop, close, or release, or by its host)
  may hold the slot, because a registration `resumeObserving()` made inside the `willSet` of that `false` is live.
  Source: `isObserving` reference, UI-004.
- **I6** On Combine classes, reports alternate, and the first is `true` on P. D reports only `false` after creation,
  unless `resume` is in the alphabet, in which case D's reports alternate too. Observation classes derive the value
  from the old one, so this is not checked there.
- **I7** At every top-level boundary, `isObserving` equals the last value reported.
- **I8** A registration admitted when no harness call that registers is running (a retry or a registration the
  presentation starts by itself) is admitted only when the last report is not `true` and no let-go or finished
  registration holds a slot. Source: `observe(host)` reference ("after isObserving has reported the end of the
  earlier one"). A refused synchronous `observe` throws at once and nothing registers later, and an `async` host
  form waits for earlier registrations and then registers once, so a second registration call by the same
  asynchronous actor-host attempt is a violation of I8 too.
- **I9** When the presentation invokes an asynchronous registration closure, no registration it let go still holds
  a slot and no other closure of it is still registering. Source: `observe(snapshotsFrom:)` async reference.
- **I10** A value is never first shown after the observation it belongs to was let go. That covers deliveries of a
  registration after its observation ended or its follower was cancelled, a host read for an attempt that ended, and
  an applied value deferred in a generation that ended or before its follower was cancelled, including while
  `follow(snapshotsFrom:)` is still registering (an `apply` accepted after cancellation remains eligible). A value
  whose publication a change, value, or projection callback announced is still assigned after that callback, so the
  next newly shown value after such a hook is exempt if it was made before the hook ran. On D, stopping discards an
  observation value whose publication has not been announced, while a change admitted through the presentation still publishes its receipt. An unannounced value
  of a registration the presentation ended by `stop`, `close`, or a release (its seed, a resumed registration's
  deferred seed included, or a delivery) is therefore never shown afterward, and neither is a delivery the host made
  on its own after it finished the registration. The receipt of `send` or `close`, and the host's delivery of that
  same change, are not observation values. The boundary is sampled when each callback starts, so a value already
  assigned when a callback runs counts as shown before it. On a real owner (70), once stopped, a revision first shown
  is the receipt or rejection snapshot of a call through the presentation, or one a change callback announced before
  the stop. With `resume`, a resumption starts a new observation, and a delivery from its own callbacks is current.
  The fake host delivers nothing to a registration it has finished. Under 47a, P never shows a value delivered inside
  the cancellation of a registration that had already ended (let go, or finished by its host), and D never shows any
  value delivered inside a cancellation because it claims the end, or learns of the host's, before the cancellation
  runs. Source: `follow` reference, `apply` reference ("one that will not be shown then … holds back no newer
  snapshot"), `stopObserving()` reference, `PresentingState.md`.
- **I11** Revision order belongs to one observation. Within one observation (an attempt, or the generation of a
  stop) the shown revision never decreases, and a value offered with an equal revision (62) is never shown. A
  host's snapshot of a newer observation is a new baseline at any revision. A value of an older observation is
  never shown after one of a newer observation. Applied values belong to the generation they were applied in and
  always compare by revision. With one clock for the whole run this reduces to one increasing order.
  `EXPLORER_SCALAR_REVISIONS=1` checks that single order instead, for replays against a tree whose presentations
  compare revisions across observations. Source: `PresentationPublisher` reference ("Revision order belongs to one
  observation"), UI-004 ("A delayed delivery must not regress the visible model").
- **I12** A top-level `apply`/`send` that returned `true` (P) or a receipt (D) is shown when it returns, unless the
  presentation was released inside it. One accepted inside a callback is shown, or a newer one is, by quiescence
  unless its generation ended first. Source: `apply`, `send` references.
- **I13** A refused synchronous observation throws without changing the shown snapshot, and its attempt never holds
  a registration. Source: `observe(host)` reference.
- **I14** Q, presentation alive: `isObserving` is `true` exactly when one registration of the presentation holds a
  slot (closures still registering are excluded).
- **I15** Q, after teardown: no call is running, the presentation is deallocated, every slot is free, and every
  client value and capture is destroyed. On D, the host is also deallocated.
- **I14 and I15 for real owners (74, 75)**, at the settled state after every step: an observing presentation shows
  its owner's current revision, and the owner counts exactly the registrations the model gives it. A closed owner
  leaves its presentation showing the closed snapshot and not observing. A released owner leaves it not
  observing. A stopped presentation does not observe. Once the presentations are released, no owner counts a
  registration (and for 74 the isolated owner is gone after its release on its own actor). In 75 (with I43), an
  owner refuses a presentation or a pending registration exactly when its live presentations and pending
  registrations fill its capacity. Observing the same owner again reuses the presentation's own slot.
- **I16** No step is stuck. Every background thread entered or returned, and every release on a background thread
  returned.
- **I17** A Combine subscriber receives the presentation's publications in publication order. It never receives the
  same value twice, sees strictly increasing revisions within one observation, and follows the I11 order across
  observations. Source: `PresentationPublisher` reference, UI-007.
- **I18** A limited subscriber never receives more values than it requested.
- **I19** A subscriber's first value is the snapshot shown when it attached, or a later publication by the I11
  order (saved publishers included). Source: `presentedSnapshots` reference, UI-007.
- **I20** No value arrives after a subscriber's cancellation returned.
- **I21** A subscriber finishes exactly when the presentation is gone, never while it is alive. Every open
  subscriber finishes once it is gone, and a subscriber that attaches to a saved publisher after the release finishes
  during the attach and receives nothing. Source: `presentedSnapshots` reference.
- **I22** Q, presentation alive: a subscriber with outstanding demand last received the snapshot shown, so no
  change is lost, the first included. Source: `presentedSnapshots` reference, UI-007.
- **I23** Q: every value a subscriber received was shown, whatever its revision.
- **I24** D: the host is destroyed on the main thread, and only once its registration's slot is free. Source:
  driving class reference, `PresentationDisposalTests`.
- **I25** Q, presentation alive: at most one registration of the presentation holds a slot.
- **I26** An asynchronous `observe(snapshotsFrom:)` that returns without throwing, and was not replaced, shows its
  registration's first snapshot or a newer one by then. Source: async `observe` reference.
- **I27** P: an `applyBelow` that returned `false` (with no hook running inside that call) must be justified at the
  call by a shown snapshot at least as new or by a newer pending value in a current generation (or left pending by
  an earlier event of the same callback), or else by the end of that top-level event by an in-progress publication
  whose value already existed at refusal and belongs to the same or an earlier observation. A later observation's
  lower baseline does not invalidate a justified refusal, and a later value or observation cannot excuse an
  unjustified one. Source: `apply` reference.
- **I28** T: a subscriber that attaches to any of the owner's publishers after the owner was released without
  closing (its `weak` reference reads `nil`) receives no ordinary value, only `.finished`. As an exception, an owner
  released without closing first processes every batch it accepted, delivering each (`ObservingState.md`, "An
  owner released without closing first processes every batch it accepted", OBS-005). Until its teardown begins, a
  value no newer than the revision it had accepted at its last reference is therefore allowed. The harness marks
  teardown at the first genuine driver cancellation or owner-released callback destruction it sees. At quiescence it
  waits for every armed capture callback and driver cancellation hook to run and every subscriber to finish before
  disarming those hooks and releasing its own registration tokens, so explicit harness cleanup never impersonates
  owner teardown. The exception applies only when the sequence made the owner accept a change, because an owner with
  nothing to process tears down at once. Source: `ObservingState.md` ("demand first made after the release receives
  only the completion" and "tells a publisher of its release before it cancels any driver"), API-120.
- **I29** T: with the same exception as I28, no ordinary value reaches any subscriber, including one attached
  earlier, after the owner was released ("finishes it at once and discards every ordinary value not yet
  delivered"). This is the stricter reading of the same paragraph. API-120 names the one further exception. An
  ordinary value is delivered only if the owner had not been released when the delivery step claimed its demand,
  so only a release on another thread that races a delivery already decided can be followed by that one value.
  The forced orders of 49a check both sides. A release whose source close comes before the delivery step's last
  source check discards the value, so the subscriber of `releaseInHandOff` receives no ordinary value. A release
  on another thread after that check races a delivery already decided, so the subscriber of `releaseInDelivery`
  receives at most that one value. Both then finish (I30). The sentinel marks teardown, so I28's exception no
  longer applies after either release.
- **I30** T, Q: once the owner is gone, every subscriber of its publishers has finished.
- **I31** Generated owners: when a presentation released on another thread has been released, before any
  main-actor turn, the owner counts no subscriber of it because its gate freed the slot at once. Source: class
  references, OBS-005 ("close the gate … which stops delivery and frees a generated owner's slot").
- **I32** Publisher: at most 32 values reach one subscriber in one main-actor turn. A turn ends when a job enqueued
  at its first value runs, or when a value arrives on another task. Source: `SnapshotPublisher` reference, API-120
  ("one allowance of 32 deliveries per main-actor turn").
- **I33** Confined streams: reads return strictly increasing revisions, and the first read is not older than the
  snapshot current at registration (OBS-001, OBS-002, OBS-003).
- **I34** P: when a step that reported `false` returns, no unread element of a removed (slot-free), let-go
  registration is still alive. Custody of the discarded element is released before the removal's completion, in
  the same turn (`cancelOnMainActor(then:)`). It is checked at the step's end rather than at the report because a
  frame still running may hold an element it polled.
- **I35** P: when a top-level `stopObserving()` or a `follow(_:)` on a cancelled task returns, no registration of
  an observation the call ended is still active, apart from one a registration closure still holds. One a
  callback started inside the call is current and stays. A stop event (`stop`, `stopCustody`) checks I35 immediately
  only when the presentation was still alive and `stopObserving()` actually ran, including when an in-flight async call
  is the presentation's only remaining owner after a drop; `stopRacingRemoval` likewise requires a live receiver and
  exercises `stopObserving()` under H1 against a parked cancellation rather than checking I35 directly. Source: UI-004
  ("stopObserving() releases every registration the presentation holds before it returns"), `PresentingState.md`
  ("follow(_:) in a task that is already cancelled … releases the sequence").
- **I36** P: the presentation applies at most 32 of a registration's elements in one main-actor turn, the first
  among them, whatever an earlier observation applied in that turn. Each registration is counted on its own
  (`ExplorerTurnBudget`). An element counts as applied when the revision check reads it, and a registration's
  count ends when a job enqueued at its first element in the turn runs, or when one of its elements is read on
  another task. An echoing source makes this reachable. Source: UI-004 ("counted for each registration on its
  own"), `PresentingState.md` ("at most 32 elements of one registration in one main-actor turn, the first among
  them, whatever an earlier observation applied in that turn"), the `observe(_:)` reference.
  `ExplorerTests.turnBoundSelfCheck` checks the count against a fake that applies elements directly. Thirty-three
  elements of one registration in one turn trip it, 32 of one registration and then 32 of another in the same turn do
  not, and a turn's end or a read on another task starts a new count.
- **I37** Checked at the report itself. On D, when `true` is reported in any call, including a reentrant
  `resumeObserving()`, the newest registration its host has not ended holds the slot, and the presentation
  already shows that registration's seed or a snapshot at least as new. On P, when `true` is reported, a registration
  of a current observation is active (not let go, not finished, not withheld), and the presentation already shows a
  snapshot of that observation, its seed or a newer one. Publication is serialized (UI-004: "each change is
  published once and in order", and a `false` "with every report after it, waits" for the released registrations'
  cancellations). A `true` published in a later step than the one that first showed its observation's snapshot is
  such a queued report of a past change. So is a change made by a callback of an earlier report in the same step,
  and so is a `true` whose own assignment's `objectWillChange` ran client code before the sink. P therefore checks
  the first report of a step in which no armed callback has run. It fails when no snapshot of the newest live
  observation has been shown yet, and otherwise, when that step first showed its observation's snapshot, when the
  snapshot shown belongs to another observation. A registration whose host's cancellation is parked elsewhere still
  counts as live, because the presentation learns of that cancellation only when it returns. I7 and I14 check the
  settled value. Source: `isObserving` reference ("if the observation's registration is still open"), UI-004,
  `PresentingState.md`.
- **I38** P: an asynchronous observation that another observation, `stopObserving()`, or its follower task's
  cancellation replaced does not run its closure afterward, and returns without throwing, even when its host
  refused it (UI-004, `PresentingState.md`: "Another observation or stopObserving() that replaces a waiting
  observation makes it return at once without registering or throwing"). Not checked during teardown, where the
  harness cancels tasks itself.
- **I39** Combine: no subscriber receives a value once the presentation is deallocated (UI-007, "discarding a value
  its demand has not reached"). A subscriber through `receive(on:)` (53) receives only values covered by demand it
  requested while the presentation was still alive, checked through a weak reference on the subscriber's queue so a
  reentrant drop while a publication still holds the presentation does not count as deallocation. A unit requested
  only after deallocation supplies none (`PresentingState.md`, buffered values and the release).
- **I40** Confined streams: when `cancel()` returns, the element it held unread has been released (OBS-005). The
  fake hosts cancel on the main thread, so no cancellation runs elsewhere then.
- **I41** Confined streams and the free-standing sequence: the element unread when the host finished the
  registration is saved at the finish, before any read, whether or not it is still alive. The next read returns
  exactly that element, and every read after the end returns `nil`. A destroyed final element therefore fails the
  read instead of passing it. A host's cancellation, `cancel()`, or a release clears the expectation. A second
  iterator of a sequence ends at once, without waiting. Source: OBS-005 ("a finish keeps the final unread element
  readable"), OBS-006, `SnapshotSequence` reference ("Only the first iterator receives elements; a later iterator
  ends immediately" and "Every later read returns `nil`").
- **I42** P: `observe(_:)` of a sequence another consumer iterates shows nothing from it and does not end it
  (UI-004, `PresentingState.md`).
- **I43** R, counts: a plain `subscriberCount` equals the live registrations the harness holds. One read with
  `countDuring` returns a count the owner held during the read, matching one of the live counts before the read or
  after each registration or cancellation inside it. The owner refuses a registration exactly when callback and
  pending registrations together fill the capacity. Source: `subscriberCount` reference ("The count is one that held
  while it was read").
- **I44** R, reconcile: every report is compared with an expectation the harness keeps itself, from the outcomes it
  offered and the preparations it saw. A report carries its completion's first delivered payload (by serial) and its
  own retained entry, which no other work's reports name, and requires reconciliation. A duplicate delivery of a
  retained completion (`redeliver`) runs no preparation. Attempt n is reported only after n preparations, with the
  reason preparation n produced, either a refusal or an admission failure of a candidate. A completion's attempts are
  reported in strictly increasing order, and none is skipped unless a later preparation superseded a candidate
  attempt that was never reported. The owner delivers its reports from one queue, oldest decision first. When a
  handler reconciles a completion, every report already decided and not yet delivered at that call (including the
  rest of the handler's own batch) precedes the reconciled completion's next report, so with B1's handler reconciling
  B the order is B1, C1, B2. Once the owner is idle, every refused attempt, and the current attempt of every entry
  that requires reconciliation, has been reported. Each step waits, with a five-second safety net, until no
  preparation or handler is running, draining has finished unless held, unheld queued executions, released
  executions, and post-termination outcome deliveries have completed, no completion is awaiting admission,
  preparation, or a scheduled retry, and every refused attempt and entry that requires reconciliation has been
  reported. Source: SPEC's completion-policy contract (each attempt reported once, in attempt
  order, with synchronous reconciliation from a handler permitted), DELIVERY-005, DELIVERY-008.
- **I45** D: a creation that the host refuses, after delivering a newer snapshot inside `subscribe` or because the
  slot is occupied, shows the snapshot read at creation, is not observing, and records the failure. A creation
  against a closed owner is not observing and records no failure. Nothing the host delivered inside a refused
  registration call is ever shown. A top-level `send` or `close` returns the receipt the host returned, checked
  where no callback made a call of its own meanwhile. On a real owner (70), `send` and `close` return the owner's
  current revision, shown in the same turn. A `commit` is admitted only when its proposal was made at the owner's
  current revision and the owner is open, and it is shown in the same turn. A rejection returns the owner's current
  snapshot, and after `close()` its reason is `closed`. A proposal of another owner is rejected as `foreignOwner`.
  The presentation never shows a revision newer than the owner's. A change the owner admits without it arrives
  through the subscription on a later main-actor turn, so the presentation shows the owner's revision only after the
  quiescent turns, while observing. Source: driving `init` reference, UI-001, `PresentingState.md` ("the creation
  snapshot").
- **I46** D, `resumeObserving()`, at top level, when no armed callback ran inside the call: a refusal throws and
  leaves `snapshot`, `isObserving`, and `observationFailure` unchanged. A call made while observing makes no
  registration call, and one made while not observing makes exactly one. One that returns to an open owner with a
  free slot leaves the presentation observing with no failure, showing at least the revision the registration
  delivered. One against a closed owner returns without throwing and is not observing. A resumed presentation's
  subscribers are checked by I21 and its reports by I6. A resumption inside a host's cancellation is reached through
  `arm(onCancel,resume)`. Source: `resumeObserving()` reference, `PresentingState.md`.
- **I47** Combine, counted per invocation: each subscriber receives exactly one `receive(subscription:)` before any
  value (checked again at quiescence) and at most one `receive(completion:)`. No downstream call begins while another
  of the same subscriber is in progress, unless the subscriber's own `request` or `cancel`, made inside the call in
  progress, caused it. The owner publishers' recorders count subscriptions and completions too.
- **I48** Combine, at the delivery callback: a value that is newly published, never shown, and not yet the
  presentation's `snapshot` is an immediately deliverable change. It arrives after an `objectWillChange` callback
  that came after the subscriber's previous such value, or after its attach. A subscriber attached inside an
  `objectWillChange` callback, or inside any other callback of a publication in progress, counts that publication's
  announcement as one made after it. "Assignment before the enclosing call returns" is I12. A buffered value, one
  already shown when it arrives, has its own timing and is not checked.
- **I49** R, copies: no registration of a raw owner learns of its release (`onFinish`) while the harness keeps any
  copy of the owner. Once the last copy is released, here or on a background thread, every live registration
  finishes, waited for with a safety net. Source: `RuntimeSharedHost` ("every copy of the host shares" the
  lifetime, "its destructor is the owner's release"), the `subscribe(_:onFinish:)` reference.
- **I50** Ingress: deliveries never overlap, so none begins inside another. They carry strictly increasing
  revisions, each one a value that was staged when it was offered (newer than every offer before it, with the first
  offer staged whatever its revision, zero included), and none begins after `cancel()` has returned. A delivery task
  applies at most 32 values in one main-actor job, and the delivery jobs number at most the activations (an offer
  that staged a value while nothing staged was undelivered and no delivery was running) plus the continuations of
  jobs that used their whole allowance. Once the ingress is idle, unless cancelled, the newest staged value has been
  delivered. Source: `MainActorSnapshotIngress` ("Stages only a newer revision and schedules at most one
  responsible delivery task" and "Exactly one responsible delivery task exists per active cohort").
- **I51** Every class, every step: a presentation publishes a property only when its value changes (UI-004), so
  each property-precise observer sees an exact trace (`ExplorerPropertyTrace`). An Observation tracker reads the
  value about to be replaced, and the `$isObserving` sink reads the value about to be set. The first invalidation of
  a step continues the value at the step's start, each differs from the one before it, and the last leads to the
  value at the step's end. A step without an invalidation leaves the value unchanged. `isObserving` is traced for
  every class and `snapshot`'s identity for the Observation classes (`objectWillChange` announces any property, so it
  traces none). An extra invalidation, a missing one, and an invalidation of a property whose value did not change
  all fail.
- **I52** Distinct projections: within one sequence, each element is the projection of a state the owner held
  after the state the previous element stands for, in order, anchored at the earliest such state, so two equal
  consecutive elements need a different projection between them, and an element seen only earlier in the history
  fails. The harness builds each sequence's history in accepted revision order from actual synchronous commit and
  close receipts before polling `snapshot()`, collapsing consecutive revisions with the same projection and never
  seeding history from sequence elements, so a transient committed phase followed by an asynchronous transition is
  retained while duplicate, stale, and out-of-order emissions still fail. Equality is registration-local, so a later
  sequence's first element may equal another's last. A sequence the harness did not cancel ends only when the owner
  has closed, and only after the closed phase, unless that equals its last element. Once the owner has closed, every
  such sequence ends. For E14 (78), a proposal kept from before the owner's reset is never committed.
- **I53** R, reconcile: `flush(through:)` of the receipt of the held drainer's batch does not return while that
  batch's emission handler is held, and returns `true` once the drainer is released and the batch processed. Source:
  `RuntimeSharedHost.flush(through:)` ("Waits until … emissions, through this receipt have been processed").
- **I54** D, Q: once a registration's cancellation has settled (its slot free), every value delivered to it that
  the presentation never showed has been released, checked after the quiescent turns while the presentation is
  still alive and held, so the final teardown cannot release the evidence first. Stopping discards an unannounced
  value, so keeping one is custody without a purpose, and one that captures the presentation would keep both alive.
  In `chains`, such a value does capture it, and I15 then finds the presentation alive. Source: `stopObserving()`
  reference, `PresentingState.md` ("Separate observation from running work"), class reference (disposal).
- **I55** R, images: while a reconciliation handler holds the owner's report queue, the payloads of completed works
  (admitted and no longer retained) that are still alive number at most two per pending-completion registration.
  Each registration keeps at most one collection it has not read, a newer one replacing it, and may be handed one
  more, and with works completed one at a time each collection shows at most one of them. With no registration, or
  once the handler returns, none stays alive. The step waits up to 200 turns for releases on the owner's workers
  before it judges. Source: SPEC's `pendingCompletionUpdates()` contract ("with a newer collection replacing one
  not yet read"), DELIVERY-011.

## Enumeration and pruning

- **Order.** Breadth-first by length, enumerating every enabled event after every prefix that found no violation, up
  to the configured depth. Each sequence runs from a fresh world, fresh hosts, and a fresh presentation, including
  the quiescence step. The empty script, creation and quiescence alone, runs first and is reported like any other.
  The first sequence recorded for an invariant is a shortest one. A sequence that violates an invariant is not
  extended.
- **Validity filter** (sound, because a disabled event is impossible or a no-op in that state). Presentation events
  need the harness to hold the presentation, and `stop` needs a current attempt; `stopCustody` and
  `stopRacingRemoval` require the presentation to still be alive and a current attempt (covering a receiver retained
  only by an in-flight async call after a drop). Host events need a registration
  holding that host's slot, active and not parked, while `hostCancelReturn` needs a parked one. `factoryReturn` and
  `factoryThrow` need a parked closure, `cancelFollower` needs an uncancelled follower, `request` and
  `cancelSubscription` need an open subscriber, and saved subscriptions need a saved publisher. Sequences allow at
  most two `turn`s in a row and at most one `arm`.
- **Symmetry** (sound, because A and B are identical fakes in identical initial states). Host B becomes available
  only after an event names it. The first event that can name B is offered once, so a sequence's first-named host is
  always A.
- **State hashing** (`EXPLORER_HASH=1`, off by default, not sound). A sequence is not extended when another
  sequence of no greater length reached the same abstract state in the harness model (held, current attempt, parked
  closures, calls, registrations' phase/host-ended/parked/let-go, shown value let go, `isObserving`, report
  parity, armed hook, subscribers, saved publisher, consecutive turns). The presentation's private state is not
  in it, so it can merge states that differ.
- **Sleep set over adjacent independent events** (sound). Only one order of an adjacent pair is run:
  `hostCancel(X)` with `hostCancel(Y)` or `deliver(Y)`, for shared hosts X ≠ Y. `hostCancel(X)` parks a background
  thread inside host X's token. It runs no main-actor code and no hook, creates no value, and touches only X's
  token and bookkeeping. `deliver(Y)` offers to Y's mailbox, at most enqueuing a resumption and releasing the
  value it displaces, and touches only Y. Either order leaves the same production state, harness state,
  revision numbering, and enabled set. Implemented as `ExplorerEvent.commutes(with:)`, the run keeps the order
  whose descriptions ascend. The reduction is off after any `arm` or `onReport` in the prefix because an armed
  callback, such as the destructor of the value a delivery displaces, can act on the other host, so the two events
  share an effect while one may still be pending.
- **Idle arms** (sound). `arm(h, e)` and `onReport(k, e)` change only harness state. If an armed hook does not run
  during the event that follows it, that event is not itself an arm, and (in passive slices) the presentation is
  still held, the sequence equals the one that arms after that event, which is enumerated too. The arm-first sequence
  is then neither extended nor reported. Two adjacent arms are both kept—both in passive `chains` and for the
  `reconcile` family's independent `onReport` and `arm(emission, …)` hooks, whose two registration orders also differ
  under work-naming symmetry—because pruning adjacent arms drops simultaneous arming altogether. Replays never prune.
- No other partial-order reduction is used. Dependent events (anything that runs presentation code, enqueues ordered
  main-actor jobs, or creates values whose revisions follow creation order) run in both orders.

## Tiers and run sizes

1. **Smoke** (in the normal suite): every fully forced slice at its smoke depth, about 78 configurations and
   56,000 sequences, about 20 seconds, beside the self-checks.
2. **Standard** (`EXPLORER_TIER=standard`): every slice of the exhaustive tier, including those that run only in
   the deeper tiers, one step shallower and never below its smoke depth. Runs about 1.8 million sequences over 90
   configurations in about 18 minutes. The raw owner's `reconcile` family (a stage and two events, about 128,000
   sequences) takes about 3 minutes, each driving class's `chains` slice with `resume` (about 191,000 sequences)
   takes under 1 minute, and each real-owner driving class takes about 1 minute.
3. **Exhaustive** (`EXPLORER_FULL=1`): every slice at its full depth. Runs about 15 million sequences over 84
   configurations in about 2 hours. The largest are the multi-owner slice (about 2.6 million sequences and 20
   minutes per class at depth 5), the owner-forms slice (about 1.4 million and 14 minutes per class at depth 5),
   the distinct slice (about 7 minutes), and the driving `resume` slice (about 830,000 per class, about 3.5
   minutes). The raw owner's `reconcile` family runs a stage and three events there (`EXPLORER_RUNTIME_DEPTH`
   overrides it).

## Interruption matrix coverage

The `matrix` family (`ExplorerMatrix.swift`) arms every interrupting event at every armable callback site. The
events are stop, close, release on and off the main actor, `resumeObserving()`, observing the same host again,
and replacing it with another source. Each class runs under every phase and every passive form.

A cell's coordinates are read from the registrations when the armed callback starts (`ExplorerMatrixCell`) rather
than from the top-level event. The callback concerns the registration being cancelled at a cancellation site, and
otherwise the newest one still holding a slot. Its form is the one that registration's attempt observed, so a
replacement's cancellation of the old form keeps the old label. Its phase is `ending` while a registration of an
ended observation still holds its slot or is being cancelled, `registering` during a registering call or while the
newest registration is live but not yet reported (as in a deferred registering callback during `turn`), and `steady`
otherwise. A cell is recorded only when the interrupt changed what the presentation or its registrations hold, so
an ineffective `resume` or release counts nowhere. Creation is outside the matrix because no client code can reach a
presentation before its initializer returns, and a passive initializer calls no host.

Each run records the cells its armed callbacks reached (`EXPLORER_COVERAGE=PATH`, one
`class|form|site|interrupt|phase|attempt|registration|origin` cell per line, where `attempt` says whether the
registration's attempt is the current one, `registration` is its state, and `origin` is the top-level event).
`Scripts/explorer-coverage.py` aggregates them by class, site, and phase into the tables below, with the attempts,
registration states, and origins each phase was reached in. Its `--cells PATH` option also writes every distinct
reached cell with all eight coordinates. Regenerate them from the package root with:

```sh
mkdir -p /tmp/state-machine-coverage
for kind in SnapshotObservableObject SnapshotPresentation StateMachineObservableObject StateMachinePresentation; do
    EXPLORER_SMOKE=0 EXPLORER_FULL=1 EXPLORER_SLICES=matrix:4 EXPLORER_KIND=$kind \
        EXPLORER_COVERAGE=/tmp/state-machine-coverage/$kind.txt \
        swift test --build-system native --scratch-path /tmp/state-machine-explorer --filter ExplorerTests/full
done
python3 Scripts/explorer-coverage.py /tmp/state-machine-coverage/*.txt
```

The script also lists any applicable cell a run did not reach. The tables come from the `matrix` family to depth 4
for each class, covering about 262,000, 158,000, 146,000, and 74,000 sequences for the four classes in the order
below. Each cell counts the five interrupting events of each form reached at that site and phase, over the applicable
ones. "n/a" means none applies, with the reasons below. "Outside the applicable set" means vacuous completion cells,
where the presentation is already gone, and cells reached before any observation (form "none").

#### SnapshotObservableObject

330 of 330 applicable cells reached; 345 not applicable; 30 reached cells outside the applicable set.

| site | registering | steady | ending |
|---|---|---|---|
| change | 25/25 | 25/25 | 25/25 |
| report | 25/25 | 15/15 | 25/25 |
| hostSubscribe | 20/20 | n/a | n/a |
| hostRead | 5/5 | n/a | n/a |
| onCancel | n/a | n/a | 25/25 |
| destroy | 25/25 | 25/25 | 15/15 |
| subscriptionBefore | n/a | 25/25 | n/a |
| value | 25/25 | 25/25 | n/a |
| completion | n/a | n/a | n/a |

| phase | attempts | registration states | origins |
|---|---|---|---|
| registering | current, earlier | active, freed, freed+hostEnded | observe, observeAsyncNow, observeSeq |
| steady | current | active, freed, freed+hostEnded | apply, deliver, subscribe, turn |
| ending | current, earlier | active, active+hostEnded, cancelling, cancelling+hostEnded, freed, freed+hostEnded | finish, hostCancelMain, observe, observeAsyncNow, observeSeq, stop, turn |

#### SnapshotPresentation

230 of 230 applicable cells reached; 220 not applicable; 18 reached cells outside the applicable set.

| site | registering | steady | ending |
|---|---|---|---|
| change | 25/25 | 25/25 | n/a |
| report | 25/25 | 15/15 | 25/25 |
| hostSubscribe | 20/20 | n/a | n/a |
| hostRead | 5/5 | n/a | n/a |
| onCancel | n/a | n/a | 25/25 |
| destroy | 25/25 | 25/25 | 15/15 |

| phase | attempts | registration states | origins |
|---|---|---|---|
| registering | current, earlier | active, freed, freed+hostEnded | observe, observeAsyncNow, observeSeq |
| steady | current | active, freed, freed+hostEnded | apply, deliver, turn |
| ending | current, earlier | active, active+hostEnded, cancelling, cancelling+hostEnded, freed, freed+hostEnded | finish, hostCancelMain, observe, observeAsyncNow, observeSeq, stop, turn |

#### StateMachineObservableObject

68 of 80 applicable cells reached; 85 not applicable; no reached cells outside the applicable set.

| site | registering | steady | ending |
|---|---|---|---|
| change | 4/5 | 5/5 | 5/5 |
| report | 4/5 | n/a | 4/5 |
| hostSubscribe | 4/5 | n/a | n/a |
| hostRead | n/a | n/a | n/a |
| hostSend | n/a | 5/5 | n/a |
| hostClose | n/a | n/a | 2/5 |
| onCancel | n/a | n/a | 4/5 |
| destroy | 4/5 | 5/5 | 4/5 |
| subscriptionBefore | n/a | 5/5 | n/a |
| value | 4/5 | 5/5 | 4/5 |
| completion | n/a | n/a | n/a |

| phase | attempts | registration states | origins |
|---|---|---|---|
| registering | current | active, active+hostEnded, freed+hostEnded | resume |
| steady | current | active, freed, freed+hostEnded | apply, deliver, subscribe |
| ending | current | active, active+hostEnded, freed, freed+hostEnded | close, finish, hostCancelMain, resume, stop |

Applicable cells not reached (12):

- change, registering: driving: resume
- destroy, ending: driving: resume
- destroy, registering: driving: resume
- hostClose, ending: driving: close, driving: resume, driving: stop
- hostSubscribe, registering: driving: resume
- onCancel, ending: driving: resume
- report, ending: driving: stop
- report, registering: driving: resume
- value, ending: driving: resume
- value, registering: driving: resume

#### StateMachinePresentation

49 of 60 applicable cells reached; 60 not applicable; no reached cells outside the applicable set.

| site | registering | steady | ending |
|---|---|---|---|
| change | 4/5 | 5/5 | 4/5 |
| report | 4/5 | n/a | 4/5 |
| hostSubscribe | 4/5 | n/a | n/a |
| hostRead | n/a | n/a | n/a |
| hostSend | n/a | 5/5 | n/a |
| hostClose | n/a | n/a | 2/5 |
| onCancel | n/a | n/a | 4/5 |
| destroy | 4/5 | 5/5 | 4/5 |

| phase | attempts | registration states | origins |
|---|---|---|---|
| registering | current | active, active+hostEnded, freed+hostEnded | resume |
| steady | current | active, freed, freed+hostEnded | apply, deliver |
| ending | current | active, active+hostEnded, freed, freed+hostEnded | close, finish, hostCancelMain, resume, stop |

Applicable cells not reached (11):

- change, ending: driving: resume
- change, registering: driving: resume
- destroy, ending: driving: resume
- destroy, registering: driving: resume
- hostClose, ending: driving: close, driving: resume, driving: stop
- hostSubscribe, registering: driving: resume
- onCancel, ending: driving: resume
- report, ending: driving: stop
- report, registering: driving: resume

#### Not applicable, by reason

| Class | Cells | Reason |
|---|---|---|
| SnapshotObservableObject | 10 | A callback host ends a registration synchronously inside the ending event, so no report is left for a later steady-state turn (a shared host's cancellation can return on one). |
| SnapshotObservableObject | 70 | A passive presentation reads a host's snapshot only after registering with a shared host. |
| SnapshotObservableObject | 50 | A registration call runs only while registering. |
| SnapshotObservableObject | 75 | A subscriber's completion runs only after the presentation is deallocated, so an armed event there acts on nothing (reached cells are counted apart as vacuous). |
| SnapshotObservableObject | 50 | A subscription is handed out only by an attach, a steady-state event (an attach armed inside a registration's callback needs two arms: `chains`). |
| SnapshotObservableObject | 50 | A token's cancellation runs only for a registration that is ending, so its callback concerns an ending observation whatever top-level event runs it. |
| SnapshotObservableObject | 25 | An ending publishes no new snapshot in a passive presentation. |
| SnapshotObservableObject | 10 | An ending with a callback host destroys no client value inside the call: the shown snapshot stays, and the registration's callbacks go on a later turn. |
| SnapshotObservableObject | 5 | The client registers the sequence before handing it over; no presentation call is in progress. |
| SnapshotPresentation | 10 | A callback host ends a registration synchronously inside the ending event, so no report is left for a later steady-state turn (a shared host's cancellation can return on one). |
| SnapshotPresentation | 70 | A passive presentation reads a host's snapshot only after registering with a shared host. |
| SnapshotPresentation | 50 | A registration call runs only while registering. |
| SnapshotPresentation | 50 | A token's cancellation runs only for a registration that is ending, so its callback concerns an ending observation whatever top-level event runs it. |
| SnapshotPresentation | 10 | An ending with a callback host destroys no client value inside the call: the shown snapshot stays, and the registration's callbacks go on a later turn. |
| SnapshotPresentation | 25 | The Observation class tracks `snapshot`, which an ending does not change; its `isObserving` is the report site. |
| SnapshotPresentation | 5 | The client registers the sequence before handing it over; no presentation call is in progress. |
| StateMachineObservableObject | 10 | `close` is an ending. |
| StateMachineObservableObject | 10 | `send` is a steady-state event. |
| StateMachineObservableObject | 5 | A callback host ends a registration synchronously inside the ending event, so no report is left for a later steady-state turn (a shared host's cancellation can return on one). |
| StateMachineObservableObject | 15 | A driving presentation reads its host only at creation and in `commit`; the fake has no proposals (the real-owner slice covers commit). |
| StateMachineObservableObject | 10 | A registration call runs only while registering. |
| StateMachineObservableObject | 15 | A subscriber's completion runs only after the presentation is deallocated, so an armed event there acts on nothing (reached cells are counted apart as vacuous). |
| StateMachineObservableObject | 10 | A subscription is handed out only by an attach, a steady-state event (an attach armed inside a registration's callback needs two arms: `chains`). |
| StateMachineObservableObject | 10 | A token's cancellation runs only for a registration that is ending, so its callback concerns an ending observation whatever top-level event runs it. |
| StateMachinePresentation | 10 | `close` is an ending. |
| StateMachinePresentation | 10 | `send` is a steady-state event. |
| StateMachinePresentation | 5 | A callback host ends a registration synchronously inside the ending event, so no report is left for a later steady-state turn (a shared host's cancellation can return on one). |
| StateMachinePresentation | 15 | A driving presentation reads its host only at creation and in `commit`; the fake has no proposals (the real-owner slice covers commit). |
| StateMachinePresentation | 10 | A registration call runs only while registering. |
| StateMachinePresentation | 10 | A token's cancellation runs only for a registration that is ending, so its callback concerns an ending observation whatever top-level event runs it. |

The applicable cells the driving classes do not reach are interrupts that change nothing there, which the
recorder does not count. `resumeObserving()` registers nothing while a registration is live or being made, or from a
callback of an ending whose owner is closed. `stop`, `close`, and `resume` armed at `hostClose`, after `close()`
finished the registration, act on an ended observation. `stop` inside the `false` report of an ending stops nothing.

## Self-check

`ExplorerTests/selfCheck` runs in the normal suite. Each invariant below decides through one function or
component (`ExplorerSelfCheck.swift`, `ExplorerPropertyTrace`, `ExplorerReportsLog`, `ExplorerTurnBudget`,
`ExplorerWorld`) that the slices call, and the self-check plants a defect that function must report beside a
control it must accept. It prints `EXPLORER self-check: N planted defects, N trusted` and records an issue for each
check that is not trusted.

| Invariant | Planted defect |
|---|---|
| I1 | A client value released on a worker thread. |
| I2 | An unread element of a let-go registration released before its slot is free. |
| I3 | The snapshot still displayed at release destroyed before its slot is free (the control releases a same-revision displaced snapshot early and frees the slot before destroying the current one). |
| I5 | `false` reported while a let-go registration holds its slot. |
| I10 | An unannounced seed of a stopped registration shown after the stop (the control is a receipt). |
| I11 | A value of an older observation published after one of a newer observation, and a lower revision within one observation. |
| I17 | A subscriber given the same value twice. |
| I18 | A limited subscriber given more values than it requested. |
| I19 | A subscriber's first value older than the snapshot shown when it attached. |
| I20 | A value after the subscriber's cancellation returned. |
| I21 | A subscriber attached after the release given a value. |
| I23 | A subscriber given a value the presentation never showed, older than the snapshot shown. |
| I36 | 33 elements of one registration in one main-actor turn (also `turnBoundSelfCheck`). |
| I37 | `true` reported while the snapshot shown is older than the live registration's seed. |
| I39 | A subscriber given a value after the presentation was deallocated, and a queued value covered only by demand returned after deallocation. |
| I44 | A later attempt reported before an earlier one, a refused attempt skipped, a later payload under the same ticket, a refusal reported as an admission failure, a handler's reconciliation reported before a report decided earlier, and two works' reports naming one retained entry. |
| I47 | A subscriber given two subscriptions. |
| I48 | A newly published value delivered before `objectWillChange` announced it. |
| I50 | A delivered value that was never staged. |
| I51 | An invalidation without a change, and a change without an invalidation. |
| I52 | A sequence that ends without the closed phase, and reads `A, B, A` against the history `A, B`. |
| I53 | `flush(through:)` returning while its batch's handler is held, and failing to return once it is processed. |
| I54 | An unshown value of a stopped registration kept after its cancellation settled. |
| I55 | Every completed payload kept behind a held handler for one pending registration. |

Untested invariants with no planted defect of their own are I4, I6–I9, I12–I16, I22, I24–I35, I38, I40–I43, I45,
I46, and I49. Each of these has been shown to find a defect only by the planted or historical defect it entered the
explorer with.

## Not covered

1. **E10** in part: demand and cancellation off the main actor reach the driving Combine class (53), while the
   passive Combine class and the owners' `SnapshotPublisher`s get demand only from the main actor.
2. **E9** for owner publishers in part: the publisher slice (52) attaches zero, finite, and returning demand and
   cancels one subscription, while the `ActorHost` and `Shared` teardown recorders request unlimited demand.
3. **E5** in part: an arbitrary choice among three parked actor-host calls, and a typed factory error other than
   `capacityExceeded`.
4. **E12** in part: pending projections, and real non-`Sendable` confined values, because every explorer snapshot is
   `Sendable` and a non-`Sendable` type needs its own fake hosts.
5. **E14** in part: fork, `init(restoring:)` of an owner whose old presentation keeps a proposal, conditional reset
   with `expecting:`, and a pending ID used on another owner.
6. **E15** in part: the owner-teardown slices arm no callbacks, the real-owner driving slice arms one per sequence,
   and arbitrary intervening background-thread turns are not built.
7. **Callback sites**: launch decisions (internal to the runtime, with no client callback), a pending-completion
   reader's callback (the `images` registrations keep nothing and arm nothing), a custom host's `commit`, receipt
   properties other than the snapshot's `revision`, `Hashable` witnesses (nothing hashes a client value on these
   paths), and the producer's yield and finish of a sequence apart from the host's own calls are not armed. Emission
   handlers (79), an `Equatable` witness (80), a buffered delivery's decision (H10), the driving snapshot's
   `revision` witness (29), physical termination (`releaseDrivers`), selected worker returns (57), and per-property
   invalidation (I51) are covered.
8. **Owner forms**: a truly non-main confined stream, and the passive presentations' Combine subscribers over real
   owners. The passive presentations over real `Shared`, `ActorHost`, `ActorHost(isolatedTo:)`, and a non-main
   `IsolatedHost`, with teardown on its actor (74), are covered.
9. **Reports** in part: I44 compares each report's attempt, payload, entry, and reason category rather than the whole
   rejection, and does not record every decision between different works in order. The debt a nested reconciliation
   owes is sampled from `pendingCompletions()`.
10. **Exact results** in part: the real-owner slices compare an owner and its presentation by revision and closure
    rather than by model, and the real-owner driving slice reduces a `send` result to its revision.
11. **Interruption matrix** attribution: a cell takes the newest ending or holding registration and the top-level
    event, so overlapping attempts are not told apart.
12. **Further compositions**: one owner with mixed presentation classes and registration kinds, reconciliation
    under each real managed owner and policy, two ingress producers racing, a choice among several saved receipts
    for `flush(through:)`, fork and restoration (E14), and a shutdown deadline raced with cancellation.
13. **Bounded storage** beyond I55's retained payloads: copies of a backlogged report queue, a parked registration's
    bookkeeping while later attempts finish, cancelled controlled-driver waits, and a work counter's width are
    measured by the work tests or by none.
