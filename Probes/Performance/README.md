# State Machine performance fixtures

Run the generated facade through normal public imports, with separate processes for shipping latency, allocation/resource memory, instrumented lock bodies, and private resource counts. These fixtures establish a baseline on the recorded hardware. They set no speed threshold.

The default full run measures the workload matrix below:

```sh
python3 Scripts/check-performance.py \
  --output /absolute/external/fresh-performance-evidence \
  --build-root "$PWD/.build/arm64-apple-macosx/release"
```

Run this after the candidate is frozen. The harness observes a native Release build of `StateMachine`, selects its shipping runtime dependency closure from the native plan, and freezes those exact modules, objects and macro executable into the external output. It never adds a benchmark target or unsafe flags to the shipping manifest. Omitting `--build-root` uses a new independent SwiftPM scratch directory inside the evidence output; that can require a cold SwiftSyntax build. Existing-build and consumer compile costs are separate command receipts, not latency samples.

For fixture development, the small control runs 100 operations with one warmup and one measured repetition:

```sh
python3 Scripts/check-performance.py --mode control \
  --reuse-build-root "$PWD/.build/arm64-apple-macosx/release" \
  --output /absolute/external/fresh-performance-control
```

`--reuse-build-root` is explicitly preliminary and accepted only in control mode. It also accepts a prior run's `shipping-closure` directory, whose derived plan maps the original observed commands to frozen artifact paths; this avoids races with later root builds. It does not prove that old objects match current sources. `--operations 10000 --control-payload-bytes 65536 --workloads pt001 pt002` in control mode exercises real large-payload workload length without running the full five-repetition matrix. `--workloads pt001 pt002`, for example, narrows a development run. A narrowed full invocation records its selected workloads and must not be presented as the complete matrix. Full mode rejects operation-count overrides and build reuse.

## Workloads and operation definitions

Full mode uses 64-byte and 65,536-byte Array payloads. Each cell/profile runs in its own process, with one full-size validated warmup followed by five measured repetitions in that same process; each iteration creates and tears down a fresh owner. PT002 crosses 1/4 writers with 1/4 readers, each performing 10,000 operations. PT001, PT003 and PT004 also perform 10,000 attempts/cycles per controller. Control mode uses the 64-byte payload and 4 writers/4 readers for PT002.

An Array's element count is the payload size. Its buffer header, capacity rounding, inline Array value, model counters, snapshot provenance, facade objects and runtime storage are additional. Each result reports model/snapshot inline sizes. Preparation copies a borrowed historical model and mutates a byte while the historical source is still alive. PT001 checks the entire final byte sequence against the accepted mutations, as well as its change counter; values escape through public observations and encoded checksums.

| Workload | Operation and validation | Timing boundary |
| --- | --- | --- |
| PT001 Shared | One snapshot, preparation and commit; all 10,000 must accept. A FIFO flush after each admission prevents queue-capacity pressure. No subscriber or effect is registered. | Snapshot, preparation, synchronous public commit, and the later scheduling fence are separate latency arrays. Wall throughput includes the fence. Internal drainer activity can overlap public commit. |
| PT001 Local | Same payload, byte mutation and acceptance checks, with explicit command draining. | No managed tasks; drain cost is outside commit samples and included in wall throughput. |
| PT002 | Each writer performs exactly 10,000 snapshot/prepare/commit attempts; each reader takes 10,000 snapshots and accumulates observed values. Acceptances, conflicts and capacities are separate counts. No fixture retry loop exists. | Per-role service-time percentiles and whole-cell wall throughput. Task/thread roles are recorded; scheduling and fairness are not guaranteed. |
| PT003 | One initial subscriber callback blocks across the fixed producer burst. Distinct effect IDs fill at most 16 execution reservations; excess attempts reject. A fast subscriber proves completion delivery before the slow callback resumes. | Producer-attempt latency includes effect admission. Whole-cell time includes gated drivers and observation settlement, separately from PT001/002. |
| PT004 | Alternate start/cancel and start/complete cycles, proving driver entry before cancellation/release. Await public shutdown; check driver returns/cancellation and weak facade-owner release. Retain up to 64 closed historical snapshots, then release them. | Whole-cycle latency includes scheduling and teardown. It is not a primitive commit latency. |
| PT006 | Existing `Scripts/check-macro-fixtures.py` generates/compiles 2/1, 32/128 and 128/512 graphs, in Debug and Release, with one warmup plus five fresh measured outputs each. | Existing compiler duration, maximum RSS and object bytes; generated object bytes are not shipped application size. The separately linked performance executable supplies one representative application-code-size artifact. |

