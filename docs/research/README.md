# CellKeeper research notes

These notes record what is known about battery telemetry and charging control
on macOS, how it was established, and how sure we are. They were produced on
2026-10-06 by parallel research workstreams and reviewed by the lead engineer
before being committed. Architecture decisions based on them live in
[`../architecture.md`](../architecture.md).

| # | Note | Question |
|---|---|---|
| 01 | [Battery telemetry](01-battery-telemetry.md) | What can be read, through which APIs, with what units, in the sandbox? |
| 02 | [Charging control on Apple silicon](02-charging-control-apple-silicon.md) | What mechanisms exist to limit, inhibit, or bypass charging? |
| 03 | [Intel differences](03-intel-differences.md) | Is Intel support worthwhile? |
| 04 | [Privileged helper](04-privileged-helper.md) | If root is needed, how should a helper be built and constrained? |
| 05 | [Distribution and signing](05-distribution-and-signing.md) | Sandbox, Hardened Runtime, signing, notarization, App Store |
| 06 | [Safety analysis](06-safety-analysis.md) | Battery ageing, hazards (FMEA), safety rules R1–R33, defaults |
| 07 | [Repository and CI](07-repository-and-ci.md) | Layout, toolchains, GitHub Actions |
| 08 | [Native Charge Limit through Shortcuts](08-native-charge-limit.md) | Can CellKeeper set, read back and restore macOS's Charge Limit from the sandbox? |
| 09 | [The ChargeInhibit probe](09-charge-inhibit-probe.md) | Does Apple's private `ChargeInhibit` power assertion stop charging on this Mac, and does charging resume when it is released? (owner-run 2026-10-19: no effect observed) |
| 10 | [The DisableInflow probe](10-disable-inflow-probe.md) | Does Apple's private `DisableInflow` power assertion do nothing, stop charging on adapter power, or cut the adapter's power on this Mac, and does everything return when it is released? (owner-run 2026-10-20: no effect observed) |
| 12 | [Guided battery calibration](12-guided-calibration.md) | What does a battery calibration need for the gauge to relearn, what do other tools do, and how can CellKeeper guide one with no SMC writes? (design, 2026-10-21, awaiting the owner's approval) |
| 11 | [The SMC adapter cut, a manual test](11-smc-adapter-cut.md) | Does writing the SMC key `CHIE` cut the adapter's power on this Mac, so that it runs from its battery while plugged in, and does restoring the key bring adapter power and charging back? (owner-run 2026-10-20, by hand with an existing open-source tool, the probe only observing: the adapter's power was cut and came back on restore; macOS reported no adapter during the cut, so the owner's account decides it. Not used: the owner rejected a cut as CellKeeper's control, and the old inhibit keys read empty) |

## Classification legend

Every mechanism is classified with one or more tags:

| Tag | Meaning |
|---|---|
| `[PUBLIC-API]` | Documented by Apple: public SDK header, developer docs, man page, support article, or user-facing setting |
| `[PRIVATE/UNDOCUMENTED]` | Not documented for third parties (undocumented keys or CLI subcommands, private headers in Apple open source) |
| `[IOKIT]` | Reached through IOKit (IORegistry, IOPowerSources, power-management assertions, user clients) |
| `[SMC/HW]` | Implemented by the SMC or charger/gauge hardware/firmware |
| `[PRIVILEGED]` | Requires root, administrator rights, or a private entitlement |
| `[ARCH-SPECIFIC]` | Differs between Apple silicon and Intel |
| `[VERIFIED-EXPERIMENTALLY]` | Observed on the research machine. Notes 01–07 used read-only methods only; note 08 also changed the user-level Charge Limit through the Shortcuts app and restored it, as described there; note 09's results come from an owner-run test that holds one private power assertion |
| `[INFERRED/UNVERIFIED]` | Reasoned from sources or third-party claims; not observed |

Some notes use their own evidence labels alongside these tags:

| Notes | Label | Meaning |
|---|---|---|
| 02, 03 | Grades A–E, X | A = Apple documentation … E = single anecdote; X = read-only observation here |
| 04, 05 | `[Doc]`, `[DTS]`, `[WWDC]`, `[man]` | Apple documentation, Apple engineer forum post, WWDC session, man page |
| 04, 05 | `[Exp]` | Experiment performed during research (read-only or sandbox-probe only) |
| 04, 05, 06 | `[Inference]`, `[I]` | Reasoning, not stated by a source |
| 04, 05 | `[3P]` | Third-party secondary source |
| 06, 12 | `[S]`, numbered `[n]` | Sourced statement / source number in that note |
| 06, 12 | `[O]` | Open question |
| 07 | `[F]`, `[V]`, `[I]` | Fetched source, verified locally, inference |

