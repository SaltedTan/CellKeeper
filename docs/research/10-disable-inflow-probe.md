# 10 — The DisableInflow probe (owner-run, on the maintainer's Mac)

- **Date:** 2026-10-19
- **Status:** Designed, not run. The owner authorized one run (§2); its
  results go in §10.
- **Machine:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (26A434),
  system firmware mBoot-20457.1.29. This is the maintainer's own Mac.
- **Tool:** [`Tools/charge-inhibit-probe/`](../../Tools/charge-inhibit-probe/),
  the standalone SwiftPM package of [note 09](09-charge-inhibit-probe.md),
  extended. `--assertion disable-inflow` selects this test;
  `--assertion charge-inhibit` selects note 09's. It is not part of the app,
  its Xcode project or CellKeeperKit, and nothing ships from it.
- **Tags and grades:** as in [note 02](02-charging-control-apple-silicon.md)
  (tag legend and grades A–E, X). Here, **B** is Apple open source, **A**
  the public macOS 27.0 SDK, and **X** a read-only observation on this Mac.

---

## 1. Purpose

Research note 02 §8 asks (open question 4): *do the private `ChargeInhibit` /
`DisableInflow` assertions affect charging on Apple silicon (macOS 26/27)?*
Note 09 answered the first half for this Mac: holding `ChargeInhibit` for
60 s showed no effect (note 09 §10). This probe asks the second half, for
one Mac, one macOS build and one firmware: does holding one `DisableInflow`
assertion change how the Mac takes power from its adapter, and does
everything return to normal when it is released?

Apple's header describes `DisableInflow` as disabling "AC Power Inflow"
(§3). Holding it could therefore:

- (a) do nothing;
- (b) stop charging while the Mac stays on adapter power, as an inhibit
  would. This is what CellKeeper needs for limits below 80%;
- (c) cut the adapter's power, so that the Mac runs from its battery while
  the adapter stays plugged in. This is how the SMC adapter cut is reported
  to behave (note 02 §3.4), but through Apple's own assertion, which powerd
  releases when the probe exits.

The verdict tells these apart (§4). The probe also changes its criteria
where note 09 §10 found them too tight for a battery that publishes new
values about once a minute; the new criteria apply to both assertion types.
It does not test sleep, restart, unplugging, persistence, or anything
SMC-based.

## 2. The owner's decision (2026-10-19)

- After note 09's result, the owner decided to probe `DisableInflow` next.
- **Authorized: one experiment.** The owner runs the probe with `sudo`. It
  holds Apple's private `DisableInflow` power assertion for a bounded time
  and releases it. Agents never run `sudo` and never create a power
  assertion, not even the public idle-sleep one (§4); the probe refuses to
  create anything unless it runs as root.
- **Not authorized:** SMC reads or writes, the SMC adapter cut (`CHIE`),
  any other private mechanism, and another `ChargeInhibit` run. The tool
  can still run note 09's test (`--assertion charge-inhibit`), so that it
  stays reproducible, but a second run needs its own owner decision.
- This Mac stays the test Mac (note 09 §2). AlDente's helper must still be
  absent, checked read-only as in note 09.

## 3. Mechanism and sources

