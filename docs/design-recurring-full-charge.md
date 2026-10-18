# Design: weekly full charge (recurring scheduled full charge)

Status: Phase 1 design for review. Decision rows D100–D106 are provisional.
Folded into `architecture.md` ("Scheduled full charge") and deleted when
implemented.

## 1. Scope

- **One weekly schedule** of the existing temporary full charge: a set of
  weekdays, a local start time (hour and minute), and a duration of 1–48
  whole hours (default 12, the full charge's default). Example: "Fridays at
  07:00 for 12 hours".
- It **coexists** with the one-shot schedule (`FullChargeSchedule`), which is
  unchanged. Both can be set; each has its own store, status fields and
  outcome.
- It **starts the existing temporary full charge** through the same path as
  the one-shot (`ChargeOverride.scheduledFullCharge`, source `.schedule`,
  display only), so rows 8 and N3, completion, unplugging, expiry, D82 and
  D83 are unchanged. It never changes settings, Manage charging or the
  backend, and never discharges.
- **Out of scope:** scheduled limits (changing the limit on a schedule),
  other recurrences (every N days, monthly), more than one weekly schedule,
  "skip the next one", waking the Mac or opening at login, a new
  notification kind, a Shortcuts action. On macOS 26+ a Shortcuts time-of-day
  automation running Start CellKeeper Full Charge remains the documented
  alternative (roadmap).

Name in the UI and log: **"Weekly full charge"**. A full charge it starts is
named "Scheduled full charge" while it runs, as for the one-shot (the menu,
the log and override-ended notifications already say that for source
`.schedule`).

## 2. Time semantics (floating local time)

Everything is pure and computed with an injected `TimeZone` and `now`; the
calendar is always Gregorian (`Calendar(identifier: .gregorian)`) with that
time zone, whatever the user's calendar is. Weekdays are Gregorian weekday
numbers (1 = Sunday … 7 = Saturday). The UI orders and names them by the
user's locale only.

- **Occurrence.** For a local day `D` (year, month, day, a floating date with
  no zone) whose weekday is in the set, the occurrence is the window
  `[S, E)`: `S` is `D` at the start time in the time zone **current at the
  check**, and `E = S + duration` in elapsed seconds. The occurrence's
  identity is `D`. At most one occurrence per local day.
- **DST gap** (the start time does not exist on `D`, e.g. 02:30 on
  2026-03-08 in New York): the time is read with the UTC offset in effect
  before the gap, so it starts later by the length of the gap (02:30 →
  03:30 EDT; Lord Howe's 30-minute gap: 02:10 → 02:40). This is RFC 5545's
  rule (§3.3.5).
- **DST overlap** (the start time occurs twice, e.g. 01:30 on 2026-11-01 in
  New York): the first one (01:30 EDT). Also RFC 5545.
- **Window across a DST change:** the duration is elapsed time, as for the
  one-shot. Saturday 20:00 + 12 h in New York ends Sunday 2026-11-01 07:00
  EST, not 08:00. The UI shows the end's actual clock time.
- **How `S` is computed.** Explicitly from `TimeZone.secondsFromGMT(for:)`:
  the candidate instants `local − offset` for the offsets a day either side;
  the valid ones (whose own offset matches) → the earliest; none (a gap) →
  `local − offset before the gap`. Not through `Calendar`'s matching
  policies: `Calendar.nextDate(after:matching:matchingPolicy:
  .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, …)`
  skipped Lord Howe's 02:10 on 2026-10-04 to the next day (observed,
  macOS 27.0), and `date(from:)` does not document what it does in a gap or
  an overlap (it gave the RFC 5545 answers in the same probe).
- **Time zone changes.** Occurrences are recomputed in the current zone at
  every check ("Friday 07:00 wherever the Mac is"). A zone change is already
  an evaluation trigger (`clockChanged`, D81). The controller gets the zone
  from an injected provider, read together with `now` after the backend's
  reads. The app's provider calls `NSTimeZone.resetSystemTimeZone()` and
  then takes `TimeZone.current`, a fixed value, at every evaluation.
  Foundation documents the system zone as cached until that reset
  (`NSTimeZone.h`, `systemTimeZone`), and does not document resetting it
  itself when `NSSystemTimeZoneDidChange` is posted. A probe that changed
  only its own `TZ` variable found `TimeZone.current`,
  `TimeZone.autoupdatingCurrent`, `NSTimeZone.system` and `NSTimeZone.local`
  all unchanged until the reset, and all updated after it; the reset posted
  no `NSSystemTimeZoneDidChange` (macOS 27.0). Resetting at every evaluation
  therefore does not depend on the notification arriving (a change while
  asleep, a missed post), and cannot loop.
- **Which occurrence counts.** At each check, only **P**, the latest
  occurrence whose start is at or before `now` (in the current zone), can
  start or pass. Earlier ones are superseded: with equal durations, P's
  window ends last, so starting P never gives less than starting an earlier
  one.
- **Overlapping windows** (a duration longer than the gap to the next
  selected day, e.g. every day for 48 h, or a 24 h window across a 23 h DST
  day): allowed. The later occurrence starts on schedule; a full charge
  still live from the earlier one keeps the later monotonic deadline (D82),
  so it is extended. A full charge ends at 100% or when macOS reports
  fully charged anyway.

## 3. Never twice, never replayed

**The record.** The schedule persists `handled`: the local day of the latest
occurrence that started, passed, or began before the schedule was saved,
with its start instant, the UTC offset at that start, and a result
(`started`, `passed`, `beforeSave`). An occurrence is **eligible only if its
local day is after `handled.day`**. Comparison is by local day only; the
instant and offset are for display and diagnostics. No time zone identifier
is stored or reported.

**The check** (`WeeklyFullChargeSchedule.check(_:input:timeZone:)`, pure):

1. P not eligible (its day ≤ `handled.day`), or none: `.notYet(next)`.
2. P eligible: run the one-shot's own `FullChargeSchedule.check` on P's
   window, so the start conditions are identical (valid settings, Manage
   charging on, a usable reading on external power; D78):
   `.start(P, remaining)`, `.waiting(P, wait)`, or `.passed(P)`.
3. `next` is the first occurrence with a day after `handled.day` (and after P
   once P is handled) and a start after `now`, found by stepping at most
   eight days from `max(today − 1, handled.day + 1)`.

**In the controller** (`applySchedule`'s start/extend/keep code is shared by
both schedules): on `.start` and `.passed`, `handled := P` is saved to the
store **before** the override is installed or the outcome set, with no
suspension point between them; the started full charge's duration is the
time left to P's end (no one-hour minimum, at most 48 h). The one-shot is
checked first, then the weekly schedule, in the same evaluation; if both
start, the second meets a live full charge and keeps the later deadline.

**What this guarantees** (one controlling instance assumed, as D79):

- No occurrence starts twice for the same local day: not within a run, not
  after a backward clock change of any size, not after a relaunch, not
  after a time-zone change (London → New York on the same Friday: Friday is
  handled; Tokyo → Honolulu repeats Friday: handled).
- A missed occurrence is never replayed: once P's window has passed, it is
  recorded as passed and reported (only P, the latest; earlier missed ones
  are not listed).
- **Launch or wake inside an unhandled occurrence's window** starts it, like
  the one-shot within its window; one already started is not resumed (a
  started charge is not persisted; quitting ends it, D79).
- **Limits, stated:** `UserDefaults` persists asynchronously, so after a
  crash or power loss right after a start, the same occurrence may start
  once more at the next launch inside its window (a relaxation the user
  scheduled; with macOS's Charge Limit, another 100% request in that
  window). A clock set far ahead and back again makes CellKeeper skip the
  days in between (the "Next" line shows the date); removing the schedule
  and setting it again counts from then.

**Saving** (new or edited) counts from the save: `handled := the later of the
existing record and the new pattern's latest occurrence that starts at or
before now` (result `beforeSave`). So a save never makes a day eligible
again, and an occurrence whose start passed before the save does not start
(as the one-shot needs a start in the future); "Charge to 100% once" covers
"now". A full charge already running is not changed by an edit. **Removing**
deletes the pattern and the record.

## 4. Interactions

- **One-shot schedule:** independent; see the order above. The menu's
  "Schedule…" button stays tied to the one-shot.
- **Running override:** D82 unchanged (a live full charge keeps the later
  monotonic deadline; an expired one is replaced; a discharge is replaced).
- **Manage charging off:** as D80 for the one-shot: the schedule is kept, a
  due occurrence waits (`managementOff`) and, if its window passes, is
  recorded as passed with "Last checked: Manage charging was off". Editing
  needs management on; Remove never does.
- **Backend switches, faults, Read-only, unavailable, simulated:** as the
  one-shot (it starts; the policy rows and action table decide; the
  explanation says what it changes per backend).
- **Notifications:** no new kind. A full charge it started that ends by
  itself is the existing override-ended notification ("Scheduled full
  charge"). A passed occurrence notifies nothing (as the one-shot).
- **Shortcuts:** no new action, and Get CellKeeper Status does not report
  schedules (D96 keeps schedules in the UI only).

## 5. Store and versioning

`WeeklyFullChargeStore` (Core) under its own key **`weeklyFullCharge.v1`**,
apart from `ChargingSettings` and `fullChargeSchedule.v1`; the key is the
schema version. JSON:

```json
{"weekdays": [6], "hour": 7, "minute": 0, "durationHours": 12,
 "handled": {"year": 2026, "month": 10, "day": 16,
             "startsAt": 1792130400, "utcOffset": 3600,
             "result": "started"}}
```

Load: a value that is not JSON data, unreadable, or invalid (weekdays empty
or outside 1–7, hour outside 0–23, minute outside 0–59, duration outside
1–48, `handled` missing, not a real Gregorian date, a non-finite instant, an
offset beyond ±18 h, an unknown result) is **removed with a notice** (outcome `.discarded`), never
affecting settings or Manage charging; only no value counts as no schedule.
Unknown keys are ignored. Loaded at the first command, like the one-shot.

**Disable without deleting** is not offered (owner question 2). If it were:
an `isEnabled` flag; off = nothing waits, passes or is reported, the menu
shows nothing; turning it on counts from then exactly like a save.

## 6. UI

**Settings › Charging**, a new section "Weekly full charge" after
"Scheduled full charge":

- Seven weekday toggle buttons (locale order, short names), a "Start" time
  picker (hour and minute), a "Duration" stepper (1–48 hours), "Save Weekly
  Full Charge" (enabled with at least one day, Manage charging on, and a
  change from what is saved) and "Remove" (when saved; always enabled). The
  editor starts from the saved schedule, else from no day, 07:00 and 12
  hours.
- Saved: "Every Friday at 07:00, for 12 hours" ("Every day" for all seven);
  "Next: Fri 23 Oct, 07:00 – 19:00" (`FullChargeScheduleWording.window`,
  which adds the zone in a repeated hour or when both ends read the same);
  when DST moves the start: "02:30 does not occur on Sun 8 Mar (the clocks
  go forward), so it starts at 03:30."; "Last: Fri 16 Oct, 07:00, started" or
  "…, passed before it could start" (not shown for `beforeSave`).
