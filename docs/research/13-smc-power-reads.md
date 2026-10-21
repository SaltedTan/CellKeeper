# 13 — Faster power readings from the SMC, read-only

- **Date:** 2026-10-21
- **Status:** Design, for review; not built. On 2026-10-21 the owner found
  the menu's power flow (D114), which updates once a minute, "not too
  helpful". They asked for about 3 s updates while they look at it, and to
  consider the SMC. After the read-only check in §4 they chose the SMC
  route with a reader they write themselves (§5). They paused new work,
  then resumed it the same day. Revised after design review r1.
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

- **The power flow is slow because of its source.** macOS refreshes the
  AppleSmartBattery values the flow reads once a minute
  ([note 01](01-battery-telemetry.md), observation 13). A comparison of
  two registry dumps 3 s apart showed no other power value changing (§2).
- **The SMC changes faster.** In the owner's read-only check (§4):
  - `PDTR`, the adapter's input power, read differently in each of 30
    samples taken about a second apart. It changes at least that often;
    its own update rate was not measured.
  - With the battery idle, `PSTR`, the Mac's total power, matched the
    previous sample's `PDTR` in 26 of 29 comparisons. That is an apparent
    lag of one second in this run, not an established rule.
  - **[I]** The once-a-minute registry value looks like a snapshot of the
    same reading, from one update that matched.

  The readings swing by several watts from second to second, so a short
  average reads better.
- **Not yet known:**
  - the sign of the battery's power key while charging and on battery
    (O1);
  - whether a sandboxed build can open the SMC at all (O3).
- **The design (§6):**
  - **The owner's reader.** It reads at most three keys and nothing else.
    Agents do not write SMC client code, reads included (§5).
  - **CellKeeper's part:**
    - decoding with exact checks;
    - one batch a second, off the main actor;
    - a 3 s average;
    - a deadline for a hung read;
    - a fallback to macOS's once-a-minute data, and a way back;
    - a label on every displayed value saying where it came from.
  - **A build option.** All of it is off until the sandbox exception is
    shown to work.
- **Display only, as before (D114).** The values never steer charging,
  and nothing here touches the controller or the calibration.

---

## 1. Why

The power flow (D114) shows the adapter's input, the Mac's use and the
battery's charge or discharge. Its data comes from:
- two undocumented AppleSmartBattery values
  (`PowerTelemetryData.SystemPowerIn`, `.SystemLoad`);
- the battery's voltage × current;
- the adapter's negotiated `Watts`. On this Mac those
values change only when the driver's `UpdateTime` changes, every 60 s
`[VERIFIED-EXPERIMENTALLY]` (note 01, observation 13).

The menu reads every 3 s while the section is shown, but that only picks
up a new value sooner; it cannot make the values change faster. The owner
asked for updates about every 3 s while they look at the flow, and less
often otherwise.

## 2. Sources that were ruled out

- **The rest of the I/O registry.** `[VERIFIED-EXPERIMENTALLY]`, by the
  lead on 2026-10-21. Two full `ioreg -l` dumps were taken 3 s apart.
  - **What changed:** no power, current or voltage value changed between
    them outside AppleSmartBattery; only counters and statistics did.
    `PowerDistribution.IPDInputPower` stayed at 67 800 mW, the adapter's
    negotiated power.
  - **What that shows:** only what changed between those two dumps. It
    does not rule out every faster registry value [I].
- **`powermetrics`** needs root ([note 01](01-battery-telemetry.md)).
  CellKeeper has none, and agents never run `sudo` (note 11 §2.2).
- **IOReport** is a private framework. As far as is known, its energy
  channels cover the chip's own parts, not the adapter or the battery
  [I]. It was not explored further.

## 3. The keys (third-party claims, then this Mac)

Apple documents none of these keys for Apple silicon. Their names and
meanings come from open-source projects; §4 says what was seen on this
Mac.