| Item | What | Source | Tags / grade |
|---|---|---|---|
| Assertion type | The string `"DisableInflow"`: `kIOPMAssertionTypeDisableInflow`, alias `kIOPMInflowDisableAssertion`, with the comment "Disables AC Power Inflow (requires root to initiate)". It is not in the public SDK. | IOKitUser `pwr_mgt.subproj/IOPMLibPrivate.h`, lines 532–534 (S1) | `[PRIVATE/UNDOCUMENTED][IOKIT][PRIVILEGED]`, B |
| Creation, release, properties | As for `ChargeInhibit` (note 09 §3): `IOPMAssertionCreateWithProperties` and `IOPMAssertionRelease`, with the same public keys. Creation is synchronous: only `PreventUserIdleSystemSleep` and `NoIdleSleep` may be created asynchronously. | `IOPMLib.h` (S3); IOKitUser `pwr_mgt.subproj/IOPMAssertions.c`, lines 814–831 (S2) | `[PUBLIC-API]`, A; B |
| Privilege | The same caveat as in note 09 §3: `propertiesDictRequiresRoot` looks `kIOPMInflowDisableAssertion` up as a *key* of the properties dictionary. The probe runs as root regardless. | PowerManagement `pmconfigd/PMAssertions.c`, lines 2523–2532 (S4) | B; shipping behaviour unknown |
| Effect in powerd | `DisableInflow` is registered with the handler `handleBatteryAssertions` (lines 6598–6604). On the first active assertion, and when the last one goes, powerd calls `sendSmartBatteryCommand(kSBUCInflowDisable, 1 or 0)` (lines 5383–5385). With a smart battery, **powerd** opens the `AppleSmartBatteryManager` user client and calls that selector (lines 1694–1741); otherwise it sets `ExternalConnected` false on `IOPMPowerSource` entries, which changes a flag only (lines 1742–1771). The probe itself opens no user client. | `PMAssertions.c` (S4) | B |
| Aggregation, timeout, release on exit | As for `ChargeInhibit` (note 09 §3): only the transitions from none to one active assertion and back are forwarded; `TimeoutActionRelease` releases at the timeout; `HandleProcessExit` releases every assertion of a process that exits. | `PMAssertions.c` (S4) | B |
| Effect in the battery driver | The user client checks `kIOClientPrivilegeAdministrator`, then calls `disableInflow` (`AppleSmartBatteryManagerUserClient.cpp`, lines 104–126). `AppleSmartBatteryManager::disableInflowGated` acts only in Intel builds (`#if TARGET_OS_OSX_X86`): it passes the request to the SMBus handler and sets the manager's `Inflow Disabled` property. In any other build it returns `kIOReturnSuccess` and does nothing (`AppleSmartBatteryManager.cpp`, lines 385–396). `inhibitChargingGated` is built the same way (lines 360–371). In those other builds the manager's provider is the SMC (`AppleSMCFamily`, lines 91–130); on this Mac, `AppleSmartBatteryManager` sits under an SMC node (note 02 §1.7). | PowerManagement `AppleSmartBatteryManager/` (S5) | B; the macOS 27 driver source is not published (note 01 §B) |
| What a working cut looks like (Intel path) | "inflow disable means the system is not drawing power from AC". While it is set, the driver reports `ExternalConnected` false even with the adapter attached, and tells the power-management root domain that the adapter went away (`AppleSmartBattery.cpp`, lines 1329–1357). In other builds, `ExternalConnected` and `AppleRawExternalConnected` are each read from the SMC, separately (lines 552–558 and 1547–1566). | S5 | B; unknown on Apple silicon |
| Full discharge | When the battery reports itself fully discharged, the manager re-enables inflow and sends `kIOPMMessageInternalBatteryFullyDischarged` with `kInflowForciblyEnabledBit` (`AppleSmartBatteryManager.cpp`, lines 405–436). The public header describes inflow disabled "for battery calibration" being "forcibly re-enabled" then. | S5; `IOKit/pwr_mgt/IOPM.h`, lines 451–460 (S3) | B; A |
| Visibility | `pmset -g assertions` lists `DisableInflow` in the system-wide summary only while its level is non-zero, and per process for its owner; `pmset -g batt` prints active `DisableInflow` assertions. | PowerManagement `pmset/pmset.m`, lines 1838–1910 and 2549–2568 (S4) | B |
| Battery update time | AppleSmartBattery's `UpdateTime`: set, when a poll of the battery finishes, to the calendar time in whole seconds (`AppleSmartBattery.cpp`, lines 1109–1123). On this Mac it advanced by exactly 60 s per update in steady state (note 01 §B; again on 2026-10-19, §9). | S5; X | B; `[VERIFIED-EXPERIMENTALLY]` read-only, steady state only |
| Idle-sleep assertion | `kIOPMAssertionTypePreventUserIdleSystemSleep` (`"PreventUserIdleSystemSleep"`) prevents idle sleep; "The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons." The client library may create it asynchronously and adds `AllowsDeviceRestart`. | `IOPMLib.h`, lines 275–292 and 1000–1004 (S3); `IOPMAssertions.c`, lines 814–831 and 2384–2395 (S2) | `[PUBLIC-API]`, A; B |
| Adapter details | `IOPSCopyExternalPowerAdapterDetails` "describes the attached (AC) external power adapter"; it returns NULL "if no adapter is attached, or if there's an error". The probe keeps only whether it returned a dictionary, and `Watts`. The dictionary also has a serial number key, which is never read into a sample. | `IOKit/ps/IOPowerSources.h`, lines 364–375; `IOPSKeys.h`, lines 58–67 and 82–91 (S3) | `[PUBLIC-API]`, A |

