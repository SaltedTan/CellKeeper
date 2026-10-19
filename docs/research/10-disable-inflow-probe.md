# 10 — The DisableInflow probe (owner-run, on the maintainer's Mac)

- **Date:** 2026-10-19
- **Status:** Designed and built, not run. The owner authorized one run
  (§2); its results go in §10.
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
| Effect in powerd | `DisableInflow` is registered with the handler `handleBatteryAssertions` (lines 6598–6604). On the first active assertion, and when the last one goes, powerd calls `sendSmartBatteryCommand(kSBUCInflowDisable, 1 or 0)` (lines 5383–5385). With a smart battery, **powerd** opens the `AppleSmartBatteryManager` user client and calls that selector (lines 1694–1741); otherwise it sets `ExternalConnected` false on `IOPMPowerSource` entries, which changes a flag only (lines 1742–1771). | `PMAssertions.c` (S4) | B |
| Aggregation, timeout, release on exit | As for `ChargeInhibit` (note 09 §3): only the transitions from none to one active assertion and back are forwarded; `TimeoutActionRelease` releases at the timeout; `HandleProcessExit` releases every assertion of a process that exits. | `PMAssertions.c` (S4) | B |
| Effect in the battery driver | The user client checks `kIOClientPrivilegeAdministrator`, then calls `disableInflow` (`AppleSmartBatteryManagerUserClient.cpp`, lines 104–126). `AppleSmartBatteryManager::disableInflowGated` acts only in Intel builds (`#if TARGET_OS_OSX_X86`): it passes the request to the SMBus handler and sets the manager's `Inflow Disabled` property. In any other build it returns `kIOReturnSuccess` and does nothing (`AppleSmartBatteryManager.cpp`, lines 385–396). `inhibitChargingGated` is built the same way (lines 360–371). In those other builds the manager's provider is the SMC (`AppleSMCFamily`, lines 91–130); on this Mac, `AppleSmartBatteryManager` sits under an SMC node (note 02 §1.7). | PowerManagement `AppleSmartBatteryManager/` (S5) | B; the macOS 27 driver source is not published (note 01 §B) |
| What a working cut looks like (Intel path) | "inflow disable means the system is not drawing power from AC". While it is set, the driver reports `ExternalConnected` false even with the adapter attached, and tells the power-management root domain that the adapter went away (`AppleSmartBattery.cpp`, lines 1329–1357). In other builds, `ExternalConnected` and `AppleRawExternalConnected` are each read from the SMC, separately (lines 552–558 and 1547–1566). | S5 | B; unknown on Apple silicon |
| Full discharge | When the battery reports itself fully discharged, the manager re-enables inflow and sends `kIOPMMessageInternalBatteryFullyDischarged` with `kInflowForciblyEnabledBit` (`AppleSmartBatteryManager.cpp`, lines 405–436). The public header describes inflow disabled "for battery calibration" being "forcibly re-enabled" then. | S5; `IOKit/pwr_mgt/IOPM.h`, lines 451–460 (S3) | B; A |
| Visibility | `pmset -g assertions` lists `DisableInflow` in the system-wide summary only while its level is non-zero, and per process for its owner; `pmset -g batt` prints active `DisableInflow` assertions. | PowerManagement `pmset/pmset.m`, lines 1838–1910 and 2549–2568 (S4) | B |
| Battery update time | AppleSmartBattery's `UpdateTime`: set, when a poll of the battery finishes, to the calendar time in whole seconds (`AppleSmartBattery.cpp`, lines 1109–1123). On this Mac it advanced by exactly 60 s per update in steady state (note 01 §B; again on 2026-10-19, §9). | S5; X | B; `[VERIFIED-EXPERIMENTALLY]` read-only, steady state only |
| Idle-sleep assertion | `kIOPMAssertionTypePreventUserIdleSystemSleep` (`"PreventUserIdleSystemSleep"`) prevents idle sleep; "The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons." The client library may create it asynchronously and adds `AllowsDeviceRestart`. | `IOPMLib.h`, lines 275–292 and 1000–1004 (S3); `IOPMAssertions.c`, lines 814–831 and 2384–2395 (S2) | `[PUBLIC-API]`, A; B |
| Sleep notifications | `IORegisterForSystemPower` "Connects the caller to the Root Power Domain IOService for the purpose of receiving sleep & wake notifications". `kIOMessageSystemWillSleep` "is delivered at the point the system is initiating a non-abortable sleep", "before any hardware is powered off"; the caller must answer with `IOAllowPowerChange`, or sleep continues after 30 s. In IOKitUser, it opens a connection to `IOPMrootDomain` (`IOServiceOpen`), and `IOAllowPowerChange` answers through it. The helper daemon uses the same interface (`SleepNotifications.swift`). | `IOPMLib.h`, lines 127–207 (S3); IOKitUser `pwr_mgt.subproj/IOPMLib.c`, lines 271–351 and 374–386 (S6) | `[PUBLIC-API][IOKIT]`, A; B |
| Adapter details | `IOPSCopyExternalPowerAdapterDetails` "describes the attached (AC) external power adapter"; it returns NULL "if no adapter is attached, or if there's an error". The probe keeps only whether it returned a dictionary, and `Watts`. The dictionary also has a serial number key, which is never read into a sample. | `IOKit/ps/IOPowerSources.h`, lines 364–375; `IOPSKeys.h`, lines 58–67 and 82–91 (S3) | `[PUBLIC-API]`, A |

