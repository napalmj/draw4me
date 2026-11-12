// swift-tools-version:6.0
import PackageDescription
import Foundation

// With only the Command Line Tools installed (no Xcode), the swift-testing framework lives in a
// directory the compiler doesn't search by default. Point the test targets at it when present.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsCLTTesting = FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
let testSwiftSettings: [SwiftSetting] = needsCLTTesting ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkerSettings: [LinkerSetting] = needsCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltLib])]
    : []

let package = Package(
    name: "Draw4Me",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Draw4MeCore", targets: ["Draw4MeCore"]),
        .library(name: "Draw4MeRender", targets: ["Draw4MeRender"]),
        .library(name: "Draw4MeAutomation", targets: ["Draw4MeAutomation"]),
        .executable(name: "Draw4Me", targets: ["Draw4Me"]),
        .executable(name: "draw4me-cli", targets: ["draw4me-cli"]),
        .executable(name: "draw4me-mcp", targets: ["draw4me-mcp"]),
    ],
    targets: [
        // Pure model + command layer. Foundation only, no UI frameworks.
        .target(name: "Draw4MeCore"),
        // SceneKit scene building, headless snapshots, 2D drafting (CoreGraphics).
        .target(name: "Draw4MeRender", dependencies: ["Draw4MeCore"]),
        // The single entry point automation clients (console, CLI, future AI transports) talk to.
        .target(name: "Draw4MeAutomation", dependencies: ["Draw4MeCore", "Draw4MeRender"]),
        // MCP server (JSON-RPC over stdio) that relays agent tool calls to the app or works headlessly.
        .target(name: "Draw4MeMCP", dependencies: ["Draw4MeCore", "Draw4MeRender", "Draw4MeAutomation"]),
        .executableTarget(name: "draw4me-mcp", dependencies: ["Draw4MeMCP"]),
        .executableTarget(name: "Draw4Me", dependencies: ["Draw4MeCore", "Draw4MeRender", "Draw4MeAutomation"]),
        .executableTarget(name: "draw4me-cli", dependencies: ["Draw4MeCore", "Draw4MeRender", "Draw4MeAutomation"]),
        .testTarget(name: "Draw4MeCoreTests", dependencies: ["Draw4MeCore"],
                    swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "Draw4MeRenderTests", dependencies: ["Draw4MeCore", "Draw4MeRender", "Draw4MeAutomation"],
                    swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "Draw4MeMCPTests", dependencies: ["Draw4MeMCP", "Draw4MeCore", "Draw4MeAutomation"],
                    swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
    ],
    swiftLanguageModes: [.v5]
)
