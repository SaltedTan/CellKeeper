# 13 — Faster power readings from the SMC, read-only

- **Date:** 2026-10-21
- **Status:** Design, for review; not built. On 2026-10-21 the owner found
  the menu's power flow (D114), which updates once a minute, "not too
  helpful". They asked for about 3 s updates while they look at it, and to
  consider the SMC. After the read-only check in §4, they chose the SMC
  route with a reader they write themselves (§5), then paused new work,
  and resumed it the same day.
- **Machine:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (26A434),
  system firmware mBoot-20457.1.29, as in notes 09–12.
- **Labels:** as in [note 06](06-safety-analysis.md):
  - **[S]** a sourced statement, with its source number (§9);
  - **[I]** an inference;
  - **[O]** an open question.

  `[VERIFIED-EXPERIMENTALLY]` marks an observation on this Mac, made
  read-only.

---

## Summary

- **The menu's power flow is slow because of its source, not because of
  CellKeeper.** macOS refreshes the AppleSmartBattery values the flow
  reads once a minute ([note 01](01-battery-telemetry.md), observation 13).
  A full registry scan found no faster power value outside the SMC (§2).
- **The SMC has the same quantities, about once a second.** The owner read
  five keys by hand, read-only (§4):
  - `PDTR`, the adapter's input power, changed every second;
  - `PSTR`, the Mac's total power, followed it one second late;
  - the once-a-minute registry value was a snapshot of `PDTR`;
  - the battery's voltage key matched the registry's.

  The values are little-endian. The readings jump by about ±5 W from
  second to second, so a short average reads better.
- **Not yet known:** the sign of the battery's power and current keys
  while charging and while on battery (O1). The owner can settle it with
  the same read-only check during the calibration's drain and final
  charge.
- **What it takes**, decided by the owner (§5):
  - **A reader the owner writes.** Agents do not write SMC client code,
    reads included, since 2026-10-20 (note 11 §2.2). The owner writes one
    small read-only reader against an interface CellKeeper defines (§6.1).
    CellKeeper builds everything above it.
  - **A sandbox exception** for the SMC's user-client class (§6.3).
  - **A narrow clean-room exception** for the facts about five read-only
    keys (§5).
- **Display only, as before.** The values never steer charging. Without
  the reader, or if a read fails, the flow falls back to macOS's
  once-a-minute data (§6.2).

---

## 1. Why

The power flow (D114) shows the adapter's input, the Mac's use and the
battery's charge or discharge, from two undocumented AppleSmartBattery
values (`PowerTelemetryData.SystemPowerIn`, `.SystemLoad`) and the
battery's voltage × current. On this Mac those values change only when
the driver's `UpdateTime` changes, every 60 s
`[VERIFIED-EXPERIMENTALLY]` (note 01, observation 13).

The menu reads every 3 s while the section is shown, but that only picks
up a new value sooner; it cannot make the values change faster. The owner
asked for updates about every 3 s while they look at the flow, and less
often otherwise.

## 2. Sources that were ruled out

- **The rest of the I/O registry.** `[VERIFIED-EXPERIMENTALLY]`, by the
  lead on 2026-10-21. Two full `ioreg -l` dumps 3 s apart: no power,
  current or voltage value changed outside AppleSmartBattery's
  once-a-minute update.
  - **What did change:** only counters and statistics.
  - **`PowerDistribution.IPDInputPower`:** 67 800 mW, the adapter's
    negotiated power, constant.
- **`powermetrics`** needs root. CellKeeper has none, and agents never run
  `sudo` (note 04).
- **IOReport** is a private framework. As far as is known its energy
  channels cover the chip's own parts, not the adapter or the battery
  [I]. It was not explored further.

## 3. The keys (third-party claims, then this Mac)

Five read-only keys cover the flow. On Apple silicon none is documented
by Apple; the names and meanings come from open-source projects, and §4
checks them on this Mac.

