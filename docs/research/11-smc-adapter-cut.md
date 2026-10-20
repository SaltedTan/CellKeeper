# 11 — The SMC adapter cut (`CHIE`): a manual, owner-run test on the maintainer's Mac

- **Date:** 2026-10-20
- **Status:** Run by the owner on 2026-10-20 (§10). Writing `CHIE` `08`
  cut the adapter's power on this Mac: it ran from its battery with the
  adapter plugged in, and macOS stopped reporting the adapter at all.
  Writing `00` brought both back. The probe's verdict is `inconclusive`
  by its own rule, because no reading during the cut reported the adapter
  attached, so the readings alone look like an unplug; the owner's account
  that the adapter stayed plugged in decides it (§4.8, §10). Phase 2 as
  first planned, in which the probe itself would open the AppleSMC user
  client and write `CHIE`, was replaced by the owner's decision of
  2026-10-20: an automated safety check stopped an agent's response as it
  began writing the SMC client code, and the lead decided not to route
  around it (§2.2). The owner read and wrote `CHIE` by hand with an
  existing open-source tool (§4.1), and the probe only observed (§4).
- **Machine:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (26A434),
  system firmware mBoot-20457.1.29. This is the maintainer's own Mac, the
  test Mac since 2026-10-19 (note 09 §2).
- **Probe:** [`Tools/charge-inhibit-probe/`](../../Tools/charge-inhibit-probe/),
  the standalone SwiftPM package of notes 09 and 10, extended again with a
  read-only observer, `--mechanism manual-adapter-cut` (§4.3). It opens no
  SMC user client and never runs the owner's tool. It is not part of the
  app, its Xcode project or CellKeeperKit, and nothing ships from it.
- **Owner's tool:** the `smc` command of smcFanControl (GPL-2.0-or-later),
  which the owner builds and runs outside the repository (§4.1).
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

This test asks, for one Mac, one macOS build and one firmware: does writing
`CHIE`'s reported cut value make the Mac run from its battery with the
adapter attached, and does writing its restore value bring adapter power
and charging back? The owner makes both writes by hand, with an existing
open-source command-line tool, in a terminal of their own. CellKeeper's
probe watches the battery, tells the owner what to type and when, and
judges the readings. Unlike notes 09 and 10, the change is an **SMC key
write**, not a power assertion. Two facts follow from that and shape the
whole design:

- macOS's own Charge Limit must be off (set to 100%), because `CHIE` is
  reported to be ignored while the native limit is active (note 02 §3.4,
  §3.10; §3 here).
- **A written key does not release itself.** powerd frees a power assertion
  when its owner exits (notes 09–10); nothing frees an SMC key. Here the
  restore is the owner's, made with the same tool. The probe reminds the
  owner, on its own timer and with a bell, and says plainly what it cannot
  guarantee: a probe that crashes, a missed reminder or a sleep can leave
  the cut in place, and whether unplug/replug, sleep or a restart clears
  `CHIE` is not known (§4, §7, §8).

It does not test sleep, restart, unplugging or persistence as outcomes; it
measures one cut and one restore while the Mac is awake, lid open, with the
owner present.

## 2. The owner's decisions (2026-10-20)

### 2.1 "B": the SMC adapter cut, with a clean-room exception

After both private assertions showed no effect, the owner chose to pursue
the SMC adapter cut on this Mac. The decision, in three parts:

1. **SMC access on this Mac is authorized for the adapter cut:** an
   owner-run test that writes `CHIE`. **Agents never write any SMC key and
   never run `sudo`.** The decision also allowed agents read-only reads of
   `CHIE` alone, never enumerating the key table; under the manual test
   (§2.2), no agent reads any SMC key at all.
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
   wire-level facts about the interface are facts, not structure. **Not
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
   does not release itself.

AlDente's helper must still be absent, checked read-only as in note 09.
This note and the probe consulted **no** AlDente source, documentation or
binary.

These are the decisions that note 10 §10 and the roadmap (phase 4c) said
the adapter cut still needed ("SMC writes and the clean-room rule"); the
owner made them on 2026-10-20, and the roadmap now says so. Discussions
around two sources cited below (S11, S12) mention a private entitlement
(note 02 §3.6 records where such names come from); as there, no
entitlement name is recorded here and nothing in this note, the probe or
the test depends on one.

### 2.2 "Existing tool, by hand"

The first version of this note designed the probe to open the AppleSMC
user client and write `CHIE` itself. When an agent began writing that SMC
client code, an automated safety check stopped its response. The lead
decided not to route around it: no agent or model writes that code. The
owner then chose, later on 2026-10-20, **"Existing tool, by hand"**:

- **The owner** makes a one-off manual test with an existing OSI-licensed
  open-source command-line tool, built and run outside the repository
  (§4.1): one read before the test, then one cut and one restore, each
  followed by a read.
- **The probe becomes a read-only observer.** It opens no SMC user client,
  reads and writes no SMC key, and never runs the tool or reads what it
  prints. It shows the owner the tool's commands, asks what the tool
  printed, and judges the battery readings by note 10's rules.
- **No CellKeeper code, test or document** contains code or pseudo-code
  that opens the AppleSMC user client or encodes its parameter block.
  §3.2 keeps only cited facts, as background.
- **Agents** never run `sudo`, never run the tool, never read or write any
  SMC key, never run the probe's `watch` (it creates a power assertion,
  which agents never do; note 10 §2), and never change the owner's System
  Settings. They may run the read-only `check`.

The lead fact-checked the tool, its licence and its commands before this
revision (§4.1; S14, S15).

## 3. Mechanism and sources

Every fact below is cited with its source and licence, and graded. Facts
about `CHIE`'s values are **third-party claims — unverified** until the
owner's test confirms them on this Mac. The interface facts in §3.2 come
from Apple's own open source and the public SDK, and are background only.
No code, comment or implementation structure was copied from any source;
facts are restated in this note's own words, and CellKeeper contains no
SMC code.

### 3.1 The key, its type and size, and the cut/restore values

| Item | What the sources report | Source | Licence | Tags / grade |
|---|---|---|---|---|
| Key name and role | `CHIE` cuts adapter input: the Mac runs from its battery while the adapter stays plugged in ("force discharge" / adapter off). It is the key used on "Tahoe" (macOS 26/27-era) firmware; older firmware used `CH0I`/`CH0J`. | batt lists `CHIE` as its adapter key for Tahoe-era firmware (S1); actuallymentor/battery uses `CHIE` for force-discharge (S2) | batt **GPL-2.0** (S1); actuallymentor/battery **MIT** (S2) | `[PRIVATE/UNDOCUMENTED][SMC/HW][PRIVILEGED][ARCH-SPECIFIC: AS]`, **D** |
| Type and size | Reported type code `hex_`, size **1 byte**. A key is treated as usable only when its reported data size is non-zero. | A read reported `CHIE` with type `hex_` and one byte `00` on an M4 MacBook Air, macOS 27.0 (26A428) (S3), and one byte `00` on an M1 Pro, macOS 27.0 (S4); batt and actuallymentor/battery write and read one byte (S1, S2), and batt tests key info for a non-zero data size (S1) | MIT (S2–S4); GPL-2.0 (S1) | `[SMC/HW]`, **E** for the type (one report), **D** for the size; to be verified on this Mac by the owner's first read (§4.4) |
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
they rest on the two macOS tools alone (S1, S2). The test writes **only**
`CHIE`, and **only** `0x08` or `0x00`.

### 3.2 The AppleSMC user-client interface (background; not implemented by CellKeeper)

**Not implemented by CellKeeper: this is what the owner's tool, like any
SMC client, does.** These facts come from Apple's own open source and the
public SDK, and are corroborated by two open-source SMC clients: SMCKit
(MIT), which describes itself as a client for Intel-based Macs, and gosmc
(GPL-2.0, strong copyleft). They describe how a client reaches **one**
named key, not how to enumerate keys. They are kept as background, for the
owner's later decision about a write layer (§8, question 7). This note
gives no layout and no call sequence.

| Item | What the sources state | Source | Licence | Tags / grade |
|---|---|---|---|---|
| Service and connection | A client finds the SMC by the service name `AppleSMC` and opens a user-client connection to it. Apple's source opens with type `1` and makes explicit open and close calls; the two open-source clients open with type `0` and make neither call. | Apple PowerManagement `pmconfigd/PrivateLib.c` (S7); SMCKit (S8); gosmc (S9) | Apple **APSL-2.0** (S7); SMCKit **MIT** (S8); gosmc **GPL-2.0** (S9) | `[PRIVATE/UNDOCUMENTED][IOKIT][SMC/HW]`, **B**; D; they **disagree** on the open type |
| Requests | Every request goes through one struct method, selector `kSMCHandleYPCEvent` (2). A command byte chooses get-key-info (9), read (5) or write (6); all three agree. Each also defines commands that walk the key table; the test never uses them, and the owner never uses the tool's `-l` (§4.1). | S7, S8, S9 | as above | **B**; agree |
| Result codes | `kSMCSuccess` 0, `kSMCError` 1, `kSMCKeyNotFound` 0x84 (132). Apple's source marks the last as not yet verified. | S7, S8 | APSL-2.0; MIT | **B**; agree |
| Parameter block | One fixed-size block carries the key, the command, the key's size and type, a result and the data. SMCKit states that it is 80 bytes. Apple declares its data-size field as `IOByteCount`, which the public SDK makes 64-bit in arm64 user space and 32-bit on Intel (S10); gosmc uses a fixed 32-bit field on every platform. | S7, S8, S9, S10 | APSL-2.0; MIT; GPL-2.0; A | **B**; A; a difference that matters on arm64 |
| Size check before a write | A client first asks for the key's size and type. gosmc refuses a write whose length differs from the key's size; Apple's writer and SMCKit do not check it. The owner's tool checks the length but not the type (§4.1). | S7, S8, S9; S14 | as above; GPL-2.0-or-later | **B**; D |

