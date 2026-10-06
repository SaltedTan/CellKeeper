# CellKeeper

[![CI](https://github.com/SaltedTan/CellKeeper/actions/workflows/ci.yml/badge.svg)](https://github.com/SaltedTan/CellKeeper/actions/workflows/ci.yml)

CellKeeper is an open-source macOS menu-bar app for transparent, safety-first
battery charge management on Mac laptops. It shows what your battery is
doing, lets you set a charge limit with a resume threshold, and explains
exactly what it would do — and whether it can actually do it.

> **CellKeeper is an independent open-source project and is not affiliated
> with Apple, AppHouseKitchen, AlDente, or their respective developers.**

## Status: early development (milestone 2)

CellKeeper is **pre-alpha**. The architecture, telemetry, and charging policy
engine work. By default the app runs with a *simulated* control backend that
records decisions without changing your Mac's charging. The first real
control is opt-in and experimental: CellKeeper can set **macOS's own Charge
Limit** (80–100%) through a shortcut you create, and macOS enforces it.

| Feature | State |
|---|---|
| Battery %, power source, charging state | **Real** — public IOPowerSources API |
| Cycle count, voltage, current, mAh capacities | **Real** — read-only IORegistry properties (some undocumented) |
| Adapter wattage | **Real** — public API |
| Battery temperature | **Not available** on macOS 27 through any public interface; shown as unavailable |
| Battery health / condition as shown by macOS | **Not available** to third-party apps; CellKeeper shows its own computed capacity ratio, labelled as such |
| Charge limit 80/85/90/95/100% via macOS's Charge Limit | **Real, experimental, opt-in** (macOS 26.4+, Apple silicon); enforced by macOS; verified on one Mac |
| Charge limit + custom resume threshold (hysteresis) | **Policy real, control simulated** |
| Temporary charge to 100% | **Real** with macOS's Charge Limit; otherwise simulated |
| Temperature protection | **Policy real**; cannot trigger without a temperature reading; not available with macOS's Charge Limit |
| Discharge to limit while plugged in | **Policy real, control simulated**; a confirmed one-shot session, never automatic; not available with macOS's Charge Limit |
| Limits below 80%, or CellKeeper switching charging itself | **Not implemented** — see [roadmap](docs/roadmap.md) and [issue #1](https://github.com/SaltedTan/CellKeeper/issues/1) |
| Scheduling, calibration, notifications, Shortcuts actions for CellKeeper's own controls, launch at login | Planned |

The menu bar always shows which kind of control is in effect: **Available**,
**Experimental**, **Simulated**, or **Unavailable**.

### Why only macOS's Charge Limit?

Apple provides no public API to stop or limit charging. macOS 26.4 and later
on Apple silicon include a built-in **Charge Limit** (80–100%, System
Settings › Battery), which is the only supported mechanism. Older approaches
used by other tools rely on undocumented hardware keys that Apple has
progressively locked down. CellKeeper adds control only through verified,
documented-as-far-as-possible mechanisms, with the fail-safe rules in
[docs/safety.md](docs/safety.md). The details are in
[docs/research/](docs/research/README.md).

Limits below 80% need private, privileged mechanisms and are a separate,
gated step on the [roadmap](docs/roadmap.md).

## Using macOS's Charge Limit (experimental)

Requirements: macOS Tahoe 26.4 or later on a Mac with Apple silicon.

1. In the **Shortcuts** app, create a shortcut named exactly
   **CellKeeper Set Charge Limit**.
2. Search the actions for "charge limit" and add the one that reads **Set
   charge limit to …**. Set its value to **Shortcut Input**, so CellKeeper
   can pass a value from 80 to 100. Leave **Set Until Tomorrow** off.
3. Shortcuts then adds **Receive … from Nowhere** at the top, with **If
   there's no input: Continue**. Leave it as it is: CellKeeper passes the
   value from the command line, which does not need the Share sheet or
   Quick Actions.
4. In CellKeeper, open **Settings… › Control**, choose **macOS Charge Limit
   (through Shortcuts)**, and confirm.
5. Pick a limit (80, 85, 90, 95 or 100%) in the menu bar.

What happens:
- **Before its first change**, CellKeeper reads your current Charge Limit
  and records it durably. If macOS reports "no limit", CellKeeper first asks
  you to confirm that your limit is 100%.
- **It restores exactly that value** when you turn off **Manage charging**,
  switch backend, quit, or if anything fails, unless you have changed the
  limit yourself meanwhile (see below). If it cannot confirm the
  restore when quitting, it tells you which value to set, and it tries
  again the next time it starts.
- **Every change is confirmed** by reading the setting back from macOS.
  The read uses `pmset -g battlimit`, an undocumented, read-only report.
  If CellKeeper cannot read or recognise it, it sets no new limit; it still
  tries to give back your recorded limit, and treats that as unconfirmed
  until it reads it back.
- **Features macOS's Charge Limit cannot express are not offered:** a
  custom resume threshold (macOS resumes after a drop of more than 5%), the
  temperature pause, and discharging. Settings hides them and says so in
  one note.
- **If you change the limit in System Settings** while CellKeeper manages
  it, CellKeeper keeps your new value as your own limit, changes nothing,
  and turns off **Manage charging**. Turn it on again to let CellKeeper
  manage the limit; your new value is then the one it restores. CellKeeper
  cannot tell who changed the limit, so it does the same if another tool
  changes it.

You can always set the limit yourself in **System Settings › Battery › ⓘ
next to Charging**. See [docs/safety.md](docs/safety.md#getting-your-own-charge-limit-back).
The research behind this backend is in
[docs/research/08-native-charge-limit.md](docs/research/08-native-charge-limit.md).

## Requirements

- **To run:** macOS 14 Sonoma or later. Telemetry has been verified on an
  Apple silicon MacBook Pro running macOS 27; other models and versions are
  expected to work but are unverified. Intel Macs can show telemetry, but
  CellKeeper will not offer charge control on Intel.
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
open .build/DerivedData/Build/Products/Debug/CellKeeper.app
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

To see CellKeeper's decisions in the unified log:

```sh
log stream --level info --predicate 'subsystem == "io.github.saltedtan.CellKeeper"'
```

## Architecture

```
CellKeeper.app (SwiftUI menu bar, settings)
  └── CellKeeperKit   macOS adapters: read-only IOKit telemetry, power
                      notifications, the shortcuts and pmset runners, and the
                      record of your own Charge Limit
        └── CellKeeperCore   pure Swift: settings validation, charging policy
                             state machine, controller, backend protocol,
                             simulated, read-only and native Charge Limit
                             backends
```

- The **charging policy** is a pure, deterministic function: telemetry +
  settings + backend capabilities → desired mode + explicit action
  (enable charging, disable charging, request discharge, no action, or
  refuse with a reason). It never touches hardware. With macOS's Charge
  Limit it computes the limit macOS should enforce.
- All control goes through the **`ChargingBackend`** protocol. Simulated
  backends report actions as *simulated*, never as applied.
- Every failure path returns to **macOS default charging**. With macOS's
  Charge Limit, that means your own limit, exactly as recorded.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Safety

Battery charging is hardware-adjacent. CellKeeper is designed to fail toward
macOS's default behaviour, validates every setting, logs every change in its
decisions and every control request, and never writes to hardware itself in
this version. Its only real control, opt-in, is macOS's own Charge Limit,
which macOS enforces. Your Mac's built-in battery
protections always remain in effect. Read [docs/safety.md](docs/safety.md)
before contributing anything that could change charging behaviour.

**Disclaimer:** CellKeeper is experimental software provided under the
Apache License 2.0, without warranty of any kind. Future control features may
depend on undocumented interfaces that Apple can change at any time. Use at
your own risk.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md),
including the clean-room rules: CellKeeper must not contain code, assets,
text, or implementation details taken from other battery applications.
Security issues: see [SECURITY.md](SECURITY.md). Everyone participating is
expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Licence

CellKeeper is licensed under the [Apache License, Version 2.0](LICENSE).
The Code of Conduct is adapted from the Contributor Covenant 3.0 and is
licensed under CC BY-SA 4.0.
