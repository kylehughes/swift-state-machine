// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

/// Tests that import the macro implementation or SwiftSyntax live in their own opt-in target.
///
/// SwiftPM links macros against its prebuilt SwiftSyntax only while no test target depends on
/// SwiftSyntax or on a macro target. Declaring this target makes every build of the package,
/// including each platform build, compile SwiftSyntax from source.
let macroImplementationTests: [Target] =
    Context.environment["STATE_MACHINE_MACRO_IMPLEMENTATION_TESTS"] == nil
    ? []
    : [
        .testTarget(
            name: "StateMachineMacroImplementationTests",
            dependencies: [
                "StateMachineMacros",
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        )
    ]

let package = Package(
    name: "StateMachine",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1), .macCatalyst(.v16)],
    products: [
        .library(name: "StateMachine", targets: ["StateMachine"]),
        .library(name: "StateMachineUI", targets: ["StateMachineUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
    ],
    targets: [
        .macro(
            name: "StateMachineMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "StateMachineMacroTests",
            dependencies: [
                "StateMachine", "StateMachineExamples", "StateMachineReferenceModel", "StateMachineTestSupport",
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .target(
            name: "StateMachine",
            dependencies: ["StateMachineMacros"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .target(name: "StateMachineUI", dependencies: ["StateMachine"], swiftSettings: [.treatAllWarnings(as: .error)]),
        // Example graphs for the tests and probes; no product publishes them.
        .target(
            name: "StateMachineExamples",
            dependencies: ["StateMachine", "StateMachineUI"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "StateMachineTests",
            dependencies: [
                "StateMachine", "StateMachineExamples", "StateMachineUI", "StateMachineReferenceModel",
                "StateMachineTestSupport",
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .target(
            name: "StateMachineTestSupport",
            path: "Tests/Support",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .target(
            name: "StateMachineReferenceModel",
            path: "Tests/ReferenceModel/Interpreter",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "StateMachineReferenceModelTests",
            dependencies: ["StateMachineReferenceModel"],
            path: "Tests/ReferenceModel/Tests",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ] + macroImplementationTests,
    swiftLanguageModes: [.v6]
)
