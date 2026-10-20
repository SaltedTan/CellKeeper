# 11 — The SMC adapter cut (`CHIE`): a manual, owner-run test on the maintainer's Mac

- **Date:** 2026-10-20
- **Status:** Phase 1 — design and policy, revised on 2026-10-20 for a
  manual test. No SMC key has been read or written yet. Phase 2 as first
  planned, in which the probe itself would open the AppleSMC user client
  and write `CHIE`, was replaced by the owner's decision of 2026-10-20: an
  automated safety check stopped an agent's response as it began writing
  the SMC client code, and the lead decided not to route around it (§2.2).
  The owner now reads and writes `CHIE` by hand with an existing
  open-source tool (§4.1), and the probe only observes (§4). The probe's
  observer mode is built next; the results land in §9 and §10.
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
- It writes only with `-w`. `-l` lists every key, which is enumeration;
  `-f` and `-t` read other keys.
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
  the tool in another terminal. It also refuses unless its input is a
  terminal, so that no script can answer its questions for the owner. Like
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
input without holding up the schedule. A line typed when no question is
open is ignored.

1. **Not as root, from a terminal.** Refuse if the effective user is root,
   or if the input is not a terminal. Nothing else happens first.
2. **Preconditions** (§5). Refuse on any failure.
3. **Report, signals, sleep.** As note 10 §4: create the report file in
   the current directory, install the signal handlers, register for sleep
   notifications, and create the public idle-sleep assertion, with a
   timeout that covers the run's bounded parts plus 30 minutes for the
   owner's restore. Refuse if either fails. These are the only things the
   probe creates.
4. **The owner's first read.** The probe shows the read command and asks
   the owner to type `yes` only if the tool printed `[hex_]` and
   `(bytes 00)`. It waits up to 120 s. On anything else, or no answer, it
   refuses (exit 1): nothing has been written, and the report says why.
   `CHIE` must read `0x00` at the start (lead's decision, 2026-10-20). The
   tool checks the length but not the type (§4.1), so the type and size are
   part of this answer.
5. **Baseline**, exactly as note 10 §4 step 4: readings for at least 20 s
   and until they show 2 battery updates, all steady charging on AC power,
   at most 150 s. If the baseline fails, there is no CUT prompt: the run
   ends inconclusive, with nothing written.
6. **CUT prompt.** Only if the baseline passed and is still fresh by note
   10's rule (the last reading at most 4 s old, the latest battery update
   at most 70 s old, the clock rules holding). The probe shows the cut and
   read commands and says: type the cut command in the other terminal, but
   do not run it yet; press Return here; then run it at once. It also says
   that it will ask for the restore when the hold (180 s by default) has
   passed after that Return. It waits up to 120 s for the Return, reading
   every 2 s. If a reading stops showing steady charging on AC power, or
   the freshness rule breaks, before the Return, it **withdraws** the
   prompt ("do not run the cut") and ends the run (below). If no Return
   comes within 120 s, it ends the same way.
7. **The cut mark.** The owner's Return is the cut time: the verdict's
   "creation". At once — before the owner runs the cut — the probe prints
   the clock time by which to restore (the mark plus the hold) and says to
   restore by then even if the probe says nothing more, and arms its
   restore reminder (§4.6). Then it asks the owner to run the cut, run the
   read, and type `yes` only if the read shows `(bytes 08)`. It waits up to
   60 s. On `yes`, the cut is confirmed. On anything else, or no answer,
   the state of `CHIE` is unknown, and the run is inconclusive. The probe
   does **not** show the RESTORE prompt (which says to write `00`); it
   shows the read-first steps of §7.1 at once, and from then on its
   reminder repeats those, with the bell, until the owner answers:
   - read `CHIE`;
   - `(bytes 08)`: run the restore, read again, and type `yes` only if
     that read shows `(bytes 00)`;
   - `(bytes 00)`: nothing to restore; type `yes`. The report then says
     that no restore was written;
   - anything else: write nothing, follow the recovery steps (§7.1), and
     type `no`.

   A `yes` here counts as a confirmed restore, at the time of the answer
   (there is no restore mark); the probe then reads for the after period
   (step 10), and the report keeps the run inconclusive. Anything else ends
   the run as in step 9.