The probe passes the properties of note 09 §3 with three differences:
`AssertType` is `"DisableInflow"` (S1; not in the SDK), `AssertName` is
`"CellKeeper disable-inflow probe"`, and `Details` names this note. The
timeout stays hold + 30 s with `TimeoutActionRelease`: 210 s for the
default 180 s hold.

**What the published source predicts** `[INFERRED/UNVERIFIED]`. Read
literally, it predicts no effect on Apple silicon for either assertion: the
battery manager accepts both selectors there and does nothing. Note 09's
result agrees for `ChargeInhibit`. The macOS 27 driver is not published,
so whether the shipping code still matches this is unknown, and the run is
the only way to find out. The newest PowerManagement tag
(PowerManagement-1846.120.8.0.1) has the same battery-manager and
user-client files as the tag cited here.

**Clean room.** The type string comes from Apple's open source only; every
key, value and function from the public SDK. No binary was disassembled,
decompiled or string-dumped, and no other battery tool's code or
documentation was consulted for this note or the probe. The SMC adapter
cut is named only as note 02 §3.4 reports it (third-party claims).

## 4. Method

### What the probe reads (read-only)

Everything note 09 §4 lists, read the same way, plus:

| Value | Source | Used for |
|---|---|---|
| Battery update time | AppleSmartBattery `UpdateTime` (undocumented; Unix seconds of the last finished poll), and the reading's own Unix time | verdict: which readings repeat one update; when an update was made |
| Adapter still attached | AppleSmartBattery `AppleRawExternalConnected` (undocumented; the driver reads it from the SMC separately from `ExternalConnected`, §3), and whether `IOPSCopyExternalPowerAdapterDetails` returns an adapter (public), with its `Watts` | verdict, for an adapter cut only |
| `DisableInflow` assertions | `pmset -g assertions`, reduced to structured fields as for `ChargeInhibit` (note 09 §4) | precondition, listing checks |

As in note 09, registry values are read one key at a time and no user
client is opened. Serial numbers, which the battery's registry entry and
the adapter details also carry, are never read into a sample.

### Sequence of `run`

As in note 09 §4, with these changes:

1. `--assertion disable-inflow` or `--assertion charge-inhibit` is
   required, for `check` and `run` alike: there is no default, so the
   owner always says which assertion is tested.
2. After the report file is created and the signal handlers are installed,
   the probe creates one public `PreventUserIdleSystemSleep` assertion for
   the whole run (§3). If the Mac runs from its battery, idle sleep becomes
   likelier during a run of several minutes. Its IOReturn is recorded; if
   it fails, the run goes on, and a sleep still shows up as a gap. It is
   released after the last reading, in a `defer` on every path out of
   `run`, and by powerd when the probe exits. It does not stop a lid-close
   or Apple-menu sleep.
3. The baseline is unchanged: 11 readings over 20 s, all steady charging
   on AC power.
4. **Hold:** 180 s by default, 150–300 s with `--hold`. The probe releases
   early when a reading is unreadable, shows 100% or charged, or shows a
   charge below 25% while the assertion is held. Battery power is no
   longer a reason to release early: it can be the effect.
5. **After:** readings for 180 s after the release. If charging has not
   resumed (a sustained run, below) by then, the probe keeps reading for up
   to 120 s more.
6. The report is written to
   `charge-inhibit-probe-<assertion>-<timestamp>.txt`, for example
   `charge-inhibit-probe-disable-inflow-20261020-101500.txt` (`.gitignore`
   already covers `charge-inhibit-probe-*.txt`).

Readings stay every 2 s, never catching up, on `CLOCK_MONOTONIC`, as in
note 09.

