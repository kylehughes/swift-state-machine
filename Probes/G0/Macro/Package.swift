// swift-tools-version: 6.4
import PackageDescription
import CompilerPluginSupport
let package = Package(
    name: "G0Macro",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "DomainMacro", targets: ["DomainMacro"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")],
    targets: [
        .macro(name: "DomainPlugin", dependencies: [
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .target(name: "DomainMacro", dependencies: ["DomainPlugin"],
            swiftSettings: [.treatAllWarnings(as: .error)])
    ],
    swiftLanguageModes: [.v6]
)