8. **Hold:** 180 s by default, 165–300 s with `--hold`, measured from the
   cut mark. The probe asks for the restore early — the RESTORE prompt at
   once — when a reading is unreadable, shows 100% or charged, shows a
   charge below 25%, or shows a battery update more than 150 s old.
   Battery power is **not** a reason to stop early: it is the expected
   effect of a cut.
9. **RESTORE prompt.** At the end of the hold, or early as above. The
   probe shows the restore and read commands and says: type the restore
   command in the other terminal; press Return here; then run it at once;
   then run the read, and type `yes` only if it shows `(bytes 00)`. Until
   the owner answers, it shows the reminder again, with a terminal bell,
   every 20 s. The owner's Return is the restore time: the verdict's
   "release". On `yes`, the restore is confirmed. On anything else, it
   prints the recovery steps (§7.1) at once, ends the readings, writes the
   report, opening with **CHECK RECOVERY FIRST**, and exits 3.
10. **After, and the end.** After a confirmed restore, readings for 180 s
    after the restore mark, up to 120 s more until charging has resumed,
    as in note 10. Then the probe releases the idle-sleep assertion,
    deregisters from sleep notifications and writes the report.

**Any end after the CUT prompt without a confirmed restore** — a withdrawn
prompt, a timeout, a `no` to the RESTORE prompt or to the read-first steps
(step 7), Ctrl-C, `SIGTERM`, `SIGHUP`, an error — prints **RESTORE CHIE
NOW** with the read-first recovery steps (§7.1), opens the report with
**CHECK RECOVERY FIRST**, and exits 3. The probe cannot know whether the
owner ran the cut or the restore. The report also opens that way when the
restore was confirmed but the last reading does not show charging on
adapter power (note 10 §4 step 8).

With the default hold and a prompt owner, the run takes about 7 minutes
(a baseline of 20–60 s, a few seconds to the cut, the 180 s hold, a few
seconds to the restore, 180 s after); up to about 11 if the baseline waits
for a battery update or charging is slow to resume. The bounded parts are
at most 150 + 120 + 300 + 300 s; the wait for the owner's restore is not
bounded, and the probe keeps reminding until it ends.

Exit status, with note 10's meanings: 0 a verdict; 1 refused before the
CUT prompt; 2 inconclusive, but only for a run whose restore was confirmed
or that ended before the CUT prompt without a refusal; 3 "follow the
recovery steps the report prints" — a run after which charging did not
resume, and **any end after the CUT prompt without a confirmed restore**;
64 a usage error.

### 4.5 Why the owner presses Return before each write

Note 10 attributes an effect to the creation only if the battery update
that first shows it was made after the creation, and it requires the
effect to last until the release. If the owner pressed Return *after*
running a command, a battery update made between the write and the Return
could show the cut before the cut time, or charging back before the
restore time. Either would make a good run inconclusive. With the Return
first, every update made after a write is also made after its mark, and
note 10's rules apply unchanged.

The owner's delay between the Return and the write (switching windows,
`sudo`'s password) falls inside the 90 s effect window. A long delay makes
a run inconclusive, never misjudged.

**How the readings around the marks are judged:**

- **Between the CUT prompt and the cut mark.** Recorded, with a phase of
  their own; not part of the baseline (whose rules are unchanged) or the
  hold, and not judged for an effect. They are used only for note 10's
  freshness rule at the cut (the last of them at most 4 s old, its battery
  update at most 70 s old, showing steady charging on AC power — so a Mac
  that stopped charging while the owner got ready is not cut: the probe
  withdraws the prompt) and for the gap and clock rules. If the owner ran
  the cut before pressing Return, the first update that shows the effect
  may be older than the mark, and note 10's rule then makes the run
  inconclusive.
