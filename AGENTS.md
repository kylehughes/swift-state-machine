# Working on State Machine

State Machine separates ordinary model data from authority to change a particular
owner. Preserve that distinction when changing the API, runtime, macros, or
examples. `SPEC.md` describes the domain and runtime contracts.

The public name is State Machine, the Swift module prefix is `StateMachine`,
and the repository identity is `swift-state-machine`. `SPEC.md` retains the
original working name `AtomicState`. Apply its contracts to the current names.

## Toolchain and platforms

Use Swift 6.4 in Swift 6 language mode. Keep the deployment minima in
`Package.swift` at iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, and
Mac Catalyst 16. SwiftSyntax is required within major version 604, which matches
Swift 6.4, so clients can resolve its patch releases. `Package.resolved` records
the version the checks run against. Update the resolved version and compiler
fixtures together.

Use `--build-system native` for SwiftPM verification. The Xcode backend in the
selected toolchain adds an experimental compiler feature to otherwise ordinary
builds. Do not add experimental features, concurrency suppression, or unchecked
`Sendable` conformances to work around a diagnostic. Every owned Swift target
treats warnings as errors through supported package settings.

## Preserve the authority boundary

- Keep facade kernels, provenance, and proof constructors private or fileprivate.
  SPI access is not a sealing boundary. A public raw kernel has a separate,
  weaker contract and cannot expose an existing facade's storage.
- Consume a prepared transition into an immutable `Copyable` and `Sendable`
  payload before entering the shared lock. Preparation and effect execution
  happen outside the lock.
- Publish root state, operation authority, and the accepted command batch as one
  atomic change. Rejection must leave all three unchanged.
- Keep user callbacks, hashing, equality, and final payload destruction outside
  critical sections. Audit ownership on rejection, replacement, cancellation,
  draining, and closure as well as the accepted path.
- Keep `Local` a noncopyable value with explicit command draining and execution
  acknowledgments. A hidden mutable reference owner changes its contract.
- Treat cancellation, execution termination, and delivery settlement as separate
  events. Revoking authority does not prove that a driver has stopped.
- Preserve the first retained terminal outcome and the single reconciliation
  claim. Capacity retries reuse the prepared candidate. Pure conflict retries
  have a bounded preparation budget.
- Restore validated data with fresh authority. Do not make live tickets,
  observed provenance, prepared transitions, or kernel stamps `Codable`.
- Keep `StateMachineTesting` on the public surface. Its helpers drive real
  owners through their own verbs. They never construct a ticket, observation,
  proposal, or completion, and never inject an outcome into a managed host. It
  depends only on `StateMachine` and links no test framework, so an app can
  import it.

## Verify the changed contract

Run the relevant focused checks during development, then the package checks for
the completed change:

```sh
python3 Scripts/check-tests.py --configuration debug
python3 Scripts/check-tests.py --configuration release
python3 Scripts/check-tests.py --macro-implementation
python3 Scripts/check-compiler-fixtures.py
python3 Scripts/check-macro-expansions.py --output /tmp/state-machine-expansions
python3 Scripts/check-macro-fixtures.py --output /tmp/state-machine-graph
python3 Scripts/check-macro-fixtures.py --variant sparse-input --output /tmp/state-machine-graph-sparse
python3 Scripts/check-macro-fixtures.py --variant operation-heavy --output /tmp/state-machine-graph-operations
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
```

### Schedule explorer

The schedule explorer (`Tests/StateMachineTests/Explorer*.swift`) runs in three
tiers. Its smoke tier runs in the normal suite in about 10 seconds. For a change
to presentation, publisher, registration, or owner-lifetime code, also run the
standard tier (about 4 minutes across 4 workers). Before a release, run the
exhaustive tier (about 75–80 minutes across 4 workers). Run one tier at a time
with a fresh `--output` directory:

```sh
python3 Scripts/check-explorer.py --tier standard --scratch-path /tmp/state-machine-explorer --output /tmp/state-machine-explorer-standard
python3 Scripts/check-explorer.py --tier exhaustive --scratch-path /tmp/state-machine-explorer --output /tmp/state-machine-explorer-exhaustive
```

`Scripts/check-explorer.py` builds or updates one native Debug test binary in
`--scratch-path` (never Release), queries that binary for its exact tier plan
(`EXPLORER_LIST_CONFIGS=1`), and fans out one configuration per read-only worker
(`EXPLORER_CONFIG_INDEX=N`, `--workers 1..4`, capped at 4) via
`swiftpm-testing-helper`, ordered by costly cases first. It rejects inherited
`EXPLORER_*` overrides, preserves per-unit logs, coverage files, L1 window
counts, and failure artifacts, and writes an aggregate `receipt.json` bound to
the candidate commit, Debug binary SHA-256, and toolchain.

