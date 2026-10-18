# Design: scheduled full charge (draft)

Status: design for review, 2026-10-18. Nothing here is implemented. Scope
(owner, 2026-10-18): a scheduled **temporary full charge** only; no
scheduled limits, no scheduled discharge (R20), no recurring schedules.
Roadmap: milestone 2 "Use it for schedules ('100% before travel on
Friday') without root" and "Later: Scheduling of overrides and limits".
Rules cited: research note 06 R20, R22, R23, hazard H14; decisions D12,
D16, D22, D24.

## 1. User model

**What the user sets: a start and an end, not a "ready by" time.**
"Ready by" would need CellKeeper to predict how long a charge takes. That
depends on the adapter's wattage, temperature, battery age, how macOS slows
charging above about 80%, and Optimized Battery Charging. IOPowerSources
only gives a time-to-full while charging, and it is invalid for 30 s after
wake. A wrong estimate either misses the deadline or leaves the battery at
100% for longer than needed, and either way CellKeeper would be claiming
something it cannot deliver. A start time is what CellKeeper can actually
honour. The end bounds the attempt and doubles as the window for a late
start (§3). The user picks:

- **Start**: date and time, to the minute. It must be in the future when
  set, and at most 7 days ahead (owner question Q3).
- **End at the latest**: 1–48 h after the start, the existing override
  bounds (R23). It defaults to start + 12 h, the manual full charge's
  expiry.

**One-shot, and only one schedule.** Recurring schedules are not nearly
free. They need floating local times (DST gaps and overlaps, which
occurrence counts after a time-zone change), `NSCalendarDayChanged`, a rule
for missed occurrences, and a persisted "last occurrence fired" so a
backward clock change cannot fire one twice (H14). A routine full charge
also works against the limit, and macOS already does its own occasional
calibration charge (R23). A second schedule would need conflict rules the
travel case does not call for.

**Editing and cancelling.** The editor goes in Settings › Charging, in a new
section "Scheduled full charge" with two date pickers and a Schedule button
(Q7). It is editable only while Manage charging is on, the same rule as the
manual button. Setting a new schedule replaces the old one. "Cancel
Schedule" is in Settings and in the menu, and is always enabled.

**What the menu shows** (`FullChargeControl`, `MenuBarView.swift`), as one
extra line under "Charge to 100% once":

| Schedule state | Menu line |
|---|---|
| None | "Schedule…" (small button; opens Settings › Charging) |
| Armed | "Full charge scheduled: Fri 24 Oct 22:00 – Sat 10:00" · Cancel |
| Due but waiting | "Scheduled full charge waiting: connect power" / "…: Manage charging is off" / "…: no battery reading" · Cancel |
| Started | The existing override line (`fullChargeText`), labelled "Scheduled"; its Cancel cancels the running charge (the schedule has already been used) |
| Missed / already full / discarded | One sentence saying what happened (§3, §4) · OK (dismiss) |

## 2. Semantics

**The schedule starts the existing temporary full charge.** There is no new
override kind:
- `ChargeOverride.Kind.fullCharge`, with precedence rows 8 and N3, expiry,
  unplugging and completion all unchanged.
- The only additions to `ChargeOverride` are:
  - a display-only `source` (`.user` by default, or `.schedule`), which the
    policy never reads;
  - a factory `scheduledFullCharge(at:uptime:until end:)`. Its duration is
    `min(end − start, 48 h)` with no 1-hour floor, so a late start never
    runs past the end. It returns nil if `end ≤ start` or a value is not
    finite.
- The schedule never turns management on, selects a backend, changes a
  setting, or starts a discharge.

**When it starts.** At the first evaluation with `now` (wall clock) in
`[start, end)` where:
- Manage charging is on, **and**
- the snapshot is usable by the policy's own rules (battery present, not
  stale by `ChargingPolicy.staleness`, a known percentage) **and** shows
  `externalPower`.

These are the manual button's enabling conditions. They exist because
starting otherwise would throw the schedule away: unplugging ends a full
charge at once (`OverrideEnd.unplugged`), and the controller refuses a full
charge while management is off. While a condition is not met, the schedule
**waits** (`ScheduleWait`: `.managementOff`, `.onBattery`,
`.noUsableReading`). Everything else is left to the unchanged policy, as for
a manual full charge:

| Situation at start | Result |
|---|---|
| On battery; no usable reading; management off | Waits until the condition is met or `end`, then it is missed (§3) |
| Already 100% or fully charged | Starts, and the policy ends it `completed` in the same evaluation. The outcome says "already full" |
| A manual full charge is running | It is kept, and its expiry is moved to `end` if that is later; a running charge is never shortened. The schedule is used up |
| A discharge session is running | Replaced by the full charge: `forceDischarge → normal` is a relaxing change. Logged as ended by the schedule (Q4) |
| Row 1: release required (pending backend switch, unfinished restore, unverified state) | Starts. Row 1 keeps `.normal` (with native: the user's own limit) until the release completes; the expiry keeps counting |
| Row 4: macOS's Charge Limit on or unreadable (backends that switch charging themselves) | Starts. Rows 4 and 8 both want `.normal`, so nothing changes. It runs if the user turns macOS's limit off before `end`, and the menu says "not in effect" until then |
| Row 5 safety floor; row 7 temperature pause | Starts. The higher rows still win (note `fullChargeSuppressed`); the schedule cannot bypass the floor or temperature (R22) |
| Limit already 100% | Starts. It changes nothing unless the limit is lowered before it ends |
| Backend unavailable, read-only or faulted | Starts. The action is refused exactly as for a manual full charge, and the menu says "not in effect" |
| Native, limit not a step (N2) | Starts. N2 wins (`.normal`) until the limit is fixed or the charge expires |
| Native (N3) | Wants `nativeLimit(100)`. Needs ownership of the user's limit first, and is rate-limited and refused while faulted (§5) |

**Once started, it is an ordinary temporary full charge.** It ends at
100%/fully charged, on unplug, at `end`, when cancelled, when management is
turned off, or on adoption of an outside Charge Limit change. Plugging in
again does not restart it (R23).

## 3. Time

**Wall-clock window, monotonic expiry** (R22, D12):
- Before the start, the schedule is a wall-clock interval, checked
  level-triggered at every evaluation against `PolicyInput.now`.
- At the start, its expiry becomes monotonic:
  `expiresAtUptime = input.uptime + (end − input.now)`, at most 48 h.
- Clock changes after the start cannot move that expiry. The controller
  reads `uptime` before the backend calls and `now` after them, so the
  charge can end up to that read time **early**, never late.

**The policy stays pure.** A new pure function
`FullChargeSchedule.check(_:input:) -> ScheduleCheck` (`.notYet`,
`.start(remaining:)`, `.waiting(ScheduleWait)`, `.missed`) reads time,
settings and the snapshot only from the same `PolicyInput` the evaluation
then passes to `ChargingPolicy.evaluate`. `ChargingPolicy` and its tables
do not change.

In `ChargeController.performEvaluation`:
1. Telemetry, `capabilities()` and `observeBackendMode()` run as today.
   An adoption that turns management off therefore comes first, and the
   check sees it.
2. Build the input, then run the check.
3. On `.start`, the schedule is removed from its store and the override is
   set, with no suspension point between the two. Then the policy runs on
   that input with the override.

This is a single evaluation, and it keeps its trigger, so automatic
evaluations still wait out a failed restore (`restoreRetryNotBefore`).

**How the app gets an evaluation at the start time: no new timer.** The
existing triggers bound the lateness while the Mac is awake:
- the 60 s periodic evaluation (macOS may defer the timers of an idle app in
  App Nap; that delays every evaluation, not only this one);
- wake and the re-read 35 s after it;
- power events (plugging in starts a waiting schedule at once);
- a new automatic trigger `EvaluationTrigger.clockChanged`, sent on
  `NSSystemClockDidChange` and `NSSystemTimeZoneDidChange` (the app also
  resets the cached system time zone).

`NSCalendarDayChanged` is not needed: it matters only for recurring
schedules. A timer aligned to the start would save at most one periodic
interval, and would have to be re-armed on every clock, time-zone and wake
event.

**Not a wake alarm.** CellKeeper cannot wake the Mac. That needs
`IOPMSchedulePowerEvent` or `pmset schedule` (root, and a pmset change,
which CellKeeper never makes). If the Mac is asleep or CellKeeper is not
running at the start, the charge starts at the first evaluation after that,
if it is still before `end`. Two consequences:
- With macOS's Charge Limit, macOS keeps enforcing the limit in effect while
  the Mac sleeps. A charge meant for overnight must therefore **start while
  the Mac is awake** (for example 22:00). macOS then enforces 100% during
  sleep, though it may still hold charging for battery health.
- CellKeeper has no launch at login yet (#38), so after a restart the user
  must open it.

**Missed means dropped, never replayed** (R22, H14). If no evaluation could
start the schedule before `end`, it is removed. The outcome then says
either:
- "was missed: CellKeeper was not running or your Mac was asleep", when no
  evaluation fell inside the window; or
- "was skipped: <last wait reason>" (the Mac was on battery, Manage
  charging was off, no battery reading).

The outcome is shown in the menu until dismissed and is logged as an
`.override` event. A system notification can be added with the planned
Notifications feature.

**Clock and time-zone changes:**

| Change | Effect |
|---|---|
| Forward into the window | Starts at the next evaluation (prompt via `clockChanged`) |
| Forward past `end` | Missed, reported |
| Backward before `start`, schedule unused | Waits for the wall clock to reach `start` again |
| Backward after the start | No second start: the schedule was removed when it started |
| Any change while it runs | Its expiry is monotonic and does not move. The displayed `expiresAt` is an estimate, as for manual overrides |
| Time-zone change, DST | Start and end are **absolute instants**, so the start does not move in real time and only the displayed local time changes (Q6). DST is resolved once, when the time is entered: the date picker turns local time into an instant, and the confirmation shows the resolved time. The 48 h bound is real time |

## 4. Persistence

**A separate store, not `ChargingSettings`.** `FullChargeScheduleStore` is a
`Sendable` protocol in Core. Its implementation uses the same
`KeyValueStorage` as `SettingsStore`, under its own key
`fullChargeSchedule.v1`, as versioned JSON (`version`, `startsAt`, `endsAt`,
`createdAt`). Decoding tolerates missing keys. The controller is given the
store, as it is given `adoptionMarkerStore`, so it can remove the schedule
before it starts the charge.

**At launch**, and whenever a stored schedule is loaded:
- **Unreadable or invalid** (not finite, end not 1–48 h after start): the
  schedule is removed, with the notice "A saved full-charge schedule could
  not be read and was removed".
- **`now ≥ end`**: missed, removed, and reported as above.
- **Valid**: kept, and checked by the launch evaluation.

The 7-day horizon is checked only when a schedule is set, so a backward
clock change cannot invalidate a stored one. None of this touches
`ChargingSettings`, its recovery path, or Manage charging: a bad schedule
can never be what turns management off.

**Durability.** UserDefaults persists asynchronously. A power loss right
after a start could bring the schedule back, and the next launch could
then start it once more inside the user's own window. That repeats a
relaxation the user asked for and costs nothing they own. An fsync'd file
(D22) is warranted only where losing the write loses the user's own limit.

**Not resumed after relaunch.** A started charge is not persisted. Quitting
restores `.normal` and ends it, as for a manual charge. Monotonic time does
not survive the process, and resuming on wall-clock time would break D12.

## 5. Safety

Rows 1–7 keep their precedence. The schedule adds no row and changes no
latch, debounce, floor or temperature rule. It only ever creates the same
override the user could start by hand.

- **Backends that switch charging themselves:** a full charge asks only for
  `.normal` (row 8). That is a relaxation: never rate-limited, never
  blocked by a fault. Its end hands back to the ordinary policy, whose
  restrictions are debounced and rate-limited exactly as after a manual
  full charge.
- **Native backend: called out explicitly.** `nativeLimit(100)` is a
  **restricting** change in CellKeeper's terms (`isRestricting`:
  `restrictionLevel` 1 versus `.normal`, or one CellKeeper-set limit
  replacing another). It therefore uses the restricting budget (60 s / 20
  per hour), is refused while faulted, and needs the user's own limit read
  and recorded first (D16). Its end (100 → limit) is restricting too, so a
  refused end leaves 100% in place until a later evaluation. The schedule
  gets **no exemption**: a refused start is retried by the next evaluation,
  as a manual one is today. In charging terms it is never stricter than
  what it replaces, because 100% is at or above every step.
- **Cases where a schedule could be more restrictive than no schedule:**
  - Shortening a running manual full charge: excluded, since a running
    charge is only ever extended.
  - Its end returning to a hold: this is identical to a manual charge's end,
    and comes no later than the user chose.

  No other case was found.
- **Fails toward the current behaviour.** A schedule that cannot start (a
  condition unmet, data unreadable, the window passed) leaves the policy
  exactly as it would be without it.

## 6. Honest wording

The wording lives in Kit (`FullChargeScheduleWording`) and is tested.
Nothing promises "ready by" or "guaranteed 100%".

| Backend | Editor and armed-line text |
|---|---|
| Simulated, Simulated helper | "Simulated: at the start, CellKeeper records a full charge. Nothing on your Mac changes." |
| Read-only | "CellKeeper will show what it would do; it changes nothing." |
| macOS Charge Limit | "At the start, CellKeeper sets macOS's Charge Limit to 100%, and sets it back to <limit>% when the battery is full, when you unplug, or at <end> at the latest. macOS may still hold charging, for battery health or when the battery is warm." |
| macOS limit on (row 4) | Adds: "While macOS's Charge Limit is on, it stays in charge and the full charge has no effect." |
| Always | "Your Mac must be awake, with CellKeeper running, at the start. CellKeeper cannot wake your Mac or open itself after a restart. If it misses the start, the full charge starts when CellKeeper next runs before <end>; otherwise it is skipped and the menu says so. Unplugging ends it." |

## 7. Tests

All tests are deterministic and use injected time only: `TestClock`, plus a
`shiftWall(by:)` that moves the wall clock without moving uptime;
`InMemoryStorage`; and an in-memory schedule store. No real clocks, sleeps
or timers.

- **Pure check (`FullChargeScheduleTests`):** before start → `.notYet`;
  `[start, end)` → `.start(remaining: end − now)`; at `end` → `.missed`;
  each wait reason (management off; on battery; nil, stale, no-battery and
  unknown-source snapshots); validation (order, 1–48 h, not finite, past,
  beyond 7 days); the factory (expiry `≤ end`, no 1-hour floor, at most
  48 h, nil for `end ≤ now`). **Policy parity:** identical decisions for
  `source` `.user` and `.schedule` across rows 1–13 and N1–N4.
- **Store:** round trip; missing keys; garbage → nil plus a recovery
  reason; its key is separate from `chargingSettings.v1`, and a corrupt
  schedule leaves `SettingsStore.loadChargingSettings()` unchanged.
- **Controller (`FullChargeScheduleControllerTests`):**
  - The first periodic evaluation at or after the start starts it: expiry
    at `end` in uptime, store cleared, state `fullChargeOverride` in that
    evaluation.
  - It never starts twice, neither after a backward wall shift nor after a
    relaunch (a new controller on the same storage). A forward shift past
    `end` → missed, no override. A wall shift during the run leaves the
    expiry unchanged.
  - Waits: on battery, then plugged in inside the window → starts; never
    plugged in → skipped with `.onBattery`. Management off, then on →
    starts; an adoption in the same evaluation → no start.
  - Already full → starts and completes in one evaluation. A running manual
    charge is extended, never shortened; a running discharge is replaced and
    logged. Temperature pause and the safety floor still win. Helper backend
    with macOS's limit on → no restricting request.
  - Native: sets 100 through the fake shortcut; within 60 s of a restricting
    change → `rateLimited`, then started at the next periodic evaluation;
    faulted → refused, override kept; the end sets the limit again.
  - Launch with a past or invalid stored schedule → outcome plus removal,
    settings untouched. After `shutdown`, set and cancel are no-ops and the
    store is untouched. `.clockChanged` is automatic.
- **Kit:** wording per backend availability: the simulated wording says
  nothing changes, and no "ready" or "guarantee" claim appears.
- **App:** offscreen render harness PNGs of the Settings section and of the
  menu line in each state.

## 8. Decision-log rows (provisional) and doc changes

| # | Decision | Rationale |
|---|---|---|
| D90 | One one-shot scheduled full charge: a start (future, ≤ 7 days ahead) and an end (1–48 h later), stored as absolute instants. It starts the existing temporary full charge (rows 8, N3 unchanged; display-only `source`). It never changes settings, management or the backend, never discharges, and does not recur | The travel case needs one charge. "Ready by" needs a charge-time estimate CellKeeper cannot make honestly. Recurrence needs floating local time, DST rules and more double-fire protection, and routine full charges work against the limit |
| D91 | Level-triggered against `PolicyInput.now` over `[start, end)` (R22). It starts at the first evaluation with management on and a usable reading showing external power, otherwise it waits. The expiry is monotonic, `end − now` at the start (≤ 48 h, no 1-hour floor), so it never runs past `end`. If nothing can start it before `end`, it is reported missed and never replayed | Starting on battery or with management off would only throw it away. A wall-clock change can delay a start but never extend a running charge (D12) |
| D92 | The schedule is removed from its store before the override is set, with no suspension point between them. A running scheduled charge ends on quit like a manual one and is not resumed | A relaunch, crash or backward clock change cannot start it twice (H14). Monotonic time does not survive a relaunch, and resuming on wall time would break D12 |
| D93 | Its own store (`fullChargeSchedule.v1`, versioned JSON). An unreadable, invalid or past schedule is removed with a notice and never affects `ChargingSettings` or Manage charging. Turning management off keeps the schedule, but it does not start while management is off. UserDefaults durability is accepted | A stale schedule must not turn management off. Losing a removal can only repeat a relaxation inside the user's window, unlike D22 |
| D94 | No dedicated timer and no wake. The triggers are the periodic evaluation, wake and post-wake re-read, power events, and a new automatic `clockChanged` trigger (system clock and time-zone change). CellKeeper is not a wake alarm | Lateness while awake is one periodic interval. Waking needs root or a pmset change, which CellKeeper never makes |
| D95 | At the start, a running full charge is kept or extended to `end` (never shortened), and a discharge session is replaced. On the native backend the start is a restricting change (budget, fault, ownership), with no exemption | A schedule must never make charging stricter than without it. `forceDischarge → normal` relaxes. Exempting `nativeLimit(100)` would weaken the rate limit for an unattended write |

Doc changes:
- **architecture.md:**
  - Overrides: add a "Scheduled full charge" paragraph.
  - Data flow: new triggers.
  - Requirement table: the Scheduler row becomes implemented.
  - Persistence: the new key.
  - User interface: the schedule section and menu line.
  - Decision log.
- **safety.md:**
  - A safeguards row: the window, monotonic expiry, no double start, cannot
    bypass the floor or temperature, not a wake alarm.
  - Validation ranges: schedule start ≤ 7 days ahead, window 1–48 h.
  - Note that the overrides row covers scheduled starts.
- **roadmap.md:** the milestone 2 schedules bullet becomes done (one-shot
  full charge), and the Later item narrows to scheduled limits and
  recurrence.
- **DiagnosticsReport:** a schedule line.

## 9. Open questions for the owner (with recommendations)

1. **Start + end, or "ready by"?** Recommend start + end (§1).
2. **One-shot only?** Recommend yes; reconsider recurrence only with real
   demand.
3. **How far ahead?** Recommend at most 7 days ("this Friday"). It keeps a
   forgotten schedule unlikely, and the menu always shows it.
4. **A discharge session running at the start?** Recommend replacing it (a
   relaxation the user scheduled; logged). The alternative is skipping the
   schedule.
5. **Management turned off while armed?** Recommend keeping it: it does not
   start while management is off, and is reported skipped if still off at
   `end`. The alternative is cancelling it, as management-off cancels a
   running override.
6. **Travel across time zones?** Recommend absolute instants: it fires at the
   same real moment and the menu shows the new local time. The alternative
   is floating local time ("05:00 wherever I am").
7. **Where to edit?** Recommend Settings › Charging, with the menu showing
   status, Cancel and "Schedule…". This keeps the 340 pt menu small (see
   #4).
8. **How to report started, missed or already full?** Recommend a menu line
   until dismissed, plus the activity log; a system notification once the
   Notifications feature lands.
9. **Native-only?** Recommend every backend, as with "Charge to 100% once",
   with honest simulated wording.
10. **Hint for overnight charging with macOS's Charge Limit?** Recommend one
    line in the editor: "To charge overnight, start it before you close the
    lid: macOS applies the 100% limit while your Mac sleeps."