The probe passes the properties of note 09 §3 with three differences:
`AssertType` is `"DisableInflow"` (S1; not in the SDK), `AssertName` is
`"CellKeeper disable-inflow probe"`, and `Details` names this note. The
timeout stays hold + 30 s with `TimeoutActionRelease`: 210 s for the
default 180 s hold.

**What the published source predicts** `[INFERRED/UNVERIFIED]`. Read
literally, the PowerManagement-1846.0.25.0.1 files cited above predict no
effect on Apple silicon for either assertion: powerd forwards both to the
battery manager, which accepts both selectors in non-Intel builds and does
nothing with them. Note 09's result agrees for `ChargeInhibit`. The newest
PowerManagement tag (PowerManagement-1846.120.8.0.1) has the same
battery-manager and user-client files. The macOS 27 driver is not
published, so whether the shipping code still matches this is unknown, and
the run is the only way to find out.

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
| Battery update time | AppleSmartBattery `UpdateTime` (undocumented; Unix seconds of the last finished poll), and the reading's own Unix time | verdict: which readings repeat one update; whether an update was made after a moment; how old it is |
| Adapter still attached | AppleSmartBattery `AppleRawExternalConnected` (undocumented; the driver reads it from the SMC separately from `ExternalConnected`, §3), and whether `IOPSCopyExternalPowerAdapterDetails` returns an adapter (public), with its `Watts` | verdict, for an adapter cut only |
| System power input | AppleSmartBattery `PowerTelemetryData.SystemPowerIn` (undocumented, mW by inference, note 01), which note 09 recorded for the report only | verdict, for an adapter cut only; the moment adapter power is back |
| `DisableInflow` assertions | `pmset -g assertions`, reduced to structured fields as for `ChargeInhibit` (note 09 §4) | precondition, listing checks |

As in note 09, registry values are read one key at a time and no
user client of the battery or the SMC is opened. Serial numbers, which the
battery's registry entry and the adapter details also carry, are never read
into a sample.

### Sequence of `run`

As in note 09 §4, with these changes:

1. `--assertion disable-inflow` or `--assertion charge-inhibit` is
   required, for `check` and `run` alike: there is no default, so the
   owner always says which assertion is tested.
2. After the report file is created and the signal handlers are installed,
   the probe registers for system sleep notifications
   (`IORegisterForSystemPower`, §3) and creates one public
   `PreventUserIdleSystemSleep` assertion for the whole run, with its own
   timeout (the longest run, below, plus 120 s, with
   `TimeoutActionRelease`). If the Mac runs from its battery, idle sleep
   becomes likelier during a run of several minutes. If either fails, the
   probe refuses (exit 1) before it creates the private assertion. The
   idle-sleep assertion does not stop a lid-close or Apple-menu sleep.
