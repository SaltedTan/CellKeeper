# Design: Shortcuts actions for CellKeeper's own controls

Status: proposal for review, revision 2 (review r1 findings and the lead's
decisions A–I applied; the owner's answers to the six questions adopted).
Implemented in phase 2, then folded into `architecture.md` ("Shortcuts
actions" + decision rows) and deleted. Decision numbers are provisional
(D90+).

## Scope

Five App Intents in the app target, shown in the Shortcuts app under
CellKeeper. Each is the UI's own command (`AppModel`), with the UI's
preconditions and validation, never a second path. The one deliberate
difference from the UI: the limit can be set while Manage charging is off
(D90).

| Action (title) | Parameter | Same as in the UI |
|---|---|---|
| **Set CellKeeper Limit** | Limit (Int, required) | Menu slider / picker, Settings › Charging › Charge limit |
| **Start CellKeeper Full Charge** | — | Menu › "Charge to 100% once" |
| **Stop CellKeeper Full Charge or Discharge** | — | Menu › "Cancel" next to a running override |
| **Set CellKeeper Manage Charging** | Manage charging (Bool, On/Off, required) | "Manage charging" toggle (menu and Settings) |
| **Get CellKeeper Status** | — | What the menu shows (read only) |

Parameter summaries: "Set CellKeeper's charge limit to [80]%", "Turn
CellKeeper's Manage charging [On]".

Out of scope (v1): discharge to the limit, switching backends, editing the
scheduled full charge, the notification setting, clearing a fault, the
native backend's "My Charge Limit is 100%" and "Discard the Record". A
"schedule a full charge" action is not worth it now: on macOS 26+ a
Shortcuts automation at a time of day can call Start CellKeeper Full Charge,
with the same "Mac awake, CellKeeper running" limits as a schedule. Revisit
if users ask (it would wrap `setFullChargeSchedule(start:end:)`).

### Naming and descriptions

Apple's Battery action is "Set Charge Limit"; the native backend runs the
user's shortcut "CellKeeper Set Charge Limit" (research note 08 also names
"CellKeeper Get Charge Limit"). Every title starts with a verb and contains
"CellKeeper", and none contains "Charge Limit", so a search for "limit"
lists "Set Charge Limit" (Battery) and "Set CellKeeper Limit" (CellKeeper),
and no two items differ only in word order.

Every description ends with the launch sentence: "If CellKeeper is not
running, it opens and starts managing charging with your saved settings, as
when you open it."

- Set CellKeeper Limit: "Changes CellKeeper's charge limit, the same setting
  as in its menu and Settings. The limit applies only while Manage charging
  is on. This is not Apple's Set Charge Limit action, nor your “CellKeeper
  Set Charge Limit” shortcut."
- Start CellKeeper Full Charge: "Asks CellKeeper for a temporary full
  charge, like “Charge to 100% once” in its menu. It does not start while a
  temporary full charge or a discharge is already running. It ends after
  the battery is full, you unplug, or 12 hours pass."
- Stop CellKeeper Full Charge or Discharge: "Ends a temporary full charge or
  a discharge to the limit, like “Cancel” in CellKeeper's menu."
- Set CellKeeper Manage Charging: "Turns CellKeeper's Manage charging on or
  off, like the toggle in its menu. Turning it off also ends a temporary
  full charge or discharge."
- Get CellKeeper Status: "Returns the battery charge and what CellKeeper is
  doing, as of its latest check. It starts no check of its own."

## Admission: decided where commands are serialized (decision A)

`ChargeController.startFullCharge` changes: while an override is live (its
monotonic deadline not passed; `ChargeOverride.isLive(atUptime:)`), a
full charge or a discharge, started by the user or a schedule, it changes
nothing. The override and its deadline stay, and the activity log records
"Temporary full charge not started: a temporary full charge is already
running." (or "… a discharge to the limit is running."). An override whose
deadline has passed is replaced, as the evaluation would have ended it.
Schedule starts keep their own rule (D82). This applies to the menu and to
actions alike: a double-click, or several queued starts, give one override
with the first one's deadline. The discharge start is unchanged (its button
needs no override and a confirmation; out of scope).

