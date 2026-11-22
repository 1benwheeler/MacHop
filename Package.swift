// swift-tools-version: 6.2
import PackageDescription

// Apple's recommended concurrency settings for every target ("approachable
// concurrency"). Both become the default in a later Swift.
let concurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
    name: "MacHop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacHop", targets: ["MacHop"]),
        .executable(name: "machop-lab", targets: ["MacHopLab"])
    ],
    targets: [
        // Platform-free logic: routing, ownership, HID encoding, queueing.
        .target(name: "MacHopCore", swiftSettings: concurrency),

        // Simulated iPhone HID host used by tests and the lab tool.
        .target(name: "VirtualPhone", dependencies: ["MacHopCore"], swiftSettings: concurrency),

        // macOS adapters and UI. Everything here runs on the main thread.
        .target(
            name: "MacHopApp",
            dependencies: ["MacHopCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)] + concurrency,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(name: "MacHop", dependencies: ["MacHopApp"], swiftSettings: concurrency),

        // Physical-device lab: iPhone screen capture, analysis and automated experiments.
        .target(
            name: "LabKit",
            dependencies: ["MacHopCore"],
            swiftSettings: concurrency,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(name: "MacHopLab", dependencies: ["LabKit", "VirtualPhone"], path: "Sources/machop-lab",
                          swiftSettings: concurrency),

        .testTarget(name: "MacHopCoreTests", dependencies: ["MacHopCore", "VirtualPhone"], swiftSettings: concurrency),
        .testTarget(name: "MacHopAppTests", dependencies: ["MacHopApp", "MacHopCore"], swiftSettings: concurrency),
        .testTarget(name: "LabKitTests", dependencies: ["LabKit"], swiftSettings: concurrency)
    ]
)
