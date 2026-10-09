// swift-tools-version: 6.0
//
// CellKeeperKit — the non-UI part of CellKeeper.
//
// - CellKeeperCore: platform-neutral domain logic (telemetry model, settings
//   validation, charging policy state machine, controller, backend protocol,
//   simulated, read-only and native Charge Limit backends). No IOKit, no
//   hardware access.
// - CellKeeperKit: macOS system adapters (read-only IOKit telemetry,
//   power-source notifications, the `shortcuts` and `pmset` runners, and the
//   Charge Limit record file). Depends on CellKeeperCore.
// - CellKeeperHelperCore: the logic of the future privileged helper (the
//   wire vocabulary shared with the app, and the helper engine: sessions,
//   per-control leases, rate limits, interlocks), with a simulated control.
//   Foundation only; no IOKit, XPC, processes, files or network. Depends on
//   nothing, and nothing uses it yet.

import PackageDescription

let package = Package(
    name: "CellKeeperKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CellKeeperCore", targets: ["CellKeeperCore"]),
        .library(name: "CellKeeperKit", targets: ["CellKeeperKit"]),
        .library(name: "CellKeeperHelperCore", targets: ["CellKeeperHelperCore"]),
    ],
    targets: [
        .target(name: "CellKeeperCore"),
        .target(
            name: "CellKeeperKit",
            dependencies: ["CellKeeperCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "CellKeeperHelperCore"),
        .testTarget(name: "CellKeeperCoreTests", dependencies: ["CellKeeperCore"]),
        .testTarget(name: "CellKeeperKitTests", dependencies: ["CellKeeperKit"]),
        .testTarget(name: "CellKeeperHelperCoreTests", dependencies: ["CellKeeperHelperCore"]),
    ]
)
