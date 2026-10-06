# 03 — Intel Macs: charging-control differences and support lifecycle

- **Date:** 2026-10-06
- **Scope:** documentary research. No Intel hardware was available, so nothing here was tested on Intel. No SMC access, no privileged commands, and no proprietary-binary inspection were performed. This complements `02-charging-control-apple-silicon.md`; its tag legend, evidence grades (A–E, X) and safe-verification protocol apply here too.

---

## Summary

1. **Apple's position:**
   - **macOS Tahoe 26 is the last macOS for Intel.** Apple said at WWDC25's Platforms State of the Union: "macOS Tahoe will be the final release for Intel Macs." (I1)
   - **macOS 27 "Golden Gate" runs on no Intel Mac.** Apple's macOS 27 page lists only Apple-silicon Macs and the A18 Pro MacBook Neo (I2). It has shipped: this dev machine runs 27.0.1.
2. **Only two Intel laptops can run macOS 26, and both are T2 Macs.**
   - Apple's Tahoe compatibility list includes four Intel models: MacBook Pro 16-inch 2019, MacBook Pro 13-inch 2020 (Four Thunderbolt 3 ports), iMac 27-inch 2020 and Mac Pro 2019 (I3).
   - Only the two MacBook Pros have batteries. Both are in Apple's T2 list, which covers "MacBook Pro introduced in 2018 through 2020, excluding … M1" (I4).
   - In practice, a CellKeeper Intel target on macOS 26 means **two T2 MacBook Pro models**.
3. **Apple's native Charge Limit is Apple-silicon-only** ("Requires macOS Tahoe 26.4 or later and a Mac with Apple silicon", I5). Intel laptops have:
   - **Battery health management** ("Manage battery longevity", macOS 10.15.5+, Thunderbolt 3 laptops). It "may temporarily reduce your battery's maximum charge" (I6).
   - **Optimized Battery Charging**: Apple lists only "macOS Big Sur 11 or later" with no architecture restriction (I5).
   - **No public API** to control either. The macOS SDK check in 02 applies to both architectures.
4. **Intel's reported private mechanism is the SMC key `BCLM`** ("battery charge level max"), together with `BFCL` for the MagSafe LED.
   - **Behaviour:** it reportedly takes a percentage, and macOS reportedly charges a few percent beyond the set value.
   - **Privilege:** writes need root; reads do not.
   - **Persistence:** it reportedly lives in the SMC until an SMC reset. A launch daemon is normally used to re-apply it.
   - **Status on macOS 15+:** the bclm project says BCLM "does not work on macOS >= 15.0 due to new entitlement enforcement from the kernel". It does not say whether that covers Intel. The failure reports seen were Apple-silicon `CHWA` errors.
   - **Classification:** `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: Intel]`, grade D, unverified.
5. **Apple's open-source battery driver for Intel** (`AppleSmartBatteryManager`, APSL-2.0) implements admin-gated **ChargeInhibit** and **InflowDisable** user-client selectors. powerd drives them through private, root-only power assertions that are released automatically when the owning process exits.
   - This is the most "Apple-native" private path on Intel.
   - Whether it actually inhibits charging on T2 Macs running macOS 26 is **unverified** (grade B for existence, unknown effect).
6. **Recommendation:** **no Intel charge-control backend.**
   - At most, ship **telemetry-only** support on Intel, and only if CellKeeper's deployment target includes macOS 26 and a universal build costs nothing extra. That support would use the public IOPowerSources APIs plus defensive unit handling (see 01).
   - If the deployment target is macOS 27, Intel is moot: CellKeeper cannot run there.

---

## Tag legend

Same as 02: `[PUBLIC-API]`, `[PRIVATE/UNDOCUMENTED]`, `[IOKIT]`, `[SMC/HW]`, `[PRIVILEGED]`, `[ARCH-SPECIFIC: AS/Intel]`, `[VERIFIED-EXPERIMENTALLY]` (read-only, this machine; nothing in this note qualifies, because no Intel hardware was used) and `[INFERRED/UNVERIFIED]`.

