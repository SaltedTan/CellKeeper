# 09 — The ChargeInhibit probe (owner-run, on the maintainer's Mac)

- **Date:** 2026-10-19
- **Status:** The probe is written and its logic is unit-tested. The owner's
  run is **pending**; the Results section is empty until then.
- **Machine:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (26A434),
  system firmware mBoot-20457.1.29. This is the maintainer's own Mac.
- **Tool:** [`Tools/charge-inhibit-probe/`](../../Tools/charge-inhibit-probe/),
  a standalone SwiftPM package. It is not part of the app, its Xcode project
  or CellKeeperKit, and nothing ships from it.
- **Tags and grades:** as in [note 02](02-charging-control-apple-silicon.md)
  (tag legend and grades A–E, X). Here, **B** is Apple open source and **A**
  the public macOS 27.0 SDK.

---

## 1. Purpose

Research note 02 §8 asks (open question 4): *do the private `ChargeInhibit` /
`DisableInflow` assertions affect charging on Apple silicon (macOS 26/27)?*
Note 02 §5 (inference 4) and §7 rank `ChargeInhibit` as the private
mechanism to evaluate first, because Apple's published power-management
source releases it when the owning process exits: a crashed client cannot
leave charging inhibited.

This probe answers the first half of that question for one Mac, one macOS
build and one firmware: does holding one `ChargeInhibit` assertion stop
charging on AC power, and does charging resume when it is released? It is
the first step of roadmap phase 4c. It does not test `DisableInflow`, sleep,
restart, or anything SMC-based.

## 2. The owner's decision (2026-10-19)

- **This Mac is the test Mac** for CellKeeper's own charge control (phase
  4c). Until now, private mechanisms were never to be tried on a daily-use
  Mac (`safety.md` precondition 1, roadmap phase 4c); the owner lifted that
  gate for this mechanism on this Mac.
- **Authorized: one experiment.** The owner runs the probe with `sudo`. It
  holds Apple's private `ChargeInhibit` power assertion for a bounded time
  and releases it. Agents never run `sudo` and never create an assertion;
  the probe refuses to create one unless it runs as root.
- **Not authorized:** SMC reads or writes, the SMC adapter cut (`CHIE`),
  `DisableInflow`, any other private assertion, and any change to the
  clean-room rule on third-party write encodings. Each needs a separate
  owner decision after this result.
- **AlDente Pro's helper** (installed through Setapp) is being removed by the
  owner before the test. The probe checks, by file existence only, that its
  two files are gone; it never reads them. The read-only check on
  2026-10-19 (§9) found neither file.

## 3. Mechanism and sources

