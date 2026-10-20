# 11 — The SMC adapter-cut probe (`CHIE`, owner-run, on the maintainer's Mac)

- **Date:** 2026-10-20
- **Status:** Phase 1 — design and policy. No SMC key has been read or
  written yet. This note states what will be tested, from which sources,
  and with what safety. The read-only `check` of `CHIE` (which opens the
  AppleSMC user client to read one key, no root, no write) and the
  owner-run `sudo run` come with the implementation (phase 2); their
  results land in §9 and §10.
- **Machine:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (26A434),
  system firmware mBoot-20457.1.29. This is the maintainer's own Mac, the
  test Mac since 2026-10-19 (note 09 §2).
- **Tool:** [`Tools/charge-inhibit-probe/`](../../Tools/charge-inhibit-probe/),
  the standalone SwiftPM package of notes 09 and 10, extended again. A new
  selector, `--mechanism smc-adapter-cut`, chooses this test; the two
  private power assertions stay under `--assertion` (§4). It is not part of
  the app, its Xcode project or CellKeeperKit, and nothing ships from it.
- **Tags and grades:** as in [note 02](02-charging-control-apple-silicon.md)
  (tag legend and grades A–E, X). Here, **B** is Apple open source, **A**
  the public macOS 27.0 SDK, **C** open-source kernel patches posted for review, **D**
  community tool documentation corroborated by several reports, **E** a
  single report, and **X** a read-only observation on this Mac.

---

## 1. Purpose

Notes 09 and 10 showed that neither of Apple's private power assertions,
`ChargeInhibit` and `DisableInflow`, changes charging on this Mac. The only
mechanism note 02 still reports to work on 20457.x firmware is the **SMC
adapter cut**, key `CHIE`: writing one value makes the Mac stop drawing
power from the adapter and run from its battery while the adapter stays
plugged in; writing another restores adapter power (note 02 §3.4).

This probe asks, for one Mac, one macOS build and one firmware: does writing
`CHIE`'s reported cut value make the Mac run from its battery with the
adapter attached, and does writing its restore value bring adapter power
and charging back? Unlike notes 09 and 10, this is an **SMC key write**, not
a power assertion. Two facts follow from that and shape the whole design:

- macOS's own Charge Limit must be off (set to 100%), because `CHIE` is
  reported to be ignored while the native limit is active (note 02 §3.4,
  §3.10; §3 here).
- **A written key does not release itself.** powerd frees a power assertion
  when its owner exits (notes 09–10); nothing frees an SMC key if the writer
  crashes. So the probe arms a restore deadline before it cuts, restores the
  key on every path it can, offers a separate `restore` command, and says
  plainly what it cannot guarantee: a hung SMC call, a crash or a sleep can
  leave the cut in place, and whether unplug/replug, sleep or a restart
  clears `CHIE` is not known (§4, §7, §8).

It does not test sleep, restart, unplugging or persistence as outcomes; it
measures one cut and one restore while the Mac is awake, lid open, with the
owner present.

## 2. The owner's decision (2026-10-20, "B")

After both private assertions showed no effect, the owner chose to pursue
the SMC adapter cut on this Mac. The decision, in three parts:

1. **SMC access on this Mac is authorized for the adapter cut:** an
   owner-run `sudo` test that writes `CHIE`. **Agents never write any SMC
   key and never run `sudo`.** Agents **may** do read-only SMC reads of
   **allowlisted** keys — here `CHIE` only (§3, §4) — and **never enumerate
   the key table** and never read or write any unlisted key.
2. **A narrow clean-room exception** (now in
   [`CONTRIBUTING.md` §1](../../CONTRIBUTING.md) and the
   [research README](README.md), referenced from
   [`safety.md`](../safety.md)): facts only, from OSI-licensed open-source
   projects, cited with source and licence and treated as third-party
   claims until verified on the test Mac — the `CHIE` key's name, type and
   size, the values those projects write to cut and restore adapter power,
   and the AppleSMC user-client interface needed to read and write one key.
   No code, comments or other text is copied, and no project's
   implementation structure (its files, types, functions or control flow);
   the wire-level facts needed to call the interface — the parameter
   block's fields, sizes and offsets, and the selector and command values —
   are used as facts, and everything is written independently. **Not
   covered:** AlDente (its repository is under a proprietary evaluation
   licence that calls its source a trade secret) or any other proprietary
   or source-available tool; decompiling, disassembling or string-dumping
   any binary (Apple's included); any other key or mechanism (each needs
   its own owner decision). Permissively licensed sources are preferred
   where the same fact is available, and the note records which sources
   agree or disagree. This is a project rule, not a legal opinion or a
   licence-compatibility review.
3. **The behaviour is accepted:** a level is held by cutting adapter power
   at the limit and restoring it below; macOS's own limit must be off; a cut
   does not release itself if the writer crashes.

AlDente's helper must still be absent, checked read-only as in note 09.
This note and the probe consulted **no** AlDente source, documentation or
binary.

These are the decisions that note 10 §10 and the roadmap (phase 4c) said
the adapter cut still needed ("SMC writes and the clean-room rule"); the
owner made them on 2026-10-20, and the roadmap now says so. Discussions
around two sources cited below (S11, S12) mention a private entitlement
(note 02 §3.6 records where such names come from); as there, no
entitlement name is recorded here and nothing in this note or the probe
depends on one.

## 3. Mechanism and sources

Every fact below is cited with its source and licence, and graded. Facts
about `CHIE`'s values are **third-party claims — unverified** until the
owner's `run` confirms them on this Mac; the interface facts come from
Apple's own open source and the public SDK. No code, comment or
implementation structure was copied from any source; facts are restated in
this note's own words, and the probe is written independently.

### 3.1 The key, its type and size, and the cut/restore values

