# CellKeeper architecture

Status: milestone 2 (telemetry + policy engine + simulated control + macOS's native Charge Limit), plus the logic of the future privileged helper with a simulated control only. Last reviewed 2026-10-09.

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
   injection framework, three modules plus the app.

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
│  FileOwnershipRecordStore  – durable record of the user's own Charge Limit    ││
└───────────────┬──────────────────────────────────────────────────────────────┘│
                │ depends on                                                    │
┌───────────────▼──────────────── CellKeeperCore (pure Swift, no IOKit) ────────▼───────────────┐
│  Telemetry:  BatterySnapshot, BatteryHealth, TelemetryProvider (protocol)                      │
│  Settings:   ChargingSettings (+ validation), SettingsStore (UserDefaults JSON)                │
│  Policy:     ChargingPolicy (pure state machine), PolicyInput/Decision/Memory, ChargeOverride  │
│  Control:    ChargingBackend (protocol), MockChargingBackend, ReadOnlyChargingBackend,         │
│              NativeChargeLimitBackend (+ ShortcutRunning / ChargeLimitReading /                │
│              OwnershipRecordStore protocols)                                                   │
│  Controller: ChargeController (actor: telemetry → policy → backend, safety fallbacks, log)     │
│  Support:    CellKeeperLog (os.Logger categories)                                              │
└────────────────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────── CellKeeperHelperCore (pure Swift, Foundation only; not used yet) ──────────────┐
│  Wire:     HelperProtocolVersion, HelperControl, HelperControlSet, HelperCapabilities,         │
│            HelperInterlocks, HelperStatus, reply values (primitives only, for NSXPC)           │
│  Engine:   HelperEngine (actor: sessions, per-control leases, rate limits, interlocks,         │
│            restore at start, exit and disconnect, read-back), HelperSession, HelperEvent       │
│  Seams:    HelperChargeControl (SimulatedChargeControl, UnknownHardwareChargeControl),         │
│            HelperPowerReading (the helper's own power state)                                   │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `Packages/CellKeeperKit` is a local Swift package (tools version 6.0, Swift
  6 language mode, macOS 14+) with three library products and three test
  targets. `swift test` runs every non-UI test without opening Xcode.
- `CellKeeper.xcodeproj` contains only the app target. It uses a
  file-system-synchronized group for `CellKeeper/`, so adding a Swift file
  needs no project edits. The project file format is pinned to
  `objectVersion = 77` (Xcode 16+); CI fails if a newer Xcode rewrites it.
- The boundary is enforced by dependency direction: `CellKeeperCore` cannot
  import `CellKeeperKit`, so policy code cannot reach IOKit.
- `CellKeeperHelperCore` depends on nothing, and nothing depends on it yet.
  It holds the logic of the future privileged helper and the vocabulary the
  app and the helper will share (see "Helper engine" below).

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
| Privileged operations | `HelperEngine` (HelperCore) | Helper logic implemented with a simulated control only; no hardware control, and the app does not use it yet. The daemon, its XPC transport and the app's backend are future work |

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
  expiry, rate limiting and the minimum temperature pause use a monotonic
  clock (`ContinuousClock`, which keeps counting during sleep), so changing
  the system clock cannot extend a temporary override or a pause, or block
  restrictions.

## Charging policy

`ChargingPolicy.evaluate(_:)` maps a `PolicyInput` (wall time, monotonic
uptime, settings, snapshot, active override, backend capabilities, backend's
current mode, policy memory, fault flag, recent restricting requests,
sleep-imminent flag) to a `PolicyDecision` (state, desired mode, action,
reason, notes, next memory, override end).

### Memory: hysteresis latches, debounce and minimum pause

The policy's only memory is `PolicyMemory`:

- `limitReached` — set when two consecutive distinct readings show
  charge ≥ limit (see the debounce below), cleared when charge ≤ resume
  threshold, unchanged in between (the hysteresis band). Never set when the
  limit is 100%. Raising the limit above the one it was set at
  (`latchedLimit`) clears it, so charging resumes toward the new limit,
  unless the charge has already reached the new limit: then the hold
  continues without a gap.
- `pendingLimitCrossing` — the debounce (research rule R14). The first
  reading with charge ≥ limit while `limitReached` is clear is kept here
  (its identity and charge), and the state stays `charging` with a note that
  CellKeeper is confirming the limit with the next reading. The next
  *distinct* reading at or above the limit sets `limitReached`. A reading's
  identity is the driver's own update time (`sourceTimestamp`) where
  reported, so several evaluations within one driver refresh count as one
  reading. Otherwise it is CellKeeper's read time, and only evaluations of
  the same read (the same timestamp) count as one. The pending reading is
  judged against the current limit, so raising the limit past it starts
  over. It is dropped by a reading below the limit and by any evaluation
  that does not look at the charge (the fail-safe rows, including invalid
  settings and a required release; management off; a native-limit
  backend), so the two readings are always consecutive.
- `temperatureTripped` — set at ≥ pause temperature on the first such
  reading, cleared at ≤ resume temperature once it has been set for at least
  5 minutes of monotonic time (`temperatureTrippedAtUptime`, research rule
  R21). It is cleared at once when the temperature is unknown or protection
  is turned off, so a lost sensor can never hold charging off. Once clear it
  sets again on the next hot reading, with no minimum (see the deviations in
  `safety.md`).
- `belowSafetyFloor` — set at ≤ 10%, cleared at ≥ 15%.

Only the limit latch is debounced. Every other rule acts on the first
reading that calls for it: the safety floor, the sleep precaution and a
temperature trip because they are safety actions, and the resume threshold,
a raised limit, battery power, an unknown temperature, overrides and the
fail-safe rows because they relax toward macOS defaults. Readings on battery
power and during an override still count toward the debounce, so a latch
confirmed then holds as soon as the rule that set it aside no longer applies.
Invalid settings, management off, no battery, and a native-limit backend
reset the whole memory, as before; a backend switch keeps it, because the
latches describe the battery, not the backend.

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
  its confirmed target is outside 20–95%. After it ends it never restarts by itself.

### Precedence (highest first)

| # | Condition | State | Desired mode |
|---|---|---|---|
| 1 | Settings invalid, or the controller requires a release (`ReleaseReason`: a pending backend switch, an unfinished restore, or a state it set but could not read back) | `failSafe` | normal |
| 2 | Management disabled | `unmanaged` | normal |
| 3 | No/stale telemetry (by read time, or by the driver's own update time > 180 s), future timestamps, no battery, unknown % or power source | `failSafe` | normal (a discharge session is interrupted) |
| 4 | Safety floor latched | `safetyFloor` | normal |
| 5 | On battery power | `onBattery` | normal (restrictions cleared; limit latch kept) |
| 6 | Temperature latch set (cooling clears it no sooner than 5 minutes after it was set) | `temperaturePause` | inhibitCharging |
| 7 | Temporary full charge active | `fullChargeOverride` | normal |
| 8 | Discharge session active | `discharging` | forceDischarge |
| 9 | Limit is 100% | `charging` | normal |
| 10 | Limit latch set (by two consecutive distinct readings) | `holding` | inhibitCharging |
| 11 | Sleep imminent and charge ≥ resume threshold | `holding` | inhibitCharging |
| 12 | Otherwise, including a first reading at or above the limit that awaits confirmation | `charging` | normal |

### Native Charge Limit

With a native-limit backend (`ControlCapabilities.style == .nativeLimit`),
macOS enforces the limit. That includes its hysteresis: it resumes after a
drop of more than 5%. It also includes its behaviour during sleep and its
occasional calibration charge. CellKeeper only chooses the limit's value.
Rows 1 and 2 of the table above apply unchanged (invalid settings or a
required release, then management off), and so do override expiry and
unplugging. Row 3 does not (see "Missing or stale telemetry" below). The
rest are replaced by:

| # | Condition | State | Desired mode |
|---|---|---|---|
| N1 | Telemetry reports no battery | `failSafe` | normal (the user's own limit) |
| N2 | Limit is not one of the backend's steps (80/85/90/95/100) | `failSafe` | normal |
| N3 | Temporary full charge active (ends when full, on unplug, or on expiry) | `fullChargeOverride` | nativeLimit(100) |
| N4 | Otherwise | `osEnforcedLimit` | nativeLimit(limit) |

What the native-limit policy does with features and inputs it cannot use:
- **Discharge:** a session is interrupted with a note.
- **Resume threshold, temperature protection, safety floor, sleep precaution, on-battery rule:** not used. macOS does these jobs itself, or the Charge Limit cannot express them; Settings hides them and one note says what macOS does instead.
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
    func takeAdoptedLimitChange() async -> AdoptedLimitChange? // native only; each adoption once
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
  was changed; confirmed all the same), `simulated`, or, for native-limit
  backends, `adoptedOutsideChange` (a limit CellKeeper did not set was kept
  as the user's own and nothing was written). Simulated backends
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
  is `.nativeLimit` with the value macOS reports, read afresh.
  `nativeLimitStatus()` reports the last read value, the recorded own limit,
  and the current target, without new I/O.
- **Outside changes are adopted.** A recognised value that CellKeeper did
  not set (not its target, a pending value, or the user's limit during a
  restore) was set by someone else, usually the user in System Settings.
  The backend adopts it as the user's own limit and writes nothing.
  `currentMode()` then reports `.normal`; `setMode` returns
  `adoptedOutsideChange` instead of writing, including when asked to
  restore. `takeAdoptedLimitChange()` reports each adoption once.
  - **Every read checks for this**: before a change, before a restore,
    while confirming a write, and in the controller's read-back after it.
    A value found while confirming is adopted at once, so a later restore
    that cannot read first never writes over it.
  - **The recorded limit, set again by hand, counts as an outside change**,
    except on the first contact with a record from an earlier session. That
    case cannot be told apart from a restore that finished late, so the
    record is cleared quietly.
  - **The record becomes an adoption marker.** The record file is replaced
    by a marker (nothing to restore).
    - It stays while management is off because of the adoption. Settings
      reach the disk asynchronously, so at launch the marker, not the saved
      settings, decides that management stays off.
    - Turning management on again removes it, whichever backend is in use;
      so does a new record of the user's limit. If it cannot be removed,
      management stays off.
    - If the marker cannot be stored, whatever is on disk is left alone and
      saving is retried at every read. An old record left in place makes
      the next launch adopt the change again. Until the marker is stored, a
      backend switch waits; turning management on removes the old record
      (it is no longer owed), or stays off if it cannot.
    - Removing a marker never deletes a record of the user's limit.
    - The kept value may be any percentage macOS reports, including one
      CellKeeper cannot set (another tool, or a later macOS with other
      steps); it is never restored. The values CellKeeper recorded or set
      must be Charge Limit steps, or the marker counts as unreadable.
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
  faulted at once (research rule R27). A native-limit backend adopts such a
  change instead (above); the controller then turns management off, so it
  never overrides what the user chose, and logs what it kept. Turning
  management on again records the adopted value as the user's own limit.
  A settings change the user made before the app had seen the adoption
  (still queued, for example) cannot turn management back on
  (`apply(settings:adoptionsSeen:)`). A write that was carried out before
  the outside change was found still counts toward the rate limit;
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
  still treated as an outside change (and adopted, for a native backend). A request the backend accepted but
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
  detection. A native backend adopts it instead (`adoptedOutsideChange`),
  which counts as nothing written;
- on the first read from a backend, ownership that the backend remembers from
  an earlier session (`nativeLimitStatus().target`) is taken on as
  CellKeeper's own. A change made while CellKeeper was not running is then
  detected (and, for a native backend, adopted) like any other outside
  change. Because a normal quit never
  leaves such a record, its presence also makes the restore owed: the
  user's limit is restored before anything else;
- after a failed restore of `.normal`, automatic evaluations wait 60 s
  before retrying it (see the action table);
- a request answered `unchanged` does not count toward the restricting
  budget, because nothing was written;
- will-sleep precautions that last until wake (bounded to 2 minutes of
  monotonic time if no wake notification arrives). The re-read 35 s after a
  wake is its own trigger and never ends them, and a sleep announcement
  cancels a pending re-read;
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
system itself: it is given a `ShortcutRunning`, a `ChargeLimitReading`, an
`OwnershipRecordStore` and a platform check. That lets the unit tests run it
against a fake macOS. `NativeChargeLimitBackend.system()` (Kit) wires it to
the real system.

| Concern | Mechanism | Classification |
|---|---|---|
| Change the limit | `shortcuts run "CellKeeper Set Charge Limit" -i <file>`. The file holds only the digits, in the container's temporary directory; 20 s deadline. The shortcut wraps Apple's “Set Battery Charge Limit” action. | `[PUBLIC-API]` CLI, user-created shortcut, verified on one Mac |
| Check the shortcut exists | `shortcuts list` before taking over (cached for 5 minutes once found; checked again after any failed run). Skipped while CellKeeper owns the limit, so a restore never waits for it; a missing shortcut then shows up as a failed run. Until CellKeeper owns the limit, the user's limit is also read at every check and must be 80–100% in 5% steps (100% only once confirmed); otherwise the backend is unavailable, so the policy refuses instead of counting backend failures | `[PUBLIC-API]` |
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
   every change, including a restore. A value CellKeeper did not set (not
   the confirmed target, a pending one, or the user's limit during a
   restore) is adopted as the user's own limit: the record is replaced by
   an adoption marker, nothing is written, and management is turned off and
   saved. A pending
   value that turns out to be in effect becomes the confirmed target.
3. **Release.** Any of these requests `.normal`: management off, quit, a
   backend switch (pending until confirmed), any failed request, a state
   that could not be read back, or a fault.
   - The backend marks the restore as in progress, runs the shortcut with
     the recorded value, and reads it back. Within a session it does so even
     if it could not read the setting first. A record from an earlier
     session is restored only after the limit has been read, because
     someone may have changed it since and a blind write could overwrite
     their choice.
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
   - Anything else is an outside change, adopted as in step 2.
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
  (≥ 60 s apart, ≤ 20 per hour). Requests made on the Simulated backend are
  dropped from the budget when the backend changes, so they never delay the
  first real change; real changes still count after a round trip through
  Simulated.
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
2. **Privileged helper (`CellKeeperHelper`).** CellKeeper's own charge
   control, for limits at any level, is the current priority (owner decision,
   2026-10-09; roadmap milestone 4). Its foundations are developed against a
   simulated control first (phase 4a). Installing the helper needs a
   Developer ID (phase 4b), and hardware control needs a mechanism verified
   on a dedicated test Mac and every precondition in `safety.md` (phase 4c).
   Design (see [04](research/04-privileged-helper.md)): `SMAppService` launch
   daemon; XPC with code-signing requirements on both sides; a fixed set of
   typed operations (no raw keys, no command execution); a lease that restores
   `.normal` if not renewed, on client disconnect, at helper start, and on
   SIGTERM; per-model allowlist and read-back. The helper would expose itself
   to the app as another `ChargingBackend`. Apple's published power-management
   source releases its private charge-inhibit assertions when the owning
   process exits, which would be a valuable fail-safe, but whether that holds
   on shipping Apple silicon is unverified.

The helper's logic exists as `CellKeeperHelperCore` (below), with a
simulated control only. There is no daemon, no XPC, and no hardware control,
and the app does not use it yet. Real control will not be enabled without the
hardware verification protocol in research note 02 §7 and the rules in
`safety.md`.

### Helper engine (`CellKeeperHelperCore`)

`HelperEngine` is everything the helper decides, without the parts that
touch the system. It is pure Swift on Foundation: no IOKit, XPC, processes,
files or network. The layers, from the client down:

1. **Transport** (future). The app's in-process backend first, then an NSXPC
   listener in the daemon. It opens one `HelperSession` per connection,
   forwards each request with its raw wire values, and invalidates the
   session when the connection ends. It must deliver one connection's
   requests in order; the engine itself is an actor. When the engine revokes
   a session (`sessionRevoked`), the transport closes its connection.
2. **Session and engine.** Validation, leases, rate limits, interlocks and
   read-back, below.
3. **`HelperChargeControl`**, the only access to hardware: `probe()`,
   `apply(_:active:)`, `readBack()`, `restoreDefaults()`. A real control is
   the one place for undocumented operations and computes its capabilities
   only from a compiled-in, reviewed allowlist. `SimulatedChargeControl`
   (tests, contributor builds) changes nothing and says so.
   `UnknownHardwareChargeControl` has no capabilities and writes nothing; the
   daemon will ship with it until a mechanism is verified (R12a).
4. **`HelperPowerReading`**: the charge, external power, physical adapter
   presence (distinct from external power, because a disabled adapter makes
   the Mac report battery power) and thermal pressure, read by the helper
   itself and stamped on the engine's clock. The helper never takes the
   client's word for them.

Wire vocabulary. Every argument and reply field is an `Int`, `UInt64` or
`Bool`, so each request maps one to one onto an NSXPC method with a single
reply block. Raw values never change and are never reused. Protocol version
1; the helper serves clients from `minimumSupportedClient` (1) to `current`.

| Request | Before `hello` | Lease | Request budget | Effect |
|---|---|---|---|---|
| `hello(clientProtocolVersion)` | — | no | yes | Status, helper protocol version, build, capabilities, whether simulated. Any failed `hello` withdraws the introduction |
| `readState()` | refused | no | yes | Read-back controls, seconds left on each lease, whether the caller holds them, interlocks, last hardware error |
| `acquireOrRenewLease(control, seconds)` | refused | — | yes | Grants or renews, clamped to 900 s (inhibit) or 120 s (adapter); one session holds leases at a time |
| `releaseLease(control)` | refused | holder | not refused¹ | Ends the lease and clears the control |
| `setControl(control, true)` | refused | yes | yes | Capability, then the checks; then, on one fresh clock reading, the lease, the power state's age, interlocks and activation limits; then write and read-back |
| `setControl(control, false)` | refused | no | not refused¹ | Clears the control if the engine set it |
| `restoreDefaults()` | allowed | no | not refused¹ | Ends every lease and restores defaults. Reads the hardware afresh and writes nothing if it shows defaults and no restore is owed; an owed restore is written even if defaults may already be in effect. Also served before start and during shutdown |
| `restoreDefaultsAndExit()` | allowed | no | not refused¹ | Restores defaults, then shuts down so the host can exit (update, uninstall). During shutdown, the same as `restoreDefaults()` |

¹ Except the one request that makes the session revoked (below), which
gets `rateLimited`, even a restore.

Only a live session is served. An invalidated or revoked session gets
`notIntroduced` for its restores, and `notReady`, `shuttingDown` or
`notIntroduced` for anything else, depending on the engine's phase.
Requests the budget does not refuse still spend a token when one is left,
and still count toward revocation.

Statuses: `ok`, `incompatibleProtocol`, `notIntroduced`,
`unsupportedControl`, `invalidArgument` (unknown control, lease of 0 s or
less), `noLease`, `leaseHeldByOtherClient`, `rateLimited`,
`blockedByInterlock`, `hardwareError`, `shuttingDown`, `notReady` (before
the start-up restore).

Interlocks are reported in `readState` and can never be set by a client:

| Interlock | Raised while | Clears and refuses |
|---|---|---|
| `powerStateUnavailable` | No reading; no charge (0–100%) or power source; read more than 60 s ago, in the future, or at or before the last wake (R9, R17) | both controls |
| `belowBatteryFloor` | Charge ≤ 10%, until ≥ 15% (R5) | both |
| `notOnExternalPower` | Not running on external power (R18) | charging inhibit |
| `adapterAbsent`, `adapterPresenceUnknown` | No adapter connected, or not known | adapter-disable |
| `belowAdapterFloor` | Charge ≤ 25%, until ≥ 30% (note 02, §7) | adapter-disable |
| `thermalPressure` | macOS reports high thermal pressure (R21) | adapter-disable |
| `sleepImminent` | From will-sleep until wake, at most 120 s without a wake (R16) | adapter-disable |
| `externalModification` | The read-back differed from what the engine set, until a client's restore reads back clean (R27) | both |
| `hardwareFault` | A restore is owed: one threw or did not read back clean, and none has read back clean since | both |
| `writeFailed` | A write to a control threw, could not be read back, or read back wrong, until a client's restore reads back clean or an hour after the last such failure (R11) | both |

Other rules:

- **Start (R2).** `start()` restores defaults and reads back before anything
  else is served; until then only restores are honoured. If that restore
  fails, the engine serves sessions with a restore owed.
- **Leases (R3).** Per control, bound to the session. A control is cleared
  when its lease expires, is released, or its session is invalidated or
  revoked (R1). Interlocks clear controls but leave leases in place. The
  checks before an activation read the hardware and the power state,
  which takes time, so the final checks use one fresh clock reading taken
  after those reads: the lease, the power state's age, the interlocks and
  the activation limits. Only these pure checks separate that reading
  from the write. A lease that ran out meanwhile ends there (`noLease`).
  A power state that went stale raises `powerStateUnavailable`, which,
  like any interlock, clears what it blocks at once, and refuses the
  activation (`blockedByInterlock`).
- **Activation limits (R13).** An activation of each control at most once a
  minute, and at most 20 activations of all controls per rolling hour, on
  the monotonic clock, measured from the moment of each write. Every
  attempted activation write counts, whatever its outcome. A request for
  the state already in effect writes nothing and is not counted. An
  activation refused by these limits restores defaults. Deactivations and
  restores are never limited. Each write is reported after it is made
  (`activationRecorded`, with the write time). The host treats that event
  as a notification and persists a snapshot of `activationHistory`,
  asynchronously; the history can be handed to the next engine
  (`HelperEngine(…, activationHistory:)`), so a relaunch, including one the
  client asks for with `restoreDefaultsAndExit`, cannot reset the limits.
  The daemon must persist it and discard it when the boot changes. The
  engine keeps only the latest 20 valid records it is given, found in one
  pass, which is enough for both limits; the daemon's reader must bound
  what it reads too.
- **Request budget.** 10 at once and 2 per second per session. Requests
  that only move toward safety are not refused by it, except the request
  that makes the session revoked, which gets `rateLimited`. A session that
  makes more than 20 requests in a row beyond its budget, refused or
  served, is revoked: its controls are cleared, its leases end, and
  `sessionRevoked` tells the transport to close the connection (research
  note 04, §3.6).
  Beyond its budget, a deactivation or lease release skips the checks and
  writes only to clear what the engine set; a restore still reads the
  hardware afresh, so an outside change is never missed, but writes only if
  something is set.
- **Writes and read-back (R11, R30).** A write that returns is read back. A
  write that throws is not; it may have taken effect, so recovery is the
  restore of defaults that follows. That restore follows any failed write,
  failed read-back or mismatch, and the write failure also raises
  `writeFailed`. A restore that throws or does not read back clean makes a
  restore owed (`hardwareFault`); a clean one settles that, but not
  `writeFailed`. `readState` always reports read-back state, never intended
  state; if the read-back fails, its status is `hardwareError`.
- **Checks.** Every admitted, valid request, except `hello`, the restores,
  and deactivations and lease releases beyond the request budget, and
  every `tick()` (every few seconds), sleep and wake, runs the same
  checks: compare the read-back with what the engine set, expire leases,
  recompute the interlocks and clear what they block. A read-back that
  fails is an unknown state, so defaults are restored (R1).
- **An owed restore** is retried once per `tick()` and per sleep or wake,
  by a client's restore or deactivation, and when the lease holder's session
  ends; never by other requests, so a failing control is not hammered.
  It is written even if defaults may already be in effect, because only a
  clean read-back after a restore settles it. Until it succeeds, nothing is
  activated.
- **The engine's own controls.** A control counts as the engine's while it
  may be active because of the engine: it set it, or a failed write or
  restore may have. After a write that threw or could not be read back,
  that is every control; after a mismatch, every control that reads back
  active. After a restore, it is a control that reads back active and was
  not active before it, and, if the restore threw or could not be read
  back, every control not known to have been active before. The state
  before is read afresh right before each restore; if that read fails,
  the controls last known to be another tool's still count as active
  before, so a failed read never makes them the engine's. A control
  active before and after a restore keeps its owner, so another tool's
  control does not become the engine's. A control stops being the
  engine's when it reads back inactive.
- **Outside changes (R26, R27).** Defaults are restored, and retried while a
  control the engine set may still be active. Once none can be, and until a
  client's restore reads back clean, the engine writes nothing on its own,
  so it does not fight another tool over controls that are clearly that
  tool's (see the limitations below); `readState` keeps reporting what it
  reads. Start, shutdown and a client's restore still write.
- **Sleep and wake (R16, R17).** `systemWillSleep()` clears the
  adapter-disable; the inhibit stays only while its lease is valid, and the
  lease keeps counting during sleep. `systemDidWake()` reads back, compares,
  and runs every check. Only a power state stamped strictly after the wake
  counts.
- **Shutdown (R4).** `terminate()` (the daemon's SIGTERM path) and
  `restoreDefaultsAndExit` end every lease and restore defaults. From then
  on, only restores are served (`shuttingDown` for everything else). If the
  restore was not confirmed, ticks, sleep and wake, `terminate()` and
  clients' restores keep retrying it. `isSafeToExit` and the `safeToExit`
  event say when defaults are confirmed. A client's restore during
  shutdown can fail and owe a restore again; `safeToExit` is then sent
  again once that is settled, and the host checks `isSafeToExit` right
  before exiting. The engine never exits the process itself. Host policy
  for SIGTERM: call `terminate()`, retry about once a second until
  `isSafeToExit` or until launchd's `ExitTimeOut` is nearly used up, then
  exit anyway; the next start restores defaults first (R2).
- **Audit.** Every hardware write (its target, the value asked for, the
  outcome and the read-back, or that it is unknown), lease grant, renewal
  and end, activation, deactivation, restore (with its reason), hardware
  error, interlock change, refused request and revoked session is an event
  for the host to log. A session over its request budget is reported once
  until it is back within it. The events of an operation are queued and
  delivered in order when the operation has ended, after its last write
  and state change, so the sink never runs between a check and a write.
  The sink may re-enter the engine: that starts a new, complete operation
  on consistent state, whose events follow the ones already queued, and
  the sink is never entered recursively. It may block, but only at the
  cost of delaying the next operation; the daemon logs and persists
  asynchronously. Losing the last activation record in a crash is
  acceptable, because the next start restores defaults first.
- **Time (R22).** One monotonic clock that counts sleep, injected, shared
  with the power reading. `HelperEngine.continuousUptime` is the system's
  `CLOCK_MONOTONIC`: the same in every process, and counting from boot on
  macOS. That origin is observed (it matched `kern.boottime` to the
  millisecond on macOS 27, and exceeded sleep-excluding uptime by the time
  slept), not documented, so persisted values are kept only within a boot.

Deliberate deviations from research note 06:

- **R13.** Exceeding the activation limits restores defaults (the safe
  state) and is logged, but raises no degraded mode (lead's decision,
  2026-10-09). A legitimate client can hit the per-control interval after a
  benign race, such as a discharge session ending in a temperature pause and
  an inhibit within a minute of an earlier one, and its own fallback already
  asks for defaults.
- **R11.** A failed write is not retried once; it restores defaults at once
  and raises `writeFailed`, which blocks activations until a client restores
  defaults or for an hour.

Remaining limitations:

- If another tool keeps setting a control the engine had also set, the
  engine cannot tell that from its own control failing to clear, and
  retries the restore once per tick.
- The same holds for another tool that sets a control which was inactive
  just before, during each of the engine's restores: before and after
  look exactly like a restore that set the wrong control, so the control
  counts as the engine's and the restore is retried once per tick,
  although the engine never set it.
- Calls into the control are not bounded in time by the engine; the real
  control and the daemon must bound them.
- The engine relies on read-back alone; behavioural verification (R11, for
  example charge current after an inhibit), debounce (R14) and temperature
  dwell (R21) are not implemented.
- A power reading that is not refreshed after a wake clears every control
  at each wake.
- Persisting the activation history, closing revoked connections, keeping
  each connection's requests in order and exiting are the host's jobs.
- A blocking event sink delays the next operation, for every client.

Not there yet: the daemon (SMAppService, launchd, SIGTERM), the NSXPC
transport and code-signing requirements, the IOKit power reading and
acknowledged sleep notifications, the app's backend, and any real control.

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
- **Outside changes are adopted, whoever made them.** CellKeeper cannot tell
  a change made in System Settings from one made by another tool or by
  macOS itself. It keeps any recognised value as the user's own limit and
  forgets the limit it had recorded. If macOS reports "no limit", that may
  be a temporary full charge rather than the user's choice (note 08, open
  question 3), so the log and the menu also name the earlier limit.
  Unrecognised reports are not adopted: they are handled as a state that
  cannot be read back.
- **A stopped shortcut run might still take effect.** If a run misses its
  20 s deadline, CellKeeper stops the `shortcuts` tool, but whether that
  also stops the shortcut itself has not been observed. If the value landed
  later, CellKeeper would not see it once it had restored and forgotten the
  user's limit; if it still held the record and the value was no longer
  among those it expects, it would adopt it as the user's. On this Mac runs
  take about 0.2 s (note 08, O5).
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
  effective power source. The helper engine already takes presence as a
  separate input and refuses the adapter-disable while it is unknown; the
  app's telemetry and the helper's power reading still have to provide it.
- **Sleep and quit are not interlocks.** The app reacts to will-sleep and
  quit notifications, but cannot delay sleep until a request completes or
  finish a hung backend call. A privileged backend needs helper-owned sleep
  handling (`IORegisterForSystemPower` with acknowledgement), per-control
  leases that lapse to `.normal`, and bounded operations (XPC timeouts with
  connection invalidation). `HelperEngine` implements the leases and the
  sleep, wake and exit rules; the daemon still has to deliver those events
  and bound its calls.

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
corrupt data falls back to defaults with Manage charging off (failing toward
macOS defaults), with a visible notice. A first launch with nothing stored
uses the defaults as they are. Invalid settings are never saved. The selected backend is stored separately.

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
| D3 | Simulated backend is the default | Nothing changes until the user opts in; the only real control, macOS's Charge Limit, is experimental and opt-in |
| D4 | Control only on Apple silicon | macOS's Charge Limit needs Apple silicon; Intel Macs end at macOS 26, and no supported control exists there ([03](research/03-intel-differences.md)) |
| D5 | App Sandbox on | All current functionality works sandboxed, including launching `shortcuts` and `pmset` (note 08, O3); revisit only if a helper is adopted |
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
| D18 | An outside change to the native limit is adopted as the user's own limit: nothing is written and management is turned off (owner decision, 2026-10-06; replaces "fault and restore the recorded limit once") | A change made in System Settings is usually deliberate, and reverting it undid the user's choice. Turning management off keeps CellKeeper from overriding it later; turning management on again records the new value as the user's own |
| D19 | Automatic retries of a failed restore wait 60 s; user actions retry at once | Bounds shortcut runs while a backend is broken without delaying a restore the user asked for |
| D20 | The native backend is `experimental` and opt-in with a confirmation | Verified on one Mac; relies on an undocumented read-back |
| D21 | A backend switch that cannot restore `.normal` stays pending instead of being dropped; at launch, an outstanding record overrides the selected backend until it is restored | Restoring the user's limit must not depend on which backend the user selects or on the app staying open |
| D22 | The ownership record is a fsync'd file, written and read back before any change | `UserDefaults` persists asynchronously; losing the record after a change would lose the user's limit |
| D23 | "No limit" is recorded as 100% only after the user confirms it | The report cannot distinguish a 100% limit from temporary states; the owner's rule is never to assume 100% |
| D24 | Invalid settings are rejected before use, never applied | The UI only offers valid values; a rejected change keeps the previous valid settings, so there is no "invalid settings" state to restore from at run time. The policy still fails safe if handed invalid settings directly |
| D25 | An attempted restore stays owed until confirmed, across relaunches; any record found at launch makes it owed | Otherwise recognising an earlier change, a relaunch, or a marker that could not be saved could quietly abandon giving the user's limit back. The cost is one restore and re-apply after a crash |
| D26 | Only the limit crossing is debounced (two consecutive distinct readings, identified by the driver's update time where reported); cooling alone ends a temperature pause no sooner than 5 minutes after it began, but a new pause needs no wait (rules R14, R21) | The limit crossing is the one restricting change that is not a safety trigger, so a single wrong reading should not cause it. Safety triggers and changes toward macOS defaults act at once; a minimum before re-pausing would only delay protection |
| D27 | The helper's logic is its own target with no dependencies, built and tested against a simulated control before any mechanism is verified | Every safety rule the helper enforces can be tested in CI without hardware or root; the daemon and its transport then stay thin |
| D28 | After an outside change, the helper restores defaults until none of its own controls can still be active, then writes nothing on its own until a client restores. Start, shutdown and a client's restore still write | Restoring after every reading would fight another tool and toggle the hardware (R26, R27), but a restriction the helper set must never be abandoned; a client restore is a deliberate act |
| D29 | The helper's hourly activation cap counts both controls together; the one-minute interval is per control | R13 caps transitions in total; a discharge that ends in a hold needs both controls in quick succession |
| D30 | A restore that fails is owed until one reads back clean; ticks, sleep and wake, client restores and deactivations, and the end of the lease holder's session retry it, other requests never do | Any one failure must not leave a restriction in place for good, and a broken control must not be written in a loop |
| D31 | The helper separates "shutdown requested" from "safe to exit": after shutdown it serves only restores and keeps retrying until defaults are confirmed; the host exits then, or at its SIGTERM deadline | A transient failure during shutdown must leave a way to recover; if the deadline passes, the next start restores first (R2) |
| D32 | A failed or mismatched control write raises `writeFailed`, which refuses activations until a client restores defaults or for an hour (R11); a successful safety restore does not clear it | The restore makes the state safe, but the control is no longer trusted; repeated failures must not keep producing restricting writes |
| D33 | An activation refused by the activation limits restores defaults but raises no degraded mode (lead's decision, 2026-10-09; a deviation from R13) | A legitimate client can hit the per-control interval after a benign race, and its own fallback already asks for defaults |
| D34 | A session that makes more than 20 requests in a row beyond its budget, refused or served, is revoked and its controls cleared | Requests the budget does not refuse must not become a way around it (research note 04, §3.6) |
| D35 | The helper's clock is the system's `CLOCK_MONOTONIC`, and a new engine takes the activation history of the previous one in the same boot | A relaunch the client asks for must not reset the activation limits; the daemon persists the history and discards it at a new boot |
| D36 | The helper engine queues its events and delivers them, in order, when each operation has ended; the final checks before an activation (lease, power state's age, interlocks, activation limits) use one fresh clock reading and only pure checks separate them from the write, which `activationRecorded` then reports with its time (lead's decision, 2026-10-09) | A sink that ran mid-operation could block or re-enter the engine between a check and a write; removing that class of bug beats re-checking after every callback |
| D37 | A control that a failed or wrong restore may have made active counts as the engine's until it reads back inactive; a control active before and after a restore keeps its owner, and the state before is read afresh, falling back to the controls last known to be another tool's | A restore that went wrong must not leave a restriction that nothing retries, while another tool's control must not become the engine's to fight over. A tool that sets an inactive control during each restore still looks like a wrong restore (a known limitation) |