| Key | Claimed meaning | Claimed type | Sources | Seen here (§4) | Used by CellKeeper |
|---|---|---|---|---|---|
| `PDTR` | Adapter input power: "AC Input Power" [S1] | IEEE-754 float, W [S2] | S1, S2; Intel tables list 2-byte fixed point [S3] | `flt `, 4 bytes, W; varied every sample | Yes |
| `PSTR` | "Total System Power" [S1] | float, W [S2] | S1, S2; Intel-era "System Total Power Consumed (Delayed 1 Second)" [S3] | `flt `, 4 bytes, W | Yes |
| `B0AP` | Battery power | signed 32-bit, mW [S2] | S2 | `si32`; 0 throughout (idle) | Only once O1 settles its sign |
| `B0AC` | Battery current | signed 16-bit [S2] | S2; S3 lists both signed and unsigned entries, labelled A and mA | `si16`; 0 throughout | No: the owner's checks only (O1) |
| `B0AV` | Battery voltage | unsigned 16-bit, mV [S2] | S2; S3 lists unsigned integer entries, labelled mV and V | `ui16`; 13 190 mV read low byte first | No: the owner's checks only (O1) |

- **Types.** S2, the Apple-silicon driver, gives the types above.
  - **`PDTR` and `PSTR`:** S3's Intel-era tables disagree, listing 2-byte
    fixed point.
  - **The battery keys:** S3 agrees, listing `B0AV` as an unsigned 16-bit
    integer and `B0AC` as a signed 16-bit one. It also has an unsigned
    entry for `B0AC`, and its unit labels conflict (A and mA, mV and V). On this Mac the tool reported
  the types S2 gives. CellKeeper checks each key's reported type and exact
  length before decoding, and refuses anything else (§6.3).
- **Not used:**
  - `PPBR`, which S3 lists as battery or PBus power and S2 never reads;
  - the adapter's voltage and current keys `VD0R` and `ID0R` [S1, S3];
  - the legacy adapter keys `AC-n` and `AC-i`, which S2 says firmware for
    macOS 15.4 and later dropped.
- **Licences.** S1 is GPL-2.0+ OR MIT; S2 is GPL-2.0-only OR MIT; S3 is
  its repository's BSD-3-Clause. CellKeeper takes facts only: key names,
  meanings, types and units. No code, comments or structure is taken (§5).

## 4. The owner's read-only check (2026-10-21) `[VERIFIED-EXPERIMENTALLY]`

**How.** The owner ran the open-source `smc` tool from smcFanControl
(GPL-2.0-or-later) by hand, from the build pinned in note 11 §4.1.
- **What it read:** `PDTR PSTR B0AP B0AC B0AV`, plus a read-only `ioreg`
  of the registry values.
- **When:** about once a second, 30 samples, 14:03:47 to 14:04:18 AEDT.
- **State:** on the adapter, at 100%, not charging, in the calibration's
  rest at the top (note 12).

No agent ran the tool. The lead read the saved text file read-only and
decoded its bytes. The file is not committed.

| Quantity | What it read |
|---|---|
| `PDTR` | 7.42–19.26 W; a different value in each of the 30 samples; mean 11.6 W, standard deviation 3.3 W, largest step between samples 11.5 W |
| `PSTR` | Equal to the previous sample's `PDTR` in 26 of 29 comparisons |
| `B0AP`, `B0AC` | 0 throughout |
| `B0AV` | 13 189–13 190 mV, read low byte first |
| Registry `SystemPowerIn` = `SystemLoad` | 8 560 mW at the update stamped 14:04:03; the update before, at 14:03:03, read 11 486 mW, before the samples began |

**What it shows:**
1. **`PDTR` changed in every sample, about a second apart.** It changes at
   least that often. Its own rate, and the rates of the other keys, were
   not measured.
2. **`PSTR` matched the previous `PDTR` in 26 of 29 comparisons** while the
   battery was idle, so input and use were the same power. That is an
   apparent one-second lag in this run [I]. It is not shown to hold while
   charging, or to mean `PSTR` is derived from `PDTR`. S3's "Delayed 1
   Second" is an Intel-era description.
3. **[I] The registry value looks like a snapshot of the SMC's reading.**
   At the update stamped 14:04:03 it read 8 560 mW. `PDTR` read 8.56 W at
   14:04:02 and 8.57 W at 14:04:03. `PSTR` read 8.56 W at 14:04:03 too, so
   the data cannot tell which key it follows. That is one update; the
   other came before the samples began.
