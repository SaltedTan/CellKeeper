# 01 — Battery telemetry and public macOS APIs

- **Date:** 2026-10-06
- **Machine:** Mac16,1 (MacBook Pro 14-inch, M4, 2024), Apple Silicon (arm64)
- **OS / toolchain:** macOS 27.0.1 (build 26A434), Xcode 27.0, Swift 6.4, MacOSX SDK from Xcode 27.0
- **Scope:** Read-only telemetry. This note does not cover writing or controlling charging, except to classify how it works.
- **Confound:** A third-party battery-management app's privileged helper is installed on this machine. Any "on AC but not charging" state seen here is **not** attributed to macOS. None of that app's files were inspected.

---

## Summary

1. **Two layers give almost everything, and both work in App Sandbox.** The layers are (a) the documented IOPowerSources API (`IOPSCopyPowerSourcesInfo` and related calls) and (b) read-only IORegistry property reads on `AppleSmartBattery`. I verified this with an ad-hoc-signed App Sandbox build: the sandboxed and unsandboxed builds returned the same data and the same notifications, with no sandbox denials logged. `[VERIFIED-EXPERIMENTALLY]`
2. **The IOPS description dictionary is now thin.** On macOS 27.0.1 it has no Temperature, Voltage, BatteryHealth, BatteryHealthCondition or cycle count. `IOPSKeys.h` still says "Apple-defined power sources will publish" Temperature, Voltage and BatteryHealth, so the header comments are stale. It also has two undocumented keys: `LPM Active` and `DesignCycleCount`. The second one is **wrong** on this machine: it says 300, while Apple's published spec for this model is 1000.
3. **Registry key layout changed between macOS 26 and macOS 27.** Apple's open-source `AppleSmartBattery` driver (PowerManagement-1846.x, likely macOS 26.x) publishes `AppleRawCurrentCapacity`, `AppleRawMaxCapacity`, `NominalChargeCapacity`, `DesignCapacity`, `Temperature` and `VirtualTemperature` at the **top level** on Apple Silicon. On macOS 27.0.1 all of these are **missing from the top level**. `DesignCapacity`, `NominalChargeCapacity` and `FullChargeCapacity` now appear only in the `BatteryData` sub-dictionary, and **Temperature does not appear anywhere**. CellKeeper must check both places for each key and treat every key as optional.
4. **Units depend on the platform.** On Apple Silicon, registry and IOPS `CurrentCapacity` and `MaxCapacity` are **percent** (MaxCapacity = 100). On Intel, the open-source driver publishes registry `CurrentCapacity`/`MaxCapacity` in **mAh**. On this build, mAh values come only from `BatteryData`.
5. **There is no unprivileged, non-private source of battery temperature on this build.** It is absent from IOPS, from the registry, from `pmset` and from `system_profiler`. The alternatives (IOHIDEventSystemClient, AppleSMC user-client key reads, IOReport, `powermetrics`) are all private, privileged, or both. I did not exercise any of them.
6. **Health and condition are not exposed to ordinary clients on macOS 27.** In the macOS 26-era open source, powerd adds the detailed health dictionary only for clients that hold the private entitlement `com.apple.private.iokit.batterydata`. `system_profiler SPPowerDataType -json` does report `sppower_battery_health` ("Good") and `sppower_battery_health_maximum_capacity` ("100%"), and that works **even when spawned from a sandboxed process**. Its JSON keys are undocumented.
7. **Charge limits are not readable through any public API.** Apple documents Optimized Battery Charging (macOS 11+) and a native **Charge Limit** (macOS Tahoe 26.4+, Apple silicon, 80–100%; it is also in the macOS 27 Mac User Guide). No public SDK symbol reads either setting or the current hold state. Apple's open-source `chargeControl.m` and `BatteryChargingStateManager.m` are published as **empty files** in every PowerManagement tag I checked.
8. **Notification cadence observed:** the driver refreshed every **60 s** in steady state (AC, not charging). Each refresh produced the IOKit interest message `kIOPMMessageBatteryStatusHasChanged` and then, about 2 ms later, the notify(3) post `com.apple.system.powersources` (`kIOPSNotifyAnyPowerSource`). `IOPSNotificationCreateRunLoopSource` and `kIOPSNotifyTimeRemaining` did **not** fire because percent and time remaining did not change. This matches the header.
9. **Recommended approach (details in "Recommended telemetry approach"):**
   - **Events:** use `notify_register_dispatch` on `kIOPSNotifyPowerSource`, `kIOPSNotifyTimeRemaining` and `kIOPSNotifyAnyPowerSource`. Add NSWorkspace wake notifications, `ProcessInfo` thermal and power-state notifications, and a slow safety timer.
   - **Data:** on each event, take one IOPS snapshot for the "official" state and one registry read for detail.
   - **Keys:** resolve each key at the top level first, then in `BatteryData`. Use plausibility checks to detect the units.

---

## Tag legend

| Tag | Meaning |
|---|---|
| `[PUBLIC-API]` | Declared in a public SDK header or Apple developer docs. For a **registry key**, this means the key-name constant is defined in a public header (e.g. `IOPM.h`). The IORegistry read functions themselves are always public. |
| `[PRIVATE/UNDOCUMENTED]` | Not declared in any public header or doc. This includes undocumented registry keys, undocumented IOPS dictionary keys, private functions and private notify names. |
| `[IOKIT]` | Read through IOKit: the IORegistry, or IOPS (which is implemented in IOKit.framework and backed by powerd). |
| `[SMC/HW]` | Comes from SMC or gas-gauge hardware via a kernel driver. Reading it directly needs a user client. |
| `[PRIVILEGED]` | Needs root, a private entitlement, or a special sandbox exception. |
| `[ARCH-SPECIFIC]` | Semantics differ between Apple Silicon (AS) and Intel. |
| `[VERIFIED-EXPERIMENTALLY]` | I observed it on this machine (macOS 27.0.1, M4). |
| `[INFERRED/UNVERIFIED]` | Comes from Apple open source, headers or reasoning, but I did not observe it here. |

---

## Metric table

Abbreviations:
- **IOPS** = `IOPSGetPowerSourceDescription(IOPSCopyPowerSourcesInfo(), …)` dictionary.
- **REG** = `IORegistryEntryCreateCFProperties` on the service matched by `IOServiceMatching("AppleSmartBattery")`.
- **REG.BatteryData** = the `BatteryData` sub-dictionary in REG.
- "SBX OK" = verified to work in App Sandbox.

