// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDesktopSwitch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "switch-inspect", targets: ["SwitchInspect"]),
        .library(name: "SwitchCore", targets: ["SwitchCore"]),
    ],
    targets: [
        .target(name: "SwitchCore", resources: [.copy("Localizations")]),
        .target(name: "SwitchStorage", dependencies: ["SwitchCore"]),
        .target(name: "SwitchMac", dependencies: ["SwitchCore", "SwitchStorage"]),
        .executableTarget(name: "SwitchInspect", dependencies: ["SwitchCore", "SwitchStorage", "SwitchMac"]),
    ],
    swiftLanguageModes: [.v5]
)
