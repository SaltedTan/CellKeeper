# 12 — Guided battery calibration, without SMC writes

- **Date:** 2026-10-21
- **Status:** Design approved by the owner on 2026-10-21, for
  implementation; nothing is built yet. The owner asked on 2026-10-20 for a
  calibration feature like the one other battery tools offer, and chose,
  from the options in §6, "write up, then build A": a calibration that
  CellKeeper guides and the owner carries out, with no SMC write, no
  privileged helper and no root. On 2026-10-21 the owner approved this
  design (§7) and decided its two open points (§7.6, §7.7).
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
  and about 5 h after a discharge, at 10–40 °C [S1–S4]. **A Mac running
  from its battery (about 1.1 A here) or charging is not at rest.** A rest
  at a low level therefore needs the Mac asleep or shut down, with
  nothing charging it [I].
- **Other tools' calibration skips that rest.** AlDente Pro, battery and
  batt all drain the battery to 10–15% while plugged in, then charge it
  straight back to 100% and hold it there for 1–2 h (§4). None of them
  includes a deliberate rest at the low level; how often their recipe
  relearns capacity is not established [I]. A drain does let the gauge
  update its resistance estimates.
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
  (as it already can, note 08) while the battery charges and rests, asks
  the owner to unplug, watches it drain to 20%, asks the owner to shut
  down (or sleep) the Mac unplugged and to plug it in again after a time
  at least 5 hours later, raises the limit to 100% again for the final
  charge, and then returns to its normal limit, confirmed. The limit is
  at 100% only in the charge and rest steps, which begin with the Mac
  plugged in and CellKeeper running (sleep, a crash or a failed return can
  keep it there longer, §7.2). It
  takes one to two days, mostly unattended, and is user-initiated only
  (§7.8). The owner approved it on 2026-10-21, deciding its two
  departures from note 06 R23: where the battery's temperature cannot be
  read, as on macOS 27, the owner confirms a cool room (§7.7); and the
  owner's requested actions arriving early continue the session (§7.6).

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