## Research environment and confound

- Mac16,1 (Apple M4 MacBook Pro), macOS 27.0.1, firmware 20457.1.29,
  Xcode 27.0.
- **A third-party battery manager's privileged helper is installed on this
  machine.** Any "on power but not charging" observation here is therefore
  *not* attributed to macOS by observation alone. That app's files were not
  inspected. The owner later confirmed that the machine is held at 80% by
  macOS's native Charge Limit (set in System Settings), which is consistent
  with `pmset -g battlimit` reporting a manual 80% limit. On 2026-10-19
  a read-only check found neither of the helper's two files (note 09 §9);
  the owner is removing it before any test.
- The project has no separate test Mac. On 2026-10-19 the owner decided to
  use this Mac as the test Mac for CellKeeper's own charge control, and
  authorized one experiment: an owner-run `sudo` test of Apple's private
  `ChargeInhibit` power assertion (note 09). After its result, the owner
  authorized one more, of the private `DisableInflow` assertion (note 10).
  After both showed no effect, the owner decided on 2026-10-20 to pursue
  the SMC adapter cut (`CHIE`) on this Mac (note 11 §2), and then chose a
  manual test: the owner reads and writes `CHIE` by hand with an existing
  open-source tool, run outside the repository, while CellKeeper's probe
  only observes. Agents never read or write any SMC key, never run the
  tool and never run `sudo`. Every other private control mechanism stays
  documentary (see [`../roadmap.md`](../roadmap.md), milestone 4).
- Notes written before the bundle identifier was chosen use the placeholder
  `com.example.CellKeeper`; the project uses `io.github.saltedtan.CellKeeper`.
- The experiments for notes 01–07 were read-only. Note 08 changed one
  user-level setting, the Charge Limit, only through the owner's shortcut and
  the documented `shortcuts` tool, and restored and read back the owner's
  80% after every change. Note 09's probe holds one private power
  assertion, and only when the owner runs it with `sudo`; the owner ran it
  once, and agents only ran its read-only `check`. Note 10's probe, the same
  tool, does the same with `DisableInflow`; its `run` also holds a public
  idle-sleep assertion and registers for sleep notifications, which
  connects it to the power-management root domain
  (`IORegisterForSystemPower`). The owner ran it once, on 2026-10-20. In
  notes 01–11 no user client of the battery or the SMC was opened by
  CellKeeper or its probes, and CellKeeper reads and writes no SMC key. In
  note 11's test the owner writes one key, `CHIE`, by hand, with an
  existing open-source tool (smcFanControl's `smc`) that the owner builds
  and runs outside the repository; the same probe, run without `sudo`,
  only observes and prompts. In all notes no `pmset` setting was changed,
  and no proprietary binary (Apple's or anyone else's) was disassembled or
  string-dumped.

## Key findings (lead's synthesis)

| Capability | Mechanism | Classification | Status in CellKeeper |
|---|---|---|---|
| Battery %, AC/battery, charging, charged, time estimates | `IOPSCopyPowerSourcesInfo` | PUBLIC-API, IOKIT, verified | Used |
| Adapter wattage | `IOPSCopyExternalPowerAdapterDetails` | PUBLIC-API, verified | Used |
| Change notifications | notify(3) `kIOPSNotify*` | PUBLIC-API, verified | Used |
| Cycle count, voltage, amperage | `AppleSmartBattery` registry (key constants in public `IOPM.h`) | IOKIT, verified, no privilege | Used |
| Design cycle count, mAh capacities | `AppleSmartBattery` registry (`DesignCycleCount9C`, `BatteryData`) | PRIVATE/UNDOCUMENTED keys, IOKIT, verified | Used, all optional |
| Battery temperature | None public on macOS 27 (IOPS key documented but absent; registry key gone, units unverified on older macOS) | — | Shown as unavailable; protection cannot trigger |
| Health / condition / "Maximum Capacity" | Gated by a private entitlement; only undocumented `system_profiler` output | PRIVILEGED / PRIVATE | Not shown; CellKeeper shows its own computed full-charge ÷ design ratio, labelled as such |
| Native Charge Limit (80–100%) | System Settings; “Set Battery Charge Limit” Shortcuts action run with the `shortcuts` CLI | PUBLIC (user setting, CLI), ARCH-SPECIFIC (Apple silicon, macOS 26.4+), verified from the App Sandbox (08) | Used by the opt-in macOS Charge Limit backend |
| Read native limit state | `pmset -g battlimit` | PRIVATE/UNDOCUMENTED, verified read-only (08) | Used read-only to confirm every change; unrecognised output blocks changes |
| Inhibit charging / force discharge | Only private: SMC keys (largely gated on macOS 27 firmware), private `ChargeInhibit`/`DisableInflow` assertions (root) | PRIVATE, PRIVILEGED, SMC/HW, unverified | Not implemented; simulated. An owner-run probe of `ChargeInhibit` showed no effect on this Mac (09); nor did one of `DisableInflow` (10). An owner-run manual test of the SMC adapter cut `CHIE`, with an existing tool and observed by the probe, cut the adapter's power on 2026-10-20 (11), and the old inhibit keys read empty there; the owner rejected the cut as CellKeeper's control, so macOS's Charge Limit (80–100%) stays the only real one |
| Privileged helper | `SMAppService` daemon + XPC with code-signing requirements | PUBLIC-API | Logic and NSXPC transport implemented and tested, on a simulated control; the daemon exists and serves the authenticated transport, but controls no hardware, is neither embedded nor registered, and the app does not connect to it yet |
| Mac App Store with control | Incompatible (sandbox, no root, no helpers) | — | Not a goal |
| Intel | macOS 26 is the last Intel release; no supported control | — | Telemetry only (code is architecture-neutral) |

## Independent review

The architecture and the low-level control conclusions were reviewed
adversarially by a separate agent on a different model provider. Its findings
were addressed in code (strict read-back, persistent faults with active
recovery, external-change detection, verified backend switching, one-shot
discharge sessions, monotonic time, driver-timestamp freshness, a floor-exit
latch, a 30 °C minimum for temperature resume, and override endings processed
before telemetry validation) or recorded as preconditions in
[`../safety.md`](../safety.md). The reviewer's caveats on these notes:

- Note 04's lease design must use **per-control** deadlines and helper-side
  freshness, floor, AC-loss, and thermal guards, with renewal tied to
  successful policy evaluation.
- Note 02 §7's journal-and-restore protocol is not by itself a recovery
  guarantee. A tested independent recovery path and known safe restoration
  values are required first.
- Firmware gating and Shortcut control remain third-party or press claims
  until verified; architecture text keeps those qualifications.

## Corrections and caveats applied during lead review

- Specific third-party SMC write encodings and magic values were removed from
  note 02, keeping only key names and claimed behaviour (clean-room).
- The registry `Temperature` key's units are unverified (Smart Battery
  format vs. hundredths of a degree), so CellKeeper does not use it (see
  architecture decision D9).
