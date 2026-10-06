# Cell Keeper research notes

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
| `[VERIFIED-EXPERIMENTALLY]` | Observed on the research machine using read-only methods |
| `[INFERRED/UNVERIFIED]` | Reasoned from sources or third-party claims; not observed |

Some notes use their own evidence labels alongside these tags:

| Notes | Label | Meaning |
|---|---|---|
| 02, 03 | Grades A–E, X | A = Apple documentation … E = single anecdote; X = read-only observation here |
| 04, 05 | `[Doc]`, `[DTS]`, `[WWDC]`, `[man]` | Apple documentation, Apple engineer forum post, WWDC session, man page |
| 04, 05 | `[Exp]` | Experiment performed during research (read-only or sandbox-probe only) |
| 04, 05, 06 | `[Inference]`, `[I]` | Reasoning, not stated by a source |
| 04, 05 | `[3P]` | Third-party secondary source |
| 06 | `[S]`, numbered `[n]` | Sourced statement / source number in that note |
| 06 | `[O]` | Open question |
| 07 | `[F]`, `[V]`, `[I]` | Fetched source, verified locally, inference |

## Research environment and confound

- Mac16,1 (Apple M4 MacBook Pro), macOS 27.0.1, firmware 20457.1.29,
  Xcode 27.0.
- **A third-party battery manager's privileged helper is installed on this
  machine.** Any "on power but not charging" observation here is therefore
  *not* attributed to macOS by observation alone. That app's files were not
  inspected. The owner later confirmed that the machine is held at 80% by
  macOS's native Charge Limit (set in System Settings), which is consistent
  with `pmset -g battlimit` reporting a manual 80% limit.
- The project has no separate test Mac, so research on private control
  mechanisms stays documentary until one is available (see
  [`../roadmap.md`](../roadmap.md), milestone 4).
- Notes written before the bundle identifier was chosen use the placeholder
  `com.example.CellKeeper`; the project uses `io.github.saltedtan.CellKeeper`.
- All local experiments were read-only. No IOUserClient was opened, no SMC
  key was read or written, no system setting was changed, and no proprietary
  binary (Apple's or anyone else's) was disassembled or string-dumped.

## Key findings (lead's synthesis)

| Capability | Mechanism | Classification | Status in Cell Keeper |
|---|---|---|---|
| Battery %, AC/battery, charging, charged, time estimates | `IOPSCopyPowerSourcesInfo` | PUBLIC-API, IOKIT, verified | Used |
| Adapter wattage | `IOPSCopyExternalPowerAdapterDetails` | PUBLIC-API, verified | Used |
| Change notifications | notify(3) `kIOPSNotify*` | PUBLIC-API, verified | Used |
| Cycle count, voltage, amperage | `AppleSmartBattery` registry (key constants in public `IOPM.h`) | IOKIT, verified, no privilege | Used |
| Design cycle count, mAh capacities | `AppleSmartBattery` registry (`DesignCycleCount9C`, `BatteryData`) | PRIVATE/UNDOCUMENTED keys, IOKIT, verified | Used, all optional |
| Battery temperature | None public on macOS 27 (IOPS key documented but absent; registry key gone, units unverified on older macOS) | — | Shown as unavailable; protection cannot trigger |
| Health / condition / "Maximum Capacity" | Gated by a private entitlement; only undocumented `system_profiler` output | PRIVILEGED / PRIVATE | Not shown; Cell Keeper shows its own computed full-charge ÷ design ratio, labelled as such |
| Native Charge Limit (80–100%) | System Settings; Shortcuts action | PUBLIC (user setting), ARCH-SPECIFIC (Apple silicon, macOS 26.4+) | Not integrated yet (milestone 3) |
| Read native limit state | `pmset -g battlimit` | PRIVATE/UNDOCUMENTED, verified read-only | Not used |
| Inhibit charging / force discharge | Only private: SMC keys (largely gated on macOS 27 firmware), private `ChargeInhibit`/`DisableInflow` assertions (root) | PRIVATE, PRIVILEGED, SMC/HW, unverified | Not implemented; simulated |
| Privileged helper | `SMAppService` daemon + XPC with code-signing requirements | PUBLIC-API | Designed only |
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
  format vs. hundredths of a degree), so Cell Keeper does not use it (see
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
- Never disassemble, decompile, or string-dump proprietary binaries,
  including Apple's.
- Never write to hardware or probe unknown keys to answer a research
  question. Observation from read-only interfaces only.
- Record exactly how each observation was made, on which model, macOS build,
  and firmware, and separate observation from inference.
- Never record serial numbers or other device identifiers.