4. **Byte order.**
   - **`B0AV`:** read low byte first, it gives 13 190 mV. That is close to
     the registry's 13 225 mV, read earlier that day rather than at the
     same moment. Read high byte first, it would be 34 355 mV, which the
     tool printed and which is not plausible.
   - **`B0AP` and `B0AC`:** their byte order and sign can't be told from
     zeros. Little-endian is assumed by analogy [I], and O1 settles it.
   - **The tool's own output:** it decodes integers high byte first, an
     Intel-era convention, and drops the decimals of floats. CellKeeper
     decodes the raw bytes itself.
5. **The readings are noisy** (the `PDTR` row above). A display that
   changes every 3 s should show the average of those seconds, not one
   reading.

## 5. Owner decisions (2026-10-21)

- **The route.** The owner chose to read the SMC with a reader they write
  themselves ("A"), over staying with once a minute.
- **Who writes what.**
  - **Agents:** everything above the reader's interface (§6).
  - **The owner:** the reader, which opens the SMC's user client and reads
    keys.

  The reason: agents stopped writing SMC client code on 2026-10-20, when
  a safety check stopped an agent's write client. Note 11 §2.2 covers any
  CellKeeper code that opens the SMC's user client, reads included. The
  lead's reason for including reads is that a read client shares almost
  all its code with a write client [I].
- **For the owner to confirm with this design:**
  - **(a) The clean-room exception.** Facts only, for `PDTR`, `PSTR` and
    `B0AP` at runtime, and `B0AC` and `B0AV` for the owner's checks: name,
    meaning, type, size and unit. They come from S1–S3 and are checked on
    this Mac. It is like note 11's exception for `CHIE`.
  - **(b) The sandbox exception and its scope** (§6.6).
  - **(c) The reader's contract** (§6.1).

## 6. Design

### 6.1 The owner's reader: interface and contract

**CellKeeper defines, in its own code:**
- **`SMCPowerKey`:** an enumeration of `PDTR`, `PSTR` and `B0AP`.
- **`SMCRawValue`:** a key's four-character type as the SMC reports it, and
  its bytes, undecoded.
- **One method:** takes a list of keys and returns, for each, its raw value
  or a per-key error (not found, or the read failed). If the user client
  cannot be opened, the whole call throws (refused, or unavailable).

**The owner's reader, one file in its own target, conforms to it:**
- **Read-only.**
  - **Allowed operations:** for each key asked for, it asks for the key's
    information and reads its bytes, nothing else.
  - **No write path:** it contains no write command and no request whose
    command comes from the caller. Every command is a constant in the
    file.
  - **No enumeration:** it does not read the key count or any key by
    index.
- **Its own allowlist.** The file holds its own list of the three
  four-character codes. Before it opens anything, it refuses any key not
  on that list. The enumeration constrains CellKeeper; the file's own
  list constrains the reader.
- **Connection lifetime.** One call opens the user client, reads the keys
  in order, and closes it before returning. That holds on every path:
  success, a per-key error, and an error after opening. The reader keeps
  no connection, buffer or state between calls.
- **Concurrency.**
  - CellKeeper never calls it twice at once (§6.2), so the reader may
    assume one call at a time.
  - It must be safe to call from any thread, one call at a time.
  - It is synchronous and cannot be cancelled. CellKeeper handles hangs
    (§6.2).
- **Nothing else.**
  - No root or helper; it runs in the app, in the sandbox.
  - No logging of values, and no identifiers read.
  - It is written from the owner's own knowledge, Apple's public IOKit
    documentation and the interface facts in note 11 §3.2. No code is
    taken from any project.
- **Provenance.** Its header says the owner wrote it.

**Review acceptance.** GPT and the lead read the complete reader file and
everything it calls in the repository. They give their findings in prose,
with no replacement code. To be accepted, the file must:
- read only the listed keys, with only the two allowed operations;
- have no enumeration, write path or caller-chosen command;
- balance every open with a close on every path;
- keep no state between calls;
- log nothing.

**When the reader is absent** (§6.5), CellKeeper never calls anything and
behaves as today.

### 6.2 Sampling, averaging and the deadline (CellKeeper)