**What a successful read does not prove.** A read that shows `CHIE` as
`[hex_]`, one byte, `00` shows that the key exists and that the tool can
read it. It does not show how the SMC handles a write, whether root may
write the key, or what the firmware does with the value. Those stay
third-party claims until the owner reads `08` back after the cut **and**
the readings change, and reads `00` back after the restore **and**
charging resumes (§4.8).

**Superseded.** The first version of this note also recorded design
decisions for CellKeeper's own single-key client: a parameter-block layout
derived from the sources, an open type, a confirming read in the writer's
own process just before the cut, and no fallback to another layout. With
the owner's decision of §2.2 that client will not be built, and those
decisions are withdrawn. Whether CellKeeper ever needs an SMC write layer,
and who would write it, is an open owner decision (§8, question 7).

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
and its effect are third-party claims (grade D/E) that only the owner's
test can confirm.

**Clean room.** The interface facts come from Apple's open source and the
public SDK; the `CHIE` facts from the GPL-2.0 batt, the MIT
actuallymentor/battery and their issue reports, and the dual-licensed Linux
macsmc driver; the facts about the owner's tool from its own README,
licence and source (GPL-2.0-or-later, S14). Each is cited above or in §4.1
with its licence. No code, comment or other text, and no implementation
structure, was copied from any of them, and CellKeeper contains no SMC
code. No binary was disassembled, decompiled or string-dumped, and no
AlDente source, documentation or binary was consulted.

## 4. Method

### 4.1 Using a third-party tool: smcFanControl's `smc`

The owner's instrument is an existing tool, not CellKeeper code. **It is an
external test instrument:** the owner builds and runs it outside the
repository. Nothing from it enters CellKeeper — no code, binary,
submodule, build step or output format. CellKeeper never invokes it: the
probe starts no process for it, opens no shell, and never reads what it
prints. The probe shows the commands below as text, from one constant; the
owner types them in a second terminal and tells the probe what the tool
printed. Its behaviour facts come from its README, licence and source
(S14), read by the lead. No agent has built or run it. This is a project
rule, not a legal opinion.

| Item | Value |
|---|---|
| Tool | `smc`, the command-line tool in `smc-command/` of hholtmann/smcFanControl (S14) |
| Licence | GPL-2.0-or-later: the header of `smc.c` allows version 2 or any later version, and `LICENSE` is the GPLv2 text. OSI-approved. |
| Version | master commit `e1bd672bcd2d72eddff9b6da7b9cae38e35c4206` (2022-12-03). `smc-command/` last changed on 2022-07-21 (its README), its code on 2021-05-17: the tool is unmaintained. |
| Warning | Its README warns that writing SMC values could irreversibly damage the computer (§7). |
| Needs | The Xcode Command Line Tools only. It installs nothing. |

**Build** (the owner, in a terminal, outside the CellKeeper checkout):

```sh
git clone https://github.com/hholtmann/smcFanControl ~/smc-test
cd ~/smc-test && git checkout e1bd672bcd2d72eddff9b6da7b9cae38e35c4206
cd smc-command && make
```

If the build fails, stop and tell the lead; do not change the tool's code.
After the test, delete `~/smc-test`.

**The commands.** This is the only place this note gives them; the probe
prints the same text from a single constant. Run them in
`~/smc-test/smc-command`:

| Step | Command | Root |
|---|---|---|
| Read | `./smc -k CHIE -r` | no |
| Cut | `sudo ./smc -k CHIE -w 08` | yes (S15) |
| Restore | `sudo ./smc -k CHIE -w 00` | yes (S15) |

A read is reported to print `CHIE  [hex_]  (bytes 00)` (S3): the key, its
type in brackets, and its bytes in hex.

**What the tool does** (S14):

- `-w` takes the value as hex digits without `0x`, two per byte, and
  refuses an odd number of digits: always `08`, never `8` or `0x08`.
- Before a write, it reads the key's information and refuses a value whose
  length differs from the key's size. It does **not** check the key's
  type, so the owner's read before the cut must show `[hex_]` and one byte
  (§4.4).
- It writes only with `-w`. `-l` and `-t` both walk the whole key table,
  which is enumeration; `-f` reads other keys.
- Nothing in it restores `CHIE`: no daemon, no exit handler, no timeout.

**Rules for its use.** Only the owner runs it, and only the three commands
above: the key `CHIE`, the values `08` and `00`. **Never `-l`, `-f` or
`-t`**, never another key or value, and nothing that installs a helper or
daemon.

**Not chosen.** actuallymentor/battery (MIT, S2): its installer adds
root-owned files and a sudoers rule that allows SMC writes without a
password, and its adapter-off command also writes a MagSafe LED key that it
never restores. charlie0129/batt (GPL-2.0, S1): it runs as a root launch
daemon, kept alive by launchd, that writes charge keys by itself, and it
has no command to read a raw key.

### 4.2 What the probe reads (read-only)

Everything note 10 §4 lists, read the same way: IOPowerSources, the
`AppleSmartBattery` registry (including `UpdateTime`,
`AppleRawExternalConnected` and `PowerTelemetryData.SystemPowerIn`), the
public adapter details, `pmset -g battlimit`, `pmset -g assertions` (for
the precondition only) and the AlDente checks. Nothing is added. Registry
values are read one key at a time, and serial numbers are never read into
a sample.

The probe opens **no** user client of the battery manager or the SMC, and
reads **no** SMC key. What it knows about `CHIE` is only what the owner
types (§4.4).

### 4.3 The command line

A new selector, `--mechanism`, chooses the mechanism:

- `--mechanism assertion` (the default, so notes 09–10 are unchanged) keeps
  the two private power assertions, `check` and `sudo … run`, and still
  requires `--assertion disable-inflow|charge-inhibit`.
- `--mechanism manual-adapter-cut` selects this test; `--assertion` is then
  not allowed.

Subcommands for this test:

- `check --mechanism manual-adapter-cut` — read-only, no privileges.
  Prints the current reading and the preconditions (§5), and the three
  tool commands as a reminder. **Agents may run this.**
- `watch --mechanism manual-adapter-cut [--hold SECONDS]` — **the owner
  only, without `sudo`.** It refuses to run as root: nothing in it needs
  privileges, and the two steps that do are the owner's writes, made with
  the tool in another terminal. It also refuses unless its input and its
  output are a terminal, so that no script can answer its questions for
  the owner and every prompt is shown where the owner looks. Like
  note 10's `run`, it creates one public `PreventUserIdleSystemSleep`
  assertion and registers for sleep notifications. `IOPMLib.h` says any
  process may create an assertion with `IOPMAssertionCreateWithName`, and
  documents the sleep notifications for applications; if either fails,
  `watch` refuses before it asks the owner to do anything. Agents never
  run `watch`.
- `run --mechanism manual-adapter-cut` is a usage error that points to
  `watch`. There is no `restore` subcommand: the restore is the owner's
  tool command (§4.1).

**Design decision — the same tool, a new verb.** The manual test shares
the probe's reading, its 2-second sampling schedule, its battery-update
rules, its sleep registration, its report format and, crucially, note 10's
verdict for an adapter cut (discharging, adapter attached, system power
input ≤ 1000 mW). Keeping it in the same tool keeps all of that in one
place, tested once. In notes 09–10, `run` means "the owner, with `sudo`".
`watch` must not run as root, holds nothing the owner must release, and
asks the owner to act, so a different verb makes the difference visible in
every command line and report. The report is written to
`charge-inhibit-probe-manual-adapter-cut-<timestamp>.txt` (Git ignores
`charge-inhibit-probe-*.txt`). A small mechanism label carries the wording
that differs into the shared report and verdict text: the cut and the
restore are owner-confirmed, and the report never mentions
`pmset -g assertions` for them.

### 4.4 Sequence of `watch`

Readings stay every 2 s, never catching up, on `CLOCK_MONOTONIC`, as in
note 10, also while the probe waits for the owner: it reads the owner's
input without holding up the schedule, and it records every reading.

**Questions and answer words.** The probe asks the owner one question at a
time. Each question has its own answer words, listed below; no word
answers more than one question, and each is typed in full, then Return.
These rules hold throughout:

- Whenever the probe shows a new question, or a question is superseded (by
  a sleep, an early stop, a timeout or an answer that is not one of its
  words), it first **discards any terminal input typed before then**, so
  an answer typed ahead, or meant for an earlier question, never carries
  over. A line typed when no question is open is discarded too.
- Recovery counts as confirmed only by an answer to a question shown
  after the latest supersession.
- A reminder repeats the question open at that moment, with its exact
  answer words: the RESTORE prompt or its read-back question, the
  read-first question or the re-check question. Repeating a question is not
  a new question: it neither supersedes it, nor changes any mark, nor
  discards input typed for it.
- The standard RESTORE prompt (step 9) is used **only** when the cut was
  confirmed (`cut08`) and no sleep has come since. Every other restore
  request uses the read-first steps (step 10).

| Question | When | Type | Meaning | Anything else |
|---|---|---|---|---|
| First read | before the baseline (step 4) | `start00` | The read printed `[hex_]` and `(bytes 00)`. | The probe refuses (exit 1); nothing has been written. |
| CUT | after the baseline (step 6) | `cutnow` | Marks the cut time. The probe then prints GO or NO GO (step 7). | Not an answer; the prompt stays until its 120 s run out. |
| Cut read-back | after GO (step 7) | `cut08` or `cutfail` | `cut08`: the read after the cut printed `(bytes 08)`. `cutfail`: it printed anything else. | Taken as `cutfail`, as is no answer within 90 s: the cut is unconfirmed, and the probe goes to read-first (step 10). |
| RESTORE | at the end of the hold, or an early stop, after a confirmed cut and no sleep (step 9) | `restorenow` | Marks the restore time; the owner then runs the restore. | Not an answer; the reminder goes on. |
| Restore read-back | after `restorenow` (step 9) | `restored00` or `restorefail` | `restored00`: the read after the restore printed `(bytes 00)`. `restorefail`: it printed anything else. | Taken as `restorefail`: read-first (step 10). |
| Read-first | every other restore request (step 10) | `08`, `00` or `other` | What the read printed: `(bytes 08)`; `(bytes 00)`; or anything else, including no output, an error, a hang, or output the owner does not trust. | Not an answer; the question stays. |
| Re-check | after `08` and the restore (step 10) | `recheck00` or `recheckfail` | `recheck00`: the read after that restore printed `(bytes 00)`. `recheckfail`: it printed anything else. | Taken as `recheckfail`: read-first again. |