| Metric | Source / API | Tags | Units / semantics | Sandbox notes | Evidence |
|---|---|---|---|---|---|
| Battery % | IOPS `kIOPSCurrentCapacityKey` "Current Capacity" ÷ `kIOPSMaxCapacityKey` "Max Capacity". Fallback: REG `CurrentCapacity` (`kIOPMPSCurrentCapacityKey`). | PUBLIC-API, IOKIT, ARCH-SPECIFIC (REG), VERIFIED | IOPS gives percent (Max = 100). REG on AS: percent, with REG `MaxCapacity` = 100. REG on Intel: mAh (from OSS). Note: the UI's 80% ≠ RemainingCapacity/FullChargeCapacity (4775/6131 = 77.9%), so do not compute the UI % from mAh. | SBX OK | IOPS 80/100, REG 80/100, `pmset -g batt` 80% |
| AC vs battery | `IOPSGetProvidingPowerSourceType` → "AC Power" / "Battery Power" / "UPS Power". IOPS `kIOPSPowerSourceStateKey`. REG `ExternalConnected`. | PUBLIC-API, IOKIT, VERIFIED | String constants `kIOPMACPowerKey` etc. REG also has an undocumented `AppleRawExternalConnected`. | SBX OK | "AC Power"; REG ExternalConnected = true |
| Charging | IOPS `kIOPSIsChargingKey`. REG `IsCharging` (`kIOPMPSIsChargingKey`). REG `ChargerData.IsCharging` (undocumented). | PUBLIC-API (IOPS/REG top), PRIVATE (ChargerData), VERIFIED | Boolean. In OSS, the driver forces IsCharging = false while a charge inhibit is active. | SBX OK | all false (see confound) |
| Fully charged | IOPS `kIOPSIsChargedKey`, present only when on AC and not charging. REG `FullyCharged` (`kIOPMFullyChargedKey`). REG.BatteryData `FullyCharged`. | PUBLIC-API, IOKIT, ARCH-SPECIFIC | OSS powerd: on arm64 macOS, Is Charged = driver FullyCharged **or** SOC ≥ 100. On Intel it is SOC ≥ 95, which is what the `IOPSKeys.h` text describes. | SBX OK | false at 80% |
| Health / condition | Intended: IOPS `kIOPSBatteryHealthKey`, `kIOPSBatteryHealthConditionKey`, `kIOPSBatteryFailureModesKey`. Actually available: **none** for unentitled clients. Fallback: `system_profiler SPPowerDataType -json` → `sppower_battery_health`. | PUBLIC-API keys but **absent**. Detailed health is PRIVILEGED (private entitlement in OSS). system_profiler output is PRIVATE/UNDOCUMENTED. VERIFIED | Apple UI shows "Normal" or "Service Recommended" (support 108376). system_profiler returns "Good" here while the UI shows "Normal"; that mapping is INFERRED. | system_profiler spawn: SBX OK (verified) | IOPS has no health keys; system_profiler "Good" |
| Maximum Capacity % (health) | No public value. Approximation: ceil(`NominalChargeCapacity` ÷ `DesignCapacity` × 100), clamped to 100, read from REG top level or REG.BatteryData. Fallback: system_profiler `sppower_battery_health_maximum_capacity`. | PRIVATE/UNDOCUMENTED keys, IOKIT, INFERRED formula (from OSS) | Here: 6283/6249 → 101 → shown as 100% by system_profiler. OSS powerd filters the value: it never increases, drops at most 1% per ≥5 cycles, and is forced to 104 when cycle count ≤ 20 with no history. A naive ratio can therefore differ from System Settings. | SBX OK | REG.BatteryData values; system_profiler "100%" |
| Full-charge / design / nominal capacity (mAh) | macOS 27: REG.BatteryData `FullChargeCapacity`, `DesignCapacity`, `NominalChargeCapacity`, `RemainingCapacity`. macOS ≤26 AS (OSS): top-level `AppleRawMaxCapacity`, `AppleRawCurrentCapacity`, `DesignCapacity`, `NominalChargeCapacity`. Intel: top-level `MaxCapacity`/`CurrentCapacity` in mAh plus the AppleRaw* keys. | `DesignCapacity` is PUBLIC (constant `kIOPMPSDesignCapacityKey`); the rest are PRIVATE/UNDOCUMENTED. IOKIT, ARCH-SPECIFIC, VERIFIED (macOS 27 layout) | mAh. IOPS `kIOPSDesignCapacityKey` / `kIOPSNominalCapacityKey` are documented as "might not publish" and are absent. | SBX OK | FCC 6131, Design 6249, NCC 6283, Remaining 4775 |
| Cycle count | REG `CycleCount` (`kIOPMPSCycleCountKey`). Fallback: system_profiler. | PUBLIC-API key, IOKIT, VERIFIED | Integer cycles. Not in IOPS. A private IOReport channel `BatteryCycleCount` also exists. | SBX OK | 54 (REG, system_profiler, pmset rawlog) |
| Design cycle count | REG `DesignCycleCount9C`. In OSS this comes from gas-gauge command 0x9C. Do **not** use IOPS `DesignCycleCount`. | PRIVATE/UNDOCUMENTED, IOKIT, VERIFIED | REG = 1000, which matches Apple support 102888 (MacBook Pro 14-inch 2024: 1000). IOPS says 300 and `pmset -g rawlog` prints "Cycles=54/300", which is **wrong** for this model. | SBX OK | REG 1000 vs IOPS 300 |
| Temperature | **Not available** on macOS 27.0.1. In older builds: REG `Temperature` (`kIOPMPSBatteryTemperatureKey`) and `VirtualTemperature`. IOPS `kIOPSTemperatureKey` (documented as °C) is not published. | Old key PUBLIC; absent now. Alternatives PRIVATE + PRIVILEGED. VERIFIED absent | The OSS comment says macOS publishes the gauge's "SmartBattery format directly", while other platforms use centi-°C. The units of the old key are therefore **unverified**. | n/a | absent in IOPS, REG, whole-registry key scan, pmset, system_profiler |
| Voltage | REG `Voltage` (`kIOPMPSVoltageKey`), plus undocumented `AppleRawBatteryVoltage`. IOPS `kIOPSVoltageKey` is documented but **absent**. | PUBLIC-API key, IOKIT, VERIFIED | mV (12427 mV here; the IOPS header doc says mV). | SBX OK | REG 12426–12428 |
| Current / amperage | IOPS `kIOPSCurrentKey` "Current" (OSS: driver average amperage). REG `Amperage` (`kIOPMPSAmperageKey`, average). REG `InstantAmperage` (undocumented). | PUBLIC-API (IOPS, REG Amperage), PRIVATE (InstantAmperage), VERIFIED | mA, signed; negative while discharging (header and OSS; not observed because the value was 0). Read it as a signed Int64 from CFNumber; `ioreg` text can show negatives as huge unsigned numbers (INFERRED). | SBX OK | 0 mA (AC, not charging) |
| Power (W) | Battery: compute Voltage × Amperage. Also REG.BatteryData `BatteryPower`, REG `PowerTelemetryData.{BatteryPower, SystemPowerIn, SystemLoad, SystemVoltageIn, SystemCurrentIn, WallEnergyEstimate…}`, REG `PowerDistribution.{IPDInputPower, IPDInputVoltage, IPDInputCurrent}`. | PRIVATE/UNDOCUMENTED, IOKIT, VERIFIED present; units INFERRED | `SystemPowerIn` 11781 ≈ `SystemVoltageIn` 20497 mV × `SystemCurrentIn` 575 mA = 11.79 W, so it is **mW** (inferred from the arithmetic). | SBX OK | values present |
| Adapter info | `IOPSCopyExternalPowerAdapterDetails()` with keys `kIOPSPowerAdapterWattsKey` "Watts", `…CurrentKey` (mA), `…IDKey`, `…FamilyKey`, `…SourceKey`. The registry's `AdapterDetails` dict mirrors it. | PUBLIC-API, IOKIT, VERIFIED | Watts = 68 for an adapter named "70W USB-C Power Adapter" (20 V × 3.39 A = 67.8 W). So Watts is the **negotiated** power, not the marketing rating (INFERRED). FamilyCode 0xE000400A = `kIOPSFamilyCodeUSBCPD` (header enum). Undocumented extras: `Name`, `Manufacturer`, `AdapterPowerTier`, `UsbHvcMenu`, `IsWireless`, `FwVersion`, `HwVersion`. `AdapterVoltage` and `Description` are public constants in IOPM.h. `SerialString` is an identifier: **do not log**. | SBX OK | adapter dict returned |
| Time remaining | `IOPSGetTimeRemainingEstimate()` in **seconds**: −1 = unknown, −2 = unlimited (on AC). IOPS `kIOPSTimeToEmptyKey` / `kIOPSTimeToFullChargeKey` in **minutes**: −1 = calculating; 0 when not applicable. REG `AvgTimeToEmpty`, `AvgTimeToFull`, `TimeRemaining` (65535 = n/a, INFERRED). | PUBLIC-API (IOPS), PUBLIC key (`TimeRemaining`) and PRIVATE keys (Avg*), VERIFIED | `BatteryInvalidWakeSeconds` = 30: the estimate is invalid for 30 s after wake (IOPM.h `kIOPMPSInvalidWakeSecondsKey`). | SBX OK | −2.0 s; 0/0 min; 65535 |
| Low battery warning | `IOPSGetBatteryWarningLevel()` → 1 none, 2 early, 3 final. REG `AtCriticalLevel`. | PUBLIC-API, VERIFIED | enum | SBX OK | 1 |
| Low Power Mode | `ProcessInfo.processInfo.isLowPowerModeEnabled` (macOS 12+). IOPS `LPM Active` (undocumented). `pmset -g custom` `lowpowermode` per source (that is the *setting*, from a CLI). | PUBLIC-API (ProcessInfo), PRIVATE (IOPS key), VERIFIED | Bool | SBX OK | false / false / 0 |
| Thermal state | `ProcessInfo.processInfo.thermalState` (.nominal/.fair/.serious/.critical). `IOPMGetThermalWarningLevel()` returns `kIOReturnNotFound` here. `IOGetSystemLoadAdvisory` / `kIOSystemLoadAdvisoryNotifyName`. | PUBLIC-API, VERIFIED | This is **system** thermal pressure, not battery temperature. | SBX OK | thermalState 0; IOPM thermal 0xe00002f0 (not published) |
| Charging inhibit / not-charging reason | No public "inhibit state". Indirect signals: on AC + `IsCharging` false + `FullyCharged` false. REG `ChargerData.NotChargingReason`, `ChargerData.SlowChargingReason`, `ChargerData.TimeChargingThermallyLimited`, `PowerDistribution.IPDChargingAllowed` (all undocumented). IOPS/REG `ChargeStatus` (`kIOPMPSBatteryChargeStatusKey`) with public values "HighTemperature", "LowTemperature", etc., present only when charging is interrupted for temperature reasons. | PRIVATE/UNDOCUMENTED (bitfields), PUBLIC key for ChargeStatus, VERIFIED present | `NotChargingReason` is an undocumented bitfield; observed 0x01000000 here, **cause not attributed** (confound). The inhibit *control* path (`AppleSmartBatteryManagerUserClient`, selector "ChargeInhibit") requires `kIOClientPrivilegeAdministrator` in OSS: PRIVILEGED + PRIVATE. Not exercised. | Reads SBX OK | REG values |
| Optimized Battery Charging / Charge Limit | **No public API** to read whether either is enabled, the configured limit, or "on hold". Not in `pmset -g`, not in `system_profiler`. | n/a (UI only). VERIFIED absent from SDK headers | Apple: OBC delays charging past 80% ("Charging On Hold"). Charge Limit is 80–100% on macOS 26.4+ with Apple silicon; it charges to within a few % of the limit and resumes if the level drops more than 5% ("Charged to [%] Limit"). Both occasionally charge to 100% for calibration. | n/a | support 102338; macOS 27 user guide |
| Change notifications | see the "Notifications" section | PUBLIC-API (most), VERIFIED | — | SBX OK (all registrations returned 0) | 5-minute monitor |

