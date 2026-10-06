# 02 — Charging-control mechanisms on Apple Silicon Macs

- **Date:** 2026-10-06
- **Machine used for read-only checks:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (build 26A434), System Firmware / OS Loader 20457.1.29, Xcode 27.0 with the MacOSX27.0 SDK.
- **Method:** Documentary research only.
  - No IOUserClient was opened. No SMC key was read or written. No SMC tool was run. No `sudo` was used, and no `pmset` or other system setting was changed.
  - No proprietary binary was inspected.
  - The only local commands were read-only `pmset -g …`, `ioreg`, `system_profiler`, man pages, and `grep` over public SDK headers and Apple open-source files.
- **Confound:** A third-party battery manager's privileged helper is installed on this machine. Its files were not inspected. The "AC attached; not charging at 80%" state seen here **cannot be attributed** to macOS, to that helper, or to both.
- **Companion note:** `01-battery-telemetry.md` covers read-only telemetry in detail. This note covers **control**.

---

## Summary

1. **Apple now ships a native, documented charge limit, and it is the only supported control.**
   - **What it is:** "Charge Limit" (System Settings → Battery → ⓘ next to Charging) sets a cap of 80–100% in 5% steps. It requires **macOS Tahoe 26.4 or later and a Mac with Apple silicon** (Apple 102338).
   - **Behaviour per Apple:** the Mac charges to "within a few percentage points" of the limit and then stops. It resumes if charge drops more than 5% while on power, and it "occasionally" charges to 100% for state-of-charge calibration.
   - **Shortcuts:** macOS 26.4 also added a Shortcuts action, "Set Battery Charge Limit" (press reports; no Apple reference page fetched).
2. **No public API exists to set, inhibit or bypass charging.**
   - The macOS 27.0 SDK has no charge-limit, charge-inhibit or adapter-disable API (header search, verified).
   - `pmset(1)` documents no charge-control setting.
   - The only **public, indirect** route is for the user to build a Shortcut containing "Set Battery Charge Limit". The app then runs that shortcut via the documented `shortcuts run` CLI. Limits: 80–100% only, and the user must create the shortcut. This flow is `[INFERRED/UNVERIFIED]` end to end.
3. **The current native-limit state is readable without privilege, but only via an undocumented `pmset -g battlimit` getter.**
   - Verified read-only on this machine.
   - It returns "Battery level limits" entries with fields such as `chargeSocLimitSoc = 80` and `chargeSocLimitReason = manualChargeLimit`.
   - It is not in `pmset(1)` and not in the open-source pmset (PowerManagement-1846.0.25.0.1). Treat it as `[PRIVATE/UNDOCUMENTED]`.
4. **Third-party SMC mechanisms have been progressively closed off, which is the dominant fact for CellKeeper.**
   - **History (community reports):**
     - CHWA/BCLM-style limits disappeared with macOS 15.
     - Charge-inhibit keys (`CH0B`/`CH0C`, later `CHTE`) and force-discharge keys (`CH0I`, …) worked through macOS 26.6.
     - macOS 27 beta 1–3 firmware briefly exposed firmware-managed limit keys (`bfF0`/`bfD0`/`bfE0`).
   - **Current state (macOS 27 beta 4+ firmware 20457.x, also shipped in the macOS 15.8 / 26.7 security updates):**
     - The legacy inhibit keys are zero-size or absent.
     - The `bf*` keys return `kIOReturnNotPrivileged` **even to root**.
     - The reporter attributes this to a private entitlement (`com.apple.private.iokit.soc-limit`).
   - All of this is `[PRIVATE/UNDOCUMENTED][SMC/HW]` and unverified.
5. **The only SMC control still reported to work on macOS 27 is the adapter cut (`CHIE`).**
   - It runs the Mac from battery while plugged in, as root.
   - It is a crude, high-risk mechanism: it micro-cycles the battery and drains it if left set. Reports also say firmware ignores it while the native Charge Limit is active.
6. **This dev machine is on the gated firmware.** Firmware 20457.1.29 on macOS 27.0.1 is exactly the combination reported as gated. Under the community reports, no SMC-key charge-inhibit or firmware-limit backend is available here; only the native limit and, reportedly, `CHIE` remain.
7. **Privilege by mechanism:**
   - SMC writes always required root, and newer keys reportedly need a private entitlement that third parties cannot obtain.
   - The native limit is user-settable through System Settings or Shortcuts.
   - Apple open source also defines private `ChargeInhibit` / `DisableInflow` power assertions that "require root". powerd releases them when the owning process exits, which is a useful fail-safe property, but their effect on Apple silicon is unknown.
8. **Sleep and shutdown:**
   - Apple documents nothing about limit behaviour during sleep or shutdown.
   - Community reports say software-loop limiters overshoot during sleep unless charging is disabled before sleep. Firmware-managed limits (native, or the `bf*` keys) are claimed to hold during sleep.
   - Several Apple Community users report the **native** limit is ignored while the Mac is **shut down** (it charges to 100%).
9. **Recommendation input for the lead:**
   - Treat the native Charge Limit as the primary control backend, set via user-owned Shortcuts.
   - Treat everything SMC-based as experimental, opt-in, and gated by the verification protocol in this note.
   - Do not build on the `bf*` keys, entitlement-gated paths, or private PowerUI classes.

---

## Tag legend

| Tag | Meaning |
|---|---|
| `[PUBLIC-API]` | Documented by Apple: a public SDK header, developer documentation, man page, Apple Support article, or user-facing setting. |
| `[PRIVATE/UNDOCUMENTED]` | Not documented for third parties. This includes private headers in Apple open source, undocumented CLI subcommands and undocumented registry keys or SMC keys. |
| `[IOKIT]` | Reached through IOKit (IORegistry, IOPS, IOPM assertions, user clients). |
| `[SMC/HW]` | Implemented by the System Management Controller or charger hardware/firmware. |
| `[PRIVILEGED]` | Needs root, admin privilege, or a private entitlement. |
| `[ARCH-SPECIFIC: AS]` / `[ARCH-SPECIFIC: Intel]` | Applies only to Apple silicon or only to Intel. |
| `[VERIFIED-EXPERIMENTALLY]` | Observed by this research on this machine, using **read-only** commands only. |
| `[INFERRED/UNVERIFIED]` | Reasoned from sources or third-party claims. Not observed here. |

**Evidence-quality grades used in the table**

| Grade | Meaning |
|---|---|
| **A** | Apple documentation: Apple Support, developer docs, WWDC, the public SDK, or a man page. |
| **B** | Apple open source (APSL-2.0). Authoritative about what the published code does, but it may not match shipping Apple-silicon builds. |
| **C** | Reviewed open-source kernel work (Linux / Asahi `macsmc` drivers). Reverse-engineered, but code-reviewed and multi-device. |
| **D** | Community tool documentation corroborated by several independent reports. |
| **E** | A single report, forum anecdote, unmerged PR, or PR declared as AI co-authored. |
| **X** | Read-only observation on this machine. |

---

## Mechanism table

Source IDs refer to the **Sources** section.