1. **Not as root, from a terminal.** Refuse if the effective user is root,
   or if the input or the output is not a terminal. Nothing else happens
   first.
2. **Preconditions** (§5). Refuse on any failure.
3. **Report, signals, sleep.** As note 10 §4: create the report file in
   the current directory, install the signal handlers, register for sleep
   notifications, and create the public idle-sleep assertion, with a
   timeout that covers the run's bounded parts plus 30 minutes for the
   owner's restore. Refuse if either fails. These are the only things the
   probe creates.
4. **The owner's first read.** The probe shows the read command and asks
   for `start00`, to be typed only if the tool printed `[hex_]` and
   `(bytes 00)`. It waits up to 120 s. On anything else, or no answer, it
   refuses (exit 1): nothing has been written, and the report says why.
   `CHIE` must read `0x00` at the start (lead's decision, 2026-10-20). The
   tool checks the length but not the type (§4.1), so the type and size are
   part of this answer.
5. **Baseline**, exactly as note 10 §4 step 4: readings for at least 20 s
   and until they show 2 battery updates, all steady charging on AC power,
   at most 150 s. The probe validates it with check (a) of §4.5. The
   baseline ends when the CUT prompt is shown. If it fails, there is no
   CUT prompt: the run ends inconclusive, with nothing written.
6. **CUT prompt.** Only if the baseline passed check (a) and, at that
   moment, freshness check (b) of §4.5 holds (with no pre-cut readings
   yet). The probe shows the cut and read commands and says: **do not type
   the cut command yet**; type `cutnow` here; wait for the GO line; only
   then run the cut in the other terminal. It waits up to 120 s for
   `cutnow`, reading every 2 s. It applies check (b) to every reading it
   takes meanwhile; if one fails, it **withdraws** the prompt ("do not run
   the cut") and ends the run (below). If no `cutnow` comes within 120 s,
   it ends the same way.
7. **The cut mark, then GO.** `cutnow` is the cut time: the verdict's
   "creation". The probe applies check (b) at that moment. If it fails,
   the probe prints **NO GO — do not run the cut** and ends the run
   (below). If it holds, the probe first arms its restore reminder (§4.6),
   and only then prints one GO line with the clock time by which to
   restore (the mark plus the hold), for example
   `GO — run the cut now in terminal B. Restore by 10:18:02.`
   **No GO line, no cut.** The owner writes that time down or sets a phone
   timer for it, outside the terminal; then runs the cut, then the read;
   then types `cut08` if the read shows `(bytes 08)`, or `cutfail` if it
   shows anything else. The probe waits up to 90 s from the mark. On
   `cut08`, the cut is confirmed. On `cutfail`, anything else, or no
   answer, the cut is unconfirmed, the state of `CHIE` is unknown, and the
   probe goes to read-first (step 10).
8. **Hold:** 180 s by default, 165–300 s with `--hold`, measured from the
   cut mark. The probe stops the hold early when a reading is unreadable,
   shows 100% or charged, shows a charge below 25%, or shows a battery
   update more than 150 s old. Then, if the cut was confirmed and no sleep
   has come, it shows the RESTORE prompt at once (step 9); if the cut
   read-back is still pending, that question is superseded and the probe
   goes to read-first (step 10). Battery power is **not** a reason to stop
   early: it is the expected effect of a cut.
9. **RESTORE prompt** — only after a confirmed cut with no sleep since. At
   the end of the hold, or early as above. The probe shows the restore and
   read commands and says: type `restorenow` here; then run the restore in
   the other terminal at once; then run the read, and type `restored00` if
   it shows `(bytes 00)`, or `restorefail` if it shows anything else.
   Until the owner answers, its reminder shows the prompt again, with a
   terminal bell, every 20 s. `restorenow` is the restore time: the
   verdict's "release". On `restored00`, the restore is confirmed. On
   `restorefail`, or anything else, the state of `CHIE` is unknown, and the
   probe goes to read-first (step 10).
10. **Read-first** — every other restore request: a cut read-back that is
    unconfirmed or still pending, an early stop before confirmation, a
    restore read-back that is not `restored00`, or a sleep after the CUT
    prompt (§4.7). The probe
    supersedes any open question, prints the read-first steps of §7.1, and
    asks what the read showed; its reminder repeats them, with the bell,
    every 20 s until the owner answers:
    - `08`: the probe asks the owner to run the restore now and read again,
      and shows the re-check question: `recheck00` if that read shows
      `(bytes 00)`, `recheckfail` if not; `recheckfail`, or anything else,
      brings read-first back.
    - `00`: nothing to restore, and nothing is written; the report says so.
    - `other`: write nothing. The probe prints the recovery steps (§7.1),
      ends the readings, writes the report, opening with **CHECK RECOVERY
      FIRST**, and exits 3.

    The answer `08` is the restore time (the owner runs the restore after
    it), and so is `00` (with nothing written). Recovery is confirmed by
    `00`, or by `08` and then `recheck00`. A run that goes through
    read-first is always inconclusive; the report records each answer and
    whether, by those answers, a restore was written.
11. **After, and the end.** After a confirmed restore, readings for 180 s
    after the restore time, up to 120 s more until charging has resumed,
    as in note 10. Then the probe releases the idle-sleep assertion,
    deregisters from sleep notifications and writes the report.

**Any end after the CUT prompt without a confirmed restore** — a withdrawn
prompt, NO GO, no `cutnow` in time, `other` in read-first, Ctrl-C,
`SIGTERM`, `SIGHUP`, any error — prints
**RESTORE CHIE NOW** with the read-first recovery steps (§7.1), opens the
report with **CHECK RECOVERY FIRST**, and exits 3. The probe cannot know
whether the owner ran the cut or the restore. The report also opens that
way when the restore was confirmed but the last reading does not show
charging on adapter power (note 10 §4 step 8).

With the default hold and a prompt owner, the run takes about 7½ minutes:
about 20 s for the first read, a baseline of 20–60 s, a few seconds to
`cutnow`, the 180 s hold (the GO line, the cut and its read-back fall
inside it), about 20 s for the restore and its read-back, and 180 s after.
It takes up to about 12 minutes if the baseline waits for a battery update
or charging is slow to resume. The bounded waits are at most 120 s for the
first read, 150 s of baseline, 120 s at the CUT prompt, 300 s of hold (the
90 s for `cut08` is inside it) and 300 s after the restore: 990 s, about
16½ minutes. The wait for the owner's restore is not bounded, and the
probe keeps reminding until it ends.

Exit status, with note 10's meanings: 0 a verdict; 1 refused before the
CUT prompt; 2 inconclusive, but only for a run whose restore was confirmed
or that ended before the CUT prompt without a refusal; 3 "follow the
recovery steps the report prints" — a run whose restore was confirmed
but whose last reading does not show charging on adapter power (whether
it ran its course and charging did not resume, or a signal ended the
after readings early, §4.6), and **any end after the CUT prompt without a
confirmed restore**; 64 a usage error.

### 4.5 The marks, and the two checks at the cut

**Why the owner marks each write before running it.** Note 10 attributes
an effect to the creation only if the battery update that first shows it
was made after the creation, and it requires the effect to last until the
release. If the owner marked a write *after* running it, a battery update
made between the write and the mark could show the cut before the cut
time, or charging back before the restore time. Either would make a good
run inconclusive. With the mark first (`cutnow`; `restorenow`, or the
read-first answer `08`), every update made after a write is also made
after its mark, and note 10's rules apply unchanged.

The owner's delay between `cutnow` and the write (the GO line, noting the
restore time, switching windows, `sudo`'s password) falls inside the 90 s
effect window. A long delay makes a run inconclusive, never misjudged.

**The two checks at the cut, kept apart.** The evaluator applies them
separately:

- **(a) Baseline validation**: note 10's baseline rules, unchanged, over
  the baseline readings only — those taken before the CUT prompt was
  shown. At least 5 readings spanning 18–152 s, no gap over 4 s, every
  reading usable and steady charging on AC power, readings of at least 2
  distinct battery updates, and the clock rules.
- **(b) Freshness at the cut**, judged at the cut mark on the **pre-cut
  segment**: the readings taken after the CUT prompt was shown and before
  the mark, with note 10's thresholds:
  - every pre-cut reading usable and steady charging on AC power;
  - no gap over 4 s between consecutive readings, from the last baseline
    reading through the pre-cut readings to the mark;
  - the latest reading before the mark (the last pre-cut reading, or the
    last baseline reading if the segment is empty) at most 4 s old;
  - the latest battery update among the readings before the mark at most
    70 s old;
  - the clock rules over the baseline and pre-cut readings, with the mark
    as an event.

The pre-cut segment never counts toward the baseline, so check (a)'s
152 s limit is unaffected by a wait at the CUT prompt, and a good baseline
is not judged stale because the owner took 30 s to type `cutnow`. The
segment has no length rule of its own; the CUT prompt's 120 s bounds it.
For the assertion mechanisms of notes 09–10 the pre-cut segment is empty,
and check (b) is exactly today's freshness check on the baseline (the last
baseline reading at most 4 s old, its latest update at most 70 s old, the
clock rules up to the creation): notes 09–10 are unchanged. The probe
applies (b) on every pre-cut reading and at the mark, before GO; the
verdict applies (a) and (b) again. The observer's implementation therefore
gives the pre-cut readings a phase of their own, and gives the evaluator a
freshness check over the baseline, the pre-cut segment and the mark.

**How the readings around the marks are judged:**

- **Before the CUT prompt.** Baseline readings: check (a).
- **Between the CUT prompt and the cut mark.** The pre-cut segment: check
  (b), and the run's gap and clock rules; not judged for an effect. If the
  owner ran the cut before `cutnow`, the first update that shows the
  effect may be older than the mark, and note 10's rule then makes the run
  inconclusive.
- **Between the cut mark and the restore time.** Held readings, judged as
  in note 10, including those taken while the cut read-back is pending and
  while the RESTORE prompt waits: the cut is still in place, and the effect
  must last until the restore time. If the owner restored before
  `restorenow`, charging may come back "while held", and the run is
  inconclusive.
- **After the restore time.** After readings, judged as in note 10.

The confirming answers (`cut08`, `restored00`, `recheck00` and their
`fail` words) come after the marks and do not move them. The report gives the time of each mark and
each answer.

### 4.6 The restore: held by the owner, reminded by the probe

The probe cannot restore `CHIE`: it writes nothing. The restore is the
owner's, made with the tool in the owner's own terminal, and it needs
nothing from the probe. There is no powerd timeout for an SMC write, so
the reminders below are what stands in for one:

- **A restore time, printed before the cut.** The GO line carries the
  clock time by which to restore. The owner writes it down or sets a phone
  timer before running the cut, so it holds whatever happens to the probe
  or its terminal.
- **A reminder on its own timer**, armed at the cut mark **before** the GO
  line is printed: no GO line means no reminder, and then no cut. At the
  end of the hold it shows the current restore request — the RESTORE
  prompt, or the read-first steps (§4.4) — and it rings and shows the
  question open at that moment again, with its answer words, every 20 s
  until the owner has confirmed recovery (§4.4, "Questions and answer
  words"). It runs apart from the sampling loop
  and the report, so a reading that hangs does not hold it up. An early
  stop (§4.4 step 8) shows the request sooner.
- **No lock, no write.** The probe holds no lock that anything outside it
  waits on, and makes no write to any key or setting. Nothing it does can
  stand in the way of the owner's restore.
- **If the probe crashes, hangs or is killed** (even with `SIGKILL`), or
  terminal A closes, it reminds no one. Restore by the noted time anyway,
  reading first (§7.1): the cut is the owner's, not the probe's, and a dead
  probe does not stop the owner restoring.
- **If a tool command hangs.** If any read or write has not returned
  within about 10 s, press Ctrl-C in terminal B. A read that hangs, errors
  or prints something unexpected is not trustworthy: the state of `CHIE` is
  unknown; answer `other` if the probe asks, and follow §7.1.
- **No staged commands.** Never leave a cut command typed but not run. If
  the probe withdraws the CUT prompt, prints NO GO, or shows any restore or
  recovery request, first clear anything typed but not run in terminal B
  (Ctrl-C at the prompt). Recovery is never established while a cut
  command might still run.
- **Ctrl-C, `SIGTERM` or `SIGHUP` after the CUT prompt and before a
  confirmed restore** print RESTORE CHIE NOW with the read-first recovery
  steps, write the report opening with CHECK RECOVERY FIRST, and end the
  run with exit status 3. A second Ctrl-C quits at once, also with exit
  status 3, after printing RESTORE CHIE NOW once more. **After a confirmed
  restore** (`restored00`, or read-first's `00` or `recheck00`), a signal
  ends the after readings early and the run is inconclusive: exit status 2
  if the last reading shows charging on adapter power; otherwise the report
  opens with CHECK RECOVERY FIRST and the exit status is 3. Before the CUT
  prompt, a signal ends the run as in note 10, with nothing to restore. A closed terminal cannot show the
  `SIGHUP` warning, which is why the owner never closes terminal A during a
  run (§6).
- **What the probe cannot know:** whether the owner ran the cut or the
  restore, and what the tool printed. It records what the owner typed, and
  when. Every report calls the cut time, the restore time and every
  read-back **owner-confirmed**, not observed by the probe; whether a
  restore was written is unknown unless the answers show it.

### 4.7 Sleep

A process cannot cancel a sleep. `kIOMessageSystemWillSleep` announces a
sleep that cannot be aborted; withholding the acknowledgement only delays
it, by at most the 30-second timeout (`IOPMLib.h`, cited in note 10 §3).
The probe has nothing to do before a sleep: it holds no private assertion,
and it cannot restore `CHIE`. So it acknowledges at once, records the
notice in memory, with no I/O on the sleep queue (as in note 10), and
keeps its idle-sleep assertion, which a forced sleep overrides anyway and
which keeps the Mac awake for the restore after the wake.

**A sleep can therefore happen with `CHIE` still at `0x08`.** Whether a
cut survives sleep is not known (§8); one tool restores before sleep
(S12). After the wake, the main thread finds the notice. Before the CUT
prompt, the run ends inconclusive, with nothing to restore. After it, and
until a restore has been confirmed, the state of `CHIE` is unknown — the
sleep may or may not have cleared the cut — so the probe supersedes any
open question (discarding pending input), prints **RESTORE CHIE FIRST**,
and goes to read-first (§4.4 step 10), even if the RESTORE prompt was
showing. It carries on to the after readings once recovery is confirmed.
A sleep after a confirmed restore asks nothing new. Any sleep notification
makes the run inconclusive. What the owner's read showed after the wake is
worth sending with the report (§6): one observation, not a persistence
test (§8).

### 4.8 The verdict (reuses note 10)

The manual cut is judged by note 10's verdict rules, unchanged. A reading
is *charging*, *stopped*, *discharging* or *mixed* by the same thresholds;
a *sustained run* needs 5 counted readings over ≥ 8 s and ≥ 2 battery
updates; the effect must begin within 90 s of the **cut mark**, and
**every reading from the first effect until the restore time** must be
discharging, with the adapter reported attached and system power input ≤
1000 mW. Charging must resume within 120 s of the **restore time**,
measured from it once its read-back is confirmed; the probe keeps sampling
and recording while the confirmation is pending.

The test maps onto note 10's `ProbeRun`. The cut mark (`cutnow`) is the
"creation", which counts as accepted only if the owner then typed `cut08`;
without it, the run is inconclusive (not `refused`: there is no IOReturn,
and the probe cannot tell a refused write from one not made). The restore
time (`restorenow`, or the read-first answer `08` or `00`) is the
"release", confirmed only by `restored00`, by `recheck00` after `08`, or by
`00` — each an answer to a question shown after the latest supersession.
That confirmation is the analogue of `pmset -g assertions` no longer
listing an assertion. An unconfirmed restore opens the report with the
recovery steps, whatever the verdict.

The expected verdict for a working cut is **`adapter cut`** (outcome c of
note 10), or `adapter cut, resumed late`. `no effect observed` means the
owner confirmed `08` but every held reading still showed charging over ≥ 2
updates made after the cut mark — which, read against note 02 §3.4, would
mean this firmware ignores `CHIE` (for example because a native limit was
left on). `discharging with adapter attached`, `discharging, did not
resume` and `inconclusive` apply unchanged. `inhibited` would mean that
`CHIE` stopped charging without cutting adapter power; it is not expected,
and would be reported as it is.

**Evidence, owner-confirmed and observed.** A read-back shows only that
the key holds a value, as the tool reports it (§3.2). The evidence that
the value cuts the adapter is the readings: a sustained discharge with the
adapter reported attached and almost no input, beginning after the cut
mark and ending after the restore mark. The verdict needs both: the
owner's read-backs, and readings that agree with them.

**What telemetry cannot tell, carried forward from note 10 §4.** No reading
can tell an adapter cut from the owner unplugging the adapter. Here it is
sharper than in note 10: after a `CHIE` cut, `ExternalConnected` is
reported to go false (S4), and IOPowerSources is then likely to report
battery power. Neither is used to judge attachment. As note 10 §4 defines
it, the adapter counts as attached when `AppleRawExternalConnected` is yes
**or** `IOPSCopyExternalPowerAdapterDetails` returns an adapter; and a
reading counts as discharging whatever IOPowerSources says about the power
source. Whether either still reports an adapter during a cut is unknown
`[INFERRED/UNVERIFIED]`. If neither does, a real cut and an unplug look the
same, and the verdict is `inconclusive` with the times in its reason; the
owner's account of whether the adapter stayed plugged in (§6) is then the
only evidence, and the report never claims a definite unplug. A system
power input near zero, alone, shows neither that the adapter is attached
nor that the Mac draws nothing from it. The observer's tests must include
synthetic runs in which the connection signals disappear during the hold,
and in which the input power cannot be read, and check that neither is
judged an `adapter cut`.

## 5. Preconditions

`check --mechanism manual-adapter-cut` prints these and exits 0 if none
fails, 1 otherwise. `watch` checks them again and refuses on any failure.
Everything note 10 §5 checks for `disable-inflow` applies: on AC power,
battery present, charge below 95% and at least 40%, macOS charging now,
battery current, `UpdateTime` and `SystemPowerIn` readable, macOS's
Charge Limit at 100%, AlDente absent, no other battery-control daemon (a
warning), no `ChargeInhibit` or `DisableInflow` assertion held, and the
warnings for a charge outside 50–74% and for Optimized Battery Charging.
With these changes:

| Check | Fails / warns when | Why |
|---|---|---|
| Not run as root | `watch` **refuses** when the effective user is root | Nothing in `watch` needs privileges. The owner's two writes use `sudo`, in the tool's own terminal (§4.3). |
| Input and output are a terminal | `watch` **refuses** otherwise | Only the owner answers its questions, and every prompt is shown to the owner (§4.3). |
| Adapter reported attached | **fails** unless `AppleRawExternalConnected` is yes **or** `IOPSCopyExternalPowerAdapterDetails` returns an adapter (§4.8) | Without either, a cut can only end inconclusive, and every write carries risk. Note 10 keeps this check a warning for the two assertions; for `--mechanism manual-adapter-cut` only, it fails. |
| `CHIE` reads `00` (the owner's read) | `check` **always warns**: the probe reads no SMC key. `watch` asks the owner before the baseline and **refuses** unless the owner types `start00`: the tool printed `[hex_]`, one byte, `00` (§4.4 step 4). | `0x08` would mean something else already holds a cut, and any other value is an unknown state: either way, the restore value `0x00` would not return the key to where it started (lead's decision, 2026-10-20). The tool checks a write's length but not the key's type (§4.1), so the type and size are part of the owner's answer (note 02 §6, "writing unknown keys or wrong widths"). |
| macOS's Charge Limit is 100% | **fails** below 100% (note 10 already checks this) | `CHIE` is reported ignored while the native limit is active (§3.3); the limit must be off for a meaningful result. |

## 6. Owner steps

Use two terminals: **A** for the probe, in `Tools/charge-inhibit-probe` of
the CellKeeper checkout, and **B** for the tool, in
`~/smc-test/smc-command`. Each prompt of the probe shows the exact command
and the exact answer word to type; §4.1 has the commands and §4.4 the
words.

1. As in note 10 §6: AlDente fully removed, and the probe built, in
   terminal A —

   ```sh
   swift build -c release --package-path Tools/charge-inhibit-probe
   cd Tools/charge-inhibit-probe
   ```

2. Build the tool in terminal B, outside the checkout (§4.1). Install
   nothing from it.
3. In **System Settings › Battery › ⓘ next to Charging**, set the **Charge
   Limit to 100%** and turn **Optimized Battery Charging off**, for the
   whole experiment. The charge must be at least 40%; 50–74% is best.
4. Connect the Apple power adapter and wait until the battery menu shows it
   charging. Keep the lid open and the Mac on a hard surface, and stay with
   it. Quit anything heavy (builds, games, video exports) and leave it idle
   during the run. If the Mac gets unusually hot, press Ctrl-C in terminal
   A. Unless you have already confirmed the restore, it prints the
   read-first steps (§7.1): follow them at once. Either way, check recovery
   (step 8).
5. **Rules for the whole run:**
   - Do not touch the adapter or its cable, and do not close the lid or let
     the Mac sleep. The run is expected to leave the Mac running from its
     battery while the adapter is plugged in, for the hold (3 minutes by
     default): that is the effect. The probe cannot tell a cut from an
     unplugged adapter, so it relies on you not touching it (§4.8). If the
     Mac does sleep, follow the read-first steps when it wakes (step 8).
   - **Never close terminal A during a run.** A closed terminal cannot show
     the probe's warnings. If it closes, follow §7.1 at once.
   - **No GO line, no cut.** Type the cut command in B only after A has
     printed its GO line, and never leave it typed but not run. If A
     withdraws the CUT prompt, prints NO GO, or shows any restore or
     recovery request, first clear anything typed but not run in B
     (Ctrl-C at the prompt).
   - If any tool command, read or write, has not returned within about
     10 s, press Ctrl-C in B. A read that hangs, errors or prints something
     unexpected is not trustworthy: answer `other` if A asks, and follow
     §7.1.
6. Check, in terminal A, without privileges:

   ```sh
   .build/release/charge-inhibit-probe check --mechanism manual-adapter-cut
   ```

   It must end with `READY`. Fix any `FAIL` line first; read the `WARN`
   lines.
7. Start the test in terminal A, **without** `sudo`:

   ```sh
   .build/release/charge-inhibit-probe watch --mechanism manual-adapter-cut
   ```

   Then do what it asks, in this order:
   1. **First read.** Run the read in B. Type `start00` in A only if it
      printed `[hex_]` and `(bytes 00)`.
   2. **Baseline.** Wait: 20 s to 2½ minutes. Type nothing in B.
   3. **CUT.** Type `cutnow` in A and wait for the GO line. **No GO line,
      no cut.** Write down the restore time the GO line shows, or set a
      phone timer for it. Then, at once, type and run the cut command in
      B (`sudo` may ask for your password), then run the read in B: GO
      means run the cut now, and the read-back is expected within 90 s
      (the first attempt in §10 missed this). Type `cut08` in A only if
      the read shows `(bytes 08)`; if it shows anything else, type
      `cutfail`: A then shows the read-first steps (step 7.5).
   4. **Hold.** 3 minutes by default. The Mac is expected to run from its
      battery with the adapter plugged in. Leave everything as it is.
   5. **RESTORE or read-first.** When A rings:
      - If it shows the **RESTORE** prompt: type `restorenow` in A, then at
        once run the restore in B, then the read. Type `restored00` in A
        only if the read shows `(bytes 00)`; otherwise type `restorefail`,
        and A shows the read-first steps.
      - If it shows the **read-first** steps: run the read in B and type
        what it showed: `08`, `00` or `other`. After `08`, run the restore
        and read again; type `recheck00` only if that read shows
        `(bytes 00)`, otherwise `recheckfail`.

      **If the restore time has passed and A shows nothing — it stopped,
      crashed, hangs or its window closed — follow §7.1 anyway.**
   6. **After.** 3 to 5 minutes of readings; then the report.

   The whole run takes about 7½ minutes with the default hold, up to about
   12. Ctrl-C ends it at any time. After the CUT prompt and before you
   have confirmed the restore, it prints RESTORE CHIE NOW, and you follow
   the read-first steps (§7.1). After a confirmed restore, it only ends the
   after readings early (§4.6); still check recovery (step 8).
8. **After the run, check recovery first** — and if the Mac slept during
   the run, as soon as it wakes. Recovery counts only when **both** hold: a
   read in B shows `(bytes 00)`, **and** the battery menu shows the power
   adapter again, and charging. If either fails, or the report or the
   console says CHECK RECOVERY FIRST, follow §7.1. **A crash or a sleep
   does not undo the cut.**
9. Only then set the Charge Limit and Optimized Battery Charging back the
   way you want them, and send the file
   `Tools/charge-inhibit-probe/charge-inhibit-probe-manual-adapter-cut-<timestamp>.txt`
   to the lead, saying whether the adapter stayed plugged in the whole time
   and what each read printed. Git ignores these files. Then delete
   `~/smc-test`.

## 7. Safety

- **What changes.** The owner's tool sets one SMC key, `CHIE`, to `0x08`
  for the hold (180 s by default, at most 300 s, plus however long the
  restore takes) and back to `0x00`, the value it must read at the start.
  No other key and no other value. The probe changes nothing: it holds one
  public idle-sleep assertion and a sleep registration for the run, and
  writes its report. No `pmset` setting, no launchd job, no file but the
  report and the owner's build of the tool in `~/smc-test`.
- **Running from the battery.** When `CHIE` is `0x08`, the Mac runs from its
  battery while plugged in. At the 10–16 W it draws while not charging,
  300 s is about 1 Wh, a percent or two `[INFERRED/UNVERIFIED]`; a heavy
  workload draws more and warms the battery, so the owner leaves the Mac
  idle and, on unusual heat, stops the run and restores at once (§6). The
  probe asks for the restore at once if the charge falls below 25% (note 02
  §7 puts the floor for an adapter cut at about 25–30%), and refuses to
  start below 40% (§5).
- **No self-release.** A written SMC key is **not** freed when anything
  exits. The restore is the owner's, with the tool, and it needs nothing
  from the probe. The probe arms its reminder at the cut mark and only then
  prints the GO line with the restore time, which the owner notes outside
  the terminal before running the cut (§4.6). No GO line, no cut. If the
  probe crashes, hangs or is killed after GO, it reminds no one; the owner
  restores by the noted time anyway. **Unknown: whether unplug/replug,
  sleep or a restart clears `CHIE`** — the published Apple source does not
  say, and this test does not measure persistence (§8).
- **Sleep.** A closed lid, the Apple menu or a low battery still sleeps the
  Mac; the idle-sleep assertion stops only idle sleep. A process cannot
  cancel a sleep: withholding the acknowledgement would delay it by at most
  the 30-second timeout (`IOPMLib.h`), and the probe has nothing to do in
  that time, so it acknowledges at once. A sleep can therefore happen with
  `CHIE` still at `0x08`; after the wake the owner follows the read-first
  steps (§4.7, §6 step 8). A sleep makes the run inconclusive.
- **The tool.** It is unmaintained, and its README warns that writing SMC
  values could irreversibly damage the computer. The test keeps that risk
  as small as it can: one key; two values that two independent projects
  use (§3.1); a read before each write that must show the expected type,
  size and value; the tool's own length check; and no enumeration.
- **The report's directory.** The probe guards against its own failures
  and against files left by earlier runs, but does not defend against
  another process renaming or replacing files in the directory it writes
  its report to during a run.
- **What the probe never does:** run as root; open a user client of the
  SMC or the battery manager; read or write any SMC key; run the tool,
  start any process for it, or read what it prints; run without a terminal
  for its input and its output; take an answer typed before its question
  was shown; create any assertion but the public idle-sleep one; change
  `pmset` settings; read the AlDente helper's files; keep anything of the
  adapter details but presence and wattage.
- **What agents never do:** run `sudo`; run the tool; read or write any
  SMC key; run `watch`; change System Settings.

### 7.1 Recovery steps

Follow these steps if adapter power did not come back after the run, if
the probe did not confirm the restore, if the report or the console says
CHECK RECOVERY FIRST or RESTORE CHIE NOW, if the probe stopped or terminal
A closed after the CUT prompt, or after a sleep. The probe shows step 1
itself as its read-first steps (§4.4 step 10), and asks for an answer.

First, clear anything typed but not run in terminal B (Ctrl-C at the
prompt). Recovery is never established while a cut command might still
run.

1. **Read `CHIE`** with the tool (§4.1). Never write before this read. If
   the read has not returned within about 10 s, press Ctrl-C and treat it
   as "anything else".
   - `(bytes 08)`: if the probe asks, type `08`. Run the restore, then read
     again; if the probe asks, type `recheck00` only if that read shows
     `(bytes 00)`, otherwise `recheckfail`, and start again at step 1.
   - `(bytes 00)`: nothing to restore; write nothing. If the probe asks,
     type `00`. Go to step 2 if the Mac still runs from its battery.
   - Anything else — another value, an error, a hang, or output you do not
     trust: the state is unknown. **Write nothing.** If the probe asks, type
     `other`. Go to step 3.

   Recovery counts only when a read shows `(bytes 00)` **and** the battery
   menu shows the power adapter again.
2. **`CHIE` reads `00`, but the Mac still runs from its battery.** Wait a
   minute: a cut is reported to act within seconds (S4), and the menu may
   lag. Check that the adapter is plugged in firmly at both ends and that
   its outlet works. Write nothing else, to `CHIE` or to any other key.
3. If adapter power still does not show, the Mac is running from its
   battery. **Save your work.**
4. Then try, in order, reading `CHIE` after each and restoring it if it
   reads `08`:
   1. unplug the adapter, wait a few seconds, and plug it back in;
   2. restart the Mac;
   3. shut it down, wait about 30 seconds, and start it again.

   None of these is known to clear `CHIE` (§8); they are attempts, not a
   verified fix. Apple's support article says the SMC resets automatically
   on Macs with Apple silicon (note 02 §1.8); whether that clears `CHIE` is
   not known.
5. If adapter power still does not come back, **shut the Mac down before
   the battery runs low**, and send the report and what each read printed
   to the lead. If a Mac that was shut down still does not take power from
   its adapter when started again, ask Apple Support for help.

These steps extend
[`safety.md`, "If charging does not resume"](../safety.md#if-charging-does-not-resume),
which has the same steps.

## 8. Open questions

1. Does writing `CHIE 0x08` make this M4, on macOS 27.0.1 with firmware
   20457.1.29, run from its battery with the adapter attached, and does
   `CHIE 0x00` bring adapter power and charging back? The owner's test,
   observed by `watch`, answers this. *Answered on 2026-10-20 (§10), for
   one run: yes, by the owner's account that the adapter stayed plugged
   in. The cut also hid the adapter from every reading the probe makes.*
2. Does `CHIE` read as `[hex_]`, one byte, `00` on this Mac, as the
   reports say (§3.1)? The owner's first read answers this, before any
   write. *Answered on 2026-10-20 (§9, §10): yes, in both attempts.*
3. **Does a written `CHIE` outlive its writer?** Specifically, does
   unplug/replug, sleep, or a restart clear it, or does it stay `0x08`?
   Not tested here (lead's decision, 2026-10-20). A persistence run
   (unplug/replug, sleep, restart; note 02 §7, Phase D) is **an owner
   decision** for before any helper work: it decides whether CellKeeper's
   own control needs a startup reconciliation and an uninstaller restore
   (note 02 §6). *Still open: in the run of §10, the owner restored `CHIE`
   by hand while the Mac was awake and plugged in.*
4. Is `CHIE` ignored while the native Charge Limit is on, as reported
   (§3.3)? The test is done with the limit off, so this is not measured
   here; it matters because CellKeeper's own control must turn the native
   limit off. *Still open: the limit was off for the run of §10.*
5. On Apple silicon the matched service is an RTKit SMC endpoint, not the
   Intel AppleSMC device (§9). Does a client written for the Intel device
   read and write `CHIE` through it? The owner's reads and writes answer
   this for that tool only; they say nothing about any client CellKeeper
   might have. *Answered for that tool only (§10): its reads showed the
   values its writes had just made, and the effect followed each write.*
6. Reading the sibling adapter keys (`CH0I`/`CH0J`) or the inhibit keys
   (`CHTE`) read-only would characterise this firmware's generation, but
   each is a key outside the allowlist and is **deliberately not read**;
   the allowlist is `CHIE` only (§2; lead's decision, 2026-10-20), and the
   owner never uses the tool's `-l`, `-f` or `-t`. Reading any of them,
   even read-only, needs its own owner decision.
7. **If `CHIE` works, how would CellKeeper write it?** CellKeeper's own
   helper would need an SMC write layer, and agents will not write one
   (§2.2). This is **the next owner decision** after the result: a layer
   the owner writes; an existing external tool that the helper uses, which
   raises licence, signing and safety questions of its own; or stopping at
   macOS's native 80–100% limit. Nothing is decided here. *The result of
   §10 makes this the owner's next decision.*
8. **Can anything tell a `CHIE` cut from an unplugged adapter?** During
   the cut in §10, no reading the probe makes reported the adapter
   (IOPowerSources, `ExternalConnected`, `AppleRawExternalConnected`,
   `IOPSCopyExternalPowerAdapterDetails`). Whether any other read-only
   signal still does, so that CellKeeper's own control could notice a
   real unplug during a cut, is not investigated; any new read would need
   its own review. *Added on 2026-10-20, after §10.*

## 9. Pre-run state

`[VERIFIED-EXPERIMENTALLY]` (read-only registry inspection, 2026-10-20): on
this Mac, `ioreg -r -c AppleSMC -d 1` returns a single entry of class
`AppleSMCKeysEndpoint` (a subclass of `AppleSMC`, which is why a lookup by
that service name finds it), whose provider class is
`RTBuddyEndpointService` and whose user-client class is `AppleSMCClient`.
This confirms note 02 §3.1: the Apple-silicon SMC is an RTKit endpoint, not
the Intel AppleSMC device the interface in §3.2 was written for. Only the
class names were read; no key was read, and no user client was opened.

The tool, checked by the lead on 2026-10-20 (compile only): at the pinned
commit, a syntax-only compile of `smc.c` on this Mac (Apple clang 21.0.0,
macOS 27.0.1) gave 7 warnings (deprecations and format strings) and no
errors, and a trivial file built with the Makefile's
`-mmacosx-version-min=10.4` linked on arm64. No agent built or ran the
tool, and no key was read.

The read-only `check --mechanism manual-adapter-cut`, run by the lead as an
ordinary user on 2026-10-20 at 21:29 local, just before the owner's runs,
follows. Nothing was created. It ran in the owner's checkout, which the
lead had first fast-forwarded to `befeec1` (#101) and rebuilt: the owner's
first `check` had printed the usage text of the probe before #101, which
has no `--mechanism` option.

```text
CellKeeper manual adapter-cut probe: check (read-only; creates nothing)
machine: Mac16,1, macOS 27.0.1 (26A434), system firmware mBoot-20457.1.29
This probe reads no SMC key and runs no tool: the owner reads and writes CHIE by hand,
with the external tool, in another terminal (docs/research/11-smc-adapter-cut.md).

Current reading
clock          time phase     AC   charging   charged     %  mA instant/avg   reg.charging  reg.ext  raw.ext  adapter  NotChargingReason  SysPowerIn mW  upd.age  state
21:29:18    +0.0 baseline  yes  yes        -          81   2582/2582        yes           yes      yes      68 W     0x0                58021          9 s      charging

Preconditions
PASS  On AC power: IOPowerSources reports AC power (AppleSmartBattery ExternalConnected: yes)
PASS  Battery present: the internal battery is present
PASS  Charge below 95%: 81%
PASS  Charge at least 40%: 81%
PASS  macOS is charging now: IOPowerSources reports charging; battery current 2582 mA
PASS  Battery current readable: InstantAmperage 2582 mA, Amperage 2582 mA
PASS  Battery update time readable: AppleSmartBattery UpdateTime, 9 s old
PASS  System power input readable: PowerTelemetryData.SystemPowerIn 58021 mW
PASS  Adapter reported attached: AppleRawExternalConnected: yes; IOPSCopyExternalPowerAdapterDetails: an adapter
PASS  macOS's Charge Limit is 100%: pmset -g battlimit: no battery level limits set
PASS  No AlDente helper files: neither of its helper files exists
PASS  AlDente helper not loaded: launchctl print system/com.apphousekitchen.aldente-pro-setapp.helper: could not find service
PASS  No AlDente process running: no executable path or name in the process table matches AlDente
PASS  No other battery-control daemon: no file name in /Library/LaunchDaemons or /Library/PrivilegedHelperTools suggests one
PASS  No ChargeInhibit or DisableInflow assertion held: pmset -g assertions lists neither
WARN  Charge in the recommended 50–74%: 81%: if Optimized Battery Charging is on, macOS may pause charging near 80% by itself and confuse the result. Turn it off for the test (System Settings › Battery › ⓘ next to Charging), or start below 75%
WARN  Optimized Battery Charging off: the probe cannot read this setting: turn it off for the whole test (System Settings › Battery › ⓘ next to Charging), so that macOS does not pause charging by itself
WARN  CHIE reads 00 (the owner's read): the probe reads no SMC key, so it cannot see CHIE. `watch` asks you to read it with the tool (./smc -k CHIE -r, in ~/smc-test/smc-command) before the baseline, and refuses unless it printed [hex_] and (bytes 00)

The owner's tool commands (run them yourself, in ~/smc-test/smc-command; the probe never does)
read:    ./smc -k CHIE -r
cut:     sudo ./smc -k CHIE -w 08
restore: sudo ./smc -k CHIE -w 00

READY: every precondition holds; `charge-inhibit-probe watch --mechanism manual-adapter-cut` may be started, without sudo. Read the 3 warnings above.
```

`[VERIFIED-EXPERIMENTALLY]` (read-only): the Charge Limit was 100% and the
Mac was charging at 2.6 A, with the adapter reported attached by both
reads, at 68 W. The charge was 81%, above the recommended 50–74%, so
`check` warned (§5); Optimized Battery Charging was to be off for the
whole test (§6).

The owner's first read of `CHIE` (§4.4 step 4) showed `[hex_]` and
`(bytes 00)` in both attempts (§10): the owner typed `start00` each time.
The probe records the owner's answer words, not what the tool printed.

## 10. Results

The owner ran `watch` twice on 2026-10-20, following §6, with the probe
built from `befeec1` and the tool at its pinned commit. The first attempt
wrote nothing and does not count. The second made the one cut and the one
restore that §2.2 allows, each read back. No sleep notification arrived in
either.

**The first attempt (21:30:49, wrote nothing).** The owner read `CHIE` as
`00` (`start00`, +53.2 s) and typed `cutnow` (+110.1 s); the probe printed
its GO line. The owner had not understood that GO meant running the cut at
once, and ran no write. With no `cut08` within 90 s, the probe showed the
read-first steps (+200.1 s); the owner typed `00` (nothing to restore,
nothing written; +247.3 s), and the run ended after its after readings
(+427.4 s). The owner's shell history shows no read of `CHIE` between the
first read (21:31:17) and the second run's first read (21:42:17), so that
`00` rests on the earlier read and on no write having been made, not on a
fresh read. Verdict: `inconclusive` ("the restore went
through the read-first steps: no cut08 within 90 s of the cut mark").
Every one of its 188 readings showed charging, from 82 to 87%. §6 step
7.3 now says that GO means running the cut at once. Between the two runs
the owner unplugged the adapter (the owner's account): at 21:39 and 21:40
the lead's read-only `pmset -g batt` and `ioreg` showed the Mac on battery
power with no adapter reported, and the shell history shows no `CHIE`
write. It was plugged in again, and reported attached, when the second
run's preconditions were checked.

**The second run (21:42:11): the result.**

| Field | Value |
|---|---|
| Date and time | 2026-10-20 21:42:11 +11:00 |
| macOS build, firmware | Mac16,1, macOS 27.0.1 (26A434), mBoot-20457.1.29 |
| Hold | 180 s from the cut mark (the default), after a 42 s baseline of 22 readings (+11.0 to +53.0 s) and 7 readings before the cut mark; readings continued for 180 s after the restore mark |
| Sleep notifications registered; idle-sleep assertion IOReturn (creation / release) | yes; `0x0` at +0.0 s / `0x0` at +447.5 s; no sleep notification arrived |
| What each read showed (the owner's answer words) | Before the cut: `[hex_]`, `(bytes 00)` (`start00`, +11.0 s). After the cut: `(bytes 08)` (`cut08`, +96.5 s). After the restore: `(bytes 00)` (`restored00`, +288.2 s) |
| Cut mark, and the cut | `cutnow` at +68.7 s (about 21:43:20). The owner's shell history (zsh's start time of each command, to the second) shows the cut entered at 21:43:25 and the read at 21:43:37 |
| Restore mark, and the restore | `restorenow` at +267.4 s (about 21:46:38), 18.7 s after the RESTORE prompt. The shell history shows the restore entered at 21:46:49 and the read at 21:46:52 |
| Battery updates in the baseline / held / after the restore mark | 2 / 4 (21:43:35, 21:44:35, 21:45:35, 21:46:35) / 4 (21:46:48, 21:47:48, 21:48:48, 21:49:34) |
| Adapter reported during the cut | Not attached, in every reading from 21:43:36 (+85.0 s) to 21:46:48 (+277.0 s): IOPowerSources reported battery power, `ExternalConnected` and `AppleRawExternalConnected` were no, and `IOPSCopyExternalPowerAdapterDetails` returned no adapter. The reading at 21:43:34 still reported the 68 W adapter |
| Effect, and when it began | Discharging. The first battery update after the cut, at 21:43:35, showed 997 mA into the battery with the charging flag off (`mixed`); the next three showed −1094, −1075 and −1099 mA. By the probe's count the discharge began 76.4 s after the cut mark and lasted until the restore. The charge stayed at 88% |
| System power input | 48 348 mW at the last update before the cut; 32 222 mW at 21:43:35; then 526, 528 and 529 mW |
| Adapter power back, and charging resumed, after the restore | The 68 W adapter was reported again from 21:46:50; the reading at 21:46:48 did not report it. The update at 21:46:48 still showed −1086 mA; the next, at 21:47:48, showed charging at 2569 mA and 49 128 mW of input, from the reading at 21:47:50, 71.6 s after the restore mark. Then 2590 and 2614 mA, 88 to 89% |
| Verdict | `inconclusive`: 62 of the 62 readings while it discharged did not report the adapter attached (§4.8) |
| Adapter stayed plugged in (the owner's account) | Yes, the whole time (the owner's message, 2026-10-20) |
| Notes | The charge was 88% at the start (`check` warned, §5); Optimized Battery Charging was to be off for the whole test (§6). `NotChargingReason` read `0x1000` (undocumented, not decoded) during the cut and until the first charging update after the restore. Recovery, after the run: the owner's last read showed `(bytes 00)` (`restored00`), and at 21:50 the lead's read-only `pmset -g batt` and `ioreg` showed the Mac on AC power and charging, at 89% |

The second run's report follows, with runs of sample rows whose values
only differ in the update's age shortened, the warnings' text, the column
legend, the criteria (§4.8) and the closing privacy line left out, and
the title and section underlines removed; bracketed text is not in the
report. It contains no serial numbers, user names or home paths.

```text
started:   2026-10-20 21:42:11 +11:00
machine:   Mac16,1, macOS 27.0.1 (26A434), system firmware mBoot-20457.1.29
test:      research note 11's manual adapter cut. The owner reads and writes the SMC key
           CHIE by hand, with an external tool; this probe reads no SMC key, runs no tool,
           and only observes. Hold 180 s from the owner's cut mark.
           The cut time, the restore time and every read-back are owner-confirmed, not
           observed by the probe.

Preconditions
PASS  On AC power: IOPowerSources reports AC power (AppleSmartBattery ExternalConnected: yes)
PASS  Battery present: the internal battery is present
PASS  Charge below 95%: 88%
PASS  Charge at least 40%: 88%
PASS  macOS is charging now: IOPowerSources reports charging; battery current 410 mA
PASS  Battery current readable: InstantAmperage 410 mA, Amperage 410 mA
PASS  Battery update time readable: AppleSmartBattery UpdateTime, 8 s old
PASS  System power input readable: PowerTelemetryData.SystemPowerIn 17358 mW
PASS  Adapter reported attached: AppleRawExternalConnected: yes; IOPSCopyExternalPowerAdapterDetails: an adapter
PASS  macOS's Charge Limit is 100%: pmset -g battlimit: no battery level limits set
PASS  No AlDente helper files: neither of its helper files exists
PASS  AlDente helper not loaded: launchctl print system/com.apphousekitchen.aldente-pro-setapp.helper: could not find service
PASS  No AlDente process running: no executable path or name in the process table matches AlDente
PASS  No other battery-control daemon: no file name in /Library/LaunchDaemons or /Library/PrivilegedHelperTools suggests one
PASS  No ChargeInhibit or DisableInflow assertion held: pmset -g assertions lists neither
WARN  Charge in the recommended 50–74%: 88%: [warning about Optimized Battery Charging]
WARN  Optimized Battery Charging off: the probe cannot read this setting: [reminder to turn it off]
WARN  CHIE reads 00 (the owner's read): the probe reads no SMC key, so it cannot see CHIE. [how watch asks for the read]

READY: every precondition holds; `charge-inhibit-probe watch --mechanism manual-adapter-cut` may be started, without sudo. Read the 3 warnings above.

The owner's answers (owner-confirmed; the probe observed no read and no write)
+11.0 s: first read: typed start00: CHIE read 00 at the start, by the owner's read
+68.7 s: CUT: typed cutnow: the cut mark
+96.5 s: cut read-back: typed cut08: the cut read back 08, by the owner's read
+267.4 s: RESTORE: typed restorenow: the restore mark
+288.2 s: restore read-back: typed restored00: the restore read back 00, by the owner's read
restore written: By the owner's answers, the restore command was run once
(restorenow, or read-first 08). The probe observed no write.

Events
sleep notifications: registered (IORegisterForSystemPower)
+0.0 s: IOPMAssertionCreateWithProperties (PreventUserIdleSystemSleep) returned 0x0 (kIOReturnSuccess)
+447.5 s: IOPMAssertionRelease (PreventUserIdleSystemSleep) returned 0x0 (kIOReturnSuccess)
+0.0 s: watch started; the first read was asked for
+11.0 s: the owner confirmed CHIE read [hex_] and (bytes 00) (start00); the
baseline began
+53.0 s: the CUT prompt was shown
+68.7 s: the cut mark (cutnow); the reminder armed, then GO
+96.5 s: the owner confirmed the cut read back (bytes 08) (cut08)
+248.7 s: the hold ended; the RESTORE prompt
+267.4 s: the restore mark (restorenow); the owner runs the restore now
+288.2 s: the owner confirmed recovery (restored00); the after readings
+447.4 s: the after readings ended
+447.4 s: the run ended
GO line: restore by 21:46:20
readings: 22 baseline, 7 pre-cut (between the CUT prompt and the cut mark), 100 held, 90 after

Samples (every 2 s)
clock          time phase     AC   charging   charged     %  mA instant/avg   reg.charging  reg.ext  raw.ext  adapter  NotChargingReason  SysPowerIn mW  upd.age  state
21:42:22   +11.0 baseline  yes  yes        -          88   410/410          yes           yes      yes      68 W     0x0                17358          19 s     charging
  [… 19 rows with the same values, the update age rising …]
21:43:02   +51.0 baseline  yes  yes        -          88   410/410          yes           yes      yes      68 W     0x0                17358          59 s     charging
21:43:04   +53.0 baseline  yes  yes        -          88   2591/2591        yes           yes      yes      68 W     0x0                48348          1 s      charging
21:43:06   +55.0 pre-cut   yes  yes        -          88   2591/2591        yes           yes      yes      68 W     0x0                48348          3 s      charging
  [… 5 rows with the same values, the update age rising …]
21:43:18   +67.1 pre-cut   yes  yes        -          88   2591/2591        yes           yes      yes      68 W     0x0                48348          15 s     charging
21:43:20   +69.0 held      yes  yes        -          88   2591/2591        yes           yes      yes      68 W     0x0                48348          17 s     charging
  [… 6 rows with the same values, the update age rising …]
21:43:34   +83.0 held      yes  yes        -          88   2591/2591        yes           yes      yes      68 W     0x0                48348          31 s     charging
21:43:36   +85.0 held      no   no         -          88   997/997          no            no       no       no       0x1000             32222          1 s      mixed
  [… 28 rows with the same values, the update age rising …]
21:44:34  +143.0 held      no   no         -          88   997/997          no            no       no       no       0x1000             32222          59 s     mixed
21:44:36  +145.0 held      no   no         -          88   -1094/-1094      no            no       no       no       0x1000             526            1 s      discharging, battery power
  [… 28 rows with the same values, the update age rising …]
21:45:34  +203.0 held      no   no         -          88   -1094/-1094      no            no       no       no       0x1000             526            59 s     discharging, battery power
21:45:36  +205.0 held      no   no         -          88   -1075/-1075      no            no       no       no       0x1000             528            1 s      discharging, battery power
  [… 28 rows with the same values, the update age rising …]
21:46:34  +263.0 held      no   no         -          88   -1075/-1075      no            no       no       no       0x1000             528            59 s     discharging, battery power
21:46:36  +265.0 held      no   no         -          88   -1099/-1099      no            no       no       no       0x1000             529            1 s      discharging, battery power
21:46:38  +267.1 held      no   no         -          88   -1099/-1099      no            no       no       no       0x1000             529            3 s      discharging, battery power
21:46:40  +269.0 after     no   no         -          88   -1099/-1099      no            no       no       no       0x1000             529            5 s      discharging, battery power
  [… 3 rows with the same values, the update age rising …]
21:46:48  +277.0 after     no   no         -          88   -1099/-1099      no            no       no       no       0x1000             529            13 s     discharging, battery power
21:46:50  +279.1 after     yes  no         no         88   -1086/-1086      no            yes      yes      68 W     0x1000             526            2 s      discharging
  [… 28 rows with the same values, the update age rising …]
21:47:48  +337.1 after     yes  no         no         88   -1086/-1086      no            yes      yes      68 W     0x1000             526            60 s     discharging
21:47:50  +339.0 after     yes  yes        -          88   2569/2569        yes           yes      yes      68 W     0x0                49128          2 s      charging
  [… 28 rows with the same values, the update age rising …]
21:48:48  +397.0 after     yes  yes        -          88   2569/2569        yes           yes      yes      68 W     0x0                49128          60 s     charging
21:48:50  +399.0 after     yes  yes        -          88   2590/2590        yes           yes      yes      68 W     0x0                49501          2 s      charging
  [… 21 rows with the same values, the update age rising …]
21:49:34  +443.0 after     yes  yes        -          88   2590/2590        yes           yes      yes      68 W     0x0                49501          46 s     charging
21:49:36  +445.1 after     yes  yes        -          89   2614/2614        yes           yes      yes      68 W     0x0                49869          2 s      charging
21:49:38  +447.0 after     yes  yes        -          89   2614/2614        yes           yes      yes      68 W     0x0                49869          4 s      charging

Verdict: inconclusive
The run cannot decide: the battery discharged 76.4 s after the owner's cut
mark and until the restore, and charging resumed 71.6 s after the restore, but
62 of the 62 readings while it discharged did not report the adapter attached
(AppleRawExternalConnected or the adapter details). An adapter unplugged at
those moments would look the same. If the adapter stayed plugged in the whole
time, the adapter's power was cut. Nothing about the adapter cut is concluded
from it.
```

### Interpretation

- `[VERIFIED-EXPERIMENTALLY]` By the owner's account that the adapter
  stayed plugged in, writing `CHIE` `08` with the tool cut the adapter's
  power on this Mac, macOS build and firmware, with the native Charge
  Limit off. The adapter stopped being reported between the cut command
  and the owner's read-back of it (21:43:25 and 21:43:37); from the
  first discharging reading, 76.4 s after the cut mark, until the
  restore, about two minutes, every update showed the battery discharging
  at about 1.1 A with about 0.5 W of system power input. Writing `00`
  brought the adapter back at once, and charging at the next full battery
  update. This answers §8 questions 1 and 2. It is one run, on one Mac.
- `[VERIFIED-EXPERIMENTALLY]` The cut hid the adapter from every reading
  the probe makes, not only from `ExternalConnected` as reported (S4): it
  also turned `AppleRawExternalConnected` false and left
  `IOPSCopyExternalPowerAdapterDetails` with no adapter, the two signals
  note 10 relies on to tell a cut from an unplug. §4.8 allowed for this.
  On this firmware, then, the readings alone cannot tell a `CHIE` cut from
  an unplugged adapter, and the probe's verdict is `inconclusive` by
  design; it never claims a definite unplug.
- Two things make it a cut, not an unplug. The owner's account, which
  §4.8 makes the deciding evidence. And the timing, from the owner's shell
  history against the probe's readings `[VERIFIED-EXPERIMENTALLY]`: the
  adapter disappeared between the readings at 21:43:34 and 21:43:36, after
  the cut was entered at 21:43:25 (`sudo` may have asked for a password
  first) and before the read at 21:43:37 that showed `08`; it came back
  between the readings at 21:46:48 and 21:46:50, within about a second of
  the restore entered at 21:46:49.
- `[VERIFIED-EXPERIMENTALLY]` The adapter's state changed from one 2 s
  reading to the next, but the battery current and the system power input
  changed only at the battery's updates. (Update times here are
  reconstructed as a reading's clock minus the update's age, to the
  second.) The first update after the cut command, at about 21:43:35,
  showed 997 mA into the battery with the charging flag off and 32 222 mW
  of input (`mixed`); the update at about 21:46:48, around the restore
  command (entered at 21:46:49), still showed discharging. Updates came
  about once a minute, and sooner three times: at about 21:43:35 (32 s
  after the previous one), 21:46:48 (13 s) and 21:49:34 (46 s, as the
  charge went from 88 to 89%).
- `[INFERRED/UNVERIFIED]` The `mixed` update most likely straddled the
  moment of the cut, and the two early updates around the cut and the
  restore were most likely set off by the change of power state, as note
  10 §10 saw updates set off by a change of charge.
- **Not tested:** whether `CHIE` stays `08` across unplug/replug, sleep or
  a restart (§8 question 3), or whether the native limit makes it ignored
  (question 4); longer cuts, repeated cuts, other charge levels, and other
  Macs, macOS builds or firmware.

### What it means for phase 4c

- `CHIE` is the first mechanism with an observed effect on this Mac;
  neither private assertion had one (notes 09 and 10). It is not added to
  the helper's allowlist: no CellKeeper code can write it (§2.2), and one
  manual run does not meet `safety.md`'s preconditions for a verified
  mechanism (behavioural verification in independent telemetry, a tested
  independent recovery).
- It is an adapter cut, not a charge inhibit: nothing observed here holds
  the charge on adapter power the way macOS's own limit does. A limit
  built on it would let the battery discharge with the adapter plugged
  in, then re-enable charging: the small cycles S13 objects to (§3.3),
  with note 02 §7's floor of about 25%.
- `[INFERRED/UNVERIFIED]` While it is cut, macOS reports battery power,
  so its battery-power behaviour presumably applies (the battery settings,
  low-battery warnings), and anything that reads IOPowerSources,
  CellKeeper included, sees an unplugged Mac. CellKeeper's own control
  would have to account for its own cut, and could not tell a real unplug
  during one from the readings the probe uses (§8 question 8).
- The next decision is the owner's (§8 question 7): a layer the owner
  writes, an external tool, or stopping at macOS's native 80–100% limit.
  A persistence run (question 3) is a separate owner decision, needed
  before any helper work. Until then, macOS's own Charge Limit stays
  CellKeeper's only real control, and limits below 80% stay simulated.

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
  size is non-zero. Also, checked by the lead: it runs as a root launch
  daemon kept alive by launchd that writes charge keys by itself, and has
  no raw key read (§4.1, not chosen).
- **S2** — actuallymentor/battery, `battery.sh` (**MIT**):
  https://github.com/actuallymentor/battery . Supports: `CHIE` used for
  force-discharge; writing `08` to `CHIE` to cut and `00` to restore;
  a read of `00` meaning not discharging. Also, checked by the lead: its
  installer adds root-owned files and a sudoers rule for SMC writes without
  a password, and its adapter-off command also writes a MagSafe LED key it
  never restores (§4.1, not chosen).
- **S3** — actuallymentor/battery pull request #469 (**MIT** project):
  https://github.com/actuallymentor/battery/pull/469 . Supports: `CHIE`
  reads as type `hex_`, one byte `00`, while the inhibit and `bf*` keys are "no data" or
  error, in a comment from an M4 MacBook Air, macOS 27.0 (build 26A428);
  the form of the `smc` tool's read output.
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
  AppleSMC user-client interface for one key as summarised in §3.2 — the
  service name, open type 1 with explicit open and close calls, the
  selector, the get-key-info, read and write command values, the result
  codes, the parameter block and its `IOByteCount` data-size field, and a
  writer that does not check the length. In the current tag
  (PowerManagement-1846.120.8.0.1), `pmconfigd/PrivateLib.h` still declares
  `_smcReadKey` and `_smcWriteKey`, and `pmconfigd/PrivateLib.m` includes a
  private `<IOKit/smc/SMCUserClient.h>` that is not in the published tree;
  the definitions above are from the older tag.
- **S8** — beltex/SMCKit, `SMCKit/SMC.swift` (**MIT**):
  https://github.com/beltex/SMCKit . Supports: the same selector, command
  values and result codes; the parameter block stated to be 80 bytes; open
  type 0; no length check before a write; a client for Intel-based Macs.
- **S9** — charlie0129/gosmc, `driver_darwin.go`, `constants.go`, `key.go`,
  `client.go` (**GPL-2.0**): https://github.com/charlie0129/gosmc .
  Supports: the service name; selector 2; the read, write and key-info
  command values; a **fixed 32-bit** data-size field; key info before read
  and write; a write refused unless its length equals the key's data size.
- **S10** — macOS 27.0 SDK (Xcode 27.0), `IOKit/IOTypes.h`, read locally.
  Supports: `IOByteCount` is `IOByteCount64` (64-bit) on arm64 user space and
  `IOByteCount32` (32-bit) on Intel.
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

**The owner's tool**

- **S14** — hholtmann/smcFanControl, `smc-command/` (`README`, `smc.c`,
  `Makefile`) and `LICENSE`, master commit
  `e1bd672bcd2d72eddff9b6da7b9cae38e35c4206` (**GPL-2.0-or-later**):
  https://github.com/hholtmann/smcFanControl . Read by the lead on
  2026-10-20. Supports: the tool, its licence and its history; the build
  and what it needs; the read and write options and the hex-digit value
  format; the length check before a write and the absence of a type check;
  `-l` lists every key and `-f`/`-t` read other keys; nothing restores a
  key; the README's warning about writing SMC values.
- **S15** — hholtmann/smcFanControl issue #131 (**GPL-2.0-or-later**
  project): https://github.com/hholtmann/smcFanControl/issues/131 .
  Checked by the lead on 2026-10-20. Supports: writing a key with `smc`
  needs root.