| Item | What | Source | Tags / grade |
|---|---|---|---|
| Assertion type | The string `"ChargeInhibit"`: `kIOPMAssertionTypeInhibitCharging`, alias `kIOPMChargeInhibitAssertion`, with the comment "Disables battery charging (requires root to initiate)". It is not in the public SDK. | IOKitUser `pwr_mgt.subproj/IOPMLibPrivate.h`, lines 536–538 (S1) | `[PRIVATE/UNDOCUMENTED][IOKIT][PRIVILEGED]`, B |
| Creation | `IOPMAssertionCreateWithProperties(CFDictionaryRef, IOPMAssertionID *)`; "the caller must specify the type of assertion, initial level, and its properties" | `IOKit/pwr_mgt/IOPMLib.h`, lines 496–538 (S3) | `[PUBLIC-API][IOKIT]`, A |
| Release | `IOPMAssertionRelease(IOPMAssertionID)` | `IOPMLib.h`, lines 647–663 (S3) | `[PUBLIC-API]`, A |
| Properties | See the table below. | `IOPMLib.h` (S3) | `[PUBLIC-API]`, A |
| Synchronous creation | The client library sends the properties to powerd and returns powerd's IOReturn. Only `PreventUserIdleSystemSleep` and `NoIdleSleep` may be created asynchronously (`createAsyncAssertion`); `ChargeInhibit` is not one of them. | IOKitUser `pwr_mgt.subproj/IOPMAssertions.c`, lines 2304–2429 and 814–831 (S2) | B |
| Privilege | powerd refuses with `kIOReturnNotPrivileged` if `propertiesDictRequiresRoot` is true and the caller is neither root nor an administrator. **Caveat:** as published, `propertiesDictRequiresRoot` looks `"ChargeInhibit"` and `"DisableInflow"` up as *keys* of the properties dictionary, not as the value of `AssertType`; read literally, it would not fire for a dictionary built as the public header describes (see §8). The probe runs as root regardless. | PowerManagement `pmconfigd/PMAssertions.c`, lines 1127–1134 and 2523–2532 (S4) | B; shipping behaviour unknown |
| Effect | On the first active `ChargeInhibit` (and when the last one goes), powerd calls `sendSmartBatteryCommand(kSBUCChargeInhibit, 1 or 0)`. With a smart battery, **powerd** opens the `AppleSmartBatteryManager` user client and calls that selector; otherwise it sets `IsCharging` false on `IOPMPowerSource` entries. The probe itself opens no user client. | `PMAssertions.c`, lines 5353–5391 and 1694–1771 (S4) | B; whether Apple silicon builds implement it is unknown |
| Aggregation | powerd forwards only the transitions from none to one active assertion and back. An assertion another process already holds would hide the probe's. | `PMAssertions.c`, `handleBatteryAssertions`, lines 5353–5380 (S4) | B |
| Timeout | A `TimeoutSeconds` number makes the assertion timed; with `TimeoutActionRelease`, powerd releases it when the timeout fires. | `PMAssertions.c`, lines 5891–5904 and 4297–4305 (S4) | B |
| Release on exit | When a process exits, `HandleProcessExit` releases every assertion it owned and calls each type's handler, which lowers `ChargeInhibit` if no other holder remains. | `PMAssertions.c`, lines 4650–4689 (S4) | B |
| Visibility | `pmset -g assertions` lists `ChargeInhibit` in the system-wide summary only while its level is non-zero, and per process for its owner; `pmset -g batt` prints active `ChargeInhibit` assertions. | PowerManagement `pmset/pmset.m`, lines 1838–1910 and 2549–2568 (S4) | B |

The probe passes exactly these properties:

| Key (public constant) | Key string | Value |
|---|---|---|
| `kIOPMAssertionTypeKey` | `AssertType` | `"ChargeInhibit"` (S1; not in the SDK) |
| `kIOPMAssertionNameKey` | `AssertName` | `"CellKeeper charge-inhibit probe"` |
| `kIOPMAssertionDetailsKey` | `Details` | a sentence naming this note |
| `kIOPMAssertionLevelKey` | `AssertLevel` | `kIOPMAssertionLevelOn` (255) |
| `kIOPMAssertionTimeoutKey` | `TimeoutSeconds` | hold + 30 s (90 s for the default 60 s hold) |
| `kIOPMAssertionTimeoutActionKey` | `TimeoutAction` | `kIOPMAssertionTimeoutActionRelease` (`TimeoutActionRelease`): "Power Management will log the timeout event, and will release the assertion" |

Header line numbers for the keys (S3): `kIOPMAssertionLevelOn` 433,
`kIOPMAssertionTimeoutKey` 798, `kIOPMAssertionTimeoutActionKey` 813,
`kIOPMAssertionTimeoutActionRelease` 840, `kIOPMAssertionNameKey` 875,
`kIOPMAssertionDetailsKey` 900, `kIOPMAssertionTypeKey` 984,
`kIOPMAssertionLevelKey` 996.

**Clean room.** The type string comes from Apple's open source only; every
key, value and function from the public SDK. No binary was disassembled,
decompiled or string-dumped, and no other battery tool's code or
documentation was consulted for this note or the probe. `DisableInflow` is
named only because Apple's sources define it next to `ChargeInhibit`; the
probe never uses it.

## 4. Method

### What the probe reads (read-only)

