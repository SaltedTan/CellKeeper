# 12 — Guided battery calibration, without SMC writes

- **Date:** 2026-10-21
- **Status:** Research and design, for the owner's approval. Nothing is
  built. The owner asked on 2026-10-20 for a calibration feature like the
  one other battery tools offer, and chose, from the options in §6, "write
  up, then build A": a calibration that CellKeeper guides and the owner
  carries out, with no SMC write, no privileged helper and no root. It is
  built only after the owner approves this design (§7).
- **Machine:** Mac16,1 (MacBook Pro, Apple M4), macOS 27.0.1 (26A434),
  system firmware mBoot-20457.1.29, as in notes 09–11.
- **Labels:** as in [note 06](06-safety-analysis.md): **[S]** a sourced
  statement, with its source number (§9); **[I]** an inference; **[O]** an
  open question. `[VERIFIED-EXPERIMENTALLY]` marks an observation on this
  Mac, made read-only.

---

## Summary

- **What calibration can fix.** The battery's fuel gauge estimates how
  much charge the battery holds (its chemical capacity, Qmax) and how
  much of it is left. If those estimates drift, the percentage shown is
  wrong: the Mac shuts down "early", or the percentage jumps. A
  calibration gives the gauge the conditions it needs to relearn. It does
  not make the battery healthier, and the "Maximum Capacity" shown
  afterwards can go up or down [S1, I].
- **What the gauge needs** (TI's Impedance Track gauges, the design Apple's
  battery data follows, §2): two readings of the battery's resting voltage,
  at least 37% of its design capacity apart, or one such reading followed
  by a genuine full charge. A reading needs the battery **at rest**: almost
  no current (below about 10 mA by default) for about 2 h after a charge
  and about 5 h after a discharge, at 10–40 °C [S1–S4]. **An awake Mac,
  running from its battery or charging, is never at rest.** A rest at a
  low level therefore needs the Mac asleep or shut down, with nothing
  charging it [I].
- **Other tools' calibration skips that rest.** AlDente Pro, battery and
  batt all drain the battery to 10–15% while plugged in, then charge it
  straight back to 100% and hold it there for 1–2 h (§4). Without a rest
  at the low level, that is unlikely to relearn capacity [I]; it does let
  the gauge update its resistance estimates.
- **macOS already keeps its estimate accurate in normal use:** with its
  Charge Limit or Optimized Battery Charging on, a Mac "will occasionally
  charge to 100% to maintain accurate battery state-of-charge estimates"
  [S5], and it may recalibrate maximum capacity after an update [S6]. A
  CellKeeper calibration is for when the percentage still misbehaves, not a
  routine.
- **The SMC adapter cut (`CHIE`, note 11) is not needed.** It could drain
  the battery without the owner unplugging, but not give the rest at the
  low level, and it needs SMC writes, a root helper, and safeguards for
  sleep, the lid and crashes (§5). The owner unplugging once and plugging in
  once does the same with public APIs only.
- **The design (§7):** CellKeeper raises macOS's own Charge Limit to 100%
  (as it already can, note 08), lets the battery charge and rest, asks the
  owner to unplug, watches it drain to 20%, asks the owner to sleep or shut
  down the Mac unplugged for at least 5 hours, then asks the owner to plug
  in, lets it charge to full, and restores the owner's own limit. It
  takes one to two days, mostly unattended, and is user-initiated only,
  with no schedule (§7.7). Besides approving the design, one part needs
  the owner's decision: it cannot check the battery's temperature on
  macOS 27 (§7.6).

---

## 1. Purpose

Other battery tools offer a "calibration" mode. The owner asked on
2026-10-20 whether the adapter cut of note 11 could provide one, since a
calibration discharges the battery below 80% while the Mac stays plugged
in. This note answers three questions:

1. What does a calibration need to do for the battery's gauge to relearn,
   and does it help on this Mac (§2–§3)?
2. What do other tools do, and what goes wrong for them (§4)?
3. Can CellKeeper do it here, and how (§5–§7)?

Note 06 already set rules for it (R23): user-initiated and abortable; never
below max(floor, 15%); abort outside 10–40 °C or on an unexpected change of
power (note 06 §4). This note keeps them, and says where macOS 27 prevents
one.

## 2. How the gauge relearns

