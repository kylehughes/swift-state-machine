// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "StateMachine",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1), .macCatalyst(.v16)],
    products: [
        .library(name: "StateMachine", targets: ["StateMachine"]),
        .library(name: "StateMachineExamples", targets: ["StateMachineExamples"]),
        .library(name: "StateMachineSchema", targets: ["StateMachineSchema"]),
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
        .target(
            name: "StateMachineSchema",
            dependencies: ["StateMachine", "StateMachineMacros"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "StateMachineMacroTests",
            dependencies: [
                "StateMachineSchema", "StateMachine", "StateMachineMacros", "StateMachineExamples",
                "StateMachineReferenceModel",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .target(name: "StateMachine", swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "StateMachineUI", dependencies: ["StateMachine"], swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(
            name: "StateMachineExamples",
            dependencies: ["StateMachine", "StateMachineSchema", "StateMachineUI"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "StateMachineTests",
            dependencies: ["StateMachine", "StateMachineExamples", "StateMachineUI", "StateMachineReferenceModel"],
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
    ],
    swiftLanguageModes: [.v6]
)