- **Who samples.** A new sampler owns the reads. While the menu is open,
  the Power flow section is expanded, and the SMC source is not absent or
  backing off (§6.4), it runs one batch about once a second.
  - **Where:** on its own serial executor, never on the main actor and
    never on the controller's path.
  - **One at a time:** a tick that finds the previous batch still running
    is skipped.
- **Who publishes.** D114's refresher still reads its source every 3 s,
  one read at a time. With the SMC available, that read does not sample.
  It takes the window the sampler has collected since the previous read,
  which returns at once:
  - the average of that window's valid samples;
  - or "nothing new", in which case the refresher uses the registry for
    that tick (§6.4).

  A window is handed out once and then cleared.
- **The window.** A window holds the valid batches since the last
  hand-out, normally three.
  - **Weights:** each batch counts equally. A window with at least one
    valid batch is published, with its batch count.
  - **Discarded batches:** those taken before a reset. Resets are:
    - the section collapsing or the menu closing (the sampler also
      stops);
    - the Mac waking;
    - a power-source change, as AppModel already observes it.

    A batch that begins within 1 s after a power-source change is also
    discarded, so a window never mixes plugged-in and battery readings.
- **The deadline.** A batch not finished 2 s after it began is **stalled**.
  - **The read itself:** it is not cancelled, which can't be done. It is
    left to finish on its executor, and no new batch starts while it is
    stuck, so at most one thread waits.
  - **The display:** the source counts as failing (§6.4), and the display
    switches to the registry.
  - **Late results:** when the batch completes, its result is dropped.
    Every batch carries the sampler's generation, and a stalled batch's
    generation is retired.
- **Quitting** does not wait for a stuck read. The controller's
  restore-on-quit flow does not depend on the sampler, and the process
  exits.

### 6.3 Decoding and validity

- **`PDTR` and `PSTR`:**
  - **Type and length:** `flt `, exactly 4 bytes, little-endian IEEE-754.
  - **Rejected:** non-finite values (NaN, infinity) and values outside
    0–500 W, the same bound as D114's registry values.
- **`B0AP`:** `si32`, exactly 4 bytes, little-endian, within ±300 000 mW.
  It is read only once O1 settles its sign.
- **Any mismatch** in type or length makes that key invalid for that
  batch, never a guessed value.
- **Required keys.** A batch is valid if `PSTR` is valid and, while on
  external power, `PDTR` is valid. On battery `PDTR` is not used, so small
  readings there are not a fault (O2). `B0AP` is optional: when it is
  missing or invalid, the battery's value comes from the registry, and
  that does not invalidate the batch.

### 6.4 States, fallback and recovery

| State | Meaning | Display | Leaves when |
|---|---|---|---|
| **absent** | The build has no reader (§6.5) | Registry, as today | Never; only another build changes it |
| **backing off** | The user client could not be opened (for example, refused by the sandbox) | Registry | A new open attempt succeeds. Attempts are 30 s apart at first, doubling to at most 5 min, and only while the section is shown |
| **failing** | 3 consecutive batches invalid, or one stalled | Registry | A window of 3 consecutive valid batches → **available** |
| **available** | Valid windows are being published | SMC averages | 3 consecutive invalid batches or a stall → **failing**; a failed open → **backing off** |

- **What the display shows,** in order:
  1. while the SMC source is available and a window was published in the
     last 6 s, the SMC average;
  2. otherwise the registry, by D114's rules;
  3. if the registry has nothing either, D114's "no reading".
- **Late SMC results** never overwrite newer registry data. A late batch is
  dropped by its generation (§6.2). A published window carries the
  continuous-clock instant at which its first batch began. Under D114's
  ordering, it then never replaces a reading that began later.

### 6.5 Timestamps, provenance and history

- **Two times per window.**
  - **`updatedAt`:** the wall-clock time the window's last batch
    completed. This is a collection time, not a firmware update time. It
    gives every window a distinct time, so D114's history neither drops
    nor merges windows by mistake.
  - **`readBegan`:** the continuous-clock instant the window's first batch
    began, conservatively. An average is no newer than its oldest reading.
    A window delivered late does not look fresh, and is handed out only
    once.