Apple does not document its battery gauge. Its battery data follows TI's
Impedance Track design: public dumps of `AppleSmartBattery` from M1
MacBooks list `Qmax`, `DOD0`, `PassedCharge`, `WeightedRa` and related
fields [S10], and Apple's published `AppleSmartBattery` source, in its
Apple-silicon build path, defines report channels for the maximum Qmax and
for counts of successful and failed Qmax updates [S9]. Which gauge chip
Apple uses is not public [O]. The rules below are TI's, and apply to this
Mac by inference [I].

| Rule | Detail | Source |
|---|---|---|
| Capacity (Qmax) is learnt from two rest readings | Qmax = the charge passed between two resting-voltage readings ÷ the difference in depth of discharge they show | S1 §2.3–2.4; S4 §6.4.2 |
| They must be far enough apart | At least 37% of the design capacity passed between them | S1 §2.4; S4 §6.4.2 |
| Or one rest, then a full charge | If a valid reading from an earlier rest exists, Qmax is also updated at a valid charge termination | S4 §6.4.2; S2 §3.1; S3 §4.1 |
| What a rest is | The current below the quit current (default 10 mA; TI recommends below C/20) for the relax timeout; then the voltage must settle (dV/dt < 4 µV/s) | S4 §6.3, §15.13.1; S3 §3.5 |
| How long a rest takes | About 2 h after a charge and 5 h after a discharge; after 5 h a reading is taken anyway. An older note: about 1 h between 0 and 80% depth of discharge, 3–4 h beyond, longer when cold | S4 §6.4.2; S2 §3.1; S1 §2.3 |
| When a reading does not count | Outside 10–40 °C; in the cell's flat voltage region (3737–3800 mV per cell for TI's default chemistry); or if the current-measurement error since the last reading exceeds 1% of design capacity | S4 §6.4.2; S1 §2.3 |
| Resistance is learnt differently | During discharge, with no rest needed | S4 §6.3 |
| A "fast" Qmax update | One rest reading and a discharge below 10%; whether a field gauge has it enabled depends on its configuration | S4 §6.4.3 [O for Apple's] |
| Drift without updates | TI's error estimate grows by 1% per 20 cycles without a Qmax update | S1 §2.8; S4 §14.13 |
| TI's learning cycle | Discharge, rest ≥ 5 h; charge to full, rest ≥ 2 h (Qmax update); discharge, rest ≥ 5 h (second update) | S2 §3.2, §5; S3 §4.2 |

What follows for a Mac [I]:

- **An awake Mac is never at rest.** Running from its battery, this Mac drew
  about 1.1 A in note 11's run (§10 there), about a hundred times the quit
  current; charging, it takes 2.5 A. A Mac asleep draws far less, and a Mac
  shut down almost nothing; whether the sleep current of this Mac is below
  the quit current is not known [O].
- **The rest at a high level is easy:** with macOS's limit at 100% and the
  battery full, the Mac runs from its adapter and the battery is idle
  (note 10 §9 saw the same at 80%).
- **The rest at a low level is the hard part,** and also what a narrow
  window of use never provides: a battery kept between, say, 50% and 80%
  never moves 37% between rests [I]. That is the case calibration is for.
- **Where to rest low:** about 20%. Lower adds wear and risk for no gain;
  around 50% may sit in the flat voltage region, where a reading does not
  count (TI's default chemistry; Apple's cells are not documented) [I].

## 3. This Mac, and what macOS already does

`[VERIFIED-EXPERIMENTALLY]` (read-only `ioreg`, 2026-10-20): on macOS 27.0.1
this Mac's `AppleSmartBattery` entry no longer shows the gauge's learning
fields. Its `BatteryData` holds only summary values (`DesignCapacity` 6249
mAh, `NominalChargeCapacity` 6302 mAh, `FullChargeCapacity` 6150 mAh,
among others), with no `Qmax`, `DOD0` or `PassedCharge`; the cycle count is
56. So CellKeeper cannot watch the gauge learn. Before and after a
calibration it can only compare these summary capacities, which the
gauge's other updates also change [I]. Nothing was written, and no
serial number was recorded.

What macOS does [S]:

- With Optimized Battery Charging or the Charge Limit, "your Mac will
  occasionally charge to 100% to maintain accurate battery state-of-charge
  estimates" [S5]. Those are the charge terminations of §2.
- After a software update a Mac with Apple silicon "might recalibrate
  maximum battery capacity", and "might briefly run on battery power, even
  when connected to AC power" [S6]. Note 06 R26 already says CellKeeper
  must not treat that as a fault.
- MacBook Pro batteries are rated to keep 80% of their capacity for 1000
  cycles [S7]; one calibration is about one cycle.

## 4. What other tools do

Behaviour only, from each project's public documentation; no code or text
was copied. AlDente's is from its public web page only: its repository,
source and binaries were not consulted (CONTRIBUTING §1 allows public
descriptions of behaviour to inform requirements).

| Tool | Licence | Steps | Rest at a low level? |
|---|---|---|---|
| AlDente Pro, "Calibration Mode" [S14] | Proprietary | Charge to 100%; discharge to 10% while plugged in; recharge to 100%; hold 1 h; return to the user's limit. Suggested monthly, or every two weeks if the battery usually sits near 50% | No |
| actuallymentor/battery, `battery calibrate` [S11] | MIT | Discharge to 15%; recharge to 100%; keep it there 1 h | No |
| charlie0129/batt, auto-calibration [S12] | GPL-2.0 | Discharge to 15% (adjustable); charge to 100%; hold 120 min (adjustable); prevents idle sleep throughout | No |
| mhaeuser/Battery-Toolkit [S13] | BSD-3-Clause | No automatic calibration: the user drains with the adapter disabled, then recharges. Archived | — |

Two findings matter here:

- **batt turns its calibration off on this firmware.** On 20457.x it can
  only limit charging by cutting the adapter, and "because `batt` owns the
  adapter to enforce the limit", auto-calibration is disabled in that mode
  [S12, README]. [S]
- **The problems reported with a drain while plugged in** come from the
  adapter cut itself: macOS behaves as if the adapter were unplugged, so a
  closed lid sleeps the Mac and ends clamshell mode, external displays go
  dark, and macOS's on-battery settings and low-battery warnings apply;
  tools hold off idle sleep, or turn sleep off altogether with its own
  overheating warning; a crash can leave the adapter cut [S12; S11
  issues]. [S, single reports weak]

## 5. Where the adapter cut fits

Note 11 verified on this Mac that writing `CHIE` `08` makes it run from its
battery with the adapter plugged in, and `00` brings the adapter back. For
a calibration that gives one thing: **the drain, without unplugging.** It
does not give the rest at a low level: with the cut on, the battery
supplies the Mac, about 1 A; restore it, and the Mac charges. Resting low
still needs sleep or shutdown, and whether a cut survives either was never
tested (note 11 §8, question 3) [I].

Against that one saved step:

- It needs an SMC write layer, which agents will not write (note 11 §2.2),
  and a root helper; the owner decided on 2026-10-20 not to use `CHIE` in
  CellKeeper (note 11 §2.3).
- While the adapter is cut macOS reports no adapter at all (note 11 §10),
  so CellKeeper could not tell a real unplug from its own cut.
- Every hazard in §4 applies.

So option B of §6 is not pursued.

## 6. The options put to the owner

| | A. Guided | B. With the adapter cut |
|---|---|---|
| The drain | The owner unplugs; the Mac runs from its battery in normal use | `CHIE` cuts the adapter |
| The rest at a low level | The Mac asleep or shut down, unplugged | Still needs sleep or shutdown; the cut across sleep untested |
| Privileges | None beyond today's: macOS's Charge Limit through the Shortcuts action (note 08) | SMC writes, a root helper |
| Owner's steps | Unplug once, plug in once, put the Mac to sleep or shut it down once | Put the Mac to sleep or shut it down once |

The owner chose **A** (2026-10-20). The other choices offered were to
record this only, to pursue B, or to drop calibration.

## 7. Design: guided calibration

### 7.1 What it uses

Only what CellKeeper has today, plus a new session:

- **macOS's Charge Limit through the Shortcuts action** (note 08), through
  the native-limit backend: it records the owner's limit durably before
  any change, confirms each change by reading `pmset -g battlimit`, and
  restores the owner's limit on stop, quit or failure. Any change it did
  not make is taken as the owner's own: it writes nothing and turns
  management off.
- **Battery readings** CellKeeper already takes: the charge, the power
  source, charging and charged, and the summary capacities and cycle
  count, with their freshness rules.
- **Power-source, sleep, wake and clock-change notifications** it already
  observes.

Nothing else: no SMC, no helper, no root, no private API, and no new
privileged interface.

### 7.2 The steps

A calibration is one **session**, stored under its own versioned key and
read back after every write, like the scheduled full charge. Each step
has an entry time (wall clock and monotonic), a bound, and an owner action
if it needs one.

| # | Step | CellKeeper does | The owner does | Ends when |
|---|---|---|---|---|
| 0 | Start | Checks §7.3; records the summary capacities and cycle count ("before") | Starts it, in Settings | Admitted, or refused with the reason |
| 1 | Charge to full | Sets macOS's limit to 100% | — | macOS reports the battery charged (`FullyCharged`, or 100% and not charging); at most 6 h, then the session ends (§7.5) |
| 2 | Rest at the top | Keeps the limit at 100% | Leaves it plugged in | 2 h after step 1 ends |
| 3 | Unplug | Asks the owner to unplug (§7.4) | Unplugs | The Mac is on battery power; if not within 4 h of the request, the session ends |
| 4 | Drain | Watches the charge; asks again if it falls below the target (§7.5) | Uses the Mac on battery, as usual | The charge reaches the target (20%) |
| 5 | Rest at the bottom | Asks the owner to sleep or shut down the Mac, unplugged, for at least 5 h | Puts the Mac to sleep or shuts it down; leaves it unplugged | Next reading after the Mac comes back: §7.5 decides whether the rest counts |
| 6 | Plug in | Asks the owner to plug in | Plugs in | The Mac is on AC power |
| 7 | Charge to full | Sets (or keeps) the limit at 100% | — | macOS reports the battery charged; at most 6 h |
| 8 | Finish | Restores the owner's limit; records the capacities and cycle count ("after") and shows both | — | Done |

The whole session ends after 72 h, whatever its step, with the owner's
limit restored. If the owner unplugs during steps 1–2, the session moves
to step 4 and records the top rest as short; if the owner plugs in during
step 4 or 5, before the target or the 5 h, it moves to step 7 and records
the drain or the rest as incomplete. Either way the report says so, and
says the gauge may not have relearnt (§7.8).

**Why these values** [I]. Step 2's 2 h and step 5's 5 h are TI's rest
times (§2). The 20% target: a move of about 80% from full, far more than
37%, and outside the flat region; it stays above note 06's
max(floor, 15%). Steps 7–8 end at the charge termination, which is the
second Qmax update of §2; a second rest at the top would add hours at
100% for little. The 6 h bound on a charge is generous for a charge from
20% on the Mac's adapter; reaching it means something is holding the
charge, such as Optimized Battery Charging (§7.3).

### 7.3 When it may start

The same kind of check as a temporary full charge, with its reason shown
on the disabled button:

- macOS's Charge Limit is available and CellKeeper can read it (Apple
  silicon, macOS 26.4 or later, the shortcut installed), and CellKeeper's
  control is macOS's Charge Limit;