3. **Sleep.** On `kIOMessageSystemWillSleep`, the probe latches its stop
   and releases the private assertion (with retries); it never creates the
   assertion again. What happens next depends on that release
   (`SleepResponse.willSleep`, a pure decision the tests drive with fakes):
   - Released (`IOPMAssertionRelease` succeeded), or none was held: the
     probe appends a line saying so to the report file, which it keeps
     open (`O_APPEND`), and allows the sleep (`IOAllowPowerChange`).
   - Every attempt failed: the probe never allows the sleep and never says
     the assertion was released. It takes these steps, in this order
     (`EmergencyExit`):
     1. It arms a 2 s exit deadline that depends on no lock, queue or
        output: SIGALRM back to its default action, which ends the
        process, and `alarm(2)`.
     2. It appends one line to the report file.
     3. It ends the process with `_exit(3)` (the exit status of a run
        after which charging did not resume).

     The console shows nothing on this path; the report file and the exit
     status carry it. If the report write hangs (a disk that does not
     answer), the deadline ends the process within 2 s.

   The notification runs on its own serial queue (`SleepQueue`), and
   nothing there may block: it writes nothing to the console on either
   path, takes no lock that the main thread holds across a blocking call,
   and uses no Foundation file handle. Its only work is the release (with
   its bounded retries), the one-line append to the report file, and the
   acknowledgement or the exit. This matters because the main thread waits
   for that queue when it deregisters from the notifications at the end of
   the run: a console write there, blocked on a full pipe, would stop the
   run from finishing. As a second guard, the probe's console drops any
   write made from that queue (`ProbeConsole`). The sleep notice reaches
   the console through the main thread, in the final report it prints,
   and the verdict is inconclusive. The probe never changes the flags of
   its console's descriptors: they are shared with the shell.
     Exiting is the strongest release left: powerd frees every assertion
     of a process that exits (`HandleProcessExit`, B; note 09 §7). Without
     an acknowledgement, the system waits until the client is gone, or for
     its acknowledgement timeout (about 30 s, S3), before it sleeps; that
     only delays the sleep, which is the safe direction
     `[INFERRED/UNVERIFIED]` for the shipping kernel. `_exit` rather than
     `exit`: it runs no exit handlers, which could wait on locks the main
     thread holds, and nothing is left to flush.

   On `kIOMessageCanSystemSleep` the probe allows at once: the idle-sleep
   assertion already covers idle sleep, and the probe does not fight a
   forced one. Any sleep notification makes the run inconclusive. Whether
   an assertion's timeout counts while the Mac sleeps is not known, which
   is why the probe does not rely on it here.
4. **Baseline:** readings every 2 s for at least 20 s and until they show 2
   battery updates (2 strictly advancing `UpdateTime` values), all steady
   charging on AC power; at most 150 s. If it has not seen 2 updates by
   then, a reading is not steady charging, or the baseline breaks a clock
   rule (below), nothing is created. At the creation, checked under the
   holder's lock immediately before the call, the last baseline reading
   must be at most 4 s old (as in note 09), the latest battery update at
   most 70 s old, and the clock rules must still hold from the baseline up
   to that moment; otherwise nothing is created, and the report says why.
5. **Hold:** 180 s by default, 165–300 s with `--hold`. The probe releases
   early when a reading is unreadable, shows 100% or charged, shows a
   charge below 25%, or shows a battery update more than 150 s old (2.5
   update intervals). Battery power is not a reason to release early: it
   can be the effect.
6. **After:** readings for 180 s after the release. If charging has not
   resumed (a sustained run, below) by then, the probe keeps reading for up
   to 120 s more. The longest run is therefore 150 + 300 + 180 + 120 s,
   about 12½ minutes; with the default hold, it is usually about 6½ minutes.
7. **Cleanup**, in this order: the private assertion (with retries), the
   idle-sleep assertion, the sleep notifications (`Teardown`). A stop
   signal or a sleep notification takes the first step at once; the run
   then finishes and takes all three, at its end and in a `defer` on every
   path out of it.
8. The report is written to
   `charge-inhibit-probe-<assertion>-<timestamp>.txt`, for example
   `charge-inhibit-probe-disable-inflow-20261020-101500.txt` (`.gitignore`
   already covers `charge-inhibit-probe-*.txt`). If an assertion was held
   and either its release is not confirmed or the last reading does not
   show charging on adapter power, the report opens with the recovery
   steps (§7), whatever the verdict.
9. **"Released" only when confirmed.** The console and the report say the
   assertion was released only when `IOPMAssertionRelease` succeeded and,
   where the probe checks it, `pmset -g assertions` no longer lists it. A
   stop signal, a sleep notification and the end of the run are worded the
   same way (`ReleaseWording`); otherwise they say "release attempted (N
   tries) and failed — powerd releases it at its timeout or when the probe
   exits", and the report opens with the recovery steps.

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

