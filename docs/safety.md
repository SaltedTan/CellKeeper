# Cell Keeper safety model

Battery charging is hardware-adjacent. This document states what Cell Keeper
does and does not do to stay safe, which safeguards exist today, and which are
required before any real control backend may be enabled. The underlying
analysis, sources, and full rule set (R1–R33) are in
[research/06-safety-analysis.md](research/06-safety-analysis.md).

## Current status (milestone 1)

**Cell Keeper does not change how your Mac charges.** It reads battery
telemetry through public, read-only interfaces and computes what it *would*
do. The default control backend is simulated: requests are recorded and
labelled "Simulated — hardware unchanged". The read-only backend performs no
control at all. There is no privileged helper, no SMC access, and no code that
writes to hardware.

Your Mac's own protections — the battery pack's management system, firmware
charge termination and thermal limits, and macOS battery health management —
are always in effect and cannot be overridden by CellKeeper.

## The safe state

The **safe state** is `ChargeControlMode.normal`: Cell Keeper has no
restriction in effect and macOS/firmware decide charging. Every failure path
converges on it. Cell Keeper only ever *restricts* charging relative to macOS
defaults (inhibit charging, or run from the battery while plugged in); it never
commands charging that macOS would withhold and never writes charge voltage,
current, or protection settings.

## Safeguards implemented today

All of these are enforced in `CellKeeperCore` and covered by unit tests.

| Safeguard | Rule (06) | Where |
|---|---|---|
| Invalid settings → fail safe; never saved or applied | R24 | `ChargingSettings.validationIssues`, `ChargingPolicy`, `SettingsStore`, `ChargeController.apply` |
| Missing, stale (read > 60 s ago, or the driver's own update time > 180 s old), future-dated telemetry, unknown power source, no battery → fail safe | R1, R9, R10 | `ChargingPolicy.staleness`, `BatteryTelemetryParser` |
| Implausible telemetry values discarded (percent, temperature −20…80 °C, voltage, current, overflow-safe parsing) | R10 | `BatteryTelemetryParser` |
| Safety floor: at ≤ 10% charging is always allowed, overriding temperature protection and every other rule, until the charge recovers to 15% | R5 | `ChargingPolicy.nextFloorLatch` |
| On battery power, Cell Keeper's restrictions are cleared, so a later plug-in charges normally even if Cell Keeper has stopped | R18 | `ChargingPolicy` (`onBattery`) |
| Overrides always expire, on a monotonic clock that wall-clock changes cannot affect: a temporary full charge at 100%/fully charged, on unplug, or after 1–48 h (default 12 h); expiry and unplug are processed even when the charge reading is unusable | R22, R23 | `ChargeOverride`, `ChargingPolicy` |
| Temperature protection with hysteresis; an unknown temperature can never hold charging off | R21 | `ChargingPolicy.nextTemperatureLatch` |
| Discharge is a confirmed, one-shot session, never a setting. Its target (20–95%) is captured when confirmed; it never goes below that target or the current limit. It ends at the target, on unplug, before sleep, on temperature pause, on lost telemetry, on a backend fault, or if unsupported, and never restarts by itself | R6, R16, R20 | `ChargeOverride.dischargeToLimit`, `ChargingPolicy`, `SettingsView` |
| Before sleep, charging is held at or above the resume threshold so a software limit cannot overshoot while asleep; the precaution lasts until wake (bounded to 2 min of monotonic time if no wake notification arrives) | R16 | `ChargingPolicy` (`sleepPrecaution`), `ChargeController` |
| Restricting changes rate-limited (≥ 60 s apart, ≤ 20 per hour, monotonic clock); relaxing changes toward normal never limited | R13 | `ChargingPolicy.rateLimitRetryTime` |
| Every request read back; an error, unknown mode, or mismatch is a failure, and nothing unconfirmed is reported as applied | R11, R30 | `ChargeController.setAndConfirm` |
| After a failed restricting request, normal charging is requested immediately and confirmed | R1 | `ChargeController` |
| Mode-read failures count as failures; 3 failures fault the backend (a successful request or a failure-free hour resets the count). While faulted, normal charging is actively requested until confirmed, nothing else is requested, and the fault persists until the user clears it | R11 | `ChargeController`, `ChargingPolicy.action` |
| A backend that does not affect hardware can never report an action as applied to hardware | R30 | `ChargeController.request` |
| A mode change Cell Keeper did not make faults the backend at once and restores normal charging | R27 | `ChargeController.observeBackendMode` |
| Backend switch only after normal charging is confirmed on the old backend; otherwise refused | R4 | `ChargeController.switchBackend` |
| On quit the controller restores normal charging and then shuts down; commands still queued become no-ops (deadlock-free) | R19 | `ChargeController.shutdown`, `AppDelegate` |
| All commands serialized under one FIFO lock; user commands applied in order | — | `ChargeController`, `AppModel` command queue |
| Slider changes applied on release (no request bursts) | R13 | `MenuBarView` |
| Simulated actions never reported as hardware actions; UI shows available / experimental / simulated / unavailable | R30 | `ControlOutcome`, `ControlAvailability`, UI |
| Decisions, requests, results, and safety fallbacks logged (unified logging + in-app activity log); no device identifiers read or logged | R32 | `ChargeController.record`, allowlists in `BatteryTelemetryParser` |

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

## Required before any real control backend

These are **not** implemented, because no real backend exists. Each is a
precondition for enabling one, and a reviewer should block any PR that adds
hardware writes without them.

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

### Deliberate deviations from research note 06

- **Rate budget (R13).** Only restricting changes are counted; relaxing
  changes toward normal charging are treated as safety-direction changes and
  never limited.
- **Debounce (R14) and temperature dwell (R21)** are deferred to the first
  real backend (precondition 6). With simulated control, an extra transition
  has no physical effect.
- **Failure handling (R11).** R11 asks for one retry and then a one-hour
  backoff. Cell Keeper instead restores normal charging after every failed
  restricting request and faults the backend after 3 failures; the fault then
  persists until the user clears it.
- **Freshness (R9).** Readings must be ≤ 60 s old by read time, and the
  driver's own update time (where reported) must be ≤ 180 s old, about three
  of its one-minute refresh periods, because a 60 s limit on the driver time
  would trip on normal refresh jitter. After wake, a stale driver time puts the
  policy in fail-safe until the driver refreshes.
- **Floor and resume.** The floor is fixed at 10% (R5 allows 5–20%).

## What Cell Keeper will never do

- Write to unknown SMC keys or probe keys by writing values.
- Change charge voltage, charge current, gauge configuration, or protection
  thresholds.
- Provide a general-purpose privileged command or key-write interface.
- Counteract a charging hold that macOS or firmware imposed.
- Claim a simulated or unverified action changed the hardware.

## If charging does not resume

Milestone 1 cannot affect charging, so Cell Keeper cannot be the cause of a
charging problem today. If your Mac shows "Not Charging", macOS's own Charge
Limit, Optimized Battery Charging, battery health management, a weak adapter,
or another battery tool may be responsible; see Apple's guidance on the
"Not Charging" status. A recovery procedure for future real backends
(restore normal charging, uninstall the helper, restart) will be documented
before such a backend ships (R31).

## Disclaimer

Cell Keeper is experimental software provided under the Apache License 2.0,
**without warranty of any kind**. Battery behaviour differs between Mac
models and macOS versions, and future control features depend on undocumented
interfaces that Apple may change at any time. Use at your own risk.
