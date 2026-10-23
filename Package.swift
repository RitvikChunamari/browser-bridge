// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BrowserBridge", platforms: [.macOS(.v14)], products: [
    .executable(name: "BrowserBridge", targets: ["BrowserBridge"]),
    .executable(name: "bridge-inspect", targets: ["BridgeCLI"])
], targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "BridgeCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "BrowserBridge", dependencies: ["BridgeCore"]),
    .executableTarget(name: "BridgeCLI", dependencies: ["BridgeCore"]),
    .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore", "CSQLite"])
])
