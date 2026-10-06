# 08 — macOS's native Charge Limit through Shortcuts (milestone 2 spike)

- **Date:** 2026-10-06
- **Machine:** Mac16,1 (MacBook Pro 14-inch, M4, 2024), macOS 27.0.1 (build 26A434), System Firmware / OS Loader 20457.1.29, Shortcuts 10.0 (5037.0.19), Xcode 27.0.
- **Owner's setting:** Charge Limit 80%, set by the owner in System Settings. It was recorded before every experiment, and 80% was restored and read back after every change.
- **Method:**
  - The limit was changed only through documented interfaces. The owner created a shortcut named "CellKeeper Set Charge Limit" around Apple's "Set Battery Charge Limit" action, and it was run with the documented `shortcuts run` command.
  - Read-back used the undocumented, read-only `pmset -g battlimit`.
  - No SMC key was read or written, and CellKeeper and the probes opened no IOUserClient (but see O7: pmset itself tries to).
  - No `sudo` was used, no `pmset` setting was changed, and no binary was disassembled, decompiled or string-dumped.
- **Confound:** a third-party battery manager's helper is installed on this Mac.
  - The active limit entries were owned by Apple's `/usr/libexec/PowerUIAgent` (from the process list).
  - Every change made here appeared and was reverted as expected.
  - Whether the helper also reads or writes the limit cannot be excluded.
- **Companion notes:** [02](02-charging-control-apple-silicon.md) §1.2–1.3 and §8 posed the questions; [01](01-battery-telemetry.md) covers telemetry.