- **Between the cut mark and the restore mark.** Held readings, judged as
  in note 10, including those taken while the owner confirms the cut and
  while the RESTORE prompt waits: the cut is still in place, and the effect
  must last until the restore mark. If the owner restored before pressing
  Return, charging may come back "while held", and the run is
  inconclusive.
- **After the restore mark.** After readings, judged as in note 10.

The owner's `yes` answers come after the marks and do not move them. The
report gives the time of each mark and each answer.

### 4.6 The restore: held by the owner, reminded by the probe

The probe cannot restore `CHIE`: it writes nothing. The restore is the
owner's, made with the tool in the owner's own terminal, and it needs
nothing from the probe. There is no powerd timeout for an SMC write, so
the reminders below are what stands in for one:

- **A restore time, printed before the cut.** At the cut mark, before the
  owner runs the cut, the probe prints the clock time by which to restore.
  It is the owner's deadline, and it holds whatever happens to the probe.
  A phone timer for it is a good idea.
- **A reminder on its own timer**, also armed at the cut mark. At the end
  of the hold it shows the RESTORE prompt, and it rings and shows it again
  every 20 s until the owner answers. It runs apart from the sampling loop
  and the report, so a reading that hangs does not hold it up. An early
  stop (§4.4 step 8) shows the same prompt sooner.
- **No lock, no write.** The probe holds no lock that anything outside it
  waits on, and makes no write to any key or setting. Nothing it does can
  stand in the way of the owner's restore.
- **If the probe crashes, hangs or is killed** (even with `SIGKILL`), it
  reminds no one. Restore by the printed time anyway: the cut is the
  owner's, not the probe's, and a dead probe does not stop the owner
  restoring.
- **If the tool hangs** on a write, press Ctrl-C in its terminal and read
  `CHIE` again; if it still does not answer, follow §7.1 from step 3.
- **Ctrl-C, `SIGTERM` or `SIGHUP` after the CUT prompt** print RESTORE
  CHIE NOW with the read-first recovery steps, write the report opening
  with CHECK RECOVERY FIRST, and end the run with exit status 3. A second
  Ctrl-C quits at once, also with exit status 3, after printing RESTORE
  CHIE NOW once more. Before the CUT prompt, a signal ends the run as in
  note 10, with nothing to restore.
- **What the probe cannot know:** whether the owner ran the cut or the
  restore, and what the tool printed. It records what the owner answered,
  and when. Every report calls the cut time, the restore time and both
  read-backs **owner-confirmed**, not observed by the probe.

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
prompt, the run ends inconclusive, with nothing to restore. After it, the
state of `CHIE` is unknown — the sleep may or may not have cleared the cut —
so the probe prints **RESTORE CHIE FIRST** and shows the §7.1 read-first
steps in place of the RESTORE prompt, answered as in §4.4 step 7, and
carries on to the after readings once the owner answers. Any sleep
notification makes the run inconclusive. What the owner's read showed after
the wake is worth sending with the report (§6): one observation, not a
persistence test (§8).

### 4.8 The verdict (reuses note 10)

The manual cut is judged by note 10's verdict rules, unchanged. A reading
is *charging*, *stopped*, *discharging* or *mixed* by the same thresholds;
a *sustained run* needs 5 counted readings over ≥ 8 s and ≥ 2 battery
updates; the effect must begin within 90 s of the **cut mark**, be
discharging with the adapter reported attached and system power input ≤
1000 mW in **every** held reading, and last until the **restore mark**;
charging must resume within 120 s of a **confirmed restore**.

