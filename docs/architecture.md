# CellKeeper architecture

Status: milestone 2 (telemetry + policy engine + simulated control + macOS's native Charge Limit). Last reviewed 2026-10-06.

This document describes how CellKeeper is put together and why. Research that
informed these decisions is in [`docs/research/`](research/README.md); safety
rules are in [`docs/safety.md`](safety.md).

## Principles

1. **Policy is pure.** The charging policy is a deterministic function of
   explicit inputs. It never touches hardware, IOKit, the clock, or private
   interfaces, so every rule is unit-testable without a Mac battery.
2. **Control is a narrow, swappable boundary.** All charging control goes
   through the `ChargingBackend` protocol. The implementations are a
   simulated backend, a read-only backend, and a backend that sets macOS's
   own Charge Limit through a user-created shortcut. Anything that touches
   undocumented or privileged interfaces lives behind this protocol (and,
   for root operations, would live behind a separate helper process).
3. **Fail toward macOS defaults.** The only "safe state" is `.normal`: macOS
   and firmware decide charging. Missing data, invalid settings, backend
   errors, quitting, and unplugging all converge on it. With the native
   Charge Limit, `.normal` means the user's own limit, exactly as it was
   before CellKeeper changed it.
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
│  ShortcutsCommandRunner    – documented `shortcuts list` / `run -i <file>`    ││
│  PmsetChargeLimitReader    – undocumented, read-only `pmset -g battlimit`     ││
│  ChargeLimitReportParser   – strict parser for that report (fixtures)         ││
│  ProcessRunner             – no shell, stdin closed, deadline, bounded output ││
│  NativeChargeLimitSupport  – platform check; `NativeChargeLimitBackend.system`││
└───────────────┬──────────────────────────────────────────────────────────────┘│
                │ depends on                                                    │
┌───────────────▼──────────────── CellKeeperCore (pure Swift, no IOKit) ────────▼───────────────┐
│  Telemetry:  BatterySnapshot, BatteryHealth, TelemetryProvider (protocol)                      │
│  Settings:   ChargingSettings (+ validation), SettingsStore (UserDefaults JSON)                │
│  Policy:     ChargingPolicy (pure state machine), PolicyInput/Decision/Memory, ChargeOverride  │
│  Control:    ChargingBackend (protocol), MockChargingBackend, ReadOnlyChargingBackend,         │
│              NativeChargeLimitBackend (+ ShortcutRunning / ChargeLimitReading protocols)       │
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
| Hardware/control backend | `ChargingBackend` (Core) | Simulated, read-only, native Charge Limit (experimental, opt-in) |
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
  `terminate(_:)` is called from inside a main-actor job.
  - Quitting cancels the command task, so an in-flight tool run is stopped
    at once and the restore is not stuck behind it.
  - The 10 s bound only limits how long quitting *waits*.
  - The durable record of the user's own Charge Limit decides the outcome:
    it is deleted only after a confirmed restore. If it still exists (also
    when the wait ran out), an alert says which value to set by hand before
    the app exits, and the next launch retries (see "Native Charge Limit
    backend").
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

### Native Charge Limit

With a native-limit backend (`ControlCapabilities.style == .nativeLimit`),
macOS enforces the limit. That includes its hysteresis: it resumes after a
drop of more than 5%. It also includes its behaviour during sleep and its
occasional calibration charge. CellKeeper only chooses the limit's value. The
first three rows of the table above apply unchanged (invalid settings,
management off, override expiry and unplugging). The rest are replaced by:

| # | Condition | State | Desired mode |
|---|---|---|---|
| N1 | Telemetry reports no battery | `failSafe` | normal (the user's own limit) |
| N2 | Limit is not one of the backend's steps (80/85/90/95/100) | `failSafe` | normal |
| N3 | Temporary full charge active (ends when full, on unplug, or on expiry) | `fullChargeOverride` | nativeLimit(100) |
| N4 | Otherwise | `osEnforcedLimit` | nativeLimit(limit) |

What the native-limit policy does with features and inputs it cannot use:
- **Discharge:** a session is interrupted with a note.
- **Resume threshold, temperature protection, safety floor, sleep precaution, on-battery rule:** not used. macOS does these jobs itself, or the Charge Limit cannot express them; the UI disables the settings and explains why.
- **Missing or stale telemetry:** does *not* release the limit, because macOS enforces it from its own measurements. Releasing would only restore and re-apply the setting after every wake. Missing telemetry only means a full charge cannot be recognised as complete; it still ends on expiry or unplug.

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
| Automatic retry of a failed restore of `.normal` within 60 s of the failure | `refuse(.rateLimited(retryAt:))` |
| Otherwise | `enableCharging` / `disableCharging` / `requestDischarge` / `setNativeLimit(n)` |

"Restricting" means moving further from macOS defaults
(normal → inhibit → discharge), or replacing one CellKeeper-set native limit
with another. Relaxing changes toward `.normal` are never blocked by a fault
and never wait for the restricting budget. (Research rule R13 caps *all*
non-safety transitions; CellKeeper deliberately counts only restricting ones,
treating every relaxing change as a safety-direction change. Total
transitions are therefore at most about twice the restricting budget, plus
spaced retries of a failing restore.) The one wait on a relaxing change is
for *automatic* evaluations (timer, power events, wake, launch) after a
restore has just failed. User actions (settings, override, backend switch,
"refresh", quit) retry at once, so a broken backend is not hammered and a
user is never made to wait.

## Control backend contract

```swift
public protocol ChargingBackend: Sendable {
    var descriptor: BackendDescriptor { get }
    func capabilities() async -> ControlCapabilities     // availability, style, supported modes
    func currentMode() async throws -> ChargeControlMode? // nil = unknown
    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome
    func nativeLimitStatus() async -> NativeLimitStatus?  // default nil; no I/O
}
```

- `ChargeControlMode`: `normal` (fail-safe), `inhibitCharging`,
  `forceDischarge`, `nativeLimit(percent:)`.
- `ControlStyle`: `chargingModes` (CellKeeper switches charging itself) or
  `nativeLimit(steps:)` (macOS enforces a limit; CellKeeper picks its value
  from `steps`). The style is kept when a backend is unavailable, so the
  policy and UI can still explain what would happen.
- `ControlAvailability`: `available` (verified real control), `experimental`
  (real, unverified, opt-in only), `simulated`, `unavailable(reason)`. The UI
  shows exactly these four states.
- `ControlOutcome`: `applied` (the requested state was reached by this
  request and confirmed), `unchanged` (it was already in effect, so nothing
  was changed; confirmed all the same), or `simulated`. Simulated backends
  must never return `applied` or `unchanged`, and `setMode` must throw rather
  than return when the requested state was not reached.
- `.normal` must always be accepted by a backend that accepts requests.
- A backend that accepts requests must report its mode. `nil` ("unknown") or
  an error from `currentMode()` counts as a failure.

The native-limit extension of the contract:

- **Target and steps.** `setMode(.nativeLimit(p))` accepts only `p` among the
  advertised steps (80, 85, 90, 95, 100 for Apple's Charge Limit).
- **Ownership.** Before its first change, the backend reads the user's own
  limit from macOS and persists it.
  - If the limit cannot be read and recognised, the backend refuses to
    change anything. It never assumes a value, in particular not 100%.
  - `setMode(.normal)` releases: it restores exactly the recorded value,
    confirms it, and only then forgets the record. With nothing recorded,
    `.normal` is already in effect.
- **Reporting.** `currentMode()` is `.normal` while nothing is recorded,
  because the user's own limit is in effect whatever its value. Otherwise it
  is `.nativeLimit` with the value macOS reports, read afresh. A value other
  than CellKeeper's target is an outside change.
  `nativeLimitStatus()` reports the last read value, the recorded own limit,
  and the current target, without new I/O.
- **Confirmation.** Only a fresh read of the setting from macOS confirms a
  change. A shortcut or command exiting successfully does not: one did so
  while changing nothing (research note 08, O2).

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
- a fault after 3 failures (a successful request or a failure-free hour
  resets the count). While faulted, `.normal` is actively requested until
  confirmed, nothing else is requested, and the fault persists until the user
  clears it, even if recovery succeeds. A fault belongs to the backend in use:
  switching to another backend (which first requires a confirmed `.normal`)
  starts that backend with a clean record;
- a backend whose availability does not affect hardware can never report an
  action as applied to hardware (a claimed `.applied` is downgraded and
  logged);
- `.normal`, confirmed, before switching backends. If it cannot be confirmed,
  the old backend stays responsible and the switch stays *pending*. The
  policy is then told to release (`ReleaseReason.backendSwitch`) whatever
  the settings say, so `.normal` keeps being requested (automatic retries
  60 s apart), and the switch completes as soon as it is confirmed.
  Choosing the current kind of backend again cancels the pending switch;
- if a read fails while CellKeeper holds a non-normal state, `.normal` is
  requested (`ReleaseReason.stateUnverified`). The last confirmed mode stays
  the expectation, so a reading that differs from it after reads recover is
  still treated as an outside change. A request the backend accepted but
  that could not be confirmed is remembered, so finding it later confirms it
  rather than counting as an outside change. A request the backend rejected
  is not remembered. Native backends decide this from their record and
  report it as `isReportedStateOwn`;
- a restore of `.normal` that was attempted and not confirmed stays owed
  (`ReleaseReason.restoreUnfinished`) until it is confirmed, whatever the
  settings say. The native backend persists this (`isRestoring`), so the
  next launch finishes it first. Finding an earlier change of CellKeeper's
  in effect does not cancel it;
- a backend that finds an outside change itself, just before writing
  (`BackendError.changedOutside`), faults at once, like the controller's own
  detection;
- on the first read from a backend, ownership that the backend remembers from
  an earlier session (`nativeLimitStatus().target`) is adopted as
  CellKeeper's own. A change made while CellKeeper was not running is then
  detected like any other outside change. Because a normal quit never
  leaves such a record, its presence also makes the restore owed: the
  user's limit is restored before anything else;
- after a failed restore of `.normal`, automatic evaluations wait 60 s
  before retrying it (see the action table);
- a request answered `unchanged` does not count toward the restricting
  budget, because nothing was written;
- will-sleep precautions that last until wake (bounded to 2 minutes of
  monotonic time if no wake notification arrives);
- `shutdown(reason:)` on quit: restore `.normal`, then turn every later
  command, including ones already queued, into a no-op;
- a bounded in-memory activity log mirrored to unified logging.

Implementations today:

| Backend | Availability | Behaviour |
|---|---|---|
| `MockChargingBackend` (default) | `simulated` | Records requests, tracks a simulated mode, supports failure injection for tests. Never touches hardware. |
| `ReadOnlyChargingBackend` | `unavailable` | Accepts nothing; CellKeeper still computes and shows what it would do. |
| `NativeChargeLimitBackend` (opt-in) | `experimental`, or `unavailable(reason)` | Sets macOS's Charge Limit by running the user's “CellKeeper Set Charge Limit” shortcut; reads it back with `pmset -g battlimit`. See below. |

## Native Charge Limit backend

`NativeChargeLimitBackend` (Core) holds the logic. It never touches the
system itself: it is given a `ShortcutRunning`, a `ChargeLimitReading`, a
`KeyValueStorage` and a platform check. That lets the unit tests run it
against a fake macOS. `NativeChargeLimitBackend.system()` (Kit) wires it to
the real system.

| Concern | Mechanism | Classification |
|---|---|---|
| Change the limit | `shortcuts run "CellKeeper Set Charge Limit" -i <file>`. The file holds only the digits, in the container's temporary directory; 20 s deadline. The shortcut wraps Apple's “Set Battery Charge Limit” action. | `[PUBLIC-API]` CLI, user-created shortcut, verified on one Mac |
| Check the shortcut exists | `shortcuts list` before taking over (cached for 5 minutes once found; checked again after any failed run). Skipped while CellKeeper owns the limit, so a restore never waits for it; a missing shortcut then shows up as a failed run | `[PUBLIC-API]` |
| Read the limit back | `pmset -g battlimit`, fixed arguments, strict parser (`ChargeLimitReportParser`). Anything unrecognised means "do not change anything". | `[PRIVATE/UNDOCUMENTED]`, read-only |
| Record of the user's own limit | JSON file `Application Support/CellKeeper/native-charge-limit-ownership.json` in the app's container, holding the own limit, the last confirmed target, the targets being set but not yet confirmed, whether a restore is in progress, and the time. A missing file means no record; any other failure to read it counts as an unreadable record. Each save writes a temporary file, flushes it with `F_FULLFSYNC`, renames it into place, flushes the directory, and reads it back; if any step fails, nothing is changed. Cleared only after a confirmed restore. | — |
| Platform | Apple silicon (`hw.optional.arm64`), macOS 26.4+, both tools present | `[PUBLIC-API]` |

Lifecycle:

1. **Take-over.** When the policy first wants `nativeLimit(n)`, the backend
   reads macOS's limit (say 80%) and durably stores
   `{own: 80, target: 80, pending: [n]}`. Only then does it run the shortcut
   with `n`. After reading `n` back, it stores `{target: n, pending: []}`.
   - If macOS already shows `n`, nothing runs and the request is
     `unchanged`. CellKeeper still records ownership, so an outside change
     is noticed later.
   - A report of "no limit" is recorded as 100% only after the user confirms
     in Settings that their limit is 100%. Otherwise the backend is
     unavailable and changes nothing, because "no limit" could also be a
     temporary state.
2. **Holding.** Each evaluation reads the limit; so does the backend before
   every change. A value CellKeeper did not set (not the confirmed target, a
   pending one, or the user's limit during a restore) faults the backend, and
   the user's own limit is restored once. A pending value that turns out to
   be in effect becomes the confirmed target.
3. **Release.** Any of these requests `.normal`: management off, quit, a
   backend switch (pending until confirmed), any failed request, a state
   that could not be read back, or a fault.
   - The backend marks the restore as in progress, runs the shortcut with
     the recorded value (even if it could not read the setting first), and
     reads it back.
   - Only then does it delete the record. If the read-back failed but a
     later read shows the user's limit, the restore counts as done.
   - If macOS already shows that value, nothing runs.
4. **Crash or kill.** The record survives. At the next launch:
   - macOS showing the recorded own limit means a restore completed late
     (or the user restored it), so the record is cleared.
   - macOS showing the target, or a pending target (which is then
     confirmed), means the limit is still CellKeeper's: it restores the
     user's limit first (a normal quit never leaves a record, so the earlier
     session did not finish, and its markers may be stale), then resumes
     management, setting its limit again subject to the rate limit.
   - Anything else is an outside change: fault, then restore.
   - The app checks for a record regardless of which backend is selected.
     If one exists while another backend is selected, it starts on the
     native backend and immediately requests the switch, so the limit is
     restored first.
5. **Unreadable record.** If the record cannot be read or is implausible,
   CellKeeper does not know what to restore. It then refuses every change,
   reports unresolved ownership (a backend switch stays pending, quitting
   warns), and shows the recovery: set the limit by hand in System
   Settings, then discard the record in Settings › Control.

Every request is logged with the value macOS reported when it was
confirmed.

How often the shortcut can run:
- Changes to a CellKeeper-chosen limit share the restricting budget
  (≥ 60 s apart, ≤ 20 per hour).
- A restore always follows a change, or retries a failed restore (≥ 60 s
  apart when automatic).
- Taking over a limit that is already in effect runs nothing.

## Future control backends

Research ([02](research/02-charging-control-apple-silicon.md)) found no public
API to inhibit charging or force discharge. Third-party reports (unverified)
say the SMC keys other tools used have been progressively closed off, with
macOS 27 firmware reportedly gating most of them even for root. The
candidates, in the order we intend to evaluate them:

1. **Delegated native limit.** Implemented in milestone 2 as
   `NativeChargeLimitBackend` (see above and
   [research note 08](research/08-native-charge-limit.md)).
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

No helper code exists. It will not be enabled without the hardware
verification protocol in research note 02 §7 and the rules in `safety.md`.

## Known limitations

### Native Charge Limit backend

- **Undocumented read-back.** `pmset -g battlimit` is not in pmset(1) and
  may change in any macOS update. If its output is not recognised, the
  backend becomes unavailable (with nothing recorded), or its requests fail
  while it owns the limit. A restore of the recorded limit is still
  attempted, and stays unconfirmed until it reads back. It never guesses. Every pmset run also attempts
  to open the SMC user client; the App Sandbox denies this (note 08, O7).
- **"No limit" needs the user.** The report showed a 100% limit as "no
  limit", but a temporary state such as "Charge to Full Now" might look the
  same. CellKeeper therefore records it as 100% only after the user confirms
  their limit is 100% (once per session), and never assumes it.
- **No restore without the shortcut.** If the shortcut is deleted or
  renamed while CellKeeper owns the limit, CellKeeper cannot change it back.
  It says so and points to System Settings › Battery › Charging, which is
  the always-available manual recovery.
- **Crashes and force-quits.** The limit stays at CellKeeper's value until
  CellKeeper runs again (the record survives) or the user changes it. On a
  normal quit the restore usually takes about 0.3 s; quitting waits up to
  10 s and warns if the restore was not confirmed.
- **Outside changes are reverted once.** If the limit is changed in System
  Settings or by another tool while CellKeeper manages it, CellKeeper faults
  and restores the user's recorded limit. That also reverts a deliberate
  change made in System Settings. To change the limit by hand, turn off
  "Manage charging" first.
- **Sleep, restart and shutdown** behaviour of the Charge Limit itself is
  macOS's; see note 08 for what has been observed.

### Before any privileged control backend

The current controller is correct for simulated control and for macOS's
Charge Limit. An independent review identified these gaps that must be
closed before a backend that changes hardware *itself* is enabled:

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

- CellKeeper ships App-Sandboxed with Hardened Runtime and no other
  entitlements. Verified: telemetry works fully inside the sandbox, and so
  does launching `/usr/bin/shortcuts` and `/usr/bin/pmset` for the native
  Charge Limit (note 08, O3). The shortcut's actions run in Shortcuts' own
  process. Release builds do not carry the debugger entitlement
  `get-task-allow`; CI checks both.
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
| D14 | First real control is macOS's Charge Limit, written through a user-created shortcut and the documented `shortcuts` CLI, and read back with `pmset -g battlimit` (read-only) | The only supported charge control; no root, helper, or private API on the write path; verified from the sandbox (note 08) |
| D15 | For a native-limit backend, `.normal` means "the user's own limit, as recorded" | Every existing fail-safe path (quit, management off, backend switch, failure, fault) then restores exactly that value without new code paths |
| D16 | CellKeeper takes ownership whenever it manages the native limit, even when the value is already right | Consistent outside-change detection; a take-over that needs no write runs nothing and does not use the rate budget |
| D17 | Missing or stale telemetry does not release a native limit | macOS enforces it from its own measurements; releasing would only cause a restore-and-reapply cycle after every wake |
| D18 | An outside change to the native limit faults the backend and restores the recorded limit once | Matches R27 and the owner's rule to restore on any failure; documented in the UI (turn management off before changing the limit by hand) |
| D19 | Automatic retries of a failed restore wait 60 s; user actions retry at once | Bounds shortcut runs while a backend is broken without delaying a restore the user asked for |
| D20 | The native backend is `experimental` and opt-in with a confirmation | Verified on one Mac; relies on an undocumented read-back |
| D21 | A backend switch that cannot restore `.normal` stays pending instead of being dropped; at launch, an outstanding record overrides the selected backend until it is restored | Restoring the user's limit must not depend on which backend the user selects or on the app staying open |
| D22 | The ownership record is a fsync'd file, written and read back before any change | `UserDefaults` persists asynchronously; losing the record after a change would lose the user's limit |
| D23 | "No limit" is recorded as 100% only after the user confirms it | The report cannot distinguish a 100% limit from temporary states; the owner's rule is never to assume 100% |
| D24 | Invalid settings are rejected before use, never applied | The UI only offers valid values; a rejected change keeps the previous valid settings, so there is no "invalid settings" state to restore from at run time. The policy still fails safe if handed invalid settings directly |
| D25 | An attempted restore stays owed until confirmed, across relaunches; any record found at launch makes it owed | Otherwise recognising an earlier change, a relaunch, or a marker that could not be saved could quietly abandon giving the user's limit back. The cost is one restore and re-apply after a crash |