For single-process debugging or replaying a finding, `EXPLORER_FAILURES=PATH`
appends every violation found and `EXPLORER_REPLAY="Class: script"` with
`swift test --build-system native --scratch-path /tmp/state-machine-explorer
--filter ExplorerTests/replay` replays one with a trace. `ExplorerTests.swift`
lists the other variables. `Tests/ScheduleExplorer.md` describes the explorer's
events and invariants. Update that file and the explorer together whenever
presentation, registration, or owner-teardown behavior changes.

### Test targets, compiler fixtures, and macro checks

Tests of the testing product belong in `Tests/StateMachineTestingTests`, which
depends on `StateMachineTesting` and `StateMachineExamples`. No other test
target imports `StateMachineTesting`. Tests that import `StateMachineMacros` or
SwiftSyntax belong in `Tests/StateMachineMacroImplementationTests`.
`Package.swift` declares that target only when
`STATE_MACHINE_MACRO_IMPLEMENTATION_TESTS` is set, and `--macro-implementation`
sets it with a separate scratch path. Keep both dependencies out of every other
test target. SwiftPM links macros against its prebuilt SwiftSyntax only while no
declared test target depends on either, and otherwise every build (including
each platform build) compiles SwiftSyntax from source.

Compiler rejection fixtures need a passing control with the same imports and
flags, a real compilation that reaches ownership checking, and a matched
diagnostic. A crash or missing module never passes as a rejection test. The
macro's graph checks are always on, so every graph meant to compile (in a
control, example, probe, snippet, or stress generator) must be structurally
valid. Every phase must be reachable, every phase without an exit must be marked
`@Terminal`, and every operation must be started and accepted by a completion
edge. `check-macro-fixtures.py` marks the phases its generated graphs leave
without an exit `@Terminal`, and outside the `operation-heavy` variant it
rejects `--edges` below `--phases` minus one because that would leave a phase
unreachable. Keep `Tests/ReferenceModel` independent of production admission
code. Comparisons against it must execute the production implementation.

Macro checks use the selected configuration's existing native build. Run their
`--configuration release` variants after the Release tests, and use fresh
external output paths for retained evidence. Compare expansion snapshots, and
update them with `--record` only after reviewing an intentional generator
change.

### Macro fuzzer

After a macro change, also run `Scripts/fuzz-macro.py`, which checks the macro
against Swift's own reading of a schema. It rewrites valid seeds (the guide's
schemas, chosen client fixtures, and schemas of its own) into five classes of
test cases:

- **Equivalent programs** that Swift reads the same way, using parentheses,
  backticks (nested argument labels included), aliases, qualified names, sugar,
  comments and decoy literals, `#if`, nesting, moving a schema to another file,
  reordered members, and a universal deprecation's options in another order.
- **Name collisions** between two distinct names in a normal form the macro
  might use, or with a generated name.
- **Invalid schemas**, including an invalid graph, a duplicate marker, a
  restricted parameter, a numeric value past its bound, or a `renamed:` target
  other than a bare edge name.
- **Unsupported forms** that the guide calls unsupported and that require a
  macro diagnostic.
- **Valid variations**, including another access level, attribute, binding of an
  unchanged spelling, default isolation, or optimization.

The fuzzer compiles each case alone through the native build's plugin as a
module imported by a separate harness module. An equivalent case must compile
with the seed's canonical generated signatures, graph, and output. Under a
reordering, the documented declaration-ordered graph lists must follow the
case's own source order. A renamed case must behave like the seed with that name
changed, and a valid variation of a domain seed must print the seed's pinned
report. An invalid case must be rejected with its documented diagnostic, matched
as a whole message, at the token the rewrite changed or the message names (by
line and column), with nothing beside it except what the refused expansion
leaves undeclared or what the entry lists as a consequence.

Every compiled case must also satisfy these checks:

- Link and run to completion.
- Print a graph for every schema the module declares, holding every phase,
  input, operation, and event declared in the source.
- Export each type spelling as the author's own text on one line without
  comments, naming the authored type where the guide says it is meant.
- Render Mermaid and DOT text that a strict reader parses back as its graph
  (state declarations, labels, and edge styles included), including the graph
  decoded under names no identifier spells, whose DOT header the reader parses
  under the grammar's quoted-identifier rule and never the label rule.
- Give each managed owner an initializer with its driver and handler labels in
  its own declaration order.
- Keep any client section that calls a deprecated generated member compiling
  once every fix-it the compiler offers for the deprecation is applied.

Every seed must pass all of these checks on its own, and a domain seed must
print the report the script pins. A module generated from each seed's
attributes, compiled separately, must use every selected owner, find no
unselected one, and reach a public schema's owners from another package.

A crash, timeout, failed run, or compilation whose processes exceed
`--memory-cap-mb` (3,000 by default) always fails before any allowance, and the
watchdog kills it. `LIMITS` in the script lists the documented limits a case may
hit instead, each quoting the guide sentence that documents it. A quotation the
guide no longer holds stops the run. An interface allowance must explain every
added and removed signature. An entry marked `exact` is a refusal a rewrite must
meet alone, and each run lists where each accepted diagnostic stood in
`anchors.txt`. A fuzzer artefact (a rewrite that broke valid client code) counts
as unusable, never as a pass, and is judged again without the client. Each mode
needs a fresh `--output`, writes every failing case to `failures/` as a
self-contained source with a one-line description, prints one summary line, and
exits non-zero on failure:

```sh
python3 Scripts/fuzz-macro.py --self-test --output /tmp/state-machine-fuzz-self-test
python3 Scripts/fuzz-macro.py --smoke --output /tmp/state-machine-fuzz
python3 Scripts/fuzz-macro.py --random --count 500 --seed 1 --output /tmp/state-machine-fuzz-random
python3 Scripts/fuzz-macro.py --cost --output /tmp/state-machine-fuzz-cost
python3 Scripts/fuzz-macro.py --scaling --output /tmp/state-machine-fuzz-scaling
```

Mode and option behavior:

- `--self-test` plants a defect for each oracle (a swapped trigger, exported
  text that dropped `Self.`, a graph missing a declared phase, a refusal at the
  wrong token, a crash behind a documented limit, an alphabetized
  declaration-ordered list, a Mermaid rendering without its state declarations,
  or a size refusal naming the wrong count) and fails unless each is reported
  and its clean control passes. Run it after changing an oracle, and add a
  planted defect for every new check.
- `--smoke` is deterministic and skips sites whose shape earlier seeds already
  covered. `--smoke --full` runs every seed with every rewrite. A smoke run over
  every seed writes each rewrite's sites and cases to `operators.json` and fails
  when a selected rewrite raised an error or made no case, because its check
  then gave no evidence. The harness links the testing product, so a seed's
  pinned report can drive a generated owner through `StateMachineTesting`.
- `--random` composes two to four rewrites, requires the equivalences before a
  final rewrite of another kind to pass on their own, and removes rewrites a
  failure does not need while preserving the same failure.
- `--spelling-scope schema` reads exported spellings at the schema's scope (the
  contract of macros older than the current one) for calibrating against them.
- `--cost` compares scaled schemas spelled two equivalent ways by outcome and by
  the plugin's own time.
- `--scaling` checks that the plugin's time for each list-like construct grows
  at most `--growth-bound` times from `n` to `4n`, as the median of `--repeats`
  runs. A crash or cap in any repeat fails.
- `--ceilings` doubles each construct from 8 up to `--ceiling-limit` and records
  the largest size that compiles. It fails any construct that first stops on a
  timeout, the memory cap, a crash, or any error other than Swift's own limits,
  and fails Swift-limit stops at 256 or below. It also checks each size limit
  the guide documents, including one crossed by a mix of operations,
  cancellations, and events. At the limit, in every owner the mode supports, the
  expansion must compile within the caps. One past the limit, the macro must
  refuse it at the schema's name with exactly its size-limit diagnostic naming
  the construct, count, and bound.

`--cost`, `--scaling`, and `--ceilings` compile one schema at a time. Smoke and
random jobs default to half the cores. `--plugin`, `--modules`, and `--library`
select another build. Run them against the plugin of a native `swift build`,
never one that `Scripts/check-compiler-fixtures.py` built without
`--reuse-macro-plugin`.

### Instrumented tests and performance

Run instrumented tests in a separate `--scratch-path`. The test helper accepts
`--sanitize thread` and `--enable-code-coverage`, and `--output PATH` retains
individual test observations in a fresh directory. Keep performance timing
separate from instrumented builds and concurrent compilation.

### Platforms, iOS Simulator, and documentation

For platform or distribution changes, run `Scripts/check-platforms.py` and its
`--interfaces` and `--device` modes. Build evidence alone does not establish
execution on an OS version. `Scripts/check-ios.py` runs an app that imports the
public products and the example graphs on its own Simulator (iOS 17.5 by
default). `--runtime` and `--device-type` select another installed runtime, and
the app must report that runtime's version. The expected checks must match every
check the app reports. `--expect` defaults to the script's `EXPECTED_CHECKS`,
which lists the checks of `Probes/iOSSmoke/Smoke.swift` in order, so update that
list with every check added to or removed from the app. Execution on the iOS 16
floor remains unestablished until a run on an iOS 16 runtime is retained.
`StateMachineExamples` is a target rather than a product. The tests, compiler
fixtures, and iOS app use it, while the platform probe declares its own graphs.

For documentation changes, use `python3 Scripts/docs.py --output PATH` with a
fresh output path and check the generated navigation and links. It builds the
`StateMachine`, `StateMachineUI`, and `StateMachineTesting` catalogs in
`Documentation/` into one site.

### Formatting and workspace hygiene

Use the root `.swift-format` configuration. Format only owned changes, verify
idempotence, and keep examples synchronized with the public interfaces. Place
temporary logs and candidate-specific delivery receipts outside the package.
Keep durable usage, constraints, and maintenance instructions in the repository.
