# CellKeeper safety model

Battery charging is hardware-adjacent. This document states what CellKeeper
does and does not do to stay safe, which safeguards exist today, and which are
required before any real control backend may be enabled. The underlying
analysis, sources, and full rule set (R1–R33) are in
[research/06-safety-analysis.md](research/06-safety-analysis.md).

## Current status (milestone 2)

**By default, CellKeeper does not change how your Mac charges.** It reads
battery telemetry through public, read-only interfaces and computes what it
*would* do.
- The default control backend is simulated: requests are recorded and
  labelled "Simulated — hardware unchanged".
- The read-only backend performs no control at all.

**The one real control is opt-in:** the **macOS Charge Limit** backend. It
changes a single, user-level macOS setting, the Charge Limit (80–100%), and
only through a shortcut you create and the documented `shortcuts`
command-line tool. macOS, not CellKeeper, enforces that limit.

There is no privileged helper, no SMC access, no `sudo`, no `pmset` setting
change, and no private API on the write path. CellKeeper opens no
IOUserClient itself.

Your Mac's own protections — the battery pack's management system, firmware
charge termination and thermal limits, and macOS battery health management —
are always in effect and cannot be overridden by CellKeeper.

## The safe state

The **safe state** is `ChargeControlMode.normal`: CellKeeper has no
restriction in effect and macOS/firmware decide charging. Every failure path
converges on it. With the macOS Charge Limit backend, the safe state is
**your own Charge Limit, exactly as it was before CellKeeper changed it**:
CellKeeper records that value before its first change and restores it. It
never substitutes a default such as 100%.

Backends that switch charging themselves only ever *restrict* charging
relative to macOS defaults (inhibit charging, or run from the battery while
plugged in); they never command charging that macOS would withhold. With
macOS's Charge Limit, CellKeeper only sets one of the values macOS itself
offers (80–100%). That can be above your own limit, for example for a
temporary full charge, and macOS still enforces it. CellKeeper never writes
charge voltage, current, or protection settings.

## Safeguards implemented today

The "Where" column names the code that enforces each safeguard. Those in
`CellKeeperCore` and `CellKeeperKit` are covered by unit tests; those in the
app (`AppModel`, `AppDelegate` and the views) are checked by hand.