So an action's Start result acknowledges a queued request; it never
promises that a full charge starts.

## Backend context (decision C)

Backend-specific validation and wording need a **settled context**: a first
status exists, `status.pendingBackend == nil`, and the status's backend is
the selected backend (`status.backend.identifier` is the chosen
`ControlBackendChoice`'s identifier). That last check also covers the
startup switch (an earlier session's record: the native backend restores it
first, then switches) and a switch the user chose that is still queued.

| Action | Unsettled context |
|---|---|
| Set CellKeeper Limit, Start CellKeeper Full Charge, Manage charging On | Refused: "CellKeeper is still starting or switching how it controls charging. Try again in a moment." |
| Manage charging Off, Stop | Accepted, with the generic sentence and no qualifiers |
| Get CellKeeper Status | Reports the battery and settings; state and control say "still starting or switching", Simulated is empty |

The context is checked once, after the first status; actions do not wait
for a switch to finish.

## Readiness and lifecycle (decision G, findings 2 and 7)

- `openAppWhenRun` is not declared: its default is false, and it is
  deprecated from macOS 26 in favour of `supportedModes` (26.0+). No window
  opens.
- When CellKeeper is not running, macOS launches it to run the action. It
  starts exactly as when opened: `start()` queues the startup switch if an
  earlier session left a record, then the launch evaluation, and CellKeeper
  stays in the menu bar. Running any action can therefore start CellKeeper
  managing charging and, with macOS's Charge Limit, issue requests, as
  opening it would. Attaching after `start()` only guarantees that this
  work is queued ahead of the action's command; it does not say it is
  done, which is why results depend on a settled context.
- `AppDelegate` attaches the model to the coordinator right after
  `model.start()`.
- **Waits.** An action computes one absolute deadline on the monotonic clock
  (`ContinuousClock`, 10 s from when it starts). It waits for the attach,
  then, if it needs one, for the first status, both against that deadline.
  A value that arrives after the deadline is rejected even if the waiting
  timer fires late (the check compares the clock, not the timer). A
  cancelled action resumes once, with no value. Either way the action
  refuses with the readiness text and changes nothing.
- **Termination** (`isTerminating`, set by `stopForTermination()`) is
  checked after every suspension, immediately before anything is changed or
  queued: "CellKeeper is quitting." Quitting during a wait refuses.
- After the waits, the action is synchronous on the main actor: check,
  save, queue, word the result. It never awaits the command queue, the
  controller or the backend.

**No deadlock.** A user's shortcut that calls an action while CellKeeper is
running the user's "CellKeeper Set Charge Limit" shortcut gets its answer
at once: the main actor is free (the backend runs on the controller and the
process runner), and the action waits for no command. The same value sent
again is `unchanged` (nothing queued); another value is bounded by the
restricting budget (≥ 60 s apart, ≤ 20 per hour). On a cold launch whose
evaluation runs the user's shortcut, the 10 s deadline ends any wait.

## Shared commands and presentation (decisions D, E, I)

- **Settings commands carry their source.** `Command.apply(settings,
  adoptionsSeen:, source:)`, with source `.ui` or `.shortcuts`.
  `AppModel.changeSettings(_:source:)` validates
  (`ChargingSettings.validationIssues`), saves and queues; it returns
  `.saved(previous:)`, `.unchanged` or `.refused(text)` and never touches
  `settingsError`. `updateSettings` (the UI) is `changeSettings(…, .ui)`
  plus the banner, unchanged in behaviour: a refusal sets it, a saved
  change clears it, and an unchanged value leaves it as it is.
- **Reconciliation after the command** (management kept off because an
  adoption was not yet seen or its marker cannot be removed) is a pure Kit
  function, `SettingsReconciliation`: both sources keep management off and
  save it, with `handledAdoptionCount` and the controller's adoption checks
  unchanged; only `.ui` gets the banner; `.shortcuts` is logged. A rejected
  `.apply` is treated the same way.
- **Intents never set or clear `settingsError`.**
- **Saving.** A failed save gives one fixed text, for Settings and actions:
  "CellKeeper could not save its settings." The error goes only to the
  unified log (`settings`, `privacy: .private`). This replaces Settings'
  "Could not save settings: <error>".
- **Limit.** `ChargeLimitRequest.proposal(limit:choices:settings:)` (Kit)
  refuses a value not in the choices, else returns
  `settings.withChargeLimit(limit)`, which then never clamps it and only
  moves the resume threshold as far as validity needs. Settings, the menu
  and the action all use it.
- **Full charge.** `FullChargeStart.refusal(settings:status:)` (Kit) is the
  menu button's `.disabled` and the action's check. It refuses without a
  battery reading that shows a battery present and external power: a
  deliberate tightening of the menu, which today checks only the power
  source, so an AC-powered Mac with no battery passes (D97).
- `cancelOverride()` is called by the menu and the action.

## Results and refusals (decisions B, E, F)

A result states only what is certain when the action returns: the saved
setting or the queued command. Backend effects appear only as something the
user can check ("The menu shows what CellKeeper does with it."), never as a
promise.

All text is in Kit (`ShortcutsActionWording`): fixed phrases, numbers,
backend display names ("Simulated", "Read-only", "macOS Charge Limit",
"Simulated helper") and D89's plain words; never an unavailability reason,
an error, a path or an identifier. This holds for every dialog, refusal,
entity property and unified-log line an action produces.

### Refusals

| When | Text |
|---|---|
| Not attached by the deadline (all); no first status by the deadline (Set Limit, Start, On, Get Status); unsettled context (Set Limit, Start, On) | CellKeeper is still starting or switching how it controls charging. Try again in a moment. |
| Quitting | CellKeeper is quitting. |
| Set Limit, outside 20–100 | `SettingsIssue.chargeLimitOutOfRange(...).description`: "Charge limit 15% is outside 20–100%." |
| Set Limit, not a step of macOS's Charge Limit | "83% cannot be set with macOS's Charge Limit. It accepts 80, 85, 90, 95 or 100%." (first clause shared with the menu's and Settings' labels) |
| Saving failed | CellKeeper could not save its settings. |
| Start: a full charge is running | A temporary full charge is already running. |
| Start: a discharge is running | A discharge to the limit is running. Stop it first. |
| Start: Manage charging off | Manage charging is off. Turn it on to charge to 100% once. |
| Start: limit is 100% | CellKeeper's limit is already 100%. |
| Start: no reading showing a battery and external power | CellKeeper has no battery reading that shows the Mac plugged in. |

Start's refusals are checked in the order listed. Refusals are thrown as
one error type whose `localizedStringResource` is the text; Shortcuts
shows it and stops the shortcut.

### Result sentences

| Action | Sentence |
|---|---|
| Set Limit, saved | CellKeeper saved its limit as 80%. (+ "Charging resumes at 75%." unless the backend is macOS's Charge Limit) |
| Set Limit, unchanged | CellKeeper's limit is already 80%. |
| Start | CellKeeper received the request for a temporary full charge. |
| Stop | CellKeeper will end any temporary full charge or discharge in progress. |
| Manage charging, saved | CellKeeper saved Manage charging as on. / … as off. |
| Manage charging, unchanged | Manage charging is already on. / … off. |

Then a closing: "The menu shows what CellKeeper does with it." after a
saved limit, Start and "saved as on"; "The menu shows what CellKeeper does
now." after "saved as off" and Stop; none after an unchanged result or
while Manage charging is off after a saved limit (nothing is applied).

### Qualifiers

Appended after the sentence, each decided on its own from the settled
context (the latest status with the settings as saved by this action),
never from which sentence was chosen. None in an unsettled context.

| Qualifier | Text | Used by |
|---|---|---|
| Management off | Manage charging is off, so the limit is not applied until you turn it on. | Set Limit |
| Simulated | Simulated: nothing on your Mac changes. | all, so the spoken dialog says it |
| No requests | Read-only is selected, so CellKeeper changes nothing. / <backend> is unavailable right now, so CellKeeper changes nothing; the menu says why. | all |
| Fault | The control backend is faulted: until you clear the fault in Settings › Control, CellKeeper only asks for normal charging. (macOS's Charge Limit: "… only gives back your own Charge Limit.") | Set Limit, Start, On, Get Status |
| Deferring to macOS's limit | `ControlStatement.limitNote(for:)` with the own-restriction caveat (the menu omits it only because its notice gives it) | Set Limit, Start, On, Get Status |
| Full charge running | A temporary full charge is running, which takes precedence over the limit until it ends. | Set Limit |
| Below 50% | Limits below 50% leave little charge for unplugged use. | Set Limit |

Stop and Off use only Simulated and No requests.

### Get CellKeeper Status

Needs the first status; reports the latest status as it is; sends no
evaluation of its own. Returns a `TransientAppEntity`, "CellKeeper Status",
whose values come from a pure Kit struct (`ShortcutsStatus`):

| Property | Type | Value |
|---|---|---|
| Battery charge | Int, optional | macOS's percentage; empty with no battery or unknown charge |
| Charging status | Text | `ChargingStatus.description` ("charging", "not charging", …) |
| State | Text | `PolicyState.description`; "control backend faulted"; ", not applied" for a backend that accepts no requests (as the menu's "Policy (not applied)"); "still starting or switching" when unsettled |
| Control | Text | The backend's display name; "still starting or switching" when unsettled |
| Simulated | Bool, optional | `isControlSimulated`; empty when unsettled |
| Charge limit | Int | CellKeeper's setting |
| Manage charging | Bool | CellKeeper's setting |
| Checked at | Date, optional | `lastEvaluation` |

Display: title "Battery 76%", subtitle the state. Dialog: "Battery 76%, not
charging. CellKeeper (Simulated helper): holding at the limit; its limit is
80%. Simulated: nothing on your Mac changes. Checked at 14:32." With macOS's
Charge Limit accepting requests, it adds "macOS reports its Charge Limit at
80%." or "macOS's Charge Limit could not be read." (never the read
problem). Unsettled: "Battery 76%, not charging. CellKeeper is still
starting or switching how it controls charging. Checked at 14:32."

## Confirmations

Mirror the UI exactly. None of the five commands asks for confirmation in
the UI (the toggles, the limit slider, picker and steppers, "Charge to 100%
once" and "Cancel" call `AppModel` directly; the only confirmations are
discharge, choosing the native backend, "My Charge Limit is 100%" and
discarding the record, all out of scope). So no action calls
`requestConfirmation`. Stop has none because the menu's Cancel has none; it
gets no exemption from the rate limit or any safety rule (ending a full
charge with macOS's Charge Limit requests its limit again, a restricting
change).

## Where code lives

- **App target** (App Intents metadata is extracted from the app's module;
  intents in a package would need `AppIntentsPackage` and the package's
  own metadata, not worth it for five thin types):
  `CellKeeper/ShortcutsActions.swift` holds the five intents, the status
  entity, the error type and the `AppShortcutsProvider`. Each `perform()`
  is a few lines: call the coordinator, turn its result into a dialog,
  value or thrown refusal. `AppModel` conforms to the coordinator's
  protocol (a few lines each), gains `changeSettings(_:source:)`, the
  command source and `isTerminating`. `CellKeeperApp.swift` attaches the
  model after `start()`. `MenuBarView` and `SettingsView` use the shared
  checks.
- **Kit** (tested):
  - `ShortcutsActionCoordinator` (`@MainActor`): owns the readiness waits,
    the termination checks, the settled-context check, the admission
    checks, and calls the target. Its target is a small `@MainActor`
    protocol (`ShortcutsActionTarget`: latest status, settings, selected
    backend identifier, `isTerminating`, the first-status signal,
    `changeSettings(_:source:)`, queue a full charge, queue a cancel). It
    logs through an injected sink.
  - `FirstValue`: a value provided once and awaited until an absolute
    deadline on an injected clock, as above.
  - `ShortcutsActionWording`, `ShortcutsStatus`, `ChargeLimitRequest`,
    `FullChargeStart`, `SettingsReconciliation`.
- **Core:** `ChargeController.startFullCharge` (decision A).

## Availability (checked in the macOS 27.0 SDK's AppIntents swiftinterface)

- `AppIntent`, `IntentDialog`, `ProvidesDialog`, `ReturnsValue`,
  `TransientAppEntity`, `EntityProperty(title:)` (also for optional values),
  `Bool.IntentDisplayName`, `AppShortcutsProvider`: macOS 13.0.
  `AppShortcut(intent:phrases:shortTitle:systemImageName:)`: macOS 14.0
  (the form without them is deprecated from 14). `supportedModes`: 26.0.
  `openAppWhenRun`: deprecated 26.0, not declared.
- **Not used:** `AppDependencyManager` / `@Dependency` (macOS 13). Its `add`
  overloads carry `@Sendable` and `@_silgen_name` in the 27 SDK, so their
  shape may differ in the Xcode 16.0 SDK; reading a dependency that was
  never added fails at run time; and it cannot express "after `start()`".
  The coordinator's attach does all three plainly.
- Swift 6: titles are `static let …: LocalizedStringResource` (Sendable).
  `TypeDisplayRepresentation` is not `Sendable`, so the entity's type name
  is a computed `static var`; the build must show its metadata extracted.
- Only Xcode 27.1 is installed here. Xcode 16.0 and 26.6 are covered by CI
  (16.0 without warnings as errors); nothing used is newer than macOS 14.
- No entitlement: App Intents need none. The CI entitlement check stays
  unchanged.

## App Shortcuts (Siri, Spotlight)

One `AppShortcutsProvider` with Get CellKeeper Status only: phrases "Get
\(.applicationName) status" and "What is \(.applicationName) doing", short
title "Status", symbol `batteryblock`. The phrase sends no control command
itself (on a cold launch, CellKeeper starts as when opened). All five
actions are in the Shortcuts app regardless.

## Logging

Each action logs one notice to the unified log (`app` category) from fixed
text: the action, the value, and the result or refusal, e.g. "Shortcuts
action Set CellKeeper Limit: saved 80%". A management change the controller
later keeps off is logged the same way. The activity log shows the
resulting settings change or override event as for the UI, without the
source (owner's answer).

## Testing

- **Core** (`ChargeControllerTests`): two queued starts give one override
  with the first one's deadline; a start behind a discharge, or behind a
  full charge a schedule started, changes nothing and is logged; a start
  after an override's deadline passed replaces it; the schedule's D82 rule
  is unchanged (existing tests).
- **Kit, coordinator** with a fake target and a manual clock (no real
  timing): not attached by the deadline; attached but no status; value
  arriving after the deadline although the timer fired late; one deadline
  for both waits; cancellation during each wait (resumes once, changes
  nothing); quitting during each wait (refuses, changes nothing); unsettled
  context by a pending switch, by the startup switch, by a queued switch
  (Set Limit, Start, On refuse; Off and Stop accepted with no qualifiers);
  settings sent with source `.shortcuts`; the target's banner state never
  touched.
- **Kit, checks:** `ChargeLimitRequest` against Settings' validation texts
  (computed from `SettingsIssue`, not copied); `FullChargeStart` against a
  table (battery present or not, each power source, no reading, management,
  limit, each override); `SettingsReconciliation` per source.
- **Kit, wording:** each sentence and each qualifier on its own, per backend
  (Simulated, Simulated helper, Read-only, macOS's Charge Limit available or
  unavailable, faulted, the Simulated helper deferring to macOS's limit with
  each own-restriction state); qualifiers independent of the sentence (for
  example Simulated with unchanged and with management off);
  `ShortcutsStatus` values. A status carrying a distinctive unavailability
  reason, read problem and save error is run through every dialog, refusal,
  entity property and log line, and none contains them.
- **Build:** Debug and Release with warnings as errors; the built app's
  `Contents/Resources/Metadata.appintents/` lists the five actions, the
  entity and the App Shortcut; signed entitlements unchanged.
- Not unit-tested (no app test target, by decision): the intents and the
  `AppModel` glue, a few lines each.

## Needs the owner (cannot be verified here)

Running anything in the Shortcuts app or by Siri needs clicks on the
owner's Mac, which the rules forbid here. To check, with the isolated
preview build (`…CellKeeper.preview`, Simulated backend; Shortcuts may list
it as a second "CellKeeper"):
1. The five actions and their titles in the Shortcuts library; search
   "limit" and "CellKeeper".
2. Each action's dialog and refusals; the status value's properties in a
   later action.
3. With CellKeeper not running: an action launches it, it stays in the menu
   bar, and the action succeeds or refuses within 10 s.
4. The Siri / Spotlight phrase.
5. Later, with the native backend: a shortcut that calls Set CellKeeper
   Limit while CellKeeper runs "CellKeeper Set Charge Limit" (no hang).

## Provisional decision rows

| # | Decision | Rationale |
|---|---|---|
| D90 | Five App Intents in the app target (set the limit, start a temporary full charge, stop a full charge or discharge, set Manage charging, get the status), each through the same `AppModel` command and Kit checks as the UI (`ChargeLimitRequest`, `FullChargeStart`, `changeSettings`). One deliberate difference: the limit can be set while Manage charging is off (the UI disables it); it is saved and not applied, and the result says so (owner's answer). Titles contain "CellKeeper" and not "Charge Limit" | One path for every change; no clamping; a shortcut can set the limit before turning management on; no confusion with Apple's Set Charge Limit or the user's shortcut |
| D91 | Admission is decided in the controller: a manual full-charge start while an override is live (full charge or discharge, from the user or a schedule) changes nothing and is logged; one whose deadline passed is replaced; schedule starts keep D82. An action's Start result acknowledges a queued request | Several queued starts (or a double-click) saw the same status and replaced each other, resetting the deadline or overwriting a schedule's full charge or a discharge |
| D92 | Results state only what is certain at return (the saved setting or the queued command); backend effects only as something the menu shows. Text is fixed phrases, numbers, backend names and D89's words; no reason, error, path or identifier, in dialogs, refusals, the status value and the log. A failed save reads "CellKeeper could not save its settings." in Settings too; the error goes only to the unified log (private) | Actions return before the backend acts, and a queued command can be superseded or refused; Shortcuts can pass the text anywhere |
| D93 | Backend-specific checks and qualifiers only in a settled context (first status, no pending switch, the status's backend is the selected one). Otherwise Set Limit, Start and Manage charging On refuse; Off and Stop are accepted with generic text | Attaching after `start()` only queues the startup switch and launch evaluation; a status from before a switch describes another backend |
| D94 | Readiness: the model is attached after `start()`; an action waits for it and for the first status against one 10 s monotonic deadline, rejects late values, resumes once on cancellation, and rechecks quitting after every suspension before changing anything. `openAppWhenRun` keeps its default (false); launching for an action is a normal start | No action runs before start-up queued its work; a bounded wait cannot deadlock |
| D95 | Settings commands carry their source; after the command, both sources are reconciled the same way, but only the UI's get the Settings banner. Intents never set or clear it | An action's refusal, immediate or delayed, must not appear as a Settings error |
| D96 | No action asks for confirmation, because none of their UI commands does. Stop ends a discharge too and has no confirmation, for parity with the menu's Cancel; it gets no exemption from the rate limit or any safety rule | Confirmation parity with the UI, no more, no less |
| D97 | "Charge to 100% once" (menu and action) needs a reading showing a battery present and external power; the menu used to check only the power source | A deliberate tightening: with no battery there is nothing to charge |
| D98 | Get CellKeeper Status reports the latest status with its time and starts no evaluation of its own; its value has charge, macOS's charging status, state, backend, simulated, limit, Manage charging, checked at. App Shortcuts: this action only; the phrase sends no control command itself | A read must not cause backend requests; a phrase needs no setup |