- Specific write values for the Intel key in note 03 were removed for the
  same clean-room reason as note 02.
- Note 07 corrects the Contributor Covenant 3.0 licence to CC BY-SA 4.0.
- Quotes from forums obtained through summarising fetch tools should be
  re-checked against the original before being quoted elsewhere.

## Clean-room rules for research contributions

- Prefer Apple documentation, public SDK headers, Apple open source, hardware
  documentation, and your own read-only observations.
- Third-party projects may be cited only as "third-party claim — unverified",
  with their licence noted. Never copy their code or record their
  implementation details (encodings, write sequences, magic values).
- **Exception (owner decision, 2026-10-20):** for CellKeeper's own charge
  control on Apple silicon, these facts may be used from OSI-licensed
  open-source projects: the name, type and size of the SMC adapter-cut key
  `CHIE`, the values those projects write to it, and the AppleSMC
  user-client interface needed to read and write one key. Each fact is
  cited with its source and licence, and treated as a third-party claim
  until verified on a test Mac; prefer permissively licensed sources where
  the same fact is available, and record which sources agree or disagree.
  No code, comments or other text is copied, and no project's
  implementation structure (its files, types, functions or control flow);
  the wire-level facts needed to call the interface (the parameter block's
  fields, sizes and offsets, and the selector and command values) are used
  as facts. The implementation is written independently. Not covered:
  AlDente or any other proprietary or source-available tool, anything
  obtained from binaries, and any other key or mechanism (each needs its
  own owner decision). This is a project rule, not a legal opinion or a
  licence-compatibility review; for an issue or pull-request comment, the
  licence noted is the project's and does not necessarily cover the
  comment, which is cited only as a report. The owner may also use an
  OSI-licensed tool as an external test instrument, built and run outside
  the repository; nothing from it enters the repository, and CellKeeper
  never invokes it. Note 11 applies it;
  [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) §1 has the same rule.
- Never disassemble, decompile, or string-dump proprietary binaries,
  including Apple's.
- Never write to hardware or probe unknown keys to answer a research
  question. Observation from read-only interfaces only. The one exception
  is an owner decision for one mechanism on the test Mac, run by the owner
  (notes 09–11); even then agents never write and never enumerate keys,
  and in note 11 they read none.
- Record exactly how each observation was made, on which model, macOS build,
  and firmware, and separate observation from inference.
- Never record serial numbers or other device identifiers.