- **Provenance travels with each sample**, not with the configured source.
  Each sample says where its values came from:
  - **registry:** once a minute;
  - **SMC:** averaged over the window's seconds;
  - **mixed:** SMC for the adapter and the Mac, the registry for the
    battery, which is the case until O1.

  The footnote is built from the provenance of the sample on screen. For
  example: "Adapter and Mac from the SMC, averaged over 3 s; battery from
  macOS's battery data, updated about once a minute." When D114's
  ordering puts a registry reading on screen, the footnote changes with
  it.
- **Statuses while the SMC source is active.** Controller statuses don't
  replace the SMC display, and don't add registry points to the history.
  This applies while the source is available and a window was published
  in the last 6 s. Otherwise the history would mix minute snapshots with
  3 s averages, and the display would flicker between them. When the
  section is closed, D114's rules apply unchanged.
- **The history** gets one point per published window, equally weighted.
  Its 10 s buckets average about three of them. Partial windows count
  like full ones, and their batch count is kept for diagnostics.

### 6.6 The sandbox exception, its scope, and the build option

- **Why it is needed.** CellKeeper runs in the App Sandbox, which allows
  opening only listed user-client classes; the SMC's is not among them
  (note 05 §1.2, §1.5).
- **The candidate.**
  `com.apple.security.temporary-exception.iokit-user-client-class`, with
  an array holding exactly `AppleSMCClient`. That is the class the
  registry showed on this Mac (note 11 §9); S4 allows a string or an
  array. Nothing establishes a need for a parent class. The minimal entry
  is tried first (O3) and widened only on evidence.
- **Its scope, independent of the reader.**
  - **What it grants:** in the system profile, opening the named class
    and setting properties on it, for the whole process (note 05 §1.2).
  - **What it does not limit:** it limits neither the keys nor the
    operations. The reader's contract binds only CellKeeper's own code.
  - **If CellKeeper were compromised:** the process could send any
    request the SMC driver accepts from an unprivileged client, including
    attempts to change keys. Whether the driver refuses those without
    root is unverified. CellKeeper assumes nothing about it and tests
    nothing; it never attempts a write.

  That is a real widening of what the sandbox contains, accepted only
  for this display feature, and only in builds that opt in.
- **The App Store.** App Review "takes a very dim view" of temporary
  exceptions (note 05 §1.5), so the exception would likely not be
  granted there. CellKeeper is not distributed there.
- **The build option.** The reader target and the entitlement are added
  together, by one build setting, off by default.
  - **When off:** the app has no reader, the SMC source is **absent**, and
    the entitlements are exactly today's.
  - **When it is turned on:** only after O3 succeeds.
- **CI.**
  - Today's check of the signed app's exact boolean entitlements stays
    for the default build.
  - A second CI build with the option on checks that the exception is an
    array holding exactly `AppleSMCClient`, and still rejects any other
    entitlement.

### 6.7 Cost and privacy

- **Cost:** one batch of two or three small reads a second, only while
  the section is shown.
- **Privacy:** no identifiers. The values live in memory only, like
  D114's history.

## 7. Plan

1. **The owner settles O1 and O2.** They run the read-only check during
   the calibration's drain (on battery) and its final charge. The criteria
   are in §8.
2. **Review.** GPT reviews this revision. The owner confirms §5 (a)–(c),
   and the decisions are recorded here.
3. **Agents build everything above the reader,** with a fake reader, as a
   pull request with GPT review:
   - decoding;
   - the sampler and the deadline;
   - the windows;
   - the states;
   - provenance and footnotes;
   - the build option and both CI checks;
   - CONTRIBUTING's clean-room exception, D114's update and note 05.

   The option stays off. Deterministic tests cover:
   - malformed values (wrong type, wrong length, non-finite, out of
     range);
   - an absent reader, a failed open, backing off, failing and
     recovering;
   - a stalled batch and its late result;
   - at most one batch at a time;
   - window resets on collapse, close, wake and power-source changes,
     and partial windows;
   - provenance and the footnote;
   - D114's races, with controller readings and failures arriving during
     SMC windows;
   - the controller and the calibration never receiving these values.
