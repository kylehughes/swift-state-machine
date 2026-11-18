// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "GeneratedExternalClient",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "swift-state-machine", path: "../..")],
    targets: [
        .target(
            name: "GeneratedDomain",
            dependencies: [.product(name: "StateMachine", package: "swift-state-machine")],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .executableTarget(
            name: "Client",
            dependencies: ["GeneratedDomain"],
            swiftSettings: [.treatAllWarnings(as: .error), .defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