| # | Mechanism | Purpose | Tags | Privilege | Persistence | Reported OS/firmware range | Evidence quality | Sources |
|---|---|---|---|---|---|---|---|---|
| 1 | **Charge Limit** (System Settings → Battery → ⓘ Charging) | Cap the charge at 80/85/90/95/100% | `[PUBLIC-API]` (user setting) `[ARCH-SPECIFIC: AS]` | Interactive user | **Setting:** a stored user setting. A temporary 100% override reportedly reverts the next morning (~6 AM). **Shutdown:** users report it is not enforced. **Sleep:** reports conflict. | macOS 26.4+ on Apple silicon | A (feature), E (sleep/shutdown) | S1, S13, S14, S35, S36, S36b |
| 2 | **Shortcuts "Set Battery Charge Limit"** + `shortcuts run` CLI | Script the native limit from an app via a user-owned shortcut | `[PUBLIC-API]` (CLI is documented; action name from press) `[INFERRED/UNVERIFIED]` (app-driven flow) | User. The shortcut must exist in the user's library. | Same as #1 | macOS 26.4+ (action) | A (CLI), D (action) | S7, S13, S14, S35 |
| 3 | **Optimized Battery Charging (OBC)** | ML-based hold at 80% until the predicted unplug time | `[PUBLIC-API]` (user setting) | Interactive user. No API. | A user setting. "Turn off until tomorrow" is available. | macOS 11+ | A | S1, S5 |
| 4 | **"Charge to Full Now"** (battery menu) | One-off override of OBC or Charge Limit | `[PUBLIC-API]` (UI only) | Interactive user | One-off | macOS 11+ / 26.4+ | A | S1, S5 |
| 5 | **Public telemetry:** IOPowerSources keys (`Is Charging`, `Is Charged`, `Is Finishing Charge`, `Power Source State`); IOPMPowerSource registry keys (`ExternalConnected`, `ExternalChargeCapable`, `IsCharging`, `ChargeStatus`) | **Observe** charging state. No control. | `[PUBLIC-API][IOKIT]` | None (read) | n/a | All | A, X | S8, 01-battery-telemetry.md |
| 6 | **`pmset -g battlimit`** | **Read** native limit state (`chargeSocLimitSoc`, `…Reason`, `…Drain`, `…IsEOC`, `…NoChargeToFull`, `…Owner`, `Terminated`) | `[PRIVATE/UNDOCUMENTED][VERIFIED-EXPERIMENTALLY]` (read) | None (read) | Reflects the live setting | Seen on macOS 27.0.1. Not in `pmset(1)` or OSS pmset 1846. | X; E (meaning of fields) | S9, S11, S19, S27 |
| 7 | **Undocumented AppleSmartBattery properties** (`ChargerData.NotChargingReason`, `PowerTelemetryData.SystemPowerIn`, `BatteryPower`, `InstantAmperage`) | Independent observation channel for verifying any control | `[PRIVATE/UNDOCUMENTED][IOKIT][VERIFIED-EXPERIMENTALLY]` (read) | None (read) | n/a | Seen on macOS 27.0.1 | X | 01-battery-telemetry.md |
| 8 | **Private PowerUI client** (PowerUIAgent's `PowerUISmartChargeClient`, reached via JXA/`osascript`) | Set the native limit programmatically | `[PRIVATE/UNDOCUMENTED][ARCH-SPECIFIC: AS]` | Claimed **no root** | Same as #1 | macOS 26.4+/27. Absent on 15.8 (`isMCLSupported: false`). | E (one open PR, AI co-authored) | S27 |
| 9 | **Root-owned defaults domain** `com.apple.smartcharging.topoffprotection` (`MCLFeatureState`, `mclLimitValue`) | Claimed to allow limits below 80% | `[PRIVATE/UNDOCUMENTED][PRIVILEGED]` | Root | Unknown | macOS 27 (claimed) | E (described, deliberately not implemented) | S27 |
| 10 | **Private IOPM assertions** `ChargeInhibit` / `DisableInflow` | Inhibit charging / disable AC inflow | `[PRIVATE/UNDOCUMENTED][IOKIT][PRIVILEGED]` | Root ("requires root to initiate"); admin check in the user client | **Released automatically when the owning process exits** (powerd OSS) | Defined in current IOKitUser. Effect on AS unknown. | B (existence, privilege, release-on-exit); unknown effect | S10, S11 |
| 11 | **SMC `CH0B` / `CH0C`** | Inhibit charging (legacy) | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: AS]` | Root (write) | SMC runtime state. Software must re-apply after wake/reboot. Reset after hibernation (claim). | Older AS firmware up to Tahoe-era. **Zero-size or "no data" on 20457.x.** | C, D | S16, S18, S19, S22–S27 |
| 12 | **SMC `CHTE`** (4 bytes) | Inhibit charging ("modern firmware") | same as #11 | Root (write) | As #11 | Sequoia/Tahoe-era firmware. **Gone on 20457.x / macOS 27.** | C, D | S16, S17, S18, S25, S26 |
| 13 | **SMC `CH0I` / `CH0J` / `CH0K`** | Force discharge / adapter disable (older firmware). Linux treats `CH0K`/`CH0B` as OBC flags. | same as #11 | Root (write) | As #11 | Older firmware. **"No data" or e00002c1 on 20457.x.** | C, D | S16, S17, S24–S27 |
| 14 | **SMC `CHIE`** | Cut adapter input (run from battery while plugged in) | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: AS]` | Root (write) | Only while set by a running daemon. Unplug/reboot behaviour unknown. | Tahoe-era → macOS 27.0 (claimed still writable on 20457.1.29). Ignored while native limit active. | D/E | S18, S19, S24–S27 |
| 15 | **SMC `CHWA`** | Fixed 80% limit flag | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: AS]` | Root (write) | SMC state, re-applied by daemon | Older AS firmware. **`keyNotFound` from macOS 15.0 beta 5.** | C, D | S16, S20, S21 |
| 16 | **SMC `BCLM` on AS** | Charge-level max (80 or 100 only on AS) | same as #15 | Root (write); read unprivileged | SMC state. A launch daemon re-applies it. Cleared by SMC reset. | AS "firmware ≥ 13.0". Not working on macOS 15+. | D | S20 |
| 17 | **SMC `CHLS`** | Percentage end-threshold with a force-discharge bit ("newer SMC firmware") | `[PRIVATE/UNDOCUMENTED][SMC/HW][ARCH-SPECIFIC: AS]` | n/a (Linux driver; under macOS unknown) | Unknown | Documented only from Linux macsmc-power v2. Status under macOS unknown. | C | S16 |
| 18 | **SMC `bfF0` / `bfD0` / `bfE0`** | Firmware-managed upper/lower limit; firmware holds it in sleep | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: AS]` | Root, **and now reportedly a private entitlement** (`com.apple.private.iokit.soc-limit`) | Claimed to hold across sleep and across processes | Worked in macOS 27 beta 1–3 firmware. **Gated from 20457.0.125+** (also 15.8/26.7 updates). One conflicting report says it works on 15.8 + 20457.1.29 (M3). | D/E | S18, S19, S23, S24, S27, S28 |
| 19 | **SMC `ACLC`** | MagSafe LED override (cosmetic, but useful as a UI hint) | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED]` | Root (write) | Unknown | Loss of control reported on 26.7 / firmware mode | D/E | S18, S22, S24 |
| 20 | **AppleSmartBattery registry property writes** (`SetChargingEnabled`, `SetPowerMode`, `SetChargeLimitEnabled`, `ExternalChargeCapable`) | Driver-level charge control | `[PRIVATE/UNDOCUMENTED][IOKIT][PRIVILEGED]` | Reportedly `kIOReturnNotPrivileged` on macOS 27 b8 | Unknown | Gated on macOS 27 | E | S19 |
| 21 | **Sleep mitigations:** `IORegisterForSystemPower` (`kIOMessageCanSystemSleep` / `kIOMessageSystemWillSleep`), `kIOPMAssertionTypePreventUserIdleSystemSleep` | Disable charging before sleep / veto idle sleep while charging | `[PUBLIC-API][IOKIT]` | None | Per process. Lid-close and manual sleep cannot be blocked by the idle assertion. | All | A | S8 |
| 22 | **`pmset disablesleep 1`** (used by one tool to keep a lid-closed Mac awake with the adapter cut) | Prevent all sleep | `[PRIVATE/UNDOCUMENTED][PRIVILEGED]` (not in `pmset(1)`) | Root | Persists until reverted. Can be left stuck. | n/a | D | S18 |

---

## 1. Documented by Apple

### 1.1 Optimized Battery Charging (OBC) — `[PUBLIC-API]` (user setting only)

- **Requirements:** "Requires macOS Big Sur 11 or later" (S1). The current article states no architecture restriction.
- **Behaviour:**
  - It uses "on-device machine learning to learn your daily charging routine". It can "delay charging past 80% in certain situations", such as when it predicts long periods on power.
  - The battery menu shows **"Charging On Hold"**, and **"Charge to Full Now"** overrides it (S1, S5).
- **Disabling:** the user can turn it off, optionally "only until tomorrow" (S1).
- **No API:** no public API toggles it or reports whether a hold is active (S8; see 01-battery-telemetry.md §H).

### 1.2 Charge Limit (macOS Tahoe 26.4+) — `[PUBLIC-API]` (user setting) `[ARCH-SPECIFIC: AS]`

Apple (S1, published 2026-04-06):
- **Requirements:** "Requires macOS Tahoe 26.4 or later and a Mac with Apple silicon."
- **Range:** the user chooses "a Charge Limit setting between 80% and 100%". The press confirms 5% steps (S13, S35).
- **Charging behaviour:**
  - The Mac charges "to within a few percentage points of the charge limit, then stop[s] charging".
  - The menu shows **"Charged to [%] Limit"**.
  - Charging restarts if charge "drops more than 5% while connected to power".
- **Calibration:** under either feature the Mac "will occasionally charge to 100% to maintain accurate battery state-of-charge estimates".
- **Not covered:** Apple does **not** document behaviour while asleep or shut down, behaviour above the limit (stop vs. drain), or programmatic access.

Press and user reports (grade D/E):
- A temporary 100% override reportedly reverts the next morning: "it will turn it back on at 6 AM" (S14, Michael Tsai).
- One blogger reports that if the battery is already above the limit, "it will gradually drop down to it" (S36).
- macOS 26.4 also added a "Slow Charger" indicator (S13). It is not a control.

### 1.3 Shortcuts and the `shortcuts` CLI — `[PUBLIC-API]`

- **The action:** 9to5Mac reports that macOS 26.4 added a Shortcuts action, **"Set Battery Charge Limit"**. It works in single-action shortcuts, multi-step shortcuts, and in Automations such as time-of-day triggers (S13, S35). I did not find an Apple reference page for the action itself.
- **The CLI:** Apple documents the `shortcuts` command-line tool (S7; local `shortcuts(1)`).
  - `shortcuts run <name>` runs a user's shortcut and "will exit 0 on a successful run or 1 on error".
  - `shortcuts list` confirms that a shortcut exists.
  - Apple says the command line is preferred over x-callback URLs.
- **Implication `[INFERRED/UNVERIFIED]`:** CellKeeper can drive the native limit **without private API or root**:
  1. The user creates or imports a shortcut, e.g. "CellKeeper Set Limit", that wraps "Set Battery Charge Limit" and takes a number as input.
  2. CellKeeper invokes it with `shortcuts run`.
- **Open details to verify:**
  - Whether the action accepts a variable or input value.
  - Whether it offers an "until tomorrow" option on the Mac.
  - Whether a sandboxed app may spawn `/usr/bin/shortcuts`; the alternatives are the URL scheme or Shortcuts Events scripting.
  - Whether any Shortcuts action can **read** the current limit.

### 1.4 Status strings and "Not Charging" — `[PUBLIC-API]` (documentation of UI)

- **"Not Charging" while connected (S4):** a Mac notebook can show this when:
  - (a) battery health management "temporarily paused charging". The article says the battery "may drain to 90% or lower before it begins charging again".
  - (b) the power source is too weak.
  - (c) the Mac draws more than the adapter supplies.
- **MagSafe LED (S5):** "Amber when charging is underway or charging is on hold", "Green when your battery is fully charged".
- **Implication `[INFERRED/UNVERIFIED]`:** a third-party inhibit is indistinguishable in the UI from (a)–(c). macOS shows the generic "Not Charging", not "Charged to [%] Limit". The native feature shows its own string.

### 1.5 `pmset` — `[PUBLIC-API]`

- **Settings:** the local `pmset(1)` (dated 2012 in the page footer) lists displaysleep, disksleep, sleep, womp, ring, powernap, proximitywake, autorestart, lidwake, acwake, lessbright, halfdim, sms, hibernatemode, hibernatefile, ttyskeepawake, networkoversleep and destroyfvkeyonstandby. None of them is a charge-control setting.
- **Getters:** it documents `-g batt`, `-g ps`, `-g rawlog`, `-g assertions`, `-g ac`/`adapter`, and others. It says "pmset must be run as root in order to modify any settings".
- **Capabilities:** `pmset -g cap` on this Mac lists no charge-control capability `[VERIFIED-EXPERIMENTALLY]`.
- **Undocumented subcommands:** `battlimit` (see §2) and `disablesleep` (used by a third-party tool, S18) are absent from the man page.

### 1.6 Public SDK — `[PUBLIC-API][IOKIT]`

- **Header search:** a search of the macOS 27.0 SDK headers and `.swiftinterface` files for `chargelimit|charge_limit|batterycharge|optimizedbatterycharging|smartcharg` found **only false positives**: DockKit accessory battery state and `kIOPMPSBatteryChargeStatusKey`. No charge-control API exists `[VERIFIED-EXPERIMENTALLY]` (static header search).
- **Telemetry:** public telemetry is read-only (S8):
  - IOPowerSources: `Is Charging`, `Is Charged`, `Is Finishing Charge`, etc. Note the header's definition: "a battery with capacity >= 95% and not charging, is defined as charged".
  - IOPMPowerSource registry keys: `ExternalConnected`, `ExternalChargeCapable`, `IsCharging`, `ChargeStatus` (values `HighTemperature`, `LowTemperature`, `HighOrLowTemperature`, `BatteryTemperatureGradient`).
  - Details are in 01-battery-telemetry.md.
- **Inflow-disable message:** public `IOPM.h` documents `kIOPMMessageInflowDisableCancelled`: "If a user process has disabled battery inflow for battery calibration, we forcibly re-enable Inflow at this point" (when the battery is fully discharged). This is the only public trace of an inflow-disable facility. It shows Apple anticipated a "user process disabled inflow" state and built a hardware-protective auto-cancel. The API to create that state is private (§1.7).
- **Sleep and wake APIs** (S8; for mitigations):
  - `IORegisterForSystemPower` delivers `kIOMessageCanSystemSleep`, which can be vetoed for **idle** sleep only.
  - It also delivers `kIOMessageSystemWillSleep`, which must be acknowledged; the system proceeds after a 30 s timeout.
  - It "Does not provide system shutdown and restart notifications."
  - `kIOPMAssertPreventUserIdleSystemSleep` prevents idle sleep only: "The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons." IOKit assertions "are suggestions and OS X may not honor them under battery, thermal, or user circumstances."

### 1.7 Apple open source (APSL-2.0) — `[PRIVATE/UNDOCUMENTED][IOKIT][PRIVILEGED]`

- **IOKitUser `pwr_mgt.subproj/IOPMLibPrivate.h`** (apple-oss-distributions/IOKitUser HEAD `323ead8`) defines two private assertion types (S10):
  - `DisableInflow` with the comment "Disables AC Power Inflow (requires root to initiate)".
  - `ChargeInhibit` with the comment "Disables battery charging (requires root to initiate)".
- **PowerManagement-1846.0.25.0.1** (S11):
  - **Root check:** pmconfigd treats either assertion as requiring root (`propertiesDictRequiresRoot`).
  - **Forwarding:** on raise and release, pmconfigd forwards to the `AppleSmartBatteryManager` user client (`kSBUCChargeInhibit` / `kSBUCInflowDisable`). A non-smart-battery build path instead sets `IsCharging` / `ExternalConnected` to false on `IOPMPowerSource` services.
  - **Admin check:** the open-source `AppleSmartBatteryManagerUserClient` checks `kIOClientPrivilegeAdministrator` before calling `inhibitCharging()` / `disableInflow()`.
  - **Release on exit:** when a process dies, pmconfigd's `HandleProcessExit` **releases every assertion owned by that PID**. This fail-safe matters for design: a crashed client cannot leave this inhibit stuck.
  - **pmset output:** in the published source, `pmset -g batt` / `-g ps` prints any active `DisableInflow` / `ChargeInhibit` assertions.
- **On this Mac (read-only checks):**
  - The registry contains `AppleSmartBatteryManager → AppleSmartBattery` under an SMC interface node `[VERIFIED-EXPERIMENTALLY]`.
  - The system-wide assertion summary shows no `ChargeInhibit` / `DisableInflow` active `[VERIFIED-EXPERIMENTALLY]`.
- **Caveat:** whether the shipping Apple-silicon battery driver implements these selectors, and whether the assertions change charging on M-series Macs, is **unknown** `[INFERRED/UNVERIFIED]`. Apple's open-source charge-control files are published empty (01-battery-telemetry.md §H).

### 1.8 SMC — `[SMC/HW]`

- **Scope:** Apple says the SMC is "responsible for managing power", including "Battery and charging" and "Status indicators, such as sleep and battery lights" (S3).
- **Reset on Apple silicon:** "SMC resets automatically on Mac with Apple silicon." There is no manual reset procedure; a restart, or shutting down and powering on, is the equivalent (S3).
- **Implication `[INFERRED/UNVERIFIED]`:** any SMC runtime state that a third-party tool writes must be assumed lost on restart or shutdown.
- **No interface for third parties:** Apple documents no SMC key interface for third parties.

### 1.9 Answer to Q1

- **Is there a public way to set a limit?** Yes, but only the native **Charge Limit** (80–100%, Apple silicon, macOS 26.4+) and **OBC**, both as user settings.
  - An app can **change** the Charge Limit only indirectly, by running a user-owned Shortcut built on the "Set Battery Charge Limit" action.
  - An app can **read** it only via the undocumented `pmset -g battlimit`, or heuristically from public IOPS state (on AC, not charging, at ~limit%).
- **Is there a public way to inhibit charging or force adapter-off running?** No. Apple provides no public API, setting, `pmset` option or documented App Intent for "inhibit charging now" or "run from the adapter / force discharge".
- **Does Apple document the 80% hold?** Only as the OBC/Charge Limit behaviour quoted above.

---

## 2. Read-only observations on this machine — `[VERIFIED-EXPERIMENTALLY]`

All observations are confounded by the installed third-party helper.

| Observation | Command | Result |
|---|---|---|
| Firmware | `system_profiler SPHardwareDataType` | System Firmware 20457.1.29, OS Loader 20457.1.29. This is the firmware family reported as **charge-keys-gated** (S19, S24). |
| Battery state | `pmset -g batt` | "80%; AC attached; not charging" |
| Native limit state | `pmset -g battlimit` (no privilege) | Prints "Battery level limits". One entry has `Terminated = 0`, `chargeSocLimitReason = manualChargeLimit`, `chargeSocLimitSoc = 80`, `chargeSocLimitDrain = 1`, `chargeSocLimitIsEOC = 1`, `chargeSocLimitNoChargeToFull = 0`, `chargeSocLimitOwner = 0`. A second entry for a terminated owner PID has the same values. |
| Man page | `man pmset` | No `battlimit`, no charge-control settings |
| OSS pmset | grep of PowerManagement-1846 `pmset.m` | No `battlimit` or `socLimit` strings. The subcommand is newer than, or omitted from, the published source. |
| Capabilities | `pmset -g cap` | No charge-control capability listed |
| Hibernate mode | `pmset -g` | `hibernatemode 3` (the default for notebooks). This is relevant to the reset-after-hibernation claim below. |
| Registry | `ioreg -rn AppleSmartBattery` | `ExternalConnected = Yes`, `ExternalChargeCapable = Yes`, `IsCharging = No`, `ChargerData.NotChargingReason` non-zero (undocumented bitfield; not decoded), `ChargerData.SlowChargingReason = 0`. `PowerTelemetryData` carries `SystemPowerIn`, `BatteryPower`, `SystemLoad` and others. |
| Assertions | `pmset -g assertions` (system-wide summary only) | No `ChargeInhibit` / `DisableInflow` active |

**Interpretation `[INFERRED/UNVERIFIED]`:**
- An active `manualChargeLimit` at 80% suggests the native Charge Limit is set to 80%. It may have been set by the user or by the third-party helper through a native path; this cannot be told apart.
- The field name `chargeSocLimitDrain = 1` is consistent with third-party reports that the native limit **drains** a battery that is above the limit, rather than merely stopping charging (S27, S36). Field semantics are undocumented.

---

## 3. Third-party claims (unverified)

Everything in this section is **third-party claim — unverified**.
- No code was copied, and no implementation is reproduced; only key names and reported behaviour are recorded.
- Licences: charlie0129/batt **GPL-2.0**; actuallymentor/battery **MIT**; Ednk-1312/BatteryControl **MIT**; zackelia/bclm **MIT**; Linux macsmc drivers **GPL-2.0-only OR MIT**.
- Several actuallymentor/battery PRs declare an AI co-author. That lowers evidence weight (grade E).

### 3.1 SMC primer (Linux kernel description, grade C)

The Apple silicon SMC (S29):
- **What it is:** a coprocessor reached over an RTKit mailbox.
- **Interface:** a key-value store. Keys are FourCC codes with metadata for size, a type code (`flag`, `ui8/16/32`, `hex`, `flt`, `ioft`, `ch8*`) and readable/writable/function flags.
- **Payloads:** values of 4 bytes or less return inline; larger values go via shared SRAM.
- **Notifications:** the SMC can send asynchronous notifications.

**Implication for CellKeeper:** every key has a discoverable size and type. A wrong-width write is a real hazard. The macOS 27 firmware already changed `BCF0` from 4 bytes to 1 byte (S17).

### 3.2 Reported timeline (Apple silicon)

| Era (as reported) | Firmware (batt README table) | Firmware limit keys | Charge-inhibit keys | Adapter-cut / force-discharge keys |
|---|---|---|---|---|
| macOS 11–14 | 6723.x – 101xx | `BCLM` (80/100 only), `CHWA` (fixed 80%) | `CH0B` / `CH0C` | `CH0I` (+ `CH0J`, `CH0K` reported) |
| macOS 15 | 118xx | `CHWA` gone (`keyNotFound` from 15.0 b5). `CHLS` per Linux ("newer firmware"); macOS status unknown. | `CH0B`/`CH0C`, later `CHTE` | `CH0I`, later `CHIE` |
| macOS 26 (to 26.6) | 138xx / 18xxx | (native Charge Limit from 26.4) | `CHTE` | `CHIE` |
| macOS 27 beta 1–3 | 20356.0.0.0.15 – 20457.0.77.0.2 | `bfF0` (activate) / `bfD0` (upper) / `bfE0` (lower) | `CH0B`/`CH0C`/`CHTE` gone | `CHIE` |
| macOS 27 beta 4+ / 27.0 / **15.8 & 26.7 security updates** | 20457.0.125.0.2+, incl. **20457.1.29** | `bf*` listed but **`kIOReturnNotPrivileged` even for root** | zero-size placeholders / "no data" | `CHIE` readable; reportedly writable as root |

Sources: S16–S28. The exact firmware boundaries where `CHTE`/`CHIE` replaced `CH0B`/`CH0C`/`CH0I` are **not** established. The Linux driver labels them only "older" vs "modern" firmware.

### 3.3 (a) Inhibiting charging

- **`CH0B` / `CH0C`** (legacy) and **`CHTE`** (4-byte, "modern firmware") are the reported charge-inhibit keys (S16, S17, S22, S25).
- Linux `macsmc-power` (grade C):
  - It offers `charge_behaviour = inhibit-charge` only if `CHTE` or `CH0C` exists.
  - At probe it zeroes `CH0K`/`CH0B` (and, per the v3 context, `CHTE`) with the comment "Reset 'Optimised Battery Charging' flags to default state" (S16, S17).
  - **Inference:** macOS's own OBC/hold logic may use the same keys, so a third-party writer would contend with macOS.
- **On 20457.x firmware** these keys are zero-size or "no data" (S19, S24–S27).
- **Value formats:** reported write values come only from tool internals and help text. They are not recorded here, by design, and they vary (1-byte vs 4-byte).

### 3.4 (b) Disabling the adapter / forcing discharge while plugged in

- **`CH0I`** (older; Linux "Force discharge") and **`CHIE`** (newer) are reported. `CH0J` / `CH0K` are listed as adapter keys by batt (S16, S18, S23, S24).
- **On macOS 27.0 (M1 Pro test):**
  - Writing the reported adapter-cut value to `CHIE` switched the Mac to "Battery Power" with `ExternalConnected = No` within 5 s.
  - **With the native Charge Limit active, the write was ignored** because "firmware owns the power path while draining" (S27, grade E).
- **Wear concern:** reviewers objected that adapter-cut limiting "forces the machine to micro-cycle on battery power". One reviewer warned it would "kill your battery quickly"; that is an opinion, not data (S26).
- **Clamshell sleep:** with the lid closed and the adapter cut, the Mac sleeps unless sleep is disabled (`pmset disablesleep 1`, root). batt warns about overheating or draining to 0% in a bag (S18).

### 3.5 (c) Charge-limit-style firmware features

- **`BCLM`** on AS accepted only 80 or 100 and needed "firmware ≥ 13.0" (S20). bclm states: "BCLM does not work on macOS >= 15.0 due to new entitlement enforcement from the kernel …" (S20).
- **`CHWA`** (fixed 80%): `keyNotFound` on macOS 15.0 beta 5 and on 15.0 release (S21, S20 #57).
- **`CHLS`:** a percentage limit with a force-discharge bit, used by the Linux driver on "newer SMC firmware". The thresholds were dropped from the upstream v3 series pending ABI review (S16). Its status under macOS is unknown.
- **`bfF0`/`bfD0`/`bfE0`:**
  - **Behaviour when available:** firmware-managed upper and lower percentages. The firmware decides when to charge, and the limit "continues to work while macOS and the `batt` daemon are asleep". Above the limit "the Mac may run on battery" (S18).
  - **Encodings:** third-party documentation (S23, S24) describes value encodings and a required write order for these keys. They are **deliberately not recorded here**: they come from other tools' implementations, and CellKeeper's clean-room rules exclude reproducing them.
  - **Gating:** gated from macOS 27 beta 4 firmware (S18, S19).

### 3.6 The macOS 27 / 20457 gating claim and its provenance

- **The claim:** batt issue #152 (opened 2026-09-02, no replies) reports (S19):
  - Legacy keys are zero-size.
  - `bf*` KeyInfo, read and write all return `kIOReturnNotPrivileged` (0xe00002c1) "even when running as root".
  - AppleSmartBattery registry writes are refused too.
  - "Apple now filters these keys inside the AppleSMC user client itself, most likely by an entitlement check."
- **Provenance:** the entitlement name `com.apple.private.iokit.soc-limit` and the related `IOPSCopyBatteryLevelLimits()` / `pmset -g battlimit` were found by the reporter **inspecting Apple's `powerd` binary**.
  - CellKeeper's clean-room rules forbid repeating that method. This note only records the claim.
  - The existence of `pmset -g battlimit` is independently confirmed here (read-only).
- **Corroboration:**
  - PR #469 comments: an M5 on 20457.1.29 is "privileged"; M4/M1 on 27.0 are blocked or absent; Sequoia 15.8.1 on 20457.1.29 is "not working" (S24).
  - Issue #151: the macOS 26.7 RC lost features such as MagSafe LED control (S22).
- **Conflict:** BatteryControl reports `bf*` limits **working** on a MacBook Air M3 with "mBoot-20457.1.29, macOS 15.8 (24H23)" ("Programmed 80/70; every write readback-verified") (S23).
  - **Inference:** key **presence** follows firmware, but **enforcement** may live in the macOS kernel's AppleSMC driver and differ between macOS 15.8 and 27. This is unverified.
- **Private entitlements:** `com.apple.private.*` entitlements are not obtainable by third-party developers. That is inference from Apple's naming convention; no Apple document was fetched stating it.

### 3.7 Private paths to the native limit

- **PowerUIAgent's `PowerUISmartChargeClient` via JXA** (actuallymentor/battery PR #480, open, AI co-authored; S27):
  - Sets the native limit "without sudo".
  - It is verified only via `pmset -g battlimit`.
  - Limits below 80 are refused; the setter reportedly **segfaults below 80**.
  - The daemon re-asserts every 60 s.
  - It reports the firmware "drains a battery above the limit down to it by itself", measured at −1.5 to −1.9 A on AC.
  - "The firmware enforces the limit, also during sleep and across reboots."
- **Root-owned `com.apple.smartcharging.topoffprotection` defaults** (`MCLFeatureState`, `mclLimitValue`): claimed to permit sub-80% limits. It was deliberately left out of that PR (S27).
- **batt's "native fallback"** drives the macOS limit "through PowerUIAgent (80% and above only)" (S18).
- **Risk:** these use private Objective-C classes and preference domains. They can break on any update and were presumably discovered by introspection. Classification: `[PRIVATE/UNDOCUMENTED]`; do not adopt.

### 3.8 Privilege (reads vs writes)

- **Reads vs writes:** "in order to write values, the program must be run as root. This is not required for reading values" (bclm, S20). Every SMC-writing tool uses a root daemon or sudoers rule (S18, S19, S23, S25).
- **macOS 27:** some keys are refused even to root, so they are effectively unreadable and unwritable without a private entitlement (S19).
- **Native limit:** setting it via PowerUI is claimed to need no root (S27). Via System Settings or Shortcuts it is a user action.
- **Apple OSS assertions:** `ChargeInhibit`/`DisableInflow` require root. The user client checks for administrator privilege (S10, S11).

### 3.9 Persistence claims

| Mechanism | Sleep | Wake | Reboot | Shutdown | SMC auto-reset (AS restart) | Adapter unplug | Hibernation | Controller dies |
|---|---|---|---|---|---|---|---|---|
| Native Charge Limit | Claimed enforced by firmware (S27). Some users report overshoot "on or asleep" (S36b). | — | Claimed to hold (S27) | **Users report not enforced; charges to 100% while off** (S36b) | Setting is OS-stored (INFERRED) | n/a | Unknown | n/a (OS-owned) |
| Software loop + inhibit key (`CH0B`/`CH0C`/`CHTE`) | **Overshoots** unless charging is disabled before sleep (S18, S20) | "will start charging soon (at most 2 minutes)" after wake (S18) | Re-applied by daemon. "batt only works when macOS is running" (S18). | Not enforced | SMC state presumably lost (INFERRED from S3) | Unknown | "firmware resets SMC keys after hibernation" with non-default `hibernatemode` (S18) | Inhibit may stay set until the next reset (INFERRED) |
| Adapter cut (`CH0I`/`CHIE`) | Enforced "only while batt is awake". Lid-close sleeps the Mac. (S18) | Re-applied | Unknown | Unknown | Presumably lost (INFERRED) | Unknown | Unknown | **Adapter may stay cut: battery drains while "plugged in"** (INFERRED). Tools re-enable it on exit, start, sleep and failure (S18, S23). |
| Firmware limit `bf*` | Holds (S18, S23) | Holds | Unknown | Unknown | Unknown | Unknown | Unknown | Holds; "across processes" (S23) |
| `BCLM`/`CHWA` (AS legacy) | Overshoot reported "while shut down or sleeping" (Intel wording, S20) | — | Needs a launch daemon to re-apply ("persist") | — | "The SMC can be reset by a startup shortcut or various other technical reasons" (S20) | — | — | Value stays in SMC until reset |
| `ChargeInhibit` assertion (Apple OSS) | Unknown | Unknown | Released (process gone) | Released | n/a | Unknown | Unknown | **Released automatically** (S11) |

### 3.10 Interactions with macOS's own battery management

- **Disable native features first:** batt says Optimized Battery Charging and, on 26.4+, the native limit "need to be disabled" when using batt (S18).
- **Native limit overrides `CHIE`:** with the native limit active, `CHIE` writes are ignored (S27).
- **Possible shared keys:** the Linux driver treats `CH0B`/`CH0K` (and `CHTE`) as "Optimised Battery Charging flags" (S16, S17). **Inference:** macOS may rewrite these keys itself and silently undo or fight a third-party inhibit.
- **UI mismatch:** with a third-party inhibit, the menu would show generic "Not Charging" (S4) rather than "Charged to [%] Limit". The MagSafe LED stays amber ("charging is on hold", S5) unless a tool overrides `ACLC`.
- **Leftover tools:** Apple Community users report leftover third-party battery tools interfering with the native limit. One user fixed it by deleting coconutBattery helpers (S36b, anecdotal).

---

## 4. Sleep behaviour (Q4)

- **Apple:** nothing documented about whether charging (or the native limit) continues during sleep or while shut down (S1, S5).
- **Software-loop limiters** (third-party, D):
  - The controlling process is suspended during sleep. If charging is enabled at that moment, the battery charges toward 100% while asleep.
  - Reported mitigations (S18):
    - "disable charging just before sleep" via `kIOMessageSystemWillSleep`.
    - Veto **idle** sleep while charging is active ("prevent-idle-sleep"). This cannot stop lid-close or manual sleep.
    - An experimental "prevent-system-sleep" assertion.
  - A batt user still saw 100% with lid closed on Tahoe 26.1 / firmware 13822.41.1 (S18-issue #101).
- **Firmware-managed limits** (`bf*`, or the native limit) are claimed to hold during sleep with no hooks needed (S18, S23, S27).
- **Adapter-cut limiters** cannot hold the limit during sleep. They re-enable the adapter before sleep, so the battery may then charge while asleep, and a lid-closed Mac with the adapter cut goes to sleep (S18, S24).
- **Native limit, user reports** (S36b, Apple Community, E):
  - Reports mostly agree the limit is **ignored when the Mac is shut down**.
  - One user says it was also exceeded "fully on or asleep".
  - Another says a full 15-minute shutdown "fixed" an ignored limit after a Tahoe update.
- **Classification:** `[INFERRED/UNVERIFIED]` throughout.

---

## 5. Lead-agent inference

(This is the research agent's inference, for lead review. None of it is verified.)

1. **The supported, durable path is the native Charge Limit.** CellKeeper's "control backend" on macOS 26.4+/27 should be a **policy layer over the native limit**:
   - Choose 80/85/90/95/100 by schedule or context.
   - Apply it through a user-installed Shortcut.
   - Verify it through public IOPS state, and optionally the undocumented `pmset -g battlimit` (diagnostics only).
   - This needs no root, no helper and no private API on the write path.
2. **Below-80% limits, "sailing" bands and force-discharge are not available through supported means on macOS 27.** On 20457.x firmware the only reported lever is the adapter cut (`CHIE`). It trades battery micro-cycling for a lower ceiling, is ignored when the native limit is active, and needs a root helper. Treat it as experimental and opt-in, behind the verification protocol, or decline it.
3. **Apple is actively closing SMC write paths.** It removed CHWA in macOS 15, gated `bf*` in macOS 27, and backported the firmware to 15.8/26.7. Any SMC backend should be assumed to break silently on any OS or firmware update. Gate it on **runtime capability probing of an allowlist**, never on OS version (several projects learned this; S18, S24).
4. **Prefer Apple's private `ChargeInhibit` assertion over raw SMC writes if (big if) it works on AS.**
   - powerd releases it on process exit, so it fails safe.
   - It goes through Apple's own policy layer instead of racing it.
   - It still needs root and is private. Its effect on M-series is unknown, and verifying it is a candidate experiment.
5. **The installed third-party helper invalidates any experiment on this machine** until it is removed or its state is otherwise controlled. Experiments belong on a dedicated test Mac.

---

## 6. Risks and failure modes (Q3)

| Risk | Mechanisms affected | Consequence | Mitigation (design) |
|---|---|---|---|
| Charging left **inhibited** after the app/helper crashes or is uninstalled | `CH0B`/`CH0C`/`CHTE` | Battery never charges. The user discovers it unplugged at a low %. | Restore-on-exit. Startup reconciliation from a persisted journal. Uninstaller restores. Prefer assertion-based inhibit, which auto-releases. |
| **Adapter left disabled** | `CH0I`/`CHIE` | Mac runs from battery while "plugged in", can drain to 0% and shut down. Clamshell or bagged Macs can overheat or deplete (S18). | Hard battery floor. Maximum duration. Re-enable on sleep, unplug, exit, launch and error. Never combine with `disablesleep` by default. |
| `pmset disablesleep 1` left stuck | Clamshell + adapter-cut workaround | Mac never sleeps, even in a bag | Avoid entirely. If ever used, journal it and revert with high priority. |
| **Writing unknown keys or wrong widths** | All SMC | Undefined firmware behaviour. Key sizes do change (`BCF0` 4→1 byte in macOS 27, S17). | Allowlist with expected type and size. Refuse on mismatch. Never enumerate-and-write. |
| **Firmware/OS update silently breaks keys** | All SMC | Limit stops working: keys become zero-size, `keyNotFound` or `kIOReturnNotPrivileged`. Tools have reported "unknown" state and silently charged to 100% (S25, S26). | Probe at every launch and after every update. Show honest "unsupported" state. Fall back to the native limit. |
| **Value-format ambiguity** | `bf*` (reportedly non-standard encodings), 1-byte vs 4-byte inhibit keys, undocumented magic values | Wrong value → no effect or a different effect | Read the key's type and size first. Write only known-good values per (key, size, type). Read back immediately. |
| Contention with macOS OBC / Charge Limit | Inhibit and adapter keys | macOS rewrites the keys. The two controllers oscillate. Writes are ignored when the native limit is active (S27). | Detect native-limit state. Disable one controller. Never run two at once. |
| Wear from micro-cycling | Adapter-cut limiting | Shallow cycles on battery instead of a passive hold (S26) | Wide hysteresis band. Opt-in only. Explain the trade-off. |
| Overshoot during sleep or shutdown | Software loops; native limit when off | Battery reaches 100% | Pre-sleep disable (software loop). User education for shutdown. Measure it. |
| Private PowerUI / defaults paths | #8, #9 | Crashes (segfault below 80, S27). Silent breakage. Notarization/review risk. | Do not adopt. |
| Misleading UI | Any third-party inhibit | User sees "Not Charging" with no explanation. LED is amber. | CellKeeper surfaces its own state clearly. |
| Root helper attack surface | All privileged mechanisms | Local privilege escalation if the XPC interface accepts arbitrary keys or values | Named operations only. No raw-key XPC. Validate the caller's code signature. |
| Experimental confound | This dev Mac | False conclusions | Use a clean test Mac. Record all battery-software state. |

---

## 7. Safe verification protocol (design only — **not executed**)

The goal is to let a future developer confirm or refute **one** mechanism on **one** Mac/OS/firmware combination without risking the machine. Nothing below was run.

**Preconditions**
1. Use a dedicated test Mac, not the daily driver. Record the model, macOS build and `System Firmware Version`.
2. Uninstall all third-party battery tools and confirm with a reboot. Record the native Charge Limit and OBC settings (`pmset -g battlimit`, System Settings).
3. Start with the battery between 50% and 75%. The Mac must be on a known-good Apple adapter, on a hard surface, lid open, with a human present.
4. Change no `pmset` settings. Use the default `hibernatemode`.
5. Abort conditions are defined in advance (step 9).

**Phase A — read-only baseline (no user client writes)**

6. Log for at least 10 minutes:
   - Public IOPS state (`Is Charging`, `Power Source State`, capacity).
   - AppleSmartBattery `ExternalConnected`, `IsCharging`, `InstantAmperage`, `ChargerData.NotChargingReason`, `PowerTelemetryData.SystemPowerIn`, `BatteryPower`.
   - `pmset -g batt` and `pmset -g battlimit`.
   - These establish **independent observables** for "charging", "on adapter" and "power from wall".

**Phase B — capability probe (read-only, allowlisted)**

7. Use an allowlist that contains only keys named in a reviewed design doc. Fetch **key info only** (size, type, flags) for those keys.
   - **Never enumerate the key table looking for candidates.** Never read or write keys outside the list.
   - If size or type differs from expectations, if the key is absent, or if the result is `kIOReturnNotPrivileged`: classify the key as **unsupported** and stop. Never retry with escalation, never try to bypass entitlements, and never consider disabling SIP.

**Phase C — single reversible write**

8. For exactly one allowlisted key:
   1. Read and persist the original value to a journal on disk **before** writing (read-before-write).
   2. Write one known value of the exact width.
   3. **Read back immediately.** On mismatch, restore and stop.
   4. Wait up to a fixed settle window (e.g. 30–120 s). Confirm the **expected** change in the Phase A observables. Inhibit means `IsCharging` false and amperage ≈ 0 on AC. Adapter cut means `ExternalConnected` false and `SystemPowerIn` ≈ 0.
   5. Restore the original value. Read back. Confirm the observables return to baseline.

**Phase D — persistence matrix** (one event per trial; restore between trials)

9. Record the key value and observables before and after each event:
   - display sleep
   - idle sleep
   - lid-close sleep
   - wake
   - unplug/replug
   - restart
   - shutdown + cold boot
   - helper SIGKILL
   - helper SIGTERM
   - logout
   - macOS point update (later)

   Separately measure overshoot during a 1-hour sleep with charging enabled, and with the native limit set.

**Safety rails** (for any future implementation)

10. Hard **floor**: never cut the adapter below ~25–30%, and auto-restore on reaching it. Hard **maximum duration** for any non-default state. Auto-restore on:
    - `kIOMessageSystemWillSleep`
    - adapter unplug
    - helper exit (launchd SIGTERM)
    - client disconnect
    - launch, after crash recovery from the journal
    - any read-back mismatch
    - battery temperature or `ChargeStatus` thermal flags
11. **Abort criteria:** unexpected key size or type, any IOReturn error, observables not matching within the window, temperature anomaly, or any unexpected shutdown. On abort, restore everything from the journal and mark the mechanism unsupported for that firmware.
12. **Log** every read and write with a timestamp, firmware, OS build and result. Never write unlisted keys. Run one variable at a time.

**Priority order for experiments**
1. Native limit via Shortcuts. This is user-level and needs no helper.
2. The `ChargeInhibit` private assertion (root, auto-release). It tests whether Apple's own policy path works on AS.
3. `CHIE` adapter cut, only if the product genuinely needs below-80% or forced-discharge behaviour.

---

## 8. Open questions

1. Does the "Set Battery Charge Limit" Shortcuts action accept a variable input? Does it have an "until tomorrow" option on the Mac? Is there a **Get** counterpart? Can a sandboxed app invoke `shortcuts run`?
2. What do `pmset -g battlimit` fields mean (`Drain`, `IsEOC`, `NoChargeToFull`, `Owner`)? Is the getter stable across 27.x? Is there any public replacement?
3. Does the native limit hold during sleep and across restart on this M4 / 20457.1.29? What happens when shut down? This needs a clean machine.
4. Do the private `ChargeInhibit` / `DisableInflow` assertions affect charging on Apple silicon (macOS 26/27)?
5. Is `CHIE` still writable by root on macOS 27.0.1 release firmware? Does an adapter cut survive unplug/replug, sleep and restart?
6. Where does the `bf*` gating live? Is it macOS-kernel or firmware enforcement (the 15.8 conflict)? Will Apple extend gating to `CHIE`?
7. When exactly did `CHTE`/`CHIE` replace `CH0B`/`CH0C`/`CH0I` (firmware build)?
8. Does Apple's native limit actively drain above the limit (−1.5 to −1.9 A reported)? Should CellKeeper surface that to users?

---

## 9. Sources

All URLs below were fetched during this research, or the files were read locally as stated. "Supports" lists what each source was used for.

**Apple — documentation**
- **S1** — Apple Support 102338, "About Optimized Battery Charging and Charge Limit on Mac" (published 2026-04-06): https://support.apple.com/en-us/102338 (also the en-euro variant). Supports: OBC behaviour; Charge Limit requirements, range and behaviour; menu strings; occasional 100%.
- **S2** — Apple Support 102588, "About battery health management in Intel-based Mac laptops" (published 2026-09-15): https://support.apple.com/en-us/102588. Supports: Intel BHM (see 03).
- **S3** — Apple Support 102605, "Reset the SMC of your Mac" (published 2025-12-08): https://support.apple.com/en-us/102605. Supports: SMC scope (battery and charging); "SMC resets automatically on Mac with Apple silicon".
- **S4** — Apple, "If your Mac battery status is 'Not Charging'": https://support.apple.com/en-us/HT211246. Supports: Not Charging reasons; drain to 90% under battery health management.
- **S5** — Apple Support 102397, "Charge your Mac laptop computer" (published 2026-09-15): https://support.apple.com/en-us/102397. Supports: "Charging On Hold", "Charge to Full Now", MagSafe LED amber/green meanings.
- **S6** — Apple, macOS Tahoe 26 compatible computers (122867): https://support.apple.com/en-us/122867. Supports: context (see 03).
- **S7** — Apple Shortcuts User Guide, "Run shortcuts from the command line": https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac, plus local `man shortcuts`. Supports: the `shortcuts run`/`list` CLI and exit codes.
- **S8** — macOS 27.0 SDK (Xcode 27.0) public headers, read locally: `IOKit/ps/IOPSKeys.h`, `IOKit/ps/IOPowerSources.h`, `IOKit/pwr_mgt/IOPM.h`, `IOKit/pwr_mgt/IOPMLib.h`, `IOKit/IOMessage.h`. Supports: public telemetry keys; no charge-control API; `kIOPMMessageInflowDisableCancelled`; sleep notification and assertion semantics.
- **S9** — Local `man pmset` (pmset(1)) and read-only `pmset -g`, `-g batt`, `-g cap`, `-g battlimit`, `-g assertions` on this Mac. Supports: no documented charge-control options; the `battlimit` getter exists.

**Apple — open source (APSL-2.0)**
- **S10** — apple-oss-distributions/IOKitUser, `pwr_mgt.subproj/IOPMLibPrivate.h` (HEAD 323ead8), fetched from https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMLibPrivate.h. Supports: `DisableInflow` / `ChargeInhibit` assertion types, "requires root".
- **S11** — apple-oss-distributions/PowerManagement, tag PowerManagement-1846.0.25.0.1 (commit d415e45), cloned from https://github.com/apple-oss-distributions/PowerManagement: `pmconfigd/PMAssertions.c`, `pmconfigd/PrivateLib.h`, `AppleSmartBatteryManager/AppleSmartBatteryManagerUserClient.cpp`, `pmset/pmset.m`. Supports: root requirement, admin-privilege check, forwarding to the battery manager, release on process exit, no `battlimit` in the published pmset.

- **S12** — Apple WWDC25 Platforms State of the Union: https://developer.apple.com/videos/play/wwdc2025/102/ (used in 03).

**Press / blogs (secondary)**
- **S13** — 9to5Mac, "macOS 26.4 adds three new battery features on Mac…" (2026-04-03): https://9to5mac.com/2026/04/03/macos-26-4-adds-three-new-battery-features-on-mac-heres-how-to-use-them/. Supports: the "Set Battery Charge Limit" action name; Slow Charger.
- **S14** — Michael Tsai, "macOS 26.4: Charge Limit and Shortcuts" (2026-02-28): https://mjtsai.com/blog/2026/02/28/macos-26-4-charge-limit-and-shortcuts/. Supports: temporary override restored at 6 AM.
- **S35** — 9to5Mac, "macOS 26.4 brings battery Charge Limit to the Mac and Shortcuts" (2026-02-16): https://9to5mac.com/2026/02/16/macos-26-4-brings-battery-charge-limit-to-the-mac-and-shortcuts/. Supports: 80–100%, Shortcuts support since beta 1.
- **S36** — junian.dev, "How to Set 80% Battery Charge Limit on MacBook without 3rd-Party App" (2026-03-25, updated 2026-09-01): https://www.junian.dev/tech/macbook-battery-charge-limit/. Supports: report that the Mac drains down to the limit if above it.
- **S36b** — Apple Community thread 256286525 (Apr–Sep 2026): https://discussions.apple.com/thread/256286525. Supports: user reports that the native limit is ignored when shut down and sometimes exceeded when on/asleep; fixes by shutdown or removing old tools. Anecdotal.
- MacRumors how-to (2026-04-10): https://www.macrumors.com/how-to/macbook-charge-limit-setting-benefits/. Supports: OBC continues alongside the Charge Limit.

**Third-party projects (claims — unverified)**
- **S16** — Linux `macsmc-power` driver, PATCH v2 (Michael Reeves / Asahi Linux, 2026-01-08; GPL-2.0-only OR MIT): https://ratatoskr.run/lkml/2026/01/3358555/t. Supports: key roles (`CH0I`, `CHTE`, `CH0C`, `CH0K`/`CH0B` "OBC flags", `CHWA`, `CHLS`); "macOS 15.4+ firmware dropped legacy AC keys".
- **S17** — "[PATCH v3] power: supply: macsmc: Support macOS 27 SMC firmware" (Sasha Finkelstein, 2026-06-29): https://ratatoskr.run/lkml/2026/06/17187069. Supports: `BCF0` 4→1 byte change; older vs modern key labels.
- **S18** — charlie0129/batt README (GPL-2.0): https://github.com/charlie0129/batt and https://raw.githubusercontent.com/charlie0129/batt/master/README.md. Supports: firmware table; legacy, firmware, adapter and native backends; sleep options; hibernation reset claim; exit behaviour; native-limit advice. Also issue #101: https://github.com/charlie0129/batt/issues/101 (charged to 100% with lid closed, Tahoe 26.1).
- **S19** — charlie0129/batt issue #152 (2026-09-02): https://github.com/charlie0129/batt/issues/152. Supports: macOS 27 b4+ gating, `kIOReturnNotPrivileged` even as root, the entitlement claim and its provenance, `CHIE` still writable.
- **S20** — zackelia/bclm README (MIT): https://github.com/zackelia/bclm, and issue #57: https://github.com/zackelia/bclm/issues/57. Supports: AS BCLM 80/100 only; reads unprivileged, writes root; macOS 15 entitlement statement; persistence via launch daemon; SMC reset caveat.
- **S21** — zackelia/bclm issue #49 (2024-08-06): https://github.com/zackelia/bclm/issues/49. Supports: `keyNotFound(CHWA)` on macOS 15.0 beta 5.
- **S22** — charlie0129/batt issue #151 (2026-08-27): https://github.com/charlie0129/batt/issues/151. Supports: macOS 26.7 RC affected (MagSafe LED control lost).
- **S23** — Ednk-1312/BatteryControl README (MIT): https://github.com/Ednk-1312/BatteryControl. Supports: key families by firmware; `bf*` encoding and write order; conflicting report that `bf*` works on 15.8 + 20457.1.29; safety design (read-back, restore, floor).
- **S24** — actuallymentor/battery PR #469 (2026-07-10, open): https://github.com/actuallymentor/battery/pull/469. Supports: per-model reports on 27.0/15.8; `CHIE` readable/not gated; "macOS 27 does not imply Golden Gate keys".
- **S25** — actuallymentor/battery README (MIT): https://github.com/actuallymentor/battery. Supports: an AS-only tool using a sudoers-allowed `smc` binary; charging/adapter/discharge functions.
- **S26** — actuallymentor/battery PR #478 (2026-09-16, closed): https://github.com/actuallymentor/battery/pull/478. Supports: only `CHIE` responds on M4/macOS 27; micro-cycling objection.
- **S27** — actuallymentor/battery PR #480 (2026-09-19, open, AI co-authored): https://github.com/actuallymentor/battery/pull/480. Supports: the PowerUI JXA path; the defaults domain; `CHIE` ignored under the native limit; firmware drain above the limit; sleep and reboot claims; `pmset -g battlimit` used for verification.
- **S28** — pkg.go.dev listing for batt `pkg/smc` v0.8.0 (GPL-2.0): https://pkg.go.dev/github.com/charlie0129/batt/pkg/smc. Supports: key names claimed for adapter (`CH0K`/`CH0J`/`CHIE`) and firmware-limit (`bf*`); marked "Not verified yet."
- **S29** — Linux "[PATCH v7 05/10] mfd: Add Apple Silicon System Management Controller" (Sven Peter / Asahi, 2025-06-10; GPL-2.0-only OR MIT): https://lkml.iu.edu/hypermail/linux/kernel/2506.1/03210.html. Supports: SMC transport, key-value model and type codes.