- management is on, and no change by the owner is pending adoption;
- the Mac is on AC power, with a fresh reading;
- no temporary or scheduled full charge is running, and no weekly full
  charge falls inside the next 72 h (or the session holds it off; §8);
- the owner has confirmed that Optimized Battery Charging is off, or
  accepted that step 1 may take longer: CellKeeper cannot read that
  setting (note 01), and with it on macOS may hold the charge at 80%.

### 7.4 Asking the owner

Each request is shown in the menu, as the status line and its next action,
and, if the owner has turned notifications on, as a notification. Both are
new: today's notifications report what happened and ask for nothing. Each
request says what to do and why ("Unplug your Mac now; CellKeeper will
watch the battery drain to 20%"), and stays until it is done or the
session ends. The menu and Settings show the step, the time left in it,
and a Cancel button throughout.

### 7.5 How the session ends early, and what "counts"

- **Cancel**, at any step: the owner's limit is restored and the session
  removed. The report says which steps were done.
- **Quit, or the Mac restarting:** CellKeeper already restores the
  owner's limit on quit. The session is kept; when CellKeeper next runs it
  resumes at the same step, and sets the limit to 100% again only in the
  steps that need it (1, 2, 7). It has no wake alarm and no launch at
  login, so after a shutdown the owner opens CellKeeper again; the menu
  says so before step 5.
- **A change CellKeeper did not make** (the owner changes the limit in
  System Settings, or another tool does): the backend takes it as the
  owner's, as today; the session ends, with nothing written.
- **A failure** to set or confirm the limit: the session ends, with the
  backend's own restore.
- **The 72 h bound, or a step's bound:** the session ends and the owner's
  limit is restored.
- **Below the target in step 4:** CellKeeper does not discharge anything,
  so it cannot stop the drain. If the charge falls to 15% before the owner
  starts the rest, it asks again, more urgently; below that, macOS's own
  low-battery warnings take over.
- **Whether the low rest counts:** CellKeeper cannot watch the Mac while
  it is asleep or off. It counts the rest if, at the first reading after
  it, the Mac is still on battery power, at least 5 h of wall-clock time
  have passed since the last reading before it, and the charge has
  barely moved (at most 3 points lower, and not higher). A clock moved
  backwards, or the Mac back on AC power, does not count. The rule is an
  inference, and the gauge itself decides [I].

### 7.6 Temperature

Note 06 R23 aborts a calibration outside 10–40 °C, TI's window for a
reading (§2). On macOS 27 CellKeeper cannot read the battery's
temperature: IOPowerSources, the registry, `pmset` and `system_profiler`
no longer show it, and the remaining sources are private, privileged, or
both (note 01, summary item 5). **Proposed:**
where a temperature is available, the rule applies as written; where it
is not, as on this Mac, the session may start only after the owner
confirms a room at 10–35 °C and the Mac out of a bag and off soft
surfaces, the menu shows "temperature unknown" throughout, and the
report says it was not checked. The battery's own protections apply
either way (note 06). **This is a departure from R23 and needs the
owner's decision.**

### 7.7 How often

User-initiated only, as R23 says; no schedule. Settings shows when the
last calibration finished, and suggests one only if the owner asks for
it: when the percentage misbehaves, or every few months for a battery that
rarely leaves a narrow window. TI's drift of 1% per 20 cycles (§2) and
macOS's own occasional full charges (§3) make monthly calibration, as
AlDente suggests, more than needed [I]. A scheduled calibration could come
later, with its own decision.

### 7.8 The report

At the end, or when the session ends early: the steps done, with their
times; the summary capacities and cycle count before and after; whether
each rest counted; and, plainly, that the gauge decides what it relearns,
that "Maximum Capacity" can go up or down, and that the result cannot be
checked on macOS 27 (§3). It goes into the activity log and the
Diagnostics report.

### 7.9 Safety

- **Restrictive-only (note 06 R8):** the only control output is macOS's
  Charge Limit, between 100% and the owner's own value; CellKeeper never
  discharges anything.
- **Floors (R5, R23):** the target is 20%, above max(floor, 15%); CellKeeper
  asks again at 15% (§7.5).
- **Never fight macOS (R26):** no response to macOS holding the charge or
  running from the battery on AC; a step that cannot finish ends at its
  bound.
- **Recovery (precondition 11):** the owner's limit is restored on every
  end; if CellKeeper cannot, System Settings › Battery › Charging sets it,
  with the value CellKeeper shows as the owner's own, as today.
- **Time at 100%:** about 2 h at the top, plus the time to the owner's
  unplugging (at most 4 h), plus the final charge; this is the main wear
  cost besides the cycle itself (§3).

### 7.10 What has to be built

From the code as it stands (2026-10-21):

- a pure session state machine and its store, with tests in the style of
  the scheduled full charge (injected clocks, telemetry and a fake Charge
  Limit system; a relaunch by a second controller on the same storage);
- a session-owned hold at 100%: today's temporary full charge ends the
  moment the battery is full, which would end step 2 at once;
- resuming after a quit or restart, re-applying 100% only in steps 1, 2
  and 7;
- the new requests in the menu, and new notification kinds;
- the admission checks and their reasons, Settings' calibration section,
  and the report in the activity log and Diagnostics;
- the documentation: `architecture.md`, `safety.md` (R23, and §7.6 once
  decided), the README's feature table and the roadmap.

## 8. Open questions

1. Does this Mac's gauge update Qmax at all from the guided cycle, and does
   it have the fast update enabled? Not observable on macOS 27 (§3) [O].
2. Is the Mac's sleep current below the gauge's quit current, so that
   sleep is a rest, or does the owner need to shut it down? Shutting down
   is the safer instruction until this is known [O].
3. Does Apple's charge to 100% with the limit at 100% end in a gauge
   charge termination? Apple says the Mac stops "within a few percentage
   points" of a limit [S5]; with no limit set it should charge fully [I, O].
4. Should a weekly full charge that falls inside a session be held off,
   or should the session refuse to start (§7.3)? To be settled in the
   implementation's review.
5. **For the owner:** the temperature rule (§7.6), and whether to approve
   the design.

## 9. Sources

All fetched on 2026-10-20 unless stated otherwise. The TI and Apple claims
were checked against these copies by a separate fact-check on 2026-10-21.

**Texas Instruments (gauge documentation)**

- **S1** — TI SLUA364B, "Theory and Implementation of Impedance Track
  Battery Fuel-Gauging Algorithm in bq20zxx Product Family":
  https://www.ti.com/lit/an/slua364b/slua364b.pdf . Supports §2.2–2.4
  (rest, Qmax, 37%), §2.3 (flat region 3737–3800 mV), §2.8 (1% per 20
  cycles).
- **S2** — TI SLUA903, "Achieving The Successful Learning Cycle" (2018):
  https://www.ti.com/jp/lit/pdf/slua903 . Supports §3.1–3.2 and §5 (rest
  times, charge termination, the learning cycle).
