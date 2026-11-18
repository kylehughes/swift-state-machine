# Working on State Machine

State Machine separates ordinary model data from authority to change a particular
owner. Preserve that distinction when changing the API, runtime, macros, or
examples. `SPEC.md` describes the domain and runtime contracts.

The public name is State Machine, the Swift module prefix is `StateMachine`,
and the repository identity is `swift-state-machine`. `SPEC.md` retains the
original working name `AtomicState`; apply its contracts to the current names.

## Toolchain and platforms

Use Swift 6.4 in Swift 6 language mode. Keep the deployment minima in
`Package.swift`: iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1, and Mac Catalyst
16. SwiftSyntax is pinned to an exact compatible version; update its resolved
identity and compiler fixtures together.

Use `--build-system native` for SwiftPM verification. The Xcode backend in the
selected toolchain adds an experimental compiler feature to otherwise ordinary
builds. Do not add experimental features, concurrency suppression, or unchecked
Sendable conformances to work around a diagnostic. Every owned Swift target
treats warnings as errors through supported package settings.

## Preserve the authority boundary

- Keep facade kernels, provenance, and proof constructors private or fileprivate.
  SPI access is not a sealing boundary. A public raw kernel has a separate,
  weaker contract and cannot expose an existing facade's storage.
- Consume a prepared transition into an immutable Copyable and Sendable payload
  before entering the shared lock. Preparation and effect execution happen
  outside the lock.
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
  claim. Capacity retries reuse the prepared candidate; pure conflict retries
  have a bounded preparation budget.
- Restore validated data with fresh authority. Do not make live tickets,
  observed provenance, prepared transitions, or kernel stamps Codable.

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

Tests that import `StateMachineMacros` or SwiftSyntax belong in
`Tests/StateMachineMacroImplementationTests`. `Package.swift` declares that
target only when `STATE_MACHINE_MACRO_IMPLEMENTATION_TESTS` is set, and
`--macro-implementation` sets it and uses a separate scratch path. Keep both
dependencies out of every other test target: SwiftPM links macros against its
prebuilt SwiftSyntax only while no declared test target depends on either, and
otherwise every build, including each platform build, compiles SwiftSyntax from
source.

Compiler rejection fixtures need a passing control with the same imports and
flags, a real compilation that reaches ownership checking, and a matched
diagnostic. A crash or missing module is not a passing rejection test. Keep
`Tests/ReferenceModel` independent of production admission code; comparisons
against it must execute the production implementation.

Macro checks use the selected configuration's existing native build. Run their
`--configuration release` variants after the Release tests, and use fresh
external output paths for retained evidence. Compare expansion snapshots;
update them with `--record` only after reviewing an intentional generator change.

Run instrumented tests in a separate `--scratch-path`. The test helper accepts
`--sanitize thread` and `--enable-code-coverage`, and `--output PATH` retains
individual test observations in a fresh directory. Keep performance timing
separate from instrumented builds and concurrent compilation.

For platform or distribution changes, run `Scripts/check-platforms.py` and its
`--interfaces` and `--device` modes. Build evidence does not establish execution
on an OS version. `Scripts/check-ios.py` runs an app that imports the public
products and the example graphs on its own Simulator, iOS 17.5 by default;
`--runtime` and `--device-type` select another installed runtime, and the app
must report that runtime's version. Its expected check list must match every
reported app check. Execution on the iOS 16 floor is unestablished until a run
on an iOS 16 runtime is retained. `StateMachineExamples` is a target, not a
product: the tests, compiler fixtures, and iOS app use it, and the platform
probe declares its own graphs.
For documentation changes, use `python3 Scripts/docs.py --output PATH` with a
fresh output path and check the generated navigation and links.

Use the root `.swift-format` configuration. Format only owned changes, verify
idempotence, and keep examples synchronized with the public interfaces. Place
temporary logs and candidate-specific delivery receipts outside the package.
Keep durable usage, constraints, and maintenance instructions in the repository.