PT005 is reserved for comparing a proposed modern backend with the same semantic checks and workloads as the `OSAllocatedUnfairLock` baseline. It remains N/A while no optional modern backend is present.

PT003 compares the exact sorted accepted IDs with driver starts and returns, requires every completion to publish, and requires precisely the initial plus final slow callback after coalescing. Its eight ordinary batch slots, sixteen reservations and two subscriber registrations are explicit. The capacity-one pending mailbox is a source contract; measured callbacks establish coalescing rather than an invented continuous mailbox-depth measurement. Automatic pure completion retry counts are not exposed by the shipping facade; explicit fixture retries are zero. The resource copy additionally reuses the validated ledger preparation-round recorder, reports total/extra completion preparations and the per-turn maximum, and resets it at cohort boundaries. These values are separate from shipping-facade rejection counts.

PT004 uses signals and continuations for entry/completion and an awaited flush for cancellation processing. It does not use sleeps as progress evidence. The blocked synchronous subscriber has a 120-second failure bound. Every benchmark process has a 600-second outer failure bound; a missing signal becomes a failed timed-out command, never a sample. The timeout is a safety bound, not evidence that cleanup occurred.

## Allocation and retained-memory profiles

Allocation profiles load only the benchmark dylib with `DYLD_INSERT_LIBRARIES`. Latency and compiler lanes remove inherited injection. The allocator probe is not a package target or dependency and must not be shipped.

Before each allocation window, touch/reset the fixed bookkeeping table and capture process heap baselines. The window includes actual fixture work and control bookkeeping. Latency arrays are disabled; formatting, JSON encoding and output occur after collection stops. Return-value/recorder storage can remain live at the final checkpoint, so window-live counts do not by themselves identify leaked library objects.

The controls prove exact C and Swift allocation counts, concurrent collection and zero tracked retention after teardown. They are rebuilt and executed against the current dylib before workload measurements. The probe exports a scalar C ABI loaded via `dlsym` and `@convention(c)` pointers, so the benchmark needs no allocation-probe link or bridging-header flag.

Recorded metrics are successful **covered allocator-entrypoint events**, cumulative requested bytes, current/peak tracked allocations and requested bytes, dropped records, all-zone live blocks/bytes, reserved heap bytes, allocator high-water bytes, and physical footprint. Zero dropped records and a successful task-info query are required. Successful reallocations count as requests even if they keep the same address. A pre-window allocation's free does not reduce this window's live count.

The probe covers ordinary and typed current-SDK malloc/calloc/realloc/free/valloc/aligned_alloc/posix_memalign and corresponding zone allocation/free variants, including zone options. It does not establish a complete arbitrary-process allocation trace: direct zone function pointers, batch APIs, zone destruction, reallocf, unlisted private paths, virtual mappings and custom pools can bypass it. Runtime pooling and optimized-away logical objects need not produce allocator events. Counts include framework/runtime traffic that traverses covered functions.

A fixed 1,048,576-slot table, pthread nesting key and bookkeeping mutex add overhead and contention. Peak tracked values follow bookkeeping order and can differ from exact allocator-time overlap. Allocation-run throughput is not shipping throughput. Allocator reserved memory and physical footprint can remain above baseline after live objects are released. Held/released snapshots deliberately change the expected live baseline; allocation windows also include harness storage and runtime caches. The controls distinguish 24 requested bytes per Swift class from allocator-rounded 32-byte blocks.

## Instrumented core copies

These are separate executables. Neither copy changes shipping sources, modules or public APIs.

The lock lane copies the exact selected `StateMachine` sources and asserts four patch matches in `RetainedAtomic.swift`. Its three `AtomicRecordStorage` lock bodies take direct monotonic C timestamps and return the timing primitives alongside the original result. Recording occurs after unlocking. The existing expected/next/retirement lifetime extensions remain present exactly. No callback, allocation recorder or user payload inspection runs inside these lock bodies.