Evidence grades: A = Apple documentation; B = Apple open source; C = reviewed kernel work; D = corroborated community docs; E = single report or anecdote.

---

## Mechanism table (Intel)

| # | Mechanism | Purpose | Tags | Privilege | Persistence | Reported OS/firmware range | Evidence quality | Sources |
|---|---|---|---|---|---|---|---|---|
| 1 | **Battery health management** ("Manage battery longevity") | Analyses temperature and charging history; "may temporarily reduce your battery's maximum charge" | `[PUBLIC-API]` (user setting) `[ARCH-SPECIFIC: Intel]` | Interactive user. No API. | User setting. On by default. | macOS 10.15.5+ on Intel laptops (default-on after upgrade on Thunderbolt 3 laptops) | A | I6 |
| 2 | **"Not Charging" pause** by battery health management | Holds charge, then "may drain to 90% or lower before it begins charging again" | `[PUBLIC-API]` (documented behaviour) | n/a | n/a | Catalina-era article | A | I7 |
| 3 | **Optimized Battery Charging** | Learned 80% hold | `[PUBLIC-API]` (user setting) `[INFERRED/UNVERIFIED]` for Intel availability | Interactive user | User setting | macOS 11+ (no architecture restriction stated) | A (feature), inference (Intel) | I5 |
| 4 | **Charge Limit (80–100%)** | Fixed cap | `[PUBLIC-API]` `[ARCH-SPECIFIC: AS]`: **not available on Intel** | — | — | macOS 26.4+, Apple silicon only | A | I5 |
| 5 | **Public telemetry** (IOPowerSources, IOPMPowerSource keys) | Observe charging | `[PUBLIC-API][IOKIT]` | None | n/a | All. Units differ on Intel (mAh in the registry; see 01). | A/B | 02-S8, 01 |
| 6 | **SMC `BCLM`** | Charge ceiling as a percentage. Intel accepts arbitrary values; overshoot is about 3%. | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: Intel]` | Root to write; read unprivileged | Stays in SMC until an SMC reset. Re-applied by a launch daemon. Pre-T2 survives reboots (Linux report). | Intel laptops, roughly 2013–2020. macOS ≤14 widely used; macOS 15+ status unclear. | D | I8, I9, I11, I12 |
| 7 | **SMC `BFCL`** | MagSafe LED "final charge level" (cosmetic) | same as #6 | Root | As #6 | Intel laptops with a MagSafe LED | D | I9, I11 |
| 8 | **SMC `CH0B`/`CH0C`/`CHTE`/`ACLC` on Intel** | Charge inhibit / LED (claimed) | same as #6 | Root | Unknown | Listed only as "Not verified yet" constants in an unused Intel file of an AS tool | E | I13 |
| 9 | **SMC `CHCE` / `CHNC`** | Floated as possible inhibit / force-discharge keys on T2. Explicitly "unvalidated". | same as #6 | — | — | T2 (Linux) | E | I12 |
| 10 | **Private assertions `ChargeInhibit` / `DisableInflow`** → `AppleSmartBatteryManager` user client | Inhibit charging / disable AC inflow | `[PRIVATE/UNDOCUMENTED][IOKIT][PRIVILEGED]` | Root (assertion). Administrator (user client). | **Released when the owning process exits** | Defined in current Apple OSS. Effect on T2 + macOS 26 unknown. | B (existence); effect unknown | I14, I15 |
| 11 | **SMC reset** (Apple procedures differ for T2 vs non-T2) | Clears SMC runtime state, including any third-party key writes | `[PUBLIC-API]` (documented procedure) | User (key combos) | n/a | All Intel laptops | A | I16 |

---

## 1. Documented by Apple

### 1.1 Support lifecycle

- **WWDC25 Platforms State of the Union** (I1, transcript): "Apple silicon enables us all to achieve things that were previously unimaginable. And it's time to put all of our focus and innovation there." … "And so, macOS Tahoe will be the final release for Intel Macs." `[A]`
- **macOS 27 compatibility** (I2, apple.com/os/macos, which now describes macOS 27 Golden Gate):
  - The list is: MacBook Neo (2026); MacBook Air with Apple silicon (2020 and later); MacBook Pro with Apple silicon (2020 and later); iMac with Apple silicon (2021 and later); Mac mini with Apple silicon (2020 and later); Mac Studio (2022 and later); Mac Pro with Apple silicon (2023).
  - No Intel model is listed. Conclusion: **macOS 27 runs on no Intel Mac.** `[A]`
  - The page does not say "Intel" explicitly; the conclusion follows from the list.
- **macOS Tahoe 26 compatibility** (I3, Apple 122867, published 2026-09-14):
  - Among other models it lists "MacBook Pro (13-inch, 2020, Four Thunderbolt 3 ports)", "MacBook Pro (16-inch, 2019)", "iMac (Retina 5K, 27-inch, 2020)" and "Mac Pro (2019)". These are the only Intel entries; the page itself does not label architectures.
  - **T2 status:** Apple's T2 list (I4, published 2026-05-27) includes "MacBook Pro introduced in 2018 through 2020, excluding MacBook Pro (13-inch, M1, 2020)". So **both Intel laptops eligible for macOS 26 have a T2 chip**.
- **Security updates for Intel/Tahoe:**
  - The Apple pages fetched for this note give no commitment.
  - The press reports about three years of security updates, to roughly fall 2028. MacRumors states this and links to Apple's Rosetta page, but it is not a direct Apple quote (I10).
  - The Rosetta developer page could not be read (it renders with JavaScript only), so this remains **unverified**.

### 1.2 Battery features on Intel

- **Battery health management** (I6, Apple 102588, published 2026-09-15). It "applies only to Mac laptop computers with an Intel processor."
  - **When it is on:**
    - It is on by default for new laptops with macOS 10.15.5+, or after upgrading "on a Mac laptop with Thunderbolt 3 ports".
    - It works by "monitoring your battery's temperature history and charging patterns".
    - It "may temporarily reduce your battery's maximum charge".
  - **Turning it off:** the user deselects "Manage battery longevity". Apple warns "Turning this feature off might reduce your battery's lifespan."
  - **Service calculation:** the service-recommendation calculation "is based on the feature being continuously enabled".
  - **Inference:** a third-party limiter that asks users to disable this feature degrades Apple's service-health estimate.
- **"Not Charging"** (I7): one cause is that battery health management "temporarily paused charging". The battery "may drain to 90% or lower before it begins charging again".
- **Optimized Battery Charging** (I5): "Requires macOS Big Sur 11 or later", with no architecture restriction stated. Availability on Intel laptops is `[INFERRED/UNVERIFIED]` from that wording.
- **Charge Limit** (I5): "Requires macOS Tahoe 26.4 or later and a Mac with Apple silicon." It is **not available on Intel**.
- **SMC reset** (I16, Apple 102605):
  - **T2 laptops:** hold the power button for 10 s. If needed, hold left Control + left Option + right Shift for 7 s, then add the power button for 7 s.
  - **Non-T2 laptops:** hold left Shift + left Control + left Option + power for 10 s.
  - **Why it matters:** these procedures clear SMC state, which matters for the persistence of any SMC-key mechanism.

### 1.3 Apple open source (APSL-2.0) relevant to Intel

- **IOKitUser `IOPMLibPrivate.h`** (I14) defines the private assertion types `DisableInflow` ("Disables AC Power Inflow (requires root to initiate)") and `ChargeInhibit` ("Disables battery charging (requires root to initiate)").
- **PowerManagement-1846.0.25.0.1** (I15):
  - **The Intel driver:** `AppleSmartBatteryManager` is Apple's SMBus "smart battery" driver lineage, which is the Intel-era driver.
  - **Admin check:** its user client exposes `kSBInflowDisable` and `kSBChargeInhibit` selectors. Each checks `kIOClientPrivilegeAdministrator` before calling `disableInflow()` / `inhibitCharging()`.
  - **Assertion forwarding:** pmconfigd raises and releases these through the private assertions.
  - **Release on exit:** pmconfigd releases all assertions of a dead process (`HandleProcessExit`).
- **Inference `[INFERRED/UNVERIFIED]`:**
  - On Intel, this path is more likely to be functional than on Apple silicon, because it is the driver it was written for.
  - Whether T2 MacBook Pros running macOS 26 honour it is unknown. No Apple documentation describes its supported use, and it is not a public API.

---

## 2. Third-party claims (unverified)

Licences: zackelia/bclm **MIT**; itsjoshpark/charge-limiter **GPL-3.0**; charlie0129/batt **GPL-2.0**; t2linux/linux-t2-patches and omacom/omarchy: licence not checked on the pages fetched. No code was copied.

### 2.1 `BCLM` / `BFCL`

- **bclm README** (I8):
  - It reads and writes "battery charge level max (BCLM)/CHWA values".
  - **Intel overshoot:** on Intel "macOS charges slightly beyond the set value (~3%)". Charging while shut down or asleep "can go beyond set value more than average 3%".
  - **Privilege:** writing "must be run as root. This is not required for reading values."
  - **Persistence:** `persist` installs a LaunchDaemon that re-applies the value. "The SMC can be reset by a startup shortcut or various other technical reasons."
  - **macOS 15+:** "BCLM does not work on macOS >= 15.0 due to new entitlement enforcement from the kernel …" This is not architecture-qualified. The linked failure reports are `keyNotFound(code: "CHWA")`, which is an Apple-silicon key (I9b). **Status on Intel + macOS 15/26 is unknown.**
- **itsjoshpark/charge-limiter** (I11; Intel-only):
  - `BCLM` "limits the charge of the battery to a set value". `BFCL` "controls the MagSafe LED indicator light".
  - It re-applies the value after restart, and setting 100 removes the persistence.
  - No macOS 15/26 claim is made.
- **batt** (I13) says Intel is not supported. Its README answer to "Will there be an Intel version?" notes that Intel can set `BCLM` with other tools.
  - Its unused `consts_amd64.go` lists `ACLC`, `AC-W`, `CH0B`, `CH0C`, `CHTE` and `bf*` as Intel keys, all marked "Not verified yet."

### 2.2 T2 vs non-T2

- **Under macOS:**
  - Apple's AppleSMC driver abstracts the transport, so no third-party source fetched describes a macOS-side BCLM difference between T2 and non-T2. On T2 Macs the SMC is reportedly hosted by the T2. That claim comes from a search summary only, so it is not cited.
  - Apple documents different SMC reset procedures for the two (I16).
- **Under Linux (context only):**
  - **Pre-T2:** pre-T2 SMCs expose `BCLM`/`BFCL` "over the legacy 0x300 I/O port". On a 2015 MacBookPro11,5 the 80% limit "lives in SMC firmware, not in a daemon" and persisted across reboots (I12b). The same issue claims T2 is "unreachable … (no SMC transport)" with stock kernels.
  - **T2 with t2linux patches:** a t2linux PR read `BCLM = 80` and accepted a write of 75 on a MacBookPro15,1, rejecting 0 and 101 (I12). It also called the inhibit/force-discharge keys `CHCE`/`CHNC` "unvalidated".
- **Inference:** `BCLM` exists on T2 MacBook Pros and accepts percentage values. Whether macOS 26 lets a root process write it is unverified.

---

## 3. Lead-agent inference

(This is the research agent's inference, for lead review.)

1. **The addressable Intel market is tiny and shrinking.**
   - On macOS 26, only two laptop models qualify, both 2019–2020 T2 MacBook Pros.
   - No Intel Mac runs macOS 27. Security updates for Tahoe end at an Apple-unspecified date; the press says about 2028.
   - Any Intel control backend would need its own hardware test matrix (T2 only), its own privileged helper path (`BCLM` or the battery-manager assertions), and its own failure modes. It would serve a population that is shrinking rapidly.
2. **Intel has no Apple-sanctioned limit equivalent to Charge Limit.** Battery health management and OBC are automatic. CellKeeper cannot drive them via public API, only tell users where the toggles are.
3. **Telemetry is nearly free** if CellKeeper builds universal and targets macOS 26, because IOPowerSources is architecture-neutral.
   - Unit differences need care: Intel registry capacities are in mAh, while Apple silicon reports percent (01).
   - Labelling Intel as "monitoring only" avoids promising control that cannot be verified.
4. **If the minimum OS is 27 (Apple silicon only), drop Intel entirely.** Do not ship x86_64 slices. This also avoids Rosetta concerns.

### Recommendation

- **Charge control on Intel: No.** Do not build an Intel SMC (`BCLM`) or assertion backend.
- **Telemetry on Intel:**
  - **Yes, read-only and best-effort**, only if the product's minimum OS is ≤ macOS 26 and a universal binary is otherwise required. Include a clear "monitoring only on Intel" message and link to Apple's "Manage battery longevity" / OBC settings.
  - **Otherwise neither.**
- **Revisit only if** an external contributor with T2 hardware volunteers to run the verification protocol (02 §7) for `BCLM` on macOS 26. The Intel-specific steps would be: allowlist only `BCLM` (and optionally `BFCL`), read size/type first, write one value derived from a reviewed design document (not copied from another tool), read back, confirm charging stops near the limit, then test persistence across sleep, reboot, shutdown and a documented SMC reset (I16). Those results should be reviewed before anything ships.

---

## 4. Risks (Intel-specific)

| Risk | Detail |
|---|---|
| Unknown macOS 15+/26 behaviour | `BCLM` may be blocked by "kernel entitlement enforcement" (I8). It might fail silently, leaving the user charging to 100% while CellKeeper claims a limit. |
| Overshoot and calibration | A ~3% overshoot, plus larger overshoot when off or asleep (I8). It also interacts with battery health management, which may lower the maximum charge on its own (I6). |
| Conflict with battery health management | Users are often told to disable "Manage battery longevity". Apple warns this "might reduce your battery's lifespan" and bases service estimates on it being enabled (I6). |
| Stale SMC state | An SMC reset clears the limit. Without a daemon, the limit silently disappears (I8, I16). |
| Test-coverage gap | No Intel hardware is available to the project, and only two eligible models exist. |
| End of platform | No macOS 27. The security-update horizon is unconfirmed by Apple. |

---

## 5. Open questions

1. Does `BCLM` remain writable by root on a T2 MacBook Pro running macOS 26.x? Does the "kernel entitlement enforcement" quoted by bclm apply to Intel?
2. Do the private `ChargeInhibit` / `DisableInflow` assertions inhibit charging on T2 MacBook Pros running macOS 26?
3. Is Optimized Battery Charging active on Intel laptops alongside battery health management? Apple's current OBC article is architecture-neutral.
4. What is Apple's actual security-update end date for macOS 26 on Intel?

---

## 6. Sources

All URLs were fetched during this research, unless marked as a local file.

**Apple**
- **I1** — WWDC25 Platforms State of the Union: https://developer.apple.com/videos/play/wwdc2025/102/. Supports: "macOS Tahoe will be the final release for Intel Macs."
- **I2** — Apple, macOS page (now describing macOS 27 Golden Gate): https://www.apple.com/os/macos/. Supports: the macOS 27 compatible-Mac list, which is Apple silicon plus MacBook Neo only.
- **I3** — Apple Support 122867, "macOS Tahoe 26 is compatible with these computers" (published 2026-09-14): https://support.apple.com/en-us/122867. Supports: the Intel models eligible for macOS 26.
- **I4** — Apple Support 103265, "Mac computers with the Apple T2 Security Chip" (published 2026-05-27): https://support.apple.com/en-us/103265. Supports: 2018–2020 Intel MacBook Pro/Air are T2.
- **I5** — Apple Support 102338, "About Optimized Battery Charging and Charge Limit on Mac" (published 2026-04-06): https://support.apple.com/en-us/102338. Supports: OBC requires macOS 11+; Charge Limit requires Apple silicon.
- **I6** — Apple Support 102588, "About battery health management in Intel-based Mac laptops" (published 2026-09-15): https://support.apple.com/en-us/102588. Supports: BHM behaviour, defaults, the warning, and the service-estimate dependency.
- **I7** — Apple, "If your Mac battery status is 'Not Charging'": https://support.apple.com/en-us/HT211246. Supports: the BHM pause and drain to 90%.
- **I16** — Apple Support 102605, "Reset the SMC of your Mac" (published 2025-12-08): https://support.apple.com/en-us/102605. Supports: T2 vs non-T2 reset procedures; SMC responsibilities.
- **I14** — apple-oss-distributions/IOKitUser `pwr_mgt.subproj/IOPMLibPrivate.h` (HEAD 323ead8): https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/pwr_mgt.subproj/IOPMLibPrivate.h. Supports: private assertion types, root requirement.
- **I15** — apple-oss-distributions/PowerManagement, tag PowerManagement-1846.0.25.0.1: https://github.com/apple-oss-distributions/PowerManagement (cloned). Supports: the `AppleSmartBatteryManagerUserClient` admin check; assertion forwarding; release on exit.

**Press**
- **I10** — MacRumors, "macOS 27 Will Mark the End of an Era" (2026-04-18): https://www.macrumors.com/2026/04/18/macos-27-compatibility-change/, and "Apple Says macOS 27 Won't Be Compatible With These Macs" (2026-06-03): https://www.macrumors.com/2026/06/03/macos-27-wont-run-on-these-macs/. Supports: Intel models dropped; the security-update horizon as stated by MacRumors (not an Apple quote); Rosetta "through macOS 27" quote.

**Third-party (claims — unverified)**
- **I8** — zackelia/bclm README (MIT): https://github.com/zackelia/bclm. Supports: Intel overshoot and the 77% advice; privilege; persist daemon; SMC reset caveat; macOS 15 entitlement statement.
- **I9** / **I9b** — zackelia/bclm issues #57 (https://github.com/zackelia/bclm/issues/57) and #49 (https://github.com/zackelia/bclm/issues/49). Supports: macOS 15 failures are `CHWA` (Apple-silicon) errors; Intel is not shown.
- **I11** — itsjoshpark/charge-limiter README (GPL-3.0): https://github.com/itsjoshpark/charge-limiter. Supports: `BCLM`/`BFCL` roles on Intel; re-apply on restart.
- **I12** — t2linux/linux-t2-patches PR #63 (2026-09-19, closed): https://github.com/t2linux/linux-t2-patches/pull/63. Supports: `BCLM` readable and writable as a percentage on a T2 MacBookPro15,1 under patched Linux; `CHCE`/`CHNC` "unvalidated".
- **I12b** — omacom/omarchy issue #11593 (2026-09-13): https://github.com/omacom/omarchy/issues/11593. Supports: pre-T2 `BCLM`/`BFCL` via I/O port 0x300; persistence across reboots; the claim that T2 is unreachable on a stock kernel.
- **I13** — charlie0129/batt README (GPL-2.0): https://github.com/charlie0129/batt, and the pkg.go.dev listing: https://pkg.go.dev/github.com/charlie0129/batt/pkg/smc. Supports: no Intel support; unverified Intel key constants.