**Battery updates.** Each reading carries the battery's `UpdateTime`, cut
to whole seconds. Readings with the same value repeat one update. An update
counts as made after a moment (the creation, the release) only if its
`UpdateTime` is at least the moment's whole second plus one; an update in
the same second is ambiguous and never counts as evidence. Only strictly
advancing values are counted. An `UpdateTime` that goes backward between
readings, or lies more than 2 s ahead of the reading's wall time, or
wall-clock and run-clock intervals that differ by more than 2 s (the wall
clock was set) make the run inconclusive; during the baseline, they stop
the assertion from being created. The intervals are compared between
consecutive readings directly, and also between the creation or the
release and the readings just before and after it, so that an event
between two readings never splits their disagreement into two smaller,
accepted steps.

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
- A stopped effect is **(b)**, charging stopped on adapter power. macOS's
  own charging and thermal management can also stop charging; the stop is
  attributed to the assertion only because it began after the creation and
  lasted until the release, and the verdict text says so.
- A discharging effect is **(c)**, an adapter cut, only if **every**
  discharging reading still reports the adapter attached
  (`AppleRawExternalConnected` is yes, or `IOPSCopyExternalPowerAdapterDetails`
  returns an adapter) **and** a system power input of at most 1000 mW. That
  the adapter's power was cut is then an inference from those readings
  `[INFERRED/UNVERIFIED]`. With the adapter reported attached but more input
  (or an input that cannot be read), the verdict is **discharging with
  adapter attached**: a weak adapter or a high load looks the same, so the
  discharge is not attributed to a cut. If some discharging reading does
  not report the adapter, the run is inconclusive (below).