- Footer: times follow the Mac's current time zone; the duration is elapsed
  time; the one-shot's start conditions (awake, CellKeeper running, cannot
  wake the Mac or open itself; starts at the next check before the end;
  unplugging ends it); a day's full charge never starts twice and one that
  passed is not made up. The backend explanation
  (`FullChargeScheduleWording.explanation`, generalised to "the end of the
  window") is shared with the one-shot section, not repeated.

**Menu** (while a weekly schedule is saved), under the one-shot's lines:

- "Weekly full charge: next Fri 23 Oct, 07:00 – 19:00", no button.
- Due and waiting (orange): "Weekly full charge is due but cannot start yet:
  the Mac is on battery; connect power. It can still start until Fri 23 Oct,
  19:00." (the one-shot's wait texts).
- Outcome with OK, **only the latest**, in memory (not persisted, as the
  one-shot): "The weekly full charge of Fri 23 Oct, 07:00 passed before it
  could start. Last checked: the Mac was on battery.", already full, kept a
  running one, a saved weekly schedule was removed. Started and extended
  show no outcome line; the running line says it
  (`TemporaryFullChargeWording`, unchanged).

Plain words throughout (D89); CellKeeper *requests* 100%; nothing promises
a charge ready by a time or a return to the limit at a time.

**Activity log** (override events): saved, changed, removed, loaded,
discarded, due but waiting (on change of reason), started / extended / kept
/ already full, passed (with "Last checked" only if this run saw it wait).
When the next occurrence moves for any other reason (zone or clock
change), one line gives the new next occurrence, without guessing why.

## 7. Diagnostics

Through PR #88's section model, in the "Decision" section after the
one-shot's rows, only when a weekly schedule is saved:

- "Weekly full charge": "every Fri at 07:00 for 12 hours (weekdays 6)"
- "Weekly next": "2026-10-23T07:00:00+01:00 to 2026-10-23T19:00:00+01:00",
  plus "; due, waiting: …"
- "Weekly handled": "2026-10-16, started at 2026-10-16T07:00:00+01:00
  (started)"
- "Weekly outcome": as the one-shot's `describe(outcome)`.

**No time zone identifier** (lead's decision): the report promises nothing
that identifies a person or place, and a zone name is a location. The
occurrence times are written in ISO 8601 with their UTC offset instead,
which still shows DST and travel shifts. That needs a new
`DiagnosticsValue` part, a moment with an offset (the report writes it as
above; Settings › Diagnostics formats it like any other time), since
`.time` writes UTC. Existing goldens stay byte-identical (no weekly schedule
in their fixtures); new fixtures pin the new rows, deliberately.

## 8. Testing

Pure Core tests (Swift Testing), injected `TimeZone`, `TestClock`, no wall
clock:

- **Occurrence instants**, asserted against hand-computed UTC instants (not
  against `date(from:)`): New York 2026-03-08 02:30 → 07:30Z; 2026-11-01
  01:30 → 05:30Z (first); London 2026-03-29 01:30 → 01:30Z; 2026-10-25
  01:30 → 00:30Z (first); Lord Howe 2026-10-04 02:10 → 02:40 +11; window
  Sat 2026-10-31 20:00 NY + 12 h → 12:00Z; weekdays across week, month and
  year ends and 2028-02-29.
- **Check:** each case of §3 for single, several and all weekdays.
- **Never twice:** clock back 1 h / 1 day / 3 weeks after a start; relaunch
  (new controller, same storage) inside a started window (no start) and
  inside an unstarted one (starts); London → New York on the same Friday;
  Tokyo → Honolulu (repeated Friday); eastward travel (next day eligible).
- **Missed:** asleep across a window (one passed outcome); asleep for nine
  days with a daily schedule (one outcome, the latest); never replayed after
  a backward clock change.
- **Forward jump and back:** days skipped, "next" after the record.
- **Overlap:** daily 48 h extends a live full charge (outcome extended);
  completes and starts again.
- **Saving:** before today's start (starts today), inside the window (not
  today; next week), editing after a start (not again today), remove and
  set again (counts from then).
- **One-shot and weekly in one evaluation:** one override, the later
  deadline, two outcomes.
- **Store:** round trip; every invalid field, wrong type, not JSON → removed
  with notice, settings and the one-shot's key untouched; key pinned.
- **Management off:** waits, passes with `managementOff`; on within the
  window starts.
- **Kit wording** (summary, next, DST note, zone in repeated hour, outcomes)
  and diagnostics goldens.
- Each test that asserts "no start" also asserts the evaluation ran in the
  window with every start condition met, so it cannot pass vacuously.

## 9. Provisional decision rows

| # | Decision |
|---|---|
| D100 | One weekly full charge (owner approval 2026-10-19; shape: lead): weekdays, local start time, 1–48 whole hours; coexists with the one-shot; starts the existing temporary full charge (source `.schedule`); no scheduled limits, no new notification kind or Shortcuts action, no wake |
| D101 | Floating local time in the zone current at each check, Gregorian weekdays; DST gap → offset before the gap, overlap → first (RFC 5545); duration is elapsed time; computed from `TimeZone` offsets, not `Calendar` matching policies (observed wrong for a 30-minute gap); the app resets the cached system zone at every evaluation |
| D102 | Only the latest occurrence that has started by the clock can start or pass; earlier ones are superseded; its window goes through the one-shot's check and D82's start rules; overlapping windows allowed |
| D103 | A persisted record of the latest handled local day, saved before the override is installed; an occurrence is eligible only after it; saving counts from the save and never lowers it; removing deletes it; crash limit and clock-forward-and-back skip stated |
| D104 | Own store `weeklyFullCharge.v1`; invalid or unreadable → removed with a notice, never affects settings; no pause flag |
| D105 | UI: Settings section with days, time, duration, Save/Remove, Next, Last, DST note; menu "next"/waiting line and the latest outcome only, in memory |
| D106 | Diagnostics rows through the section model: the pattern, the next occurrence and the record, times in ISO 8601 with their UTC offset; no time zone identifier (lead's decision) |

## 10. Owner questions (answered by the lead, 2026-10-19)

1. **Scope:** weekly only, one schedule, whole-hour durations, alongside the
   one-shot. *Adopted.*
2. **Pause without deleting:** not offered; Remove only. "Skip the next one"
   (advancing the record) is the better later addition. *Adopted.*
3. **Saving inside today's window** does not start today's occurrence; it
   counts from the save, like the one-shot's future start, and "Charge to
   100% once" covers now. *Adopted.*
4. **Menu line always** while a weekly schedule is saved, not only within
   24 h of the start: it is the only reminder that a 100% request is
   coming. *Adopted.*
5. **Time zone identifier in the diagnostics report:** *no* (lead). The
   report names no person or place, and a zone name is a location; times
   carry their UTC offset instead (section 7).
6. **Overlapping windows** allowed, with the D82 extension, so the
   duration's range does not depend on the days chosen. *Adopted.*
