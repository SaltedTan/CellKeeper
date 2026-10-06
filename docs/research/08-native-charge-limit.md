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
| How can the current limit be read back? | With `pmset -g battlimit`, which CellKeeper uses now. It works unprivileged and inside the sandbox, and it reflected each change as soon as `shortcuts run` exited. It is undocumented, so CellKeeper uses it read-only and refuses to act on anything it does not recognise. Shortcuts also has a "Get charge limit" action (O16). Run from Terminal, it returned the same value as `pmset` for 80, 85 and 100%, and plain `100` for no limit (O18), so it could replace `pmset` as a documented read-back. Not yet tried from the sandbox. | `[PRIVATE/UNDOCUMENTED][VERIFIED-EXPERIMENTALLY]` (pmset read); getter `[PUBLIC-API][VERIFIED-EXPERIMENTALLY]` (Terminal only) |
| Is a shortcut finishing a confirmation? | **No.** A run exited 0 and changed nothing (O2). | `[VERIFIED-EXPERIMENTALLY]` |
| Does the limit hold through sleep and restart? | **Sleep: yes, in one owner-performed run.** An 85% limit set by CellKeeper was still in effect after about 12 minutes of clamshell sleep on AC, with five maintenance wakes and a full wake, and was not re-applied (O10). **Restart: yes, in one owner-performed run.** The owner's own 80% was still in effect after a restart, both in `pmset -g battlimit` and in System Settings (O17). See "Sleep and restart" below. | `[VERIFIED-EXPERIMENTALLY]` (one run each) |

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

So a restore takes well under CellKeeper's quit wait (10 s) on this Mac.

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

### O9 — The CellKeeper app end to end `[VERIFIED-EXPERIMENTALLY]`

**Setup:** the App-Sandboxed Debug build of this branch (ad-hoc signed), with the native backend preselected and a CellKeeper limit of 85%. The owner's own limit was 80%. Each run was observed with `pmset -g battlimit` and CellKeeper's unified log.

| Run | What happened |
|---|---|
| Launch | Recorded the owner's 80% in the record file, ran the shortcut (0.15–0.23 s), and confirmed 85% by read-back. |
| Quit (Apple event) | Restored 80%, confirmed by read-back, and deleted the record. No warning was shown. |
| `kill -9`, then relaunch on the native backend | 85% stayed in effect and the record survived the kill. On relaunch, CellKeeper restored 80% first, then set 85% again on a later evaluation; quitting restored 80%. |
| `kill -9`, select Simulated while not running, relaunch | CellKeeper started on the native backend, restored 80%, confirmed it, and then switched to Simulated. |

All runs ended with the owner's 80% in effect and no record left behind. The CellKeeper preferences used for these runs were deleted afterwards.

### O10 — The limit held through sleep (owner-performed) `[VERIFIED-EXPERIMENTALLY]`

**Setup:**
- The owner ran the Debug build on the native backend with a CellKeeper limit of 85%, on AC, and closed the lid.
- Readings come from:
  - `pmset -g log`, which is documented and was read-only;
  - CellKeeper's unified log, including its telemetry;
  - `pmset -g batt`, and `pmset -g battlimit` after wake.
- Times are local, on 2026-10-06.