### The verdict (a pure function, `Verdict.evaluate`)

Both assertion types are judged by the same rules. `ChargeInhibit` is not
described as cutting the adapter, but if it did, the verdict would say so.

**A reading** is:

- **charging** when IOPowerSources reports AC power, the charging flag is on
  and the battery current is above 50 mA;
- **stopped** when IOPowerSources reports AC power, the flag is off and the
  current is above −100 mA and at most 50 mA;
- **discharging** when the flag is off and the current is −100 mA or lower,
  whatever IOPowerSources reports about the power source;
- **mixed** otherwise: the flag and the current disagree, or IOPowerSources
  reports battery power while the battery is not discharging. A flag-only
  effect (Apple's published fallback path changes only `ExternalConnected`,
  §3) therefore never passes as a cut.

**Distinct updates.** Each reading carries the battery's `UpdateTime`. Two
readings with the same value repeat one update. A reading's update was made
at its run time minus (its Unix time − `UpdateTime`); since `UpdateTime` is
cut to whole seconds, an update counts as made after a moment *t* when this
is later than *t* − 1 s.

**A sustained run** is as in note 09 (N = 5 counted readings in a row that
agree, each at least 1.5 s after the previous counted one, spanning at least
8 s), and now also needs **readings of at least 2 distinct battery
updates**. Five readings 2 s apart that repeat one update no longer confirm
anything (note 09 §10).

**The effect** while held:

- The first stopped or discharging reading must come within **90 s** of the
  creation (note 09 used 30 s; its one update during the hold came 46 s
  after creation), and its battery update must have been made after the
  creation.
- Every later reading until the release must be in the same state; a
  charging, mixed or other reading makes the run inconclusive, so the
  effect cannot end, or change, while the assertion is still held.
- Those readings must form a sustained run.
- A stopped effect is **(b)**, charging stopped on adapter power. A
  discharging effect is **(c)**, an adapter cut, and it counts as one only
  if **every** discharging reading still reports the adapter attached:
  `AppleRawExternalConnected` is yes, or `IOPSCopyExternalPowerAdapterDetails`
  returns an adapter. Otherwise the run is inconclusive (below).

**After the release**, charging must resume: a sustained run of charging
readings, of battery updates made after the release, beginning within
**120 s** of it (60 s in note 09). Battery power after the release is not a
problem after an adapter cut (the cut may take a moment to end), but it is
after a stopped effect, where it looks like an unplugged adapter.

**No effect observed** needs every reading while held to show charging,
and those readings to include at least **2 distinct battery updates made
after the creation**. Note 09's run, with one update during its hold, would
now be inconclusive.

**What telemetry cannot tell.** No reading can tell an inflow cut from the
owner unplugging the adapter. The probe uses what it can: the effect must
start after the creation and last until the release, then end, and during
an adapter cut every reading must still report the adapter attached. Whether
`AppleRawExternalConnected` or the public adapter details report an adapter
while inflow is disabled on Apple silicon is itself unknown
`[INFERRED/UNVERIFIED]`. If neither does, a real cut and an unplug look the
same, and the verdict is inconclusive with the times in its reason; the
owner then says whether the adapter stayed plugged in (§6).

**The thresholds are judgment calls**, not values from any source, and
every report prints them: 50 mA for "not charging" and −100 mA for
"discharging" (the Mac draws about 10 W from its adapter while not charging,
note 09 §9, so running from the battery means several hundred mA out of
it); readings of 2 distinct updates in every sustained run; an effect
within 90 s of creation (one update interval of 60 s, plus margin); a
resume within 120 s of the release, and 180 s of readings after it (the
resume window plus one update interval); a hold of at least 150 s (the 90 s
effect window plus one update interval, so that an effect first seen late
in the window can still show a second update before the release); a charge
floor of 25% while held; and the baseline and gap rules of note 09 (a gap
over 10 s between readings is a sleep).

