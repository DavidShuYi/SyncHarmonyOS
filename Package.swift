// swift-tools-version:5.10
// SyncHarmonyOS — macOS ↔ HarmonyOS/Android USB file transfer (MTP).
import PackageDescription

let package = Package(
    name: "SyncHarmonyOS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SyncHarmonyCore", targets: ["SyncHarmonyCore"]),
        .executable(name: "SyncHarmonyOS", targets: ["SyncHarmonyOSApp"]),
        .executable(name: "syncharmony", targets: ["SyncHarmonyCLI"])
    ],
    targets: [
        // Thin C wrapper over the legacy IOKit/IOUSBLib CFPlugin user clients.
        // The function-pointer tables in IOUSBLib.h are not importable from Swift.
        .target(
            name: "CUSBShim",
            path: "Sources/CUSBShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "SyncHarmonyCore",
            dependencies: ["CUSBShim"],
            path: "Sources/SyncHarmonyCore"
        ),
        .executableTarget(
            name: "SyncHarmonyCLI",
            dependencies: ["SyncHarmonyCore"],
            path: "Sources/SyncHarmonyCLI"
        ),
        .executableTarget(
            name: "SyncHarmonyOSApp",
            dependencies: ["SyncHarmonyCore"],
            path: "Sources/SyncHarmonyOSApp"
        ),
        .testTarget(
            name: "SyncHarmonyCoreTests",
            dependencies: ["SyncHarmonyCore"],
            path: "Tests/SyncHarmonyCoreTests"
        )
    ]
)
