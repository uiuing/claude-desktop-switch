// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDesktopSwitch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeSwitch", targets: ["ClaudeSwitch"]),
        .executable(name: "switch-inspect", targets: ["SwitchInspect"]),
        .library(name: "SwitchCore", targets: ["SwitchCore"]),
    ],
    targets: [
        .target(name: "SwitchCore", resources: [.copy("Localizations")]),
        .target(name: "SwitchStorage", dependencies: ["SwitchCore"]),
        .target(name: "SwitchMac", dependencies: ["SwitchCore", "SwitchStorage"]),
        .executableTarget(name: "ClaudeSwitch", dependencies: ["SwitchCore", "SwitchStorage", "SwitchMac"]),
        .executableTarget(name: "SwitchInspect", dependencies: ["SwitchCore", "SwitchStorage", "SwitchMac"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore", "SwitchStorage"]),
        .testTarget(name: "SwitchMacTests", dependencies: ["SwitchMac", "SwitchCore", "SwitchStorage"]),
    ],
    swiftLanguageModes: [.v5]
)