The test maps onto note 10's `ProbeRun`. The cut mark is the "creation",
which counts as accepted only if the owner confirmed the read-back of
`08`; without it, the run is inconclusive (not `refused`: there is no
IOReturn, and the probe cannot tell a refused write from one not made).
The restore mark is the "release", confirmed only if the owner confirmed
the read-back of `00` — the analogue of `pmset -g assertions` no longer
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
| Input is a terminal | `watch` **refuses** otherwise | Only the owner answers its questions (§4.3). |
| Adapter reported attached | **fails** unless `AppleRawExternalConnected` is yes **or** `IOPSCopyExternalPowerAdapterDetails` returns an adapter (§4.8) | Without either, a cut can only end inconclusive, and every write carries risk. Note 10 keeps this check a warning for the two assertions; for `--mechanism manual-adapter-cut` only, it fails. |
| `CHIE` reads `00` (the owner's read) | `check` **always warns**: the probe reads no SMC key. `watch` asks the owner before the baseline and **refuses** unless the owner types `yes`: the tool printed `[hex_]`, one byte, `00` (§4.4 step 4). | `0x08` would mean something else already holds a cut, and any other value is an unknown state: either way, the restore value `0x00` would not return the key to where it started (lead's decision, 2026-10-20). The tool checks a write's length but not the key's type (§4.1), so the type and size are part of the owner's answer (note 02 §6, "writing unknown keys or wrong widths"). |
| macOS's Charge Limit is 100% | **fails** below 100% (note 10 already checks this) | `CHIE` is reported ignored while the native limit is active (§3.3); the limit must be off for a meaningful result. |

## 6. Owner steps

Use two terminals: **A** for the probe, in `Tools/charge-inhibit-probe` of
the CellKeeper checkout, and **B** for the tool, in
`~/smc-test/smc-command`. Each prompt of the probe shows the exact command
to type; §4.1 has them all.

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
   during the run. If the Mac gets unusually hot, restore `CHIE` at once
   in terminal B (the restore command, then a read), then press Ctrl-C in
   terminal A.
5. **During the run, do not touch the adapter or its cable**, and do not
   close the lid or let the Mac sleep. The run is expected to leave the Mac
   running from its battery while the adapter is plugged in, for the hold
   (3 minutes by default): that is the effect. The probe cannot tell a cut
   from an unplugged adapter, so it relies on you not touching it (§4.8).
   If the Mac does sleep, restore first when it wakes (step 8).
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
   1. **First read.** Run the read in B. Type `yes` in A only if it
      printed `[hex_]` and `(bytes 00)`.
   2. **Baseline.** Wait: 20 s to 2½ minutes.
   3. **CUT.** Type the cut command in B, without pressing Return. Press
      Return in A, then at once press Return in B (`sudo` may ask for your
      password). Then run the read in B, and type `yes` in A only if it
      shows `(bytes 08)`. Note the restore time A prints. If it shows
      anything else, type `no`: A then shows the read-first steps of §7.1
      instead of the RESTORE prompt; follow them.
   4. **Hold.** 3 minutes by default. The Mac is expected to run from its
      battery with the adapter plugged in. Leave everything as it is.
   5. **RESTORE.** When A rings and shows the RESTORE prompt: type the
      restore command in B, press Return in A, then at once press Return
      in B. Then run the read in B, and type `yes` in A only if it shows
      `(bytes 00)`. **If the restore time has passed and A shows nothing —
      it stopped, crashed or hangs — restore anyway.**
   6. **After.** 3 to 5 minutes of readings; then the report.

   The whole run takes about 7 minutes with the default hold, up to about
   11. Ctrl-C ends it at any time; after the CUT prompt it prints RESTORE
   CHIE NOW, and you restore with the tool (§7.1).
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
  idle and restores at once on unusual heat (§6). The probe asks for the
  restore at once if the charge falls below 25% (note 02 §7 puts the floor
  for an adapter cut at about 25–30%), and refuses to start below 40% (§5).
- **No self-release.** A written SMC key is **not** freed when anything
  exits. The restore is the owner's, with the tool, and it needs nothing
  from the probe. The probe arms two reminders at the cut mark, before the
  cut: the printed restore time and its own timer (§4.6). If the probe
  crashes, hangs or is killed, it reminds no one; the owner restores by the
  printed time anyway. **Unknown: whether unplug/replug, sleep or a restart
  clears `CHIE`** — the published Apple source does not say, and this test
  does not measure persistence (§8).