| Time | Event | Charge Limit | Battery |
|---|---|---|---|
| 21:31:23 | CellKeeper's will-sleep evaluation. The change to 85% was still rate-limited (O11). | 80% (the owner's) | — |
| 21:31:28 | Clamshell sleep | 80% | 81%, AC |
| 21:32:43 | Maintenance dark wake. CellKeeper recorded 80% and set 85%, confirmed by read-back. | 85% | 81% |
| 21:33:01 | Maintenance dark wake (10 s) | — | 81%, AC, charging (CellKeeper's telemetry) |
| 21:33:11–21:41:23 | Asleep (492 s) | — | — |
| 21:41:23 | Maintenance dark wake | — | 85%, AC, not charging (CellKeeper's telemetry; `pmset -g log`'s line for this wake still showed 81%) |
| 21:42:24–21:45:11 | Asleep, apart from one 10 s dark wake | — | 85% |
| 21:45:11 | Full wake (lid opened) | — | 85% |
| 21:46:21 | Read after wake | 85%, both entries as in O4 | 85%, AC attached, not charging |
| 21:49:20 | CellKeeper quit | 80% restored and confirmed; record deleted | — |

CellKeeper made no change between 21:32:43 and quitting. So the 85% read at 21:46 is the value set before the Mac went back to sleep, not a value re-applied after wake.

**Observed:**
- The 85% limit survived about 12.5 minutes of sleep, five maintenance dark wakes and a full wake.
- On AC, with the lid closed throughout, the battery rose from 81% to 85% between dark-wake readings (21:33:01 and 21:41:23). From then on it was reported "not charging" at 85%.
- Every battery reading was taken at a dark wake or after the full wake; none was taken during sleep itself.

**Inferred, not observed** `[INFERRED/UNVERIFIED]`:
- That the charging, and its stop at the limit, happened during sleep itself, with macOS enforcing the limit while asleep. The charge stopping at exactly the limit fits that. However, the charging could also have happened during the dark wakes, which this run cannot rule out.
- Nothing is known about longer sleeps or sleep on battery power.

### O11 — The shortcut runs during a maintenance dark wake `[VERIFIED-EXPERIMENTALLY]`

**What happened:**
- The owner turned "Manage charging" off and on again less than a minute before closing the lid. So CellKeeper's rate limit refused the change to 85% at will-sleep.
- CellKeeper's periodic evaluation then ran during a maintenance dark wake, with the lid closed, at 21:32:43.
- The shortcut ran in 0.21 s, and the read-back confirmed 85%.
- The rate limit had expired while the Mac slept. Its clock keeps counting during sleep.

**What it means:** CellKeeper can change the limit while the lid is closed. That is an ordinary setting change, and every restore path still applies.

### O12 — Telemetry was briefly missing at a dark wake `[VERIFIED-EXPERIMENTALLY]`

At 21:41:23.644, during a dark wake, CellKeeper's evaluation found no battery telemetry. It left macOS's limit unchanged, as designed ([architecture](../architecture.md), "Missing or stale telemetry"). The reading arrived 134 ms later.

If missing telemetry released the limit, this wake would have restored 80% and a later evaluation would have set 85% again.

### O13 — The owner's walk-through of the app `[VERIFIED-EXPERIMENTALLY]`

The owner followed a scripted walk-through, starting on the Simulated backend. From CellKeeper's log:

| Step | What happened |
|---|---|
| Choose the macOS Charge Limit backend | The switch completed. The first evaluation was rate-limited for 27 s by requests made on the Simulated backend a minute earlier. After that, CellKeeper recorded 80% and ran nothing, because CellKeeper's limit was also 80%. |
| Pick 85% | The shortcut ran in 0.23 s; read-back 85%. |
| Turn "Manage charging" off | 80% restored and confirmed. |
| Switch to Simulated, back again, and quit, with management still off | Each time: nothing to restore, which is correct because CellKeeper held no change. |
| Second session: management on, off, on | 85% set, then 80% restored. The third change was rate-limited as designed and was applied later, during sleep (O11). |

**Change made afterwards:** requests sent to a backend that touches no hardware no longer count toward the rate limit once the backend changes. Real changes still count after a round trip through Simulated.

**The owner's report afterwards:** the settings looked right overall but cluttered (to be tidied up separately).

**Not covered here:**
- The look of the settings (the limit picker, and the disabled settings with their explanations) is not in the log; it rests on the owner's report.
- Restoring a changed limit on a backend switch and on quit was not exercised in this walk-through, because management was off. Both are covered by O9; quitting is also covered by the end of O10.

### O14 — How the owner's shortcut is built `[VERIFIED-EXPERIMENTALLY]`

From the owner's screenshot of the Shortcuts editor (Shortcuts 10.0), the shortcut "CellKeeper Set Charge Limit" has two parts:

1. **Receive Apps and 18 more from Nowhere**, with **If there's no input: Continue**. Shortcuts adds this block when an action uses Shortcut Input; the owner left it as it was.
2. **Set charge limit to Shortcut Input**, with **Set Until Tomorrow** off. This is how the editor displays the action. Press coverage calls it "Set Battery Charge Limit" (S2); the name in the action library was not checked.

"From Nowhere" means the shortcut is not offered in the Share sheet or Quick Actions. The command-line input in O1 and O3 reached it all the same.

### O15 — A change made outside CellKeeper is kept `[VERIFIED-EXPERIMENTALLY]`

**Setup:**
- The Debug build of this branch, after the owner's decision to adopt outside changes (decision 5).
- The owner's saved settings: native backend, CellKeeper limit 85%, management on.
- The owner's own limit was 80%.
- A change in System Settings was stood in for by running the owner's shortcut from Terminal with 90.

| Time | What happened |
|---|---|
| 22:20:26 | CellKeeper recorded 80% and set 85%, confirmed by read-back. |
| 22:20:35 | `shortcuts run "CellKeeper Set Charge Limit" -i <file with 90>` exited 0; `pmset -g battlimit` read 90%. |
| 22:20:36 | macOS sent a power-source notification, and CellKeeper evaluated at once. It kept 90% as the owner's own limit, deleted its record, wrote nothing, and turned off Manage charging. The saved settings then had management off. |
| 22:20:47 | Quit: "Nothing to restore … macOS reports 90%". Nothing was run, and the limit stayed at 90%. |

**Afterwards:** the owner's 80% was set again with the shortcut and read back, and the owner's saved settings were put back as they were.

**Also observed:** changing the Charge Limit produced a power-source change notification, so CellKeeper noticed the change within about a second, not at its next periodic check.

**Repeated after the review fixes (22:37–22:38), with the same setup:**
- CellKeeper again kept 90% about a second after the shortcut ran, and wrote nothing.
- The saved settings had management off once the preferences were written to disk; a read about a second after adoption still showed the old value.
- Quitting wrote nothing.
- That build removed the adoption marker as soon as management off had been saved. The next review pointed out that settings reach the disk asynchronously, so the marker now stays until the user turns management on again.

**Run with the final design (22:46–22:48):**
- CellKeeper kept 90%, wrote nothing, and left the marker in place after quitting.
- To stand in for settings that never reached the disk, the owner's earlier saved settings (management on) were put back while the marker stayed.
- On relaunch CellKeeper logged "CellKeeper kept a Charge Limit of 90% set outside it; Manage charging stays off until you turn it on". It changed nothing, and the limit stayed at 90% through launch and quit.
- The saved settings showed management off a few seconds later. A read right after quitting still showed the old value, which is the lag the marker covers.
- Afterwards the test marker was removed, and the owner's 80% and saved settings were put back.

### O16 — Shortcuts has a "Get charge limit" action (owner's report)

The owner reports that the Shortcuts action library on this Mac contains a "Get charge limit" action. This answers open question 1.

**Not tested yet:**
- what the action returns: a number, text, or something else;
- what it returns when there is no limit (100%), and in temporary states;
- how its result reaches `shortcuts run … -o <file>`;
- how long it takes.

A shortcut containing only that action, run with `-o`, would answer these without changing anything. O18 does that.

### O17 — The limit held through a restart (owner-performed) `[VERIFIED-EXPERIMENTALLY]`

**Setup:**
- CellKeeper was not running, and the owner's own limit of 80% was in effect, with both entries at 80 (O4).
- The owner restarted the Mac with Apple menu › Restart. In the power log, `powerd` started again at 23:18:35.

**After logging back in, before CellKeeper was opened:**
- `pmset -g battlimit` showed both entries at 80%, reason `manualChargeLimit`.
- The entry owned by PowerUIAgent now named PID 476 instead of 97057, as expected after a fresh boot.
- System Settings › Battery › Charging showed 80% (owner's report).

**Inferred, not observed:** macOS keeps the Charge Limit as a persistent setting. That rests on one restart, with the owner's own value. A value set by CellKeeper should behave the same way, since it is the same setting, but that was not restarted. Shutdown was not tested.

### O18 — The "Get charge limit" action returns the limit as text `[PUBLIC-API][VERIFIED-EXPERIMENTALLY]`

**Setup:**
- The owner created a shortcut "CellKeeper Get Charge Limit" containing only the "Get charge limit" action.
- It was run unsandboxed, from Terminal, a few minutes after the restart in O17.
- 85% and 100% were set briefly with the owner's setter shortcut (O1). Afterwards 80% was set again and read back.

| Limit set | Getter output (`--output-type public.plain-text`) | `pmset -g battlimit` | Getter time |
|---|---|---|---|
| 80 (owner's) | `80` | 80 | 0.12–0.16 s |
| 85 | `85` | 85 | 0.15 s |
| 100 | `100` | No battery level limits set | 0.17 s |

**Other observations:**
- **Output format:** plain ASCII digits with no line terminator. `-o -` writes the same to standard output.
- **No file without an output type.** With `-o <file>` and no `--output-type`, the type follows the file extension. With `.txt` the file was written. With `.bin` the run exited 0 in 0.13 s and **wrote no file**. A missing output must therefore count as a failure.
- **Cold start:** the very first run, about 4 minutes after boot with a load average near 19, took **91.7 s** (and, with `.bin`, wrote nothing). Warm runs took 0.12–0.17 s, about the same as the setter (0.19 s). CellKeeper's 20 s run deadline would have stopped that first run.

**Inferred, not observed:**
- The getter reports the configured Charge Limit.
- It reports 100 where `pmset` reports no limit, which supports I2 for this state.
- What it returns during a temporary state ("Charge to Full Now", "Set Until Tomorrow") is unknown. Unlike `pmset`'s entries, a single number cannot show that such a state exists.
- Whether it works from the App Sandbox (writing its output into the container) is untested. The setter does work from the sandbox (O3).

---

## Inferences `[INFERRED/UNVERIFIED]`

- **I1:** Standard input probably reaches the shortcut as untyped data that "Set Battery Charge Limit" cannot use as a number, while a `.txt` file is coerced to text and then to a number. Only the outcome (O1, O2) was observed.
- **I2:** "No battery level limits set" probably means the Charge Limit is at 100%: that is what the report showed after setting 100%. It might also appear in other states, such as a temporary "Charge to Full Now" (open question 3). CellKeeper therefore records it as the user's 100% limit only after the user confirms that their limit is 100%. It never maps "no limit" or an unknown state to 100% by itself.
- **I3:** Entries with a reason other than `manualChargeLimit` (for example from Optimized Battery Charging) or with disagreeing values may exist. CellKeeper treats them as unrecognised and changes nothing.
- **I4:** `chargeSocLimitDrain = 1` is consistent with third-party reports that macOS drains a battery above the limit down to it (02 §3.7, unverified).
- **I5:** The 80% limit observed throughout was the owner's own setting. The owner confirmed this; the observations are consistent with it.

---

## Sleep and restart

**Status:** sleep observed once (O10–O12) and restart once (O17); shutdown not tested. The design does not depend on the outcome:
- CellKeeper re-reads the limit after every wake and at launch.
- It treats any value it did not set as an outside change.
- It keeps the user's own limit in a persisted record until it has been restored and read back.

Planned procedure:
1. **Sleep (done, O10):**
   - CellKeeper sets 85% (recording 80%).
   - The owner sleeps the Mac with the lid closed for at least 2 minutes, then wakes it.
   - Compare `pmset -g battlimit` before and after, and `pmset -g log` for the sleep/wake entries and their charge readings.
   - Then restore 80%.
   - In the run, the 85% was set during a dark wake just after the lid closed (O11), rather than before.
2. **Restart (done, O17):** with the owner's own 80% (no CellKeeper change), restart and read `pmset -g battlimit`. Optionally repeat with a CellKeeper-set value, which also exercises the launch-time recovery path (not done).
3. **Enforcement during sleep:** not yet observed directly. In O10, with the lid closed on AC, the charge rose to the limit and stopped there between dark-wake readings. Enforcement during sleep itself is only inferred from that. A longer sleep, and sleep on battery power, are deferred to a later observation run.

---

## Decisions taken from this spike

1. **Write path:** `shortcuts run "CellKeeper Set Charge Limit" -i <file>`. The file holds only the digits and is created in the app container's temporary directory and removed afterwards. Runs have a 20 s deadline, because a shortcut that asks a question would otherwise wait forever.
2. **Read-back:** `pmset -g battlimit`, labelled undocumented and used read-only.
   - The arguments are fixed.
   - The parser accepts only the shapes in O4.
   - Every active entry must be a manual Charge Limit, and they must agree.
   - Anything else is "unrecognised": CellKeeper then records nothing and sets no new limit. It still attempts to restore a limit it already recorded, and treats that restore as unconfirmed until it reads it back.
3. **Sandbox:** stays on, with no new entitlements (O3). Keeping it also blocks pmset's SMC user-client attempt (O7).
4. **Confirmation:** only a read-back equal to the requested value. The exit status never confirms (O2).
5. **Outside changes (owner decision, 2026-10-06):** a recognised limit that CellKeeper did not set is adopted as the owner's own limit, and nothing is written. CellKeeper then turns off "Manage charging", so it does not override the change later. This replaces the first design, which restored the recorded limit and faulted.
   - CellKeeper cannot tell who made a change, so a change by another tool or by macOS is adopted too.
   - A "no limit" report might be a temporary full charge (open question 3), so the earlier limit is named in the log and the menu.
   - The owner's longer-term direction is that CellKeeper itself controls charging, with macOS's own Charge Limit turned off. That needs a different backend and is not part of milestone 2.

---

## Open questions

1. ~~Is there a "Get Battery Charge Limit" Shortcuts action?~~ Yes (O16), as one beta-era report suggested (S3), and its output matches `pmset` (O18). Should it replace `pmset -g battlimit` as the read-back? It would mean a second shortcut, and it cannot show temporary states. Does it work from the sandbox, and what does it return during a temporary full charge?
2. How does "Set Until Tomorrow" (S4) appear in `battlimit`, and does macOS revert it in a way CellKeeper would see as an outside change?
3. How does "Charge to Full Now" appear in `battlimit`: an empty list, `Terminated = 1`, or another reason?
4. Does Optimized Battery Charging add entries with another `chargeSocLimitReason`?
5. Shutdown behaviour, longer sleeps, and a restart with a CellKeeper-set value (above); one sleep run (O10) and one restart (O17) are recorded. Apple Community users report that the limit is not enforced while the Mac is shut down (02 §4).
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