---

## Details per mechanism

### A. IOPowerSources (`IOKit/ps/IOPowerSources.h`, `IOPSKeys.h`) — `[PUBLIC-API][IOKIT]`

**Functions used** (all declared in `IOPowerSources.h`):
- `IOPSCopyPowerSourcesInfo`
- `IOPSCopyPowerSourcesList`
- `IOPSGetPowerSourceDescription`
- `IOPSGetProvidingPowerSourceType`
- `IOPSGetTimeRemainingEstimate`
- `IOPSGetBatteryWarningLevel`
- `IOPSCopyExternalPowerAdapterDetails`
- `IOPSNotificationCreateRunLoopSource`
- `IOPSCreateLimitedPowerNotification`

Apple's docs list `IOPSCopyPowerSourcesInfo` as macOS 10.2+, not deprecated.

**Transport (Apple OSS, IOKitUser-100231.120.3, `IOPowerSources.c`):**
- `IOPSCopyPowerSourcesInfo` makes a MIG call (`io_ps_copy_powersources_info`) to powerd.
- `IOPSGetTimeRemainingEstimate` only reads the notify(3) state word of `com.apple.system.powersources.timeremaining`.
- `IOPSNotificationCreateRunLoopSource` registers on `kIOPSNotifyTimeRemaining`.
- `IOPSCreateLimitedPowerNotification` registers on `kIOPSNotifyPowerSource`.

**Observed IOPS description on macOS 27.0.1 (17 keys):**
- `Battery Provides Time Remaining`
- `Current`
- `Current Capacity`
- `DesignCycleCount`
- `Hardware Serial Number` (identifier, not recorded)
- `Is Charged`
- `Is Charging`
- `Is Present`
- `LPM Active`
- `Max Capacity`
- `Name`
- `Power Source ID`
- `Power Source State`
- `Time to Empty`
- `Time to Full Charge`
- `Transport Type`
- `Type`

**Undocumented keys among these:** `Battery Provides Time Remaining`, `LPM Active` and `DesignCycleCount` are not in `IOPSKeys.h`. `LPM Active` and `DesignCycleCount` are also missing from the latest published powerd source (PowerManagement-1846.120.8.0.1), so they are probably macOS 27 additions. That is INFERRED.

**Documented "Apple-defined power sources will publish this key" but absent here:**
- `Voltage`
- `Temperature`
- `BatteryHealth`
- `BatteryHealthCondition`
- `Vendor ID`
- `Product ID`