| Verdict | When | Exit status |
|---|---|---|
| `inhibited` | Steady charging over the baseline; the assertion created; a sustained stop on AC power beginning within 90 s of creation, from an update made after it, and every reading stopped until the release; the release succeeded and `pmset -g assertions` no longer listed the assertion; then a sustained run of charging readings, beginning within 120 s of the release. Outcome (b). | 0 |
| `inhibited, resumed late` | As above, but the sustained run of charging readings began more than 120 s after the release. | 0 |
| `inhibited, did not resume` | A sustained stop and a confirmed release, then not a single charging reading in at least 120 s of readings after the release (normally 300 s). The report tells the owner to follow the recovery steps (§7). | 3 |
| `adapter cut` | As `inhibited`, but the readings while held were discharging, and every one of them still reported the adapter attached. Outcome (c). | 0 |
| `adapter cut, restored late` | As `adapter cut`, but charging resumed more than 120 s after the release. | 0 |
| `adapter cut, did not restore` | A sustained discharging run while held, a confirmed release, then not a single charging reading in at least 120 s of readings after the release, whatever the adapter reads said. The report tells the owner to follow the recovery steps (§7). | 3 |
| `no effect observed` | Every reading while held showed charging, from at least 2 battery updates made after the creation, and the release was confirmed. Outcome (a), for the measured hold only. | 0 |
| `refused` | `IOPMAssertionCreateWithProperties` did not return `kIOReturnSuccess`. Nothing was held. | 0 |
| `inconclusive` | Anything that prevents a conclusion, including every case of note 09 §4 except battery power while held, and: an effect, or a stretch of charging readings, that does not span 2 battery updates; an effect whose first update was made before the creation; an effect that ends or changes while held; discharging readings that did not all report the adapter attached (the reason gives the times, and says that an unplug at those moments would look the same); a charge below 25% while held; battery power after the release following a stopped effect. | 2 |

The function is pure and covered by unit tests over synthetic runs (§4 of
note 09 lists the earlier ones); this note lists the new ones once they are
written.

## 5. Preconditions

`check --assertion …` prints these and exits 0 if none fails, 1 otherwise.
`run` checks them again and refuses on any failure. Everything in note 09
§5 still applies, with these changes:

| Check | Fails / warns when | Why |
|---|---|---|
| No ChargeInhibit or DisableInflow assertion held | **fails** if `pmset -g assertions` lists either, or cannot be run (both assertion types; replaces note 09's "No ChargeInhibit assertion held") | powerd forwards only the first raise of each type (§3), and either one held by another process would confound the result. |
| Battery update time readable | **fails** without AppleSmartBattery `UpdateTime` (both types) | The verdict counts distinct battery updates. |
| Charge at least 40% | **fails** below 40% (`disable-inflow` only) | If the adapter is cut, the Mac runs from its battery for the hold, and longer if adapter power does not come back. 40% leaves at least 15 points above the 25% floor; at the about 10 W the Mac draws while not charging (note 09 §9), that is hours, not minutes `[INFERRED/UNVERIFIED]`. |
| Adapter reported attached | **warns** unless `AppleRawExternalConnected` is yes or `IOPSCopyExternalPowerAdapterDetails` returns an adapter (`disable-inflow` only) | Without either read, an adapter cut can only be inconclusive. |

The warning for a charge outside 50–74% stays (note 02 §7 recommends 50–75%,
and Optimized Battery Charging may pause near 80%).

## 6. Owner steps

1. Steps 1–4 of note 09 §6 still apply: AlDente fully removed, the probe
   built (`swift build -c release --package-path Tools/charge-inhibit-probe`,
   then `cd Tools/charge-inhibit-probe`), macOS's **Charge Limit at 100%**
   (and Optimized Battery Charging off if the charge is 75% or more), and
   the Apple power adapter connected, with the Mac charging. The charge must
   be at least 40%; 50–74% is best.
2. Keep the lid open and the Mac on a hard surface, stay with it, and **do
   not touch the adapter or its cable** during the run: if the Mac starts
   running from its battery, the probe cannot tell that from an unplugged
   adapter (§4).
3. Check, without privileges:

   ```sh
   .build/release/charge-inhibit-probe check --assertion disable-inflow
   ```

   It must end with `READY`. Fix any `FAIL` line first; read any `WARN`.
4. Run the test:

   ```sh
   sudo .build/release/charge-inhibit-probe run --assertion disable-inflow
   ```

   It takes about 6½ minutes (20 s baseline, 180 s hold, 180 s after), up
   to 8½ minutes if charging is slow to resume. `--hold` takes 150–300 s.
   If the battery menu shows the Mac on battery power during the hold, that
   may be the effect: leave the adapter as it is. Ctrl-C at any time
   releases the assertion and ends the run with a report.
5. Send the file
   `Tools/charge-inhibit-probe/charge-inhibit-probe-disable-inflow-<timestamp>.txt`
   to the lead, and say whether the adapter stayed plugged in the whole
   time. Git ignores these files.
6. Set the Charge Limit (and Optimized Battery Charging) back the way you
   want them.

## 7. Safety

- **What it changes.** One private assertion, held for the hold time (180 s
  by default, at most 300 s), and one public idle-sleep assertion for the
  run, both in powerd's memory. No other file than the report, no setting,
  no `pmset` setting, no SMC key, no launchd job, nothing persistent that
  the published source shows.
- **If the adapter is cut** (outcome c), the Mac runs from its battery while
  the assertion is held. At the about 10 W it draws while not charging
  (note 09 §9), 300 s is under 1 Wh, about a percent of a laptop battery
  `[INFERRED/UNVERIFIED]`. The probe releases at once if the charge falls
  below 25% (note 02 §7 puts the floor for an adapter cut at about 25–30%),
  and it refuses to start below 40% (§5). In Apple's published source, a
  fully discharged battery also re-enables inflow (§3, B; Intel path).
- **Sleep.** A closed lid or the Apple menu still sleeps the Mac; the
  idle-sleep assertion stops only idle sleep. A sleep shows up as a gap and
  makes the run inconclusive.
- **Fail-safe release, in layers**, as in note 09 §7: the probe releases
  the assertion after the hold, on SIGINT, SIGTERM or SIGHUP, on a reading
  that ends the hold early, and in a `defer`; a failed release is retried;
  after a signal, nothing is created. The assertion carries a timeout of
  hold + 30 s with `TimeoutActionRelease`, and powerd releases every
  assertion of a process that exits. The idle-sleep assertion is released
  the same ways.
- **If adapter power or charging does not come back** (verdict
  `adapter cut, did not restore` or `inhibited, did not resume`, or at any
  time):
  1. If the probe still runs, press Ctrl-C (twice quits at once); powerd
     releases its assertions when it exits.
  2. Run `pmset -g assertions`: it must list no `DisableInflow`.
  3. Unplug the adapter, wait a few seconds, and plug it back in.
  4. Quit any battery tool (and CellKeeper, if it is running).
  5. Restart the Mac. On Apple silicon there is no SMC reset: "SMC resets
     automatically" (note 02 §1.8). The strongest step is to shut down,
     wait about 30 seconds, and start the Mac again.
  6. Check macOS's own Charge Limit and Optimized Battery Charging; you set
     them for the test.

  These follow
  [`safety.md`, "If charging does not resume"](../safety.md#if-charging-does-not-resume).
  **Unknown:** whether any state outlives powerd's memory. The published
  source keeps assertions in powerd and, on Intel, passes the request to
  the battery's SMBus handler; what the macOS 27 driver or the SMC keep, and
  whether a restart clears it, is not known.
- **What the probe never does:** run as root unless the owner starts it
  with `sudo`; create more than one private assertion and one idle-sleep
  assertion; use any other assertion type; open an IOUserClient (powerd
  may, as part of Apple's own handling); read or write SMC keys; change
  `pmset` settings; read the AlDente helper's files; read any process's
  memory.

## 8. Open questions

1. Does the macOS 27 battery driver implement the inflow-disable selector
   on Apple silicon? The published one does not (§3).
2. If it does, does an inflow cut keep reporting the adapter attached
   (`AppleRawExternalConnected`, the public adapter details), so that it
   can be told from an unplug?
3. Does the shipping powerd require root for `DisableInflow`? The same
   question as note 09 §8 (1); not tested.
4. Sleep, wake, restart, unplug and replug while held (note 02 §7, Phase D)
   are out of scope, as is whether the assertion's timeout counts while the
   Mac sleeps.
5. How often does `UpdateTime` advance while charging, discharging, or
   around plug events? Only the steady state (on AC, not charging, at 80%)
   was observed (note 01 §B, §9).

## 9. Pre-run state

`[VERIFIED-EXPERIMENTALLY]` (read-only, 2026-10-19, 21:55–22:00 local): with
the Mac on AC power, held at 80% by macOS's Charge Limit and not charging,
`ioreg -r -c AppleSmartBattery -d 1` showed `UpdateTime` advancing by
exactly 60 s, six times in a row; once before that it advanced by 39 s.
`AppleRawExternalConnected`, `ExternalConnected` and
`ExternalChargeCapable` were all yes. Only these values and key names were
read.

The read-only `check` output follows once the probe is extended.

## 10. Results

Not run yet. The owner fills in, or sends the report for:

| Field | Value |
|---|---|
| Date and time | |
| macOS build, firmware | |
| Assertion, hold | `DisableInflow`, … s (timeout … s, `TimeoutActionRelease`) |
| IOReturn of creation | |
| IOReturn of release (attempts) | |
| Listed by `pmset -g assertions` 2 s after creation / before / after the release | |
| Idle-sleep assertion: IOReturn of creation / release | |
| Battery updates during the hold | |
| Effect, and when it began | |
| Adapter reported attached during the effect | |
| Charging resumed after the release | |
| Verdict | |
| Adapter stayed plugged in (the owner's account) | |
| Notes | |

## 11. Sources

All fetched on 2026-10-19 unless stated otherwise.

- **S1** — apple-oss-distributions/IOKitUser, `pwr_mgt.subproj/IOPMLibPrivate.h`,
  branch `main` (commit 323ead8, note 02's S10):
  https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMLibPrivate.h
  (APSL-2.0). Supports: the `DisableInflow` type string and its comment.
- **S2** — apple-oss-distributions/IOKitUser, `pwr_mgt.subproj/IOPMAssertions.c`,
  branch `main`:
  https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMAssertions.c
  (APSL-2.0). Supports: synchronous creation for `DisableInflow`; how the
  idle-sleep assertion is created.
- **S3** — macOS 27.0 SDK (Xcode 27.0), `IOKit/pwr_mgt/IOPMLib.h`,
  `IOKit/pwr_mgt/IOPM.h`, `IOKit/ps/IOPowerSources.h`, `IOKit/ps/IOPSKeys.h`
  and `IOKit/IOReturn.h`, read locally. Supports: the creation and release
  functions, every property key and value except the type, the idle-sleep
  assertion, the inflow-cancelled message, the adapter details, and
  IOReturn names.
- **S4** — apple-oss-distributions/PowerManagement, tag
  PowerManagement-1846.0.25.0.1 (note 02's S11, note 09's S4), files
  `pmconfigd/PMAssertions.c` and `pmset/pmset.m`:
  https://raw.githubusercontent.com/apple-oss-distributions/PowerManagement/PowerManagement-1846.0.25.0.1/pmconfigd/PMAssertions.c
  and
  https://raw.githubusercontent.com/apple-oss-distributions/PowerManagement/PowerManagement-1846.0.25.0.1/pmset/pmset.m
  (APSL-2.0). Supports: the privilege check, the forwarding to the battery
  manager and its fallback, aggregation, timeout release, release on
  process exit, and what `pmset` prints.
- **S5** — apple-oss-distributions/PowerManagement, tag
  PowerManagement-1846.0.25.0.1, files
  `AppleSmartBatteryManager/AppleSmartBatteryManager.cpp`,
  `AppleSmartBatteryManager/AppleSmartBatteryManagerUserClient.cpp` and
  `AppleSmartBatteryManager/AppleSmartBattery.cpp`, under
  https://raw.githubusercontent.com/apple-oss-distributions/PowerManagement/PowerManagement-1846.0.25.0.1/AppleSmartBatteryManager/
  (APSL-2.0); the first two compared with tag
  PowerManagement-1846.120.8.0.1 (identical). Supports: the administrator
  check, the Intel-only inflow and charge-inhibit actions, the SMC
  provider in other builds, how `ExternalConnected` and
  `AppleRawExternalConnected` are set, the full-discharge re-enable, and
  `UpdateTime`.