- **S3** — TI SLUA777, learning cycle for the bq28z610 and bq78z100:
  https://www.ti.com/lit/pdf/slua777 . Supports §3.5 (quit current below
  C/20) and §4.1–4.2.
- **S4** — TI bq40z50-R2 Technical Reference Manual, SLUUBK0B (the
  SLUUBK0A link redirects to revision B):
  https://www.ti.com/lit/ug/sluubk0a/sluubk0a.pdf . Supports §6.3
  (resistance updates in discharge, Qmax in rest), §6.4.2 (rest criteria,
  disqualifications, charge termination), §6.4.3 (fast Qmax), §14.13,
  §15.13.1 (quit current, relax timeouts).

**Apple**

- **S5** — Apple Support 102338, "About Optimized Battery Charging and
  Charge Limit on your Mac": https://support.apple.com/en-us/102338 .
  Supports §3 (occasional 100%), and the limit's range and behaviour.
- **S6** — Apple Support 102589, battery health management on Mac laptops
  with Apple silicon: https://support.apple.com/en-us/102589 . Supports §3
  (recalibration after an update; briefly on battery while connected).
- **S7** — Apple Support HT201585, battery cycle counts:
  https://support.apple.com/en-us/HT201585 . Supports §3 (1000 cycles).
- **S8** — Apple Support 101613, Energy Mode on a Mac:
  https://support.apple.com/en-us/101613 . Supports §4 (settings for
  battery and adapter differ).