`Is Finishing Charge` is only added while charging (OSS).

**macOS 26-era OSS behaviour worth knowing (`pmconfigd/BatteryTimeRemaining.m`, PowerManagement-1846.120.8.0.1) — `[INFERRED/UNVERIFIED for macOS 27]`:**
- **Percent and capacity:** IOPS `Current Capacity` = round(REG CurrentCapacity / REG MaxCapacity × 100), clamped to 1…100, and never allowed to rise while discharging. IOPS `Max Capacity` is always 100. Intel only: 100% is shown as 99% while charging.
- **Time fields:** `Time to Empty` / `Time to Full Charge` are set to 0 when on AC and not charging. That matches what I observed.
- **Possible privacy rounding:** there is a privacy feature flag, `os_feature_enabled(privacy, ImprecisePowerData)`. When it is on, the percent returned by `IOPSCopyPowerSourcesInfo` to clients is **rounded to the nearest 5%**.
  - No `privacy` feature-flag domain file exists under `/System/Library/FeatureFlags/Domain/` on this machine, so the flag is probably off. That is INFERRED; it cannot be confirmed at SOC = 80%.
  - The registry `CurrentCapacity` is not affected by this flag. It makes a good cross-check.
- **Entitlement gate:** the detailed health dictionary (`Maximum Capacity Percent`, service flags and state) is added to the IOPS dictionary **only** for callers with the private entitlement `com.apple.private.iokit.batterydata`.

### B. IORegistry `AppleSmartBattery` — `[IOKIT]`, keys mixed public/private

**How it is read:** `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))`, then `IORegistryEntryCreateCFProperties` or `IORegistryEntryCreateCFProperty`. This only reads properties; it does **not** open a user client.

**Driver identity:**
- The live service is `AppleSmartBatteryManager`, bundle `com.apple.driver.AppleSmartBatteryManager`, provider class `AppleSMC`.
- The same bundle ID and provider class appear in Apple's open-source `AppleSmartBatteryManager/Info.plist`. So the OSS is representative of this driver, at least as of macOS 26.x.

**Observed:** 51 properties via the CF call; 59 in `ioreg -a`, which adds IO* bookkeeping and children.

**Keys with public constants (`IOPM.h`):**
- `ExternalConnected`
- `ExternalChargeCapable`
- `BatteryInstalled`
- `IsCharging`
- `FullyCharged`
- `AtCriticalLevel`
- `CurrentCapacity`
- `MaxCapacity`
- `TimeRemaining`
- `Amperage`
- `Voltage`
- `CycleCount`
- `AdapterInfo`
- `Location`
- `AdapterDetails` (sub-keys `AdapterID`, `Watts`, `Current`, `FamilyCode`, `Description`, `PMUConfiguration`, `AdapterVoltage`, `Source`)
- `ChargerConfiguration`
- `BatteryInvalidWakeSeconds`
- `PostChargeWaitSeconds`
- `PostDischargeWaitSeconds`
- `Serial` and `ManufactureDate`: identifiers, do not log
- `DeviceName` (gauge chip model, e.g. "bq40z651")

Constants `DesignCapacity` and `Temperature` exist in `IOPM.h` but are **absent** at the top level here.

**Undocumented keys seen:**
- `InstantAmperage`
- `AppleRawBatteryVoltage`
- `AppleRawExternalConnected`
- `AvgTimeToEmpty`
- `AvgTimeToFull`
- `DesignCycleCount9C`
- `BatteryData{…}`
- `ChargerData{…}`
- `PowerDistribution{…}`
- `PowerTelemetryData{…}`
- `PortControllerInfo[…]`
- `FedDetails[…]`
- `PowerOutDetails[…]`
- `DeadBatteryBootData{…}`
- `BatteryShutdownReason{…}`
- `UpdateTime` (UNIX seconds of the last driver poll)
- `IOReportLegend` (one private IOReport channel, `BatteryCycleCount`)
- `ManufacturerData`: do not log

**`BatteryData` on macOS 27.0.1 (11 keys):**
- `AbsoluteCapacity` (0)
- `AvgTimeToEmpty`
- `BatteryPower`
- `CurrentCapacity` (%)
- `DesignCapacity` (mAh)
- `FullChargeCapacity` (mAh)
- `FullyCharged`
- `MaxCapacity` (100)
- `NominalChargeCapacity` (mAh)
- `RemainingCapacity` (mAh)
- `TrueRemainingCapacity` (0)

No temperature, cycle count or cell voltages.

**Version difference (important):**
- In OSS 1846.120.8 (non-x86 branch), the driver polls and publishes these at the top level on Apple Silicon:
  - `AppleRawCurrentCapacity`
  - `AppleRawMaxCapacity`
  - `NominalChargeCapacity`
  - `AbsoluteCapacity`
  - `Temperature`
  - `VirtualTemperature`
  - `DesignCapacity`
  - `PackReserve`
- On macOS 27.0.1, none of these are top-level. Some moved into `BatteryData`; temperatures disappeared.
- The macOS 27 driver source is not published (as of today), so the reason is unknown. It could be a privacy hardening or a restructuring. This is `[INFERRED]`.

**Intel semantics (OSS, `TARGET_OS_OSX_X86`)** `[INFERRED/UNVERIFIED]`, no Intel machine tested:
- `CurrentCapacity` = gauge RemainingCapacity (mAh).
- `MaxCapacity` = gauge FullChargeCapacity (mAh).
- `AppleRawCurrentCapacity` / `AppleRawMaxCapacity` are mirrored in mAh.
- A legacy `LegacyBatteryInfo` dictionary is built.

**Update cadence (verified):** `UpdateTime` advanced by exactly 60 s per update over 5 minutes in steady state (AC, not charging, 80%). Behaviour while charging, discharging or during plug events was not observed (see "Open questions").

### C. External adapter — `[PUBLIC-API][IOKIT]`

- **Public API:** `IOPSCopyExternalPowerAdapterDetails()`. Use the documented keys `Watts` (W), `Current` (mA), `AdapterID`, `FamilyCode` and `Source`.
- **FamilyCode values:** decode with the public enum in `IOPM.h` (e.g. `kIOPSFamilyCodeUSBCPD`).
- **Error flags:** `ErrorFlags` uses public constants such as `kIOPSAdapterErrorFlagInsufficientAvailablePower`.
- **Display name and PD menu:** the private keys `Name` (has a trailing space here), `Manufacturer` and `UsbHvcMenu` (PD voltage/current menu) are also present, but undocumented.
- **Wattage:** for "how big is the charger", `Watts` is the negotiated contract (68 W here for a 70 W brick). This is INFERRED. The registry `PowerDistribution.IPDInputPower` (67800, probably mW) agrees.
- **Equivalent CLI:** `pmset -g adapter`.

### D. ProcessInfo / IOPM thermal and Low Power Mode — `[PUBLIC-API]`

