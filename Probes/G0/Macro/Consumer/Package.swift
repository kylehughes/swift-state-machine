// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "ExternalConsumer",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "..")],
    targets: [
        .target(name: "DomainFixture", dependencies: [.product(name: "DomainMacro", package: "Macro")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .executableTarget(name: "ExternalConsumer", dependencies: ["DomainFixture"],
            swiftSettings: [.treatAllWarnings(as: .error)])
    ],
    swiftLanguageModes: [.v6]
)
