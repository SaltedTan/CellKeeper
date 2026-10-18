# Design: scheduled full charge (draft, revised)

Status: revised 2026-10-18 after GPT-6.1-Sol's review ("revise first"),
with the lead's decisions on each finding. Scope (owner, 2026-10-18): a
scheduled **temporary full charge** only. No scheduled limits, no scheduled
discharge (R20), no recurring schedules. Rules cited: research note 06 R20,
R22, R23, hazard H14; decisions D12, D16, D22, D24. "Lead decision" marks
the §9 recommendations, which the lead adopted; they are not owner
decisions.

## 1. User model

**What the user sets: a start and an end, not "ready by".** A charge-time
estimate cannot be made honestly. It depends on the adapter, temperature,
battery age, macOS slowing charging above about 80%, and Optimized Battery
Charging, and IOPowerSources' time-to-full is only given while charging. A
start time is what CellKeeper can honour.

- **Start**: date and time to the minute. It must be in the future when set
  and at most 7 days ahead (lead decision).
- **End**: 1–48 h after the start (the override bounds, R23); default start
  + 12 h. The end bounds the attempt and the window for a late start.

**One schedule, one-shot** (lead decision). Recurrence is not nearly free:
- floating local time, with DST and time-zone rules;
- `NSCalendarDayChanged`;
- a rule for missed occurrences;
- a persisted "last occurrence", so a backward clock change cannot fire
  one twice (H14).

A routine full charge also works against the limit (R23).

**Editing and cancelling.** The editor is a section in Settings › Charging
(lead decision): start and end date pickers, a Schedule button, and the
explanation. It is editable only while Manage charging is on. A new
schedule replaces the old one. Cancel Schedule is in Settings and in the
menu and is always enabled. The menu adds one line under "Charge to 100%
once":
- a "Schedule…" button when nothing is armed;
- the armed window;
- "waiting: <reason>" while it is due but cannot start;
- or an outcome sentence with OK.

A running scheduled charge uses the existing override line, labelled
"Scheduled".

## 2. Semantics

**The schedule starts the existing temporary full charge.** There is no new
override kind:
- `ChargeOverride.Kind.fullCharge`, with rows 8 and N3, completion,
  unplugging and expiry all unchanged.
- `ChargeOverride` gains a display-only `source` (`.user`, `.schedule`),
  which the policy never reads.
- It also gains a factory `scheduledFullCharge(at:uptime:remaining:)`: a
  monotonic deadline `remaining` seconds after the start, at most 48 h,
  with no 1-hour floor. It returns nil unless `remaining` is positive and
  finite.
- The schedule never turns management on, selects a backend, changes a
  setting, or starts a discharge.

**Eligibility, the schedule's own rules.** At the first evaluation with
`now` in `[start, end)` where:
1. the settings are valid and Manage charging is on;
2. there is a usable reading: battery present, not stale by
   `ChargingPolicy.staleness`, a percentage, a known power source;
3. that reading shows `externalPower`.

Otherwise it waits (`.settingsInvalid`, `.managementOff`,
`.noUsableReading`, `.onBattery`). Starting earlier would only waste it:
unplugging ends a full charge at once, and management off cancels one.
Unlike the menu's manual button (management on, limit < 100%, external
power), the schedule **may start when the limit is already 100%**. It then
changes nothing unless the limit is lowered before it ends. Everything
else is left to the unchanged policy:

