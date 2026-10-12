// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacHop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacHop", targets: ["MacHop"]),
        .executable(name: "machop-lab", targets: ["MacHopLab"])
    ],
    targets: [
        // Platform-free logic: routing, ownership, HID encoding, queueing.
        .target(name: "MacHopCore"),

        // Simulated iPhone HID host used by tests and the lab tool.
        .target(name: "VirtualPhone", dependencies: ["MacHopCore"]),

        // macOS adapters and UI. Everything here runs on the main thread.
        .target(
            name: "MacHopApp",
            dependencies: ["MacHopCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(name: "MacHop", dependencies: ["MacHopApp"]),

        // Physical-device lab: iPhone screen capture, analysis and automated experiments.
        .target(
            name: "LabKit",
            dependencies: ["MacHopCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision")
            ]
        ),
        .executableTarget(name: "MacHopLab", dependencies: ["LabKit", "VirtualPhone"], path: "Sources/machop-lab"),

        .testTarget(name: "MacHopCoreTests", dependencies: ["MacHopCore", "VirtualPhone"]),
        .testTarget(name: "MacHopAppTests", dependencies: ["MacHopApp", "MacHopCore"]),
        .testTarget(name: "LabKitTests", dependencies: ["LabKit"])
    ]
)
