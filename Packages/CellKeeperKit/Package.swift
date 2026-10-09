// swift-tools-version: 6.0
//
// CellKeeperKit — the non-UI part of CellKeeper.
//
// - CellKeeperCore: platform-neutral domain logic (telemetry model, settings
//   validation, charging policy state machine, controller, backend protocol,
//   simulated, read-only, native Charge Limit and helper backends, and the
//   in-process helper transport). No IOKit, no hardware access. Depends on
//   CellKeeperHelperCore.
// - CellKeeperKit: macOS system adapters (read-only IOKit telemetry,
//   power-source notifications, the `shortcuts` and `pmset` runners, the
//   Charge Limit record file, and the helper's read-only power reading for
//   the Simulated helper). Depends on CellKeeperCore and CellKeeperHelperCore.
// - CellKeeperHelperCore: the logic of the privileged helper (the wire
//   vocabulary shared with the app, and the helper engine: sessions,
//   per-control leases, rate limits, interlocks), with a simulated control.
//   Foundation only; no IOKit, XPC, processes, files or network. Depends on
//   nothing. The app runs it in process for the Simulated helper.

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
        .target(name: "CellKeeperCore", dependencies: ["CellKeeperHelperCore"]),
        .target(
            name: "CellKeeperKit",
            dependencies: ["CellKeeperCore", "CellKeeperHelperCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "CellKeeperHelperCore"),
        .testTarget(name: "CellKeeperCoreTests", dependencies: ["CellKeeperCore", "CellKeeperHelperCore"]),
        .testTarget(name: "CellKeeperKitTests", dependencies: ["CellKeeperKit", "CellKeeperHelperCore"]),
        .testTarget(name: "CellKeeperHelperCoreTests", dependencies: ["CellKeeperHelperCore"]),
    ]
)
