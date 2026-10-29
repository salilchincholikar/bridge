// swift-tools-version:6.2
// bridge: native macOS workbench for AWS. SwiftPM only; builds with Command Line Tools (no Xcode).
// Layout and rules: docs/technical.md section 3.
import PackageDescription

let package = Package(
    name: "Bridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "BridgeUI", targets: ["BridgeUI"]),
        .library(name: "BridgeAgents", targets: ["BridgeAgents"]),
        .executable(name: "BridgeApp", targets: ["BridgeApp"]),
    ],
    targets: [
        // Headless core: no AppKit/SwiftUI imports, so it is testable without a window.
        .target(name: "BridgeCore", path: "Sources/BridgeCore"),
        .target(name: "BridgeUI", dependencies: ["BridgeCore"], path: "Sources/BridgeUI"),
        .target(name: "BridgeAgents", dependencies: ["BridgeCore"], path: "Sources/BridgeAgents"),
        // AppKit app: a thin layer over BridgeCore.
        .executableTarget(name: "BridgeApp", dependencies: ["BridgeCore", "BridgeUI", "BridgeAgents"], path: "Sources/BridgeApp"),
        // Plain executable instead of XCTest: Command Line Tools ships no XCTest/Swift Testing (as in ../waffle).
        .executableTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore", "BridgeAgents"], path: "Tests/BridgeCoreTests"),
        .executableTarget(name: "BridgeClientExample", dependencies: ["BridgeCore"], path: "examples/BridgeClient"),
    ],
    swiftLanguageModes: [.v5]
)