| Key | Claimed meaning | Claimed type | Sources | Status here |
|---|---|---|---|---|
| `PDTR` | Adapter input power: "AC Input Power" [S1], "DC-In total power" [S3] | IEEE-754 float, W [S2]; Intel tables list 2-byte fixed point [S3] | S1, S2, S3 | Read; `flt `, 4 bytes, W (§4) |
| `PSTR` | "Total System Power" [S1]; "System Total Power Consumed (Delayed 1 Second)" [S3] | float, W [S2] | S1, S2, S3 | Read; `flt `, W; one second behind `PDTR` (§4) |
| `B0AP` | Battery power | signed 32-bit, mW [S2] | S2 | Read; `si32`; 0 at rest; sign open (O1) |
| `B0AC` | Battery current | signed 16-bit, mA [S2, S3] | S2, S3 | Read; `si16`; 0 at rest; sign open (O1) |
| `B0AV` | Battery voltage | unsigned 16-bit, mV [S2, S3] | S2, S3 | Read; `ui16`, little-endian, 13 190 mV, matching the registry (§4) |

- **Types disagree** between the Intel-era table [S3] and the Asahi
  driver [S2]. On this Mac the tool reported the types `flt `, `si32`,
  `si16` and `ui16`, matching S2. CellKeeper checks each key's reported
  type and size before decoding, and refuses anything else (§6.2).
- **Not used:**
  - `PPBR`, which one Intel table [S3] lists as battery or PBus power, and
    which S2 never reads;
  - the adapter's voltage and current keys, `VD0R` and `ID0R` [S1, S3],
    which `PDTR` makes unnecessary;
  - the legacy adapter keys `AC-n` and `AC-i`, which S2 says firmware for
    macOS 15.4 and later dropped.
