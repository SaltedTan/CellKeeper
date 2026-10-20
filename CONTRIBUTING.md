# Contributing to CellKeeper

Thank you for helping. CellKeeper touches battery charging, so we hold
contributions to a few rules that matter more here than in most apps. Please
read this whole page before opening a pull request.

## Ground rules

### 1. Clean-room development

CellKeeper is an independent implementation. Contributions must not include:

- source code, assets, icons, screenshots, text, UI layouts, or branding from
  other battery-management applications (open-source or proprietary);
- implementation details learned from other tools' source code, such as
  hardware key encodings, write sequences, or magic values;
- anything obtained by decompiling, disassembling, or string-dumping
  proprietary binaries — including Apple's;
- code whose licence or origin is unclear.

Public descriptions of *behaviour* may inform requirements. Prefer Apple
documentation, public SDK headers, Apple open source, hardware
documentation, and your own read-only observations. When you rely on a
third-party claim, cite it as a claim, not as fact.

**Exception (owner decision, 2026-10-20):** for CellKeeper's own charge
control on Apple silicon, contributors may use these facts from
OSI-licensed open-source projects: the name, type and size of the SMC
adapter-cut key `CHIE`, the values those projects write to it, and the
AppleSMC user-client interface needed to read and write one key. Each fact
is cited in `docs/research` with its source and licence and treated as a
third-party claim until verified on a test Mac. No code, comments or other
text is copied, and no project's implementation structure (its files,
types, functions or control flow); the wire-level facts needed to call the
interface (the parameter block's fields, sizes and offsets, and the
selector and command values) are used as facts. The implementation is
written independently. Not covered: AlDente or any other proprietary or
source-available tool, anything obtained from binaries, and any other key
or mechanism (each needs its own owner decision). The owner may also use
an OSI-licensed tool as an external test instrument, built and run outside
the repository; nothing from it enters the repository, and CellKeeper
never invokes it. Later on 2026-10-20 the owner also allowed one
owner-run, read-only read of the inhibit keys `CHTE`, `CH0B` and `CH0C`
by name, and decided not to use `CHIE` in CellKeeper (note 11 §2.3). This
is a project rule, not a legal opinion or a licence-compatibility review.
See
[docs/research/11-smc-adapter-cut.md](docs/research/11-smc-adapter-cut.md).

### 2. Safety

Read [docs/safety.md](docs/safety.md). In particular:

- **No hardware writes** (SMC, IOUserClient, privileged power assertions,
  `pmset` changes) without a design issue that has been discussed and
  approved first.
- **Never probe unknown keys by writing values**, even locally.
- Charging policy code (`CellKeeperCore`) must not import IOKit or call any
  hardware or private interface. System access belongs in `CellKeeperKit` or
  behind a `ChargingBackend`.
- The helper's logic (`CellKeeperHelperCore`) imports Foundation only: no
  IOKit, XPC, processes, files or network. Hardware access will live only
  behind `HelperChargeControl`.
- The helper daemon (`CellKeeperHelperDaemon`, `CellKeeperHelper`) depends on
  `CellKeeperHelperCore` only, never on the app's modules, and ships with
  `UnknownHardwareChargeControl`. Never install it, register it with
  launchd, or run it as root.
- Every failure path must return to macOS default charging.
- New policy behaviour needs deterministic tests.

### 3. Privacy

Never log, store, or include in issues: serial numbers, lot codes, power
source IDs, adapter serials, or other device identifiers.

## Development setup

Requirements: macOS 14+ and Xcode 16.0+. No Apple Developer account is
needed; builds are ad-hoc signed.

```sh
open CellKeeper.xcodeproj
swift test --package-path Packages/CellKeeperKit
```

Optional local signing overrides: copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` (git-ignored). Never commit team IDs, certificates,
provisioning profiles, or other credentials.

### Project layout

| Path | Contents |
|---|---|
| `CellKeeper/` | SwiftUI app (menu bar, settings, app model) |
| `Packages/CellKeeperKit/Sources/CellKeeperCore/` | Pure domain logic: policy, controller, settings, backend protocol and backends (simulated, read-only, native Charge Limit, helper), the in-process helper transport, and what to notify (the notification planner and its wording) |
| `Packages/CellKeeperKit/Sources/CellKeeperKit/` | macOS adapters (read-only telemetry, power-source notifications, the `shortcuts` and `pmset` runners, the Charge Limit record file, the saved diagnostics report, the helper's read-only power reading and the Simulated helper, and the local-notification poster) |
| `Packages/CellKeeperKit/Sources/CellKeeperHelperCore/` | Logic of the future privileged helper: wire vocabulary, the helper engine (leases, rate limits, interlocks), simulated and monitor-only controls. Foundation only, no hardware access; the app runs it in process for the Simulated helper |
| `Packages/CellKeeperKit/Sources/CellKeeperHelperDaemon/` | The helper daemon's host: start, ticks, SIGTERM, acknowledged sleep, its own read-only power reading, the activation history file and the audit log, each behind a protocol with a test fake. Depends on `CellKeeperHelperCore` only |
| `Packages/CellKeeperKit/Sources/CellKeeperHelper/` | The daemon executable (`main.swift`). No hardware control; not installed or embedded in this phase |
| `Packages/CellKeeperKit/Tests/` | Swift Testing tests |
| `Config/` | xcconfig files, entitlements, and the helper daemon's launchd property list (`LaunchDaemons/`, not installed) |
| `docs/` | Architecture, safety, roadmap, research |

New Swift files in `CellKeeper/` are picked up automatically (synchronized
folder); no project edits are needed. If Xcode offers to "upgrade" the project
format, decline: the project must stay at `objectVersion = 77` so Xcode 16
and 26 can open it (CI enforces this).

## Coding standards

- Swift 6 language mode with complete concurrency checking. No new warnings;
  CI treats warnings as errors on the reference toolchain.
- Prefer value types and pure functions; keep shared mutable state in actors
  or on the main actor.
- No third-party dependencies without prior discussion (licence and supply
  chain review).
- Keep comments for intent and constraints, not narration.
- Match the existing style; use `swift-format` defaults if unsure.

## Pull requests

1. Open an issue first for anything non-trivial, and always for anything that
   could change charging behaviour or needs privileges.
2. Keep changes focused; write a clear description and fill in the PR
   checklist.
3. Make sure `swift test --package-path Packages/CellKeeperKit` passes and the
   app builds without warnings.
4. Use clear commit messages (`area: summary`, e.g. `policy: clamp override
   duration`).

`main` is protected, and that includes maintainers. Every change lands
through a pull request. The branch must be up to date with `main`, and these
CI checks must pass: **Repository hygiene**, **macOS 26 / Xcode 26.6** and
**macOS 15 / Xcode 16.0**. Review threads must be resolved. The Xcode 27
preview job is informational only. Force-pushes to `main` and deleting it are
blocked, and merged branches are deleted automatically.

By contributing, you agree that your contributions are licensed under the
Apache License 2.0 (see [LICENSE](LICENSE)).

## Research contributions

Hardware observations are valuable. Use the "Hardware / telemetry
observation" issue form, record model identifier, macOS build, and firmware,
describe exactly how you observed something, and separate observation from
inference. Read-only methods only. See
[docs/research/README.md](docs/research/README.md) for the classification
legend.