| Value | Source | Used for |
|---|---|---|
| On AC power | IOPowerSources `IOPSGetProvidingPowerSourceType` (falls back to the battery's `Power Source State`) | verdict |
| Battery present, charge % | IOPowerSources internal battery: `Is Present`, `Current Capacity` / `Max Capacity` | verdict |
| Charging, charged | IOPowerSources `Is Charging`, `Is Charged` | verdict |
| Battery current | AppleSmartBattery `InstantAmperage` (undocumented), else `Amperage` (`kIOPMPSAmperageKey`, an average) | verdict |
| `IsCharging`, `ExternalConnected` | AppleSmartBattery registry | report only |
| `ChargerData.NotChargingReason` | AppleSmartBattery registry, undocumented bit field, not decoded | report only |
| `PowerTelemetryData.SystemPowerIn` | AppleSmartBattery registry, undocumented, mW by inference (note 01) | report only |
| Charge Limit | `pmset -g battlimit` (`[PRIVATE/UNDOCUMENTED]` getter, notes 02 and 08) | precondition |
| Assertions | `pmset -g assertions`; only lines that mention `ChargeInhibit` are kept | precondition, listing checks |
| Model, macOS, firmware | `sysctlbyname` (`hw.model`, `kern.osproductversion`, `kern.osversion`); `system-firmware-version` of `IODeviceTree:/chosen` | report header |

Registry values are read one key at a time with
`IORegistryEntryCreateCFProperty`; no user client is opened. Serial numbers,
which the battery's description and registry entry also carry, are never
read into a sample, and the report contains no user names or home paths
(the tests check this). Note 08 observed that `pmset` itself tries to open
the SMC user client as it starts; under `sudo` that attempt is pmset's own,
for its read-only getters, as when an administrator runs `pmset -g`.

### Sequence of `run`

1. Refuse unless the effective user is root (`geteuid() == 0`). This is the
   first statement of `run`; `AssertionHolder.create` checks it again and
   never calls powerd otherwise.
2. Re-check every precondition (§5); refuse on any failure.
3. Create the report file in the current directory; refuse if it cannot be
   written.
4. Install handlers for SIGINT, SIGTERM and SIGHUP.
5. **Baseline:** 11 readings, every 2 s for 20 s. Create nothing unless every
   reading shows steady charging on AC power.
6. **Hold:** create the assertion; record the IOReturn; read every 2 s for the
   hold (default 60 s, 30–300 s with `--hold`); check `pmset -g assertions`
   2 s after creation and just before the release. If a reading shows the
   Mac on battery, at 100%, or unreadable, release at once (the run is
   inconclusive).
7. **Release** with `IOPMAssertionRelease`; record the IOReturn; check
   `pmset -g assertions` again.
8. **After:** read every 2 s for 60 s. If charging has not resumed by then,
   keep reading for up to 120 s more, to tell a late resume from none.
9. Compute the verdict and write the report to standard output and to
   `charge-inhibit-probe-<timestamp>.txt`.

Times are on `CLOCK_MONOTONIC`, which keeps counting while the Mac sleeps
(clock_gettime(3)), so a sleep shows up as a gap; every reading also carries
the local wall-clock time, to match the report against the system log.

### The verdict (a pure function, `Verdict.evaluate`)

A reading is **charging** when the charging flag is on and the battery
current is above 50 mA, **stopped** when the flag is off and the current is
at most 50 mA, and **mixed** otherwise. Both are required because Apple's
published fallback path changes only the `IsCharging` flag; a flag alone
could be cosmetic.

| Verdict | When | Exit status |
|---|---|---|
| `inhibited` | Steady charging in the baseline; the assertion created; charging **stopped** within 30 s of creation and stayed stopped while held, on AC power; charging resumed within 60 s of the release. | 0 |
| `inhibited, resumed late` | As above, but charging resumed more than 60 s after the release. | 0 |
| `inhibited, did not resume` | Charging stopped as above and had not resumed after at least 60 s of readings after the release (normally 180 s). The report tells the owner to follow the recovery steps (§7). | 3 |
| `no effect` | The assertion was created and every reading while it was held showed charging. | 0 |
| `refused` | `IOPMAssertionCreateWithProperties` did not return `kIOReturnSuccess`. Nothing was held. | 0 |
| `inconclusive` | Anything that prevents a conclusion: the baseline was not steady charging or had fewer than 5 readings; a reading showed battery power, 100% or charged, or an unreadable value while it mattered; a gap of more than 10 s between readings (a sleep); a stop later than 30 s after creation; charging that restarted while the assertion was held; readings that never clearly stopped but disagreed; readings after the release that end before the 60 s window; a stop signal before the assertion. | 2 |

The function is pure and covered by unit tests over synthetic runs on the
probe's real schedule (`swift test --package-path Tools/charge-inhibit-probe`):
inhibited; no effect; refused; unplugged while held and after the release;
reached 100%; resumed late; resumed exactly at the window's end; never
resumed; late stop; restart while held; mixed readings; non-charging or short
baseline; unreadable values; a sleep gap; an assertion not released by the
probe; unordered samples. `charge-inhibit-probe` also builds with
`-warnings-as-errors`, and CI runs those tests on every matrix toolchain.

## 5. Preconditions

`check` prints these and exits 0 if none fails, 1 otherwise. `run` checks
them again and refuses on any failure. Warnings never stop a run.

| Check | Fails / warns when | Why |
|---|---|---|
| On AC power | **fails** on battery or unknown | The assertion inhibits charging; without AC there is nothing to inhibit. |
| Battery present | **fails** without a readable internal battery | |
| Charge below 95% | **fails** at 95% or more | Near full, charging tapers and stops by itself. |
| macOS is charging now | **fails** unless the charging flag is on and the current is above 50 mA. Not charging: "macOS isn't charging the battery now — raise macOS's Charge Limit to 100% (System Settings › Battery) and wait until it charges" | Without charging in progress, a stop cannot be observed. |
| Battery current readable | **fails** without `InstantAmperage` or `Amperage` | The verdict needs it. |
| macOS's Charge Limit is 100% | **fails** if `pmset -g battlimit` reports a limit below 100%; **warns** if it cannot be read | A native limit can stop charging by itself during the run; reports also say firmware owns the power path while the native limit is active (note 02 §3.10). |
| No AlDente helper | **fails** if `/Library/PrivilegedHelperTools/com.apphousekitchen.aldente-pro-setapp.helper` or `/Library/LaunchDaemons/com.apphousekitchen.aldente-pro-setapp.helper.plist` exists (existence only) | Another charge controller would confound the result. |
| No other battery-control daemon | **warns** if a file name in `/Library/LaunchDaemons` or `/Library/PrivilegedHelperTools` contains `aldente`, `apphousekitchen`, `batt`, `charg`, `bclm` or `smc` (names only) | A name says nothing certain, so it only warns. |
| No ChargeInhibit assertion held | **fails** if `pmset -g assertions` lists one; **warns** if pmset cannot be run | powerd forwards only the first raise (§3), so the probe's own assertion would change nothing. |
| Charge in the recommended 50–74% | **warns** at 75–94% (Optimized Battery Charging may pause near 80%) and below 50% (note 02 §7 recommends 50–75%, for margin) | |

## 6. Owner steps

1. Make sure AlDente is fully removed, then restart the Mac.
2. In Terminal, at the top of the repository, build the probe:

   ```sh
   swift build -c release --package-path Tools/charge-inhibit-probe
   cd Tools/charge-inhibit-probe
   ```

3. In **System Settings › Battery › ⓘ next to Charging**, set the **Charge
   Limit to 100%**. If the charge is 75% or more, also turn off Optimized
   Battery Charging for the test (or use the Mac on battery until it is
   between 50 and 74%).
4. Connect the Apple power adapter. Keep the lid open and the Mac on a hard
   surface, and stay with it. Wait until the battery menu shows it charging.
5. Check, without privileges:

   ```sh
   .build/release/charge-inhibit-probe check
   ```

   It must end with `READY`. Fix any `FAIL` line first; read any `WARN`.
6. Run the test:

   ```sh
   sudo .build/release/charge-inhibit-probe run
   ```

   It takes about 2½ minutes (20 s baseline, 60 s hold, 60 s after), up to
   4½ minutes if charging is slow to resume. Do not unplug the adapter, close
   the lid or let the Mac sleep. Ctrl-C at any time releases the assertion
   and ends the run with a report.
7. Send the file `Tools/charge-inhibit-probe/charge-inhibit-probe-<timestamp>.txt`
   to the lead. Git ignores these files.
8. Set the Charge Limit (and Optimized Battery Charging) back the way you
   want them.

## 7. Safety

- **What it changes.** One power assertion, held for the hold time (60 s by
  default, at most 300 s), in powerd's memory. No file other than the report,
  no setting, no `pmset` setting, no SMC key, no launchd job, nothing
  persistent. By its header comment, `ChargeInhibit` "disables battery
  charging"; it is not `DisableInflow`, so the Mac is expected to keep
  running from the adapter `[INFERRED/UNVERIFIED]`.
- **Fail-safe release, in layers.**
  1. The probe releases the assertion after the hold, on SIGINT, SIGTERM or
     SIGHUP (from the signal handler, at once), when a reading shows the run
     cannot conclude, and in a `defer` on every path out of `run`. A lock
     makes creation and release safe against the signal handler.
  2. The assertion carries a timeout of hold + 30 s with
     `TimeoutActionRelease`: powerd releases it if the probe stalls (B).
  3. powerd releases every assertion a process owns when the process exits,
     however it exits, including `kill -9` (B).

  Whether the shipping powerd on Apple silicon behaves like the published
  source is part of what the run shows: the report records whether
  `pmset -g assertions` still lists the assertion just after the release.
- **If charging does not resume** (verdict `inhibited, did not resume`, or at
  any time):
  1. Run `pmset -g assertions`. If it lists a `ChargeInhibit` and the probe
     is still running, press Ctrl-C (twice quits at once); powerd releases the
     assertion when the probe exits.
  2. Unplug the adapter, wait a few seconds, and plug it back in.
  3. Quit any battery tool (and CellKeeper, if it is running).
  4. Restart the Mac.
  5. Check macOS's own Charge Limit and Optimized Battery Charging (System
     Settings › Battery › ⓘ next to Charging); you set them for the test.

  These follow the general procedure in
  [`safety.md`, "If charging does not resume"](../safety.md#if-charging-does-not-resume).
  Whether a restart clears any state the assertion causes is not known
  beyond the published source, which keeps assertions in powerd's memory.
- **What the probe never does:** run as root unless the owner starts it
  with `sudo`; create more than one assertion; use `DisableInflow` or any
  other assertion type; open an IOUserClient (powerd may, as part of Apple's
  own handling); write SMC keys; change `pmset` settings; read the AlDente
  helper's files.

## 8. Open questions

1. Does the shipping powerd on Apple silicon require root for
   `ChargeInhibit`? The published `propertiesDictRequiresRoot` checks for
   keys named after the types, not for the `AssertType` value, so as
   published it would not demand root for a dictionary like the probe's.
   This is not tested: the probe never creates an assertion without root,
   and the owner authorized only the root run.
2. Does the Apple-silicon battery driver implement the charge-inhibit
   selector, or does only the `IsCharging` flag change? The verdict's
   current threshold separates the two.
3. Sleep, wake, restart, unplug and replug while held (the persistence
   matrix of note 02 §7, Phase D) are out of scope for this probe.
4. Does the assertion timeout count while the Mac sleeps?

## 9. Pre-run state: read-only `check` on 2026-10-19

Run by the agent as an ordinary user (uid 501), before the owner prepared
the Mac. Nothing was created. `run` without `sudo` was also tried, to
confirm it refuses: it printed that it must be started with `sudo`, exited 1,
wrote no report, and `pmset -g assertions` listed no `ChargeInhibit`
afterwards.

```text
CellKeeper ChargeInhibit probe: check (read-only; creates nothing)
machine: Mac16,1, macOS 27.0.1 (26A434), system firmware mBoot-20457.1.29

Current reading
clock          time phase     AC   charging   charged     %  mA instant/avg   reg.charging  reg.ext  NotChargingReason  SysPowerIn mW  state
12:45:45    +0.0 baseline  yes  no         no         80   0/0              no            yes      0x1000000          16117          stopped

Preconditions
PASS  On AC power: IOPowerSources reports AC power (AppleSmartBattery ExternalConnected: yes)
PASS  Battery present: the internal battery is present
PASS  Charge below 95%: 80%
FAIL  macOS is charging now: macOS isn't charging the battery now — raise macOS's Charge Limit to 100% (System Settings › Battery) and wait until it charges
PASS  Battery current readable: InstantAmperage 0 mA, Amperage 0 mA
FAIL  macOS's Charge Limit is 100%: pmset -g battlimit reports 80%: set the Charge Limit to 100% (System Settings › Battery › ⓘ next to Charging)
PASS  No AlDente helper: neither of its helper files exists
PASS  No other battery-control daemon: no file name in /Library/LaunchDaemons or /Library/PrivilegedHelperTools suggests one
PASS  No ChargeInhibit assertion held: pmset -g assertions lists none
WARN  Charge in the recommended 50–74%: 80%: if Optimized Battery Charging is on, macOS may pause charging near 80% by itself and confuse the result. Turn it off for the test (System Settings › Battery › ⓘ next to Charging), or start below 75%

NOT READY: 2 preconditions fail; `run` would refuse. Read the warning above.
```

`[VERIFIED-EXPERIMENTALLY]` (read-only): the Mac was held at 80% by macOS's
native Charge Limit, as in notes 02 and 08, and the AlDente helper's two
files were absent.

## 10. Results

*To be filled in from the owner's report after the run.*

| Field | Value |
|---|---|
| Date and time | |
| macOS build, firmware | |
| Hold | |
| IOReturn of creation | |
| Listed by `pmset -g assertions` 2 s after creation / before / after the release | |
| Charging stopped after | |
| Charging resumed after the release | |
| Verdict | |
| Notes | |

Interpretation, and what it means for phase 4c: *pending.*

## 11. Sources

All fetched on 2026-10-19 unless stated otherwise.

- **S1** — apple-oss-distributions/IOKitUser, `pwr_mgt.subproj/IOPMLibPrivate.h`,
  branch `main` (byte-identical to commit 323ead8, cited in note 02 as S10):
  https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMLibPrivate.h
  (APSL-2.0). Supports: the `ChargeInhibit` type string and its comment.
- **S2** — apple-oss-distributions/IOKitUser, `pwr_mgt.subproj/IOPMAssertions.c`,
  branch `main`:
  https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMAssertions.c
  (APSL-2.0). Supports: synchronous creation for `ChargeInhibit`.
- **S3** — macOS 27.0 SDK (Xcode 27.0), `IOKit/pwr_mgt/IOPMLib.h` and
  `IOKit/IOReturn.h`, read locally. Supports: the creation and release
  functions, every property key and value except the type, and IOReturn
  names.
- **S4** — apple-oss-distributions/PowerManagement, tag
  PowerManagement-1846.0.25.0.1 (note 02's S11), files
  `pmconfigd/PMAssertions.c` and `pmset/pmset.m`:
  https://raw.githubusercontent.com/apple-oss-distributions/PowerManagement/PowerManagement-1846.0.25.0.1/pmconfigd/PMAssertions.c
  and
  https://raw.githubusercontent.com/apple-oss-distributions/PowerManagement/PowerManagement-1846.0.25.0.1/pmset/pmset.m
  (APSL-2.0). Supports: the privilege check, the forwarding to the battery
  manager, aggregation, timeout release, release on process exit, and what
  `pmset` prints.
- **S5** — local `clock_gettime(3)`. Supports: `CLOCK_MONOTONIC` keeps
  counting while the system is asleep.