Tags follow the [classification legend](README.md#classification-legend). Each finding is either an **observation** (O-numbers, seen on this Mac) or an **inference** (I-numbers, reasoned and not observed).

---

## Answers

| Question (02 §8.1, milestone 2) | Answer | Tags |
|---|---|---|
| Can the shortcut take the limit as input? | **Yes, as a text file** (`shortcuts run "<name>" -i <file containing 85>`). The same value piped through standard input ran without error and **changed nothing**. | `[PUBLIC-API]` (CLI) `[VERIFIED-EXPERIMENTALLY]` |
| Can a sandboxed app launch `/usr/bin/shortcuts`? | **Yes.** An App-Sandboxed probe with no other entitlement listed shortcuts and changed the limit 80 → 85 → 80. **No entitlement or design change is needed.** | `[PUBLIC-API]` `[VERIFIED-EXPERIMENTALLY]` (ad-hoc-signed probe) |
| How can the current limit be read back? | Only through `pmset -g battlimit`. It works unprivileged and inside the sandbox, and it reflected each change as soon as `shortcuts run` exited. It is undocumented, so CellKeeper uses it read-only and refuses to act on anything it does not recognise. | `[PRIVATE/UNDOCUMENTED][VERIFIED-EXPERIMENTALLY]` (read) |
| Is a shortcut finishing a confirmation? | **No.** A run exited 0 and changed nothing (O2). | `[VERIFIED-EXPERIMENTALLY]` |
| Does the limit hold through sleep and restart? | **Pending:** needs owner-performed steps; see "Sleep and restart" below. | — |

---

## Observations

### O1 — File input changes the limit `[VERIFIED-EXPERIMENTALLY]`

Unsandboxed, from Terminal:

| Step | Command (input file holds only the digits) | Exit | `pmset -g battlimit` afterwards |
|---|---|---|---|
| baseline | — | — | 80, reason `manualChargeLimit` |
| set 85 | `shortcuts run "CellKeeper Set Charge Limit" -i in85.txt` | 0 | 85 (at +1, +3, +6 and +10 s) |
| restore | `… -i in80.txt` | 0 | 80 |
| set 90 / 95 | `… -i in90.txt`, `… -i in95.txt` | 0 / 0 | 90 / 95 |
| set 100 | `… -i in100.txt` | 0 | `No battery level limits set` |
| restore | `… -i in80.txt` | 0 | 80, owner again PowerUIAgent's PID |

No output was written (`-o`), so the shortcut produces no output.

### O2 — Standard-input input exits 0 but does nothing `[VERIFIED-EXPERIMENTALLY]`

`printf 85 | shortcuts run "CellKeeper Set Charge Limit" -i - -o -` exited 0 after 0.74 s. The limit stayed at 80 at +1 to +4 s and on a later read.

**This is the evidence that a shortcut finishing successfully is not a confirmation.**

### O3 — The sandbox allows it `[VERIFIED-EXPERIMENTALLY]`

**Probe setup:**
- A Swift command-line probe with an embedded `Info.plist` (bundle ID `io.github.saltedtan.CellKeeper.spike.shortcuts`).
- Ad-hoc signed with Hardened Runtime and only `com.apple.security.app-sandbox`.
- `APP_SANDBOX_CONTAINER_ID` was set at run time, confirming the sandbox. This is the same method as note 01 §I.

**What it ran:** `Process` with `/usr/bin/shortcuts` and `/usr/bin/pmset`, standard input closed, and input files in the container's `tmp`.

| Step | Exit | Time | Read-back immediately after exit | +1 s |
|---|---|---|---|---|
| `pmset -g battlimit` | 0 | — | 80 | — |
| `shortcuts list` | 0 | — | shortcut listed | — |
| run with 85 | 0 | 0.20 s | 85 | 85 |
| run with 80 | 0 | 0.20 s | 80 | 80 |

**Sandbox denials logged during the run** (`log stream`, kernel `Sandbox` messages):
- `system-info vfs.disk-space` for the probe, `shortcuts` and `pmset`. This is noise that did not affect any result.
- `iokit-open-user-client AppleSMCClient` for `pmset`; see O7.
- For `BackgroundShortcutRunner`: `file-read-data` on its own cache and `mach-lookup com.apple.cloudd`. **The same two denials appear when the shortcut is run unsandboxed from Terminal**, so they come from Shortcuts' own sandbox, not CellKeeper's.

The shortcut's actions run in `BackgroundShortcutRunner`, not in the calling process. That is inferred from the process names in the denial log.

### O4 — The read-back report `[PRIVATE/UNDOCUMENTED][VERIFIED-EXPERIMENTALLY]`

**Below 100%**, `pmset -g battlimit` prints `Battery level limits:` followed by an old-style property-list array. Every entry had:
- `Terminated = 0`
- `chargeSocLimitDrain = 1`, `chargeSocLimitIsEOC = 1`, `chargeSocLimitNoChargeToFull = 0`
- `chargeSocLimitReason = manualChargeLimit`
- `chargeSocLimitSoc = <limit>`

**The two entries:**
- One is owned by the PID of `/usr/libexec/PowerUIAgent`.
- One is owned by `0`.
- They always agreed.

**At 100%:** the single line `No battery level limits set`.

**Not in the documentation:** `battlimit` is absent from pmset(1) (checked locally) and from the open-source pmset in note 02.

### O5 — Timing `[VERIFIED-EXPERIMENTALLY]`

| Operation | Time |
|---|---|
| `shortcuts list` | 0.02–0.03 s |
| `pmset -g battlimit` | 0.015–0.02 s |
| `shortcuts run` (warm, 80 → 80) | 0.18–0.24 s |
| `shortcuts run` (first of the session, stdin) | 0.74 s |

So a restore takes well under CellKeeper's 3-second quit budget on this Mac.

### O6 — Errors `[VERIFIED-EXPERIMENTALLY]`

A missing shortcut exits 1 with `Error: The operation couldn’t be completed. Couldn’t find shortcut` on standard error.

### O7 — pmset tries to open the SMC user client `[VERIFIED-EXPERIMENTALLY]`

**Observed:** inside the sandbox, every pmset invocation produced the kernel message `Sandbox: pmset(<pid>) deny(1) iokit-open-user-client AppleSMCClient`. That includes the documented `pmset -g batt`, not only `-g battlimit`. The report printed normally despite the denial.

**What this means:**
- This is pmset's own start-up behaviour; CellKeeper opens no user client itself.
- In the App Sandbox the attempt is blocked.
- An unsandboxed build would presumably let pmset open it, as it does whenever anyone runs pmset. That is an inference: it was not observed, because nothing was traced.

### O8 — Platform facts `[VERIFIED-EXPERIMENTALLY]`

- `sysctl hw.optional.arm64` returns 1.
- `/usr/bin/shortcuts` and `/usr/bin/pmset` are present and executable.
- pmset(1) documents `-g log` (the history of sleeps and wakes), which is usable read-only for the sleep test.

---

## Inferences `[INFERRED/UNVERIFIED]`

- **I1:** Standard input probably reaches the shortcut as untyped data that "Set Battery Charge Limit" cannot use as a number, while a `.txt` file is coerced to text and then to a number. Only the outcome (O1, O2) was observed.
- **I2:** "No battery level limits set" means the Charge Limit is at 100%: that is what the report showed after setting 100%. It might also appear in other states, such as a temporary "Charge to Full Now". CellKeeper therefore records it as 100% only when it reads it at take-over, shows it to the user, and restores it as 100% (which is what the user had). It never maps an unknown state to 100%.
- **I3:** Entries with a reason other than `manualChargeLimit` (for example from Optimized Battery Charging) or with disagreeing values may exist. CellKeeper treats them as unrecognised and changes nothing.
- **I4:** `chargeSocLimitDrain = 1` is consistent with third-party reports that macOS drains a battery above the limit down to it (02 §3.7, unverified).
- **I5:** The 80% limit observed throughout was the owner's own setting. The owner confirmed this; the observations are consistent with it.

---

## Sleep and restart

**Status: pending owner-performed steps.** Nothing below has been observed yet. The design does not depend on the outcome:
- CellKeeper re-reads the limit after every wake and at launch.
- It treats any value it did not set as an outside change.
- It keeps the user's own limit in a persisted record until it has been restored and read back.

Planned procedure:
1. **Sleep:**
   - CellKeeper sets 85% (recording 80%).
   - The owner sleeps the Mac with the lid closed for at least 2 minutes, then wakes it.
   - Compare `pmset -g battlimit` before and after, and `pmset -g log` for the sleep/wake entries and their charge readings.
   - Then restore 80%.
2. **Restart:** with the owner's own 80% (no CellKeeper change), restart and read `pmset -g battlimit`. Optionally repeat with a CellKeeper-set value, which also exercises the launch-time recovery path.
3. **Enforcement during sleep:** this needs the battery below the limit while plugged in and a long sleep. It is deferred to a later observation run.

---

## Decisions taken from this spike

1. **Write path:** `shortcuts run "CellKeeper Set Charge Limit" -i <file>`. The file holds only the digits and is created in the app container's temporary directory and removed afterwards. Runs have a 20 s deadline, because a shortcut that asks a question would otherwise wait forever.
2. **Read-back:** `pmset -g battlimit`, labelled undocumented and used read-only.
   - The arguments are fixed.
   - The parser accepts only the shapes in O4.
   - Every active entry must be a manual Charge Limit, and they must agree.
   - Anything else is "unrecognised": CellKeeper then neither records nor changes the limit.
3. **Sandbox:** stays on, with no new entitlements (O3). Keeping it also blocks pmset's SMC user-client attempt (O7).
4. **Confirmation:** only a read-back equal to the requested value. The exit status never confirms (O2).

---

## Open questions

1. Is there a "Get Battery Charge Limit" Shortcuts action? One beta-era press report mentions a getter (S3); release coverage only mentions the setter (S2, S4). If a getter exists, it would give a documented read-back.
2. How does "Set Until Tomorrow" (S4) appear in `battlimit`, and does macOS revert it in a way CellKeeper would see as an outside change?
3. How does "Charge to Full Now" appear in `battlimit`: an empty list, `Terminated = 1`, or another reason?
4. Does Optimized Battery Charging add entries with another `chargeSocLimitReason`?
5. Sleep, restart and shutdown behaviour (above). Apple Community users report that the limit is not enforced while the Mac is shut down (02 §4).
6. Is the `battlimit` report stable across macOS 27.x and on macOS 26.4–26.x?

---

## Sources

- **S1:** Apple Support 102338, "About Optimized Battery Charging and Charge Limit on Mac": https://support.apple.com/en-us/102338. Supports the requirements (macOS 26.4+, Apple silicon), the 80–100% range, and resuming after a drop of more than 5%.
- **S2:** 9to5Mac, "macOS 26.4 adds three new battery features on Mac" (2026-04-03): https://9to5mac.com/2026/04/03/macos-26-4-adds-three-new-battery-features-on-mac-heres-how-to-use-them/. Supports the "Set Battery Charge Limit" action name.
- **S3:** iDrop News, "macOS 26.4 Adds Battery Charge Limit With Shortcuts Support": https://www.idropnews.com/news/macbook-battery-charge-limit-shortcuts/260174/. A beta-era mention of Set and Get actions; unverified.
- **S4:** 9to5Mac, "macOS 26.4 brings battery Charge Limit to the Mac and Shortcuts" (2026-02-16): https://9to5mac.com/2026/02/16/macos-26-4-brings-battery-charge-limit-to-the-mac-and-shortcuts/. Supports the action's parameters (Charge Limit, Set Until Tomorrow), as reported from a beta.
- **S5:** Apple Shortcuts User Guide, "Run shortcuts from the command line": https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac (macOS 27 version), and the local `man shortcuts` and `shortcuts help run`. Supports `run`, `list`, `-i`/`--input-path`, "exit 0 on a successful run or 1 on error", and that a shortcut asking for input pauses the command.
- **S6:** Local `man pmset`. `battlimit` is absent; `-g log` is documented.
- **S7:** Local read-only commands on this Mac: `pmset -g battlimit`, `pmset -g batt`, `ps -o pid,user,comm` (to name the owner process), `log stream` (sandbox messages), `sysctl hw.optional.arm64`, `sw_vers`, `system_profiler SPHardwareDataType`, and `defaults read` of the Shortcuts app's `Info.plist` (version only).

The spike's probes and input files were built in `/tmp` and are not part of the repository. Running the probe left the empty sandbox containers `~/Library/Containers/io.github.saltedtan.CellKeeper.spike.shortcuts` and `…spike.pmset`; the owner can delete them in Finder.
