// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HouseBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HouseBridgeCore", targets: ["HouseBridgeCore"]),
        .executable(name: "housebridgectl", targets: ["housebridgectl"]),
        .executable(name: "HouseBridgeMenu", targets: ["HouseBridgeMenu"]),
    ],
    targets: [
        .target(name: "HouseBridgeCore"),
        .executableTarget(name: "housebridgectl", dependencies: ["HouseBridgeCore"]),
        .executableTarget(name: "HouseBridgeMenu", dependencies: ["HouseBridgeCore"]),
        .testTarget(name: "HouseBridgeCoreTests", dependencies: ["HouseBridgeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
