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

### 2. Safety

Read [docs/safety.md](docs/safety.md). In particular:

- **No hardware writes** (SMC, IOUserClient, privileged power assertions,
  `pmset` changes) without a design issue that has been discussed and
  approved first.
- **Never probe unknown keys by writing values**, even locally.
- Charging policy code (`CellKeeperCore`) must not import IOKit or call any
  hardware or private interface. System access belongs in `CellKeeperKit` or
  behind a `ChargingBackend`.
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
| `Packages/CellKeeperKit/Sources/CellKeeperCore/` | Pure domain logic: policy, controller, settings, backend protocol and backends (simulated, read-only, native Charge Limit) |
| `Packages/CellKeeperKit/Sources/CellKeeperKit/` | macOS adapters (read-only telemetry, notifications, the `shortcuts` and `pmset` runners, the Charge Limit record file) |
| `Packages/CellKeeperKit/Tests/` | Swift Testing tests |
| `Config/` | xcconfig files and entitlements |
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
