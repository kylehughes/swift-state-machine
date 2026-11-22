# Construct a runtime behind a facade

Keep the reusable admission engine separate from a domain's sealed API.

The `Runtime*` types in this article support generated code and carry no
source-stability promise. A graph declared with the macros uses its generated
owners and never names them. Read this article to understand what a generated
owner relies on rather than as a public construction API.

``RuntimeState`` holds a complete value record containing model data, retained
identities, active operation authority, execution reservations, and committed
batches. Its methods perform synchronous engine work without invoking reducer or
driver closures. Payload destruction can execute user code outside the shared
lock.

A local host owns this value exclusively. A shared host reads an immutable
version, computes a proposed engine value outside the lock, and installs the
whole value through ``AtomicRecordStorage``. If the storage version changed,
the host must validate again. Repeating engine preflight does not authorize
repeating an application reducer.

A manual owner creates the engine with `.commands` recording, which queues a
batch only for an acceptance that cancels or starts work and for closure. Its
caller receives every other receipt from the commit. A managed host uses
`.everyAcceptance`, because it publishes each accepted snapshot from its queue.

``RuntimeState/propose(on:next:requiring:plan:)`` returns either a candidate or
a ``RuntimeState/DefectivePlan`` that keeps the snapshot the plan was prepared
on. ``RuntimeState/reject(_:)`` reports that defect after the checks that
precede it, so a snapshot from another owner reports
``CommitRejection/foreignOwner`` and a closed owner reports
``CommitRejection/closed``. The rejection type and the values it carries are
ordinary `StateMachine` types that generated facades name directly.

``RuntimeSharedHost`` provides this shared orchestration. Its copies refer to
one owner. It requires `Sendable` model data, effect descriptions, and outcomes.
Its immutable preparation and driver closures run outside the storage lock.
Generated facades project their sealed domain types through this common host.

``RuntimeMainActorHost``, ``RuntimeActorHost``, and ``RuntimeIsolatedHost`` own
the value engine and delivery ledger directly on their actor. Their synchronous
input handling can read, prepare, and admit in one isolated turn. They release
stored-property access before invoking domain functions or observation
callbacks, and recheck the captured revision if synchronous reentry changed it.
For each accepted batch, they process start commands and advance the revision
tracked by `flush(through:)` before invoking that batch's observer callbacks. A
synchronous `MainActor` callback can delay a scheduled driver on the same actor.
Releasing a host without closing it finishes its retained registrations without
a closed snapshot. The `MainActor` host can retain non-`Sendable` value data
within that actor, and the isolated host can do the same within the actor
instance it is created with, which it holds weakly. The native actor host
requires `Sendable` data at its crossing boundaries.

## Define the trust boundary

The raw runtime validates identities, freshness, and operation policy. It also
checks that the revision counter has room for another commit and that the
proposed change fits the configured capacity limits. It trusts the supplied
model, scope eligibility, operation metadata, and value semantics. A generated
facade adds the domain's legal edge surface and privately binds observations,
prepared proposals, and typed completions to this runtime.

Keep raw snapshots, candidates, tickets, and the runtime instance out of the
facade's public properties. Public access to these lower-level types allows
building a separate raw runtime, but it does not make them interchangeable with
facade proofs.

Copying a `RuntimeState` preserves its identity lineage. This supports
speculative engine calculations followed by one atomic installation. It is not
a fork operation. Construct a new runtime from validated model data when an
independent owner is required.

## Bind operations to scope activations

``RuntimeScopeID`` combines a primitive kind with an optional retained instance
identity, and ``RuntimeKey`` carries a keyed operation's resolved key. Resolve
domain keys before constructing runtime plans. Removing and reactivating a scope
creates a new activation, even when its visible domain key is unchanged. A
ticket from the earlier activation cannot authorize the new instance.

An operation binds its primary scope and every declared dependency. Unrelated
root edits preserve that authority, while a completion proposal still needs a
fresh whole-root observation. Declare semantic dependencies explicitly, because
the runtime cannot infer them from arbitrary model fields.

| Policy | Active authority in one scope activation, operation kind, and key |
| --- | --- |
| `latest` | Revoke older members when the replacement is accepted. |
| `rejectWhenActive` | Reject if a member would remain active after this transition's retirements and scope invalidations. |
| `parallel` | Admit only within the declared active-authority limit. |

Policy changes, model replacement, authority changes, and the command batch
take effect together. A rejected replacement cannot cancel the older operation.

## Account for execution separately

Revoked authority prevents a late state change. It does not prove that an
external task has ended. Execution reservations cover queued or running work,
retained delivery obligations, and preparation claims until their separate
lifetimes finish.

The host owns physical task registration, cancellation, outcome retention, and
termination acknowledgments. Drain complete batches in FIFO order, and execute
their commands after releasing mutable or locked access. A close record has
reserved queue and revision capacity, but processing that record alone does not
prove shutdown has joined every task.

Confined hosts store `Task<Void, Never>` worker handles. A separate watcher
awaits each worker before acknowledging actual termination. Returning a driver
outcome to the host can settle delivery before that worker has returned.
Cancellation alone settles neither lifetime. Task closures capture immutable
work and drivers without retaining the owner across the entire driver await.

## Retain a terminal result until settlement

``RuntimeDeliveryLedger`` stores the first terminal outcome for an operation.
Another delivery cannot replace it. A preparation claim captures one root
observation and excludes other preparations for the same retained outcome.
Install ledger changes together with their engine changes.

A terminal candidate must both require and retire its operation's ticket.
Preparing an input transition or another operation's transition for a completion
cannot settle the pending result. That invalid plan leaves the first outcome
available for explicit reconciliation. A candidate's rejected authority also
does not discard an outcome whose own operation remains active.

A raw host takes a ``RuntimeCompletionPolicy`` and a separate reconciliation
callback. Its default, ``RuntimeCompletionPolicy/manual``, retains a failed
attempt with its typed reason and passes the retained completion to the
callback. ``RuntimeCompletionPolicy/retry`` permits automatic preparation after
root conflicts, with at most four preparations per result in a scheduling turn
before yielding, and at most sixteen turns that end in a conflict before the
result parks for explicit reconciliation. Choose it only for deterministic,
side-effect-free preparation. Every automatic retry, immediate or scheduled,
acts on the decision of the attempt that lost the conflict. An explicit attempt
that finishes first makes a newer decision, and the retry neither prepares
again nor replaces a candidate that waits for capacity. A capacity retry reuses
the sealed candidate and does not rerun preparation. A generated owner combines
the two raw parameters into one `CompletionPolicy` value that carries its
optional handler. It defaults to `.retry` unless one of the schema's
completions can refuse its outcome, as
[Settle completions that do not commit](<doc:HostingAGraph#Settle-completions-that-do-not-commit>)
describes.

Managed defaults allow 256 queued batches, 64 effect descriptions per plan, 256
execution reservations, and 128 subscriptions. Use
``ManagedConfiguration`` to validate explicit bounds. Shared callback
subscriptions and all managed snapshot sequences keep one pending latest value
per subscriber. Callback subscriptions on ``RuntimeActorHost`` and
``RuntimeMainActorHost`` receive each eligible batch directly. A live
registration receives the terminal snapshot when closure ends observation. A
sequence registers one subscriber. Coalescing snapshots preserves all accepted
effect commands.