- **Low Power Mode:** `ProcessInfo.isLowPowerModeEnabled` (macOS 12+) plus `NSProcessInfoPowerStateDidChangeNotification` (posted on a global queue, per the header and docs).
  - The macOS 27 user guide also describes an "Energy Mode" (Low Power / Automatic / High Power) per power source. ProcessInfo exposes only the LPM boolean.
  - Whether "Low Power" energy mode on battery shows up as `isLowPowerModeEnabled == true` only while on battery is **unverified**; I did not toggle settings.
- **Thermal state:** `ProcessInfo.thermalState` (macOS 10.10.3+) plus `ProcessInfo.thermalStateDidChangeNotification`. The header says you must read `thermalState` once before registering for the notification.
- **IOPM thermal APIs:** `IOPMGetThermalWarningLevel` and `IOPMCopyCPUPowerStatus` (`IOPMLib.h`) both returned `kIOReturnNotFound` here, and `pmset -g therm` reports "No thermal warning level has been recorded". Treat them as not useful on Apple Silicon (INFERRED from one machine).
- **Load advisory:** `IOGetSystemLoadAdvisory` / `kIOSystemLoadAdvisoryNotifyName` (public) gave notify state 2 (= OK).

### E. Notifications

Exact names from SDK headers. "Private" means it is only in Apple OSS private headers.

| Name (constant) | String | Header | Observed in 5-min steady-state monitor |
|---|---|---|---|
| `kIOPSNotifyPowerSource` | `com.apple.system.powersources.source` | IOPowerSources.h (public) | no events (no AC/battery transition) |
| `kIOPSNotifyTimeRemaining` (= `kIOPSTimeRemainingNotificationKey`) | `com.apple.system.powersources.timeremaining` | public | no events (percent/time unchanged) |
| `kIOPSNotifyAnyPowerSource` | `com.apple.system.powersources` | public; the header discourages it for efficiency | **fired every 60 s** |
| `kIOPSNotifyAttach` | `com.apple.system.powersources.attach` | public | none |
| `kIOPSNotifyLowBattery` | `com.apple.system.powersources.lowbattery` | public | none |
| `kIOPMThermalWarningNotificationKey` | `com.apple.system.power.thermal_warning` | IOPMLib.h (public) | none |
| `kIOPMCPUPowerNotificationKey` | `com.apple.system.power.CPU` | public | none |
| `kIOSystemLoadAdvisoryNotifyName` | `com.apple.system.powermanagement.SystemLoadAdvisory` | public | none |
| `kIOPSNotifyPercentChange` | `com.apple.system.powersources.percent` | **private** (IOKitUser `IOPowerSourcesPrivate.h`) | not registered; state word read via `notifyutil -g` = 0x90050 (valid + external + 80) |
| `kIOPSNotifyAdapterChange`, `kIOPSNotifyCriticalLevel` | `com.apple.system.powermanagement.poweradapter`, `com.apple.system.powersources.criticallevel` | **private** | not registered |
| `IOPSNotificationCreateRunLoopSource` | (wraps timeremaining) | public | no callbacks |
| `IOServiceAddInterestNotification(…, "AppleSmartBattery", kIOGeneralInterest)` | message `kIOPMMessageBatteryStatusHasChanged` (0xe0024100, IOPM.h) | public IOKit | **every 60 s**, about 2 ms before the IOPS notify |
| `NSWorkspace.willSleepNotification` / `didWakeNotification` (+ screens sleep/wake) | — | AppKit (public) | registered; not exercised (machine not slept) |
| `IORegisterForSystemPower` | `kIOMessageSystemWillSleep` / `kIOMessageSystemHasPoweredOn` | IOPMLib.h (public) | not tested; needed only to *delay or veto* sleep, not for UI |
| `ProcessInfo` thermal / power-state notifications | — | Foundation (public) | registered; no changes occurred |

**Recommendation for a menu-bar app:**
- Register `notify_register_dispatch` on a private serial queue for:
  - `kIOPSNotifyPowerSource`: plug/unplug, low latency, documented as cheap.
  - `kIOPSNotifyTimeRemaining`: percent/time changes.
  - `kIOPSNotifyAnyPowerSource`: every driver refresh, which catches charging-state flips and power/voltage changes. The header warns it fires more often; observed once a minute at steady state.
- Add `NSWorkspace.didWakeNotification`. Re-read after wake, and again after `BatteryInvalidWakeSeconds` (30 s).
- Add the `ProcessInfo` thermal and power-state notifications.
- Coalesce all of these through a short debounce (about 250 ms), then take one IOPS snapshot plus one registry read. Use `UpdateTime` to skip duplicate registry snapshots.
- Keep a low-frequency safety timer (e.g. 120 s with generous `leeway`) in case a notification is missed.
- `IOServiceAddInterestNotification` is an acceptable alternative to the AnyPowerSource notify, with the same 60 s cadence, but needs IONotificationPort plumbing. It also notifies *before* powerd has refreshed IOPS, so IOPS reads triggered by it could be stale by about 2 ms (INFERRED).
- Avoid private notify names.

### F. Temperature

**Unprivileged, non-private source on macOS 27.0.1:** none found `[VERIFIED-EXPERIMENTALLY]`. Checked:
- IOPS dict
- `AppleSmartBattery` properties, including `BatteryData`
- a key-name scan of the whole IORegistry (only config flags such as `OverrideBatteryInputTemp`, no live battery temperature)
- `pmset -g batt|ps|rawlog|therm`
- `system_profiler SPPowerDataType`

`DeadBatteryBootData.GeneralPayload.AverageBattSkinTemp` exists but is a boot-time payload (0 here), not live telemetry.

**Alternatives — classified only, NOT exercised:**
- **IOHIDEventSystemClient temperature services:** `[PRIVATE/UNDOCUMENTED]` (no public header on macOS). Whether it works in the sandbox was not investigated.
- **AppleSMC key reads via `IOServiceOpen` on `AppleSMC`:** `[PRIVATE/UNDOCUMENTED][SMC/HW]`, needs an IOUserClient. In App Sandbox that requires `com.apple.security.temporary-exception.iokit-user-client-class`, a temporary exception that needs App Store justification (Apple archive doc). Out of scope by policy.
- **IOReport (libIOReport):** `[PRIVATE]`. The battery IOReport legend here only lists `BatteryCycleCount`.
- **`powermetrics`:** `[PRIVILEGED]` (needs root).

**Recommendation:** show temperature only if a public key reappears (top-level `Temperature` or IOPS `Temperature`). Keep that path behind runtime detection, with units marked unverified. Otherwise show "Unavailable on this macOS version". `ProcessInfo.thermalState` is not a substitute; it is system-wide thermal pressure.

### G. Health, condition and "Maximum Capacity"

**Apple's definitions:**
- "Maximum Capacity" is "the measure of your battery's capacity relative to when it was new" (macOS 27 Mac User Guide; support 102589).
- Condition is **Normal** or **Service Recommended** (support 108376).
- On Apple silicon, battery health management "may temporarily reduce your battery's maximum charge" as needed (102589). This is another, Apple-side reason a Mac may stop charging below 100%.

