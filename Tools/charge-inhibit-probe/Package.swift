// swift-tools-version: 6.0
//
// charge-inhibit-probe — a standalone, owner-run test of one of Apple's
// private power assertions, `DisableInflow` (research note 10,
// docs/research/10-disable-inflow-probe.md) or `ChargeInhibit` (note 09,
// docs/research/09-charge-inhibit-probe.md), chosen with `--assertion`;
// and the observer of research note 11's manual adapter cut
// (docs/research/11-smc-adapter-cut.md), chosen with
// `--mechanism manual-adapter-cut`, in which the owner writes the SMC key
// by hand with an external tool. The probe never touches the SMC and never
// runs that tool.
//
// Not part of the CellKeeper app, its Xcode project or CellKeeperKit, and
// never shipped. No third-party dependencies.
//
// - ProbeCore: pure logic, Foundation only: samples, the verdict function,
//   the precondition rules, parsers for `pmset -g battlimit` and
//   `pmset -g assertions` output, report formatting, the sleep and
//   teardown decisions, the sleep queue and the console guard that keeps
//   it from blocking, the emergency exit's one write to the report file
//   descriptor it is given, and the manual adapter cut's questions, marks
//   and endings as a pure state machine, with the session, console writer,
//   terminal input and report file `watch` runs it with. No IOKit, no
//   processes, and it opens no file but the report file `watch` names.
//   This is what the tests exercise.
// - ProbeAtomics: a sequence number and a time, recorded and read with C11
//   atomics: `watch`'s sleep latch, which the sleep notification records
//   into without a lock (the package targets macOS 14, before Swift's
//   Synchronization module).
// - charge-inhibit-probe: the executable. `check` reads public
//   IOPowerSources data (including the adapter's presence and wattage),
//   AppleSmartBattery registry properties, two `pmset -g` getters,
//   `launchctl print` for AlDente's helper service, and the process table's
//   executable paths and names, and changes nothing. `run` (root only,
//   started by the owner with sudo) additionally registers for system sleep
//   notifications (`IORegisterForSystemPower`), holds one public
//   `PreventUserIdleSystemSleep` assertion for the run, and creates and
//   releases one private assertion with a timeout. `watch --mechanism
//   manual-adapter-cut` (the owner, never as root, from a terminal) makes
//   `check`'s reads, registers for sleep notifications, holds one public
//   idle-sleep assertion, and asks the owner, on the terminal, for the tool
//   commands' results; it reads no SMC key and starts no process.

import PackageDescription

let package = Package(
    name: "charge-inhibit-probe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "charge-inhibit-probe", targets: ["charge-inhibit-probe"]),
    ],
    targets: [
        .target(name: "ProbeAtomics"),
        .target(name: "ProbeCore", dependencies: ["ProbeAtomics"]),
        .executableTarget(
            name: "charge-inhibit-probe",
            dependencies: ["ProbeCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
    ]
)