These samples are **critical-section body time**. Timestamp placement excludes acquisition and unlock overhead and includes clock-call/instrumentation cost. Tuple return and closure epilogue instructions can follow the final read, so the interval is not the complete physical lock hold. A separate 10,000-pair calibration uses the same Swift-to-C clock entrypoints. On the development M1 host, short body intervals can read zero while paired-clock calibration is about 41 ns; zero is a quantized interval, not evidence of zero-cost locking. Raw body and calibration distributions are both retained; no automatic subtraction or precision claim is made. A copied-core functional workload must pass before its samples can be used. Shipping commit latency is never relabeled as lock hold.

The resource lane registers task handles and awaits their termination. Exact patch counts cover ten Shared-host `Task<Void>` sites, four mailbox sites, one coordinator watcher assignment and one outside-lock ledger preparation-round defer; coordinator watchers await their exact Outcome workers. A lexical inventory recognizes ordinary, generic, parenthesized, detached and nested Task constructions. Comments, strings and Task type annotations do not count as constructions. Unknown constructor/member spellings, Task-bearing string interpolation, async-let or task-group creation reject the copy for review.

The whole Core module also contains confined-host definitions. Their task families are explicitly inventoried but excluded from joining: eight MainActor-host constructions, ten actor-host constructions (two inherited and eight detached), six isolated-host constructions, and one MainActor subscription cleanup construction. The sequence and publisher sources are inventoried the same way (five and six constructions); the workload registers callbacks only and never creates those tasks. This workload constructs only Local and Shared owners, so it never executes those confined host/token paths. The copy asserts that exercised Core files have no references to the excluded types and that execution fixtures do not use Actor/MainActor facades. The excluded files remain byte-identical to their shipping sources. This is a scoped Shared-resource measurement, not coverage of confined-host task lifetimes. Changed exclusion inventories, new task sites and changed patch shapes reject the copy.

Private getters count queued batches, execution reservations, active authorities, preparation claims, retained deliveries, subscribers, mailboxes, coordinator workers, and tasks waiting for flush or shutdown progress. These reads occur outside the core locks. The emitted `task-inventory.json` records every construction's source hash, line, constructor kind, nesting depth and tracked/joined/excluded disposition.

PT004 joins registered library tasks after **every cycle**, so completed task handles cannot accumulate over all 10,000 cycles. It checks zero settled private counts and weak release of owner storage, coordinator, progress, and registered mailboxes, whose state lives inside them behind a lock, after dropping the owner. It retains only weak markers. Storage and mailbox markers must be released when the owner is dropped, and dropping it must start no library task. The coordinator and progress markers are actors: after their last job has returned and every library task is joined, the concurrency runtime can still hold an actor for a moment on one of its own threads, as a processing job does after a priority escalation. So the copy waits up to one second for those two markers, fails if either is still alive then, and reports `actorReleasesAfterOwnerDrop`, the cycles that needed the wait, and `maxActorReleaseNanosecondsAfterOwnerDrop`. `maxSampled_*` values are checkpoint maxima, not continuously observed peaks. Registered task-handle counts include completed tasks until a join and are not called simultaneously live task counts. Resource-copy timings are perturbed and are not shipping performance results. State and actor counts are separate checkpoint reads, not one atomic cross-actor snapshot.

## Evidence and interpretation

The output retains every command, exit code, timeout, monotonic duration and raw process result. Each successful repetition has role-specific p50/p95/p99/median latency, attempt/acceptance throughput, conflict/rejection counts, allocation and resource checkpoints. Percentiles use nearest rank (`ceil(p × N)`); the separately named median uses the statistical median. Aggregate values are medians of the five corresponding repetition summaries. Warmup data remains in raw logs and is excluded from aggregates. Failure/timeouts stop the run with `status: fail` and preserve the evidence.

An uncommitted checkout can have no Git HEAD; that failed lookup is retained and the used-source SHA-256 map supplies the candidate identity. Toolchain, SDK, OS, hardware, compiler flags, source identities, selected native plan, frozen object/module/plugin hashes, instrumented copy hashes, patch assertions and executable hashes accompany the results. Used source changes during measurement invalidate the receipt. These data describe one candidate on one environment and do not establish a historical improvement, universal tail latency, fairness or minimum-OS execution.
