// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisionDesk",
    platforms: [.macOS(.v14), .visionOS(.v2)],
    products: [
        .library(name: "VirtualDisplayBridge", type: .static, targets: ["VirtualDisplayBridge"]),
        .library(name: "DeskCore", targets: ["DeskCore"]),
        .library(name: "DeskTransport", targets: ["DeskTransport"]),
        .executable(name: "VisionDeskMac", targets: ["VisionDeskMac"])
    ],
    targets: [
        .target(name: "DeskCore"),
        .target(name: "DeskTransport", dependencies: ["DeskCore"]),
        .target(name: "VirtualDisplayBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc", "-fobjc-arc-exceptions"])],
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreGraphics")]),
        .executableTarget(name: "VisionDeskMac", dependencies: ["DeskCore", "DeskTransport", "VirtualDisplayBridge"]),
        .testTarget(name: "DeskCoreTests", dependencies: ["DeskCore"]),
        .testTarget(name: "DeskTransportTests", dependencies: ["DeskCore", "DeskTransport"])
    ],
    swiftLanguageModes: [.v5]
)
