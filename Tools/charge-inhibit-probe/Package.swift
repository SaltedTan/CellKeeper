// swift-tools-version: 6.0
//
// charge-inhibit-probe — a standalone, owner-run test of one of Apple's
// private power assertions, `DisableInflow` (research note 10,
// docs/research/10-disable-inflow-probe.md) or `ChargeInhibit` (note 09,
// docs/research/09-charge-inhibit-probe.md), chosen with `--assertion`.
//
// Not part of the CellKeeper app, its Xcode project or CellKeeperKit, and
// never shipped. No third-party dependencies.
//
// - ProbeCore: pure logic, Foundation only: samples, the verdict function,
//   the precondition rules, parsers for `pmset -g battlimit` and
//   `pmset -g assertions` output, report formatting, the sleep and
//   teardown decisions, the sleep queue and the console guard that keeps
//   it from blocking, and the emergency exit's one write to the report
//   file descriptor it is given. No IOKit, no processes, and it opens no
//   files. This is what the tests exercise.
// - charge-inhibit-probe: the executable. `check` reads public
//   IOPowerSources data (including the adapter's presence and wattage),
//   AppleSmartBattery registry properties, two `pmset -g` getters,
//   `launchctl print` for AlDente's helper service, and the process table's
//   executable paths and names, and changes nothing. `run` (root only,
//   started by the owner with sudo) additionally registers for system sleep
//   notifications (`IORegisterForSystemPower`), holds one public
//   `PreventUserIdleSystemSleep` assertion for the run, and creates and
//   releases one private assertion with a timeout.

import PackageDescription

let package = Package(
    name: "charge-inhibit-probe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "charge-inhibit-probe", targets: ["charge-inhibit-probe"]),
    ],
    targets: [
        .target(name: "ProbeCore"),
        .executableTarget(
            name: "charge-inhibit-probe",
            dependencies: ["ProbeCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
    ]
)