- **Sleep.** A closed lid, the Apple menu or a low battery still sleeps the
  Mac; the idle-sleep assertion stops only idle sleep. A process cannot
  cancel a sleep: withholding the acknowledgement would delay it by at most
  the 30-second timeout (`IOPMLib.h`), and the probe has nothing to do in
  that time, so it acknowledges at once. A sleep can therefore happen with
  `CHIE` still at `0x08`; the owner restores first after the wake (§4.7,
  §6 step 8). A sleep makes the run inconclusive.
- **The tool.** It is unmaintained, and its README warns that writing SMC
  values could irreversibly damage the computer. The test keeps that risk
  as small as it can: one key; two values that two independent projects
  use (§3.1); a read before each write that must show the expected type,
  size and value; the tool's own length check; and no enumeration.
- **What the probe never does:** run as root; open a user client of the
  SMC or the battery manager; read or write any SMC key; run the tool,
  start any process for it, or read what it prints; take answers from
  anything but a terminal; create any assertion but the public idle-sleep
  one; change `pmset` settings; read the AlDente helper's files; keep
  anything of the adapter details but presence and wattage.
- **What agents never do:** run `sudo`; run the tool; read or write any
  SMC key; run `watch`; change System Settings.

### 7.1 Recovery steps

Follow these steps if adapter power did not come back after the run, if
you did not answer `yes` to the restore, if the report or the console says
CHECK RECOVERY FIRST or RESTORE CHIE NOW, or if the probe stopped after
its CUT prompt. The probe also shows step 1 itself when the cut's
read-back was not confirmed (§4.4 step 7), and asks for an answer:

1. **Read `CHIE`** with the tool (§4.1). Never write before this read.
   - `(bytes 08)`: run the restore, then read again. If the probe asks,
     type `yes` only if that read shows `(bytes 00)`.
   - `(bytes 00)`: nothing to restore; write nothing. If the probe asks,
     type `yes`. Go to step 2 if the Mac still runs from its battery.
   - Anything else: **write nothing**. If the probe asks, type `no`. Go to
     step 3.

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
   observed by `watch`, answers this.
2. Does `CHIE` read as `[hex_]`, one byte, `00` on this Mac, as the
   reports say (§3.1)? The owner's first read answers this, before any
   write.
3. **Does a written `CHIE` outlive its writer?** Specifically, does
   unplug/replug, sleep, or a restart clear it, or does it stay `0x08`?
   Not tested here (lead's decision, 2026-10-20). A persistence run
   (unplug/replug, sleep, restart; note 02 §7, Phase D) is **an owner
   decision** for before any helper work: it decides whether CellKeeper's
   own control needs a startup reconciliation and an uninstaller restore
   (note 02 §6).
4. Is `CHIE` ignored while the native Charge Limit is on, as reported
   (§3.3)? The test is done with the limit off, so this is not measured
   here; it matters because CellKeeper's own control must turn the native
   limit off.
5. On Apple silicon the matched service is an RTKit SMC endpoint, not the
   Intel AppleSMC device (§9). Does a client written for the Intel device
   read and write `CHIE` through it? The owner's reads and writes answer
   this for that tool only; they say nothing about any client CellKeeper
   might have.
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
   macOS's native 80–100% limit. Nothing is decided here.

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

The owner's first read of `CHIE` (§4.4 step 4), and the read-only
`check --mechanism manual-adapter-cut` once the observer is built, will be
recorded here, as note 10 §9 recorded its `check`.

## 10. Results

Not run yet. The owner's manual test — one cut and one restore, each read
back (§2.2) — is the one experiment this note covers. Its outcome, the
verdict, what each read printed and the full report (with no serial
numbers, user names or home paths) will be recorded here, as in notes 09
§10 and 10 §10.

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
