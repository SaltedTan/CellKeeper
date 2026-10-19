// swift-tools-version: 6.0
//
// charge-inhibit-probe — a standalone, owner-run test of Apple's private
// `ChargeInhibit` power assertion (research note 09,
// docs/research/09-charge-inhibit-probe.md).
//
// Not part of the CellKeeper app, its Xcode project or CellKeeperKit, and
// never shipped. No third-party dependencies.
//
// - ProbeCore: pure logic, Foundation only: samples, the verdict function,
//   the precondition rules, parsers for `pmset -g battlimit` and
//   `pmset -g assertions` output, and report formatting. No IOKit, no
//   processes, no files. This is what the tests exercise.
// - charge-inhibit-probe: the executable. `check` reads public
//   IOPowerSources data, AppleSmartBattery registry properties, two
//   `pmset -g` getters, `launchctl print` for AlDente's helper service, and
//   the process table's executable paths and names, and changes nothing.
//   `run` (root only, started by the owner with sudo) additionally creates
//   and releases one `ChargeInhibit` assertion with a timeout.

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