**How macOS likely derives it (Apple OSS PowerManagement-1846.x, `BatteryTimeRemaining.m`)** `[INFERRED/UNVERIFIED for macOS 27]`:
- **Gauges that report nominal capacity (presumably Apple Silicon):** Maximum Capacity % = ceil(NominalChargeCapacity / DesignCapacity × 100), then filtered:
  - The value only ever decreases.
  - It drops by at most 1 point after ≥5 additional cycles.
  - It is set to 104 when cycle count ≤ 20 and there is no stored history.
  - It is frozen in some service modes.
  - Service is flagged when the value is < 80.
- **Legacy (FCC-based) path:** ceil(FCC/Design × 100) + ceil(200 mAh/Design × 100).
- **Display:** the UI probably caps at 100% (here NCC/Design = 101 → shown as 100%). This is INFERRED.

**Access:**
- The computed value and the service flags are **not** in the IOPS dictionary for unentitled clients. The OSS gates them on the private entitlement `com.apple.private.iokit.batterydata`. `[PRIVILEGED]`
- `BatteryHealth` / `BatteryHealthCondition` (public keys) are also absent on macOS 27.
- **Practical options:**
  1. Compute an "estimated" value from registry `NominalChargeCapacity` / `DesignCapacity` (top level or `BatteryData`) and label it as an estimate.
  2. Spawn `/usr/sbin/system_profiler SPPowerDataType -json` and read `sppower_battery_health` and `sppower_battery_health_maximum_capacity`.
     - Verified to work from inside App Sandbox; took 0.11 s.
     - The JSON keys are undocumented and could change.
     - Spawning helper tools may draw App Review scrutiny (INFERRED).

### H. Charging inhibit, Optimized Battery Charging and Charge Limit

**Native features (Apple support 102338, published 2026-04-06; macOS 27 Mac User Guide):**
- **Optimized Battery Charging** (macOS 11+) uses on-device learning to delay charging past 80% ("Charging On Hold").
- **Charge Limit** (macOS Tahoe 26.4+, Apple silicon): user picks 80–100%. The Mac charges to within a few % of the limit and stops ("Charged to [%] Limit"). Charging resumes if the level drops by more than 5% while connected.
- Both features "occasionally charge to 100%" for SoC calibration.
- "Charge to Full Now" in the battery menu overrides either.
- Apple's article does **not** say whether these features act while the Mac is shut down.

**Readable state:**
- No public API reads the OBC/Charge Limit setting, the configured percentage, or whether a hold is active. Verified: no match in the macOS 27 SDK headers.
- The SDK's `IOKit.tbd` exports two **undocumented** symbols, `_IOPSShippingChargeLimitEnable` and `_IOPSShippingChargeLimitGetState`. They have no header and an unknown purpose; "shipping" suggests a factory/transport mode, not the user Charge Limit (INFERRED). `[PRIVATE]`: do not use.
- Apple's OSS publishes `pmconfigd/chargeControl.{h,m}` and `BatteryChargingStateManager.{h,m}` as **0-byte files** in PowerManagement tags 1630.0.33 through 1846.120.8.0.1. The charge-control logic is not open source.
- Best available inference: "on AC, `IsCharging == false`, `FullyCharged == false`" means **"charging paused, cause unknown"**. Possible causes: OBC, Charge Limit, battery health management, thermal limits (`ChargeStatus`, `ChargerData.TimeChargingThermallyLimited`), an insufficient adapter (`AdapterDetails.ErrorFlags`), or a third-party controller.
- `ChargerData.NotChargingReason` and `PowerDistribution.IPDChargingAllowed` are undocumented. Log them for diagnostics only. Do not decode bits.

**Control (classification only):**
- In OSS, `AppleSmartBatteryManagerUserClient` exposes "ChargeInhibit" and "InflowDisable" selectors gated by `kIOClientPrivilegeAdministrator`: `[PRIVILEGED][PRIVATE/UNDOCUMENTED][IOKIT]`. The driver then forces `IsCharging = false`.
- Not exercised. This is a separate workstream.

### I. App Sandbox — verified

**Method:**
- Compiled a read-only probe with an embedded `Info.plist` (`-sectcreate __TEXT __info_plist`).
- Ad-hoc signed it with only `com.apple.security.app-sandbox = true`.
- Confirmed the sandbox was active (`APP_SANDBOX_CONTAINER_ID` set).

**All of the following matched the unsandboxed run exactly:**
- `IOPSCopyPowerSourcesInfo` / `List` / `GetPowerSourceDescription`
- `IOPSGetProvidingPowerSourceType`
- `IOPSGetTimeRemainingEstimate`
- `IOPSGetBatteryWarningLevel`
- `IOPSCopyExternalPowerAdapterDetails`
- `IOPMGetThermalWarningLevel`
- `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperties` / `CreateCFProperty`
- `notify_register_dispatch` on the 8 public names (status 0)
- `IOPSNotificationCreateRunLoopSource`
- `IOServiceAddInterestNotification` (kr 0, events delivered)
- `ProcessInfo`
- NSWorkspace observers
- spawning `system_profiler`

No sandbox denials appeared in the unified log.

**Caveats:**
- I tested an ad-hoc-signed CLI, not a Developer ID or App Store app. The sandbox profile is the same, but App Review policy is a separate question.
- `IOServiceOpen` was **not** tested (forbidden). Per Apple's archived entitlement reference, opening or setting properties on non-default IOUserClient classes needs a temporary-exception entitlement.

### J. CLI tools (diagnostics only, not for app use)

- `pmset -g batt|ps|adapter|therm|custom|cap|sysload` and `pmset -g rawlog` (a streaming log; "Cycles=54/300", "Design=-1", "FCC=100", "Cap=80").
- `system_profiler SPPowerDataType [-json]`.

---

## Observations (verified on this machine)