- **A Mac running from its battery, or charging, is not at rest.** Running
  from its battery, this Mac drew about 1.1 A in note 11's run (§10
  there), about a hundred times TI's default quit current; charging, it
  takes about 2.5 A. (Apple's quit current is not documented.) A Mac asleep draws far less, and a Mac
  shut down almost nothing; whether the sleep current of this Mac is below
  the quit current is not known [O].
- **The rest at a high level is easy:** with macOS's limit at 100% and the
  battery full, the Mac runs from its adapter and the battery is idle
  (note 10 §9 saw the same at 80%).
- **The rest at a low level is the hard part,** and also what a narrow
  window of use never provides: a battery kept between, say, 50% and 80%
  never moves 37% between rests [I]. That is the case calibration is for.
- **Where to rest low:** about 20%, as a conservative choice. Lower adds
  wear and risk for no known gain; around 50% may sit in the flat voltage
  region, where a reading does not count (TI's default chemistry; Apple's
  cells are not documented) [I].

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
  estimates" [S5]. Those are likely charge terminations in §2's sense
  [I].
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
  the native-limit backend: it records the owner's own limit durably
  before any change, confirms each change by reading `pmset -g battlimit`,
  and restores the owner's limit when CellKeeper quits or fails. Any
  change it did not make is taken as the owner's own: it writes nothing
  and turns management off. If CellKeeper is killed, the limit it set
  stays in effect until CellKeeper runs again, which restores the owner's
  limit first (note 08, O9).
- **Battery readings** CellKeeper already takes: the charge, the power
  source, charging and charged, and the summary capacities and cycle
  count, with their freshness rules.
- **Power-source, sleep, wake and clock-change notifications** it already
  observes.

Nothing else: no SMC, no helper, no root, no private API, and no new
privileged interface.

### 7.2 Where the limit is at 100%, and who watches

The session asks for macOS's limit at **100% only in steps 1, 2 and 7**
(§7.3), which begin only while the Mac is on AC power and CellKeeper is
running. In every other step, and after the session, CellKeeper's normal
policy applies as if no session were running: its own configured limit,
with management on. When CellKeeper quits, the backend restores the
owner's own limit, as today.

**Leaving 100% is confirmed, not assumed.** The session leaves step 2 for
step 3, and step 7 for step 8, only once the backend has confirmed the
normal limit by read-back; until then the menu shows "returning to your
limit". The request is retried as the policy's rate limits allow. If the
backend cannot apply it, the controller's existing failure handling
applies: it records the failure and falls back to the owner's own limit;
if that is confirmed, the owner's limit is in effect, and if not, the
notice that a restore is unconfirmed follows; three failures in a row
mark the backend faulted. Either way the session ends. So the drain and
the rest at the bottom begin with the normal limit in effect, except
after an early unplug (§7.6), when the return may still be pending as the
drain begins; on battery power the limit changes nothing until the Mac is
plugged in again.

**Where 100% can last longer** (disclosed before the start):

- **Sleep in steps 1, 2 or 7.** macOS keeps a limit through sleep (note 08,
  O10), so 100% stays in effect while the Mac sleeps on AC power. That is
  macOS's own default with no limit set, so it adds no risk beyond the
  time at 100%; the step's bound still applies, at the first evaluation
  after waking.
- **A return that is deferred or fails,** as above, until it is confirmed
  or the owner sets the limit.
- **CellKeeper killed or crashing in steps 1, 2 or 7:** the limit stays at
  100% until CellKeeper runs again (which restores the owner's limit
  first, note 08 O9) or the owner sets it.

CellKeeper cannot act while it is not running: its step bounds and the
72 h cap are applied at its next evaluation, not on time. Before a session
starts, CellKeeper shows the recovery, with the value to set in System
Settings › Battery (the owner's own limit), as `safety.md` precondition
11 requires.

### 7.3 The steps

A calibration is one **session**, stored under its own versioned key and
read back after every write, as the weekly full charge's store does.
Each step records its entry time, by the wall clock and by a monotonic
clock that counts sleep.

| # | Step | Limit | CellKeeper does | The owner does | Ends when |
|---|---|---|---|---|---|
| 0 | Start | normal | Checks §7.4; records the summary capacities and cycle count ("before"), the owner's own limit and CellKeeper's limit | Starts it, in Settings | Admitted, or refused with the reason |
| 1 | Charge to full | 100% | — | Leaves it plugged in | macOS reports the battery charged (`FullyCharged`, or 100% and not charging); at most 6 h |
| 2 | Rest at the top | 100% | Times the rest | Leaves it plugged in | 2 h on AC power by the monotonic clock that counts sleep, the timer restarting after a resume (§7.6); then the normal limit, confirmed (§7.2) |
| 3 | Unplug | normal | Asks the owner to unplug (§7.5) | Unplugs | The Mac is on battery power; at most 4 h |
| 4 | Drain | normal | Watches the charge | Uses the Mac on battery, as usual | The charge reaches the target, 20% (if it is at 15% or below, §7.6) |
| 5 | Rest at the bottom | normal | Shows the request with a clock time to plug in again, at least 5 h later | Shuts the Mac down (or puts it to sleep), unplugged; plugs in after the time shown | The Mac is back, and CellKeeper running (§7.6 decides whether the rest counts) |
| 6 | Plug in | normal | If the Mac is still on battery, asks the owner to plug in | Plugs in | The Mac is on AC power |
| 7 | Charge to full | 100% | — | Leaves it plugged in | macOS reports the battery charged, at most 6 h; then the normal limit, confirmed (§7.2) |
| 8 | Finish | normal | Records the "after" values and shows the report (§7.9) | — | Done |

A session ends after 72 h, whatever its step. Ending, here and below,
means the session is marked ended and CellKeeper's normal policy applies
again. A step that reaches its bound ends the session.

**Why these values** [I]. Step 2's 2 h and step 5's 5 h are TI's rest
times (§2). The 20% target is a conservative choice: about 80% below
full, far more than 37%, and well away from TI's default flat region;
whether it is outside the flat region of Apple's cells is not known. It
stays above note 06's max(floor, 15%). Step 7 ends at the charge
termination, a possible second Qmax update (§2); a second rest at the
top would add hours at 100% for little. The 6 h bound is generous for a
charge from 20% on the Mac's adapter; reaching it suggests that something
holds the charge, such as Optimized Battery Charging (§7.4).

### 7.4 When it may start, and what it excludes

A session may start only when all of these hold; otherwise the button is
disabled with the reason, as for a temporary full charge:

- macOS's Charge Limit is available and readable (Apple silicon, macOS
  26.4 or later, the shortcut installed), and CellKeeper's control is
  macOS's Charge Limit;
- management is on, and no change by the owner is waiting to be adopted;
- the Mac is on AC power, with a fresh reading;
- no temporary full charge is running and **no one-shot full charge is
  scheduled**: the owner cancels it first;
- the owner has confirmed that Optimized Battery Charging is off, or
  accepted that step 1 may reach its bound: CellKeeper cannot read that
  setting (note 01), and with it on, macOS may hold the charge at 80%;
- the owner has confirmed the temperature conditions of §7.7, if
  CellKeeper cannot read the battery's temperature;
- the owner has seen the recovery of §7.2, and, if notifications are off,
  that requests will appear only in the menu.

While a session exists, including after a relaunch or a clock change:

- starting a temporary full charge, or scheduling one, from the menu,
  Settings or a Shortcuts action, is refused with "a calibration is in
  progress";
- a weekly full charge that falls due is skipped, and recorded as
  handled, with that reason; the schedule continues after the session;
- changing CellKeeper's own limit is allowed: it is the normal policy of
  steps 3–6 and after;
- turning management off, or switching CellKeeper's control away from
  macOS's Charge Limit, ends the session.

### 7.5 Asking the owner

Each request is shown in the menu, as the status line and its next action,
and, if the owner has turned notifications on, as a notification. Both are
new: today's notifications report what happened and ask for nothing. Each
request says what to do and why ("Unplug your Mac now; CellKeeper will
watch the battery drain to 20%"), and stays until it is done or the
session ends. The menu and Settings show the step, the time left in it,
and a Cancel button throughout.

The rest's request carries everything the owner needs without CellKeeper:
"Shut down your Mac now and leave it unplugged. Plug it in again after
06:40 (at least 5 hours from now), even before you open CellKeeper." After
a shutdown, CellKeeper continues only when the owner opens it again (it
has no launch at login yet); the request says that too.

### 7.6 Early ends, resuming, low battery, and the rest

**Cancel**, at any step: CellKeeper's normal policy applies again at once,
and the session is marked ended and removed from storage. The store, like
the weekly full charge's, reads back every write but cannot promise that
the last write survives a crash or a power loss; so durability does not
rest on the mark (next paragraph). The report says which steps were done.

**Storage failures.** If a write of the session fails, or its read-back
differs, the session stops at once in memory (normal policy), and the menu
says so; CellKeeper does not wait for storage to recover.

**Resuming after a quit, a crash or a restart.** A session found at
launch never resumes on its own: an older record may have come back, or
the owner may have cancelled it before a crash. Startup runs in this
order:

1. **Before anything is written,** CellKeeper reads the session, macOS's
   current limit, and the backend's outstanding record, if any.
2. **The backend's own recovery runs first, as today:** after a crash it
   restores the owner's own limit and removes its record (note 08, O9).
   Ordinary policy, and the session, write nothing until step 4.
3. CellKeeper ends the session if the 72 h cap or the current step's
   bound has passed (the monotonic clock within the same boot, the wall
   clock across a restart), or if a §7.4 condition for the current step
   fails. It also ends it, writing nothing, if the limit is not
   accounted for: where the backend had a record (a crash), its recovery
   already judges the limit it finds against that record, and if it
   adopts an outside change, the session ends; where it had none (a quit
   restored the owner's limit and removed it), the limit read in step 1
   must equal the owner's own limit recorded in the session, and
   anything else is the owner's change.
4. Otherwise CellKeeper shows the session paused, with normal policy, and
   asks the owner to continue or cancel. Only "continue" lets it ask for
   100% again. Step 2's rest timer starts again: CellKeeper cannot know
   whether the Mac stayed plugged in while it was not running.

**Unexpected changes of power** end the session, as R23 requires:
unplugging during step 1 (the battery is not full), and plugging in
during step 4 (the drain has not reached its target). Two requested
actions arriving early are accepted instead, and recorded: unplugging
during step 2 moves to step 4 with the top rest short; plugging in during
step 5, before the time shown, moves to step 7 with the bottom rest short.
These two acceptances read R23's "unexpected" as "not the requested
action". **Decided by the owner on 2026-10-21: continue, and record the
rest as short.** An early unplug
during step 2 requests the return to the normal limit at once, with the
same confirmation as §7.2: the menu shows "returning to your limit" until
it is confirmed, and if it cannot be, the session ends as there.

**Low battery.** CellKeeper does not discharge anything, so it cannot
stop a drain; it can only ask, and never ask for a rest at too low a
charge. The rest's request is shown only while the charge is above 15%.
If CellKeeper sees the charge at 15% or below before the rest has begun
(for example, waking from a sleep during the drain), the session ends,
and CellKeeper asks the owner to plug in now. Below that, macOS's own
low-battery warnings take over.

**Whether the rest at the bottom counts.** The rest is the owner's; the
gauge decides what it learns. CellKeeper records one of three results,
and continues to step 6 or 7 in every case, so a failed check never
lengthens the time at a low charge:

- **Counted (sleep):** the Mac slept without restarting, CellKeeper kept
  running, and: it fell asleep on battery power at 15–20%; it slept for at
  least 5 h by the monotonic clock that counts sleep, with the wall clock
  agreeing within 10 minutes; its first fresh reading after waking was on
  battery power (a later reading on AC power is then the plug-in); and
  the charge at that reading was no higher, and at most 3 points lower.
  Power notifications carry no state and can be coalesced, so a first
  reading after waking already on AC power cannot show when the plug-in
  happened, and the result is "not confirmed".
- **By the owner's account (shutdown):** after a restart CellKeeper cannot
  know what happened. It asks the owner whether the Mac stayed shut down
  and unplugged until the time shown, and records the answer, with the
  boot time and the last reading before the shutdown.
- **Not confirmed:** anything else, including a clock moved during the
  rest.

If the Mac wakes on battery power before 5 h, with the charge above 15%,
CellKeeper asks once to rest again until the time first shown; it never
moves that time later.

These rules are inferences [I]. `pmset -g log`, which note 08 read
(O10), may show sleeps, wakes and changes of power during the rest; using
it as evidence is an open question (§8).

### 7.7 Temperature

Note 06 R23 aborts a calibration outside 10–40 °C, TI's window for a
reading (§2). On macOS 27 CellKeeper cannot read the battery's
temperature: IOPowerSources, the registry, `pmset` and `system_profiler`
no longer show it, and the remaining sources are private, privileged, or
both (note 01, summary item 5).

**Proposed:** where CellKeeper can read the temperature, R23 applies as
written, and if the reading disappears during a session, the session
ends. Where it cannot, as on this Mac, a session may start only after
the owner confirms a room at 10–35 °C, with the Mac out of a bag and off
soft surfaces; the menu shows "temperature unknown" throughout, and the
report says it was not checked. A room's temperature does not establish
the battery's; the battery's own protections apply either way (note 06).
The alternative was to offer no managed calibration where the
temperature cannot be read, only a written checklist the owner follows
alone. **Decided by the owner on 2026-10-21: the proposal above** (the
owner confirms a cool room), a departure from R23 where the temperature
cannot be read.

### 7.8 How often

User-initiated only, as R23 says; no schedule. Settings shows when the
last calibration finished, and suggests one only if the owner asks for
it: when the percentage misbehaves, or every few months for a battery that
rarely leaves a narrow window. TI's drift of 1% per 20 cycles (§2) and
macOS's own occasional full charges (§3) make monthly calibration, as
AlDente suggests, more than needed [I]. A scheduled calibration could come
later, with its own decision.

### 7.9 The report

At the end, or when the session ends early: the steps done, with their
times; the summary capacities and cycle count before and after; the
result of the rest check (§7.6), and any step recorded as short; and,
plainly, that the gauge decides what it relearns, that "Maximum
Capacity" can go up or down, and that the result cannot be checked on
macOS 27 (§3). It goes into the activity log and the Diagnostics report.

### 7.10 Safety

- **Restrictive-only (note 06 R8):** the only control output is macOS's
  Charge Limit, at 100% in steps 1, 2 and 7 and at CellKeeper's normal
  limit otherwise; CellKeeper never discharges anything.
- **Floors (R5, R23):** the target is 20%, above max(floor, 15%); no rest
  is requested at 15% or below, and the session ends there (§7.6).
- **Never fight macOS (R26):** no response to macOS holding the charge or
  running from the battery on AC; a step that cannot finish ends at its
  bound.
- **Unsupervised time:** none at 100% by design, except sleep during steps
  1, 2 or 7, a deferred or failed return, or CellKeeper killed or crashing
  in those steps (§7.2), all disclosed before the start.
- **Recovery (precondition 11):** shown before the start; every end
  returns to the normal policy; if CellKeeper cannot, System Settings ›
  Battery › Charging sets the limit, with the value CellKeeper shows as
  the owner's own, as today.
- **Time at 100%:** the charge, about 2 h of rest, up to 4 h waiting for
  the owner to unplug, and the final charge: the main wear cost besides
  the cycle itself (§3).
- **Departures from R23,** decided by the owner on 2026-10-21: the
  temperature rule (§7.7), and the two early actions accepted (§7.6).

### 7.11 What has to be built

From the code as it stands (2026-10-21):

- a pure session state machine and its store (versioned, every write read
  back, the ended mark), tested in the style of the full-charge features:
  injected clocks, telemetry and a fake Charge Limit system, and a
  relaunch by a second controller on the same storage;
- the policy's integration: a session-owned request for 100% in steps 1,
  2 and 7 (today's temporary full charge ends the moment the battery is
  full, which would end step 2 at once), and the normal policy otherwise;
- resuming, in §7.6's order: evidence first, the backend's recovery, the
  checks, then the owner's choice to continue; the confirmed return to the
  normal limit (§7.2); and the exclusion of §7.4, with the schedules gated
  before the controller applies them in its evaluation;
- the requests in the menu and new notification kinds, the rest check,
  and the owner's answer after a restart;
- the admission checks and their reasons, Settings' calibration section,
  the recovery shown before the start, and the report in the activity log
  and Diagnostics;
- the documentation: `architecture.md`, `safety.md` (R23 as decided), the
  README's feature table and the roadmap.

## 8. Open questions

1. Does this Mac's gauge update Qmax at all from the guided cycle, and does
   it have the fast update enabled? Not observable on macOS 27 (§3) [O].
2. Is the Mac's sleep current below the gauge's quit current, so that
   sleep is a rest? Until that is known, the request asks for a shutdown,
   and offers sleep as the second choice [O].
3. Does a charge with the limit at 100% end in a gauge charge
   termination? Apple says the Mac stops "within a few percentage points"
   of a limit [S5]; with no limit set it should charge fully [I, O].
4. Can `pmset -g log` show reliably that the Mac stayed unplugged and
   asleep or off during the rest (§7.6)? Its format is not documented [O].
5. *Decided by the owner on 2026-10-21:* the design is approved; the
   temperature rule as proposed (§7.7); the two early actions continue the
   session (§7.6).

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
