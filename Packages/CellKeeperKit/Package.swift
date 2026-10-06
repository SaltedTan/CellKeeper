// swift-tools-version: 6.0
//
// CellKeeperKit — the non-UI part of CellKeeper.
//
// - CellKeeperCore: platform-neutral domain logic (telemetry model, settings
//   validation, charging policy state machine, controller, backend protocol,
//   mock/read-only backends). No IOKit, no hardware access.
// - CellKeeperKit: macOS system adapters (read-only IOKit telemetry and
//   power-source notifications). Depends on CellKeeperCore.

import PackageDescription

let package = Package(
    name: "CellKeeperKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CellKeeperCore", targets: ["CellKeeperCore"]),
        .library(name: "CellKeeperKit", targets: ["CellKeeperKit"]),
    ],
    targets: [
        .target(name: "CellKeeperCore"),
        .target(
            name: "CellKeeperKit",
            dependencies: ["CellKeeperCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "CellKeeperCoreTests", dependencies: ["CellKeeperCore"]),
        .testTarget(name: "CellKeeperKitTests", dependencies: ["CellKeeperKit"]),
    ]
)