4. **The owner writes the reader** against §6.1. GPT and the lead review it
   against §6.1's acceptance list.
5. **After the calibration,** when launching a build is safe again:
   - the owner tries a `.preview` build with the option on (O3);
   - then they try the app itself, which also covers D114's checks still
     pending on a Mac.

## 8. Open questions and how each is settled

- **O1. The sign of `B0AP`, and whether it can replace voltage × current.**
  It is settled when the owner's samples show all of these:
  - nonzero `B0AP` and `B0AC` both while charging and while on battery,
    each with its type and length;
  - a consistent sign, mapped to D114's convention (positive while
    charging);
  - `B0AP` close to `B0AV` × `B0AC`, from samples taken in the same
    second;
  - `PSTR` while charging, to see how it relates to `PDTR` then.

  The idle relationship of §4 is not assumed to hold there. Until O1 is
  settled, `B0AP` is not read.
- **O2. What `PDTR` reads on battery, and at small loads on the adapter.**
  It is settled by samples on battery and on the adapter. On battery the
  design does not use `PDTR`. On the adapter, a small but real input is
  not a fault.
- **O3. Does the minimal exception work?** It is settled after the
  calibration, with a `.preview` build signed as CI signs it and the
  option on. All of these must hold:
  - the signed app shows exactly the expected entitlements;
  - the reader opens `AppleSMCClient` and reads the keys without root;
  - the menu stays responsive;
  - no user-client connections or threads pile up over several minutes
    of reading.
- **O4. Other Macs and macOS versions.** Matching types, lengths and
  ranges keep wrong encodings out. They cannot prove that a key means the
  same on another Mac. The SMC source stays labelled with its provenance,
  and is off by default.

## 9. Sources

- **S1** — Linux, `arch/arm64/boot/dts/apple/hwmon-common.dtsi`, at
  commit 56c65dc95f3d1513fd0806bd59da0392e8b6913c:
  https://github.com/torvalds/linux/blob/56c65dc95f3d1513fd0806bd59da0392e8b6913c/arch/arm64/boot/dts/apple/hwmon-common.dtsi
  (GPL-2.0+ OR MIT). Supports: `PSTR` "Total System Power", `PDTR` "AC
  Input Power", `VD0R` "AC Input Voltage", `ID0R` "AC Input Current", as
  sensors "expected on all systems".
- **S2** — Asahi Linux, `drivers/power/supply/macsmc-power.c`, at commit
  8249f07c8de2cc78bcd5857a0985e9c032e44ddc:
  https://github.com/AsahiLinux/linux/blob/8249f07c8de2cc78bcd5857a0985e9c032e44ddc/drivers/power/supply/macsmc-power.c
  (GPL-2.0-only OR MIT). Supports:
  - `B0AV` read as u16, `B0AC` as s16, `B0AP` as s32;
  - `PDTR` and `PSTR` read as IEEE-754 floats;
  - "macOS 15.4+ firmware dropped legacy AC keys (AC-n, AC-i)".

  It documents no sign convention.
- **S3** — acidanthera VirtualSMC, `Docs/SMCSensorKeys.txt`, at commit
  2a454baa71b590e3380e4985aab1f2052a8352af:
  https://github.com/acidanthera/VirtualSMC/blob/2a454baa71b590e3380e4985aab1f2052a8352af/Docs/SMCSensorKeys.txt
  (repository BSD-3-Clause; the file states no licence of its own).
  Intel-era tables. Supports:
  - `PSTR` "System Total Power Consumed (Delayed 1 Second)" and `PDTR`
    "DC-In total power", as 2-byte fixed point;
  - `PPBR` "PBus on battery power";
  - `B0AC` "Battery Actual current", in signed and unsigned entries
    labelled A and mA;
  - `B0AV` "Battery Actual Voltage", in unsigned entries labelled mV and V.
- **S4** — Apple, "App Sandbox Temporary Exception Entitlements" (archived
  Entitlement Key Reference, 2017):
  https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html
  Supports: `com.apple.security.temporary-exception.iokit-user-client-class`,
  "Ability to specify additional IOUserClient subclasses to open or to set
  properties on"; the value is "a string or an array of one or more
  strings".
