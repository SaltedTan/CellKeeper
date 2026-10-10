# CellKeeper architecture

Status: milestone 2 (telemetry + policy engine + simulated control + macOS's native Charge Limit), plus the logic of the future privileged helper, which the app runs in process on a simulated control (the Simulated helper), the helper's NSXPC transport, tested over an anonymous listener but not used by the app yet, and the helper daemon's executable, which controls no hardware, does not serve that transport yet, and is neither installed nor embedded, and the logic that removes the helper only after its restore, tested against fakes. Last reviewed 2026-10-10.

This document describes how CellKeeper is put together and why. Research that
informed these decisions is in [`docs/research/`](research/README.md); safety
rules are in [`docs/safety.md`](safety.md).

## Principles

1. **Policy is pure.** The charging policy is a deterministic function of
   explicit inputs. It never touches hardware, IOKit, the clock, or private
   interfaces, so every rule is unit-testable without a Mac battery.
2. **Control is a narrow, swappable boundary.** All charging control goes
   through the `ChargingBackend` protocol. The implementations are a
   simulated backend, a read-only backend, a backend that sets macOS's
   own Charge Limit through a user-created shortcut, and a backend that
   drives CellKeeper's helper (simulated only so far). Anything that touches
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
   injection framework, six package modules plus the app.

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
│  SystemHelperPowerReading  – the helper's own read-only power state;          ││
│                              `HelperChargingBackend.simulatedHelper()`,       ││
│                              `MacOSChargeLimitMonitor.system()`               ││
│  XPCHelperTransport        – `HelperTransport` over NSXPC (not used yet)      ││
│  NoHelperRegistration      – the helper's registration: none in phase 4a      ││
└───────────────┬──────────────────────────────────────────────────────────────┘│
                │ depends on                                                    │
┌───────────────▼──────────────── CellKeeperCore (pure Swift, no IOKit) ────────▼───────────────┐
│  Telemetry:  BatterySnapshot, BatteryHealth, TelemetryProvider (protocol)                      │
│  Settings:   ChargingSettings (+ validation), SettingsStore (UserDefaults JSON)                │
│  Policy:     ChargingPolicy (pure state machine), PolicyInput/Decision/Memory, ChargeOverride  │
│  Control:    ChargingBackend (protocol), MockChargingBackend, ReadOnlyChargingBackend,         │
│              NativeChargeLimitBackend (+ ShortcutRunning / ChargeLimitReading /                │
│              OwnershipRecordStore protocols), HelperChargingBackend (+ HelperTransport /       │
│              HelperConnection protocols, InProcessHelperTransport), MacOSChargeLimitMonitor,   │
│              HelperRemoval (+ HelperRegistration protocol)                                     │
│  Controller: ChargeController (actor: telemetry → policy → backend, safety fallbacks, log)     │
│  Support:    CellKeeperLog (os.Logger categories)                                              │
└───────────────┬────────────────────────────────────────────────────────────────────────────────┘
                │ depends on (Kit too)
┌───────────────▼ CellKeeperHelperCore (pure Swift, Foundation only; run in process by the app) ─┐
│  Wire:     HelperProtocolVersion, HelperControl, HelperControlSet, HelperCapabilities,         │
│            HelperInterlocks, HelperStatus, reply values (primitives only, for NSXPC)           │
│  Engine:   HelperEngine (actor: sessions, per-control leases, rate limits, interlocks,         │
│            restore at start, exit and disconnect, read-back), HelperSession, HelperEvent       │
│  Seams:    HelperChargeControl (SimulatedChargeControl, UnknownHardwareChargeControl),         │
│            HelperPowerReading (the helper's own power state)                                   │
│  Names:    HelperServiceName (launchd label and Mach service)                                  │
└───────────────▲────────────────────────────────────────────────────────────────────────────────┘
                │ depends on (used by Kit, and later by the daemon)
┌───────────────┴ CellKeeperHelperXPC (NSXPC + Security, public APIs; shared by app and daemon) ─┐
│  CellKeeperHelperXPCProtocol (@objc, primitives only), HelperXPCWire (reply conversions)       │
│  HelperXPCServer (listener side: one session per connection, per-connection FIFO)              │
│  HelperXPCClient (client side: requirement, timeouts, unusable after any failure)              │
│  HelperCodeSigningRequirement (requirements both sides place on each other)                    │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
                  (the daemon depends on CellKeeperHelperCore only; its XPC frontend comes later)
┌─ CellKeeperHelperDaemon (IOKit, os; never the app's modules) ──────────────────────────────────┐
│  HelperDaemon (actor: start, ticks, SIGTERM, acknowledged sleep, exit), HelperFrontend         │
│  (NoFrontend), DaemonPowerReading, SystemSleepNotifications, SystemTerminationSignals,         │
│  FileActivationHistoryStore (boot session UUID), UnifiedHelperLog                              │
│  CellKeeperHelper (executable): main.swift assembles HelperDaemonEnvironment.system and runs   │
│  the daemon. Not embedded in the app, not registered with launchd                              │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- `Packages/CellKeeperKit` is a local Swift package (tools version 6.0, Swift
  6 language mode, macOS 14+) with four library products, the helper
  daemon's library target and executable product (`CellKeeperHelper`), and
  five test targets. `swift test` runs every non-UI test without opening
  Xcode. The app links only `CellKeeperKit`; the daemon is built by
  `swift build --product CellKeeperHelper`.
- `CellKeeper.xcodeproj` contains only the app target. It uses a
  file-system-synchronized group for `CellKeeper/`, so adding a Swift file
  needs no project edits. The project file format is pinned to
  `objectVersion = 77` (Xcode 16+); CI fails if a newer Xcode rewrites it.
- The boundary is enforced by dependency direction: `CellKeeperCore` cannot
  import `CellKeeperKit`, so policy code cannot reach IOKit.
- `CellKeeperHelperCore` depends on nothing. It holds the logic of the
  future privileged helper and the vocabulary the app and the helper share
  (see "Helper engine" below). `CellKeeperCore` depends on it for that
  vocabulary, and the app runs its engine in process for the Simulated
  helper (see "Helper backend").
- `CellKeeperHelperXPC` depends only on `CellKeeperHelperCore`. It holds
  everything the app and the daemon both need to talk over NSXPC (see
  "Helper transport" below); `CellKeeperKit` adapts its client to the app's
  `HelperTransport`. The app does not use it yet.
- `CellKeeperHelperDaemon` depends on `CellKeeperHelperCore` only, never on
  `CellKeeperCore` or `CellKeeperKit`, so the root process carries none of
  the app (D27, D58). See "Helper daemon" below. It does not use
  `CellKeeperHelperXPC` yet: the change that wires the transport in adds
  that dependency.

Requirement → location:

| Concern | Where | Status |
|---|---|---|
| Telemetry | `TelemetryProvider` (Core), `SystemTelemetryProvider` (Kit) | Implemented, read-only |
| Hardware/control backend | `ChargingBackend` (Core) | Simulated, read-only, native Charge Limit (experimental, opt-in), Simulated helper |
| Charging policy & state machine | `ChargingPolicy` (Core) | Implemented |
| Orchestration & safety fallbacks | `ChargeController` (Core) | Implemented |
| Persistence/settings | `ChargingSettings`, `SettingsStore` (Core) | Implemented |
| macOS UI | `CellKeeper/` app target | Implemented (menu bar + settings) |
| Scheduler | — | Future: will feed overrides into `PolicyInput` |
| Notifications | — | Future: driven from `ControlEvent`s |
| Shortcuts/automation | — | Future: App Intents calling `AppModel` intents |
| Privileged operations | `HelperEngine` (HelperCore), `HelperChargingBackend` (Core), `HelperXPCServer` / `HelperXPCClient` (HelperXPC), `XPCHelperTransport` (Kit), `HelperDaemon` (HelperDaemon), `CellKeeperHelper` | Helper logic and the app's backend implemented, with a simulated control only, in process (the Simulated helper); no hardware control. The NSXPC transport with code-signing requirements on both sides is implemented and tested over an anonymous listener. The removal of the helper (`HelperRemoval`, `ChargeController.removeHelper`) is implemented and tested against fakes. The daemon executable and its launchd property list exist, control nothing, and do not serve the transport yet; wiring the transport into the daemon, embedding and registration are future work |

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

Evaluations that defer to macOS's own Charge Limit (row 4 below) look at
the charge, so the latches keep following the readings meanwhile, and a
reading then counts toward the debounce.

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
  pause, on lost or stale telemetry, while macOS's own Charge Limit is on or
  unreadable, when the backend cannot discharge, or if its confirmed target
  is outside 20–95%. After it ends it never restarts by itself.

### Precedence (highest first)

| # | Condition | State | Desired mode |
|---|---|---|---|
| 1 | Settings invalid, or the controller requires a release (`ReleaseReason`: a pending backend switch, an unfinished restore, or a state it set but could not read back) | `failSafe` | normal |
| 2 | Management disabled | `unmanaged` | normal |
| 3 | No/stale telemetry (by read time, or by the driver's own update time > 180 s), future timestamps, no battery, unknown % or power source | `failSafe` | normal (a discharge session is interrupted) |
| 4 | macOS's own Charge Limit is on, or its report cannot be read and recognised (`ControlCapabilities.macOSChargeLimit`, reported by backends that switch charging themselves and check it) | `deferringToMacOS` | normal (nothing below applies; a discharge session is interrupted; the latches keep following the readings; whether a hold in place ended is up to the read-back) |
| 5 | Safety floor latched | `safetyFloor` | normal |
| 6 | On battery power | `onBattery` | normal (restrictions cleared; limit latch kept) |
| 7 | Temperature latch set (cooling clears it no sooner than 5 minutes after it was set) | `temperaturePause` | inhibitCharging |
| 8 | Temporary full charge active | `fullChargeOverride` | normal |
| 9 | Discharge session active | `discharging` | forceDischarge |
| 10 | Limit is 100% | `charging` | normal |
| 11 | Limit latch set (by two consecutive distinct readings) | `holding` | inhibitCharging |
| 12 | Sleep imminent and charge ≥ resume threshold | `holding` | inhibitCharging |
| 13 | Otherwise, including a first reading at or above the limit that awaits confirmation | `charging` | normal |

Row 4 is safety precondition 7 for backends that switch charging
themselves (decision D63): macOS's lower limit would win anyway (R25), so
CellKeeper asks for normal charging and withholds its own restrictions
rather than claim a limit it does not enforce, or fight macOS (R26). Its
reason names macOS's limit, or the read problem, describes that request
(not its outcome), and says to turn the limit off in System Settings ›
Battery.

### Native Charge Limit

With a native-limit backend (`ControlCapabilities.style == .nativeLimit`),
macOS enforces the limit. That includes its hysteresis: it resumes after a
drop of more than 5%. It also includes its behaviour during sleep and its
occasional calibration charge. CellKeeper only chooses the limit's value.
Rows 1 and 2 of the table above apply unchanged (invalid settings or a
required release, then management off), and so do override expiry and
unplugging. Row 3 does not (see "Missing or stale telemetry" below), and
row 4 never applies. The rest are replaced by:

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
    func capabilitiesForRelease() async -> ControlCapabilities // default: capabilities()
    func isReportedModeOwn() async -> Bool?               // default nil; no I/O
    func currentMode() async throws -> ChargeControlMode? // nil = unknown
    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome
    func reportedModeOrigin() async -> ReportedModeOrigin? // default nil; no I/O
    func outsideChangeEvidence() async -> Set<RecordedChange> // default []; no I/O
    func renewHold(_ mode: ChargeControlMode) async throws // default: nothing
    func resetAfterFault() async throws                     // default: nothing
    func recheckAvailability() async                        // default: nothing
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
- `ControlCapabilities.macOSChargeLimit`: macOS's own Charge Limit as a
  backend that switches charging itself last read it (the limit, 100 for
  none, or nil with the read problem; the read time; `isLimiting`, meaning
  on or unreadable). Nil for backends that do not check it: the native,
  simulated and read-only backends. While it is limiting, such a backend
  offers only `.normal`, keeps its availability (the backend is fine; macOS
  is in the way), and the policy defers to macOS (row 4 above).
- `capabilitiesForRelease()` is what `ChargeController.restoreNormal`
  (quitting, a backend switch, every safety fallback) asks for: the same
  as `capabilities()` without reading anything a request for `.normal`
  does not depend on, so a release never waits for it. The helper backend
  attaches the kept reading of macOS's Charge Limit instead of reading it
  again, and withholds restricting modes if it has none.
- `isReportedModeOwn()` says, by the backend's own records, whether what
  the last `currentMode()` reported is CellKeeper's (decision D64):
  - true if a control CellKeeper set, or may have set, is in effect;
  - false only on positive evidence that nothing in effect is CellKeeper's;
  - nil if that read threw, if the records cannot establish it, or if the
    backend keeps no records. Absence from the backend's bookkeeping is not
    evidence.
  The helper backend answers from the helper's change history, and only
  for a read that returns normally. True: a control it holds or may have
  set by a pending activation is active, or an active control's latest
  change is an activation by one of CellKeeper's sessions. False: nothing
  is active, or every active control's latest change is another client's
  activation or a change made outside the helper, with no restore owed
  (`hardwareFault`) and no failed write (`writeFailed`). Anything else is
  nil: a control a failed or wrong restore of the helper's may have made
  active (`restoredAfterWriteFailure`, `restoredAfterReadBackFailure`,
  `restoreRetried`; the engine's "own controls", D37), one a restarted
  helper left active because its start restore failed, one with no
  recorded change. The controller calls a restriction someone else's, and
  ends its responsibility for it, only on false; a reported outside change
  alone never does.
- `outsideChangeEvidence()` identifies, by the backend's own records, the
  changes behind the outside change it last reported with a read
  (`ReportedModeOrigin.changedOutside`) or threw
  (`BackendError.changedOutside`): a `RecordedChange` is the source that
  recorded it, the control and the change's generation. The helper
  backend gives, for each control whose latest change is another client's
  activation or a change made outside the helper (and for a control it
  held that ended that way), the helper's instance, the control's raw
  value and the generation, the same for a read and for a request. The
  controller uses it to log each outside change once: the same change read
  again is not news, and a newer one (a new generation, or one a restarted
  helper recorded) is, whatever the message says. Empty for a backend
  without such records; the controller then goes by the message.
- `recheckAvailability()` is the user's "check again": the next
  `capabilities()` must not rely on what the backend cached about what it
  depends on (the native backend's shortcut check; macOS's Charge Limit for
  the helper backend, read again at once).
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
- `reportedModeOrigin()` says how the mode last reported came about, when
  the backend knows more than the controller's comparison with the mode
  CellKeeper last confirmed: `cellKeeper` (CellKeeper set or restored it,
  even if it could not confirm it then; the native backend decides this from
  its record), `releasedByBackend(HoldRelease)` (the backend ended
  CellKeeper's hold under its own safety rules: a lapsed lease, an
  interlock, a lost connection, the backend stopping or restarting),
  `changedOutside(detail)` (the backend found a change CellKeeper did not
  make), or `needsAcknowledgement(detail)` (the backend stopped making
  changes until someone acknowledges a problem it found itself, such as a
  failed write). The last two are reported for as long as the backend sees
  them, also by a `currentMode()` that throws; an outside change the backend
  found earlier (while releasing a hold, say) is reported once, by the next
  read, even if the request that found it succeeded.
- Backends whose holds lapse unless renewed implement `renewHold(_:)`; the
  others keep the default, which does nothing. A backend never overrides
  another tool's change by itself; `resetAfterFault()` is called only when
  the user clears the fault, and is where a backend that waits for an
  acknowledgement (the helper after an outside change) may restore macOS
  defaults.

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
  Choosing the current kind of backend again cancels the pending switch.
  The app shows a pending switch for every backend, in the menu and in
  Settings › Control: which backend is still in charge, which one was
  chosen, and what the switch waits for (the user's own limit for macOS's
  Charge Limit, confirmed normal charging otherwise), with a button that
  stays with the backend in charge;
- if a read fails while CellKeeper holds a non-normal state, `.normal` is
  requested (`ReleaseReason.stateUnverified`). The last confirmed mode stays
  the expectation, so a reading that differs from it after reads recover is
  still treated as an outside change (and adopted, for a native backend). A request the backend accepted but
  that could not be confirmed is remembered, so finding it later confirms it
  rather than counting as an outside change. A request the backend rejected
  is not remembered. Native backends decide this from their record and
  report it as `reportedModeOrigin() == .cellKeeper`;
- a hold the backend reports it ended itself (`releasedByBackend`: a
  helper's lapsed lease, one of its interlocks, a lost connection, a helper
  that stopped or restarted) is not an outside change: the controller logs
  that the backend released the hold and why, takes the reported mode as its
  own, and evaluates as usual. An outside change the backend reports
  (`changedOutside`) faults it at once, like the controller's own detection,
  also while CellKeeper holds nothing; so does a backend that waits for an
  acknowledgement (`needsAcknowledgement`), with its own message, so the
  user is offered the fault reset. The controller looks for these after
  every read, not only an evaluation's: also when it confirms a request
  (including a successful `.normal`, which still counts as confirmed), in a
  fallback, and when the read itself fails, which then counts as no further
  failure (nor does the request whose confirming read it was). A problem
  needing acknowledgement is logged once for as long as the backend keeps
  reporting faults; an outside change once per change the backend recorded
  (`outsideChangeEvidence()`), or per message for a backend without
  records, so the same change read again is not logged twice and a newer
  one is never hidden behind the same message;
- renewal of the hold at the end of every evaluation in which CellKeeper
  holds a confirmed non-normal mode that the policy still wants, including
  evaluations whose action is "no change", and only if the backend accepts
  requests and is not faulted (`renewHold(_:)`). Nothing else renews, so a
  hung or stalled loop lets a helper's lease lapse (research rule R3). A
  failed renewal is counted like a failed request, and `.normal` is
  requested at once;
- clearing the fault (`resetBackendFault()`) calls the backend's
  `resetAfterFault()` before evaluating: the user's deliberate
  acknowledgement;
- a restore of `.normal` that was attempted and not confirmed stays owed
  (`ReleaseReason.restoreUnfinished`) until it is confirmed, whatever the
  settings say. The native backend persists this (`isRestoring`), so the
  next launch finishes it first. Finding an earlier change of CellKeeper's
  in effect does not cancel it;
- a backend that finds an outside change itself, just before writing
  (`BackendError.changedOutside`), faults at once, like the controller's own
  detection. A native backend adopts it instead (`adoptedOutsideChange`),
  which counts as nothing written. A backend that finds a problem it cannot
  attribute to anyone, or one of its own, throws
  `BackendError.needsAcknowledgement` instead, which faults at once too but
  names no outside writer;
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
| `HelperChargingBackend` (Simulated helper) | `simulated`, or `unavailable(reason)` | CellKeeper's own charge control at any limit through the helper's logic, run in process on a simulated control: nothing on the Mac changes. Restricts nothing while macOS's own Charge Limit is on. See "Helper backend". |

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

## Helper backend

`HelperChargingBackend` (Core) controls charging through CellKeeper's helper
(`HelperEngine`, see "Helper engine" below), reached through a
`HelperTransport`. Its style is `chargingModes`, so the policy offers every
limit from 20 to 100% with its resume threshold, temperature pause and
discharge sessions. Today the only helper is the Simulated helper, which
runs in process on a simulated control: nothing on the Mac changes.

**Transport.** `HelperTransport.connect()` opens a `HelperConnection`: the
helper's operations, with the same primitive arguments and reply types as
`HelperSession`. A method throws only for a transport failure; the helper's
refusals are reply statuses. `HelperSession` is a connection whose transport
never fails. `InProcessHelperTransport` builds an engine and runs it inside
the app: it starts it (restoring defaults) before serving the first
connection, ticks it every 5 s while the transport exists (the ticking task
holds the engine weakly and is cancelled with the transport), and forwards
sleep and wake. When the engine revokes a session, the transport closes that
connection: the request that caused it and every later one throw
`HelperTransportError.sessionRevoked`. `XPCHelperTransport` (Kit) is the
drop-in for the daemon: each connection is a `HelperXPCClient` that requires
the helper's code signature, and it throws `interrupted`, `invalidated`,
`requirementNotMet`, `timedOut` or `malformedReply` when the transport fails
(see "Helper transport" below). Any of them leaves that connection
unusable, and the backend connects again, as for any transport failure. A
revoked session's connection is closed by the server once the reply to
the request that caused it (`rateLimited`) has been sent, so over NSXPC
that request normally returns. A request sent after it throws once the
client has seen the connection close; one sent before then may instead
reach a new session that has not said hello, which refuses it
(`notIntroduced`, except a restore). Either way the backend reconnects.
The app does not use the XPC transport until the daemon can be registered
(phase 4b).

| Mode | Helper control | Lease |
|---|---|---|
| `.normal` | neither | none |
| `.inhibitCharging` | `chargingInhibited` | 900 s, renewed by evaluations |
| `.forceDischarge` | `adapterDisabled` | 120 s, renewed by evaluations |
| (both read back) | — | unknown: an error, so the controller fails safe |

- **Connection.** The backend connects lazily and introduces itself with
  `hello` at the current protocol version. A transport failure (including a
  connection closed after a revocation), or a session the helper no longer
  knows (`notIntroduced`, `shuttingDown`), drops the connection; the next
  request connects again, says hello and reads the state. Nothing is assumed
  after reconnecting.
- **Availability.** A helper that cannot be reached is `unavailable` (not
  installed or not running); so is one with an incompatible protocol (update
  needed) and one with no capabilities (it does not support this Mac yet:
  monitor-only, R12a). A simulated helper is `simulated`; any other would be
  `experimental` (not reached today). The supported modes follow the
  capability bits, minus every mode an interlock the helper reports blocks
  right now, so the policy refuses them as unsupported instead of counting
  failures.
- **macOS's own Charge Limit** (safety precondition 7, decision D63). With
  a `MacOSChargeLimitMonitor`, `capabilities()` attaches macOS's Charge
  Limit as last read and, while it is below 100% or its report cannot be
  read and recognised, withholds every mode but `.normal`, as for the
  helper's interlocks (D42), keeping the availability. A restriction asked
  for anyway is refused (`unsupportedMode`) and nothing is written. The
  monitor wraps a `ChargeLimitReading` (in the app, `pmset -g battlimit`,
  read-only, through `ChargeLimitReportParser`), keeps the latest reading
  with its date and problem text, and reads again only when it is 30 s old
  or older, so the capability checks of one evaluation run pmset at most
  once. A read under way is shared: every caller waits for it rather than
  return an older reading, and its result is kept before any of them
  returns. Reads are numbered and only the newest settled one counts: a
  result is kept only if no later read has been kept or cancelled, and a
  caller whose read was overtaken takes the current reading. A cancelled
  caller cancels the read it waits for, which stops pmset at once; a
  cancelled read is not kept, the reading before it is dropped too, and a
  caller still waiting for it that was not cancelled reads again, at most
  twice (`maximumRereads`); then it gets "may be limiting" (the read was
  interrupted), so other callers' cancellations cannot hold up an
  evaluation, and the commands queued behind it, without end.
  `recheckAvailability()` reads again at once. Only a
  recognised report of no active limit, or of 100%, counts as off; an
  unrecognised one (how an Optimized Battery Charging entry or a temporary
  state would appear) or a failed read counts as "macOS may be limiting",
  and replaces an earlier reading of "off". Nothing new happens on
  release: when macOS's limit turns on while CellKeeper holds a control,
  the policy wants `.normal`, and the ordinary release clears it,
  confirmed by a read like any other; `capabilitiesForRelease()` keeps
  quitting, switching and fallbacks from waiting for pmset. The controller
  logs a safety event saying whether a read-back confirmed the end, and, if
  not, another once one does; until then `ControllerStatus.ownRestriction`
  says the restriction may remain, and `MacOSChargeLimitWording` (the menu,
  Settings and the diagnostics report) says so too, marked as simulated on
  the Simulated helper. What CellKeeper may still have in effect
  (`ownRestrictionMode`) is kept apart from ownership bookkeeping and
  faults: it is set before a restricting request is sent (which also
  clears the mode last read, so a read taken before the request cannot
  vouch for it), and cleared only by a later read showing normal charging,
  or by `isReportedModeOwn() == false`, which needs positive evidence; an
  attempted restore, a fault or a restarted helper never clears it. The
  safety event fires for any such responsibility, also a hold that a failed
  restore, a failed activation, a restore that activated the other control,
  or a restarted helper whose start restore failed left unresolved. The
  helper's outside-change report says whether its restore read back clean
  or is owed (`hardwareFault`), and never claims a restore it has not
  confirmed. Other changes of
  macOS's limit are notices that claim no more than the report: its going
  off is "CellKeeper stops deferring to it", never "manages again".
  CellKeeper never turns macOS's limit off itself.
- **Reading.** `currentMode()` comes from a fresh `readState`, never from
  what CellKeeper asked for. A read-back the helper could not make is an
  error, but the interlocks and error count in that reply are still read, so
  a fault the helper reports is reported with it (below). A helper that
  cannot be reached while CellKeeper is responsible for nothing there
  reports an unknown mode, like a backend that accepts no requests, so it is
  not counted as failing.
- **Pending activations.** Before it sends an activation, the backend
  records it as pending: the control, the helper instance, the session it
  is sent on and the control's generation before. From then on the
  activation may take effect whatever happens to the reply, so CellKeeper
  stays responsible for the control. The next successful read settles it:
  if the helper names it as the control's latest change (`setByClient`, on
  that session, after that generation) and the control is active, it
  becomes a hold; otherwise CellKeeper does not own the control (it did
  not take effect, it has ended since, or the helper restarted). Ownership
  is not responsibility: the controller stays responsible for what the
  activation may have set until a read shows normal charging or the
  helper's history shows positively that nothing in effect is CellKeeper's
  (`isReportedModeOwn()`, D64). An active control CellKeeper does not own is
  classified by its latest recorded change, as for the end of a hold
  (below): another client's activation, clear or restore, or a change the
  helper recorded as made outside it, is reported as `changedOutside`, so
  the controller faults and does not set the control again (R27); anything
  else (one of the helper's own restores after a failure, a control it
  found active when it started, no recorded change) is reported as
  `needsAcknowledgement`, which faults just the same but names no writer;
  one of the helper's own releases is not reported. A pending activation
  grants no ownership: nothing is ever cleared on its account.
- **Ownership.** A hold records the generation of CellKeeper's activation.
  The control stays CellKeeper's only while that generation is current.
  Holds are kept across disconnects until a fresh read explains how they
  ended.
- **Setting.** The backend takes the control's longest lease, activates the
  control, confirms by a fresh read that the helper names the activation as
  the latest change, and only then clears the other control (if it is still
  CellKeeper's) and ends its lease, so switching between inhibit and
  discharge never allows charging the policy did not ask for. A final read
  must then show exactly that control (`verificationFailed` otherwise). The
  outcome is `simulated` for a simulated helper, otherwise `applied`, or
  `unchanged` if it was already in effect. An outside change found just
  before writing is `changedOutside`, and nothing is written.
- **`.normal`.** The backend reads the state, then clears each control it
  holds with `clearControlIfUnchanged`, naming the generation and helper
  instance of its own activation, ends only leases it holds, and confirms
  that nothing is active. The helper compares the change right before it
  clears, so a control that changed hands since the read (CellKeeper's lease
  ran out and another client set it) is never cleared: the helper writes
  nothing (`controlChanged`), and the next read shows the control as someone
  else's, so the request fails with `changedOutside`, which faults the
  controller (R26, R27). A control CellKeeper did not set is never touched
  either. The backend never asks the helper to restore defaults by itself.
  If the helper flags an outside change but nothing is active, `.normal` is
  in effect and confirmed, so quitting and switching backend are not
  blocked. An outside change found on the way is kept until a read reports
  it through `reportedModeOrigin()`, even when the release succeeds, so the
  controller faults (the confirmation of the `.normal` request is such a
  read).
- **Unresolved responsibility.** While CellKeeper may still hold a control it
  cannot confirm released, or one a pending activation may have set (the
  helper cannot be reached, cannot read its controls back, refuses to
  introduce CellKeeper because it is shutting down, or a release failed),
  the backend still accepts requests with only `.normal` supported, and
  `currentMode()` throws. The controller then keeps asking for `.normal`,
  counts the failures, and a backend switch stays pending, until a fresh
  read explains it: for example the restarted helper's start restored
  defaults.
- **Renewal.** `renewHold(_:)` renews CellKeeper's lease for the longest the
  helper grants. The backend keeps a deadline for each lease that is never
  later than the helper's (the time before the request plus the seconds
  granted). A lease past it is not renewed: a new lease would not bring back
  a control the helper has cleared, and the next read reports the lapse.
- **How a hold ended** is a lookup in the helper's history, not an
  inference from the state:

  | The helper's history shows | Reported as |
  |---|---|
  | The same generation | still CellKeeper's |
  | The next generation, control off, `leaseExpired` | `releasedByBackend(.leaseExpired)` |
  | The next generation, control off, `interlock` with only power and sleep interlocks (as they were then, even if lifted since) | `releasedByBackend(.interlock(…))`, named |
  | The next generation, control off, `sessionEnded` or `sessionRevoked` of a CellKeeper session | `releasedByBackend(.connectionLost)` |
  | The next generation, control off, `shutdown` or `start`; or a hold made with an earlier helper process, now off | `releasedByBackend(.backendStopped)` |
  | A hold made with an earlier helper process, still active | by the new process's record of the control (the row below for an active control): a control its first read-back found active before it wrote anything is recorded as `foundActiveAtStart`, which names no writer, so this is `needsAcknowledgement`, a fault that names none |
  | The next generation, control off, cleared by one of CellKeeper's sessions (also an earlier one, after a reconnect) | `cellKeeper`: CellKeeper's own release |
  | The next generation, control off, a restore after a failed write or read-back, or an interlock that needs an acknowledgement | a failure, reported by `currentMode()` |
  | The next generation, control off, cleared by another session (a deactivation or a restore), `changedOutside` or the restore after it | `changedOutside` |
  | The next generation, control off, `setByClient` or no recorded cause | `needsAcknowledgement`: a change the history does not explain |
  | Any other generation, or the control active again | by the latest change only (changes in between are unknown): another client's activation, clear or restore, or `changedOutside` or the restore after it → `changedOutside`, whatever the interlocks; anything else, including one of the helper's own restores after a failure, its start or shutdown, `foundActiveAtStart`, or no recorded change → `needsAcknowledgement`, naming no writer. Either way CellKeeper no longer owns the control |

  Releases are reported until CellKeeper's next request; an outside change,
  or a change the history does not explain, found in the history is kept
  until a read reports it. The engine reports causality; the backend does
  not infer it. An active control CellKeeper does not own is classified by
  its latest recorded change, as in the last row: `changedOutside` if the
  history names another client of the helper or a change the helper
  recorded as made outside it, whatever the interlocks; a control one of
  the helper's own restores after a failure, its start or shutdown left
  active, one it found active when it started (`foundActiveAtStart`), or
  one with no recorded change, is `needsAcknowledgement` with what the
  helper reports (a restriction CellKeeper cannot attribute, the helper's
  failure). Both fault the controller at once (R27), for as long as the
  backend sees them, and the backend refuses to set a control meanwhile; a
  request that finds such a control fails with `changedOutside` or
  `BackendError.needsAcknowledgement` to match. The controller handles
  both the same way whether a read reports them or a request throws them,
  in every path (an evaluation, a restore, a backend switch, quitting): it
  faults at once, counts the fault once, and logs a problem needing
  acknowledgement once while the backend keeps reporting faults, and each
  outside change once by what identifies it in the helper's history (the
  helper's instance, the control, the generation), also after a problem
  needing acknowledgement, so an existing fault never hides fresh evidence
  of another writer and the same change read again adds nothing. The helper's
  `externalModification` interlock is reported as `changedOutside`, and
  says whether its restore read back clean; if not, the helper retries only
  while a control it set itself may still be active, and otherwise writes
  nothing until the user clears the fault (D28). An outside change takes
  precedence over everything else.
- **Helper failures.** A helper that waits for an acknowledgement (an
  interlock other than the power and sleep conditions and an outside change:
  `writeFailed`, `hardwareFault`, or one this version does not know) is
  reported as `needsAcknowledgement`, which faults the controller at once so
  the user is offered the fault reset; the helper's hour of backoff for
  `writeFailed` stays as the fallback. This holds also when the helper
  cannot read its controls back: the mode is then unknown and the read
  fails, but the fault is reported with it, and the controller does not
  count the failed read on top. A hardware error the helper had not
  reported before (its count grew) is reported by the next `currentMode()`
  as a failure, whatever else that read shows, unless a fault is reported
  instead.
- **Acknowledgement.** `resetAfterFault()`, called only when the user clears
  the fault, asks the helper to restore defaults if it waits for a client to
  acknowledge something: an interlock other than the power and sleep
  conditions (an outside change, `writeFailed`, an owed restore), a control
  CellKeeper did not set, or a failed read-back. That ends every lease and
  may undo another tool's change, once, at the user's request. If the
  session ended before the restore arrived (`notIntroduced`, or a closed
  connection), the backend connects again, says hello, and tries once more.
  With the Simulated helper this resets only simulated controls.
- **Request budget.** Requests are paced against a copy of the session's
  request budget (with one token in reserve). Requests the budget may refuse
  wait for a token. Requests that only move toward safety (deactivations,
  lease releases, restores) go at once, but never more than 4 in a row
  beyond the budget, far below the 20 after which the helper revokes a
  session.
- **App Nap.** While CellKeeper holds a control through a live session and
  has not asked to release it, the backend holds a `ProcessInfo` activity
  (`userInitiatedAllowingIdleSystemSleep`, through `LeaseActivity`), so
  macOS does not nap the app, which makes a late renewal less likely but
  does not rule it out; an idle Mac may still sleep. It ends when CellKeeper releases the control,
  when a read shows the hold ended, and when the session ends, also while
  the hold stays unresolved (research note 04, §3.4).

**Simulated helper** (Kit). `HelperChargingBackend.simulatedHelper()` builds
an engine on `SimulatedChargeControl` and `SystemHelperPowerReading`, with
`HelperEngine.continuousUptime` as the one clock of the engine, the power
reading and the backend. On a Mac that has macOS's Charge Limit (Apple
silicon, macOS 26.4 or later: `NativeChargeLimitSupport.featureIssue()` is
nil) it installs `MacOSChargeLimitMonitor.system()` with
`PmsetChargeLimitReader`; if pmset is missing, every read fails and the
limit counts as unreadable. On a Mac without the Charge Limit it installs
none, and nothing is withheld for it. Releasing the backend (after a
backend switch) ends its session and stops the ticking. The app forwards NSWorkspace's will-sleep
and did-wake to the engine; unlike the daemon's, these are not acknowledged
sleep notifications.

`SystemHelperPowerReading` reads, read-only:
- the charge and the power source from IOPowerSources;
- adapter presence from `IOPSCopyExternalPowerAdapterDetails`, which is
  documented to describe the attached adapter and to return nothing when
  none is attached or on an error: present when it returns details, absent
  when it returns none on battery, unknown when it returns none on external
  power. Whether it still describes an adapter that a control has disabled is
  unverified (safety precondition 12); reading such an adapter as absent
  makes the helper clear the adapter-disable, the safe direction;
- thermal pressure: `ProcessInfo.thermalState` serious or critical.

Known limitations:
- Evaluations run every 60 s and on events; the adapter-disable lease is
  120 s. App Nap is prevented while CellKeeper holds a control through a
  live session, but a long
  command (a slow user action ahead in the queue) can still delay an
  evaluation and let a discharge's lease lapse. That is logged as the
  helper's release, and the discharge is requested again when the rate
  limits allow.
- The helper's activation limit also counts activations that the policy
  treats as relaxing (from discharge back to inhibit). In rare sequences the
  helper refuses an activation the policy allowed; that is a failed request.
- A helper that stops while CellKeeper is responsible for a control and
  cannot confirm defaults keeps the backend unresolved until the helper is
  reachable again; meanwhile each evaluation counts failures, and the
  backend faults.
- A lease release still clears the control if CellKeeper holds the lease;
  only the holder's session can have set a control under it, so this never
  clears another client's.
- macOS's Charge Limit is read periodically: at most every 30 s, and
  evaluations run every 60 s, so a change is normally seen within about a
  minute, and at worst after about 90 s (an evaluation that an event
  triggered can reuse a reading up to 30 s old). Until then a hold stays in
  place alongside macOS's limit; both only restrict, and the lower limit
  wins.
- Optimized Battery Charging, temporary states and battery health
  management are seen only if they appear in the `battlimit` report: an
  entry the parser does not recognise withholds restrictions, but a hold
  that leaves no entry there is not seen (note 08, I3 and open questions
  2–4). "Charge to Full Now" may appear as "no limit" (I2); CellKeeper's
  own limit then applies.
- A single failed read of macOS's limit asks for a hold's release (an
  earlier reading of "off" is not kept); the hold is taken again, within
  the rate limits, once a read shows no active limit.
- The check is the app's: the helper does not read macOS's limit itself.
  Whether it should enforce it independently is to be decided before any
  privileged write.
- In the App Sandbox, every pmset run logs the kernel's denial of pmset's
  own SMC user-client attempt (note 08, O7), now about once a minute while
  the helper backend is selected; the report is unaffected and no
  entitlement is added.

### Helper removal (`HelperRemoval`)

Safety precondition 9 and research rule R4: the helper is unregistered
only after it has confirmed that it restored defaults, and CellKeeper's
own state is back to normal before that. The one exception is a removal
the user forces, after reading the recovery procedure, when nothing could
confirm the restore (step 5 below). The logic is in Core and tested against fakes;
the app has no button for it yet, and no helper is registered in this
phase.

**Seam.** `HelperRegistration` (Core) is the system's registration of the
daemon: `status()` returns a `HelperRegistrationStatus` (`notRegistered`,
`enabled`, `requiresApproval`, `notFound`, or `unknown(detail)`, mirroring
`SMAppService.Status`, research note 04 §1.3, without importing
ServiceManagement), and `unregister()` removes it. The only implementation
in phase 4a is `NoHelperRegistration` (Kit): always `notRegistered`, so the
flow stops at its first step; its `unregister()` does nothing and is never
reached. Nothing in this phase calls `SMAppService`. Phase 4b supplies an
implementation on `SMAppService.daemon(plistName:)`, whose `unregister()`
also terminates a running daemon (note 04, §1.4); it treats the errors
that mean "already unregistered", `kSMErrorJobNotFound` and the EPERM that
macOS 26 is reported (unverified) to return instead, as already gone.

**Flow** (`HelperRemoval.remove()`):

1. Read the registration. `notRegistered` or `notFound`: nothing to remove,
   and no helper is contacted. Any other status, `unknown` included, goes
   on.
2. Connect, say `hello`, and send `restoreDefaultsAndExit`. A `hello`
   answered with a refusal (`incompatibleProtocol`, `notReady`,
   `shuttingDown`, `notIntroduced`, `rateLimited`) does not stop the flow:
   the engine serves restores without an introduction, before start and
   during shutdown. Only `ok` confirms defaults. The engine's other replies
   to this request are `hardwareError` (its restore did not read back
   clean; it keeps retrying, D30, D31), `notIntroduced` (the session no
   longer existed) and `rateLimited` (this request revoked the session);
   `notReady` and `shuttingDown` cannot occur.
3. Only after `ok`: `unregister()`, then read the registration again. The
   helper counts as removed only if that read says `notRegistered` or
   `notFound`, also when `unregister()` threw; anything else is
   `unregisterIncomplete` with the status and the error.
4. An explicit reply to `restoreDefaultsAndExit` other than `ok` is never
   overridden, with or without force (a refused `hello` is not such a
   reply: the restore is still sent, and may confirm). `hardwareError` means the restore did not read back clean and the
   helper keeps retrying it, so unregistering would stop the one process
   that is restoring; `notIntroduced` and `rateLimited` mean the request
   was refused, and nothing is known about defaults.
5. If nothing confirmed the restore because the transport failed or no
   reply arrived in time, at any stage (connecting, `hello` or the
   restore), the helper is not unregistered either.
   `remove(force: .userHasSeenRecoveryProcedure)` unregisters it anyway,
   and the outcome says that its restore was not confirmed. Such a helper
   can be broken in a way that would block its removal forever, for
   example one that answers `hello` and then never replies to the restore.
   Force is an acknowledged loss of assurance: unregistering terminates a
   running daemon, whose SIGTERM path attempts the restore, retrying until
   it is confirmed or about 7 s have passed (the rest of the 8 s shutdown
   deadline is kept for the log and the final check; D31, D59), and exits
   with status 75 if it is not confirmed; a missing reply does not
   show that the helper had stopped retrying; and an unregistered helper
   does not start at the next boot, so no start restore (R2) follows. What
   remains is a mechanism whose state outlives the helper, which is what
   the recovery procedure in `safety.md` covers.

| Outcome (`HelperRemovalOutcome`) | Helper confirmed defaults | Unregistered |
|---|---|---|
| `nothingToRemove(status)` | not asked | no |
| `removed(kind)` | yes | yes, and the status says it is gone |
| `unregisterIncomplete(kind, status:, error:)` | yes | asked; the status says it is still there |
| `restoreRefused(status, helper:)` | no: an explicit reply to the restore other than `ok` | no, and force is not offered |
| `restoreUnconfirmed(reason)` | unknown: the transport failed or no reply came in time | no; force is offered |
| `removedWithoutConfirmedRestore(reason)` (forced) | unknown | yes, and the status says it is gone |
| `forcedUnregisterIncomplete(reason, status:, error:)` (forced) | unknown | asked; the status says it is still there |

The reasons (`HelperNoConfirmationReason`) are `connectFailed`,
`helloFailed`, `noHello` (no `hello` within the deadline),
`restoreConnectionFailed` and `noRestoreReply` (the helper answered
`hello`, then the connection failed or the restore's reply did not
arrive in time).

Each outcome has a `summary` that says only what was confirmed. The kind
of helper comes from its `hello`: `simulated` ("restored its simulated
controls … your Mac's charging was not changed"), `monitorOnly` (no
capabilities, like the daemon of this phase: it "controls no charging on
this Mac" and changed nothing), `controlsCharging` ("restored macOS's
default charging and confirmed it"), or `unknown` when `hello` was refused
("its controls are back at their defaults"). No outcome without `ok` says
that defaults were restored, and only `hardwareError` says that the helper
keeps retrying: after any other refusal, a failure or a missing reply,
whether it restored defaults and whether it is still trying is unknown.
A forced removal also says that no helper starts at the next boot to
restore defaults, and that a mechanism's state may outlast the helper.

**Deadlines.** The conversation with the helper (connecting, `hello` and
the restore together) has 20 s; each NSXPC request also times out after
10 s on its own (D53). Each call to the registration has 15 s, more than
launchd's 10 s `ExitTimeOut`, in case unregistering waits for the daemon
to exit (unverified). Each deadline is an absolute expiry on a monotonic
clock that keeps counting during sleep (`ContinuousClock`, injected for
tests as `RemovalClock`). Whenever evidence arrives (a `hello`, a reply, a
failure, a registration result), it is judged against that expiry under
the lock that holds the decision (`HelperConversation`, and
`DeadlineResult` for each registration call): at or after the expiry, the
timeout outcome is frozen from the evidence recorded before, and the new
evidence is refused. The timer only wakes the same check; which callback
reaches the lock first never decides whether the deadline has passed. A
confirmation recorded before the expiry counts, also while the connection
is still being closed; a reply or a `hello` that arrives at or after it
authorises nothing, so a late `ok` never leads to unregistering, a helper
whose `hello` arrives late is not asked to exit, and a late registration
result changes nothing (a late status is `unknown`, a late unregistering
counts as unanswered). A deadline ends the wait, not the call: the call is
cancelled and its late result dropped. The flow runs in a task of its own and ignores the caller's
cancellation, so a confirmed restore is never left without its
unregistering and its report. `HelperRemoval` alone ends within about
65 s (20 s plus three registration calls); the controller adds its own
registration read and the backend's restore. Ignoring the caller's
cancellation bounds the waiting, not work that does not cooperate with
cancellation: such a call keeps running on its own, so the phase-4b
`SMAppService` adapter, like the NSXPC transport, must bound its own
completion and clean-up.

**CellKeeper's own state first.** `ChargeController.removeHelper(using:)`
(and `removeHelper(using:force:)`) runs under the controller's command
lock: it reads the registration and stops if no helper is registered,
without restoring anything; otherwise it restores normal charging on the
current backend and confirms it by read-back (`restoreNormal`; with
macOS's Charge Limit, the user's own limit, its record deleted only after
the read-back). If that is not confirmed, it stops
(`normalChargingNotConfirmed`) without contacting the helper. Only then
does it run the helper's flow. Holding the lock throughout keeps an
evaluation from applying a restriction between the two restores (lead's
decision, 2026-10-10). Each step and the outcome (`HelperUninstallOutcome`)
are recorded in the activity log.

Limitations:
- The app does not call it yet; the button comes with phase 4a's UI work.
- In the app today the registration is `NoHelperRegistration`, so a
  removal ends at its first step with "nothing to remove": nothing is
  restored, no helper is contacted, and the in-process Simulated helper
  keeps running. Only the tests, with a fake registration, take the flow
  further, and there a removal through the in-process transport leaves
  that engine shut down.
- After a removal, the controller keeps its backend; a helper backend then
  finds the helper gone and reports it unavailable. The UI work is to
  switch the app to the Simulated backend after a removal (lead's
  decision, 2026-10-10).
- While a removal runs, other commands wait for the lock, up to its
  deadlines; quitting waits for it at most 10 s, as for any slow restore
  (see "Data flow").
- Whether `unregister()` waits for the daemon to exit, and whether turning
  off the background item stops the daemon, are verified only with a
  registered helper (phase 4b). A helper whose approval was revoked
  (`requiresApproval`) may not run at all; it is then unreachable, and
  removing it needs force.

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
   SIGTERM; per-model allowlist and read-back. The helper exposes itself to
   the app as another `ChargingBackend` (`HelperChargingBackend`, above).
   Apple's published power-management
   source releases its private charge-inhibit assertions when the owning
   process exits, which would be a valuable fail-safe, but whether that holds
   on shipping Apple silicon is unverified.

The helper's logic exists as `CellKeeperHelperCore` (below), with a
simulated control only, and the app runs it in process as the Simulated
helper. Its NSXPC transport exists as `CellKeeperHelperXPC` (below), tested
inside the test process only. The daemon executable (`CellKeeperHelper`,
below) runs the same engine with no hardware control, but does not serve
the transport yet. Nothing is registered with launchd, and there is no
hardware control. Real control
will not be enabled without the
hardware verification protocol in research note 02 §7 and the rules in
`safety.md`.

### Helper engine (`CellKeeperHelperCore`)

`HelperEngine` is everything the helper decides, without the parts that
touch the system. It is pure Swift on Foundation: no IOKit, XPC, processes,
files or network. The layers, from the client down:

1. **Transport.** In process for the Simulated helper
   (`InProcessHelperTransport`), and over NSXPC (`HelperXPCServer`, which
   the daemon will serve as its `HelperFrontend`; see "Helper transport"
   and "Helper daemon" below). It opens one `HelperSession` per
   connection, forwards each request with its raw wire values, and
   invalidates the session when the connection ends. It delivers one
   connection's requests in order, one at a time; the engine itself is an
   actor, which would not order independent calls. When the engine revokes
   a session (`sessionRevoked`), the transport closes its connection.
2. **Session and engine.** Validation, leases, rate limits, interlocks and
   read-back, below.
3. **`HelperChargeControl`**, the only access to hardware: `probe()`,
   `apply(_:active:)`, `readBack()`, `restoreDefaults()`. A real control is
   the one place for undocumented operations and computes its capabilities
   only from a compiled-in, reviewed allowlist. `SimulatedChargeControl`
   (tests, contributor builds) changes nothing and says so.
   `UnknownHardwareChargeControl` has no capabilities and writes nothing; the
   daemon ships with it until a mechanism is verified (R12a).
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
| `hello(clientProtocolVersion)` | — | no | yes | Status, helper protocol version, build, capabilities, whether simulated, the caller's session number and the helper's instance. Any failed `hello` withdraws the introduction |
| `readState()` | refused | no | yes | Read-back controls, seconds left on each lease, whether the caller holds them, each control's latest change (below), interlocks, the last hardware error and the number of hardware errors since start |
| `acquireOrRenewLease(control, seconds)` | refused | — | yes | Grants or renews, clamped to 900 s (inhibit) or 120 s (adapter); one session holds leases at a time |
| `releaseLease(control)` | refused | holder | not refused¹ | Ends the lease and clears the control |
| `setControl(control, true)` | refused | yes | yes | Capability, then the checks, which end with every lease and the power state's age judged on a fresh clock reading; then, on that reading, the lease, interlocks and activation limits; then write and read-back |
| `setControl(control, false)` | refused | no | not refused¹ | Clears the control if the engine set it |
| `clearControlIfUnchanged(control, generation, helperInstance)` | refused | no | not refused¹ | Clears the control if the engine set it and its latest change is still `generation` on the helper process `helperInstance`; otherwise writes nothing and returns `controlChanged` |
| `restoreDefaults()` | allowed | no | not refused¹ | Ends every lease and restores defaults. Reads the hardware afresh and writes nothing if it shows defaults and no restore is owed; an owed restore is written even if defaults may already be in effect. Also served before start and during shutdown |
| `restoreDefaultsAndExit()` | allowed | no | not refused¹ | Restores defaults, then shuts down so the host can exit (update, uninstall). During shutdown, the same as `restoreDefaults()` |

¹ Except the one request that makes the session revoked (below), which
gets `rateLimited`, even a restore.

Only a live session is served. An invalidated or revoked session gets
`notIntroduced` for its restores, and `notReady`, `shuttingDown` or
`notIntroduced` for anything else, depending on the engine's phase.
Requests the budget does not refuse still spend a token when one is left,
and still count toward revocation.

The engine knows why each control changes, so `readState` reports it
instead of leaving clients to infer it. Per control (`HelperControlChange`,
four primitive fields on the wire):

- `generation`: how many times the control has turned on or off since
  start, as read-backs saw it;
- `cause` (a raw `HelperChangeCause`, 0 for none): `setByClient`,
  `clearedByClient` (a deactivation or a lease release), `clearedByRestore`,
  `leaseExpired`, `interlock`, `sessionEnded`, `sessionRevoked`, `shutdown`,
  `start`, `changedOutside`, `restoredAfterOutsideChange`,
  `restoredAfterWriteFailure`, `restoredAfterReadBackFailure`,
  `restoreRetried`, `activationLimited` or `foundActiveAtStart` (raw value
  16; raw values are never changed or reused, and a client reads one it does
  not know as no known cause);
- `interlocks`: for `interlock`, the interlocks that cleared it, as they were
  then;
- `session`: the session that made the change or whose end made it, by the
  number `hello` gave it; 0 for the engine's own changes and outside ones.

A change is recorded by the read-back that first shows it, for what the
engine was doing: a write records the change of the control it wrote, a
restore the changes of every control, and any other change a read-back finds
is `changedOutside`, except that a control the process's first successful
read-back finds active, before it has written anything, is
`foundActiveAtStart`: an earlier helper process may have set it, and the
engine cannot tell that from another tool. The checks record each clear
for the lease that ran out or the interlocks that made it, also when the
time limits are settled again after a slow write, in the same check or at
the end of the call. A lease
ending is not a change, so a later expiry never hides an earlier
deactivation. `hello` also returns the caller's session number and the
helper's instance (random, fixed for the process), so a client recognises
its own sessions' changes after reconnecting, and a restarted helper, whose
generations and session numbers start again. The host can read the same
history with `latestChange(of:)`, also during shutdown.

A client that releases a control it set names the change it set with
`clearControlIfUnchanged`: the engine compares the generation and the
helper instance with the latest change after its checks and right before
it clears, with nothing in between, so a control that changed hands since
the client last read it (its lease ran out, and another client set it) is
never cleared by mistake. Over the request budget it skips the checks, as a
deactivation does; every change made through the engine is already in the
history then, because each write is read back at once. Any live session may
still clear a control toward safety unconditionally, with
`setControl(control, false)` or a restore; the history names it.
`hardwareErrorCount` counts every hardware error since start, so a client
can tell a new error from an old one with the same code.

Statuses: `ok`, `incompatibleProtocol`, `notIntroduced`,
`unsupportedControl`, `invalidArgument` (unknown control, lease of 0 s or
less), `noLease`, `leaseHeldByOtherClient`, `rateLimited`,
`blockedByInterlock`, `hardwareError`, `shuttingDown`, `notReady` (before
the start-up restore), `controlChanged` (`clearControlIfUnchanged` found
another change; nothing written).

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
  checks read the hardware and the power state, and clearing a control
  writes to it, all of which takes time. So lease expiry and the power
  state's age, the time limits that only restrict, are judged on a clock
  reading taken after every read they depend on, and judged again on a
  newer reading whenever that cleanup made a hardware call, until a pass
  makes none. Every lease that has run out ends and its control is
  cleared; a power state that has gone stale raises
  `powerStateUnavailable`, which, like any interlock, clears what it
  blocks at once. This happens in every check: requests, ticks, sleep
  and wake, so an expired lease is cleared before `systemWillSleep()`
  returns. An activation then uses the last reading: only pure checks
  (its own lease, the interlocks, the activation limits) separate it from
  the write, and a refusal such as `noLease` comes after the cleanup.
  Any call that writes after that (an activation, a release, a
  deactivation, a client's restore, the end of a session) settles the
  time limits once more before it returns. During shutdown no lease
  remains and nothing is expected to be active, so there is nothing to
  settle; a restore still owed is retried by the shutdown path.
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
  The daemon persists it and discards it when the boot changes (see
  "Helper daemon"). The engine keeps only the latest 20 valid records it is
  given, found in one pass, which is enough for both limits; the daemon's
  reader bounds what it reads too.
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
  checks: compare the read-back with what the engine set, read the power
  state and recompute the interlocks, clear what they block, then judge
  the time limits as above. A read-back that fails is an unknown state,
  so defaults are restored (R1).
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
  the sink is never entered recursively. Delivery is synchronous, at the
  end of each call and before it returns: a sink that blocks delays that
  call's own reply and every operation after it, and a host that waits
  for `systemWillSleep()` before acknowledging sleep also waits for the
  delivery. So the daemon logs and persists asynchronously. Losing the
  last activation record in a crash is acceptable, because the next start
  restores defaults first.
- **Time (R22).** One monotonic clock that counts sleep, injected, shared
  with the power reading. `HelperEngine.continuousUptime` is the system's
  `CLOCK_MONOTONIC`: the same in every process, and counting from boot on
  macOS. That origin is observed (it matched `kern.boottime` to the
  millisecond on macOS 27, and exceeded sleep-excluding uptime by the time
  slept), not documented, so persisted values are kept only within a boot.
- **Its own thread (D62).** The engine runs on a serial dispatch queue of
  its own (a custom actor executor), not on Swift's cooperative thread
  pool. Its calls into the control are synchronous; a call that blocks
  holds that queue's thread, never one of the pool's few threads (as many
  as there are cores), which every other task needs, the host's shutdown
  and sleep handling and other clients' transport included.

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
- Calls into the control are not bounded in time by the engine. The real
  control must bound them; the daemon stops waiting for a hung call where
  it must (the sleep acknowledgement, the shutdown deadline) but cannot
  interrupt it.
- The engine relies on read-back alone; behavioural verification (R11, for
  example charge current after an inhibit), debounce (R14) and temperature
  dwell (R21) are not implemented.
- A power reading that is not refreshed after a wake clears every control
  at each wake.
- Persisting the activation history and exiting are the host's jobs (the
  daemon does both). Closing revoked connections and keeping each
  connection's requests in order are the transport's (`HelperXPCServer`
  does both).
- A blocking event sink delays the reply of the call that caused the
  events, the host's acknowledgement of sleep, and every later operation,
  for every client.

Not there yet: the daemon serving the NSXPC transport, the daemon's
registration (SMAppService) and embedding, and any real control. The NSXPC
transport and its code-signing requirements exist (below), and so does the
daemon with SIGTERM, acknowledged sleep and its own power reading (further
below), but nothing serves or uses the transport outside the tests.

### Helper transport (`CellKeeperHelperXPC`)

The NSXPC connection between CellKeeper and the helper daemon, on public
Foundation (`NSXPCConnection`, `NSXPCListener`) and Security (`SecCode`,
`SecRequirement`) APIs only. Nothing in it registers a launchd job or a
Mach service; the tests use `NSXPCListener.anonymous()` inside the test
process.

- **Interface.** `CellKeeperHelperXPCProtocol` has one method per request
  in the wire vocabulary table above, with the same raw `Int`, `UInt64` and
  `Bool` arguments and a single reply block of the reply's fields (16 for
  `readState`). No strings, collections or archived objects cross, so
  neither side ever decodes an object from the other. `HelperXPCWire`
  converts replies to and from their fields. The engine validates every
  argument. The client accepts only statuses it knows: any other raw
  status is `malformedReply`, never read as `ok`. Unknown capability,
  interlock and control bits and unknown change causes are kept as they
  came, as with the in-process transport.
- **Server** (`HelperXPCServer`, the daemon's side). It builds the engine,
  as `InProcessHelperTransport` does, so it sees the sessions the engine
  revokes. It sets the client requirement on the listener
  (`setConnectionCodeSigningRequirement`) before resuming it, and `start()`
  starts the engine, which restores defaults first, before the listener
  accepts anything. Each accepted connection gets its own session. A
  client can make the helper do only bounded work, and cannot delay the
  release of what it holds:
  - *Order.* NSXPC calls the exported object on the connection's own
    queue, which only appends the request to that connection's FIFO (an
    `AsyncStream` with one consumer task). The consumer opens the session,
    then runs the requests strictly in arrival order, one at a time, and
    sends each reply after the engine has returned. Connections run
    concurrently; the engine serialises them.
  - *Bounds.* At most 32 requests may wait behind the one in progress
    (`maximumQueuedRequests`; CellKeeper waits for each reply, and the
    engine's budget allows 10 at once). One more is a protocol violation:
    the server closes the connection, never drops a request silently. At
    most 8 clients are served at once (`maximumConnections`); one more is
    refused.
  - *End of a connection.* When a connection closes for any reason (the
    client quit, crashed or invalidated it, a protocol violation, a
    revocation, a stop), the session is invalidated at once, which clears
    what it held. The request in progress finishes, since the engine runs
    one call at a time, and nothing queued behind it runs. Every decision
    that ends admission (an overflow, a revocation, a stop, the connection's
    end) records the close in the same critical section that takes it,
    before the consumer can take another request; ending the queue and
    invalidating the connection and the session follow outside the lock.
  - *Revocation.* The engine's `sessionRevoked` event, delivered before the
    revoking call returns, marks the session. After that request the server
    invalidates the connection behind a send barrier, so the reply
    (`rateLimited`) is sent first; requests behind it never run.
  - *Lifecycle.* Resuming and invalidating the listener, and configuring,
    resuming and publishing each accepted connection, all happen under one
    lock together with the decision to do them, so `start()` cannot resume
    a listener `stop()` has invalidated, and a connection accepted while
    the server stops is either closed by the stop or refused. A server
    stopped before it ever listened resumes its listener once, already
    stopped, so that clients waiting to connect are refused rather than
    left waiting; it then invalidates it. `stop()` returns when every
    session is invalidated. Ticks, sleep and wake, SIGTERM and exit stay
    with the host, on `server.engine`.
  - *Audit.* The host gets each accepted connection (its session, process
    ID and effective user ID), each refusal and each close with its reason,
    asynchronously and in order on a queue of its own. Process and user IDs
    are for the log only, never for a decision (note 04, §2.3).
- **Client** (`HelperXPCClient`, the app's side). It connects to the
  daemon's Mach service with `.privileged`, or to an endpoint in tests, and
  sets the helper requirement (`setCodeSigningRequirement`) before
  `resume()`. Each call waits at most its timeout (10 s by default), and
  exactly one outcome is delivered per call: the reply, NSXPC's error, or
  the timeout, whichever claims the call first. (Tests inject the timer, so
  a timeout fires when the test says, after it has seen the helper stall,
  and never during connection setup.) Any failure (interrupted,
  invalidated, requirement not met, timed out, unreadable reply) makes the
  client unusable before the caller resumes: it records the failure,
  invalidates the connection and fails the calls in flight, and every later
  call throws `invalidated`. Otherwise NSXPC would reconnect an interrupted
  connection by itself on the next message, to a new session that has not
  said hello; and an invalidated connection delivers no late reply after a
  timeout. The backend then connects again with a new client.
- **Requirements** (`HelperCodeSigningRequirement`). A value always holds a
  requirement compiled by `SecRequirementCreateWithString`, because NSXPC
  treats a malformed one as a fatal error. The server and the client take
  one as a non-optional argument, so neither can be made without a
  requirement. Production builds use research note 04, §2.4: the helper
  requires `anchor apple generic and identifier "<CellKeeper's identifier>"
  and certificate leaf[subject.OU] = "<team>"` of its client, and CellKeeper
  requires the same of the helper, with the helper's identifier. The team
  is the building process's own, read from its signature (`SecCodeCopySelf`,
  `SecCodeCopySigningInformation`) and trusted only if the running code is
  valid against an Apple-issued certificate of that team. Identifiers are
  limited to the characters of bundle identifiers, so they cannot change
  the requirement. An ad-hoc or unsigned build has no team and cannot build
  either requirement; the daemon must then not listen (note 04, §2.4). The
  peer's process ID is never used (note 04, §2.3). The release-only
  clauses of note 04 §2.4 (Developer ID certificate fields, no
  `get-task-allow`) are not added yet: they can only be validated against
  signed builds, in phase 4b.
- **Tests.** The tests serve an engine on an anonymous listener in the test
  process, with the test process's own designated requirement on both
  sides (`SecCodeCopyDesignatedRequirement`; for the ad-hoc signed
  `swift test` host it names the exact build by its cdhash), so NSXPC checks
  a real code signature on every connection. Connections get a generous
  30 s for setup, and a refusal is never accepted as a timeout. The tests
  cover every request round-tripping with the in-process transport's
  replies; requirements that cannot match on either side; a stand-in
  helper that replies with a status this version does not know; arrival
  order over 300 pipelined requests; a burst across the revocation boundary
  and requests sent at the instant of revocation; disconnect, also while a
  request is blocked in the engine; the queue bound, also when the request
  in progress ends just as an overflow is decided; the connection limit;
  a timeout against a stalled engine; start and stop racing; connections
  arriving while the server stops; the audit events; and
  `HelperChargingBackend` reconnecting after the server drops its
  connection.

Limitations:

- The XPC runtime checks a peer when its first message arrives, so
  CellKeeper's first request may reach a helper that fails CellKeeper's
  requirement (note 04, §2.2). CellKeeper's requests carry nothing secret,
  and no reply from such a helper is delivered. A client that fails the
  helper's requirement never reaches the engine.
- A request sent in the moment between the helper closing a connection and
  the client noticing may reach the helper on a new connection, because
  NSXPC reconnects by itself. That session has not said hello, so the
  helper refuses everything but a restore, which only moves toward safety;
  the client closes itself as soon as it notices. A send barrier
  guarantees that a reply was sent before the connection closed, not that
  the client received it.
- A call is bounded by its timeout, but not cancelled with its task.
- Clients that fail the listener's requirement never reach the server, so
  the host cannot log them. The XPC runtime logs each one in the helper's
  process (observed on macOS 27: "Dropping check-in message due to code
  signing requirement", subsystem `com.apple.xpc`, category `connection`).
- Calls into the control are not bounded in time on the helper's side: a
  stalled control stalls the engine for every client, whose calls then
  time out. Being synchronous, it blocks the engine's own dispatch queue
  while it lasts, not a thread of Swift's cooperative pool (D62). The
  daemon stops waiting for such a call where it must (see "Helper
  daemon"), but cannot interrupt it; a real control must bound its calls.
  (The tests that stall the engine on purpose run one at a time, to keep
  their timing simple.)

### Helper daemon (`CellKeeperHelperDaemon`, `CellKeeperHelper`)

`CellKeeperHelper` is the executable launchd will run as root once it is
installed (phase 4b). Its `main.swift` only assembles
`HelperDaemonEnvironment.system(frontend:)` with a `NoFrontend` and runs a
`HelperDaemon`; everything else is in the `CellKeeperHelperDaemon` library,
which depends on `CellKeeperHelperCore` only and links IOKit (D27, D58). In
this phase it controls no hardware, serves no clients, and is neither
embedded in the app nor registered.

**Seams.** Every system dependency is a protocol with a system
implementation and a test fake. The tests run the real engine through the
daemon on a simulated control and a clock they move by hand, in
`swift test`, without root, launchd or a Mach service.

| Seam | System implementation | Role |
|---|---|---|
| `HelperChargeControl` | `UnknownHardwareChargeControl` | No capabilities, nothing written, so `hello` reports no capabilities and clients stay monitor-only (R12a). `HelperDaemonEnvironment.system` is the only public way to build the daemon's environment, and it always uses this control |
| `HelperPowerReading` | `DaemonPowerReading` | The daemon's own read-only power state (below) |
| `HelperDaemonClock` | `SystemDaemonClock` | `CLOCK_MONOTONIC` (`HelperEngine.continuousUptime`) for the engine and the power reading; waits until absolute deadlines on that clock (`Task.sleep` on the continuous clock) for ticks, polls and deadlines |
| `HelperFrontend` | `NoFrontend` | Serves clients. `NoFrontend` logs, through the daemon's asynchronous log, that this build has no listener, and serves nobody |
| `SleepNotifications` | `SystemSleepNotifications` | `IORegisterForSystemPower`, delivered on a dispatch queue |
| `TerminationSignals` | `SystemTerminationSignals` | SIGTERM through a dispatch signal source, its default action ignored |
| `ActivationHistoryStore` | `FileActivationHistoryStore` | The activation history file (below) |
| `HelperDaemonLog` | `UnifiedHelperLog` | `os.Logger`, subsystem `io.github.saltedtan.CellKeeper.Helper`, categories `lifecycle`, `xpc`, `control` and `safety`; every value `.public` (nothing logged is sensitive) |

**Start (R2).** `HelperDaemon.init` first handles SIGTERM (a signal that
arrives before `run()` is held, and `run()` then shuts down before serving
anyone), then loads the activation history saved earlier in this boot and
builds the engine with it, so a slow disk cannot leave SIGTERM unhandled.
`run()` then, in order: calls `engine.start()`, which restores defaults
and reads them back before anything else is served; registers for sleep
and wake; waits up to 0.5 s for the log, so that the start's restore is
usually written before anyone is served, without guaranteeing it; starts
the frontend, unless shutdown has begun meanwhile; and ticks the engine
every 5 s. If sleep notifications cannot be registered or the frontend
refuses to start, the daemon serves nobody and shuts down as below.

**A responsive coordinator.** The daemon's actor only coordinates, and
nothing that can block runs on it: every log line, the frontend's
included, is only enqueued for the log writer (`DaemonEventQueue`, which
the frontend receives as its log); the activation history is saved by the
same writer; and the frontend's `start` and `stop`, the sleep registration
and its removal, and the signal source's removal run off the actor. Nor
does anything that can block run on Swift's cooperative thread pool, which
the coordination needs (D62): the log writer (`DaemonEventWriter`) runs on
a dispatch queue of its own, the blocking seam calls on another
(`HelperDaemon.blocking`), and the engine on its own. So a log, a disk, a
frontend or a control that blocks cannot keep SIGTERM from beginning the
shutdown. Every wait carries an absolute deadline on the daemon's
clock and works out what is left when it actually starts: a timer that
starts late shortens its wait instead of postponing the deadline, a
deadline already passed is not waited for, and a result that arrives
after its deadline is not used.

**Frontend.** `HelperFrontend` (`start(serving:log:)`, `stop()`) is the seam for
the NSXPC listener: `HelperXPCServer` ("Helper transport" above) exists,
and a follow-up wires it into `main.swift` as the daemon's frontend. Its
contract, in the protocol's documentation: it is started
once, only after `engine.start()` has returned, and never during shutdown;
it checks every connection against a code-signing requirement for
CellKeeper's app before it opens a session, and throws rather than start
without one, in every build; it opens one session per connection, delivers
each connection's requests in order, invalidates the session when the
connection ends and closes the connection of a revoked session. A request
is *accepted* once the frontend has received it from a connection, and its
reply is *sent* once the transport has confirmed that the send completed:
for NSXPC, a send barrier (`scheduleSendBarrierBlock`) scheduled after the
reply has run. That confirms the send, not receipt by the client, which
would need an acknowledgement the protocol does not have. `stop()` stops
accepting connections and requests, waits until every accepted request has
been answered and its reply sent (the reply to a `restoreDefaultsAndExit`
before that client's session is invalidated), invalidates every session
and closes every connection, and returns true only once all of that is
done. That return is the frontend's confirmation that nothing it accepted
can still change the engine's state. An implementation that discards queued
requests, or invalidates connections before their replies are sent,
returns false unless every accepted request still got its reply sent.
`HelperXPCServer` as merged with #64 builds its own engine, and its
`stop()` invalidates connections before draining replies and discards
queued requests; the change that wires it in must make it serve the
daemon's engine and drain its replies before its `stop()` may return
true.

**Shutdown (R4, D31, D59).** It begins on SIGTERM, when the engine shuts
down at a client's request (`restoreDefaultsAndExit`; the engine's
`shuttingDown` event is noticed as the sink receives it, so a slow log
cannot delay it, and handled on the daemon's own task), or when a seam
cannot start. Whatever began it, one absolute deadline, 8 s after it began
(`ExitTimeOut`, 10 s, less a 2 s margin), bounds all of it, logging and the
final decision included. Every wait is bounded by what is left, and a step
with no time left is skipped. In order:

1. The frontend is told to stop. The daemon waits up to 1 s for its
   confirmation before it restores, and keeps watching for it afterwards.
2. `terminate()`, then about once a second again, until the frontend has
   confirmed and the engine is safe to exit, or until 1 s before the
   deadline (a frontend that reports it could not stop cleanly ends this
   at once).
3. The log is written, until 0.5 s before the deadline at the latest.
4. The final check of `isSafeToExit`, bounded by the deadline, made only if
   the frontend has confirmed: until then a request it accepted could still
   make a restore owed, so nothing is safe.
5. Only now is the exit status committed: 0 if that check passed, and
   otherwise 75 (`EX_TEMPFAIL`). launchd restarts a job that exits non-zero
   (`KeepAlive.SuccessfulExit = false`), and the next start restores
   defaults first. Ticks keep retrying an owed restore, and SIGTERM stays
   handled (a second one is ignored), until this point. The decision is
   logged, and the log waited for within what is left of the deadline.

The deadline holds with a stuck engine, a log that cannot be written, or
a timer that starts late: the daemon stops waiting and exits, though it
cannot interrupt a call to the control. After a seam that cannot start, a
clean exit (0) means launchd starts the daemon again only on demand, not
in a loop.

**Sleep and wake (R16, R17, precondition 13, D60).**
`kIOMessageCanSystemSleep` is allowed at once; the daemon never vetoes
sleep. On `kIOMessageSystemWillSleep` the daemon calls
`engine.systemWillSleep()` and acknowledges (`IOAllowPowerChange`) only
once it has returned, or 5 s after the announcement at the latest, with a
fault in the log. The deadline runs from the announcement, whatever the
engine is busy with. An unacknowledged sleep notification only delays sleep,
by up to 30 s, and the engine's leases count sleep, so holding sleep for a
stuck engine would buy nothing. `kIOMessageSystemHasPoweredOn` calls
`engine.systemDidWake()`. Sleep and wake reach the engine in the order they
happened. `IORegisterForSystemPower` does not report shutdown or restart;
SIGTERM covers those.

**Power reading (R9, R17, D45, D58).** `DaemonPowerReading` reads only
public, read-only IOPowerSources data: the charge from the internal
battery's `kIOPSCurrentCapacityKey` over `kIOPSMaxCapacityKey` (unknown if
`kIOPSIsPresentKey` says the battery is absent); external power from
`IOPSGetProvidingPowerSourceType` (AC power is external, battery power is
not, anything else is unknown); adapter presence from
`IOPSCopyExternalPowerAdapterDetails` by D45's rules; thermal pressure from
`ProcessInfo.thermalState` serious or critical. Each reading is stamped
with the uptime taken just before it. Only those three battery keys, and
whether adapter details exist, are kept, so no identifiers are read. The
reading repeats `SystemHelperPowerReading`'s rules on purpose, because the
daemon must not depend on the app's modules; the one difference is that the
app's reading consults the battery's own power source state before the
providing source.

**Activation history (D35, D61).** On every `activationRecorded`, the
daemon's event task saves a snapshot of `engine.activationHistory` with the
boot identifier: the boot session UUID, which the kernel generates once
per boot (`kern.bootsessionuuid`, read with `sysctlbyname`; read-only, not
declared in the SDK's headers, observed on macOS 27), and which must parse
as a UUID. Nothing derived from the wall clock identifies the boot:
`kern.boottime` moves when the calendar time is set (XNU's
`osfmk/kern/clock.c`), so a clock step followed by a relaunch would have
discarded valid records and reset the limits within one boot. At start, the
saved records go to the engine only if they were saved in this boot
session. The file is
`/Library/Application Support/CellKeeper/Helper/activation-history.json`:
versioned JSON (version 2) with at most the latest 20 records, written to a
temporary file in the same directory and renamed over the old one. The
reader opens it without following a symbolic link and without blocking,
refuses anything but a regular file at once (a FIFO with no writer would
otherwise hold the daemon before its start-up restore), refuses a file over
64 KiB, and discards the whole history on any decoding problem, another
boot, or a record whose time is negative or later than now; it keeps the
latest 20.
Loading never prevents start: anything unusable is logged and the engine
starts with an empty history. A save that fails, for example when the
daemon is run as an ordinary user who cannot write under `/Library`, is
logged once until a save succeeds again, and the daemon carries on. Without
a boot identifier nothing is loaded or saved; there is no fallback.

**Audit log.** The engine's sink only enqueues. One task writes the
engine's events and the daemon's own lines to unified logging, in order,
and saves the history, so the sink returns at once (the engine waits for
its sink before it replies, and before `systemWillSleep()` returns). The
levels follow the Simulated helper's log: routine events (sessions opened
and ended, lease grants and renewals, writes, activation records) at info,
everything else at notice, and failed restores and hardware errors at
fault. During shutdown the daemon waits for the log within the deadline
(above). Read it with
`/usr/bin/log show --info --predicate 'subsystem == "io.github.saltedtan.CellKeeper.Helper"'`.

**launchd property list.**
`Config/LaunchDaemons/io.github.saltedtan.CellKeeper.Helper.plist`: `Label`
and its one `MachServices` entry are `io.github.saltedtan.CellKeeper.Helper`
(`HelperServiceName.label` and `.machService`, in `CellKeeperHelperCore` so
the app can share them); `BundleProgram` `Contents/MacOS/CellKeeperHelper`;
`KeepAlive` {`SuccessfulExit`: false, `Crashed`: true}, which restarts the
daemon after a crash or a non-zero exit and implies a run at load (research
note 04, §1.2); `ProcessType` `Adaptive`; `ExitTimeOut` 10
(`HelperDaemon.exitTimeout`); `AssociatedBundleIdentifiers`
[`io.github.saltedtan.CellKeeper`]. A test reads the file and checks it
against those constants. `HelperBuild.number`, which `hello` reports,
equals the app's `CURRENT_PROJECT_VERSION`; a test checks that too.

**Not there yet:** serving the NSXPC transport (`HelperXPCServer` as the
daemon's frontend, with the changes above) and its wiring into
`main.swift`;
embedding the executable and the property list in the app bundle; signing,
`SpawnConstraint` (it needs a team identifier) and `SMAppService`
registration (phase 4b, issue #57); idle exit and a check that the app
bundle still exists (research note 04, §3.5). Nothing in this repository
registers a launchd job, installs the property list, or creates a Mach
service.

Limitations:

- A SIGTERM in the first instants of the process, before the daemon's
  initialiser handles signals, ends it at once; nothing has been done yet,
  and the next start restores defaults.
- A hung control call cannot be interrupted. The daemon stops waiting for
  it to acknowledge sleep and to exit at the shutdown deadline, but
  requests and ticks wait behind it.
- A log that cannot be written also holds back saving the activation
  history, which shares its task; a relaunch in the same boot would then
  not know the latest activations.

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
  sleep, wake and exit rules; the XPC client bounds every call with a
  timeout and invalidates the connection after one; and the daemon delivers
  acknowledged sleep and SIGTERM to the engine with bounded waits. The
  daemon does not serve the transport yet, and a real control still has to
  bound its own calls.

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

The helper daemon keeps one file, its activation history, under
`/Library/Application Support/CellKeeper/Helper/` (see "Helper daemon").

## Logging

`CellKeeperLog` defines `os.Logger` categories (`app`, `telemetry`, `policy`,
`backend`, `safety`, `settings`) under the app's bundle identifier. Telemetry
changes log at info level (memory only); decisions, requests, results,
settings changes, and safety fallbacks log at notice level or above so they
persist. Logged content is limited to battery state, settings values, and
decisions.

The helper daemon logs under its own subsystem,
`io.github.saltedtan.CellKeeper.Helper`, in the categories `lifecycle`,
`xpc`, `control` and `safety` (research note 04, §3.7).

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
  [05](research/05-distribution-and-signing.md). The XPC transport already
  pins both sides (identifier, Apple-issued certificate and the team read
  from the process's own signature); an ad-hoc contributor build cannot
  build those requirements, so it can never talk to a release helper.

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
| D36 | The helper engine queues its events and delivers them, in order, when each operation has ended (lead's decision, 2026-10-09). Lease expiry and the power state's age are judged on a clock reading taken after every read they depend on, and again after any write, including the last write of a request, before the call returns; an activation follows on that reading with only pure checks, and `activationRecorded` reports the write with its time | A sink that ran mid-operation could block or re-enter the engine between a check and a write; removing that class of bug beats re-checking after every callback. A time limit judged on a reading taken before a slow read or write could let an expired lease or a stale power state stay in force |
| D37 | A control that a failed or wrong restore may have made active counts as the engine's until it reads back inactive; a control active before and after a restore keeps its owner, and the state before is read afresh, falling back to the controls last known to be another tool's | A restore that went wrong must not leave a restriction that nothing retries, while another tool's control must not become the engine's to fight over. A tool that sets an inactive control during each restore still looks like a wrong restore (a known limitation) |
| D38 | `readState` reports, per control, a change generation and the cause, interlocks and session of its latest change, and how many hardware errors there have been; `hello` gives the caller's session number and the helper's instance. Any live session may still clear a control toward safety (lead's decisions, 2026-10-09). A control the first successful read-back of a process finds active, before any write, is recorded as `foundActiveAtStart`, never as `changedOutside` (amended 2026-10-10) | Snapshots of active bits, current interlocks and lease state cannot establish why a control changed; the engine knows, so a client's classification becomes a lookup. Limiting deactivation to the lease holder would make a move toward safety depend on who asks |
| D39 | The app renews a helper lease only at the end of an evaluation that still wants the mode it holds, including one that changes nothing; a failed renewal is a failure and `.normal` is requested at once | Safety precondition 3 and rule R3: a hung or stalled policy loop must let the restriction lapse, and a renewal that cannot be made must not leave one in place |
| D40 | The helper backend owns a control only while the change generation it recorded at activation is current, and classifies how a hold ended by the cause the helper recorded for the next change. An expired lease, a power or sleep interlock (as raised then), the end of one of CellKeeper's sessions, or a helper shutdown or start is logged as the helper's release; CellKeeper's own deactivation, also from an earlier session, is its own; anything else, including any later generation, another client's restore or deactivation and `externalModification`, faults the backend at once. The fault names an outside writer only when the helper's history does (another client's change, or an outside change the helper reports); otherwise it says what the helper reports, without a writer (amended 2026-10-10) | Only the helper knows why a control changed; inferring it from active bits, current interlocks or lease state misreads handoffs, later expiries and lifted interlocks. The helper's releases are its safety rules working, and faulting on them would stop control for nothing; anything else may be another tool, which R27 says to stop for |
| D41 | The helper backend never asks the helper to restore defaults by itself; `.normal` clears only controls CellKeeper still owns, each with `clearControlIfUnchanged` naming its own activation (D48), ends only leases it holds, and succeeds when nothing is active, even after an outside change, which faults the controller through `reportedModeOrigin()`. Only the user clearing the fault restores defaults, and only if the helper waits for that (lead's decision, 2026-10-09) | A restore or deactivation may undo another tool's change (R26, R27), so it must be a deliberate act; and quitting or switching backend must not be blocked while macOS's defaults are in effect |
| D42 | Modes an interlock of the helper blocks are not offered by the backend's capabilities | The policy then refuses them as unsupported instead of counting each refusal as a failure, which would fault the backend for conditions such as a warm Mac or a low battery |
| D43 | The helper backend paces its requests against a copy of the session's request budget, and sends at most 4 requests in a row beyond it | A well-behaved client must never be refused or revoked (20 in a row), including during bursts of user actions; moves toward safety must not wait for a token |
| D44 | While CellKeeper holds a control through a live helper session and has not asked to release it, the app holds a `ProcessInfo` activity that prevents App Nap but allows idle system sleep; it ends with the session, also while the hold is unresolved | A napped app renews late and lets the lease lapse, which toggles charging for nothing; idle sleep is fine, because the lease counts sleep and the helper handles it (research note 04, §3.4). Without a session there is nothing to renew, and keeping the app awake would only cost energy |
| D45 | The Simulated helper reads adapter presence from `IOPSCopyExternalPowerAdapterDetails`: present with details, absent without on battery, unknown without on external power | It is documented to describe the attached adapter; behaviour with a disabled adapter is unverified (safety precondition 12), and an adapter wrongly read as absent only makes the helper clear the adapter-disable |
| D46 | CellKeeper stays responsible for a control from the moment it sends an activation (recorded as pending, with the helper instance, the session and the generation before) and for a hold it cannot confirm released, across failed replies, disconnects, failed releases and helper shutdowns: until a fresh read settles it from the helper's history, the backend accepts only `.normal` and reports its mode as an error, so a backend switch stays pending. A pending activation becomes a hold only when the helper names it as the latest change; it never grants ownership by itself, but a later change by another client or tool is reported as an outside change | An activation may take effect even if its reply or the read after it is lost, and a helper that cannot be asked may still enforce CellKeeper's restriction; completing a switch then would leave it in place with nothing renewing or releasing it. Owning on a guess could clear another client's control |
| D47 | A helper that waits for an acknowledgement because of its own failure (`writeFailed`, an owed restore, or an interlock this version does not know) faults the backend at once with that reason, also when the helper cannot read its controls back (the mode is then unknown); a hardware error the helper had not reported before is a failure of the next read, whatever else it shows | The user must learn of a broken control when it happens, not after a lease expiry, an hour of backoff or three failed reads, and only the fault reset offers the restore the helper waits for; a recovered error must still be counted |
| D48 | The helper's wire API has a conditional deactivation, `clearControlIfUnchanged(control, generation, helperInstance)`, which the engine checks after its checks and right before clearing, and which writes nothing on a mismatch (`controlChanged`, raw value 12); `setControl(control, false)` and the restores stay unconditional (lead's decision, 2026-10-10) | A client that checks ownership and then clears in a second request can clear a control that changed hands in between; only the engine can compare and clear atomically. Deliberate clears and safety restores must not depend on what a client last saw |
| D49 | An outside change a backend finds is kept until a read reports it, even if the request that found it succeeds, and the controller handles faults a backend reports after every read: request confirmations, fallbacks, recovery reads and reads that fail, not only an evaluation's | Otherwise a successful `.normal` could erase the only notice of another tool's change, and the next evaluation would set the restriction again without a fault (R27) |
| D50 | Each helper connection's requests go through a FIFO with one consumer: strictly in arrival order, one at a time, each reply sent after the engine returns. A revoked session's connection is closed behind a send barrier after the reply to the revoking request, and requests after it never run | NSXPC delivers each connection's messages on its own queue, and the engine is an actor that does not order independent calls, so the order must be explicit (research note 04, §3.6). The revoking request's reply tells the client why |
| D51 | Both sides of the helper connection always carry a code-signing requirement: the helper requires CellKeeper's identifier, CellKeeper the helper's, each with `anchor apple generic` and the team identifier read from the process's own signature. Requirements are compiled before NSXPC sees them, the server and the client cannot be made without one, and an ad-hoc build cannot build the production ones | Research note 04, §2.4: certificate clauses are false for ad-hoc code, and an identifier alone is chosen by whoever signs. Reading the team from the signature works for the project's and a contributor's own team without configuration. NSXPC treats a malformed requirement as a fatal error; PIDs are unsafe (§2.3) |
| D52 | After any transport failure (interruption, invalidation, unmet requirement, timeout, unreadable reply) the XPC client is unusable: it invalidates its connection before the caller resumes, fails the calls in flight, and every later call throws; the backend connects again with a new client and reads afresh | NSXPC would otherwise reconnect an interrupted connection to a new session by itself, and a timed-out call's late reply must never be delivered. A fresh connection keeps the helper's state the only source of truth (D46) |
| D53 | Every helper call times out, after 10 s by default. A timeout is a transport failure: the connection is invalidated, so the helper ends the session and clears what it held | A hung helper must not hang the app's controller (safety precondition 13). The engine answers in milliseconds, so 10 s only fires on a stuck helper, and ending the session moves toward the safe state |
| D54 | A helper reply with a status this version does not know is an unreadable reply, a transport failure, and is never mapped to a status | A guess could read a refusal as `ok`. Failing the connection makes the backend read the state afresh, and a helper that keeps sending it is unavailable |
| D55 | A client can make the helper do only bounded work: at most 32 requests wait behind the one in progress on a connection, and one more closes the connection as a protocol violation; at most 8 connections are served. A closed connection runs nothing more and its session is invalidated at once (after review, 2026-10-10) | The engine's request budget is judged only when a request runs, so it cannot bound what waits; a flooding client could otherwise pile up work that delays the end of its own session, and with it the release of its restriction. A silent drop would leave a client waiting for a reply that never comes |
| D56 | The server's registry lock serialises the listener's lifecycle (resume, invalidate) and the acceptance of each connection (configure, resume, publish), each together with the decision to make it; a server stopped before it ever listened resumes its listener, already stopped, and then invalidates it. Each connection's close is recorded under that connection's own lock, in the same critical section that decides it, which ends admission before its consumer can start another request; ending its queue and invalidating the connection and the session follow outside the lock | Releasing a lock between deciding and acting let a stop be undone by a start or an acceptance in progress, and let a consumer start a queued request after an overflow had been decided. A listener invalidated while still suspended left connecting clients waiting with no answer (seen in the start/stop race test) |
| D57 | The server reports accepted connections (session, process ID, effective user ID), refusals and closes to the host asynchronously, for its log only | Research note 04 §3.7 asks for every accept and reject to be logged; process IDs are reused, so they never decide anything (§2.3). Clients that fail the requirement never reach the server; the XPC runtime logs them |
| D58 | The daemon's library depends on `CellKeeperHelperCore` only and repeats the app's read-only power reading instead of sharing it; the only public way to build the daemon's environment uses `UnknownHardwareChargeControl` | D27: the root process carries none of the app, and a second copy of a few dozen lines costs less than linking the app's modules into it. With no public interface that accepts another control, a real control needs a reviewed change to `HelperDaemonEnvironment.system` |
| D59 | Every shutdown (SIGTERM, a client's `restoreDefaultsAndExit`, a seam that cannot start) runs one procedure within one absolute deadline 8 s after it began: stop the frontend and have it confirm that everything it accepted is answered and every session invalidated; terminate and retry; write the log; then the final bounded `isSafeToExit` check, made only after that confirmation; only then commit the exit status, 0 if the check passed and 75 (`EX_TEMPFAIL`) otherwise. Retries and SIGTERM handling stay live until the commit. The daemon's actor only coordinates: nothing that can block (log writes, history saves, frontend calls, sleep and signal registration) runs on it, and every wait carries an absolute deadline that it recomputes when it starts (reviews of PR #65) | The exit status must come from the last safety check, after everything that could still change safety: a request the frontend accepted can still make a restore owed, so an unconfirmed stop establishes nothing, and a check before the log is written can be outdated by then. launchd restarts a job that exits non-zero (`KeepAlive.SuccessfulExit = false`), and the next start restores defaults first (R2, D31); one deadline that includes logging keeps the exit ahead of SIGKILL at `ExitTimeOut` even with a stuck engine or log; a coordinator blocked by a log write cannot even begin the shutdown, and a timer that restarts its duration when it starts late postpones the deadline into launchd's margin; a clean exit after a failed start is restarted only on demand, not in a loop |
| D60 | Sleep is acknowledged when the engine's sleep checks return or 5 s after the announcement, whichever comes first, with a fault logged at the deadline | Safety precondition 13 asks for acknowledged sleep handling in the privileged component; an unacknowledged notification only delays sleep (by up to 30 s) and the engine's leases count sleep, so holding sleep for a stuck engine would buy nothing |
| D61 | The activation history file is keyed by the boot session UUID (`kern.bootsessionuuid`), with no fallback; it is bounded (64 KiB, 20 records), replaced by rename, opened without blocking and refused at once unless it is a regular file, discarded whole on anything unexpected, and loaded only after SIGTERM is handled (review of PR #65) | The engine's clock starts again at every boot (D35), and only a value the kernel sets once per boot identifies one: `kern.boottime` moves when the calendar time is set, which would discard valid records within a boot. A corrupt, foreign or special file must be neither trusted nor allowed to stop or delay the restore at start, and losing the history only loosens the limits for at most an hour |
| D62 | Nothing that may block runs on Swift's cooperative thread pool: the helper engine runs on a serial dispatch queue of its own (a custom actor executor), and the daemon writes its log, saves its history and calls its blocking seams on dispatch queues of their own. Tests that stall on purpose stall on those queues (review of PR #65, after #64) | The pool has as many threads as cores (three on CI's macOS 15 image). A synchronous control call, a log write or a file write that blocks there takes one of them, and a few at once take every thread: nothing else runs, neither the daemon's shutdown and sleep handling nor, in tests, other suites in the same process, until the stalls end. A dispatch queue's thread blocks alone. `.serialized` only orders tests within one suite, so it could not prevent that |
| D63 | While macOS's own Charge Limit is on, or its `pmset -g battlimit` report cannot be read and recognised, a backend that switches charging itself is asked for nothing but `.normal`: it offers only `.normal` and keeps its availability, the policy wants `.normal` (`deferringToMacOS`, before the safety floor, temperature, overrides and the limit), a hold in place is asked to end through the ordinary path and counts as ended only once a read taken after CellKeeper's last restricting request shows it (logged as safety events either way; a restriction is someone else's only on the backend's records), and CellKeeper asks the user to turn macOS's limit off; it never turns it off itself. macOS's limit is read at most every 30 s, and never on the release path (lead's decision, 2026-10-10; a deviation from R25) | The owner's direction (2026-10-06, 2026-10-09): CellKeeper controls charging, and the user turns macOS's limit off, so two limits never compete. The lower limit wins anyway (R25), so CellKeeper's status would be dishonest, and restricting on top of macOS fights it (R26). Restrictions toward safety are not needed while macOS enforces its own limit, and macOS has its own thermal limiting. An unreadable report is not guessed to be off, and `.unavailable` would misreport a backend that works |
| D64 | `ChargingBackend.isReportedModeOwn()` is false only on positive evidence in the backend's records that nothing in effect is CellKeeper's (for the helper: nothing active, or every active control last changed by another client's activation or an outside change, with no restore owed and no failed write); it is nil when the records cannot establish it and after a read that threw. The controller ends its responsibility for a restriction only on a read showing normal charging or on false (reviewer's principle, 2026-10-10) | Missing activation bookkeeping, an attempted restore or a new helper instance does not prove that CellKeeper's restriction ended or became someone else's: a failed or wrong restore of the helper's can leave or make a control active on CellKeeper's account (D37), and a helper serves sessions after a failed start restore. Calling such a control someone else's would drop CellKeeper's responsibility and the safety event for it |
| D65 | The helper is unregistered only after it replies `ok` to `restoreDefaultsAndExit`, and counts as removed only when the registration then reads `notRegistered` or `notFound`. An explicit reply to that restore request other than `ok` (`hardwareError`, `notIntroduced`, `rateLimited`) is never overridden, even when forced (lead's decision, 2026-10-10) | Safety precondition 9 and R4. After `hardwareError` the helper is the one process still retrying the restore (D30, D31), and unregistering terminates it; a refusal is the helper's answer and says nothing about defaults. Only the status read afterwards shows that the helper is gone |
| D66 | A helper whose restore went unconfirmed because the transport failed or no reply arrived in time, at any stage (connecting, `hello`, the restore), is unregistered only with an explicit `HelperRemovalForce` (the user has seen the recovery procedure). The forced outcome says that the restore was not confirmed, that the exit restore is only an attempt, that a missing reply does not show the helper had stopped trying, that no helper starts at the next boot to restore defaults, and that a mechanism's state may outlast the helper (lead's decision and review of PR #66, 2026-10-10) | Such a helper can be broken in a way that would block its removal forever, for example by answering `hello` and never replying to the restore. Unregistering terminates a running daemon, whose SIGTERM path attempts the restore (D31) but may exit unconfirmed at its deadline; force is therefore an acknowledged loss of assurance, and the remaining risk is what the recovery procedure in `safety.md` covers |
| D67 | The registration is behind a `HelperRegistration` seam in Core that mirrors `SMAppService.Status`; in phase 4a its only implementation is `NoHelperRegistration`, always `notRegistered`. The `SMAppService` implementation (phase 4b) treats "already unregistered" errors (`kSMErrorJobNotFound`, and the EPERM reported on macOS 26) as gone (lead's decision, 2026-10-10) | Nothing in phase 4a may register or unregister anything with launchd, and the removal logic must be testable without ServiceManagement |
| D68 | The conversation with the helper has one 20 s deadline, and each registration call 15 s. Each is an absolute expiry on a monotonic clock that keeps counting during sleep; every piece of evidence (a `hello`, a reply, a failure, a registration result) is judged against it under the lock that holds the decision, when it arrives. At or after the expiry the timeout outcome is frozen and the evidence refused, so a late reply or `hello` authorises nothing (no unregistering, no request to exit) and a late registration result changes nothing. The timer only wakes that check. The flow ignores the caller's cancellation (reviews of PR #66, 2026-10-10) | Every call must be bounded (precondition 13), and a time limit must be judged on the clock when evidence is accepted, not by which callback reaches the lock first: a reply that completes after the deadline, while the timer's wake-up is delayed or set off by the deadline's own cancellation, could otherwise authorise unregistering. 20 s covers two NSXPC requests at their own 10 s timeout (D53); 15 s exceeds launchd's 10 s `ExitTimeOut` in case unregistering waits for the daemon to exit. A cancellation between a confirmed restore and the unregistering would leave the outcome unreported |
| D69 | `ChargeController.removeHelper` restores and confirms normal charging on the current backend before it contacts the helper, holding the command lock throughout; if that is not confirmed it stops, and with no helper registered it restores nothing (lead's decision on the order, 2026-10-10) | The app holds state of its own, such as the user's Charge Limit; holding the lock keeps an evaluation from applying a restriction between the two restores. Restoring when there is nothing to remove would only cost a write and a re-apply |
| D70 | Removal outcomes are typed, and each says only what was confirmed, worded by the kind of helper its `hello` reported (simulated, monitor-only, controls charging, unknown). Only `hardwareError` is described as a helper that keeps retrying; otherwise whether it restored defaults or is still trying is stated as unknown. A `hello` answered with a refusal does not stop the flow: `restoreDefaultsAndExit` is still sent (review of PR #66, 2026-10-10) | R30: nothing unconfirmed is claimed, including a recovery in progress that the reply does not establish, and a simulated or monitor-only helper never claims to have changed the Mac's charging. The engine serves restores without an introduction, so an incompatible or shutting-down helper can still confirm defaults |
