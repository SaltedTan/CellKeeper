# Design: weekly full charge (recurring scheduled full charge)

Status: Phase 1 design, revision 2 (design review r1 folded in). Decision
rows D100–D107 are provisional. Folded into `architecture.md` ("Scheduled
full charge") and deleted when implemented.

## 1. Scope

- **One weekly schedule** of the existing temporary full charge: a set of
  weekdays, a local start time (hour and minute), and a duration of 1–48
  whole hours (default 12, the full charge's default). Example: "Fridays at
  07:00 for 12 hours".
- It **coexists** with the one-shot schedule (`FullChargeSchedule`). Each has
  its own store, status fields and outcome. The one-shot's behaviour is
  unchanged except for the shared parts named in §4 (completion
  reconciliation) and §6 (the year in dates).
- It **starts the existing temporary full charge** through the one-shot's
  path (`ChargeOverride.scheduledFullCharge`, source `.schedule`, display
  only), so rows 8 and N3, completion, unplugging, expiry, D82, D83 and D91
  are unchanged. It never changes settings, Manage charging or the backend,
  and never discharges.
- **Out of scope:** scheduled limits (changing the limit on a schedule),
  other recurrences (every N days, monthly), more than one weekly schedule,
  pausing without deleting, "skip the next one", waking the Mac or opening
  at login, a new notification kind, a Shortcuts action. On macOS 26+ a
  Shortcuts time-of-day automation running Start CellKeeper Full Charge
  remains the documented alternative (roadmap).

Name in the UI and log: **"Weekly full charge"**. A full charge it starts is
named "Scheduled full charge" while it runs, as for the one-shot (the menu,
the log and override-ended notifications already say that for source
`.schedule`).

## 2. Time semantics (floating local time)

Everything is pure and computed from an injected `TimeZone` and `now`.

- **Nominal day.** An occurrence belongs to a **nominal local day** `D`: a
  floating Gregorian date (year, month, day) with no time zone, whose
  weekday is in the set. `D` is the occurrence's identity, and each nominal
  day has at most one occurrence. Days are enumerated and their weekdays
  found by floating date arithmetic (a Gregorian calendar in UTC, which has
  no gaps or repeats), never with a calendar in the user's zone: that would
  normalise a day the zone skips (Apia's 2011-12-30) into the next one. The
  user's calendar and locale only order and name the weekdays in the UI.
- **Start and end.** `S` is `D` at the start time, read in the time zone
  current at the check; `E = S + duration` in elapsed seconds. The day `S`
  falls on locally can differ from `D` (below).
- **Reading a local time.** This follows RFC 5545 §3.3.5's interpretation of
  a DATE-TIME with local time and a time zone reference:
  - a time that does not exist (a change of offset skips it) is read with
    the UTC offset in force before the change, so it falls later by the
    length of the skip (New York, 2026-03-08 02:30 → 03:30 EDT; Lord Howe,
    2026-10-04 02:10 → 02:40, a 30-minute skip);
  - a time that occurs twice is the first of the two (New York, 2026-11-01
    01:30 → 01:30 EDT).

  RFC 5545 §3.3.10 says that recurrence instances at a nonexistent local
  time are ignored. CellKeeper deliberately does not drop them: it reads
  them as DATE-TIMEs, so a week's full charge is moved, never silently
  dropped.
- **A whole skipped day.** Apia (Pacific/Apia) went from UTC−10 to UTC+14
  at the end of 2011-12-29, skipping the 30th. Nominal 2011-12-30 07:00,
  read with the offset before the change, is 2011-12-30 17:00Z (the 31st,
  07:00 local), the same instant as nominal 2011-12-31 07:00. **Among
  occurrences with equal start instants, the greatest nominal day wins** and
  supersedes the others, both when choosing the occurrence that can start
  and when choosing the next one, so the two choices agree.
- **Window across a change of offset:** the duration is elapsed time, as for
  the one-shot. Saturday 2026-10-31 20:00 + 12 h in New York ends Sunday
  07:00 EST, not 08:00. The UI shows the end's actual clock time.
- **How `S` is computed.** From `TimeZone.secondsFromGMT(for:)` only: the
  candidate instants `local − offset` for the offsets a day either side;
  those whose own offset matches → the earliest; none (a skip) → `local −
  offset before`. Not through `Calendar`'s matching policies:
  `Calendar.nextDate(after:matching:matchingPolicy:
  .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, …)`
  moved Lord Howe's 02:10 on 2026-10-04 to the next day (observed on macOS
  27.0, reproduced by the review on 27.0.1), and `date(from:)` documents no
  rule for skipped or repeated times.
- **The time zone.** Occurrences are recomputed in the current zone at every
  check ("Friday 07:00 wherever the Mac is"). The controller reads the zone
  through an injected provider at every evaluation, together with `now`
  after the backend's reads, never captured at init. The app's provider
  calls `NSTimeZone.resetSystemTimeZone()` and then reads `TimeZone.current`.
  `AppModel.clockDidChange()` keeps its own reset before queuing
  `.clockChanged`. Foundation documents the system zone as cached until that
  reset (`NSTimeZone.h`, `systemTimeZone`) and does not document resetting
  it itself. A probe that changed only its own `TZ` variable found
  `TimeZone.current`, `TimeZone.autoupdatingCurrent`, `NSTimeZone.system`
  and `NSTimeZone.local` all unchanged until the reset and all updated
  after it, and the reset posted no `NSSystemTimeZoneDidChange` (macOS
  27.0). So the evaluation does not depend on the notification arriving,
  and resetting cannot loop.
- **Which occurrence counts.** At each check only **P** can start or pass:
  the occurrence with the latest start at or before `now` (ties: the
  greatest nominal day). Earlier ones are superseded: with equal durations,
  P's window ends last, so starting P never gives less than starting an
  earlier one.
- **Day search.** P: nominal days from today + 1 back to today − 8 (today
  in the current zone). Next: offsets 0 through 8 from the first candidate
  day, `max(today − 1, handled.day + 1)`; from a Sunday start, Monday just
  after its start needs the following Monday, at offset 8.
- **Overlapping windows** (a duration longer than the gap to the next
  selected day, e.g. every day for 48 h, or a 24 h window across a 23 h
  day): allowed. The later occurrence starts on schedule; a full charge
  still live from the earlier one keeps the later monotonic deadline (D82),
  so it is extended. A full charge ends at 100% or when macOS reports fully
  charged anyway.

## 3. The handled record

**The record.** The schedule persists `handled`: the nominal day of the
latest occurrence that started, passed, or began before the schedule was
saved, with its start instant, the UTC offset at that start, and a result
(`started`, `passed`, `beforeSave`). An occurrence is **eligible only if its
nominal day is after `handled.day`**. Comparison is by nominal day only; the
instant and offset are for display and diagnostics. No time zone identifier
is stored or reported.

**The check** (`WeeklyFullChargeSchedule.check(_:input:timeZone:)`, pure):

1. P not eligible (its day ≤ `handled.day`), or none: nothing is due.
2. P eligible: the one-shot's own `FullChargeSchedule.check` on P's window,
   so the start conditions are identical (valid settings, Manage charging
   on, a usable reading on external power; D78): `.start(P, remaining)`,
   `.waiting(P, wait)` or `.passed(P)`.
3. `next`: the first occurrence that starts **strictly after** `now` on a
   day after `handled.day` (ties: the greatest nominal day). A due P is
   never Next; it has its own line and row (§6, §7).

**Writing the record is transactional.** `WeeklyFullChargeStore.save`
encodes, sets, reads the value back and compares it. The controller changes
nothing until that succeeds:

- **Start:** `handled := P (started)` is written first; only then is the
  override installed or extended, with no suspension point in between. The
  started full charge's duration is the time left to P's end (no one-hour
  minimum, at most 48 h).
- **Passed:** `handled := P (passed)` is written before the outcome is set.
- **Save, edit, remove:** written (or removed) and verified before the new
  schedule, or its absence, takes effect.
- **A detected failure** leaves the previous record and schedule in force,
  starts and extends nothing, and shows a fixed line (§6); the error goes
  only to the unified log, privately. A start or a passed record is tried
  again at later evaluations while P is the occurrence that counts; the log
  notes the first failure and the next success, not every retry. A failed
  save, edit or remove is not retried: the user tries again.
- **What a read-back does not show.** It confirms the value this process
  will read, not that `UserDefaults` has written it to disk. Every
  cross-launch statement below assumes it reached persistent storage; after
  a crash or power loss right after a start, the record can be lost, and
  the same occurrence can start once more at the next launch while its
  window is open (a relaxation the user scheduled; with macOS's Charge
  Limit, another 100% request inside that window). The one-shot has the
  same limit (D79).

**What the record gives** (one controlling instance assumed, as D79):

- An occurrence whose record was written is not started again: not within
  a run, not after a backward clock change of any size, not after a
  relaunch (given the write reached disk), not after a time-zone change
  (London → New York on the same Friday: Friday is handled; Tokyo →
  Honolulu repeats Friday: handled).
- A missed occurrence is not replayed: once P's window has passed, it is
  recorded as passed and reported. Only P is reported; earlier missed ones
  are not listed.
- **Launch or wake inside an unhandled occurrence's window** starts it, like
  the one-shot within its window. One already started is not resumed (a
  started charge is not persisted; quitting ends it, D79).
- **Clock jumps are level-triggered.** Fridays at 07:00 for 48 h: a jump
  forward to Sunday 06:00 starts Friday's occurrence for its remaining hour
  (its window is open, so it was not missed); at Sunday 07:00 or later it
  has passed and is recorded so; a rewind afterwards cannot reactivate it.
  A clock set far ahead and back again makes CellKeeper skip the days in
  between (Next shows the date); removing the schedule and setting it again
  counts from then.

**Saving counts from the save.** Inside the serialized controller command,
with the time and zone read then (not a value captured before the command
was queued): `handled := the later of the existing record and the new
pattern's P (beforeSave)`. A save never makes a day eligible again, and an
occurrence whose start passed before the save does not start (as the
one-shot needs a future start); "Charge to 100% once" covers "now". A full
charge already running is not changed by an edit. **Removing** deletes the
pattern and the record; a schedule set again after that starts a new record.

**Wait evidence belongs to an occurrence.** The controller keeps the reason
P last waited together with P's nominal day, in memory only. A passed
outcome says "Last checked: …" only with evidence for that same day. The
evidence is dropped when an occurrence with a later nominal day becomes P
(Monday's reason never reaches Wednesday); a clock rewind, which makes an
earlier occurrence P, keeps it, so Monday's reason still counts when Monday
later passes.

## 4. Interactions

- **One-shot schedule:** in one evaluation the one-shot is applied first,
  then the weekly schedule. Each writes its own record (the one-shot removes
  itself from its store) before touching the override.
- **Completion reconciliation (both schedules).** Today one Bool
  (`startedSchedule`) lets `performEvaluation` turn one `.started` into
  `.alreadyFull`. Instead, each schedule that took part (started, extended
  or kept a running full charge) is tracked with a provisional outcome.
  After the one policy evaluation, if the full charge they started,
  extended or kept ended as completed in that evaluation, each
  participant's outcome becomes "already full"; otherwise the provisional
  outcomes stand. There is still exactly one override and one ending event
  (`overridesEnded` counts it once, so notification gating is unchanged).
  "Kept" is worded for equal deadlines too ("expires no earlier than this
  one would have"). Tests: both deadline orders, equal deadlines, already
  full, an expired predecessor (replaced and counted as expired, as now).
- **Running override:** D82 unchanged for schedule application. D91
  unchanged: a manual, UI or Shortcuts start is ignored while a full charge
  a weekly occurrence started is live.
- **Manage charging off:** as D80: the schedule is kept, a due occurrence
  waits (`managementOff`), and if its window passes it is recorded as
  passed, with "Last checked: Manage charging was off" if this run saw it
  wait. Editing needs management on; Remove never does.
- **Backend switches, faults, Read-only, unavailable, simulated:** as the
  one-shot (it starts; the policy rows and action table decide; the
  explanation says what it changes per backend).
- **Notifications:** no new kind. A full charge it started that ends by
  itself is the existing override-ended notification ("Scheduled full
  charge"). A passed occurrence notifies nothing (as the one-shot).
- **Shortcuts:** no new action; Get CellKeeper Status does not report
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
offset beyond ±18 h, an unknown result) is **removed with a notice**
(outcome `.discarded`), never affecting settings or Manage charging; only no
value counts as no schedule. If that removal cannot be verified, the
schedule is still not used, and the notice says it could not be removed.
Unknown keys are ignored. Loaded at the first command, like the one-shot.

## 6. UI

**Settings › Charging**, a new section "Weekly full charge" after
"Scheduled full charge":

- Seven weekday toggle buttons (locale order, short names), a "Start" time
  picker (hour and minute), a "Duration" stepper (1–48 hours), "Save Weekly
  Full Charge" (enabled with at least one day, Manage charging on, and a
  change from what is saved) and "Remove" (when saved; always enabled). The
  editor starts from the saved schedule, else from no day, 07:00 and 12
  hours.
- Saved: "Every Friday at 07:00, for 12 hours" ("Every day" for all seven).
- **Due** (its own line, orange, only while P is eligible and waiting):
  "Due now, cannot start yet: the Mac is on battery; connect power. It can
  still start until Fri 23 Oct, 19:00." (the one-shot's wait texts).
- **Next** (strictly future): "Next: Fri 23 Oct, 07:00 – 19:00"
  (`FullChargeScheduleWording.window`, which adds the zone in a repeated
  hour or when both ends read the same). When a skip moves the start: "02:30
  does not occur on Sun 8 Mar (the clocks go forward), so it starts at
  03:30."
- **Last** (for `started` and `passed`, not `beforeSave`): "Last: Fri 16 Oct,
  07:00, started" or "…, passed before it could start".
- **Record not saved** (orange, while a start or passed record cannot be
  written): "CellKeeper could not save its record of the weekly full charge
  of Fri 23 Oct, 07:00, so it has not started it. It tries again at its next
  check." (for a passed one: "CellKeeper could not save that the weekly full
  charge of … passed. It tries again at its next check."). A failed save,
  edit or remove: "CellKeeper could not save the weekly full charge." or
  "CellKeeper could not remove the weekly full charge."; the previous
  schedule stays.
- **Dates** show the year whenever it is not the current year in the Mac's
  zone ("Fri 1 Jan 2027, 07:00"). This is in the shared formatter, so the
  one-shot's lines get it too.
- Footer: times follow the Mac's current time zone; the duration is elapsed
  time; the one-shot's start conditions (awake, CellKeeper running, cannot
  wake the Mac or open itself; starts at its next check before the end;
  unplugging ends it). On repeats, no promise: "CellKeeper records each
  weekly full charge that starts or passes, so it does not start that one
  again, even if the clock or time zone changes. One that passes while it
  cannot start is not made up later. Removing the schedule clears the
  record." The crash exception goes in the help of Save Weekly Full Charge,
  where it belongs to the record: "If CellKeeper quits unexpectedly or the
  Mac loses power just after a start, the record may not have been saved,
  and that full charge can start again at the next launch while its window
  is open." The backend explanation (`FullChargeScheduleWording.explanation`,
  generalised to "the end of the window") is shared with the one-shot
  section, not repeated.

**Menu** (while a weekly schedule is saved), under the one-shot's lines,
one of:

- "Weekly full charge: next Fri 23 Oct, 07:00 – 19:00", no button; or,
  instead,
- while P is due and waiting (orange): "Weekly full charge is due but cannot
  start yet: the Mac is on battery; connect power. It can still start until
  Fri 23 Oct, 19:00."; or
- while a record cannot be saved (orange): the Settings line, in short.

Plus the outcome with OK, **only the latest**, in memory (not persisted, as
the one-shot), also after Remove or a discard: "The weekly full charge of
Fri 23 Oct, 07:00 passed before it could start. Last checked: the Mac was on
battery.", already full, kept a running one, a saved weekly schedule was
removed. Started and extended show no outcome line; the running line says
it (`TemporaryFullChargeWording`, unchanged).

Plain words throughout (D89); CellKeeper *requests* 100%; nothing promises a
charge ready by a time, a return to the limit at a time, or that a full
charge never starts twice.

**Activity log** (override events): saved, changed, removed, loaded,
discarded, due but waiting (on a change of reason), started / extended /
kept / already full, passed (with "Last checked" only with evidence for
that day), record not saved (first failure) and saved again. When Next
changes for any other reason (a zone or clock change), one line gives the
new Next, without guessing why.

## 7. Diagnostics

Through the section model (PR #88), in the "Decision" section after the
one-shot's rows:

| Row | When | Value (report) |
|---|---|---|
| Weekly full charge | saved | "every Fri at 07:00 for 12 hours (weekdays 6)" |
| Weekly due | P eligible and waiting, or its record not saved | "2026-10-23 (nominal), 2026-10-23T07:00:00+01:00 to 2026-10-23T19:00:00+01:00; waiting: …" |
| Weekly next | saved | "2026-10-30 (nominal), 2026-10-30T07:00:00+01:00 to 2026-10-30T19:00:00+01:00" |
| Weekly handled | saved | "2026-10-16, started at 2026-10-16T07:00:00+01:00 (started)" |
| Weekly record not saved | a write failed | "start of 2026-10-23" or "passed 2026-10-23" |
| Weekly outcome | an outcome exists, also after Remove or a discard | as the one-shot's `describe(outcome)` |

- **Times with their UTC offset, no region names** (lead's decision): the
  report names no person or place, and a zone name is a location. A new
  `DiagnosticsValue` part, a moment with the UTC offset in force at it
  (`.offsetTime(Date, utcOffset:)`), renders as ISO 8601 with that offset in
  the report; the Diagnostics tab shows it in local time like every other
  moment. The offsets come with the occurrence (start and end) and the
  record (start), computed when the controller checked, so the report needs
  no zone. `.time` and every existing golden stay byte-identical.
- **New fixtures:** a window across a change of offset (start and end
  offsets differ), travel after an occurrence was handled (the record's
  offset differs from Next's), a due occurrence with its wait, a record not
  saved, and an outcome after Remove.

## 8. Testing

Pure Core tests (Swift Testing), injected `TimeZone`, `TestClock`, no wall
clock. Every expected instant is hand-computed in UTC, never compared with
Foundation's own local-time conversion.

- **Local times:** fixtures that prove each case is a real change of offset;
  New York 2026-03-08 02:30 → 07:30Z and 2026-11-01 01:30 → 05:30Z (first);
  London 2026-03-29 01:30 → 01:30Z and 2026-10-25 01:30 → 00:30Z; Lord Howe
  2026-10-04 02:10 → 15:40Z on the 3rd and 2026-04-05 01:45 → 14:45Z on the
  4th; window Sat 2026-10-31 20:00 New York + 12 h → 12:00Z.
- **Days:** weekdays across week, month and year ends and 2028-02-29;
  Apia's skipped day: nominal 30th and 31st collide at 2011-12-30 17:00Z,
  P and Next both pick the 31st, enumeration across the skip, saving before
  and after it, repeated checks start it once.
- **Search bounds:** Monday only, checked just after Monday's start, finds
  the following Monday as Next.
- **Check:** every case of §3 for single, several and all weekdays; Next
  strictly after `now`; a due P is not Next.
- **Record writes:** a store whose write or read-back fails: no start, no
  extension, previous record intact, the fixed line, and a retry that
  succeeds later in the window starts it; the same for passed, save, edit
  and remove.
- **Repeats:** clock back 1 h, 1 day and 3 weeks after a start; relaunch (a
  new controller, same storage) inside a started window (no start) and an
  unstarted one (starts); London → New York on the same Friday; Tokyo →
  Honolulu (repeated Friday); eastward travel (the next day is eligible).
- **Missed:** asleep across a window (one passed outcome); asleep nine days
  with a daily schedule (one outcome, the latest); not replayed after a
  backward clock change.
- **Clock jumps:** the 48 h Friday example of §3 (starts at Sunday 06:00 for
  its remaining hour; passed at 07:00; a rewind does not reactivate it);
  forward and back skips days, Next after the record.
- **Wait evidence:** Monday waits on battery, the next evaluation is after
  Wednesday's window: Wednesday's passed outcome has no "Last checked"; a
  rewind before Monday's window, then Monday passes: Monday's reason kept.
- **Saving:** before today's start (starts today), inside the window (not
  today; Next is next week), editing after a start (not again today),
  remove and set again (counts from then); eligibility computed with the
  time read inside the command (a clock that moves while it is queued).
- **Overlap:** daily 48 h extends a live full charge; completes and starts
  again.
- **Both schedules:** the reconciliation cases of §4, exactly one ending
  event, D91 still ignoring a manual start.
- **Store:** round trip; every invalid field, wrong type, not JSON → removed
  with a notice, settings and the one-shot's key untouched; key pinned.
- **Management off:** waits, passes with `managementOff`; turned on within
  the window, starts.
- **Kit wording:** summary, Due, Next, Last, the skip note, the zone in a
  repeated hour, the year outside the current year (also for the one-shot),
  the record-not-saved lines, outcomes. **Diagnostics:** the fixtures of §7.
- Each test that asserts "no start" also asserts that the evaluation ran
  inside the window with every start condition met, so it cannot pass
  without exercising the rule.

## 9. Provisional decision rows

| # | Decision |
|---|---|
| D100 | One weekly full charge (owner approval 2026-10-19; shape and answers: lead): weekdays, local start time, 1–48 whole hours; coexists with the one-shot; starts the existing temporary full charge (source `.schedule`); no scheduled limits, pause, skip, new notification kind or Shortcuts action, no wake |
| D101 | Floating local time: occurrences belong to nominal Gregorian days, enumerated without a zone; the start is read in the zone current at each evaluation (read fresh, after a reset of the cached system zone) by RFC 5545 §3.3.5 (skipped → offset before, repeated → first), not dropped as §3.3.10 would; equal starts → greatest nominal day; duration is elapsed time; computed from `TimeZone` offsets, not `Calendar` matching policies |
| D102 | Only P, the occurrence with the latest start at or before now, can start or pass; earlier ones are superseded; its window goes through the one-shot's check and D82's rules; overlapping windows allowed; Next is strictly future |
| D103 | A record of the latest handled nominal day; an occurrence is eligible only after it; written and read back before anything changes, and a failure changes nothing and is shown; saving counts from the save (inside the command) and never lowers it; removing deletes it; cross-launch statements assume the write reached disk |
| D104 | Own store `weeklyFullCharge.v1`; invalid or unreadable → removed with a notice, never affects settings |
| D105 | Wait evidence is kept per occurrence; both schedules are reconciled after the one policy evaluation, with one override and one ending event |
| D106 | UI: Settings section (days, time, duration, Save, Remove, Due, Next, Last, the skip note, record failures, the year outside the current year); menu Next or Due line and the latest outcome only, in memory; no promise that a full charge never starts twice |
| D107 | Diagnostics rows through the section model, times as ISO 8601 with their UTC offset (a new part), no time zone identifier (lead's decision); existing goldens unchanged |

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
   carry their UTC offset instead (§7).
6. **Overlapping windows** allowed, with the D82 extension, so the
   duration's range does not depend on the days chosen. *Adopted.*

## 11. Review r1 findings and where they are handled

| # | Finding | Where |
|---|---|---|
| 1 | Diagnostics prescribed region identifiers | §7 (offset part, no zone, fixtures) |
| 2 | Failure to write the record undefined | §3 (transactional writes, honest persistence), §6, §8 |
| 3 | Whole-day skips and equal starts | §2 (nominal day, zone-free enumeration, greatest day wins), §8 |
| 4 | Wait evidence crossed occurrences | §3 (evidence per occurrence), §8 |
| 5 | One completion Bool for two schedules | §4 (per-participant reconciliation), §8 |
| 6 | Next not strictly future; outcome row tied to a saved schedule | §3, §6, §7 |
| 7 | UI promised "never twice"; no year | §6 |
| 8 | Forward jumps and save-time eligibility unstated | §3, §8 |
| 9 | Zone freshness and day-search bounds | §2 |
