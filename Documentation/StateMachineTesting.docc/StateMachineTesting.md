# ``StateMachineTesting``

Drive real owners step by step in tests, control when each driver call ends, and measure which declared edges the tests exercised.

`StateMachineTesting` is a small library of test helpers for graphs declared
with `StateMachine`. It depends only on `StateMachine` and links no test
framework, so the same helpers work under Swift Testing and XCTest, and an app
target can import them too. Add `StateMachineTesting` to a test target in
`Package.swift`.

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Transfers",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/kylehughes/swift-state-machine.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "TransfersFeature",
            dependencies: [.product(name: "StateMachine", package: "swift-state-machine")]
        ),
        .testTarget(
            name: "TransfersFeatureTests",
            dependencies: [
                "TransfersFeature",
                .product(name: "StateMachineTesting", package: "swift-state-machine"),
            ]
        ),
    ]
)
```

The helpers cover the two ways a graph's work runs.

- A managed owner, such as `Shared`, `ActorHost`, `MainActorHost`, or
  `IsolatedHost`, runs its operations through drivers. ``ControlledDriver``
  and ``KeyedControlledDriver`` stand in for those drivers when the operation's
  values are `Sendable`, and ``MainActorControlledDriver``,
  ``KeyedMainActorControlledDriver``, ``IsolatedControlledDriver``, and
  ``KeyedIsolatedControlledDriver`` do the same when values stay on the host's
  actor. Each call the host starts waits until the test finishes it, so a test
  orders every event explicitly without sleeping.
- A `Local` owner leaves execution to its caller. ``ManualMachineTest`` drives
  one step by step through the owner's own methods and records every accepted
  change with the edge its receipt names, and ``GraphCoverage`` combines the
  records of one owner type's runs to report the declared edges and phases that
  no test exercised.

None of the helpers grants authority. They cannot construct a ticket, an
observation, a prepared transition, or a completion, and they never inject an
outcome into a managed host. A managed host still receives work only from its
own drivers, and a `Local` owner admits only completions sealed by work it
issued. A test therefore exercises the same admission rules as production code.

A helper that expects an outcome throws ``StateMachineTestFailure`` when the
owner does something else. Its message names what was expected and what
happened, and it carries the source location of the helper call, so the
failure points at the line of the test that made it. Swift Testing and XCTest
both report a thrown error as a failure of the test that threw it.

The `StateMachine` module's documentation describes testing a graph from its
edges to its hosts in the article "Testing a graph".

## Topics

### Essentials

- <doc:ControllingDrivers>
- <doc:ScriptingALocalOwner>

### Controlling drivers

- ``ControlledDriver``
- ``KeyedControlledDriver``
- ``MainActorControlledDriver``
- ``KeyedMainActorControlledDriver``
- ``IsolatedControlledDriver``
- ``KeyedIsolatedControlledDriver``

### Scripting a Local owner

- ``ManualMachineTest``

### Measuring coverage

- ``GraphCoverage``

### Reporting failures

- ``StateMachineTestFailure``