**After the release**, charging must resume: a sustained run of charging
readings, of battery updates made after the release, beginning within
**120 s** of it (60 s in note 09). After a discharge, the verdict also
reports separately when adapter power was back: the first reading, of an
update made after the release, that is not discharging and shows more than
1000 mW of input. Battery power after the release is not a problem after a
discharge (it may take a moment to end), but it is after a stopped effect,
where it looks like an unplugged adapter. A negative verdict ("did not
resume") needs no charging reading in at least 120 s of readings **and**
readings of at least 2 battery updates made after the release; otherwise
the run is inconclusive (and the report still opens with the recovery
steps).

**No effect observed** needs every reading while held to show charging,
and those readings to include at least **2 distinct battery updates made
after the creation**. Note 09's run, with one update during its hold, would
now be inconclusive; its recorded verdict (note 09 §10) is left as it was.

**What telemetry cannot tell.** No reading can tell an inflow cut from the
owner unplugging the adapter. The probe uses what it can: the effect must
start after the creation and last until the release, then end, and during
an adapter cut every reading must still report the adapter attached.
Whether `AppleRawExternalConnected` or the public adapter details report an
adapter while inflow is disabled on Apple silicon is itself unknown
`[INFERRED/UNVERIFIED]`. If neither does, a real cut and an unplug look the
same, and the verdict is inconclusive with the times in its reason; the
owner then says whether the adapter stayed plugged in (§6).

**The thresholds are judgment calls**, not values from any source, and
every report prints them:

- 50 mA for "not charging", and −100 mA for "discharging": the Mac draws
  about 10–16 W from its adapter while not charging (note 09 §9, §9 here),
  so running from the battery means several hundred mA out of it;
- 1000 mW of system power input as the most a cut adapter may still show;
- readings of 2 distinct battery updates in every sustained run, in the
  baseline, in "no effect observed" and in "did not resume";
- an effect within 90 s of creation: one update interval of 60 s, plus
  margin;
- a resume within 120 s of the release, and 180 s of readings after it:
  the resume window plus one update interval;
- a hold of at least 165 s: the 90 s effect window, one 60 s update
  interval so that an effect first seen late in the window can show a
  second update before the release, and 15 s of sampling margin. Cases
  closer to that boundary are inconclusive, not misjudged;
- a baseline of 20–150 s, its latest update at most 70 s old at creation;
  a battery update at most 150 s old while held; a charge floor of 25%
  while held;
- 2 s of tolerance between `UpdateTime`, the wall clock and the run's
  clock;
- the gap rules of note 09: a gap over 10 s between readings is a sleep,
  and the last baseline reading at most 4 s old at creation.

| Verdict | When | Exit status |
|---|---|---|
| `inhibited` | Steady charging over the baseline; the assertion created; a sustained stop on AC power beginning within 90 s of creation, from an update made after it, and every reading stopped until the release; the release succeeded and `pmset -g assertions` no longer listed the assertion; then a sustained run of charging readings, beginning within 120 s of the release. Outcome (b). | 0 |
| `inhibited, resumed late` | As above, but the sustained run of charging readings began more than 120 s after the release. | 0 |
| `inhibited, did not resume` | A sustained stop and a confirmed release, then not a single charging reading in at least 120 s of readings after the release (normally 300 s), over at least 2 updates made after it. The report tells the owner to follow the recovery steps (§7). | 3 |
| `adapter cut` | As `inhibited`, but the readings while held were discharging, and every one of them reported the adapter attached and at most 1000 mW of input. Outcome (c), by inference. | 0 |
| `adapter cut, resumed late` | As `adapter cut`, but charging resumed more than 120 s after the release. | 0 |
| `discharging with adapter attached` | A sustained discharge while held, every reading reporting the adapter attached, but some with more than 1000 mW of input or none readable; charging resumed after a confirmed release. Not attributed to a cut. | 0 |
| `discharging, did not resume` | A sustained discharge while held, a confirmed release, then not a single charging reading in at least 120 s of readings after the release, over at least 2 updates made after it, whatever the adapter reads said. The report says whether the readings looked like a cut, and tells the owner to follow the recovery steps (§7). | 3 |
| `no effect observed` | Every reading while held showed charging, from at least 2 battery updates made after the creation, and the release was confirmed. Outcome (a), for the measured hold only. | 0 |
| `refused` | `IOPMAssertionCreateWithProperties` did not return `kIOReturnSuccess`. Nothing was held. | 0 |
| `inconclusive` | Anything that prevents a conclusion, including every case of note 09 §4 except battery power while held, and: a baseline without 2 updates in 150 s, or with its latest update more than 70 s old at creation; a sleep notification; an `UpdateTime` that goes backward or runs ahead, or a wall clock that jumps (during the baseline or up to the creation, nothing is created); an effect, or a stretch of charging readings, that does not span 2 battery updates; an effect whose first update was not made after the creation; an effect that ends or changes while held; discharging readings that did not all report the adapter attached (the reason gives the times, and says that an unplug at those moments would look the same); a battery update more than 150 s old, or a charge below 25%, while held; battery power after the release following a stopped effect; no charging after the release, but fewer than 2 updates made after it. | 2 |

The function is pure and covered by unit tests over synthetic runs, on
the probe's real schedule, with every reading its own battery update or
with the battery updating once a minute as on this Mac
(`swift test --package-path Tools/charge-inhibit-probe`, 137 tests). Beyond
the cases note 09 §4 lists, which still pass with the new windows, they
cover:

- outcome (b) for both assertion types;
- outcome (c) with IOPowerSources reporting battery power or still AC
  power; adapter power back before charging resumes; a resume after the
  120 s window; a cut that does not end after the release (exit 3);
- discharging with the adapter still delivering power, including one
  reading above 1000 mW and an unreadable input;
- unplug-like readings that end after the release (inconclusive) and that
  never end (exit 3), and a single unplug-like reading during a cut;
- Apple's flag-only fallback; a cut that ends while held; a stop that turns
  into a discharge;
- no effect over two updates, and note 09's case of one;
- at once-a-minute updates: a stop seen only in readings of one update, a
  stop first seen 46 s after creation (attributed now, late under note 09's
  30 s window), and a resume that needs its second update;
- an update in the creation's second; the same-second rule itself;
  `UpdateTime` going backward or running ahead; a wall clock that jumps;
- the same clock faults in the baseline (backward, ahead, a jump) and a
  jump between the last baseline reading and the creation, each refused
  before anything is created; and the code review's case of a 3 s jump
  that an event between two readings split into two 1.5 s steps, across
  the creation and across the release, each inconclusive;
- on a sleep notification: a successful release, then the report line
  and the acknowledgement; nothing held, in the same order; and a failed
  release, with no acknowledgement, no claim that it was released, and
  the emergency exit with status 3, after which nothing else happens even
  when a fake exit returns; the teardown order on the normal path, after a
  stop signal and after a sleep notification;
- the probe's sleep handler run on a real sleep queue, for each outcome,
  with a console that fails the test if the queue writes to it; the
  console dropping a write from the sleep queue; and the teardown, which
  drains the sleep queue, completing within 2 s while a console writer is
  blocked (a writer that waits until the test lets it go);
- the emergency exit's order (deadline, report line, exit, and no console
  step), alone and inside the sleep response; the report line appended to
  a real report file; a report file that could not be opened, after which
  the exit still happens;