| Item | What the sources report | Source | Licence | Tags / grade |
|---|---|---|---|---|
| Key name and role | `CHIE` cuts adapter input: the Mac runs from its battery while the adapter stays plugged in ("force discharge" / adapter off). It is the key used on "Tahoe" (macOS 26/27-era) firmware; older firmware used `CH0I`/`CH0J`. | batt lists `CHIE` as its adapter key for Tahoe-era firmware (S1); actuallymentor/battery uses `CHIE` for force-discharge (S2) | batt **GPL-2.0** (S1); actuallymentor/battery **MIT** (S2) | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: AS]`, **D** |
| Type and size | Reported type code `hex_`, size **1 byte**. A key is treated as usable only when its reported data size is non-zero. | A read reported `CHIE` with type `hex_` and one byte `00` on an M4 MacBook Air, macOS 27.0 (26A428) (S3), and one byte `00` on an M1 Pro, macOS 27.0 (S4); batt and actuallymentor/battery write and read one byte (S1, S2), and batt tests key info for a non-zero data size (S1) | MIT (S2–S4); GPL-2.0 (S1) | `[SMC/HW]`, **E** for the type (one report), **D** for the size; to be verified on this Mac by `check` |
| Cut value | **`0x08`** (one byte) cuts the adapter. | batt writes `0x08` to `CHIE` to disable the adapter (S1); actuallymentor/battery writes `08` to `CHIE` to start discharging (S2) | GPL-2.0 (S1); MIT (S2) | `[SMC/HW]`, **D**; two independent OSI projects agree |
| Restore value | **`0x00`** (one byte) restores adapter power; a read of `0x00` means the adapter is not cut. | batt writes `0x0` to restore and treats one byte equal to `0x0` as enabled (S1); actuallymentor/battery writes `00` to `CHIE` to stop discharging and treats a read of `00` as not discharging (S2) | GPL-2.0 (S1); MIT (S2) | `[SMC/HW]`, **D**; both projects agree |

**A disagreement, recorded.** The Linux `macsmc-power` driver
(GPL-2.0-only OR MIT) does **not** use `CHIE`: it uses other keys for
force-discharge and inhibit, and never mentions `CHIE` (S6; the later version, S5, keeps those keys). Their
values are outside the owner's exception and are not recorded here. The two user-space
macOS tools (S1, S2) treat `CHIE` as the *newer* adapter key that replaced
`CH0I`/`CH0J` on Tahoe-era firmware, and report that on 20457.x firmware the
older keys are gone while `CHIE` remains (S3). The Linux driver targets
the keys it supports on the hardware it was tested on (an M3), which did not
include `CHIE`, so it neither confirms nor contradicts `CHIE` or its values;
they rest on the two macOS tools alone (S1, S2). The probe writes **only**
`CHIE`, and **only** `0x08` or `0x00`.

### 3.2 The AppleSMC user-client interface (to read and write one key)

These facts come from Apple's own open source and the public SDK, and are
corroborated by two open-source SMC clients, one permissive (SMCKit, MIT)
and one strong copyleft (gosmc, GPL-2.0). They
describe how to open the SMC user client and read or write **one** named
key — not how to enumerate keys, which the probe never does.

| Item | What the sources state | Source | Licence | Tags / grade |
|---|---|---|---|---|
| Service and user client | `IOServiceMatching("AppleSMC")` finds the SMC; `IOServiceOpen` opens a connection. In Apple's source the open uses type `1` and is followed by an `IOConnectCallMethod` with selector `kSMCUserClientOpen` (0), and closed with `kSMCUserClientClose` (1). The two OSS clients open with type `0` and make no open or close call. | Apple PowerManagement `pmconfigd/PrivateLib.c` (S7); SMCKit `SMC.swift` (S8); gosmc `driver_darwin.go` (S9) | Apple **APSL-2.0** (S7); SMCKit **MIT** (S8); gosmc **GPL-2.0** (S9) | `[PRIVATE/UNDOCUMENTED][IOKIT][SMC/HW]`, **B**; D; they **disagree** on the open type |
| Selector | The struct method's selector is `kSMCHandleYPCEvent = 2` (gosmc uses the same value), called with `IOConnectCallStructMethod(conn, 2, &in, size, &out, &size)`. | S7, S8, S9 | as above | **B**; all three agree |
| Command bytes (in `data8`) | `kSMCGetKeyInfo = 9`, `kSMCReadKey = 5`, `kSMCWriteKey = 6`, which all three agree on (also `kSMCGetKeyFromIndex = 8` in all three, and `kSMCGetKeyCount = 7` in Apple's source only; the probe uses neither). | S7, S8, S9 | as above | **B**; agree on 5, 6, 9 |
| Result codes (output `result` byte) | `kSMCSuccess = 0`, `kSMCError = 1`, `kSMCKeyNotFound = 0x84` (132). Apple's source marks the key-not-found value as not yet verified. | S7, S8 | APSL-2.0; MIT | **B**; agree |
| Parameter struct | `SMCParamStruct`: `key` (uint32); `vers` (SMCVersion: `major`/`minor`/`build`/`reserved` uint8, `release` uint16); `pLimitData` (version/length uint16, cpuPLimit/gpuPLimit/memPLimit uint32); `keyInfo` (`dataSize`, `dataType` uint32, `dataAttributes` uint8); `result` uint8; `status` uint8; `data8` uint8; `data32` uint32; `bytes[32]`. SMCKit adds an explicit `padding` uint16 before `result` and asserts the struct is **80 bytes**. | S7 (the struct and command enums), S8 (padding and the 80-byte assertion) | APSL-2.0; MIT | **B**; agree |
| `dataSize` width | Apple declares `keyInfo.dataSize` as `IOByteCount`. In the public SDK, `IOByteCount` is 64-bit on arm64 user space and 32-bit on Intel (`IOTypes.h`, S10). gosmc instead uses a **fixed 32-bit** `dataSize` on every platform, matching the kext's wire format. | S7, S10 (IOByteCount); S9 (fixed uint32) | APSL-2.0; A; GPL-2.0 | **B**; A; a difference that matters on arm64 (§4) |
| Read/write sequence | For both read and write, first a `kSMCGetKeyInfo` call (set `key`, `data8 = 9`) learns the key's `dataSize` and `dataType` and detects `kSMCKeyNotFound`; then the op call sets `keyInfo.dataSize` and `data8 = 5` (read) or `6` (write), with the payload in `bytes`. gosmc refuses a write whose length differs from the key's `dataSize` (S9); Apple's writer (S7) and SMCKit (S8) do not check it, so the probe enforces it itself. Apple byte-swaps a read key's bytes (reverse order) except for `'ACID'`. | S7, S8, S9 | as above | **B**; agree |
| FourCC packing | A 4-character key or type code is packed big-endian: `c0 << 24 | c1 << 16 | c2 << 8 | c3`. | S8, S9 | MIT; GPL-2.0 | C/D; agree |

**What this means for writing one byte to `CHIE`.** Open the AppleSMC user
client; `GetKeyInfo(CHIE)`; require `dataType == "hex_"` and `dataSize == 1`
(the cited expectation) or **refuse**; then `WriteKey` with
`keyInfo.dataSize = 1` and `bytes[0] = 0x08` (cut) or `0x00` (restore); then
`ReadKey` and require the read byte to equal what was written. A one-byte
value is unaffected by the byte-swap.

Design decisions for the interface, each written independently:

- **Layout.** With a fixed 32-bit `dataSize` and C's usual alignment, the
  struct of S7 is 80 bytes: `key` at offset 0, `vers` at 4, `pLimitData` at
  12, `keyInfo` at 28 (`dataSize` 28, `dataType` 32, `dataAttributes` 36),
  `result` at 40, `status` at 41, `data8` at 42, `data32` at 44 and `bytes`
  at 48–79 (this note's own derivation; SMCKit's 80-byte assertion, S8,
  agrees). With the SDK's 64-bit `IOByteCount` on arm64 (S10) it would be
  88 bytes. The probe uses the fixed 32-bit field, as gosmc does (S9) — and
  batt, which uses gosmc, is reported to work on Apple silicon (S1, S12) —
  so the size sent is 80 bytes, provisionally `[INFERRED/UNVERIFIED]`. It
  encodes and
  decodes the 80 bytes at those offsets explicitly, rather than relying on
  a Swift struct's layout, and the tests check every offset.
- **Opening.** `IOServiceOpen` with type `0` and no `kSMCUserClientOpen`
  call, as gosmc does (S9); batt, which uses gosmc, is the client reported to
  work on Apple silicon (S1, S12). SMCKit (S8) also opens with type `0`, but
  describes itself as a client for Intel-based Macs. Apple's type `1` and
  open/close calls (S7) are from an old release, presumably written for
  Intel Macs `[INFERRED/UNVERIFIED]`.
- **Confirmation before any write — one layout, no fallback.** The
  interface was written for the Intel SMC device, and on Apple silicon the
  matched service is an RTKit endpoint (§9). So the probe treats the
  interface, the 80-byte layout and open type `0` as third-party claims. A
  `GetKeyInfo` and a `ReadKey` of `CHIE`, sent with **exactly** the layout
  `run` writes with, must both succeed: an 80-byte response, IOReturn
  success **and** result byte `0`, type `hex_`, size 1. Any IOReturn
  error, non-zero result byte, other response size, or other type or size
  makes `check` FAIL and `run` refuse (§5), and `run` repeats both calls
  itself, in the same process, immediately before the cut (§4) rather
  than relying on an earlier `check`. The probe has one layout and never
  falls back to another — not at check time, and not at write time. A
  wrong struct size is expected to fail the call (`kIOReturnBadArgument`
  or similar) rather than act `[INFERRED/UNVERIFIED]`.
- **What a successful read does not prove.** It shows that this layout and
  open type work for *reading* `CHIE`. It does not show how the SMC
  interprets a write, whether root may write the key, whether a write is
  applied atomically, or what the firmware does with the value. Those stay
  third-party claims until the owner's run reads `0x08` back after the cut
  and the readings change (§4, §8).

### 3.3 Reported behaviour (third-party claims — unverified)

- On 20457.x firmware, `CHIE` reads as present (one byte, `00`) while the
  inhibit keys (`CHTE`/`CH0B`/`CH0C`/`CH0I`) and the firmware-limit keys
  (`bfF0`/`bfD0`/`bfE0`) are "no data" or return `kIOReturnNotPrivileged`
  even to root. Reported on an M4 and an M1 Pro on macOS 27.0 (S3, S4),
  and on firmware 20457.1.29 with a macOS 27.0 beta (S11).
  `[INFERRED/UNVERIFIED]`
- Writing `CHIE 0x08` with **no** native limit set: the Mac switches to
  "Battery Power", `ExternalConnected = No`, within about 5 s. With the
  native Charge Limit **active**: the write is ignored and the Mac stays on
  AC, reportedly because the firmware controls the power path while that limit
  is in effect (S4).
  `[INFERRED/UNVERIFIED]`
- The adapter cut enforces **only while the Mac is awake**; it is not a
  firmware ceiling like the native limit. A tool using it disables the cut
  before sleep (S12). `[INFERRED/UNVERIFIED]`
- A written key does **not** release itself. One tool re-applies and
  restores the key on exit, before sleep, and after an unclean kill
  (`SIGKILL`), recovering by re-detecting and restoring (S12). Whether
  unplug/replug, sleep or a restart clears `CHIE` is **not reported**; Apple's
  support article on resetting the SMC says it resets automatically on Macs
  with Apple silicon (Apple Support 102605, note 02 §1.8 and its S3), which
  suggests but does not confirm that a restart clears it. `[INFERRED/UNVERIFIED]`
- Wear: cutting the adapter makes the battery go through many small
  discharge–charge cycles; one contributor stopped using such a build for that reason (S13).
  This is the opinion behind the 25% floor and the opt-in, wide-band design
  CellKeeper's own control will need, not a measurement.

**What the published Apple source predicts** `[INFERRED/UNVERIFIED]`. Apple
publishes the SMC user-client *interface* (S7) but not `CHIE` or its
semantics; the macOS 27 SMC firmware and the AppleSMC kext are not
published. So the interface is Apple's (grade B) while the key, its values
and its effect are third-party claims (grade D/E) that only the owner's run
can confirm.

**Clean room.** The interface facts come from Apple's open source and the
public SDK; the `CHIE` facts from the GPL-2.0 batt, the MIT
actuallymentor/battery and their issue reports, and the dual-licensed Linux
macsmc driver, each cited above with its licence. No code, comment or
other text, and no implementation structure, was copied from any of them;
the parameter block's fields and sizes are used as interface facts, its
offsets were derived here (§3.2), and the probe is written independently.
No binary was disassembled, decompiled or string-dumped, and no AlDente
source, documentation or binary was consulted.

## 4. Method

### What the probe reads (read-only)

Everything notes 09 §4 and 10 §4 list, read the same way (IOPowerSources,
the `AppleSmartBattery` registry, `pmset -g battlimit`, `pmset -g
assertions`, the AlDente checks), plus one new read:

| Value | Source | Used for |
|---|---|---|
| `CHIE` type, size and current value | the AppleSMC user client, `GetKeyInfo` then `ReadKey` for the one key `CHIE` (§3.2); no enumeration, no other key | `check`: report and verify type/size; `run`: baseline and the read-back after every write; `restore`: the read-back |

As in notes 09–10, registry values are read one key at a time, serial
numbers are never read into a sample, and no user client of the battery
manager is opened. The AppleSMC user client is opened only to read or write
`CHIE`.

### The command line

A new selector, `--mechanism`, chooses the mechanism:

- `--mechanism assertion` (the default, so notes 09–10 are unchanged) keeps
  the two private power assertions and still requires
  `--assertion disable-inflow|charge-inhibit`.
- `--mechanism smc-adapter-cut` selects this test; `--assertion` is then not
  allowed.

Subcommands:

- `check` — read-only, **no root needed** if the user client allows it:
  bclm's documentation says root is needed to write SMC keys but not to
  read them (bclm, MIT; cited in note 02 §3.8 as S20 — a third-party claim). If
  the user client cannot be opened without root, `check` FAILs and says so;
  it never asks for root. Opens the AppleSMC user client, reads `CHIE`'s type,
  size and value, and **FAILs** if the type is not `hex_` or the size is not
  1 byte, or if the key is `kSMCKeyNotFound` or unreadable; prints the
  current value and every other precondition. **Agents may run this.**
- `run` — **owner only, `sudo`.** The preconditions of note 10's
  `disable-inflow` run (on AC, Charge Limit 100%, charge ≥ 40%, adapter
  attached, no other battery tool, `UpdateTime` and `SystemPowerIn`
  readable, no assertion held), plus the `CHIE` type/size/value check. It
  records a baseline, writes the cut value `0x08`, reads it back, holds,
  writes the restore value `0x00`, reads it back, and watches after. It
  writes no other value: it refuses to start unless `CHIE` reads `0x00`
  (§5), so `0x00` is both the starting state and the restore value.
- `restore` — **owner only, `sudo`.** For the case a writer crashed, or the
  Mac slept, and left the adapter cut. It reads first, after the same type,
  size and layout check (lead's decision, 2026-10-20):
  - `CHIE` reads `0x00`: it writes **nothing** and reports "already
    restored";
  - `CHIE` reads `0x08`: it writes `0x00`, reads it back, and reports
    whether the read-back is `0x00`;
  - any other value: it **refuses**, writes nothing, and prints what it
    read: there is no value it could justify writing.

**Design decision — why the same tool and a new selector.** The adapter cut
shares the probe's reading, 2-second sampling schedule, battery-update
rules, sleep handling, console/report format and — crucially — note 10's
verdict for an adapter cut (discharging, adapter attached, system power
input ≤ 1000 mW). Keeping it in the same tool keeps all of that in one
place, tested once. But it is a different *mechanism*: an SMC key write, not
a power assertion; it needs a `restore` subcommand the assertions do not;
its "release" is a second write with a read-back rather than a powerd
release; and its reports must never mention `pmset -g assertions`. So the
mechanism is a separate dimension (`--mechanism`) rather than another
`--assertion` value, and a small `Mechanism` label carries the
mechanism-specific wording (how a "release" is confirmed, and the different
crash story) into the shared report and verdict text.

### Sequence of `run`

As in note 10 §4, with the assertion create/release replaced by SMC writes:

1. Refuse unless root. Re-check every precondition (§5); refuse on any
   failure, including a `CHIE` type/size mismatch.
2. Create the report file and install the signal handlers, as in note 10.
   Register for system sleep notifications and create the public
   `PreventUserIdleSystemSleep` assertion for the run (the Mac may run from
   its battery; idle sleep becomes likelier). The idle-sleep assertion is
   the **only** power assertion this mechanism creates.
3. **Baseline:** readings every 2 s for at least 20 s and until 2 battery
   updates, all steady charging on AC power, exactly as note 10.
4. **Confirm, in this process, immediately before the cut.** Under the
   writer's lock: the baseline is still fresh, and a `GetKeyInfo` and a
   `ReadKey` of `CHIE` both pass every test of §3.2 (80-byte response,
   IOReturn success and result byte `0`, type `hex_`, size 1) and read
   `0x00`. An earlier `check` or `READY` does not count. On any failure
   nothing is written and the report says why.
5. **Arm the restore deadline, then mark a restore as needed — both before
   the write.** The deadline runs on its own thread, independent of
   sampling, console and report output: at the hold plus 15 s after the cut
   write (at most 315 s), it restores `CHIE` (writes `0x00`, reads back)
   whatever the rest of the probe is doing, and does no I/O until it has.
   If its restore is confirmed, the run carries on and the report says the
   deadline restored it; if not, it follows the emergency path below.
   Marking the restore as needed before the write means every path
   restores if the write *may* have happened — including a write call that
   returned an error, or a read-back that failed.
6. **Cut:** `WriteKey(CHIE, 0x08)`, then `ReadKey(CHIE)` and verify it is
   `0x08`. A write that fails, or does not read back `0x08`, is treated as
   a possible cut: **restore at once** (write `0x00`, read back), and the
   run is inconclusive.
7. **Hold:** 180 s by default, 165–300 s with `--hold`. The probe restores
   early (writes `0x00`, reads back) when a reading is unreadable, shows
   100% or charged, shows a charge below 25%, or shows a battery update more
   than 150 s old. Battery power is **not** a reason to restore early: it is
   the expected effect of a cut.
8. **Restore:** write `0x00`, then `ReadKey` and verify it is `0x00`, then
   cancel the deadline. Retry a failed write a bounded number of times.
9. **After:** readings for 180 s after the restore (up to 120 s more until
   charging has resumed), then release the idle-sleep assertion, deregister
   from sleep notifications and write the report. The longest run matches
   note 10.

### Restore on every path

The cut value is written in exactly one place; the **restore** is driven on
every path out of the hold, writing `0x00` and reading it back each time (a
restore that finds the run already restored does nothing):

- the end of the hold;
- the restore deadline (step 5), if the hold has not ended by then;
- `SIGINT`/`SIGTERM`/`SIGHUP` (the teardown's first step is the restore);
- an early stop (charge below 25%, a stale battery update, an unreadable or
  full reading);
- a `will-sleep` notification (below);
- a `defer` on every path out of the run.

**Sleep cannot be held off.** `kIOMessageSystemWillSleep` announces a sleep
that cannot be cancelled, and if the probe does not answer, macOS sleeps
anyway after 30 s (`IOPMLib.h`, cited in note 10 §3). On `will-sleep` the
probe restores and reads back **before** it acknowledges, under the same
no-I/O-on-the-sleep-queue rules as note 10: the restore write and read-back
are the queue's only blocking work (bounded retries). If the restore cannot
be confirmed, the probe does not acknowledge, appends one line to the open
report file under a 2 s exit deadline, and `_exit`s. **The Mac then sleeps
anyway, and `CHIE` may still be `0x08`:** unlike an assertion, exiting does
not undo the write. The line tells the owner to recover at once after the
Mac wakes, with `restore` (§6 step 7, §7).

The emergency path of the restore deadline is the same: if its restore
cannot be confirmed, it appends one line under the 2 s exit deadline and
`_exit`s, and the line tells the owner to recover at once.

**What the probe cannot guarantee, stated plainly.** A power assertion is
released when its owner exits (notes 09–10); a written SMC key is not. The
SMC calls are synchronous calls into the kernel: bounded retries bound the
number of calls, not how long one call takes, and if a call hangs, neither
the deadline nor any other path can complete a restore. If the probe hangs,
is killed with `SIGKILL`, panics, or loses power mid-run, or the Mac sleeps
before a restore is confirmed, `CHIE` may stay at `0x08` and the Mac may
keep running from its battery while plugged in. Recovery is the `restore`
command, confirmed by its read-back **and** by adapter power coming back
(§7). Unplugging and replugging the adapter, and restarting, are
**unverified** recovery attempts: it is unknown whether either, or a sleep,
clears `CHIE` (§8). Every report and the owner steps print this and the
`restore` command prominently.

**Never** writes any key other than `CHIE`; **never** a value other than the
cited `0x08` (cut) and `0x00` (restore); verifies type and size before every
write; reads back after every write.

**Under the same caveat, a short supervised run only.** The 40% start and
25% floor (§5, §7) are reasonable for a few minutes on battery with the
owner present and the readings working. They give no guarantee after a
crash, a hang or a sleep.

### The verdict (reuses note 10)

The adapter cut is judged by note 10's verdict rules, unchanged: a reading
is *charging*, *stopped*, *discharging* or *mixed* by the same thresholds; a
*sustained run* needs 5 counted readings over ≥ 8 s and ≥ 2 battery updates;
the effect must begin within 90 s of the **cut write**, be discharging with
the adapter reported attached and system power input ≤ 1000 mW in **every**
held reading, and last until the **restore write**; charging must resume
within 120 s of a **confirmed restore**. The mechanism maps onto note 10's
`ProbeRun`: the cut write is the "creation" (its IOReturn is the write/
read-back result, success only when the key read back `0x08`), the restore
write is the "release" (confirmed only when `CHIE` read back the restore
value — the analogue of `pmset -g assertions` no longer listing an
assertion). An unconfirmed restore opens the report with the recovery steps,
whatever the verdict. The expected successful verdict is **`adapter cut`**
(outcome c of note 10). `no effect observed` means `CHIE` was written and
read back `0x08` but every reading still showed charging over ≥ 2 updates —
which, read against note 02 §3.4, would mean this firmware ignores `CHIE`
(for example because a native limit was left on). All other note 10 verdicts
(`discharging with adapter attached`, `discharging, did not resume`,
`inconclusive`) apply unchanged.

**What telemetry cannot tell, carried forward from note 10 §4.** No reading
can tell an adapter cut from the owner unplugging the adapter. Here it is
sharper than in note 10: after a `CHIE` cut, `ExternalConnected` is
reported to go false (S4), so that flag is **expected** to say the adapter
is gone, and it is not used to judge attachment. Whether
`AppleRawExternalConnected` or the public adapter details still report an
adapter during a cut is unknown `[INFERRED/UNVERIFIED]`. If neither does, a
real cut and an unplug look the same, and the verdict is `inconclusive`
with the times in its reason; the owner's account of whether the adapter
stayed plugged in (§6) is then the only evidence, and the report never
claims a definite unplug. A system power input near zero, alone, shows
neither that the adapter is attached nor that the Mac is drawing nothing
from it. Phase 2's tests must include synthetic runs in which the
connection signals disappear during the hold, and in which the input power
cannot be read, and check that neither is judged an `adapter cut`.

## 5. Preconditions

`check --mechanism smc-adapter-cut` prints these and exits 0 if none fails,
1 otherwise. `run` checks them again and refuses on any failure. Everything
in note 10 §5 applies (AC, Charge Limit 100%, charge ≥ 40%, adapter
attached, `UpdateTime`/`SystemPowerIn` readable, no assertion held, AlDente
absent), with these changes:

| Check | Fails / warns when | Why |
|---|---|---|
| `CHIE` present with the expected type and size | **fails** if the AppleSMC user client cannot be opened, `CHIE` is `kSMCKeyNotFound` or unreadable, its type is not `hex_`, or its size is not 1 byte | A wrong type or size means a different key layout; the probe refuses to write (note 02 §6, "writing unknown keys or wrong widths"). |
| `CHIE` reads `0x00` | **fails** if `CHIE` reads `0x08` or any value other than `0x00` (lead's decision, 2026-10-20) | `0x08` means something else already holds a cut; any other value is an unknown state. Either way the run would start from a state it cannot justify restoring to, so it refuses. |
| The round-trip read uses the write's layout | **fails** if `GetKeyInfo` or `ReadKey` of `CHIE`, sent with the exact 80-byte layout `run` would write with (§3.2), returns an IOReturn error, a non-zero result byte or a response of another size, or reports anything but type `hex_` and size 1 | For reading, the layout question (80 vs 88 bytes, §3.2) is settled only by this read succeeding; for writing it stays open until the run (§3.2). `run` repeats this read in its own process immediately before the cut (§4). There is no fallback: a mismatch never makes the probe try another layout, at check time or at write time. |
| macOS's Charge Limit is 100% | **fails** below 100% (note 10 already checks this) | `CHIE` is reported ignored while the native limit is active (§3.3); the limit must be off for a meaningful result. |

The 40% floor-margin check, the "charge in 50–74%" warning and the
Optimized Battery Charging warning carry over from note 10 §5.

## 6. Owner steps

1. As in note 10 §6: AlDente fully removed, and the probe built —

   ```sh
   swift build -c release --package-path Tools/charge-inhibit-probe
   cd Tools/charge-inhibit-probe
   ```

2. In **System Settings › Battery › ⓘ next to Charging**, set the **Charge
   Limit to 100%** and turn **Optimized Battery Charging off**, for the
   whole experiment. The charge must be at least 40%; 50–74% is best.
3. Connect the Apple power adapter and wait until the battery menu shows it
   charging. Keep the lid open and the Mac on a hard surface, and stay with
   it. Quit anything heavy (builds, games, video exports) and leave it idle
   during the run. If the Mac gets unusually hot, press Ctrl-C: that
   restores `CHIE` and ends the run.
4. **During the run, do not touch the adapter or its cable.** The run is
   expected to leave the Mac running from its battery while the adapter is
   plugged in, for the hold (3 minutes by default): that is the effect. If
   the battery menu shows battery power during the hold, leave the adapter
   as it is. The probe cannot tell a cut from an unplugged adapter, so it
   relies on you not touching it (§4).
5. Check, without privileges:

   ```sh
   .build/release/charge-inhibit-probe check --mechanism smc-adapter-cut
   ```

   It must end with `READY`. Fix any `FAIL` line first; read the `WARN`
   lines.
6. Run the test:

   ```sh
   sudo .build/release/charge-inhibit-probe run --mechanism smc-adapter-cut
   ```

   It takes about 6½ minutes with the default hold, up to about 10½ if the
   baseline waits for a battery update or charging is slow to resume. Ctrl-C
   at any time restores `CHIE` and ends the run with a report.
7. **After the run, check recovery first** — and if the Mac slept during
   the run, do this as soon as it wakes. The battery menu must show the Mac
   on power adapter and charging again. If not, or if the report or the
   console says "CHECK RECOVERY FIRST", run, from the same folder
   (`Tools/charge-inhibit-probe` in the CellKeeper checkout):

   ```sh
   sudo .build/release/charge-inhibit-probe restore --mechanism smc-adapter-cut
   ```

   Recovery counts only when **both** hold: `restore` reports that `CHIE`
   read back `0x00` (or was already `0x00`), **and** the battery menu shows
   the power adapter again. **A crash or a sleep does not undo the cut**, so
   do this before anything else. If either fails, follow §7's recovery
   steps.
8. Only then set the Charge Limit and Optimized Battery Charging back the
   way you want them, and send the file
   `Tools/charge-inhibit-probe/charge-inhibit-probe-smc-adapter-cut-<timestamp>.txt`
   to the lead, saying whether the adapter stayed plugged in the whole
   time. Git ignores these files.

## 7. Safety

- **What it changes.** One SMC key, `CHIE`, set to `0x08` for the hold
  (180 s by default, at most 300 s) and restored to `0x00`, the value it
  must read before the write; one public idle-sleep assertion for the run;
  a registration for sleep notifications. No other key, no other value, no `pmset`
  setting, no launchd job, no persistent file but the report.
- **Running from the battery.** When `CHIE` is `0x08`, the Mac runs from its
  battery while plugged in. At the 10–16 W it draws while not charging,
  300 s is about 1 Wh, a percent or two `[INFERRED/UNVERIFIED]`; a heavy
  workload draws more and warms the battery, so the owner leaves the Mac
  idle and stops the run on unusual heat (§6). The probe ends the hold and
  restores at once if the charge falls below 25% (note 02 §7 puts the floor
  for an adapter cut at about 25–30%), and refuses to start below 40% (§5).
- **No self-release.** Unlike a power assertion, a written SMC key is **not**
  freed when the writer exits (§4). The probe arms a restore deadline before
  the cut, restores on every path it can and reads the restore back; a
  `restore` command exists for a crash, a hang or a sleep. A hung SMC call
  or a killed process can still defeat every one of these (§4). **Unknown:
  whether unplug/replug, sleep or a restart clears `CHIE`** — the published
  Apple source does not say, and this probe does not test persistence (§8).
- **Sleep.** A closed lid or the Apple menu still sleeps the Mac; the
  idle-sleep assertion stops only idle sleep. On `will-sleep` the probe
  restores `CHIE` and reads it back before acknowledging, but it **cannot
  delay the sleep**: macOS sleeps anyway after 30 s. If the restore cannot
  be confirmed, the probe records one line and exits, and the Mac may
  sleep with `CHIE` still at `0x08`; the owner then recovers as soon as it
  wakes (§6 step 7). A sleep makes the run inconclusive.
- **Fail-safe restore, in layers:** after the hold; by the restore
  deadline; on `SIGINT`/`SIGTERM`/`SIGHUP`; on an early-end reading; on a
  `will-sleep` notification; and in a `defer` on every path. A failed
  restore is retried a bounded number of times, and every report and the
  owner steps print the `restore` command.
- **What the probe never does:** run as root unless the owner starts it with
  `sudo`; write any SMC key but `CHIE`; write any value but `0x08` and
  `0x00`; write without first confirming `CHIE`'s type and size;
  skip the read-back after a write; enumerate the SMC key table; read any
  SMC key but `CHIE`; open a user client of the battery manager; change
  `pmset` settings; read the AlDente helper's files; keep anything of the
  adapter details but presence and wattage.

### Recovery steps

If adapter power did not come back after the run, or the probe did not
confirm its restore:

1. Run `restore` (§6 step 7). Recovery counts only when it reports `CHIE`
   at `0x00` **and** the battery menu shows the power adapter again.
2. If `restore` refuses, fails, or the adapter still does not show: the Mac
   is running from its battery. **Save your work.**
3. Then try, in order, unplugging and replugging the adapter, and
   restarting the Mac, running `restore` again after each. Neither is known
   to clear `CHIE` (§8); they are attempts, not a verified fix.
4. If adapter power still does not come back, **shut the Mac down before
   the battery runs low**, and send the report to the lead. If a Mac that
   was shut down still does not take power from its adapter when started
   again, ask Apple Support for help.

These steps extend
[`safety.md`, "If charging does not resume"](../safety.md#if-charging-does-not-resume),
which has the same steps.

## 8. Open questions

1. Does writing `CHIE 0x08` make this M4, on macOS 27.0.1 with firmware
   20457.1.29, run from its battery with the adapter attached, and does
   `CHIE 0x00` bring adapter power and charging back? This is what `run`
   answers.
2. Does `CHIE` read with type `hex_` and size 1 on this Mac, as the reports
   say (§3.1)? `check` answers this without a write.
3. **Does a written `CHIE` outlive the probe?** Specifically, does
   unplug/replug, sleep, or a restart clear it, or does it stay `0x08`?
   Not tested here (lead's decision, 2026-10-20). A persistence run
   (unplug/replug, sleep, restart; note 02 §7, Phase D) is **the next owner
   decision**, before any helper work: it decides whether CellKeeper's own
   control needs a startup reconciliation and an uninstaller restore
   (note 02 §6).
4. Is `CHIE` ignored while the native Charge Limit is on, as reported
   (§3.3)? The run is done with the limit off, so this is not measured here;
   it matters because CellKeeper's own control must turn the native limit off.
5. On Apple silicon the matched service is an RTKit SMC endpoint, not the
   Intel AppleSMC device (§9). Does the `IOServiceMatching("AppleSMC")` /
   `kSMCHandleYPCEvent` / `SMCParamStruct` interface (§3.2), written for the
   Intel device, work against that endpoint for a single-key read and write?
   The round-trip read in `check` answers it for reading, before any write.
   For writing — how the SMC interprets the write, whether root may write
   `CHIE`, and what the firmware does with it — only the run's read-back
   and readings answer it (§3.2).
6. Reading the sibling adapter keys (`CH0I`/`CH0J`) or the inhibit keys
   (`CHTE`) read-only would characterise this firmware's generation, but
   each is a key outside the allowlist and is **deliberately not read**; the
   allowlist is `CHIE` only (§2; lead's decision, 2026-10-20). Reading any
   of them, even read-only, needs its own owner decision; it is an open
   question for the owner, not part of this test.

## 9. Pre-run state

`[VERIFIED-EXPERIMENTALLY]` (read-only registry inspection, 2026-10-20): on
this Mac, `ioreg -r -c AppleSMC -d 1` returns a single entry of class
`AppleSMCKeysEndpoint` (a subclass of `AppleSMC`, which is why an
`IOServiceMatching("AppleSMC")` lookup finds it), whose provider class is
`RTBuddyEndpointService` and whose user-client class is `AppleSMCClient`.
This confirms note 02 §3.1: the Apple-silicon SMC is an RTKit endpoint, not
the Intel AppleSMC device the interface in §3.2 was written for. Only the
class names were read; no key was read, and no user client was opened.

The read-only `check --mechanism smc-adapter-cut` on this Mac — which opens
the AppleSMC user client and reads `CHIE`'s type, size and value, without
root and without any write — lands with the implementation (phase 2) and
will be recorded here, as note 10 §9 recorded its `check`.

## 10. Results

Not run yet. The owner-run `sudo run` is the one experiment §2 authorizes;
its outcome, the verdict, and the full report (with no serial numbers, user
names or home paths) will be recorded here, as in notes 09 §10 and 10 §10.

## 11. Sources

All fetched on 2026-10-20 unless stated otherwise. Each is cited for the
facts it supports; no code, comment, implementation structure or other
text was copied from any of them. For an issue or pull-request comment, the
licence given is the project's; it does not necessarily cover the comment,
which is cited only as a report.

**Third-party open-source projects (claims — unverified)**

- **S1** — charlie0129/batt, `pkg/smc/consts_arm64.go` and
  `pkg/smc/adapter.go` (**GPL-2.0**):
  https://github.com/charlie0129/batt . Supports: the key name
  `CHIE` as the adapter key for Tahoe-era firmware; the cut value `0x08` and the
  restore value `0x0`, one byte; treating a key as usable only when its data
  size is non-zero.
- **S2** — actuallymentor/battery, `battery.sh` (**MIT**):
  https://github.com/actuallymentor/battery . Supports: `CHIE` used for
  force-discharge; writing `08` to `CHIE` to cut and `00` to restore;
  a read of `00` meaning not discharging.
- **S3** — actuallymentor/battery pull request #469 (**MIT** project):
  https://github.com/actuallymentor/battery/pull/469 . Supports: `CHIE`
  reads as type `hex_`, one byte `00`, while the inhibit and `bf*` keys are "no data" or
  error, in a comment from an M4 MacBook Air, macOS 27.0 (build 26A428).
- **S4** — actuallymentor/battery PR #480 (**MIT** project, AI co-authored):
  https://github.com/actuallymentor/battery/pull/480 . Supports: `CHIE 08`
  with no native limit switches to "Battery Power", `ExternalConnected=No`
  within 5 s; with the native limit active it is ignored; a probe read of
  `CHIE` as one byte `00` on an M1 Pro, macOS 27.0.
- **S5** — Linux "[PATCH v3] power: supply: macsmc: Support macOS 27 SMC
  firmware" (Sasha Finkelstein, 2026-06-29; **GPL-2.0-only OR MIT**):
  https://ratatoskr.run/lkml/2026/06/17187069 . Supports: the driver's
  charge keys are `CHTE`/`CH0C` (inhibit) and `CH0I` (force discharge); it
  does not use `CHIE`; a macOS 27 firmware key-size change (`BCF0`, 4→1 byte).
- **S6** — Linux `macsmc-power` PATCH v2 (Michael Reeves / Asahi,
  2026-01-08; **GPL-2.0-only OR MIT**):
  https://ratatoskr.run/lkml/2026/01/3358555/t . Supports: the driver's
  force-discharge, inhibit and Optimized Battery Charging keys are others
  (values not recorded); no `CHIE`; SPDX `GPL-2.0-only OR MIT`.

**Apple — open source and SDK**

- **S7** — apple-oss-distributions/PowerManagement, tag
  PowerManagement-211.14, `pmconfigd/PrivateLib.c` (**APSL-2.0**):
  https://github.com/apple-oss-distributions/PowerManagement . Supports: the
  AppleSMC user-client interface for one key — `IOServiceMatching("AppleSMC")`,
  `IOServiceOpen` type 1 with `kSMCUserClientOpen`/`Close`,
  `kSMCHandleYPCEvent = 2`, command bytes `kSMCGetKeyInfo = 9`/`kSMCReadKey
  = 5`/`kSMCWriteKey = 6`, result codes `kSMCSuccess = 0`/`kSMCError =
  1`/`kSMCKeyNotFound = 0x84`, the `SMCParamStruct` layout, and the
  GetKeyInfo-then-op sequence with the read byte-swap. In the current tag
  (PowerManagement-1846.120.8.0.1), `pmconfigd/PrivateLib.h` still declares
  `_smcReadKey` and `_smcWriteKey`, and `pmconfigd/PrivateLib.m` includes a
  private `<IOKit/smc/SMCUserClient.h>` that is not in the published tree;
  the definitions above are quoted from the older tag.
- **S8** — beltex/SMCKit, `SMCKit/SMC.swift` (**MIT**):
  https://github.com/beltex/SMCKit . Supports: the same selector, command
  bytes and result codes; the `SMCParamStruct` with an explicit `padding`
  field asserted to make the struct 80 bytes; `IOServiceOpen` type 0; FourCC
  packed big-endian; data-type sizes ("flag"/"ui8 " = 1).
- **S9** — charlie0129/gosmc, `driver_darwin.go`, `constants.go`, `key.go`,
  `client.go` (**GPL-2.0**): https://github.com/charlie0129/gosmc .
  Supports: `IOServiceMatching("AppleSMC")`; selector 2; command
  bytes read 5 / write 6 / key-info 9; a **fixed 32-bit** `dataSize` field;
  GetKeyInfo before read and write; a write refused unless its length equals
  the key's data size; FourCC packed big-endian.
- **S10** — macOS 27.0 SDK (Xcode 27.0), `IOKit/IOTypes.h`, read locally.
  Supports: `IOByteCount` is `IOByteCount64` (64-bit) on arm64 user space and
  `IOByteCount32` (32-bit) on Intel — why a fixed 32-bit `dataSize` is used.
- **S11** — charlie0129/batt issue #152 (**GPL-2.0** project):
  https://github.com/charlie0129/batt/issues/152 . Supports: `CHIE` readable
  and reported writable while the other charge keys are gated on 20457.x,
  making it the only charge-related key left to use there.
- **S12** — charlie0129/batt PR #154, "Add adapter mode …" (**GPL-2.0**
  project): https://github.com/charlie0129/batt/pull/154 . Supports: an
  adapter-cut limit cuts wall power at the upper limit and restores at the
  lower; it enforces only while awake and disables before sleep; it is not a
  firmware ceiling; it restores on `batt disable` and recovers after
  `SIGKILL`; verified on an M5, firmware 20457.1.29.
- **S13** — actuallymentor/battery PR #478 (**MIT** project):
  https://github.com/actuallymentor/battery/pull/478 . Supports: on gated
  Macs only `CHIE` responds; the micro-cycling objection.
