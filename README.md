# Cell Keeper

[![CI](https://github.com/SaltedTan/CellKeeper/actions/workflows/ci.yml/badge.svg)](https://github.com/SaltedTan/CellKeeper/actions/workflows/ci.yml)

Cell Keeper is an open-source macOS menu-bar app for transparent, safety-first
battery charge management on Mac laptops. It shows what your battery is
doing, lets you set a charge limit with a resume threshold, and explains
exactly what it would do — and whether it can actually do it.

> **Cell Keeper is an independent open-source project and is not affiliated
> with Apple, AppHouseKitchen, AlDente, or their respective developers.**

## Status: early development (milestone 1)

Cell Keeper is **pre-alpha**. The architecture, telemetry, and charging policy
engine work. **Real charging control does not exist yet**: the app runs
with a *simulated* control backend that records decisions without changing
your Mac's charging.

| Feature | State |
|---|---|
| Battery %, power source, charging state | **Real** — public IOPowerSources API |
| Cycle count, voltage, current, mAh capacities | **Real** — read-only IORegistry properties (some undocumented) |
| Adapter wattage | **Real** — public API |
| Battery temperature | **Not available** on macOS 27 through any public interface; shown as unavailable |
| Battery health / condition as shown by macOS | **Not available** to third-party apps; Cell Keeper shows its own computed capacity ratio, labelled as such |
| Charge limit + resume threshold (hysteresis) | **Policy real, control simulated** |
| Temporary charge to 100% | **Policy real, control simulated** |
| Temperature protection | **Policy real**; cannot trigger without a temperature reading |
| Discharge to limit while plugged in | **Policy real, control simulated**; a confirmed one-shot session, never automatic |
| Hardware charging control | **Not implemented** — see [roadmap](docs/roadmap.md) |
| Scheduling, calibration, notifications, Shortcuts, launch at login | Planned |

The menu bar always shows which kind of control is in effect: **Available**,
**Experimental**, **Simulated**, or **Unavailable**.

### Why no real control yet?

Apple provides no public API to stop or limit charging. macOS 26.4 and later
on Apple silicon include a built-in **Charge Limit** (80–100%, System
Settings › Battery), which is the only supported mechanism. Older approaches
used by other tools rely on undocumented hardware keys that Apple has
progressively locked down. Cell Keeper will add control only through verified,
documented-as-far-as-possible mechanisms, with the fail-safe rules in
[docs/safety.md](docs/safety.md). The details are in
[docs/research/](docs/research/README.md).

The next milestone builds on macOS's native Charge Limit (80–100%). Limits
below 80% need private, privileged mechanisms and are a separate, gated step
on the [roadmap](docs/roadmap.md).

## Requirements

- **To run:** macOS 14 Sonoma or later. Telemetry has been verified on an
  Apple silicon MacBook Pro running macOS 27; other models and versions are
  expected to work but are unverified. Intel Macs can show telemetry, but
  Cell Keeper will not offer charge control on Intel.
- **To build:** Xcode 16.0 or later (Swift 6). No Apple Developer account and
  no third-party dependencies are needed.

## Build and run

```sh
git clone https://github.com/SaltedTan/CellKeeper.git
cd CellKeeper
open CellKeeper.xcodeproj        # then choose the CellKeeper scheme and Run
```

Or from the command line:

```sh
xcodebuild -project CellKeeper.xcodeproj -scheme CellKeeper -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
open ".build/DerivedData/Build/Products/Debug/Cell Keeper.app"
```

The app appears in the menu bar (no Dock icon). Builds are ad-hoc signed
("Sign to Run Locally"). To use your own bundle identifier or signing team,
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored)
and edit it. The bundle identifier is `io.github.saltedtan.CellKeeper`; forks
that distribute their own builds should use their own prefix.

## Test

```sh
swift test --package-path Packages/CellKeeperKit
```

This runs all core and telemetry tests (Swift Testing). The tests are
deterministic and need no battery; one smoke test reads the real system's
power information read-only. In Xcode, ⌘U on the `CellKeeper` scheme runs the
same tests.

To see Cell Keeper's decisions in the unified log:

```sh
log stream --level info --predicate 'subsystem == "io.github.saltedtan.CellKeeper"'
```

## Architecture

```
Cell Keeper.app (SwiftUI menu bar, settings)
  └── CellKeeperKit   macOS adapters: read-only IOKit telemetry, power notifications
        └── CellKeeperCore   pure Swift: settings validation, charging policy
                             state machine, controller, backend protocol,
                             simulated and read-only backends
```

- The **charging policy** is a pure, deterministic function: telemetry +
  settings + backend capabilities → desired mode + explicit action
  (enable charging, disable charging, request discharge, no action, or
  refuse with a reason). It never touches hardware.
- All control goes through the **`ChargingBackend`** protocol. Simulated
  backends report actions as *simulated*, never as applied.
- Every failure path returns to **macOS default charging**.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Safety

Battery charging is hardware-adjacent. Cell Keeper is designed to fail toward
macOS's default behaviour, validates every setting, logs every change in its
decisions and every control request, and
never writes to hardware in this version. Your Mac's built-in battery
protections always remain in effect. Read [docs/safety.md](docs/safety.md)
before contributing anything that could change charging behaviour.

**Disclaimer:** Cell Keeper is experimental software provided under the
Apache License 2.0, without warranty of any kind. Future control features may
depend on undocumented interfaces that Apple can change at any time. Use at
your own risk.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md),
including the clean-room rules: Cell Keeper must not contain code, assets,
text, or implementation details taken from other battery applications.
Security issues: see [SECURITY.md](SECURITY.md). Everyone participating is
expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Licence

Cell Keeper is licensed under the [Apache License, Version 2.0](LICENSE).
The Code of Conduct is adapted from the Contributor Covenant 3.0 and is
licensed under CC BY-SA 4.0.