- **S9** — apple-oss-distributions/PowerManagement, branch `main`,
  `AppleSmartBatteryManager/AppleSmartBattery.cpp` (APSL-2.0):
  https://github.com/apple-oss-distributions/PowerManagement . Supports §2:
  report-channel identifiers for the maximum Qmax and for successful and
  failed Qmax updates, inside the Apple-silicon build path. Identifiers
  only; no code was copied.

**Others (claims)**

- **S10** — exelban/stats issue #222, `ioreg` dumps of `AppleSmartBattery`
  from M1 MacBooks: https://github.com/exelban/stats/issues/222 . Supports
  §2 (Impedance Track fields on Apple silicon, on an earlier macOS).
- **S11** — actuallymentor/battery (MIT), README and issues:
  https://github.com/actuallymentor/battery . Supports §4.
- **S12** — charlie0129/batt (GPL-2.0), README (branch `master`) and
  issues: https://github.com/charlie0129/batt . Supports §4, including
  "auto-calibration are disabled in this mode" (adapter mode) and the
  clamshell, display and sleep reports.
- **S13** — mhaeuser/Battery-Toolkit (BSD-3-Clause), README:
  https://github.com/mhaeuser/Battery-Toolkit . Supports §4.
- **S14** — AlDente Pro, public feature page "Calibration Mode":
  https://apphousekitchen.com/feature-explanation-calibration-mode-2/ .
  Supports §4 (its steps and suggested frequency), as a claim about its
  behaviour. Read for behaviour only; nothing else from AlDente was
  consulted.
