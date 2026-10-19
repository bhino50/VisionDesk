// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisionDesk",
    platforms: [.macOS(.v14), .visionOS(.v2)],
    products: [
        .library(name: "DeskCore", targets: ["DeskCore"]),
        .library(name: "DeskTransport", targets: ["DeskTransport"]),
        .executable(name: "VisionDeskMac", targets: ["VisionDeskMac"])
    ],
    targets: [
        .target(name: "DeskCore"),
        .target(name: "DeskTransport", dependencies: ["DeskCore"]),
        .executableTarget(name: "VisionDeskMac", dependencies: ["DeskCore", "DeskTransport"]),
        .testTarget(name: "DeskCoreTests", dependencies: ["DeskCore"]),
        .testTarget(name: "DeskTransportTests", dependencies: ["DeskCore", "DeskTransport"])
    ],
    swiftLanguageModes: [.v5]
)
