# CellKeeper architecture

Status: milestone 1 (telemetry + policy engine + simulated control). Last reviewed 2026-10-06.

This document describes how CellKeeper is put together and why. Research that
informed these decisions is in [`docs/research/`](research/README.md); safety
rules are in [`docs/safety.md`](safety.md).

## Principles

1. **Policy is pure.** The charging policy is a deterministic function of
   explicit inputs. It never touches hardware, IOKit, the clock, or private
   interfaces, so every rule is unit-testable without a Mac battery.
2. **Control is a narrow, swappable boundary.** All charging control goes
   through the `ChargingBackend` protocol. Today the only implementations are
   a simulated backend and a read-only backend. Anything that touches
   undocumented or privileged interfaces will live behind this protocol (and,
   for root operations, behind a separate helper process).
3. **Fail toward macOS defaults.** The only "safe state" is `.normal`: macOS
   and firmware decide charging. Missing data, invalid settings, backend
   errors, quitting, and unplugging all converge on it.
4. **Honest state.** Simulated actions are reported as simulated, refused
   actions as refused, and what macOS reports is shown separately from what
   CellKeeper wants.
5. **Minimal machinery.** No third-party dependencies, no dependency
   injection framework, two modules plus the app.

## Modules

```
┌──────────────────────────── CellKeeper.app (SwiftUI, MainActor) ────────────────────────────┐
│  CellKeeperApp / AppDelegate   MenuBarView   SettingsView   Presentation (wording)           │
│  AppModel: owns the controller, ordered command queue, notifications, sleep/wake, quit path  │
└───────────────┬──────────────────────────────────────────────────────────────┬───────────────┘
                │ uses                                                         │ uses
┌───────────────▼──────────────── CellKeeperKit (macOS adapters) ──────────────┐│
│  SystemTelemetryProvider   – IOPowerSources + allowlisted AppleSmartBattery   ││
│                              registry reads (read-only, sandbox-safe)         ││
│  BatteryTelemetryParser    – pure dictionary → BatterySnapshot (fixtures)     ││
│  PowerSourceNotifications  – notify(3) on the public IOPS notification names  ││
└───────────────┬──────────────────────────────────────────────────────────────┘│
                │ depends on                                                    │
┌───────────────▼──────────────── CellKeeperCore (pure Swift, no IOKit) ────────▼───────────────┐
│  Telemetry:  BatterySnapshot, BatteryHealth, TelemetryProvider (protocol)                      │
│  Settings:   ChargingSettings (+ validation), SettingsStore (UserDefaults JSON)                │
│  Policy:     ChargingPolicy (pure state machine), PolicyInput/Decision/Memory, ChargeOverride  │
│  Control:    ChargingBackend (protocol), MockChargingBackend, ReadOnlyChargingBackend          │
│  Controller: ChargeController (actor: telemetry → policy → backend, safety fallbacks, log)     │
│  Support:    CellKeeperLog (os.Logger categories)                                              │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `Packages/CellKeeperKit` is a local Swift package (tools version 6.0, Swift
  6 language mode, macOS 14+) with two library products and two test targets.
  `swift test` runs every non-UI test without opening Xcode.
- `CellKeeper.xcodeproj` contains only the app target. It uses a
  file-system-synchronized group for `CellKeeper/`, so adding a Swift file
  needs no project edits. The project file format is pinned to
  `objectVersion = 77` (Xcode 16+); CI fails if a newer Xcode rewrites it.
- The boundary is enforced by dependency direction: `CellKeeperCore` cannot
  import `CellKeeperKit`, so policy code cannot reach IOKit.

Requirement → location:

| Concern | Where | Status |
|---|---|---|
| Telemetry | `TelemetryProvider` (Core), `SystemTelemetryProvider` (Kit) | Implemented, read-only |
| Hardware/control backend | `ChargingBackend` (Core) | Simulated + read-only only |
| Charging policy & state machine | `ChargingPolicy` (Core) | Implemented |
| Orchestration & safety fallbacks | `ChargeController` (Core) | Implemented |
| Persistence/settings | `ChargingSettings`, `SettingsStore` (Core) | Implemented |
| macOS UI | `CellKeeper/` app target | Implemented (menu bar + settings) |
| Scheduler | — | Future: will feed overrides into `PolicyInput` |
| Notifications | — | Future: driven from `ControlEvent`s |
| Shortcuts/automation | — | Future: App Intents calling `AppModel` intents |
| Privileged operations | — | Future: `CellKeeperHelper` behind a backend |

## Data flow

```
 notify(3) power events ─┐
 60 s timer ─────────────┤
 wake (+35 s re-read) ───┤      AppModel (MainActor)            ChargeController (actor, serialized)
 will-sleep ─────────────┼──▶  ordered command queue  ──────▶  1. read telemetry snapshot
 user intents ───────────┘     (AsyncStream, 1 consumer)        2. backend.capabilities(), currentMode()
                                                                3. ChargingPolicy.evaluate(input)   ← pure
                                         ◀── ControllerStatus   4. execute action via backend
                                                                5. read back, record outcome/events