1. IOPS dictionary: the 17 keys listed above. Percent 80/100, AC Power, not charging, not charged, `LPM Active` false, `DesignCycleCount` 300, time fields 0.
2. `IOPSGetTimeRemainingEstimate` = −2.0 (unlimited); `IOPSGetBatteryWarningLevel` = 1.
3. Registry: no top-level `Temperature`, `VirtualTemperature`, `AppleRawCurrentCapacity`, `AppleRawMaxCapacity`, `DesignCapacity` or `NominalChargeCapacity`. `BatteryData` holds `DesignCapacity` 6249, `FullChargeCapacity` 6131, `NominalChargeCapacity` 6283, `RemainingCapacity` 4775 (mAh). `CycleCount` 54, `DesignCycleCount9C` 1000, `Voltage` ≈ 12427 mV, `Amperage` 0, `InstantAmperage` 0.
4. Registry `CurrentCapacity` 80 / `MaxCapacity` 100 are percent on AS. Remaining/FCC = 77.9% ≠ the displayed 80%.
5. Adapter: Watts 68, Current 3390 mA, AdapterVoltage 20000 mV, FamilyCode 0xE000400A (USB-C PD), name "70W USB-C Power Adapter".
6. `ProcessInfo.thermalState` = nominal. `isLowPowerModeEnabled` = false. `IOPMGetThermalWarningLevel` / `IOPMCopyCPUPowerStatus` → `kIOReturnNotFound`.
7. Driver refresh every 60 s. IOKit interest message `0xe0024100` is followed about 2 ms later by `com.apple.system.powersources` notify. No `source`, `timeremaining` or run-loop-source events while the state was static.
8. notify state words: `…percent` = 0x90050 (valid | external | 80). `…timeremaining` = 0x1000000004DFFFF (valid | unknown | external | batt-support | 0xFFFF). The bit layout is private (IOKitUser `IOPowerSourcesPrivate.h`).
9. `system_profiler SPPowerDataType -json` gives `sppower_battery_health` "Good", `…maximum_capacity` "100%", cycle count 54. It works from App Sandbox.
10. Every API above behaves identically inside App Sandbox.
11. On AC at 80% with `IsCharging` false: `ChargerData.NotChargingReason` = 0x01000000 and `PowerDistribution.IPDChargingAllowed` = 0. **The cause is not attributed** because of the third-party helper confound.
12. The macOS 27 SDK has no header mentioning charge limit or optimized charging.

## Inferences (unverified)

1. The macOS 27 driver dropped or relocated the top-level raw capacity and temperature keys. The reason (privacy vs refactor) is unknown. Older macOS versions (≤ 26.x) and Intel use different key placement, per the OSS.
2. IOPS `DesignCycleCount` = 300 is a fallback default produced by macOS 27 powerd, not real data.
3. System Settings "Maximum Capacity" ≈ the filtered ceil(NCC/Design), capped at 100%. Condition "Normal" corresponds to system_profiler "Good".
4. `Watts` reflects the negotiated USB-PD contract, not the adapter's marketing rating.
5. `PowerTelemetryData.*Power*` and `PowerDistribution.IPDInputPower` are in mW (from arithmetic consistency).
6. Registry `AvgTimeToEmpty` / `AvgTimeToFull` / `TimeRemaining` = 65535 means "not applicable" (Smart Battery convention).
7. The `ImprecisePowerData` privacy flag (5% rounding of IOPS percent) is off on this build, because no `privacy` flag domain file is present. If Apple enables it later, IOPS percent will be coarse but registry `CurrentCapacity` will not.
8. Notification cadence while charging or discharging is likely faster than 60 s (percent changes trigger `timeremaining`), but this was not measured.
9. The old `Temperature` key's units are unclear: the OSS says macOS uses the "SmartBattery format", while other platforms use centi-°C.

---

## Recommended telemetry approach for CellKeeper

1. **Primary snapshot (cheap, documented): IOPS.** Read `Power Source State`, `Current Capacity` / `Max Capacity`, `Is Charging`, `Is Charged`, `Time to Empty` / `Time to Full Charge`, and `Current` from the internal-battery entry (`Type == "InternalBattery"`). Also call `IOPSGetProvidingPowerSourceType`, `IOPSGetTimeRemainingEstimate`, `IOPSGetBatteryWarningLevel` and `IOPSCopyExternalPowerAdapterDetails`. `[PUBLIC-API]`
2. **Detail snapshot: registry `AppleSmartBattery` via `IORegistryEntryCreateCFProperties`.** One call per refresh; never open a user client. Use it for `CycleCount`, `DesignCycleCount9C`, `Voltage`, `Amperage` / `InstantAmperage`, `ExternalConnected`, `FullyCharged`, `UpdateTime`, and the mAh capacities.
3. **Key resolution (handles macOS-version differences):**
   - Implement `value(key) = top[key] ?? top["BatteryData"]?[key]`.
   - **FCC:** `AppleRawMaxCapacity` (AS ≤26) → `BatteryData.FullChargeCapacity` (27) → `MaxCapacity` if > 100 (Intel mAh).
   - **Remaining:** `AppleRawCurrentCapacity` → `BatteryData.RemainingCapacity` → `CurrentCapacity` if MaxCapacity > 100.
   - **Design / Nominal:** top level → `BatteryData`.
   - **Units:** if `MaxCapacity == 100` and `CurrentCapacity ≤ 100`, treat them as percent; if `MaxCapacity > 100`, treat both as mAh.
   - **Percent shown to the user:** take it from IOPS, cross-checked with the registry. Do not derive the UI percent from mAh.
   - **Design cycles:** `DesignCycleCount9C` → `DesignCycleCount70` → unknown. Never use IOPS `DesignCycleCount`.
   - **Temperature:** top-level `Temperature` / IOPS `Temperature` if present, otherwise "unavailable". Mark the units as unverified until tested on a build that has it.
   - Every key is optional. Unknown or absent should be a first-class state in the model.
4. **Power:**
   - `watts = Voltage(mV) × Amperage(mA) / 1e6`, signed (negative = discharging).
   - Show adapter `Watts` and name.
   - `PowerTelemetryData.SystemPowerIn` (mW) can drive an optional "system draw" readout, labelled experimental.
5. **Health:**
   - Show cycle count (public key) and the estimated Maximum Capacity (computed NCC/Design, labelled "estimate").
   - Optionally offer a "match System Settings" mode that runs `system_profiler SPPowerDataType -json` infrequently (on launch, then daily) and parses it defensively.
   - Do not claim the condition is "Normal" unless it comes from system_profiler.
6. **State interpretation:**
   - Present "Charging paused" (AC connected, not charging, not full) **without asserting a cause**, unless CellKeeper itself issued the pause.
   - Surface `ChargeStatus` (public values) when present.
   - Put the raw `NotChargingReason` value in a diagnostics pane.
   - Mention that macOS OBC / Charge Limit / battery health management can also hold the charge, since none of these is readable.
7. **Events:** follow section E. notify(3) on the three public IOPS names, plus wake and ProcessInfo notifications, then a debounce, a single re-read, and a 120 s safety timer. Use `UpdateTime` to dedupe. All of this works in App Sandbox.
8. **Do not use:** private IOPS functions (`IOPSCopyPowerSourcesByType`, `IOPSGetPercentRemaining`), private notify names, IOReport, IOHIDEventSystemClient, SMC user clients, `IOPSShippingChargeLimit*`, or the `ioreg` / `pmset` text output in production.
9. **Privacy hygiene:** filter out `Serial`, `Hardware Serial Number`, `ManufacturerData`, `AdapterDetails.SerialString`, lot codes and `Power Source ID` before any logging, export or bug report.

---

## Open questions