- "released" only when confirmed: the console line after SIGINT with a
  failed release, the report's stop note (a failed release, an assertion
  still listed or not checkable, nothing held), a whole report after a
  failed release at the normal end or after SIGINT (no "released"
  anywhere, recovery steps first), a release still listed or not
  checkable (recovery steps first), and the verdict after a sleep notice;
- a "did not resume" without 2 updates after the release (inconclusive,
  with the recovery steps first in the report); a stale update while held;
  a baseline of one update; a baseline update too old at creation;
- a sleep notification; a charge below 25%; a hold shorter than the 90 s
  window; a failed release, no resume and a sleep gap, as before.

Each key rule was mutation-checked on 2026-10-19: with any one of 44 rules
disabled (the 2-update requirement, the same-second rule, the adapter and
power-input conditions of a cut, the 90 s window, the floor, the sleep
notices, the staleness and clock checks, the 2 updates after the release,
the release check, the gap rule, the update-after-creation rule, the
baseline's 2 updates and update age, the reading states, the effect lasting
until the release, the report's recovery section, the baseline's and the
creation's clock checks, the direct comparison of consecutive readings and
of events with the reading before them, and, on a sleep notification, the
release before the acknowledgement, no acknowledgement and an exit after a
failed release, the failure line, and the teardown order; the report line
before the acknowledgement; the emergency exit's deadline before the
report line, the report line before the exit, and the report line itself;
the console dropping writes from the sleep queue, the queue being
recognised, the handler recording the stop, and a handler that blocks on
the queue (the teardown then misses its 2 s bound); and "released" only
when confirmed in the signal line, the stop note, the recovery block and
the sleep-notice verdict), at least one test fails.
`charge-inhibit-probe` builds with `-warnings-as-errors`, and CI
runs those tests on every matrix toolchain.

## 5. Preconditions

`check --assertion …` prints these and exits 0 if none fails, 1 otherwise.
`run` checks them again and refuses on any failure. Everything in note 09
§5 still applies, with these changes:

| Check | Fails / warns when | Why |
|---|---|---|
| No ChargeInhibit or DisableInflow assertion held | **fails** if `pmset -g assertions` lists either, or cannot be run (both assertion types; replaces note 09's "No ChargeInhibit assertion held") | powerd forwards only the first raise of each type (§3), and either one held by another process would confound the result. |
| Battery update time readable | **fails** without AppleSmartBattery `UpdateTime` (both types) | The verdict counts battery updates. |
| System power input readable | **fails** without `PowerTelemetryData.SystemPowerIn` (both types) | Without it, a cut adapter cannot be told from a weak one. |
| Charge at least 40% | **fails** below 40% (`disable-inflow` only) | If the adapter is cut, the Mac runs from its battery for the hold, and longer if adapter power does not come back. 40% leaves 15 points above the 25% floor; at the 10–16 W the Mac draws while not charging, that is hours, not minutes `[INFERRED/UNVERIFIED]`. |
| Adapter reported attached | **warns** unless `AppleRawExternalConnected` is yes or `IOPSCopyExternalPowerAdapterDetails` returns an adapter (`disable-inflow` only) | Without either read, an adapter cut can only be inconclusive. |
| Optimized Battery Charging off | **always warns** (`disable-inflow` only): the probe cannot read this setting | It must be off for the whole experiment (§6), so that macOS does not pause charging by itself. |

The warning for a charge outside 50–74% stays (note 02 §7 recommends 50–75%,
and Optimized Battery Charging may pause near 80%).

## 6. Owner steps

1. Steps 1–2 of note 09 §6 still apply: AlDente fully removed, and the
   probe built:

   ```sh
   swift build -c release --package-path Tools/charge-inhibit-probe
   cd Tools/charge-inhibit-probe
   ```

2. In **System Settings › Battery › ⓘ next to Charging**, set the **Charge
   Limit to 100%** and turn **Optimized Battery Charging off**, for the
   whole experiment. The charge must be at least 40%; 50–74% is best.
3. Connect the Apple power adapter and wait until the battery menu shows it
   charging. Keep the lid open and the Mac on a hard surface, and stay with
   it.
4. **During the run, do not touch the adapter or its cable.** The run may
   leave the Mac running from its battery while the adapter is plugged in,
   for up to the hold (3 minutes by default): that may be the effect. If
   the battery menu shows battery power during the hold, leave the adapter
   as it is. The probe cannot tell this from an unplugged adapter, so it
   relies on you not touching it (§4).
5. Check, without privileges:

   ```sh
   .build/release/charge-inhibit-probe check --assertion disable-inflow
   ```

   It must end with `READY`. Fix any `FAIL` line first; read the `WARN`
   lines (the Optimized Battery Charging reminder always shows).
6. Run the test:

   ```sh
   sudo .build/release/charge-inhibit-probe run --assertion disable-inflow
   ```

   It takes about 6½ minutes (a baseline of 20–60 s, the 180 s hold, 180 s
   after), up to about 10½ minutes if the baseline waits for a battery
   update or charging is slow to resume. `--hold` takes 165–300 s. Do not
   close the lid or let the Mac sleep. Ctrl-C at any time releases the
   assertion and ends the run with a report.
7. **After the run, check recovery first.** The battery menu must show the
   Mac on power adapter and charging again, and `pmset -g assertions` must
   list neither `DisableInflow` nor `ChargeInhibit`. If not, or if the
   report opens with "CHECK RECOVERY FIRST", follow §7's recovery steps.
8. Only then set the Charge Limit and Optimized Battery Charging back the
   way you want them, and send the file
   `Tools/charge-inhibit-probe/charge-inhibit-probe-disable-inflow-<timestamp>.txt`
   to the lead, saying whether the adapter stayed plugged in the whole
   time. Git ignores these files.

## 7. Safety

- **What it changes.** One private assertion, held for the hold time (180 s
  by default, at most 300 s), one public idle-sleep assertion for the run,
  both in powerd's memory, and a registration for sleep notifications. No
  other file than the report, no setting, no `pmset` setting, no SMC key, no
  launchd job, nothing persistent that the published source shows.
- **If the adapter is cut** (outcome c), the Mac runs from its battery while
  the assertion is held. At the 10–16 W it draws while not charging, 300 s
  is about 1 Wh, a percent or two of a laptop battery
  `[INFERRED/UNVERIFIED]`. The probe ends the hold and releases the
  assertion at once if the charge falls below 25% (note 02 §7 puts the floor for an adapter cut at about 25–30%),
  and it refuses to start below 40% (§5). In Apple's published source, a
  fully discharged battery also re-enables inflow (§3, B; Intel path).
- **Sleep.** A closed lid or the Apple menu still sleeps the Mac; the
  idle-sleep assertion stops only idle sleep. Before any sleep, the probe
  releases the private assertion and only then allows it (§4); a sleep
  makes the run inconclusive. Whether an assertion's timeout counts during
  sleep is unknown, so the probe does not rely on it there.
- **Fail-safe release, in layers**, as in note 09 §7: the probe releases
  the private assertion after the hold, on SIGINT, SIGTERM or SIGHUP, on a
  sleep notification, on a reading that ends the hold early, and in a
  `defer`; a failed release is retried; after a signal or a sleep
  notification, nothing is created. If the release fails on a sleep
  notification, the probe does not allow the sleep, records one line in
  the report file, and exits; a 2 s deadline armed before the write ends
  it even if the write hangs (§4), so that powerd frees the assertion with
  the process. The assertion carries a timeout of
  hold + 30 s with `TimeoutActionRelease`, and powerd releases every
  assertion of a process that exits. The idle-sleep assertion has its own
  timeout (the longest run plus 120 s) and is released after the private
  one, then the sleep notifications are deregistered.
- **If adapter power or charging does not come back** (verdict
  `discharging, did not resume` or `inhibited, did not resume`, a report
  that opens with "CHECK RECOVERY FIRST", or at any time):
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
  assertion; use any other assertion type; open a user client of the
  battery manager or the SMC (powerd may, as part of Apple's own handling;
  the one IOKit connection the probe makes is the root domain's, which
  `IORegisterForSystemPower` opens for sleep notifications); read or write
  SMC keys; change `pmset` settings; read the AlDente helper's files; read
  any process's memory; keep anything of the adapter details but presence
  and wattage.

## 8. Open questions

1. Does the macOS 27 battery driver implement the inflow-disable selector
   on Apple silicon? The published one does not (§3).
2. If it does, does an inflow cut keep reporting the adapter attached
   (`AppleRawExternalConnected`, the public adapter details), so that it
   can be told from an unplug? And does `SystemPowerIn` measure the
   adapter's input, as the cut criterion assumes?
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

The read-only `check`, run by the agent as an ordinary user on 2026-10-19
with the probe as built for this note, follows. Nothing was created. `run`
without `sudo` was also tried from an empty directory: it printed that it
must be started with `sudo`, exited 1, wrote no file, and
`pmset -g assertions` listed no `DisableInflow`, `ChargeInhibit` or
CellKeeper assertion afterwards. `run` without `--assertion` exits 64 with
the usage text.

```text
CellKeeper DisableInflow probe: check (read-only; creates nothing)
machine: Mac16,1, macOS 27.0.1 (26A434), system firmware mBoot-20457.1.29

Current reading
clock          time phase     AC   charging   charged     %  mA instant/avg   reg.charging  reg.ext  raw.ext  adapter  NotChargingReason  SysPowerIn mW  upd.age  state
22:38:02    +0.0 baseline  yes  no         no         80   0/0              no            yes      yes      68 W     0x1000000          15786          41 s     stopped

Preconditions
PASS  On AC power: IOPowerSources reports AC power (AppleSmartBattery ExternalConnected: yes)
PASS  Battery present: the internal battery is present
PASS  Charge below 95%: 80%
PASS  Charge at least 40%: 80%
FAIL  macOS is charging now: macOS isn't charging the battery now — raise macOS's Charge Limit to 100% (System Settings › Battery) and wait until it charges
PASS  Battery current readable: InstantAmperage 0 mA, Amperage 0 mA
PASS  Battery update time readable: AppleSmartBattery UpdateTime, 41 s old
PASS  System power input readable: PowerTelemetryData.SystemPowerIn 15786 mW
PASS  Adapter reported attached: AppleRawExternalConnected: yes; IOPSCopyExternalPowerAdapterDetails: an adapter
FAIL  macOS's Charge Limit is 100%: pmset -g battlimit reports 80%: set the Charge Limit to 100% (System Settings › Battery › ⓘ next to Charging)
PASS  No AlDente helper files: neither of its helper files exists
PASS  AlDente helper not loaded: launchctl print system/com.apphousekitchen.aldente-pro-setapp.helper: could not find service
PASS  No AlDente process running: no executable path or name in the process table matches AlDente
PASS  No other battery-control daemon: no file name in /Library/LaunchDaemons or /Library/PrivilegedHelperTools suggests one
PASS  No ChargeInhibit or DisableInflow assertion held: pmset -g assertions lists neither
WARN  Charge in the recommended 50–74%: 80%: if Optimized Battery Charging is on, macOS may pause charging near 80% by itself and confuse the result. Turn it off for the test (System Settings › Battery › ⓘ next to Charging), or start below 75%
WARN  Optimized Battery Charging off: the probe cannot read this setting: turn it off for the whole test (System Settings › Battery › ⓘ next to Charging), so that macOS does not pause charging by itself

NOT READY: 2 preconditions fail; `run` would refuse. Read the 2 warnings above.
```

`[VERIFIED-EXPERIMENTALLY]` (read-only): as in note 09 §9, the Mac was held
at 80% by macOS's native Charge Limit and not charging, so `check` reports
NOT READY; the owner sets the limit to 100% for the run (§6). The adapter
was reported attached by both reads, at 68 W, and the system drew about
16 W from it while not charging.

## 10. Results

Not run yet. The owner sends the report; the lead fills in:

| Field | Value |
|---|---|
| Date and time | |
| macOS build, firmware | |
| Assertion, hold | `DisableInflow`, … s (timeout … s, `TimeoutActionRelease`) |
| Sleep notifications registered; idle-sleep assertion IOReturn (creation / release) | |
| IOReturn of creation | |
| IOReturn of release (attempts) | |
| Listed by `pmset -g assertions` 2 s after creation / before / after the release | |
| Battery updates in the baseline / during the hold / after the release | |
| Effect, and when it began | |
| Adapter reported attached, and system power input, during the effect | |
| Adapter power back, and charging resumed, after the release | |
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
  assertion, sleep notifications, the inflow-cancelled message, the adapter
  details, and IOReturn names.
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
- **S6** — apple-oss-distributions/IOKitUser, `pwr_mgt.subproj/IOPMLib.c`,
  branch `main`:
  https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMLib.c
  (APSL-2.0). Supports: `IORegisterForSystemPower` opens a connection to
  `IOPMrootDomain`, and `IOAllowPowerChange` answers through it.