```

- **Ordering.** The app sends every evaluation, settings change, override and
  backend switch through one `AsyncStream` with a single consumer, so commands
  apply in the order the user issued them. Inside the controller an async
  lock serializes evaluations and backend calls, so two evaluations can never
  interleave backend requests (covered by a test).
- **Slider safety.** The charge-limit slider commits on release, so dragging
  never produces a burst of control requests.
- **Quit.** `applicationShouldTerminate` returns `.terminateLater`, restores
  `.normal` off the main actor, and replies through
  `RunLoop.main.perform(inModes: [.common])`. This avoids a deadlock when
  `terminate(_:)` is called from inside a main-actor job. The 3 s bound only
  limits how long quitting *waits*; it cannot complete a hung backend call
  (see "Known limitations").
- **Time.** Wall-clock time is used for telemetry age and display. Override
  expiry and rate limiting use a monotonic clock (`ContinuousClock`, which
  keeps counting during sleep), so changing the system clock cannot extend a
  temporary override or block restrictions.

## Charging policy

`ChargingPolicy.evaluate(_:)` maps a `PolicyInput` (wall time, monotonic
uptime, settings, snapshot, active override, backend capabilities, backend's
current mode, policy memory, fault flag, recent restricting requests,
sleep-imminent flag) to a `PolicyDecision` (state, desired mode, action,
reason, notes, next memory, override end).

### Memory: three hysteresis latches

The policy's only memory is `PolicyMemory`:

- `limitReached` — set when charge ≥ limit, cleared when charge ≤ resume
  threshold, unchanged in between (the hysteresis band). Never set when the
  limit is 100%.
- `temperatureTripped` — set at ≥ pause temperature, cleared at ≤ resume
  temperature, and cleared when temperature is unknown so a lost sensor can
  never hold charging off.
- `belowSafetyFloor` — set at ≤ 10%, cleared at ≥ 15%.

### Overrides

Two one-shot overrides exist, and at most one is active. Both always expire
(monotonic clock, default 12 h for a full charge and 6 h for a discharge,
clamped to 1–48 h) and both end when external power is disconnected. Expiry
and unplugging are processed before telemetry validation, so they take effect
even when the charge reading is unusable.

- **Temporary full charge** — ends at 100% or when macOS reports fully
  charged.
- **Discharge to limit** — a confirmed, one-shot session (never a persistent
  setting). Ends at the limit, and is interrupted before sleep, on temperature
  pause, on lost or stale telemetry, when the backend cannot discharge, or if
  the limit is outside 20–95%. After it ends it never restarts by itself.

### Precedence (highest first)

| # | Condition | State | Desired mode |
|---|---|---|---|
| 1 | Settings invalid | `failSafe` | normal |
| 2 | Management disabled | `unmanaged` | normal |
| 3 | No/stale telemetry (by read time, or by the driver's own update time > 180 s), future timestamps, no battery, unknown % or power source | `failSafe` | normal (a discharge session is interrupted) |
| 4 | Safety floor latched | `safetyFloor` | normal |
| 5 | On battery power | `onBattery` | normal (restrictions cleared; limit latch kept) |
| 6 | Temperature latch set | `temperaturePause` | inhibitCharging |
| 7 | Temporary full charge active | `fullChargeOverride` | normal |
| 8 | Discharge session active | `discharging` | forceDischarge |
| 9 | Limit is 100% | `charging` | normal |
| 10 | Limit latch set | `holding` | inhibitCharging |
| 11 | Sleep imminent and charge ≥ resume threshold | `holding` | inhibitCharging |
| 12 | Otherwise | `charging` | normal |

### From desired mode to action

| Situation | Action |
|---|---|
| Backend unavailable, desired `.normal`, current mode normal/unknown | `noAction` |
| Backend unavailable otherwise | `refuse(.controlUnavailable)` |
| Backend faulted and current mode not confirmed `.normal` (including unknown) | `enableCharging` (active recovery) |
| Backend faulted, current mode `.normal`, desired ≠ `.normal` | `refuse(.backendFaulted)` |
| Mode not supported | `refuse(.modeUnsupported)` |
| Current mode == desired | `noAction` |
| Restricting change within 60 s of the last one, or ≥ 20 in the past hour | `refuse(.rateLimited(retryAt:))` |
| Otherwise | `enableCharging` / `disableCharging` / `requestDischarge` |

"Restricting" means moving further from macOS defaults
(normal → inhibit → discharge). Relaxing changes toward `.normal` are never
rate-limited or blocked by a fault. (Research rule R13 caps *all* non-safety
transitions; CellKeeper deliberately counts only restricting ones, treating
every relaxing change as a safety-direction change. Total transitions are
therefore at most about twice the restricting budget.)

## Control backend contract

```swift
public protocol ChargingBackend: Sendable {
    var descriptor: BackendDescriptor { get }
    func capabilities() async -> ControlCapabilities     // availability + supported modes
    func currentMode() async throws -> ChargeControlMode? // nil = unknown
    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome
}
```

- `ChargeControlMode`: `normal` (fail-safe), `inhibitCharging`,
  `forceDischarge`.
- `ControlAvailability`: `available` (verified real control), `experimental`
  (real, unverified, opt-in only), `simulated`, `unavailable(reason)`. The UI
  shows exactly these four states.
- `ControlOutcome`: `applied` (hardware changed and confirmed) or `simulated`.
  Simulated backends must never return `applied`, and `setMode` must throw
  rather than return when the requested state was not reached.
- `.normal` must always be accepted by a backend that accepts requests.
- A backend that accepts requests must report its mode. `nil` ("unknown") or
  an error from `currentMode()` counts as a failure.

The controller adds, independent of the backend:

- one FIFO lock around every public command (no barging), so commands and
  backend requests never interleave and each returned status reflects one
  complete operation;
- read-back after every request: an error, `nil`, or a mismatch is a
  failure, and nothing unconfirmed is reported as applied;
- an immediate, read-back-confirmed request for `.normal` after any failed
  non-normal request;
- mode-read failures count as failures;
- external-change detection: if the backend's mode differs from the mode
  CellKeeper last confirmed, another tool may be in control, so the backend is
  faulted at once (research rule R27);
- a fault after 3 consecutive failures. While faulted, `.normal` is actively
  requested until confirmed, nothing else is requested, and the fault
  persists until the user clears it, even if recovery succeeds;
- `.normal`, confirmed, before switching backends. If it cannot be confirmed,
  the switch is refused and the old backend stays responsible for recovery;
- `.normal` on quit;
- a bounded in-memory activity log mirrored to unified logging.

Implementations today:

| Backend | Availability | Behaviour |
|---|---|---|
| `MockChargingBackend` (default) | `simulated` | Records requests, tracks a simulated mode, supports failure injection for tests. Never touches hardware. |
| `ReadOnlyChargingBackend` | `unavailable` | Accepts nothing; CellKeeper still computes and shows what it would do. |

## Future control backends

Research ([02](research/02-charging-control-apple-silicon.md)) found no public
API to inhibit charging or force discharge. Third-party reports (unverified)
say the SMC keys other tools used have been progressively closed off, with
macOS 27 firmware reportedly gating most of them even for root. The
candidates, in the order we intend to evaluate them:

1. **Delegated native limit.** Apple documents a built-in Charge Limit
   (80–100%) on macOS 26.4+ with Apple silicon. Press reports describe a
   Shortcuts action to set it; whether an app can drive that action reliably
   is unverified. This is a different *style* of control: the OS enforces a
   limit rather than CellKeeper toggling charging. The current mode-based
   contract cannot express it, so it will need a small explicit extension:
   - a target percentage and the supported increments (80–100 in steps of 5);
   - ownership: record the user's own limit before changing it, and on
     release restore *that* value rather than mapping `.normal` to 100%;
   - confirmation semantics: a Shortcut finishing, or charging behaviour, is
     not a confirmed read-back of the setting.
   Public interfaces only, no root, no helper.
2. **Privileged helper (`CellKeeperHelper`).** Only if a verified mechanism
   exists that the native limit cannot provide (for example limits below 80%).
   Design (see [04](research/04-privileged-helper.md)): `SMAppService` launch
   daemon; XPC with code-signing requirements on both sides; a fixed set of
   typed operations (no raw keys, no command execution); a lease that restores
   `.normal` if not renewed, on client disconnect, at helper start, and on
   SIGTERM; per-model allowlist and read-back. The helper would expose itself
   to the app as another `ChargingBackend`. Apple's published power-management
   source releases its private charge-inhibit assertions when the owning
   process exits, which would be a valuable fail-safe, but whether that holds
   on shipping Apple silicon is unverified.

No code for either exists yet. Neither will be enabled without the hardware
verification protocol in research note 02 §7 and the rules in `safety.md`.

## Known limitations before any real control backend

The current controller is correct for simulated control; an independent
review identified these gaps that must be closed before a backend that
changes hardware is enabled:

- **Adapter-cut semantics.** Research reports that cutting the adapter makes
  macOS report battery power. The policy treats battery power as "unplugged",
  so it would end a discharge session immediately. That is safe (no cycling,
  because sessions never restart by themselves), but discharge would not
  work. Telemetry must first distinguish *physical* adapter presence from the
  effective power source.
- **Sleep and quit are not interlocks.** The app reacts to will-sleep and
  quit notifications, but cannot delay sleep until a request completes or
  finish a hung backend call. A privileged backend needs helper-owned sleep
  handling (`IORegisterForSystemPower` with acknowledgement), per-control
  leases that lapse to `.normal`, and bounded operations (XPC timeouts with
  connection invalidation).
- **Debounce and dwell** (research rules R14, R21) are not implemented.

## Telemetry

`SystemTelemetryProvider` combines:

- the documented IOPowerSources API (percentage, power source, charging and
  charged flags, time estimates, documented `Temperature` key) and
  `IOPSCopyExternalPowerAdapterDetails` (watts); and
- allowlisted properties of the `AppleSmartBattery` IORegistry entry (cycle
  count, design cycle count, voltage, amperage, mAh capacities). These reads
  use public IOKit registry functions, need no privileges, and work in the
  App Sandbox, but several key names are undocumented and moved between macOS
  26 and 27. The parser checks both the top level and the nested
  `BatteryData` dictionary, validates every value's type and range, and treats
  every field as optional.

Identifiers (serial numbers, lot codes, power source IDs, adapter serials) are
filtered out at read time and never logged. The registry `Temperature` key is
not read because its units are unverified; on macOS 27 no public battery
temperature source exists, and temperature protection reports itself as
unavailable.

## Persistence

`SettingsStore` stores `ChargingSettings` as versioned JSON in `UserDefaults`.
Decoding tolerates missing keys; decoded values are validated, and invalid or
corrupt data falls back to defaults with a visible notice. Invalid settings
are never saved. The selected backend is stored separately.

## Logging

`CellKeeperLog` defines `os.Logger` categories (`app`, `telemetry`, `policy`,
`backend`, `safety`, `settings`) under the app's bundle identifier. Telemetry
changes log at info level (memory only); decisions, requests, results,
settings changes, and safety fallbacks log at notice level or above so they
persist. Logged content is limited to battery state, settings values, and
decisions.

## Distribution and security posture

- Milestone 1 ships App-Sandboxed with Hardened Runtime and no other
  entitlements (verified: telemetry works fully inside the sandbox).
- Contributor builds are ad-hoc signed and need no Apple Developer account.
  Release builds carry the Hardened Runtime flag even when ad-hoc signed;
  Debug builds omit it so the debugger can attach.
- A privileged helper, if ever added, implies Developer ID distribution
  outside the Mac App Store, a non-sandboxed app, notarization, and
  code-signing-requirement-pinned XPC. See
  [05](research/05-distribution-and-signing.md).

## Decision log

| # | Decision | Rationale |
|---|---|---|
| D1 | Swift package for core + thin app project | Fast `swift test`, enforced dependency direction, no project churn for core files |
| D2 | Policy as a pure function with explicit memory | Determinism and exhaustive testing |
| D3 | Simulated backend is the default | Requirement; no verified public control mechanism exists |
| D4 | Control only on Apple silicon (future) | Intel Macs end at macOS 26, and no supported control exists there ([03](research/03-intel-differences.md)) |
| D5 | App Sandbox on for milestone 1 | All current functionality works sandboxed; revisit only if a helper is adopted |
| D6 | macOS 14 deployment target | Observation framework and `openSettings` need 14. The telemetry APIs exist on 14–27, but have been verified only on 27 |
| D7 | No third-party dependencies | Nothing needed; avoids licence and supply-chain review |
| D8 | Swift Testing | Modern, ships with Xcode 16+, works with plain `swift test` |
| D9 | Registry temperature not used | Units unverified; a wrong unit would silently weaken protection |
| D10 | Restrictions cleared on battery power | If CellKeeper dies while unplugged, the next plug-in charges normally |
| D11 | Discharge is a confirmed one-shot session, not a setting | A persistent "discharge above limit" setting could discharge a freshly topped-up battery or restart unattended (rule R20) |
| D12 | Monotonic clock for expiry and rate limits | Wall-clock changes must not extend overrides or block restrictions (rule R22) |
| D13 | Faults persist until the user clears them | Automatic recovery from a fault could hide a misbehaving backend and cycle restrictions |
