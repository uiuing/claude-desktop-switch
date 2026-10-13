// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeDesktopSwitch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitchCore", targets: ["SwitchCore"]),
    ],
    targets: [
        .target(name: "SwitchCore", resources: [.copy("Localizations")]),
        .target(name: "SwitchStorage", dependencies: ["SwitchCore"]),
        .target(name: "SwitchMac", dependencies: ["SwitchCore", "SwitchStorage"]),
    ],
    swiftLanguageModes: [.v5]
)
