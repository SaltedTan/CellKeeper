# 06 — Safety Analysis for Battery-Control Operations

- **Date:** 2026-10-06
- **Status:** Research input for the lead engineer. Nothing here is a decision yet. The rules in section 4 are written so they can be turned into requirements and tests.
- **Scope:** Charge ceiling, resume threshold/hysteresis ("sailing range"), enabling and disabling charging, discharge-to-target (forced discharge on AC), temperature-based charge protection, temporary top-up to 100%, calibration, and scheduling. The target is macOS laptops (Apple silicon first; Intel noted where it differs).
- **Evidence labels used throughout:**
  - **[S]** Sourced fact. Reference numbers like [3] point to the Sources section. Only URLs that were actually fetched are cited.
  - **[I]** Engineering inference. It is reasonable but not directly sourced.
  - **[O]** Open question. It needs hardware testing or more research.
  - **Evidence strength:** *Strong* means peer-reviewed or manufacturer-primary and consistent across sources. *Moderate* means one good source, or one that depends on chemistry or conditions. *Weak* means secondary or popular sources, or sources that contradict themselves.

---

## Summary

- **Main finding: CellKeeper's realistic hazards are about availability and longevity, not fire, as long as it only ever *restricts* charging.** The pack's gauge/BMS enforces over-voltage, over-/under-temperature, over-current, and under-voltage protections in hardware and firmware, independent of user software [S, 13]. CellKeeper's levers are inhibiting charging and temporarily disabling the adapter. Neither can push a cell past those limits [I]. The worst credible outcomes are: the Mac dies when the user expected it to be charged; the battery drains while the user believes it is on AC; the battery is left deeply discharged; a bug silently stops the feature from working; or a privileged helper is abused. **Strong recommendation:** treat "CellKeeper never makes charging *less* conservative than macOS would by default, and never writes charge-voltage, charge-current, protection, or gauge-configuration parameters" as an architectural invariant.
- **Degradation science supports the core feature, with caveats.** Calendar aging rises with storage temperature and with high state of charge. It does this in chemistry-dependent *steps*, not linearly. In NCA/NMC cells the largest step is around 60% SoC [S, 14]. Cycling in a high SoC window ages cells faster than cycling the same depth in a low window [S, 15]. Larger depth of discharge increases fade [S, 16]. Charging at low temperature, high rate, or high SoC promotes lithium plating [S, 17]. Apple's own features (Optimized Battery Charging, battery health management, and the native Charge Limit) rest on the same premise [S, 3, 4].
- **macOS now has a native Charge Limit.** It needs macOS Tahoe 26.4 or later on Apple silicon. It covers 80–100% and resumes charging after a drop of more than 5% [S, 3]. CellKeeper must detect it and coexist with it. Its main safety-relevant differentiators are limits below 80%, temperature pausing, and discharge-to-target. Discharge-to-target is also the riskiest feature.
- **Calibration does not need a full discharge.** TI Impedance Track gauges update chemical capacity (Qmax) from two relaxed OCV readings separated by at least 37% passed charge, taken at 10–40 °C. Qmax can also update at a valid full-charge termination [S, 12, 11]. Apple says Macs "occasionally charge to 100% to maintain accurate battery state-of-charge estimates" [S, 3]. A calibration workflow should never run the battery to shutdown.
- **Top 5 hazards** (section 3):
  1. Forced discharge left on, so the battery drains while the user thinks the Mac is plugged in.
  2. An OS or firmware update changes what control keys mean, or wrong or unknown keys get written.
  3. Charging left disabled or never resuming (crash, uninstall, policy bug, stale telemetry).
  4. Compromise of the privileged helper.
  5. Several controllers fighting (other apps or macOS), with a UI that shows *intended* rather than *actual* state.
- **Recommended defaults:**

  | Setting | Default | Allowed range / constraint |
  |---|---|---|
  | Charge limit | 80% | 20–100% |
  | Hysteresis | 5 percentage points | 3–20 pp |
  | Critical floor (charging always allowed) | 10% | 5–20% |
  | Discharge-to-target floor | 20% | at least floor + 10 pp |
  | Temperature pause / resume | 40 °C / 35 °C | at least 3 °C apart |
  | Top-up | 12 h | 1–48 h, ends on unplug |
  | Forced-discharge lease | 120 s | — |
  | Non-safety control transitions | at most 1 per 60 s and 20 per hour | — |
  | Stale-telemetry limit | 60 s (SoC/AC), 120 s (temperature) | — |

---

## 1. Lithium-ion degradation basics relevant to laptop packs

### 1.1 Calendar aging vs cycle aging

- **[S]** Degradation is usually split into two kinds. **Calendar aging** happens while the battery is at rest. **Cycle aging** happens while it is being used or charged. The order in which stresses occur (path dependence) also matters [17]. *Strong.*
- **[S]** Apple describes a battery's lifespan as depending on its "chemical age". Chemical age is shaped by factors "such as its temperature history and charging pattern" [4, 5]. *Strong (manufacturer).*
- **[S]** Apple defines a charge cycle as discharging 100% of capacity cumulatively, not necessarily in one go. Current Apple silicon MacBooks are rated to retain up to 80% of original capacity at 1000 cycles "under ideal conditions" [8, 2]. *Strong (manufacturer).*
- **[I]** A Mac that sits on AC most of the day accumulates few cycles. Its aging is dominated by calendar aging at whatever SoC and temperature it is held at. That is exactly the variable a charge limit changes.

### 1.2 High state of charge