| Situation at the start | Result |
|---|---|
| Already full | Starts; the policy completes it in the same evaluation; outcome "already full" |
| A full charge is running and still live (`input.uptime < expiresAtUptime`) | Kept, with deadline `max(existing.expiresAtUptime, candidate.expiresAtUptime)`, monotonic only. **Extended**: `source` becomes `.schedule`, outcome "extended". **Kept**: `source` unchanged, outcome "a full charge was already running". The displayed deadline is derived from the retained monotonic deadline (`now + (expiresAtUptime − uptime)`), even when it is beyond the schedule's end |
| A full charge whose monotonic deadline has passed | Treated as expired (logged), never kept because its wall-clock estimate looks later; the scheduled charge replaces it |
| A discharge session is running | Replaced (`forceDischarge → normal` relaxes; lead decision); logged as ended by the schedule |
| Rows 1, 4, 5, 7; N2; backend unavailable or faulted | Starts. The higher rows and the action table decide exactly as for a manual full charge (with macOS's limit on: "not in effect") |

**Native recovery is unchanged, so the invariant is qualified.** A
*successful* scheduled request (`nativeLimit(100)`) never lowers the limit.
A *failed* one keeps the existing recovery: the controller restores
`.normal`, which is the user's own limit, and that can be **lower** than
CellKeeper's configured limit (owner 80%, CellKeeper 95% → 80%). A faulted
backend is handled by the action table as today:
- current mode `.normal`: the 100% request is refused;
- current mode non-normal or unknown: `.normal` is requested actively.

Schedules get no exemption from either.

## 3. Time

Three things are kept apart:
1. **Activation window** `[start, end)`: wall clock, checked
   level-triggered against `PolicyInput.now` at every evaluation (R22).
2. **Override deadline**: monotonic, `input.uptime + (end − input.now)` at
   activation, at most 48 h. Like every override expiry, it is **processed
   only during an evaluation** (`ChargingPolicy.evaluate`). If the Mac
   sleeps across it, nothing happens until the first evaluation after wake;
   with macOS's Charge Limit, macOS keeps 100% until then. A forward clock
   change after activation does not move it (D12).
3. **Confirmed setting change**: what a read-back shows. A request may be
   rate-limited, refused or fail, and the return to the limit may be
   delayed in the same ways.

Wording therefore says that CellKeeper *requests* 100% and then *requests*
its limit again at its next check after the battery is full, you unplug, or
the charge expires, and that sleep can delay that request. No lateness bound
is claimed. Evaluations come from:
- the 60 s periodic timer, which App Nap can defer;
- the ordered command queue, which other commands and backend calls can
  occupy;
- wake and the post-wake re-read;
- power events;
- a new automatic trigger `EvaluationTrigger.clockChanged`, on
  `NSSystemClockDidChange` and `NSSystemTimeZoneDidChange` (the app first
  resets the cached system time zone).

No aligned timer is added.

**The pure check.** `FullChargeSchedule.check(_:input:)` returns
`.notYet`, `.start(remaining:)`, `.waiting(_)` or `.passed`. It reads time,
settings and the snapshot only from the `PolicyInput` the evaluation then
gives `ChargingPolicy.evaluate`.

In `performEvaluation`, the check runs after `observeBackendMode()`, so an
adoption that turns management off in the same evaluation is seen. On
`.start`, the schedule is removed from its store and the override installed
with no suspension point between the two. The same evaluation then runs the
policy, and it keeps its trigger.

**Not a wake alarm.** Waking the Mac needs root (`IOPMSchedulePowerEvent`,
`pmset schedule`), which CellKeeper never uses. There is no launch at login
(#38).

**Missed.** When the window passes before the charge could start:
- the schedule is removed, never replayed;
- the outcome reads "The scheduled window passed before the full charge
  could start.";
- it adds "Last checked: <wait reason>" only if a wait reason was observed
  in this run. Wait reasons are not persisted.

It is shown in the menu until dismissed and logged as an `.override` event.

| Clock or time-zone change | Effect |
|---|---|
| Forward into the window | Starts at the next evaluation |
| Forward past `end` | Window passed |
| Backward, unused schedule | Waits for `start` again |
| Backward after the start | No second start: the schedule was removed |
| During the run | Deadline unchanged |
| Time zone, DST | Absolute instants (lead decision): only the displayed local time changes. DST is resolved once, when the time is entered |

## 4. Persistence

**Its own store.** `FullChargeScheduleStoring` (Core, `Sendable`) is backed
by the same `KeyValueStorage` as `SettingsStore`.
- **Key and schema.** The key `fullChargeSchedule.v1` is the schema version.
  A later format uses a new key, which this version never reads or
  removes.
- **Fields.** The record is `{"startsAt": <s since 1970>, "endsAt": …}`.
  Both are required; a record missing either is unreadable. Unknown keys are
  ignored. There is no optional metadata (`createdAt` is dropped).
- **Load.** An unreadable record, or one whose window is not finite or not
  1–48 h, is removed with a notice. It never touches `ChargingSettings`, its
  recovery or Manage charging. A record whose window has passed is reported
  by the first check. The 7-day lead time is checked only when a schedule is
  set.

**The no-second-start contract** (narrowed). There is no second start:
- within a run;
- after a backward clock change;
- after a relaunch that follows a **persisted** removal.

UserDefaults persists asynchronously, so after a crash or power loss right
after a start, the schedule may start once more inside the user's own
window. That is a relaxation the user asked for; with the native backend it
is another 100% request inside the window the user authorised. Crash
durability is not claimed.

**One controlling instance.** The guarantees assume one CellKeeper instance
controls charging. Two instances could both load the armed schedule, but
overlapping instances already break native ownership more broadly. There is
no atomic claim.

**Not resumed.** A started charge is not persisted. Quitting ends it, as for
a manual one.

## 5. Safety

Rows 1–7 keep their precedence. There is no new row, and no latch,
debounce, floor or temperature rule changes; the schedule creates only the
override the user could start by hand.

- **Backends that switch charging themselves:** a full charge asks only for
  `.normal`. That relaxes, and is never rate-limited.
- **Native backend:** `nativeLimit(100)` is a restricting change
  (`isRestricting`). It uses the budget, is refused while faulted, and needs
  ownership (D16); its return is restricting too.
- **The qualified invariant:**
  - a successful scheduled target never lowers the limit;
  - a running full charge is never shortened;
  - failures keep the existing owner-limit recovery, which can be lower
    than the configured limit (§2).

## 6. Wording

The wording lives in Kit (`FullChargeScheduleWording`) and is tested.

| Backend | Explanation |
|---|---|
| macOS Charge Limit | "At the start, CellKeeper requests a macOS Charge Limit of 100%. After the battery is full, you unplug, or the charge expires (<end>), it requests its <limit>% limit again at its next check; while your Mac sleeps, that waits until it wakes. macOS may still hold charging, for battery health or when the battery is warm." Plus the hint (lead decision on Q10): "To charge overnight, schedule a start while your Mac is awake and wait until the menu shows macOS enforcing 100%. Returning to your limit can wait until your Mac wakes." |
| Simulated, Simulated helper | "Simulated: at the start, CellKeeper records a temporary full charge. Nothing on your Mac changes." While macOS's limit may be limiting: "macOS's Charge Limit stays in charge." |
| Read-only, unavailable | "<backend> changes nothing; CellKeeper only shows what it would do." |
| Real charging-mode backend (future) | "At the start, CellKeeper allows charging to 100%; it applies its limit again at its next check after the battery is full, you unplug, or the charge expires (<end>)." |
| Always | "Your Mac must be awake, with CellKeeper running, for the full charge to start; CellKeeper cannot wake your Mac or open itself after a restart. If the start passes while it cannot start, it starts at CellKeeper's next check before <end>; otherwise the menu says the window passed. Unplugging ends it." |

## 7. Tests

All deterministic: `TestClock` with a new `shiftWall(by:)` (moves the wall
clock only), `InMemoryStorage`, no real clocks.

- **Pure check:**
  - each result and each wait reason, including stale, no-battery and
    unknown-source readings and invalid settings;
  - start allowed at a 100% limit;
  - validation and the factory (no 1-hour floor, at most 48 h, nil for
    non-positive remaining);
  - policy parity for `.user` and `.schedule`.
- **Store:**
  - round trip;
  - partial records → unreadable and removed;
  - a record under `fullChargeSchedule.v2` is neither read nor removed;
  - settings recovery is independent.
- **Controller, scheduling:**
  - start at the first periodic evaluation in the window: store cleared,
    deadline at `end` in uptime, `fullChargeOverride` in that evaluation;
  - no second start within a run, after a backward shift, or after a
    relaunch that follows the persisted removal;
  - forward jump past `end`, and a relaunch after waiting: neither shows
    "Last checked";
  - waiting on battery or with management off, then starting;
  - an adoption in the same evaluation: no start;
  - already full.
- **Controller, running charges:** extending or keeping a running full
  charge on monotonic deadlines, with the wall clock jumped forward and
  backward; an expired one replaced; a discharge replaced.
- **Controller, deadlines:**
  - sleep across the deadline: nothing until the next evaluation, then
    expired and the limit requested;
  - native, a return write that is rate-limited (stays 100% until the
    retry) and one that fails (owner limit restored).
- **Controller, native recovery:**
  - a scheduled 100% request that fails, with the owner limit below the
    configured limit (→ owner limit) and above it;
  - faulted with current mode normal (refused), non-normal (`.normal`
    requested) and unknown (`.normal` requested).
- **Controller, other rules:**
  - temperature pause and safety floor still win;
  - helper with macOS's limit on: no restricting request;
  - a stored record that is invalid, or whose window has passed, at launch;
  - after shutdown, commands are inert;
  - `.clockChanged` is automatic.
- **Kit:** wording per backend, with no "ready" or "guarantee" claims.
- **App:** offscreen render-harness PNGs.

## 8. Decision-log rows (provisional D90–D95)

| # | Decision |
|---|---|
| D90 | One one-shot scheduled full charge, a start (≤ 7 days ahead) and an end 1–48 h later, as absolute instants. It starts the existing temporary full charge (rows 8, N3 unchanged; display-only `source`). It never changes settings, management or the backend, never discharges, and does not recur |
| D91 | The activation window `[start, end)` is checked level-triggered against `PolicyInput.now` (R22). It starts with valid settings, management on and a usable reading on external power, and may start at a 100% limit; otherwise it waits. Its monotonic deadline `end − now` at activation (≤ 48 h, no 1-hour floor) is processed only at evaluations, so sleep, refusals and failures can delay the return to the limit, and the wording says CellKeeper requests. A passed window is reported and never replayed |
| D92 | The schedule is removed from its store before the override is installed, with no suspension point. No second start within a run, after a backward clock change, or after a relaunch that follows a persisted removal; after a crash or power loss right after a start it may start once more inside the user's window. One controlling instance is assumed |
| D93 | Its own store, `fullChargeSchedule.v1`; the key is the schema version and both endpoints are required. An unreadable or invalid record is removed with a notice and never affects `ChargingSettings` or Manage charging. Management off keeps the schedule without starting it |
| D94 | No dedicated timer and no wake. A new automatic `clockChanged` trigger joins the existing triggers; no lateness bound is claimed. CellKeeper is not a wake alarm |
| D95 | At the start, a live full charge keeps the later monotonic deadline (never shortened; display derived from it); an expired one is replaced; a discharge is replaced. On the native backend the start is restricting, with no exemption, and failures keep the owner-limit recovery, which can be lower than the configured limit |

The design folds into `architecture.md`, `safety.md` and `roadmap.md` and
the diagnostics report in the implementation branch, and this file is then
removed.

## 9. Lead decisions (from the recommendations)

| # | Question | Decision |
|---|---|---|
| Q1 | Start + end, or "ready by"? | Start + end |
| Q2 | One-shot? | One-shot only |
| Q3 | How far ahead? | At most 7 days |
| Q4 | Discharge session running at the start? | Replaced |
| Q5 | Management turned off while armed? | Kept, not started while off |
| Q6 | Travel across time zones? | Absolute instants |
| Q7 | Where to edit? | Settings › Charging; the menu has status, Cancel and "Schedule…" |
| Q8 | How to report outcomes? | Menu line until dismissed, plus the activity log; notifications later |
| Q9 | Which backends? | Every backend, with honest simulated wording |
| Q10 | Overnight hint? | Wait until the menu shows macOS enforcing 100%; the return can wait until wake |