| Safeguard | Rule (06) | Where |
|---|---|---|
| Invalid settings → fail safe; never saved or applied | R24 | `ChargingSettings.validationIssues`, `ChargingPolicy`, `SettingsStore`, `ChargeController.apply` |
| Missing, stale (read > 60 s ago, or the driver's own update time > 180 s old), future-dated telemetry, unknown power source, no battery → fail safe | R1, R9, R10 | `ChargingPolicy.staleness`, `BatteryTelemetryParser` |
| Implausible telemetry values discarded (percent, temperature −20…80 °C, voltage, current, overflow-safe parsing) | R10 | `BatteryTelemetryParser` |
| Safety floor: at ≤ 10% charging is always allowed, overriding temperature protection and every other rule, until the charge recovers to 15% | R5 | `ChargingPolicy.nextFloorLatch` |
| On battery power, CellKeeper's restrictions are cleared, so a later plug-in charges normally even if CellKeeper has stopped | R18 | `ChargingPolicy` (`onBattery`) |
| Overrides always expire, on a monotonic clock that wall-clock changes cannot affect: a temporary full charge at 100%/fully charged, on unplug, or after 1–48 h (default 12 h); expiry and unplug are processed even when the charge reading is unusable | R22, R23 | `ChargeOverride`, `ChargingPolicy` |
| Temperature protection with hysteresis; an unknown temperature can never hold charging off | R21 | `ChargingPolicy.nextTemperatureLatch` |
| Discharge is a confirmed, one-shot session, never a setting. Its target (20–95%) is captured when confirmed; it never goes below that target or the current limit. It ends at the target, on unplug, before sleep, on temperature pause, on lost telemetry, on a backend fault, or if unsupported, and never restarts by itself | R6, R16, R20 | `ChargeOverride.dischargeToLimit`, `ChargingPolicy`, `SettingsView` |
| Before sleep, charging is held at or above the resume threshold so a software limit cannot overshoot while asleep; the precaution lasts until wake (bounded to 2 min of monotonic time if no wake notification arrives) | R16 | `ChargingPolicy` (`sleepPrecaution`), `ChargeController` |
| Restricting changes rate-limited (≥ 60 s apart, ≤ 20 per hour, monotonic clock); relaxing changes toward normal never limited | R13 | `ChargingPolicy.rateLimitRetryTime` |
| Every request read back; an error, unknown mode, or mismatch is a failure, and nothing unconfirmed is reported as applied | R11, R30 | `ChargeController.setAndConfirm` |
| After a failed restricting request, normal charging is requested immediately and confirmed | R1 | `ChargeController` |
| Mode-read failures count as failures; 3 failures fault the backend (a successful request or a failure-free hour resets the count). While faulted, normal charging is actively requested until confirmed, nothing else is requested, and the fault persists until the user clears it | R11 | `ChargeController`, `ChargingPolicy.action` |
| A backend that does not affect hardware can never report an action as applied to hardware | R30 | `ChargeController.request` |
| A mode change CellKeeper did not make faults the backend at once and restores normal charging. With the native Charge Limit it is adopted as your own limit instead (see below and the deviations) | R27 | `ChargeController.observeBackendMode` |
| Backend switch only after normal charging is confirmed on the old backend; otherwise the switch stays pending and normal charging keeps being requested until it is confirmed | R4 | `ChargeController.switchBackend` |
| On quit the controller restores normal charging and then shuts down; commands still queued become no-ops (deadlock-free) | R19 | `ChargeController.shutdown`, `AppDelegate` |
| All commands serialized under one FIFO lock; user commands applied in order | — | `ChargeController`, `AppModel` command queue |
| Slider changes applied on release (no request bursts) | R13 | `MenuBarView` |
| Simulated actions never reported as hardware actions; UI shows available / experimental / simulated / unavailable | R30 | `ControlOutcome`, `ControlAvailability`, UI |
| Decisions, requests, results, and safety fallbacks logged (unified logging + in-app activity log); no device identifiers read or logged | R32 | `ChargeController.record`, allowlists in `BatteryTelemetryParser` |
| An automatic retry of a failed restore waits 60 s; user actions retry at once | R13 | `ChargingPolicy.restoreRetryRefusal`, `ChargeController` |

### macOS Charge Limit backend

| Safeguard | Where |
|---|---|
| Opt-in only, marked experimental, with a confirmation that explains what will change and what will be restored | `ControlSettingsTab` |
| Before the first change, your own limit is read from macOS and stored durably (written, flushed to disk, read back). If it cannot be read, recognised, or stored, nothing is changed. No value is ever assumed: "no limit" is recorded as 100% only after you confirm your limit is 100% | `NativeChargeLimitBackend.setLimit`, `FileOwnershipRecordStore` |
| Your recorded limit is restored exactly, and confirmed, when you quit, turn off management, switch backend, after any failed request, when CellKeeper cannot read back the state it set, and when the backend is faulted. The record is deleted only after the restore is read back | `ChargeController.restoreNormal`, `NativeChargeLimitBackend.restoreOwnerLimit` |
| A restore that fails stays owed until it is confirmed: CellKeeper makes no other change until then, retries (automatically at most once a minute), and finishes it at the next launch if needed. A backend switch whose restore fails stays pending; quitting cancels in-flight work, waits up to 10 s, and warns you with the value to set if your limit is not confirmed restored | `ChargeController`, `NativeChargeLimitBackend`, `AppDelegate` |
| The record survives crashes, and is checked at every launch whichever backend is selected. A record found at launch means an earlier session did not finish, so CellKeeper first restores your own limit once it can read the current one (or, if someone else changed the limit meanwhile, keeps that value as yours and turns management off), and only then resumes. An unreadable record blocks all changes and is never treated as "nothing to restore" | `NativeChargeLimitBackend`, `ChargeController.observeBackendMode`, `AppModel` |
| Every change is confirmed by reading the setting back from macOS; a shortcut exiting successfully never counts | `NativeChargeLimitBackend.confirm`, `ChargeController.setAndConfirm` |
| Only the values the Charge Limit accepts (80, 85, 90, 95, 100) are ever requested; others are refused, and a limit outside them makes the policy keep your own limit | `NativeChargeLimitBackend.setLimit`, `ChargingPolicy.evaluateNativeLimit` |
| A change made outside CellKeeper (System Settings, another tool) is kept as your own limit, whether CellKeeper notices it when reading, just before writing, or just before restoring: nothing is written, the old record is replaced by a marker that holds nothing to restore, and Manage charging is turned off and saved, so CellKeeper changes nothing more until you turn it on again. The marker keeps management off at every launch until you turn it on again, because settings reach the disk asynchronously; if the marker cannot be stored, the old record is kept, which has the same effect, a backend switch waits until the marker is stored, and turning management on removes the old record first (or stays off if it cannot). A settings change you made before CellKeeper kept your value cannot turn management back on. If the marker or record cannot be removed, the menu and Settings say so next to the toggle. The menu and the log say what was kept; if macOS reported "no limit", they also name your earlier limit in case it was a temporary full charge | `ChargeController.adopt`, `NativeChargeLimitBackend.adopt`, `AppModel` |
| Changes are rate-limited (≥ 60 s apart, ≤ 20 per hour), and real changes still count after a switch to Simulated and back; simulated requests are dropped when the backend changes; a take-over that needs no change runs nothing | `ChargingPolicy.rateLimitRetryTime`, `ChargeController.request`, `ChargeController.completePendingSwitch` |
| The read-back uses `pmset -g battlimit` with fixed arguments, read-only, through a strict parser; anything unrecognised is never guessed | `PmsetChargeLimitReader`, `ChargeLimitReportParser` |
| Tools are run directly (no shell), with standard input closed, a deadline (shortcut 20 s, pmset 5 s), bounded output, and cancellation; incomplete output is never parsed | `ProcessRunner` |
| Features the Charge Limit cannot express are not offered, and a note says so: custom resume threshold, temperature pause, discharge | `SettingsView`, `MenuBarView`, `ChargingPolicy.evaluateNativeLimit` |
| The menu shows that macOS is enforcing the limit, the value macOS reports, and the limit that will be restored | `NativeLimitSummary` |

### Validation ranges

| Setting | Default | Allowed |
|---|---|---|
| Charge limit | 80% | 20–100% (100% = no limit; UI warns below 50%) |
| Resume threshold | 75% | 3–20 points below the limit, and ≥ 15% (floor + 5) |
| Safety floor | 10% | fixed |
| Temperature pause / resume | 40 °C / 35 °C | pause 35–45 °C; resume ≥ 30 °C and ≥ 3 °C below pause |
| Temporary full charge | 12 h | 1–48 h |
| Discharge session | 6 h | 1–48 h; only for limits of 20–95% |
| Safety floor exit | 15% | floor + 5 |
| Telemetry age | — | read ≤ 60 s ago; driver update ≤ 180 s ago (≈ 3 refresh periods); ≤ 60 s clock skew |
| Restricting changes | — | ≥ 60 s apart, ≤ 20 per rolling hour |
| Native Charge Limit | — | 80, 85, 90, 95, 100% (Apple's steps); resume threshold and temperature settings are not used |

## Required before any privileged control backend

These are **not** implemented, because no backend that writes to hardware
itself exists. Each is a precondition for enabling one, and a reviewer should
block any PR that adds hardware writes without them. How the macOS Charge
Limit backend relates to them is described after the list.

1. **Verified mechanism per model.** Run the verification protocol in research
   note 02 §7 (a read-only, allowlisted capability probe, then single
   reversible writes) on a dedicated test Mac with no other battery tools
   installed. Private mechanisms are never tried on a daily-use Mac; the
   maintainer currently has no separate test Mac, so this is blocked. Include
   the persistence matrix (sleep, wake, restart, shutdown, helper crash,
   unplug), and record the results in `docs/research/`.
2. **Allowlist, never probe.** Writes only to keys or interfaces on a reviewed
   per-model, per-firmware allowlist with expected type and size. Unknown
   hardware or a changed OS/firmware build means monitor-only (R12, R15).
3. **Lease / dead-man switch in the privileged component.** Any non-default
   state is held under a lease the app must renew; the helper restores the safe
   state when the lease lapses, when the client disconnects, at helper start,
   and on SIGTERM (R2, R3). Losing the app must never leave a restriction in
   place. Prefer mechanisms the OS releases automatically when the owning
   process exits. The lease must be **per control**, with its own deadline
   (≤ 120 s for adapter-disable, ≤ 15 min for charge inhibit); renewal must be
   tied to a successful policy evaluation (including evaluations whose action
   is "no change"); and the helper must enforce its own telemetry-freshness,
   battery-floor, AC-loss, and thermal guards rather than trusting the client.
4. **Narrow, authenticated helper API.** Typed operations only (set/clear one
   restriction, read state, restore defaults, version) with code-signing
   requirements on both ends of XPC; no raw key/value access, no file access,
   no command execution (R28, R29).
5. **Behavioural verification.** After a write, confirm the expected effect in
   independent telemetry (for example charge current falls to about zero after
   an inhibit) and fall back to the safe state if it does not appear (R11).
6. **Debounce and dwell.** Two consecutive fresh samples before acting on a
   threshold crossing; minimum dwell for temperature pause (R14, R21).
7. **External-writer detection and coexistence.** Stop and restore if another
   tool changes the same state; detect macOS Charge Limit / Optimized Battery
   Charging and never fight them (R25–R27).
8. **Monotonic time for leases and expiries** (R22).
9. **Uninstall that restores the safe state** before unregistering any helper
   (R4).
10. **Opt-in.** Real control is off by default and marked experimental until
    verified on that model.
11. **Tested independent recovery.** Before the first experimental write, prove
    a recovery path that works when the helper has been killed or the Mac has
    slept, using *known safe restoration values* (not merely "the value read
    before the write", which may itself be non-default), with observable
    success criteria. Where battery temperature is unavailable, provide another
    way to watch for heat during tests, and corroborate software power-path
    readings with an external input-power measurement where feasible.
12. **Physical adapter presence.** A backend that cuts the adapter must come
    with telemetry that distinguishes "adapter physically connected" from "Mac
    running on battery"; until then the policy ends a discharge session as
    soon as it sees battery power (safe, but discharge cannot work). Such a
    backend must also enforce its own higher floor (research note 02 §7
    suggests 25–30%) in addition to the policy's 20% minimum target.
13. **Sleep interlock and bounded operations.** Sleep handling, deadlines, and
    restore-on-exit must live in the privileged component, with acknowledged
    sleep notifications and time-limited operations; the app's own will-sleep
    and quit handling cannot guarantee completion.

### How the macOS Charge Limit backend meets the applicable preconditions

The native backend writes nothing to hardware itself. It changes a
supported user setting that you could equally change in System Settings, and
macOS enforces it. Preconditions 2–4, 9, 12 and 13 concern privileged
hardware writes and a helper, and do not apply. For the rest:

- **1, verified mechanism:** verified on the maintainer's Mac (M4,
  macOS 27.0.1), including from inside the App Sandbox
  ([research note 08](research/08-native-charge-limit.md)). Sleep and restart
  observations are recorded there as they are made; see that note for what
  is still pending.
- **5, behavioural verification:** the setting itself is read back after
  every change. Charging behaviour is macOS's and is not used as
  confirmation.
- **6, debounce and dwell:** macOS applies its own hysteresis; CellKeeper's
  rate limit bounds how often the setting changes.
- **7, external-writer detection:** implemented. An outside change is
  detected and adopted as your own limit; CellKeeper then stops managing
  (see the deviations below).
- **8, monotonic time:** used for rate limits, retries and overrides.
- **10, opt-in:** off by default, marked experimental, with a confirmation.
- **11, independent recovery:** System Settings › Battery › Charging can
  always set the limit, with or without CellKeeper. The value to set is the
  one CellKeeper shows as "your own limit" (also in the activity log).

### Deliberate deviations from research note 06

- **Rate budget (R13).** Only restricting changes are counted; relaxing
  changes toward normal charging are treated as safety-direction changes and
  never limited.
- **Debounce (R14) and temperature dwell (R21)** are deferred to the first
  real backend (precondition 6). With simulated control, an extra transition
  has no physical effect.
- **Failure handling (R11).** R11 asks for one retry and then a one-hour
  backoff. CellKeeper instead restores normal charging after every failed
  restricting request and faults the backend after 3 failures; the fault then
  persists until the user clears it.
- **Freshness (R9).** Readings must be ≤ 60 s old by read time, and the
  driver's own update time (where reported) must be ≤ 180 s old, about three
  of its one-minute refresh periods, because a 60 s limit on the driver time
  would trip on normal refresh jitter. After wake, a stale driver time puts the
  policy in fail-safe until the driver refreshes.
- **Floor and resume.** The floor is fixed at 10% (R5 allows 5–20%).
- **Telemetry loss with the native Charge Limit (R1, R9).** Missing or stale
  telemetry does not release a native limit: macOS enforces it from its own
  measurements, so CellKeeper's view of the battery cannot make it unsafe.
  Releasing would only restore and re-apply the setting after every wake.
- **Restore retries.** An automatic retry of a failed restore waits 60 s
  (user actions retry at once), so a broken backend is not run in a loop.
- **Outside changes with the native Charge Limit (R27).** R27 asks for a
  fault. With the native Charge Limit, a recognised value that CellKeeper did
  not set is instead adopted as your own limit: nothing is written, not even
  a restore, and management is turned off. This is the owner's decision
  (2026-10-06): a change made in System Settings is usually deliberate.
  CellKeeper cannot tell who made the change, so a change by another tool or
  by macOS is adopted too. An unrecognised report is never adopted.

## What CellKeeper will never do

- Write to unknown SMC keys or probe keys by writing values.
- Change charge voltage, charge current, gauge configuration, or protection
  thresholds.
- Provide a general-purpose privileged command or key-write interface.
- Counteract a charging hold that macOS or firmware imposed. (Setting
  macOS's own Charge Limit is not counteracting it: it is the setting that
  configures that hold.)
- Claim a simulated or unverified action changed the hardware.

## If charging does not resume

With the simulated or read-only backend, CellKeeper cannot affect charging.
With the macOS Charge Limit backend, the only thing CellKeeper changes is
macOS's Charge Limit, which never goes below 80%. If your Mac shows "Not
Charging", macOS's own Charge Limit, Optimized Battery Charging, battery
health management, a weak adapter, or another battery tool may be
responsible; see Apple's guidance on the "Not Charging" status.

### Getting your own Charge Limit back

1. In CellKeeper, turn off **Manage charging**, or quit CellKeeper.
   CellKeeper restores the limit it recorded and reads it back. The activity
   log shows "Restored your own macOS Charge Limit of N%".
2. If CellKeeper cannot do that (for example because the shortcut was
   deleted, or CellKeeper is no longer installed), set the limit in **System
   Settings › Battery › ⓘ next to Charging**. The value CellKeeper recorded
   is shown in its menu and settings as "your own limit".
3. If CellKeeper quits without confirming the restore, it shows an alert
   with the value to set, and tries again the next time it starts.
4. If CellKeeper reports that its record of your limit is unreadable, it
   will not change the limit at all. Set your limit in System Settings, then
   choose **Settings… › Control › I've Set My Limit — Discard the Record…**.
   Without CellKeeper, the record is the file
   `~/Library/Containers/io.github.saltedtan.CellKeeper/Data/Library/Application Support/CellKeeper/native-charge-limit-ownership.json`.
   Builds with another bundle identifier use their own container path.

A recovery procedure for future privileged backends (restore normal
charging, uninstall the helper, restart) will be documented before such a
backend ships (R31).

## Disclaimer

CellKeeper is experimental software provided under the Apache License 2.0,
**without warranty of any kind**. Battery behaviour differs between Mac
models and macOS versions, and future control features depend on undocumented
interfaces that Apple may change at any time. Use at your own risk.