- **[S]** Keil et al. (2016) stored NCA, NMC, and LFP 18650 cells at 16 SoC levels and 25/40/50 °C. Calendar aging "does not increase steadily with the SoC". Fade instead forms plateaus spanning 20–30% of capacity [14]. The main driver is low anode potential, which happens when graphite is more than ~50% lithiated. This promotes SEI growth and loss of cyclable lithium. For NCA/NMC there is a clear step at roughly 60% SoC. NMC faded much faster at 100% SoC, and NCA aged slightly faster above 90% [14]. The authors recommend avoiding high storage SoC and keeping the graphite less than 50% lithiated for long-term storage [14]. *Strong (peer-reviewed, open access), but the step positions depend on chemistry and cell design.*
- **[S]** Wikner & Thiringer (2018) ran three years of tests on graphite/NMC-LMO cells in 10%-wide SoC windows. They found two distinct aging regimes: low SoC windows aged much more slowly. "The battery will last much longer if used in the lower SOC intervals even when using higher C-rates" [15]. In their synthetic cases, a 40–90% window aged fastest. The same depth of discharge in a 0–50% window reached more than twice as many full cycle equivalents before 80% capacity retention. The authors conclude "the SOC level is more important than the C-rate" [15]. In calendar tests at 25 °C, storing at 15% SoC instead of 90% roughly tripled projected calendar life [15]. (The paper's sentence lists the two lifetimes, 10 and 32 years, in an order that looks transposed. Its stated conclusion is "triple".) *Strong (peer-reviewed), single chemistry.*
- **[S]** Edge et al. (2021, review) list high voltage/SoC as a trigger for SEI growth, lithium plating, and cathode structural change and decomposition. They note that lattice-oxygen oxidation "will only happen in the extremely high SoC range" [17]. *Strong (review).*
- **[S]** Apple: when storing long-term, "Do not fully charge or fully discharge your device's battery — charge it to around 50%". Storing fully charged "may lose some capacity" [1]. *Strong (manufacturer).*
- **[I]** Because of the plateau structure, the benefit of moving a limit from 100% to ~80% may be large or small depending on the actual cell chemistry. Below roughly 50–60%, the extra benefit per point probably shrinks while lost runtime keeps growing. Apple does not publish Mac cell chemistry **[O]**, so CellKeeper should not promise specific lifetime gains.

### 1.3 Temperature: high

- **[S]** Apple names 16–22 °C as the "ideal comfort zone". It says to avoid ambient temperatures above 35 °C, "which can permanently damage battery capacity", and that charging in high ambient temperatures "can damage it further". MacBooks "work best at 50° to 95° F (10° to 35° C) ambient temperatures" [1]. *Strong (manufacturer).*
- **[S]** In Keil et al., all three chemistries aged faster in storage as temperature rose from 25 to 40 to 50 °C. At 50 °C, fade was "substantially higher" and NMC showed a steep rise at 100% SoC [14]. This is the combined high-SoC plus high-temperature effect. *Strong.*
- **[S]** Preger et al. (2020, Sandia) note that across LFP, NCA, and NMC calendar-aging studies, "capacity fade consistently decreased with decreasing temperature". During *cycling*, however, the dependence is chemistry-specific. In 15–35 °C cycling, NMC fade *decreased* with rising temperature and NCA showed no strong dependence [16]. They reproduce Waldmann et al.'s result for NMC/LMO-graphite 18650s: lithium plating dominates below 25 °C and SEI growth above it [16]. (Waldmann was read via Preger and not fetched directly.) *Strong for calendar aging. Moderate and chemistry-dependent for cycling.*
- **[S]** Edge et al.: "High temperatures will accelerate the rate of degradation for all the mechanisms listed" for the cathode [17].
- **[I]** For a plugged-in laptop, the relevant regime is mostly calendar aging. Keeping the pack cooler and at lower SoC are both supported. A temperature-based pause during charging is reasonable because charging adds heat at a time when SoC is rising.

### 1.4 Temperature: low

- **[S]** Lithium plating is promoted by "Low temperatures, high SoC, high (charge) current, high cell voltage". It "can lead to dendrite growth, which can puncture the separator and cause an internal short circuit". Even at moderate charge rates, "below-freezing temperatures slow down the main intercalation reaction enough to cause plating" [17]. *Strong.*
- **[S]** Plating occurs only during charging. Calendar aging is slow at low temperature [17, 16]. *Strong.*
- **[S, secondary]** Battery University gives a typical Li-ion charge window of 0–45 °C, says there should be "No charge permitted below freezing", and recommends reduced current below 5 °C [24]. A Lenovo patent quoting the JEITA/BAJ notebook safety guidelines gives example ranges: charging inhibited below 0 °C and at or above 55 °C, with reduced current and voltage in 0–10 °C and 45–55 °C [22]. *Moderate (secondary sources; the original JEITA/BAJ document was not retrieved).*
- **[I]** Cold-charge protection is a firmware responsibility. It is implemented in the gauge's temperature ranges (section 2) and needs no CellKeeper logic. CellKeeper should not add a default low-temperature pause. A cold user with a low battery needs charge, and the firmware already limits it.

### 1.5 Depth of discharge (DoD)

- **[S]** Preger et al. found that for all cells studied (LFP, NCA, NMC; 40–60%, 20–80%, and 0–100% windows at 25 °C), "the rate of capacity fade increased with an increasing depth of discharge". NCA and NMC showed a sharper transition from partial to full DoD than LFP [16]. *Strong.*
- **[S]** Preger et al. attribute the DoD effect to "Greater volume change in the graphite during (de)intercalation", which causes microcracks, fresh SEI formation, and loss of lithium inventory [16]. Edge et al. list particle fracture among the principal mechanisms, triggered by low temperature and high current, and for NMC also by high SoC [17]. *Strong.*
- **[S, weak]** Battery University's DoD-versus-cycles table (for example NMC ~300 cycles at 100% DoD vs ~1,000 at 40%) is widely quoted. The article itself notes contradictions between its own tables [25]. *Weak. Do not quote numbers in UI.*
- **[I]** For CellKeeper: discharge-to-target *adds* throughput (cycling) in exchange for lower resting SoC. That makes sense when the battery will then sit at the lower SoC for a long time, for example before storage or when moving from a 100% to a 60% limit. Repeated discharge-to-target on a schedule probably costs more than it saves. It should be a deliberate, one-shot action, not a routine **[I]**.

### 1.6 Charge rate

- **[S]** High charge current triggers lithium plating and particle fracture [17]. Wikner & Thiringer note currents above 3C rapidly degrade the cell they tested. They also found SoC window mattered more than C-rate within their test range [15]. *Strong (mechanism); moderate (magnitude).*
- **[S]** Apple's charging "uses fast charging to quickly reach 80% of its capacity, then switches to slower trickle charging" [2].
- **[S]** The gauge computes ChargingVoltage() and ChargingCurrent() per temperature range and voltage range. In TI's generic defaults, the High Temp range (30–55 °C) lowers charge voltage to 4.00 V/cell from 4.20 V and cuts current [13].
- **[I]** CellKeeper does not and must not control charge rate. Charge rate is a firmware and charger function. It is mentioned here only so docs do not overclaim.

### 1.7 Folklore check

| Claim | Verdict | Evidence |
|---|---|---|
| "Fully discharge Li-ion regularly to keep it healthy." | **False** for Li-ion use. Apple: "no need to let it discharge 100% before recharging" [2]. Deep discharge in storage can render the battery "incapable of holding a charge" [1]. | Strong |
| "Keeping a laptop at 100% on AC is harmful." | **Partly true.** High SoC plus heat accelerates calendar aging [14, 15]. How much depends on chemistry. Apple itself limits time at full charge [3, 4]. | Strong (direction), moderate (magnitude) |
| "Each 0.1 V lower peak voltage doubles cycle life." | **Unreliable as stated.** Battery University's own prose and table disagree [25]. | Weak |
| "20–80% is always the optimum." | **Oversimplified.** The aging steps sit at chemistry-specific SoCs (~60% for NCA/NMC in [14]). Lower windows are generally better [15], but there is no universal magic number. | Moderate |
| "Low SoC is bad for the battery." | **Nuanced.** Moderate-to-low SoC gives the *lowest* calendar aging [14, 15]. *Deep* discharge, near or below cut-off especially in storage, is harmful [1]. | Strong |
| "The battery must be calibrated by running it to 0%." | **Not for Impedance Track gauges.** Qmax field updates need about 37% passed charge between relaxed rests [12, 11]. | Strong (TI), inference for Apple's specific gauge |
| "Cold is always good for batteries." | **Only for storage/calendar aging.** Charging cold causes plating [17]. Cycling optima can sit at 25–35 °C depending on chemistry [16]. | Strong |

---

## 2. Protections independent of user software

### 2.1 Which gauge is in the pack

- **[S, local observation]** On the lead's development machine (Mac16,1, Apple M4, macOS 27.0.1), `system_profiler SPPowerDataType` reports battery **Device Name: bq40z651**, firmware 0b00. A secondary source reports the TI bq20z451 in a 2015 13″ MacBook Pro [26].
- **[I]** The bq40z651 has no public TI datasheet; it looks like an Apple-specific variant. The closest public sibling is the **bq40z50-R2**, whose Technical Reference Manual (TRM) is summarized below [13]. **Everything in 2.2 describes what the bq40z50-R2 family *can* do, with TI's generic default thresholds. Apple's actual enabled features and thresholds are unknown [O].**

### 2.2 Gauge/BMS protections (TI bq40z50-R2 TRM, SLUUBK0B [13])

All sourced [S] from [13] unless noted otherwise. "Default" means TI's generic data-flash default, not Apple's configuration.

| Protection | Behaviour | TI generic default |
|---|---|---|
| Recoverable protections (general) | When triggered, "charging and/or discharging is disabled" (XCHG/XDSG). They resume once the condition recovers. Each protection can be enabled or disabled in data flash. | — |
| Cell overvoltage (COV) | Stops further charging. The threshold depends on temperature range and can be configured to escalate to a permanent failure (COVL). | 4300 mV/cell trip, 2 s delay, 3900 mV recovery |
| Cell undervoltage (CUV, CUVC) | Prevents further discharge. CUVC compensates for I×R. | 2500 mV trip, 3000 mV recovery |
| Overtemperature in charge (OTC) | Uses the *max* cell temperature while charging. | 55.0 °C trip, 2 s delay, 50.0 °C recovery |
| Undertemperature in charge (UTC) | Uses the *min* cell temperature while charging. | 0.0 °C trip, 5.0 °C recovery |
| Over/undertemperature in discharge, FET overtemperature | Separate protections in discharge/relax state and for the power FETs. | — |
| JEITA-style charge temperature ranges | Temperature is split into Under/Low/Standard-Low/Recommended/Standard-High/High/Over ranges, each with its own charge voltage and current. *Charge Inhibit* prevents charging from starting in the HT/OT/UT ranges. *Charge Suspend* stops charging that is already under way. | T1..T4 = 0/12/20/25/30/55 °C, hysteresis 1 °C. High-temp range charge voltage 4000 mV vs 4200 mV standard. |
| Overcharge (OC) | Stops charging if charge continues beyond FullChargeCapacity(). | — |
| Charge/precharge timeouts, over-charging-voltage/current checks | Present. | — |
| Permanent failures (SOV, SOT, SOTF, FET failures, etc.) | When tripped, "Precharge, charge, and discharge FETs are turned off". The FUSE pin can be driven to blow an in-line fuse for configured failures. All PF checks (except IFC/DFW) "are disabled until ManufacturingStatus()[PF] is set". | SOT 65.0 °C |
| Reserve capacity / termination voltage | Allows "a system to report zero energy, but still have enough reserve energy to perform a controlled shutdown or provide an extended sleep period". | Term Voltage 9000 mV (pack) |

**Implications [I]:**

- Software running on the host cannot push cells above COV or charge outside the OTC/UTC windows, provided the gauge keeps them enabled. **CellKeeper must never write anything that could change these** (rule R12).
- "0%" reported by macOS is a gauge-defined point *above* the true cell cut-off, with reserve for a controlled shutdown [13]. That makes the system-level low-battery behaviour the first line of defence during discharge-to-target. CUV is the last.
- The gauge's `Temperature()` can be set to report the min, max, or average of several thermistors [13]. What macOS exposes as "battery temperature", and how fresh it is, is **[O]**.

### 2.3 Mac firmware and macOS behaviour (sourced)

- **[S]** Battery health management (on by default) "may temporarily reduce your battery's maximum charge" based on temperature history and charging patterns [4, 5]. On Intel, users can turn off "Manage battery longevity" [5]. Status "Not Charging" can mean charging "temporarily paused … to extend the life of your battery". The battery "may drain to 93% or lower before it begins charging again" [6].
- **[S]** If Optimized Battery Charging is off and a Mac still won't charge past 80%, "the battery temperature may be too hot" [7]. Apple more generally: "Software may limit charging above 80% when the recommended battery temperatures are exceeded" [2].
- **[S]** Optimized Battery Charging (macOS 11+) learns the user's routine and may hold at 80%, showing "Charging On Hold". **Charge Limit** (macOS Tahoe 26.4+, Apple silicon) lets the user pick a limit between 80% and 100%. The Mac stops "within a few percentage points of the charge limit" and resumes if the level drops more than 5% while plugged in. "Charge to Full Now" overrides both. With either feature, the Mac "will occasionally charge to 100% to maintain accurate battery state-of-charge estimates" [3]. No time-to-full estimate is shown when the limit is below 100% [9].
- **[S]** After an Apple software update, a Mac "might recalibrate maximum battery capacity" and "might briefly run on battery power, even when connected to AC power" [4, 5].
- **[S]** With an underpowered adapter or a heavy load, a Mac can be plugged in and still not charge, or can draw from the battery [6].
- **[S]** Forced sleep cannot be vetoed by applications, only delayed (up to 30 s). Besides lid close or the Apple menu, "the system will also induce forced sleep under certain conditions, for example, a thermal emergency or a low battery" [10].
- **[S]** `hibernatemode = 3` is the default on portables. Memory is saved to disk and restored if "a power loss forces it to restore from hibernate image" (pmset(8), macOS 27.0.1, local man page [L1]). UPS halt-level settings "are not observed on a system with support for an internal battery" [L1].
- **[S]** On Apple silicon, Apple's guidance for power-related SMC issues is: "just restart it" [19].

### 2.4 What is *not* guaranteed by firmware

- **[I]** Nothing in firmware ensures that a user-space inhibit is lifted when the app that set it dies. Whether SMC charge-inhibit or adapter-disable states persist across helper exit, sleep, shutdown, and reboot is **[O, test per model]**.
- **[I]** The system's forced sleep at low battery protects against an uncontrolled power-off. It does not protect against the user's surprise and lost work when a battery drains while "plugged in".
- **[I]** Firmware protections bound safety. They do nothing for longevity or availability, which are CellKeeper's domain.
- **[S]** For context, IEEE 1625 (the laptop multi-cell battery standard, inactive since 2019) frames battery-system reliability as spanning "charge and discharge controls at the system, pack, and cell levels" plus end-user notification [28]. **[I]** CellKeeper adds a fourth, user-space layer above the system level. It should be designed so that its failure falls back to the layers below it (rule R1), never so that it weakens them.

---

## 3. Hazard analysis (FMEA)

**Scales (pre-mitigation):**

- **Severity (S):**
  - 1: cosmetic.
  - 2: inconvenience, or slight extra wear.
  - 3: unexpected loss of availability (Mac dies or sleeps unexpectedly, possible unsaved-work loss) or measurable extra wear.
  - 4: deep discharge, sustained abnormal battery stress, or root-level compromise.
  - 5: physical hazard (fire or swelling). The BMS should prevent this, and CellKeeper must never take an action that could contribute to it.
- **Likelihood (L):** 1 (remote) to 5 (frequent).
- **Detection (D):** 1 (detected automatically and immediately) to 5 (undetectable by user or software).
- **RPN** = S × L × D. Mitigations reference rules R1–R33 in section 4.

| # | Failure mode | Cause | Effect | S | L | D | RPN | Mitigation for CellKeeper |
|---|---|---|---|---|---|---|---|---|
| H1 | Charging left disabled after app crash, quit, uninstall, or update | Process killed or crashed while the inhibit is set. App dragged to Trash without running cleanup. Updater replaces the helper mid-state. Inhibit persists in SMC [O]. | User unplugs expecting a full battery and finds the Mac at its limit or lower. Mac may not charge until the next restart or reinstall. | 3 | 4 | 3 | 36 | R1 safe state; R2 restore on every helper start (launchd KeepAlive relaunches); R3 lease on inhibit; R4 restore on SIGTERM, quit, uninstall, and update; R18 clear inhibits on AC disconnect; R31 README recovery steps; R30 actual-state UI. |
| H2 | Adapter / forced discharge left enabled | Helper crash or hang during discharge-to-target. Policy bug. Missed AC or SoC events. Sleep entered with forced discharge on. | Battery drains while the user believes they are on AC. Forced sleep at low battery [10]. Lost work. If the Mac is left unattended, deep discharge. | 4 | 3 | 4 | **48** | R3 short lease (≤120 s) with auto-restore; R5 hard floor; R6 discharge lower bound; R16 cancel forced discharge before sleep; R20 discharge only while awake and supervised; R30 distinct menu-bar state; notifications at start, end, and abort. |
| H3 | Charging never resumes (policy bug or stale telemetry) | Off-by-one in the resume comparison. SoC reading frozen. Resume threshold above the limit due to bad config. Event subscription lost after wake. | Battery slowly drains under load while "plugged in" (if the adapter is insufficient) or never reaches the limit. Silent failure. | 3 | 3 | 4 | 36 | R5 floor override; R9 telemetry max-age leads to safe state; R10 cross-check SoC against charging-current direction; R17 re-evaluate on wake; R24 config validation; property-based tests of the policy state machine. |
| H4 | Rapid toggling / oscillation | Zero or tiny hysteresis. SoC jitter or gauge FCC re-estimation jumps. Competing writers. Temperature hovering at a threshold. | Charger churn, log spam, extra micro-cycles, possible audible coil noise. No evidence of cell harm from SMC writes themselves [I]. | 2 | 3 | 2 | 12 | R7 minimum hysteresis; R13 rate limits and dwell time; R14 debounce on two consecutive samples; temperature hysteresis plus dwell (R21). |
| H5 | Writing a wrong value or an unknown hardware key | Key table mismatch for the model. Endianness or type error. Typo. Generic "write key" API. | Unknown behaviour. At best a no-op, at worst altered charging parameters or a persistent odd state. BMS protections still apply [13]. | 4 | 2 | 4 | 32 | R12 per-profile allowlist of keys and values, typed intents only, never voltage, current, protection, or gauge data flash; R11 read-back verify; R12a monitor-only mode on unknown hardware. |
| H6 | Firmware/OS update changes semantics | Apple changes SMC key meaning, value encoding, or adds its own policy (as with the native Charge Limit in 26.4 [3]). | Writes "succeed" but do nothing (feature silently off) or do something else (charging permanently off, conflicts). | 4 | 3 | 4 | **48** | R15 detect OS build, firmware, and battery changes, then re-probe read-only and drop to monitor-only until the profile is re-validated; R11 read-back plus behavioural verification (charge current goes to ~0 after inhibit); R10 plausibility; publish a compatibility matrix. |
| H7 | Sleep while charging overshoots the limit | User-space can't run while asleep. Charging was enabled at sleep entry below the limit. | Battery charges past the limit, possibly to 100%. Minor longevity cost. | 2 | 5 | 2 | 20 | R16 at sleep entry, inhibit if SoC ≥ resume threshold; document the overshoot; R17 log the overshoot on wake; consider delegating ≥80% limits to the native Charge Limit [3] (whether it enforces during sleep is **[O]**). |
| H8 | Mac sleeps or shuts down at low charge during discharge-to-target | Target set too low. Floor not enforced. Telemetry stale. User walks away. | Forced sleep or hibernation [10, L1]. Lost work. Deep-discharge risk if left. | 3 | 3 | 2 | 18 | R6 target ≥ max(20%, floor + 10); R5 floor; R16 cancel forced discharge at sleep; R20 supervision; R9 stale leads to cancel. |
| H9 | Temperature sensor unavailable or stale | Key or property missing on a model. Reading frozen after wake. Implausible values. Which sensor is reported is unclear [13]. | Temperature protection silently doesn't protect, or pauses charging forever on a bogus high reading. | 2 | 3 | 4 | 24 | R9/R10 freshness and plausibility; R21 on stale or implausible temperature, suspend the temperature feature (*no* pause) and warn; firmware OTC/JEITA still apply [13]; never let a temperature pause block the floor (R5). |
| H10 | Invalid user configuration | Hand-edited prefs, corrupted file, migration bug, MDM profile, UI bug. Examples: resume ≥ limit, floor ≥ limit, T_resume ≥ T_pause, top-up of 0 h. | Oscillation, charging never resumes, or nonsensical behaviour. | 3 | 3 | 2 | 18 | R24 schema plus cross-field validation in the **helper as well as the UI**; reject leads to last-known-good or safe state; R28 helper re-validates bounds. |
| H11 | Conflicts with macOS OBC, Charge Limit, or battery health management | Two policies active. macOS "Charging On Hold" or a BHM pause mistaken by CellKeeper for its own state or for a fault. "Charge to Full Now" vs CellKeeper inhibit. | Confusing behaviour ("why is it at 80% when I set 90%?"). CellKeeper might "fight" macOS. | 2 | 4 | 3 | 24 | R25 restrictive-only invariant (effective limit = the lower of the two); R26 detect and display macOS features; never counteract macOS holds; docs explain the interplay; behaviour of "Charge to Full Now" with a CellKeeper inhibit is **[O]**. |
| H12 | Calibration that requires a full discharge | Naive "calibrate = run to 0%" design. | Deep discharge, forced sleep, extra wear for no benefit [12]. | 3 | 2 | 2 | 12 | R23 calibration never goes below max(floor, 15%); based on Qmax rules (≥37% passed charge, relaxed rests, 10–40 °C) [12]; user-initiated, abortable, and abort leads to safe state. |
| H13 | Multiple battery apps fighting | Another tool or script writes the same SMC keys. | Oscillation, unpredictable state, each app blaming the other. Neither app's UI is truthful. | 3 | 3 | 4 | 36 | R27 detect external modification (read-back differs from last write and the change wasn't CellKeeper's), then stop writing, go to safe state, and notify; single-writer design inside CellKeeper (only the helper writes). |
| H14 | Time or clock changes affecting schedules | Manual clock change, NTP jump, time-zone travel, DST, sleep across a schedule boundary. | A schedule fires twice, never fires, or a top-up never expires. | 2 | 3 | 3 | 18 | R22 schedules are level-triggered against wall clock and re-evaluated on clock change [18], time-zone change, and wake; durations (top-up, leases) use a monotonic clock that counts sleep (`CLOCK_MONOTONIC` [L2]); schedules cannot bypass floors. |
| H15 | Helper compromise | Unauthenticated XPC; generic key-write API; injection via config; vulnerable dependency; malicious update. | Local privilege escalation. Persistent manipulation (charging held disabled indefinitely, forced discharge to empty). Denial of service. | 4 | 2 | 5 | 40 | R28/R29 code-signing requirement on XPC peers [20]; typed minimal API; helper-side bounds validation; SMAppService/launchd-managed daemon [21]; least privilege, minimal dependencies, no shell-outs [23]; signed and notarized updates; independent security review. |
| H16 | CellKeeper interferes with Apple's post-update recalibration | macOS runs on battery while on AC [4]. CellKeeper interprets that as a fault or "stuck" forced discharge and writes to the adapter key. | Apple calibration disrupted; capacity estimate possibly less accurate; confusing state. | 2 | 3 | 4 | 24 | R26 only act on state CellKeeper itself commanded (read-back of its own keys); log unexplained discharge on AC but don't "correct" it. |
| H17 | UI shows intended rather than actual state | UI binds to the policy target, not read-back. Helper unreachable. | User trusts a false status: thinks it is charging when it isn't, or thinks it is limited when it isn't. | 3 | 3 | 4 | 36 | R30 UI shows read-back hardware state and telemetry age; explicit "monitor-only", "degraded", and "helper unavailable" states. |

**Ranking (by RPN plus judgement):** H2 and H6 (48), H15 (40), then H1, H3, H13, and H17 (36). H5 is folded into H6 because their mitigations overlap.

---

## 4. Recommended safety rules for CellKeeper

Each rule is written to be testable. "Safe state" means: **every CellKeeper-controlled charge inhibit is cleared and forced discharge / adapter-disable is off.** In other words, macOS and firmware default charging behaviour. Every error path must converge on the safe state.

### A. Fail-safe direction and state ownership

1. **R1 — Fail-safe direction.** Any error, unknown state, or loss of supervision results in the safe state. *Test:* inject each error class (telemetry stale, write failure, read-back mismatch, XPC loss, config invalid, unknown hardware). Read-back must show the safe state within 5 s, or within 5 s of helper relaunch.
2. **R2 — Restore on start.** On every helper start (boot, launchd relaunch, update), the helper first restores the safe state. It re-applies policy only after (a) the hardware profile is recognized, (b) fresh valid telemetry is available, and (c) config validates. *Test:* `kill -9` the helper with an inhibit or forced discharge active. After relaunch the state is safe before any policy write.
3. **R3 — Leases (dead-man switch).** Every non-default control state is held under a lease. If the policy loop does not renew it, the helper restores the safe state. Forced-discharge lease: ≤ 120 s. Charge-inhibit lease: ≤ 15 min. *Test:* freeze the policy loop. The state reverts within the lease plus 5 s.
4. **R4 — Graceful exit and uninstall.** On SIGTERM, user "Quit and restore normal charging", update, or uninstall, the helper restores the safe state *before* exiting or unregistering (`SMAppService.unregister` [21]). Uninstall is a first-class flow, not "drag to Trash". *Test:* each path ends with read-back showing the safe state.

### B. Hard bounds and floors

5. **R5 — Critical floor overrides everything.** If SoC ≤ floor (default 10%, allowed 5–20%), CellKeeper removes its own inhibit and cancels forced discharge. This overrides policy, schedules, temperature pause, calibration, and discharge-to-target. The override holds until SoC ≥ floor + 5 pp. *Test:* simulated SoC at the floor in every mode leads to the safe state.
6. **R6 — Discharge lower bound.** The discharge-to-target target must be ≥ max(20%, floor + 10 pp) and ≤ 95%. Forced discharge also stops on reaching the target, on AC disconnect, at sleep entry, on stale telemetry, or when the temperature pause triggers.
7. **R7 — Limit and hysteresis bounds.** Charge limit 20–100% (warn below 50%). Hysteresis 3–20 pp. Resume threshold = limit − hysteresis, and must be ≥ floor + 5 pp. A limit of 100% means "CellKeeper inactive for limiting".
8. **R8 — Restrictive-only invariant.** CellKeeper's only control outputs are "inhibit charging" and "temporarily disable adapter". It never commands charging that macOS or firmware would withhold. It never raises any limit above the macOS default. "Top-up" only removes CellKeeper's *own* restriction. *Test:* code audit; the helper API has no other control verbs.

### C. Telemetry

9. **R9 — Freshness.** SoC, AC state, and charging state must be ≤ 60 s old. Temperature must be ≤ 120 s old. After wake, all telemetry is stale until a fresh sample arrives. Stale SoC/AC means safe state. Stale temperature means the temperature feature is suspended (rule R21).
10. **R10 — Plausibility and cross-checks.** Reject SoC outside 0–100, temperature outside −20…80 °C, and voltage outside the pack's plausible range. Flag inconsistencies: "inhibited" but charge current > threshold for more than 2 min, or "charging" but SoC falling for more than 10 min on AC. An inconsistency means safe state plus degraded mode plus a user notice.

### D. Control writes

11. **R11 — Verify every write.** Each write is followed by a read-back within 2 s. Where measurable, a behavioural check follows within 2 min (charge current drops to about zero after an inhibit; the battery shows discharge after adapter-disable). If the check fails, retry once, then go to safe state plus degraded mode (no further non-safety writes until user acknowledgement or a 1 h backoff).
12. **R12 — Allowlist only.** The helper writes only keys and values in a per-profile allowlist keyed by model identifier, OS build family, and firmware/key signature. It **never** writes keys affecting charge voltage, charge current, protection thresholds, or gauge configuration. It never sends gauge commands (unseal, data flash, Qmax reset).
    - **R12a:** unknown profile means monitor-only mode, with zero writes.
13. **R13 — Rate limits.** Non-safety state transitions: ≥ 60 s dwell per control, ≤ 20 per hour in total. Exceeding either means safe state plus degraded mode plus a log entry. Safety restores (R1, R5) are never rate-limited.
14. **R14 — Debounce.** A threshold crossing must be seen on 2 consecutive fresh samples before acting, except for floor and safety triggers.
15. **R15 — Change detection.** On an OS build change, SMC/firmware version change, or battery change (device name, serial, or design capacity), switch to monitor-only and re-run read-only capability probing. Resume control only if the profile matches a validated entry.

### E. Lifecycle events

16. **R16 — Sleep entry** (`kIOMessageSystemWillSleep` [10]). Always cancel forced discharge. If SoC ≥ resume threshold, set or keep the inhibit (this limits overshoot). Otherwise leave charging enabled and accept the overshoot. Acknowledge promptly; never try to veto forced sleep (it isn't possible [10]).
17. **R17 — Wake** (`kIOMessageSystemHasPoweredOn` [10]). Mark telemetry stale (R9) and re-evaluate policy from scratch (level-triggered). Log any overshoot or undershoot that happened during sleep.
18. **R18 — AC transitions** (`IOPSNotificationCreateRunLoopSource` [27] plus polling). On AC disconnect: cancel forced discharge, end top-up, and clear inhibits, so a later plug-in charges normally even if CellKeeper has died. On AC connect: evaluate policy before applying any inhibit. A brief initial charge is acceptable.
19. **R19 — App quit semantics.** If the policy engine lives in the UI process, quitting the UI leads to the safe state. If it lives in the helper, quitting the UI must not leave the user blind: the menu-bar status, or a notification "CellKeeper is still limiting charging", must make it visible, and "Quit and restore normal charging" must be offered.

### F. Discharge-to-target

20. **R20 — Supervised, opt-in, one-shot.** Discharge-to-target requires explicit per-use confirmation, runs only while the Mac is awake and the helper is healthy, and shows a persistent, distinct indicator. It is never started by a schedule unless the user explicitly enabled scheduled discharge with a warning. It ends at the target, then sails (no repeated cycling).

### G. Temperature protection

21. **R21 — Temperature pause.**
    - Pause charging at T_pause (default 40 °C, allowed 35–45 °C). Resume at T_resume (default 35 °C). T_pause − T_resume must be ≥ 3 °C. Minimum dwell is 5 min in each state.
    - Forced discharge is also suspended while paused, because an idle battery on AC is the lowest-stress state [I].
    - The pause never overrides R5.
    - On stale or implausible temperature, the feature is suspended (no pause) and the user is told "temperature protection unavailable".
    - No default low-temperature pause, because the firmware handles it [13].

### H. Top-up, schedules, calibration

22. **R22 — Time handling.** Durations (top-up expiry, leases, dwell) use a monotonic clock that counts sleep (`CLOCK_MONOTONIC` [L2]). Schedules are evaluated level-triggered against local wall-clock time, and re-evaluated on `NSSystemClockDidChange` [18], time-zone change, and wake. Missed schedule edges are never "replayed". A schedule can only select among validated configurations and cannot disable floors.
23. **R23 — Top-up and calibration.**
    - **Top-up** is one-shot. It lifts CellKeeper's limit to 100% and expires on AC disconnect, after a timeout (default 12 h, allowed 1–48 h), or on cancel. After that, CellKeeper sails down naturally and does not force a discharge unless the user opts in.
    - **Calibration** is user-initiated and abortable. It never discharges below max(floor, 15%). It aborts outside 10–40 °C [12] or on unexpected AC changes. Abort means the safe state.
    - An optional periodic full charge (to give the gauge a valid charge termination [12]) should be offered. Apple does this itself [3]; the interval is **[O]**.

### I. Coexistence

24. **R24 — Config validation.** Schema plus cross-field checks: resume < limit; resume ≥ floor + 5; discharge target ≥ max(20, floor + 10); T_resume ≤ T_pause − 3; all values within the ranges in the defaults table. These checks are enforced in the UI **and** re-enforced in the helper. If validation fails at load, keep the last-known-good config. If there is none, use the safe state plus a notice.
25. **R25 — Effective limit.** When macOS limiting is active (Charge Limit, OBC hold, BHM pause, or temperature limiting), the effective behaviour is the *more restrictive* of the two. CellKeeper displays both and never claims to override macOS.
26. **R26 — Don't fight macOS.** CellKeeper acts only on state it commanded itself. It never issues writes to counteract an unexplained macOS hold or "on battery while on AC" (for example Apple's post-update calibration [4]). It logs these instead.
27. **R27 — External-writer detection.** If read-back of a CellKeeper-controlled key differs from CellKeeper's last write without a CellKeeper action, stop all writes, go to the safe state, and notify ("another tool may be controlling charging").

### J. Security

28. **R28 — Narrow, authenticated helper API.**
    - XPC only, with `setCodeSigningRequirement` pinned to CellKeeper's Team ID and bundle identifier [20].
    - Typed intents only (`setChargeInhibit(Bool, reason)`, `setForcedDischarge(Bool, reason, lease)`, `restoreSafeState()`, read-only telemetry). There is no raw key/value write.
    - The helper independently validates all bounds, so a compromised UI still cannot violate R5–R8.
29. **R29 — Helper hygiene.** The helper is a launchd daemon registered via SMAppService [21]. It runs with hardened runtime and minimal dependencies, makes no shell-outs or external tool execution [23], has no network access, and parses no untrusted file formats beyond its own versioned config. Updates are signed and notarized. An independent security review is done before 1.0 [23].

### K. Logging, audit, UI honesty

30. **R30 — Truthful UI.** The UI shows read-back hardware state, telemetry age, and mode (active, monitor-only, degraded, safe, helper unavailable). Forced discharge has a distinct menu-bar icon plus a notification at start, end, and abort.
31. **R31 — Recovery path documented.** README and in-app help give a "charging won't resume" procedure: open CellKeeper → Restore normal charging → uninstall via the in-app uninstaller → restart the Mac (Apple silicon guidance for power issues [19]; whether a restart clears CellKeeper-written state is **[O]**).
32. **R32 — Audit log.** Every control write and safe-state transition is logged with:
    - wall-clock and monotonic timestamps;
    - the rule ID or reason;
    - inputs (SoC, temperature, AC, charging current, telemetry ages);
    - old and new value, and the read-back result;
    - the OS build and hardware profile.

    Logs go through unified logging (os_log) plus a rotating local file (default 14 days, allowed 1–90). They are never sent off-device. A user can export a diagnostics bundle.
33. **R33 — Testability.** The backend sits behind an interface with a simulated implementation, so R1–R32 can be fault-injection tested in CI without hardware. A hardware test matrix (per model and OS build) must verify persistence behaviour (O1) before any write is enabled on a profile.

---

## 5. Recommended defaults and validation ranges

| Parameter | Default | Allowed range / constraint | Justification |
|---|---|---|---|
| Charge limit | 80% | 20–100%; warn < 50% | Apple's native limit is 80–100% [3]. High-SoC calendar aging [14, 15]. Below ~50% gives little extra benefit and costs runtime [I]. Storage use case ~50% [1]. |
| Hysteresis (limit → resume) | 5 pp | 3–20 pp | Apple resumes after a > 5% drop [3]. BHM allows ~7 pp (to 93%) [6]. 3 pp minimum gives margin over 1% reporting granularity and gauge jumps [I]. |
| Critical floor | 10% | 5–20% | Gauge "0%" keeps only a shutdown reserve [13]. Deep discharge is harmful [1]. Forced sleep at low battery [10]. |
| Floor exit hysteresis | +5 pp | fixed | Prevents oscillation at the floor [I]. |
| Discharge-to-target minimum | 20% | ≥ max(20%, floor + 10); ≤ 95% | Stays clear of forced sleep and deep discharge [10, 1]. |
| Forced-discharge lease | 120 s | 30–300 s (developer setting) | Bounds H2 if supervision is lost [I]. |
| Charge-inhibit lease | 15 min | 1–60 min (developer setting) | Bounds H1 if the policy loop hangs [I]. |
| Temperature pause | 40 °C | 35–45 °C | Apple: > 35 °C ambient damages capacity [1]. Faster aging at 40 °C [14]. Firmware OTC (TI default 55 °C) remains the hard limit [13]. |
| Temperature resume | 35 °C | ≤ T_pause − 3 °C; ≥ 30 °C | Hysteresis prevents oscillation. TI uses hysteresis on its temperature ranges too [13]. |
| Temperature dwell | 5 min | 1–15 min | Thermal time constants are minutes [I]. |
| Low-temperature pause | Off | Not offered by default | Firmware UTC/JEITA handles it [13, 22]. |
| Telemetry max age | 60 s (SoC/AC/charging), 120 s (temperature) | fixed | [I]. Poll every 30 s plus IOPS event notifications [27]. |
| Read-back timeout | 2 s | fixed | [I] |
| Non-safety transition rate | ≥ 60 s dwell; ≤ 20 per hour | fixed | Defence-in-depth against H4/H13 [I]. |
| Top-up expiry | 12 h, or AC disconnect | 1–48 h | Covers an overnight charge before travel. Mirrors Apple's "until tomorrow" pattern [3] [I]. |
| Calibration minimum SoC | 15% | ≥ max(floor, 15%) | Qmax needs ≥ 37% delta, not 0% [12]. |
| Calibration temperature window | 10–40 °C | fixed | TI Qmax update window [12]. |
| Log retention | 14 days | 1–90 days | [I] |
| Unknown hardware or OS profile | Monitor-only | — | H5/H6 |

---

## 6. Proposed user-facing disclaimers and warnings

Tone: factual, short, not alarmist. Suggested text:

**README / About (short form):**

> CellKeeper helps you keep your Mac's battery at a lower charge level when you don't need a full charge, which research and Apple's own battery features suggest can slow battery aging. It can only make charging *more conservative* than macOS would by default — it cannot override your Mac's built-in battery protections, and it does not change charging voltage or current.
>
> Battery aging depends on many factors (temperature, usage, cell chemistry), so we can't promise a specific improvement. All batteries are consumable and will lose capacity over time.
>
> CellKeeper uses undocumented hardware interfaces. Apple may change them in any macOS or firmware update; when CellKeeper detects a change it stops controlling charging and switches to monitor-only until it's been verified. CellKeeper is not affiliated with or endorsed by Apple. It is provided under its open-source license without warranty.

**First-run / enabling control:**

> While CellKeeper is limiting charging, your Mac may show "Not Charging" even though it's plugged in. That's expected. If you need a full battery, use **Top up to 100%** before you leave.
>
> macOS has its own battery features (Optimized Battery Charging, Charge Limit, battery health management). They can also stop charging early. When both are active, the lower limit wins.

**Discharge-to-target confirmation:**

> Your Mac will run on battery while plugged in until it reaches **N%**. This uses battery cycles, so it's best for occasional use (for example before storing your Mac or lowering your limit). CellKeeper stops automatically at the target, if you unplug, if your Mac goes to sleep, or if the battery gets too warm. Don't leave your Mac unattended with this running.

**Temperature protection:**

> Charging pauses when the battery reaches **40 °C** and resumes at **35 °C**. Your Mac's built-in protections still apply at all temperatures. If CellKeeper can't read the battery temperature, it will tell you and temperature-based pausing will be off.

**Low-limit warning (limit < 50%):**

> Limits below 50% give relatively little extra battery-aging benefit but leave you much less runtime when you unplug.

**Troubleshooting / uninstall (README):**

> **If your Mac won't charge:** open CellKeeper and choose **Restore normal charging**. If CellKeeper won't open, use the uninstaller (or `CellKeeper.app → Uninstall`) rather than dragging the app to the Trash, because the uninstaller restores normal charging first. If charging still doesn't resume, restart your Mac. *(Lead: confirm the restart step per model once O1 is tested.)*

---

## 7. Open questions

- **O1 — Persistence (test per model and OS).** Do SMC charge-inhibit and adapter-disable states persist across helper exit, sleep, deep sleep/hibernate, shutdown, reboot, and (Intel) SMC reset? This determines how serious H1/H2 really are and whether R31's "restart" advice is valid.
- **O2 — Temperature telemetry.** Which temperature does macOS expose (the gauge's `Temperature()` can be min, max, or average of thermistors [13]), at what update interval, and is it available on every supported model?
- **O3 — Native Charge Limit interplay.** Does macOS's Charge Limit enforce during sleep and shutdown? What happens to "Charge to Full Now" when CellKeeper holds an inhibit? Can CellKeeper read whether the native limit and OBC are enabled through a supported API?
- **O4 — Apple's gauge configuration.** Which protections and thresholds are enabled in Apple's bq40z651 configuration? (Only TI's generic bq40z50-R2 defaults are sourced.)
- **O5 — Low-battery behaviour.** At what SoC does macOS force sleep on each model? Does a forced-discharge state survive into sleep, so the battery could drain to hibernation?
- **O6 — Gauge accuracy under long-term limiting.** Without regular full charges, does SoC/FCC estimation drift enough to make "80%" inaccurate? What interval does Apple use for its "occasional" 100% charge [3]?
- **O7 — BHM learning.** Does Apple's battery health management adapt to CellKeeper-shaped charging patterns in ways that compound limits, or that affect the "Service Recommended" calculation? (The Intel article notes the service calculation assumes the feature is continuously enabled [5].)
- **O8 — Cell chemistry.** Apple doesn't publish Mac cell chemistry. The SoC positions of the calendar-aging steps [14] are therefore unknown for these packs, which limits how precise the default limit's justification can be.
- **O9 — Forced-discharge limits.** Does firmware limit forced-discharge rate or block it by temperature, and does it behave differently on low-wattage adapters?
- **O10 — Policy engine location.** Should the policy loop live in the helper (survives UI quit; larger privileged code) or in the UI (smaller privileged surface; quitting means safe state)? This is a security vs availability trade-off for the lead (see R19, R29).

---

## Sources

All URLs below were fetched during this research on 2026-10-06. Items marked *(secondary)* are reputable but not primary; *(weak)* sources are used only with caveats.

**Apple**

1. Apple — Batteries: Maximizing Battery Life and Lifespan. https://www.apple.com/batteries/maximizing-performance/
2. Apple — Batteries: Why Lithium-ion? https://www.apple.com/batteries/why-lithium-ion/
3. Apple Support — About Optimized Battery Charging and Charge Limit on Mac (102338, published 2026-04-06). https://support.apple.com/en-us/102338
4. Apple Support — About battery health management in Mac laptops with Apple silicon (102589). https://support.apple.com/en-us/102589
5. Apple Support — About battery health management in Intel-based Mac laptops (102588). https://support.apple.com/en-us/102588
6. Apple Support — If your Mac battery status is "Not Charging". https://support.apple.com/guide/mac-help/if-your-battery-status-is-not-charging-mh20876/mac
7. Apple Support — If your Mac battery won't charge completely. https://support.apple.com/guide/mac-help/if-your-battery-wont-charge-completely-mchlbfb7e12a/mac
8. Apple Support — Determine battery cycle count for Mac laptops (102888). https://support.apple.com/en-us/102888
9. Apple Support — Monitor your Mac laptop's battery. https://support.apple.com/guide/mac-help/mchlp1115/mac
10. Apple Developer — Technical Q&A QA1340: Registering and unregistering for sleep and wake notifications. https://developer.apple.com/library/archive/qa/qa1340/_index.html

**Fuel gauge (Texas Instruments)**

11. TI — Impedance Track Gas Gauge for Novices (SLUA375). https://www.ti.com/lit/pdf/slua375. Qmax from two relaxed OCV readings (dV/dt < 4 µV/s) with passed charge > 37% of design capacity.
12. TI — Achieving The Successful Learning Cycle (SLUA903). https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/196/Achieving-the-Successful-Learning-Cycle.pdf. Relaxation ~2 h charged / ~5 h discharged. Qmax not updated outside 10–40 °C or with < 37% delta capacity in field updates. Update at valid charge termination when DOD0 is valid.
13. TI — bq40z50-R2 Technical Reference Manual (SLUUBK0B, rev. Oct 2018). https://www.ti.com/lit/ug/sluubk0b/sluubk0b.pdf. Protections (ch. 2), permanent fails (ch. 3), advanced charge algorithm and temperature ranges (ch. 4), reserve capacity / Term Voltage (ch. 6), data-flash defaults (ch. 15).

**Peer-reviewed literature**

14. Keil P., Schuster S.F., Wilhelm J., Travi J., Hauser A., Karl R.C., Jossen A. "Calendar Aging of Lithium-Ion Batteries: I. Impact of the Graphite Anode on Capacity Fade." *J. Electrochem. Soc.* 163(9):A1872–A1880 (2016). doi:10.1149/2.0411609jes. https://iopscience.iop.org/article/10.1149/2.0411609jes
15. Wikner E., Thiringer T. "Extending Battery Lifetime by Avoiding High SOC." *Applied Sciences* 8(10):1825 (2018). doi:10.3390/app8101825. Full text read from https://mdpi-res.com/d_attachment/applsci/applsci-08-01825/article_deploy/applsci-08-01825-v2.pdf (the MDPI HTML page returned HTTP 403).
16. Preger Y. et al. "Degradation of Commercial Lithium-Ion Cells as a Function of Chemistry and Cycling Conditions." *J. Electrochem. Soc.* 167:120532 (2020). doi:10.1149/1945-7111/abae37. https://www.osti.gov/biblio/1650174 (accepted manuscript: https://www.osti.gov/servlets/purl/1650174). Also the source for the Waldmann et al. (2014) plating-vs-SEI temperature result, which was cited via this paper and not fetched directly.
17. Edge J.S. et al. "Lithium ion battery degradation: what you need to know." *Phys. Chem. Chem. Phys.* 23:8200–8221 (2021). doi:10.1039/d1cp00359c. https://spiral.imperial.ac.uk/handle/10044/1/88300 (full text via the repository bitstream https://spiral.imperial.ac.uk/bitstreams/a36faa4a-412e-4271-9a7d-c3336c2fd11a/download). Table 3 maps mechanisms to temperature, SoC, and current triggers.

**Platform documentation, standards, and secondary sources**

18. Apple Developer — `NSSystemClockDidChange`. https://developer.apple.com/tutorials/data/documentation/foundation/nsnotification/name-swift.struct/nssystemclockdidchange.json
19. Apple Support — If your Mac sleeps or wakes unexpectedly (SMC note: "If you have a Mac with Apple silicon, just restart it"). https://support.apple.com/guide/mac-help/if-your-mac-sleeps-or-wakes-unexpectedly-mchlp2995/mac
20. Apple Developer — `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13+). https://developer.apple.com/tutorials/data/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:).json
21. Apple Developer — `SMAppService` (macOS 13+). https://developer.apple.com/documentation/servicemanagement/smappservice. Content read via https://developer.apple.com/tutorials/data/documentation/servicemanagement/smappservice.json.
22. *(secondary)* Lenovo patent US8203314B2, "Surface temperature dependent battery cell charging system". It quotes the JEITA/BAJ notebook Li-ion safety guidelines' temperature ranges (0/10/45/55 °C) and per-range current and voltage limits. https://patents.google.com/patent/US8203314. The original JEITA/BAJ guide was not retrieved.
23. Apple — Secure Coding Guide: Elevating Privileges Safely. https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/AccessControl.html
24. *(secondary)* Battery University BU-410, Charging at High and Low Temperatures. https://batteryuniversity.com/article/bu-410-charging-at-high-and-low-temperatures
25. *(weak)* Battery University BU-808, How to Prolong Lithium-based Batteries. https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries. Internally inconsistent tables; used only in the folklore check.
26. *(weak, secondary)* Kaspars Dambis, "MacBook Battery Time Remaining". Reports a TI BQ20Z451 in a 2015 13″ MacBook Pro. https://kaspars.net/blog/macbook-battery-remaining
27. Apple Developer — `IOPSNotificationCreateRunLoopSource`. https://developer.apple.com/tutorials/data/documentation/iokit/1523868-iopsnotificationcreaterunloopsou.json
28. IEEE SA — IEEE 1625-2008, Standard for Rechargeable Batteries for Multi-Cell Mobile Computing Devices (status: Inactive-Reserved since 2019-11-07). It covers charge and discharge controls at system, pack, and cell level, and end-user notification. https://standards.ieee.org/ieee/1625/4382/. Context only; the standard's text was not reviewed.

**Local references (read on the development machine, macOS 27.0.1, read-only)**

- **L1.** `pmset(8)` man page: hibernatemode defaults on portables; UPS halt settings not observed on laptops.
- **L2.** `clock_gettime(3)` man page: `CLOCK_MONOTONIC` "will continue to increment while the system is asleep"; `CLOCK_UPTIME_RAW` does not.
- **Local observation:** `system_profiler SPPowerDataType` on Mac16,1 reports battery gauge Device Name `bq40z651`, firmware `0b00`.

*Not used as sources, per project rules:* proprietary battery-management apps' materials and designs.
