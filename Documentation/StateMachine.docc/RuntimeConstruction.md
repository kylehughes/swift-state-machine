# Construct a runtime behind a facade

Keep the reusable admission engine separate from a domain's sealed API.

``RuntimeState`` holds a complete value record: model data, retained identities,
active operation authority, execution reservations, and committed batches. Its
methods perform synchronous engine work without invoking reducer or driver
closures. Payload destruction can execute user code outside the shared lock.

A local host owns this value exclusively. A shared host reads an immutable
version, computes a proposed engine value outside the lock, and installs the
whole value through ``AtomicRecordStorage``. If the storage version changed,
the host must validate again. Repeating engine preflight does not authorize
repeating an application reducer.

``RuntimeSharedHost`` provides this shared orchestration. Its copies refer to
one owner. It requires `Sendable` model data, effect descriptions, and outcomes;
its immutable preparation and driver closures run outside the storage lock.
Generated facades and the handwritten profile example project their sealed
domain types through this common host.

``RuntimeMainActorHost`` and ``RuntimeActorHost`` own the value engine and
delivery ledger directly on their actor. Their synchronous input handling can
read, prepare, and admit in one isolated turn. They release stored-property
access before invoking domain functions or observation callbacks, and recheck
the captured revision if synchronous reentry changed it. The `MainActor` host
can retain non-`Sendable` value data within that actor; the native actor host
requires `Sendable` data at its crossing boundaries.

## Define the trust boundary

The raw runtime validates identities, freshness, and operation policy. It also
checks that the revision counter has room for another commit and that the proposed
change fits the configured capacity limits. It trusts the supplied model, scope eligibility,
operation metadata, and value semantics. A generated facade adds the domain's
legal edge surface and privately binds observations, prepared proposals, and
typed completions to this runtime.

Keep raw snapshots, candidates, tickets, and the runtime instance out of the
facade's public properties. Public access to these lower-level types allows a
separate raw runtime; it does not make them interchangeable with facade proofs.

Copying a `RuntimeState` preserves its identity lineage. This supports
speculative engine calculations followed by one atomic installation. It is not
a fork operation. Construct a new runtime from validated model data when an
independent owner is required.

## Bind operations to scope activations

``RuntimeScopeID`` combines a primitive kind with an optional retained instance
identity. Resolve domain keys before constructing runtime plans. Removing and
reactivating a scope creates a new activation, even when its visible domain key
is unchanged. A ticket from the earlier activation cannot authorize the new
instance.

An operation binds its primary scope and every declared dependency. Unrelated
root edits preserve that authority, while a completion proposal still needs a
fresh whole-root observation. Declare semantic dependencies explicitly; the
runtime cannot infer them from arbitrary model fields.

| Policy | Active authority in one scope activation and operation kind |
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
outcome to the host can settle delivery before that worker has returned;
cancellation alone settles neither lifetime. Task closures capture immutable
work and drivers without retaining the owner across the entire driver await.

## Retain a terminal result until settlement

``RuntimeDeliveryLedger`` stores the first terminal outcome for an operation.
Another delivery cannot replace it. A preparation claim captures one root
observation and excludes other preparations for the same retained outcome.
Install ledger changes together with their engine changes.

A terminal candidate must both require and retire its operation's ticket.
Returning an input transition or another operation's transition from a router
cannot settle the pending result. That invalid plan leaves the first outcome
available for explicit reconciliation. A candidate's rejected authority also
does not discard an outcome whose own operation remains active.

The default `manualOnConflict` policy retains a failed attempt with its typed
reason. `retryPure` permits automatic preparation after root conflicts, with
at most four preparations per result in a scheduling turn before yielding.
Choose it only for deterministic, side-effect-free preparation. A capacity
retry reuses the sealed candidate and does not rerun preparation.

Managed defaults allow 256 queued batches, 64 effect descriptions per plan,
256 execution reservations, and 128 subscriptions. Use
``RuntimeManagedConfiguration`` to validate explicit bounds. Observations use
one pending latest value per subscriber plus reserved terminal delivery;
coalescing observations never discards accepted effect commands.