- **Licences:** S1 is GPL-2.0+ OR MIT, S2 is GPL-2.0-only OR MIT, and S3 is
  BSD-3-Clause (its repository's). CellKeeper takes facts only: key names,
  meanings, types and units. No code or text is taken (§5).

## 4. The owner's read-only check (2026-10-21) `[VERIFIED-EXPERIMENTALLY]`

**How.** The owner ran the existing open-source `smc` tool, from
smcFanControl (GPL-2.0, the build used for note 11), by hand. It read
`PDTR PSTR B0AP B0AC B0AV`, with a read-only `ioreg` of the registry
values, about once a second for 30 samples. That was from 14:03:47 to
14:04:18 AEDT, with the Mac on the adapter at 100% and not charging, in
the calibration's rest at the top (note 12). No agent ran the tool. The
lead decoded the saved output; the file stays on the owner's Mac.

| Quantity | What it read |
|---|---|
| `PDTR` (adapter input) | 7.42–19.26 W; **a different value in all 30 samples** |
| `PSTR` (the Mac's use) | Equal to the previous sample's `PDTR` in 26 of 29 samples |
| `B0AP`, `B0AC` | 0 throughout (battery at rest) |
| `B0AV` | 13 189–13 190 mV (the registry's `Voltage` read 13 225 mV earlier that day) |
| Registry `SystemPowerIn` = `SystemLoad` | 11 486 mW, then 8 560 mW at the next `UpdateTime`, 60 s later |

**Findings:**
1. **`PDTR` updates about once a second**, against once a minute for the
   registry. The SMC's own update rate below one second was not measured:
   the samples were about 1 s apart.
2. **`PSTR` is `PDTR` one second late** while the battery is idle. That
   matches S3's "Delayed 1 Second". With the battery at rest, the input
   and the use are the same power.
3. **The registry value looks like a snapshot of `PDTR`.** Its update
   stamped 14:04:03 read 8 560 mW; `PDTR` read 8.56 W at 14:04:02 and
   8.57 W at 14:04:03. The fast and slow sources agree, and one is sampled
   more often [I, from one update: the earlier one, 11 486 mW at
   14:03:03, came before the samples began].
4. **The values are little-endian.**
   - `B0AV`'s bytes `86 33` are 13 190 mV read low byte first, which
     matches the registry.
   - The tool printed 34 355, reading them high byte first, a convention
     of Intel-era SMCs. Its float output also drops the decimals.
   - CellKeeper must decode the raw bytes itself (§6.2).
5. **The readings are noisy.** `PDTR` averaged 11.6 W, with a standard
   deviation of 3.3 W, and moved by up to 11.5 W from one second to the
   next. A display that changes every 3 s should show the average of those
   seconds, not one reading.

**Not settled by this check:**
- what `B0AP` and `B0AC` read while charging and while on battery, and
  with which sign (O1);
- whether `PDTR` reads near 0 on battery (O2).

## 5. Owner decisions (2026-10-21)

- **The route.** The owner chose to read the SMC, with a reader they write
  themselves ("A"), over staying with once a minute.
- **Who writes what.**
  - **Agents:** everything above a narrow interface (§6.1).
  - **The owner:** the reader below it, which opens the SMC's user client
    and reads one key.

  The reason: agents stopped writing SMC client code on 2026-10-20, when
  a safety check stopped an agent's write client, and the lead extended
  that to read clients, which share almost all their code (note 11 §2.2).
  The owner chose this boundary there for writes, and here for reads.
- **For the owner to confirm with this design:**
  - **(a) The clean-room exception.** Facts only, for these five
    read-only keys: name, meaning, type, size and unit. They come from
    S1–S3 and are checked on this Mac. No code, comments or structure is
    taken from any project. It is like note 11's exception for `CHIE`.
  - **(b) The sandbox exception** of §6.3.
  - **(c) The reader's contract** in §6.1.

## 6. Design

### 6.1 The boundary: the owner's reader

CellKeeper defines, in its own code:
- **`SMCPowerKey`:** an enumeration of exactly the five keys. The reader
  can be asked for nothing else, so CellKeeper can never name another
  key.
- **`SMCRawValue`:** the key's four-character type, as the SMC reports it,
  and its bytes, undecoded.
- **`SMCPowerKeyReading`:** a protocol with one method, which reads one
  key and returns its raw value or throws.
- **The errors:** the SMC is unavailable or could not be opened (for
  example, refused by the sandbox), the key was not found, or the read
  failed.

The owner writes one file, in its own target, conforming to that
protocol. Its contract:
- **Read-only.** It asks for a key's information and reads its bytes,
  nothing else.
  - It contains no write command.
  - It does not enumerate the key table.
  - It does not read any key other than the one asked for.
- **It opens and closes the user client itself.** Reads are not shared
  with anything else.
- **No root, no helper.** It runs in the app, in the sandbox.
- **No logging of values,** and no identifiers read.
- **From the owner's own knowledge, Apple's public IOKit documentation and
  the interface facts in note 11 §3.2.** No code taken from any project.
- **Its header says the owner wrote it,** so the clean-room record stays
  true.

GPT reviews it like any other code, but gives its findings in prose and
proposes no replacement code.

### 6.2 Above the boundary (CellKeeper)

- **Decoding.** Each key's value is accepted only with its expected type
  and size:
  - `flt ` and 4 bytes for `PDTR` and `PSTR`;
  - `si32` and 4 for `B0AP`;
  - `si16` and 2 for `B0AC`;
  - `ui16` and 2 for `B0AV`.

  All are decoded little-endian. Anything else makes the key unavailable,
  never a guessed value.
- **Plausibility.** Each value is discarded outside a sane range: for
  example, input and use 0–500 W, and battery power within ±300 W.
- **The flow from the SMC.** A new `PowerFlowReading`, which D114's seam
  was built for:
  - **adapter input:** `PDTR`, while on external power;
  - **Mac use:** `PSTR`;
  - **battery:** `B0AP` once O1 confirms its sign. Until then, voltage ×
    current from the registry, as today.
- **Cadence and averaging.**
  - While the menu is open and the section expanded, the SMC is read about
    once a second. The diagram updates every 3 s, showing the average of
    those readings. The chart keeps its 10 s points.
  - Collapsed or closed, nothing is read from the SMC. The once-a-minute
    registry data keeps the chart going, as today.
- **Fallback.** No reader, the SMC refused, a key missing, a type
  mismatch or repeated failures each switch the flow back to the
  registry. The footnote then says which source is shown ("updated about
  once a minute" or "updated every few seconds").
- **Display only** (D114). The policy, the controller and the safety rules
  never see these values.
- **Diagnostics.** The power flow's source is named; no raw SMC bytes
  appear.

### 6.3 The sandbox exception

- **Why it is needed.** CellKeeper runs in the App Sandbox, which allows
  opening only listed user-client classes. The SMC's is not among them
  (note 05 §1.2, §1.5).
- **The exception.** Apple's temporary exception
  `com.apple.security.temporary-exception.iokit-user-client-class` takes
  the class names to allow [S4]. In the system profile it expands to
  allowing `iokit-open-user-client` and `iokit-set-properties` for those
  classes (note 05 §1.2). The class here is `AppleSMCClient`, as the
  registry showed on this Mac (note 11 §9).
- **What it costs.**
  - **The App Store:** CellKeeper would not qualify (note 05 §1.5). It is
    not distributed there.
  - **The sandbox:** the app could open the SMC's user client. If
    CellKeeper were compromised, an attacker could read SMC keys. Writes
    are reportedly refused to processes without root, but that is
    unverified, and no one will test it: CellKeeper never attempts a write
    [I].
  - **CI:** its check of the signed app's exact entitlements gains this one
    entry, and note 05 records it.
- **Whether it works is open (O3).** This needs a sandboxed, ad-hoc-signed
  build on macOS 27. It is tested with the owner's reader in the isolated
  `.preview` build after the calibration, when launching a build is safe
  again.

### 6.4 Cost, privacy and failure

- **Cost:** five small reads a second, only while the section is shown.
- **Privacy:** no identifiers. The values live in memory only, like
  D114's history.
- **A read that hangs.** The menu's single-flight reader (D114) has at
  most one read in flight, so a hang stops updates without piling up
  reads. Quitting stops the reads, as today.
- **Reads cannot change charging,** and no write path exists in the
  reader.

## 7. Plan

1. **Owner:** the same read-only check twice more: on battery during the
   calibration's drain, and while charging in its final step. That
   settles O1 and O2.
2. **Review:** GPT reviews this design. The owner then confirms §5 (a)–(c)
   and the decisions are recorded here.
3. **Agents build everything above the boundary** with a fake reader:
   - decoding, the SMC flow source, the 1 s reads and 3 s averages, the
     fallback;
   - the entitlement and CI check;
   - CONTRIBUTING's clean-room exception, D114's update and note 05.

   This is a pull request with GPT review. Until the owner's reader
   exists, the app keeps the registry source.
4. **Owner:** writes the reader against §6.1. GPT reviews it, in prose.
5. **After the calibration:**
   - the owner tries the `.preview` build to settle O3;
   - then they try the app itself, which also covers the power flow
     checks from D114 still pending on a Mac.

## 8. Open questions

- **O1.** What sign do `B0AP` and `B0AC` take while charging and while on
  battery, and does `B0AP` match voltage × current?
- **O2.** Does `PDTR` read near 0 on battery? A third-party report has it
  near 0.27 W with an adapter attached [unverified], which the fallback
  and plausibility rules must tolerate.
- **O3.** Does the temporary exception let a sandboxed, ad-hoc-signed
  CellKeeper open `AppleSMCClient` on macOS 27, and read without root?
- **O4.** Do the keys and their types hold across other Apple-silicon
  Macs and macOS versions? The design refuses anything unexpected, so a
  different Mac falls back to the registry rather than showing wrong
  values.

## 9. Sources

- **S1** — Linux, `arch/arm64/boot/dts/apple/hwmon-common.dtsi`:
  https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/apple/hwmon-common.dtsi
  (GPL-2.0+ OR MIT). Supports: `PSTR` "Total System Power", `PDTR` "AC
  Input Power", `VD0R` "AC Input Voltage", `ID0R` "AC Input Current", as
  sensors "expected on all systems".
- **S2** — Asahi Linux, `drivers/power/supply/macsmc-power.c`:
  https://github.com/AsahiLinux/linux/blob/asahi/drivers/power/supply/macsmc-power.c
  (GPL-2.0-only OR MIT). Supports:
  - `B0AV` read as u16 (voltage), `B0AC` as s16 (current), `B0AP` as s32
    (power);
  - `PDTR` and `PSTR` read as IEEE-754 floats (watts);
  - "macOS 15.4+ firmware dropped legacy AC keys (AC-n, AC-i)".

  It does not document a sign convention.
- **S3** — acidanthera VirtualSMC, `Docs/SMCSensorKeys.txt`:
  https://github.com/acidanthera/VirtualSMC/blob/master/Docs/SMCSensorKeys.txt
  (repository BSD-3-Clause; Intel-era key tables). Supports:
  - `PSTR` "System Total Power Consumed (Delayed 1 Second)";
  - `PDTR` "DC-In total power";
  - `PPBR` "PBus on battery power";
  - `B0AC` "Battery Actual current", `B0AV` "Battery Actual Voltage".

  Types there are Intel fixed-point.
- **S4** — Apple, "App Sandbox Temporary Exception Entitlements" (archived
  Entitlement Key Reference, 2017):
  https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html
  Supports: `com.apple.security.temporary-exception.iokit-user-client-class`,
  "Ability to specify additional IOUserClient subclasses to open or to set
  properties on"; the value is "a string or an array of one or more
  strings".
