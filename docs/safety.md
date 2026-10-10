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
- The **Simulated helper** runs CellKeeper's own charge control, at any
  limit from 20 to 100%, through the logic of the future privileged helper
  inside the app, on a simulated control. It too changes nothing. While
  macOS's own Charge Limit is on, it withholds its own restrictions and asks
  for normal charging, as a real helper backend will (precondition 7
  below).

**The one real control is opt-in:** the **macOS Charge Limit** backend. It
changes a single, user-level macOS setting, the Charge Limit (80–100%), and
only through a shortcut you create and the documented `shortcuts`
command-line tool. macOS, not CellKeeper, enforces that limit.

There is no privileged helper, no SMC access, no `sudo`, no `pmset` setting
change, and no private API on the write path. CellKeeper opens no
IOUserClient itself. The NSXPC transport for a future helper exists in code
and is tested inside the test process only, and the helper daemon's
executable (`CellKeeperHelper`) is built and tested but never installed: it
controls no hardware and does not serve that transport yet. Nothing
registers, starts or connects to a helper process.

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
| Invalid settings → fail safe; never saved or applied. Unusable stored settings are replaced by the defaults with Manage charging off | R24 | `ChargingSettings.validationIssues`, `ChargingPolicy`, `SettingsStore`, `ChargeController.apply` |
| Missing, stale (read > 60 s ago, or the driver's own update time > 180 s old), future-dated telemetry, unknown power source, no battery → fail safe | R1, R9, R10 | `ChargingPolicy.staleness`, `BatteryTelemetryParser` |
| Implausible telemetry values discarded (percent, temperature −20…80 °C, voltage, current, overflow-safe parsing) | R10 | `BatteryTelemetryParser` |
| Safety floor: at ≤ 10% charging is always allowed, overriding temperature protection and every other rule, until the charge recovers to 15% | R5 | `ChargingPolicy.nextFloorLatch` |
| On battery power, CellKeeper's restrictions are cleared, so a later plug-in charges normally even if CellKeeper has stopped | R18 | `ChargingPolicy` (`onBattery`) |
| Overrides always expire, on a monotonic clock that wall-clock changes cannot affect: a temporary full charge at 100%/fully charged, on unplug, or after 1–48 h (default 12 h); expiry and unplug are processed even when the charge reading is unusable | R22, R23 | `ChargeOverride`, `ChargingPolicy` |
| Temperature protection with hysteresis. A pause starts on the first hot reading. Cooling alone ends it no sooner than 5 minutes after it began (monotonic clock); an unknown temperature or turning protection off ends it at once, so it can never hold charging off, and higher-priority rules (safety floor, battery power, fail-safe, macOS's own Charge Limit being on) still override it | R21 | `ChargingPolicy.nextTemperatureLatch` |
| Debounce: charging is paused at the limit only once two consecutive distinct readings (identified by the driver's own update time, or else the read time) reach it. Re-evaluating one reading does not count twice, a reading below the limit or an unusable one in between starts over, and meanwhile charging continues with a note saying so. The safety floor, the sleep precaution, temperature protection, and every change toward macOS defaults act on the first reading | R14 | `ChargingPolicy.nextLimitLatch` |
| Discharge is a confirmed, one-shot session, never a setting. Its target (20–95%) is captured when confirmed; it never goes below that target or the current limit. It ends at the target, on unplug, before sleep, on temperature pause, on lost telemetry, on a backend fault, while macOS's own Charge Limit is on or unreadable, or if unsupported, and never restarts by itself | R6, R16, R20 | `ChargeOverride.dischargeToLimit`, `ChargingPolicy`, `SettingsView` |
| Before sleep, charging is held at or above the resume threshold so a software limit cannot overshoot while asleep; the precaution lasts until wake (bounded to 2 min of monotonic time if no wake notification arrives) | R16 | `ChargingPolicy` (`sleepPrecaution`), `ChargeController` |
| Restricting changes rate-limited (≥ 60 s apart, ≤ 20 per hour, monotonic clock); relaxing changes toward normal never limited | R13 | `ChargingPolicy.rateLimitRetryTime` |
| Every request read back; an error, unknown mode, or mismatch is a failure, and nothing unconfirmed is reported as applied | R11, R30 | `ChargeController.setAndConfirm` |
| After a failed restricting request, normal charging is requested immediately and confirmed | R1 | `ChargeController` |
| Mode-read failures count as failures; 3 failures fault the backend (a successful request or a failure-free hour resets the count). While faulted, normal charging is actively requested until confirmed, nothing else is requested, and the fault persists until the user clears it | R11 | `ChargeController`, `ChargingPolicy.action` |
| A backend that does not affect hardware can never report an action as applied to hardware | R30 | `ChargeController.request` |
| A mode change CellKeeper did not make faults the backend at once and restores normal charging. With the native Charge Limit it is adopted as your own limit instead (see below and the deviations) | R27 | `ChargeController.observeBackendMode` |
| While macOS's own Charge Limit is on, or its report (`pmset -g battlimit`, read-only) cannot be read and recognised, a backend that switches charging itself is asked for normal charging only: it offers no other mode, a discharge session ends, and temperature protection and the limit do not apply. A hold in place is asked to end at the next evaluation; a safety event says whether a read-back confirmed the end, and until one does, the menu, Settings › Control, the diagnostics report and the log say the restriction may remain (it can still hold charging below macOS's limit). What may remain is tracked from before each restricting request until a later read shows normal charging, whatever faults, bookkeeping, attempted restores or a restarted helper say; a restriction is called someone else's only on positive evidence in the helper's history (D51). A read of macOS's limit that other callers' cancellations keep interrupting gives "may be limiting" after two re-reads. The menu and Settings › Control say how to turn macOS's limit off, with Check Again. CellKeeper never turns macOS's limit off itself. A release, quitting and a backend switch never wait for a read of macOS's limit. The limit is read at most every 30 s (see the deviations) | R25, R26 | `MacOSChargeLimitMonitor`, `HelperChargingBackend.capabilities`, `ChargingPolicy.macOSChargeLimitReason`, `ChargeController`, `MacOSChargeLimitWording` |
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
| Temperature pause, minimum before cooling ends it | 5 min | fixed (monotonic clock) |
| Limit debounce | 2 readings | fixed: two consecutive distinct readings at or above the limit |
| Temporary full charge | 12 h | 1–48 h |
| Discharge session | 6 h | 1–48 h; only for limits of 20–95% |
| Safety floor exit | 15% | floor + 5 |
| Telemetry age | — | read ≤ 60 s ago; driver update ≤ 180 s ago (≈ 3 refresh periods); ≤ 60 s clock skew |
| Restricting changes | — | ≥ 60 s apart, ≤ 20 per rolling hour |
| Native Charge Limit | — | 80, 85, 90, 95, 100% (Apple's steps); resume threshold and temperature settings are not used |

## Required before any privileged control backend

Except where marked, these are **not** implemented, because no backend that
writes to hardware itself exists. Each is a precondition for enabling one,
and a reviewer should block any PR that adds hardware writes without them.
How the macOS Charge Limit backend relates to them is described after the
list.

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
   *Implemented in the transport, not deployed*: the NSXPC interface has one
   method per typed operation with only integer and boolean arguments, and
   both ends carry a code-signing requirement (Apple-issued certificate,
   signing identifier and team; see the helper backend below). Tested over
   an anonymous listener; no helper is registered, and the daemon does not
   serve the transport yet.
5. **Behavioural verification.** After a write, confirm the expected effect in
   independent telemetry (for example charge current falls to about zero after
   an inhibit) and fall back to the safe state if it does not appear (R11).
6. **Debounce and dwell.** Two consecutive fresh samples before acting on a
   threshold crossing; minimum dwell for temperature pause (R14, R21).
   *Implemented in the policy* for backends that switch charging themselves:
   the limit latch needs two consecutive distinct readings, and cooling
   alone ends a temperature pause no sooner than 5 minutes after it began
   (see the safeguards table and the deviations below). A privileged helper
   must still enforce its own guards (precondition 3).
7. **External-writer detection and coexistence.** Stop and restore if another
   tool changes the same state; detect macOS Charge Limit / Optimized Battery
   Charging and never fight them (R25–R27).
   *Coexistence with macOS's Charge Limit implemented* for backends that
   switch charging themselves: while it is on, or its report cannot be read
   and recognised, CellKeeper withholds new restrictions, asks for the
   release of any of its own (which counts as done only once a read-back
   shows it) and asks you to turn macOS's limit off (see "Where the helper
   backend stands" and the deviations). *Coexistence with Optimized
   Battery Charging and battery health management is partial and
   unverified:* they are seen only if they appear in that report, and are
   never inferred or counteracted otherwise.
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
    *In part*: the helper's logic implements the sleep, wake and exit rules;
    the app's XPC client bounds every call with a timeout and then
    invalidates the connection, which makes the helper end the session; and
    the daemon (not installed, not yet serving the transport) acknowledges
    sleep after the engine's sleep checks, or 5 s after the announcement at
    the latest, and finishes every shutdown within one 8 s deadline. Time
    limits on the helper's own calls into the hardware wait for a real
    control.

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
  rate limit bounds how often the setting changes. The policy's debounce and
  minimum pause are not used, because CellKeeper only chooses the limit's
  value.
- **7, external-writer detection:** implemented. An outside change is
  detected and adopted as your own limit; CellKeeper then stops managing
  (see the deviations below).
- **8, monotonic time:** used for rate limits, retries and overrides.
- **10, opt-in:** off by default, marked experimental, with a confirmation.
- **11, independent recovery:** System Settings › Battery › Charging can
  always set the limit, with or without CellKeeper. The value to set is the
  one CellKeeper shows as "your own limit" (also in the activity log).

### Where the helper backend stands

The helper backend (`HelperChargingBackend`) drives the helper's logic
(`HelperEngine`), which runs only in the app's own process and only on a
simulated control. The NSXPC transport that will connect the app to a
helper daemon exists and is tested inside the test process, and so does
the daemon (below), but the daemon does not serve the transport yet,
nothing is registered with launchd, and the app does not use the
transport. Nothing is written to hardware, so none of these
preconditions is met for a real backend yet. Because the Simulated helper
lives and dies with the app, its leases, disconnect handling and restores
are exercised by tests, not by a separate process that outlives a crashed
app.

The helper daemon (`CellKeeperHelper`, hosted by `HelperDaemon`) runs the
same engine with `UnknownHardwareChargeControl`: it reports no
capabilities, so clients stay monitor-only (R12a), writes nothing, and
never reports hardware defaults as restored by it (its restores write
nothing and read back nothing active). The only public way to assemble it
uses that control. It serves no clients yet and is neither embedded in the
app nor registered with launchd; its host logic is tested in `swift test`
without registering anything. What is already in place, and tested against
the simulated control:

- **3, lease / dead-man switch (logic only):** per-control leases with their
  own deadlines (15 min for the charging inhibit, 2 min for the
  adapter-disable). The engine clears a control when its lease expires or the
  lease holder's session ends, restores defaults at start and at shutdown,
  and keeps retrying a restore that failed; it applies its own floor,
  AC-loss, adapter, thermal, sleep and freshness guards. Renewal is tied to
  policy evaluations: the controller renews a hold only at the end of an
  evaluation that still wants it, including one whose action is "no change",
  so a hung or stalled loop lets the lease lapse. A failed renewal counts as
  a failure and normal charging is requested at once
  (`ChargeController.renewHoldIfStillWanted`). While CellKeeper holds a
  control through a live session, the app asks macOS not to nap it
  (`LeaseActivity`); that makes late renewals less likely but does not
  guarantee them, and a lease that lapses only ends the restriction. The
  helper's own power reading uses public, read-only interfaces, in process
  for the Simulated helper and in the daemon (`DaemonPowerReading`, the same
  rules). The daemon restores defaults at start before it serves anyone,
  and on SIGTERM restores them and exits within 8 s, inside launchd's
  `ExitTimeOut` of 10 s. It exits with 0 only if, after its frontend has
  confirmed that every accepted request is answered and every session
  invalidated, and after its log is written, a final check finds defaults
  confirmed; otherwise it exits non-zero, so launchd starts it again and
  the next start restores first.
- **4, narrow, authenticated API (transport only):** the NSXPC interface
  (`CellKeeperHelperXPC`) has one method per typed operation, with only
  `Int`, `UInt64` and `Bool` arguments and replies, so neither side decodes
  objects from the other. The helper's listener requires CellKeeper's
  signing identifier, an Apple-issued certificate and its own team of
  every client; the app requires the same of the helper, with the helper's
  identifier. The team is read from the process's own signature, so an
  ad-hoc build cannot build these requirements at all, and every
  requirement is compiled before use. Process IDs are never trusted. Each
  connection's requests reach the engine in arrival order, one at a time,
  and a session revoked for flooding the helper loses its connection. A
  client can make the helper do only bounded work: at most 32 requests may
  wait on a connection (one more closes it), at most 8 clients are served,
  and a closed connection runs nothing more while its session, and with it
  any restriction it held, ends at once. Tests run both sides in the test
  process over an anonymous listener, with the test binary's own code
  signature required on both sides. The release-only requirement clauses
  (Developer ID certificate, no debugger entitlement) wait for signed
  builds (phase 4b). The daemon does not serve this transport yet; its
  frontend contract requires a code-signing requirement on every
  connection, and a stop that drains every accepted request before the
  daemon may exit cleanly.
- **6, debounce and dwell:** the policy's debounce and minimum pause apply to
  the helper backend, as to any backend that switches charging itself.
- **7, external-writer detection (in part):** the helper records why each
  control last changed, and the backend decides from that record whether a
  hold ended under the helper's own rules (an expired lease, a power or sleep
  interlock, the end of CellKeeper's session, a helper restart), by
  CellKeeper's own release, or otherwise. Anything else, including another
  client of the helper clearing or restoring a control, faults the backend,
  also when CellKeeper finds it while releasing and the release succeeds.
  The fault names an outside writer only when the helper's history names
  one (another client, or an outside change the helper reports); a control
  the helper's own failed restore or failed start left active, or one with
  no recorded change, faults the backend just the same, as a restriction
  CellKeeper cannot attribute or the helper's own failure.
  CellKeeper deactivates only controls it still owns by that record, and the
  helper checks that record itself right before it clears
  (`clearControlIfUnchanged`), so a control that changed hands in between
  is left alone. CellKeeper never restores defaults by itself; only the
  user clearing the fault restores defaults, once. Limit: the helper sees
  an outside change only when it reads the control, so a change undone
  between two reads goes unnoticed.
- **7, coexistence with macOS's Charge Limit and Optimized Battery
  Charging:** the backend reads macOS's Charge Limit through the same
  read-only `pmset -g battlimit` report and strict parser as the native
  backend (`MacOSChargeLimitMonitor`, on a Mac that has the Charge Limit).
  While the limit is below 100%, or the report cannot be read or
  recognised, the backend offers only normal charging (its availability
  stays Simulated) and the policy withholds new restrictions and asks for
  the release of any of CellKeeper's own (state `deferringToMacOS`): no
  limit, no temperature pause, no sleep precaution, no discharge. That does
  not establish that a hold already in place ended, so it does not promise
  that two limits never compete: until the release is confirmed, a
  restriction CellKeeper set can still hold charging below what macOS would
  allow. The next evaluation asks for the release through the ordinary
  path, and a safety event says whether a read-back confirmed the end. If
  not, the menu, Settings › Control, the diagnostics report and the log say
  that the restriction may remain, normal charging keeps being requested,
  and a later safety event says when a read-back shows it ended. A
  discharge session ends. What CellKeeper may still have in effect is
  tracked apart from its ownership bookkeeping and faults
  (`ControllerStatus.ownRestriction`): it starts before a restricting
  request is sent (a read taken before it no longer counts), and ends only
  with a read taken after it that shows normal charging, or with positive
  evidence in the helper's history that nothing in effect is CellKeeper's
  (another client's activation or a change made outside the helper, with
  no restore owed and no failed write). Only that evidence makes a
  restriction "someone else's". Missing bookkeeping, an attempted restore,
  a fault or a restarted helper is not evidence: a control the helper's own
  failed or wrong restore may have made active, or one a restarted helper
  left active because its start restore failed, stays CellKeeper's
  responsibility. The helper's outside-change report says whether its
  restore read back clean or is still owed. Every such message on
  the Simulated helper says its controls are simulated and the Mac's
  charging is not changed. The menu and Settings › Control name what macOS
  reports and say to turn the limit off in System Settings › Battery
  (Charge Limit at 100%), also while an unfinished restore is what the
  policy reports first.
  CellKeeper never turns it off itself, and a release, quitting and a
  backend switch never wait for a read of it (only an evaluation or Check
  Again reads it, and a cancelled read is stopped at once). What remains or
  is limited:
  - Coexistence with Optimized Battery Charging, temporary states ("Set
    Until Tomorrow", "Charge to Full Now") and battery health management
    is partial and unverified: CellKeeper sees them only if they appear in
    the `battlimit` report. An entry it does not recognise withholds
    restrictions; a hold that leaves no entry there is not seen, and is
    never inferred or counteracted (research note 08, I3 and open
    questions 2–4). "Charge to Full Now" may appear as "no limit" (I2),
    and then CellKeeper's own limit applies; this must be verified before
    any hardware control. So "no active limit" in the report is shown as
    exactly that, never as "your limit is 100%" or "macOS holds nothing".
  - Detection is periodic: the report is read at most every 30 s and
    evaluations run every 60 s, so a change is normally seen within about
    a minute, and at worst after about 90 s when an evaluation that an
    event triggered reused a recent reading. Check Again reads it at once.
  - A report that cannot be read even once asks for a hold's release, and
    an earlier reading of "off" is not kept; the hold is taken again,
    within the rate limits, once a read shows no active limit.
  - The check is the app's. The helper does not read macOS's limit
    itself; whether the helper enforces it independently must be decided
    before any privileged write.
  - In the App Sandbox, every pmset run logs the kernel's denial of
    pmset's own attempt to open the SMC user client (research note 08,
    O7), now about once a minute while the helper backend is selected. The
    report is unaffected, and no entitlement is added for it.
- **Unconfirmed changes:** CellKeeper is responsible for a control from the
  moment it sends an activation until the helper's history shows what came
  of it, and for a hold until it sees it end. If the helper cannot be
  reached, cannot read its controls back, is shutting down, or a release
  fails meanwhile, the backend keeps asking for normal charging, counts
  failures and keeps a backend switch pending. An activation whose outcome
  is unknown never makes a control CellKeeper's, so nothing is cleared on
  its account; if another client or tool changed the control before
  CellKeeper could confirm the activation, that is reported as an outside
  change, and CellKeeper stops (R27).
- **Helper failures:** a failed write or an owed restore faults the backend
  at once, also while the helper cannot read its controls back, and a new
  hardware error is counted as a failure.
- **8, monotonic time:** one clock that counts sleep for the helper's leases,
  rate limits and power-state age. The daemon keeps the activation history
  across relaunches within a boot, in a file keyed by the boot session UUID
  that the kernel sets once per boot (never by wall-clock time), and
  discards it at a new boot, when that clock starts again.
- **9, uninstall that restores the safe state (the daemon's part):** a
  client's `restoreDefaultsAndExit` (once the daemon serves the transport)
  and SIGTERM, which launchd sends when it stops the job, both run the same
  bounded shutdown: the reply to `restoreDefaultsAndExit` is sent, with
  send completion confirmed, before that client's session ends (receipt
  by the client is not confirmed), and the daemon exits with 0 only once
  defaults are confirmed as above. The app's uninstall flow is not done.
- **13, sleep interlock and bounded operations:** on the app's side, every
  call over the XPC transport has a timeout (10 s by default). A timeout,
  an interruption or any other transport failure invalidates the
  connection, so a late reply is never used and the helper ends the
  session, clearing what it held; the backend then connects again and
  reads the state afresh. On the daemon's side, the daemon registers with
  `IORegisterForSystemPower` and acknowledges sleep only once the engine
  has run its sleep checks (the adapter-disable cleared, an expired lease
  ended), or 5 s after the announcement at the latest; it never vetoes
  sleep. Restore on exit lives in the daemon, with one 8 s deadline for the
  whole shutdown, logging and the final decision included, that holds even
  if a control call hangs, the log cannot be written or a timer starts late
  (every wait carries its absolute deadline). Nothing that can block runs
  on the daemon's coordinating actor, so a stuck log or frontend cannot
  keep SIGTERM from beginning the shutdown. Still missing: a real control
  that bounds its own calls.

Everything else, including the daemon serving the transport, its
registration, a verified mechanism, behavioural verification and time
limits on the helper's own calls into the hardware, is still missing.

### Deliberate deviations from research note 06

- **Rate budget (R13).** Only restricting changes are counted; relaxing
  changes toward normal charging are treated as safety-direction changes and
  never limited.
- **Debounce (R14).** Only the limit crossing waits for a second reading:
  it is the one restricting crossing that is not a safety trigger (R14
  exempts those). Crossings that relax toward macOS defaults (falling to the
  resume threshold, raising the limit, unplugging, losing the temperature
  reading) also act on the first reading, for the same reason as the rate
  budget: they move toward the safe state. While a crossing waits, charging
  continues until the next reading, normally about a minute later (one
  driver refresh), so the charge can rise a little further past the limit.
- **Temperature dwell (R21).** R21 asks for a 5-minute minimum in each
  state. CellKeeper has a minimum only for the paused state, and only
  against cooling: cooling to the resume temperature ends a pause no sooner
  than 5 minutes after it began. An unknown temperature or turning
  protection off ends a pause at once, and higher-priority rules (safety
  floor, battery power, fail-safe, management off, macOS's own Charge Limit
  being on) override it at once. The
  cleared state has no minimum: the next reading at or above the pause
  temperature pauses charging again at once, because pausing is a safety
  action and a wait before it could only delay protection. The minimum
  therefore does not bound how often pauses start; a temperature reading
  that keeps disappearing and returning hot can start one about every
  minute. What bounds the requests is the rate limit: pausing from normal
  charging is a restricting change, so such requests are at least 60 s
  apart and at most 20 an hour, shared with every other restricting change.
  A pause that ends a discharge session (`forceDischarge` →
  `inhibitCharging`) is a relaxing change and is not counted.
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
- **macOS's own limits (R25, R26).** R25 asks that, while macOS limits
  charging, the more restrictive of the two limits apply and both be shown.
  With a backend that switches charging itself, CellKeeper instead
  withholds new restrictions and asks for the release of any of its own
  while macOS's Charge Limit is on, or while its report cannot be read and
  recognised (lead's decision, 2026-10-10, following the owner's direction
  of 2026-10-06 and 2026-10-09 that you turn macOS's limit off and
  CellKeeper controls charging). The lower limit would win anyway, so
  CellKeeper's status would claim a limit it does not enforce, and
  restricting on top of macOS would fight it (R26). This also sets aside
  CellKeeper's temperature pause, sleep precaution and discharge sessions
  while macOS's limit is on: macOS enforces its own limit and has its own
  thermal limiting. Nothing is guessed: an unrecognised or failed read
  counts as "macOS may be limiting". A restriction already in place counts
  as ended only once a read-back shows it. The native Charge Limit backend
  is unaffected: it sets that limit.
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

With the simulated, read-only or Simulated helper backend, CellKeeper cannot
affect charging. With the macOS Charge Limit backend, the only thing CellKeeper changes is
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