1. **Live cadence and transitions.** Notification cadence and latency during plug/unplug, active charging and discharging, and sleep/wake. This needs a user-performed unplug/replug test with the monitor running. It was not possible without changing physical state.
2. **macOS 26.x layout.** On a clean macOS 26.x Apple Silicon Mac, are the top-level `AppleRaw*`, `NominalChargeCapacity`, `DesignCapacity` and `Temperature` keys present, as the OSS indicates? Also, what unit does the old `Temperature` use?
3. **Clean macOS 27 machine.** On a macOS 27 Mac **without** the third-party helper, what do `NotChargingReason`, `IPDChargingAllowed` and `IsCharging` look like while native Charge Limit / OBC holds the charge? This could give a heuristic for "macOS is holding". It can only be done by observation, not decoding.
4. **Low Power Mode semantics.** Does `isLowPowerModeEnabled` reflect the macOS 27 per-source "Energy Mode = Low Power", and does it flip on AC/battery transitions?
5. **Precise percent.** Will Apple enable the `ImprecisePowerData` rounding for IOPS on macOS 27.x? Re-check by comparing IOPS vs registry percent at a non-multiple-of-5 SOC.
6. **system_profiler and App Store.** Is spawning `system_profiler` acceptable for a Mac App Store build, or should the health readout be Developer-ID-only?
7. **Design cycle count.** Where does macOS 27's IOPS `DesignCycleCount` = 300 come from? Does Apple's UI anywhere use it? The macOS 27 powerd source is not yet published.
8. **Leftover container.** `~/Library/Containers/dev.cellkeeper.research.telemetryprobe/` remains, containing only the containermanagerd-protected `.com.apple.containermanagerd.metadata.plist` (32 KB); Terminal could not delete it. The user can remove it in Finder if desired.

---

## Sources

**Apple documentation and support (fetched):**
- https://support.apple.com/en-us/102338 — "About Optimized Battery Charging and Charge Limit on Mac" (published 2026-04-06). Supports: OBC requires macOS 11+; Charge Limit requires macOS Tahoe 26.4+ and Apple silicon, set 80–100%; charges to within a few % then stops; resumes after a >5% drop; "Charging On Hold", "Charged to [%] Limit", "Charge to Full Now"; occasional 100% charge; no API or shutdown behaviour mentioned.
- https://support.apple.com/guide/mac-help/change-battery-settings-mchlfc3b7879/mac — Mac User Guide, macOS 27 version. Supports: Charge Limit and OBC exist in macOS 27; Battery Health Normal/service recommended; Maximum Capacity definition; Low Power Mode and Energy Mode options.
- https://support.apple.com/en-us/102888 — battery cycle count; MacBook Pro (14-inch, 2024) is rated for 1000 cycles.
- https://support.apple.com/en-us/108376 — "Service Recommended" vs "Normal" definitions (published 2026-05-11).
- https://support.apple.com/en-us/102589 — battery health management on Apple silicon; may temporarily reduce maximum charge; Maximum Capacity definition; possible recalibration after updates (published 2026-09-14).
- https://developer.apple.com/tutorials/data/documentation/iokit/1523839-iopscopypowersourcesinfo.json — `IOPSCopyPowerSourcesInfo`: macOS 10.2+, Mac Catalyst 18.4+, not deprecated.
- https://developer.apple.com/tutorials/data/documentation/foundation/processinfo/islowpowermodeenabled.json — `isLowPowerModeEnabled` macOS 12+; `NSProcessInfoPowerStateDidChange`.
- https://developer.apple.com/tutorials/data/documentation/foundation/processinfo/thermalstate-swift.property.json — `thermalState` macOS 10.10.3+.
- https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html — `com.apple.security.temporary-exception.iokit-user-client-class` (archived, 2017).

**Public SDK headers (local, Xcode 27.0 MacOSX.sdk):**
- `IOKit.framework/Headers/ps/IOPowerSources.h` — functions; notify names; time-remaining constants.
- `IOKit.framework/Headers/ps/IOPSKeys.h` — IOPS keys, units and "will publish" claims; adapter keys; health values.
- `IOKit.framework/Headers/pwr_mgt/IOPM.h` — registry key constants `kIOPMPS*`, adapter details keys, FamilyCode enum, `ChargeStatus` values, `kIOPMMessageBatteryStatusHasChanged`, `BatteryInvalidWakeSeconds`, thermal levels.
- `IOKit.framework/Headers/pwr_mgt/IOPMLib.h` — `IOPMGetThermalWarningLevel`, `IOPMCopyCPUPowerStatus`, thermal/CPU notify keys, SystemLoadAdvisory, `IORegisterForSystemPower`.
- `Foundation.framework/Headers/NSProcessInfo.h` — thermal state enum/notification; LPM property/notification.
- `AppKit.framework/Headers/NSWorkspace.h` — sleep/wake notifications.

**Apple open source (retrieved via the GitHub API from apple-oss-distributions; Apple Public Source License; read for behaviour, no code copied):**
- `PowerManagement`, tag `PowerManagement-1846.120.8.0.1` (latest tag; likely macOS 26.x):
  - `pmconfigd/BatteryTimeRemaining.m` and `.h` — IOPS dict assembly, Is Charged rules, percent computation, notify posting, health / Maximum Capacity Percent algorithm and constants, private entitlement gate, `ImprecisePowerData` 5% rounding.
  - `AppleSmartBatteryManager/AppleSmartBattery.cpp` — polled/published keys per platform, Intel mAh semantics, temperature format comment, charge-inhibit effect on IsCharging, 30 s invalid-on-wake.
  - `AppleSmartBatteryManager/AppleSmartBatteryManagerUserClient.cpp` — ChargeInhibit/InflowDisable selectors require administrator privilege.
  - `AppleSmartBatteryManager/Info.plist` — driver bundle ID and provider `AppleSMC`.
  - `pmconfigd/chargeControl.{h,m}` and `BatteryChargingStateManager.{h,m}` — 0-byte blobs in tags 1630.0.33–1846.120.8.0.1.
  - `main` branch `pmconfigd/BatteryTimeRemaining.m` — `getNominalChargeCapacityPercent` = ceil(NCC/Design×100).
  - GitHub code search result for `AppleSmartBatteryCommands.h` — `kBDesignCycleCount9CCmd = 0x9C`.
- `IOKitUser`, tag `IOKitUser-100231.120.3`:
  - `ps.subproj/IOPowerSourcesPrivate.h` — private notify names (`…percent`, `…poweradapter`, `…criticallevel`), packed state bit layout, private functions.
  - `ps.subproj/IOPSKeysPrivate.h` — private adapter keys (`Name`, `Manufacturer`, `FwVersion`, `HwVersion`, `SerialString`, `Description`).
  - `ps.subproj/IOPowerSources.c` — MIG transport to powerd; which notify key each public function uses.
- https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeysPrivate.h (fetched via WebFetch) — same private key list.

**Local read-only observations:**
- `ioreg -rn AppleSmartBattery [-a]`; a key-name-only scan of `ioreg -l`.
- `pmset -g batt|ps|adapter|therm|custom|live|cap|sysload|rawlog`.
- `system_profiler SPPowerDataType [-json]`.
- `notifyutil -g` (state read only).
- Directory listing of `/System/Library/FeatureFlags/Domain/`.
- Temporary Swift probes (sandboxed and unsandboxed) built in `/tmp` and since deleted.

**Third-party claims:** none relied on. The search-result summaries from MacRumors, Apple Community and others were not used as evidence.
