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
//   Charge Limit record file, the helper's read-only power reading for the
//   Simulated helper, and the NSXPC helper transport). Depends on
//   CellKeeperCore, CellKeeperHelperCore and CellKeeperHelperXPC.
// - CellKeeperHelperCore: the logic of the privileged helper (the wire
//   vocabulary shared with the app, and the helper engine: sessions,
//   per-control leases, rate limits, interlocks), with a simulated control.
//   Foundation only; no IOKit, XPC, processes, files or network. Depends on
//   nothing. The app runs it in process for the Simulated helper.
// - CellKeeperHelperXPC: the NSXPC transport between the app and the helper
//   daemon: the `@objc` protocol, the listener side (`HelperXPCServer`), the
//   client side (`HelperXPCClient`), and the code-signing requirements both
//   sides place on each other. Public Foundation and Security APIs only.
//   Depends on CellKeeperHelperCore.
// - CellKeeperHelperDaemon: the host of the helper daemon (start, ticks,
//   SIGTERM, acknowledged sleep, its own read-only power reading, the
//   activation history file, the audit log) and its NSXPC frontend. Depends
//   on CellKeeperHelperCore and CellKeeperHelperXPC, never on the app's
//   modules.
// - CellKeeperHelper: the daemon executable. It controls no hardware
//   (`UnknownHardwareChargeControl`), serves CellKeeper over the
//   authenticated NSXPC transport, and is neither installed nor embedded in
//   the app in this phase.

import PackageDescription

let package = Package(
    name: "CellKeeperKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CellKeeperCore", targets: ["CellKeeperCore"]),
        .library(name: "CellKeeperKit", targets: ["CellKeeperKit"]),
        .library(name: "CellKeeperHelperCore", targets: ["CellKeeperHelperCore"]),
        .library(name: "CellKeeperHelperXPC", targets: ["CellKeeperHelperXPC"]),
        .executable(name: "CellKeeperHelper", targets: ["CellKeeperHelper"]),
    ],
    targets: [
        .target(name: "CellKeeperCore", dependencies: ["CellKeeperHelperCore"]),
        .target(
            name: "CellKeeperKit",
            dependencies: ["CellKeeperCore", "CellKeeperHelperCore", "CellKeeperHelperXPC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "CellKeeperHelperCore"),
        .target(name: "CellKeeperHelperXPC", dependencies: ["CellKeeperHelperCore"]),
        .target(
            name: "CellKeeperHelperDaemon",
            dependencies: ["CellKeeperHelperCore", "CellKeeperHelperXPC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "CellKeeperHelper", dependencies: ["CellKeeperHelperDaemon"]),
        .testTarget(name: "CellKeeperCoreTests", dependencies: ["CellKeeperCore", "CellKeeperHelperCore"]),
        .testTarget(name: "CellKeeperKitTests", dependencies: ["CellKeeperKit", "CellKeeperHelperCore", "CellKeeperHelperXPC"]),
        .testTarget(name: "CellKeeperHelperCoreTests", dependencies: ["CellKeeperHelperCore"]),
        .testTarget(name: "CellKeeperHelperXPCTests", dependencies: ["CellKeeperHelperXPC", "CellKeeperHelperCore"]),
        .testTarget(name: "CellKeeperHelperDaemonTests", dependencies: ["CellKeeperHelperDaemon", "CellKeeperHelperCore", "CellKeeperHelperXPC"]),
    ]
)
