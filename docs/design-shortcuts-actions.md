# Design: Shortcuts actions for CellKeeper's own controls

Status: proposal for review (phase 1). Implemented in phase 2, then folded
into `architecture.md` ("Shortcuts actions" + decision rows) and deleted.
Decision numbers are provisional (D90+).

## Scope

Five App Intents in the app target, shown in the Shortcuts app under
CellKeeper. Each is the UI's own command (`AppModel`), with the UI's
preconditions and validation, never a second path.

| Action (title) | Parameter | Same as in the UI |
|---|---|---|
| **Set CellKeeper Limit** | Limit (Int, required) | Menu slider / picker, Settings › Charging › Charge limit |
| **Start CellKeeper Full Charge** | — | Menu › "Charge to 100% once" |
| **Stop CellKeeper Full Charge or Discharge** | — | Menu › "Cancel" next to a running override |
| **Set CellKeeper Manage Charging** | Manage charging (Bool, On/Off, required) | "Manage charging" toggle (menu and Settings) |
| **Get CellKeeper Status** | — | What the menu shows (read only) |

Parameter summaries: "Set CellKeeper's charge limit to [80]%", "Turn
CellKeeper's Manage charging [On]".

Out of scope (v1): discharge to the limit (confirmed in the UI), switching
backends (the native backend is confirmed in the UI), editing the scheduled
full charge, the notification setting, clearing a fault, the native
backend's "My Charge Limit is 100%" and "Discard the Record" (both
confirmed in the UI).

**A "schedule a full charge" action is not worth it now.** On macOS 26+
Shortcuts can run an automation at a time of day; it can call Start
CellKeeper Full Charge, with the same "Mac awake, CellKeeper running"
limits as a schedule. A schedule action would add date parameters and a
second way to set one window. Revisit if users ask (it would wrap
`setFullChargeSchedule(start:end:)` with its existing validation).

### Naming

Apple's Battery action is "Set Charge Limit" (summary "Set charge limit to
…"); the native backend runs the user's shortcut "CellKeeper Set Charge
Limit" (research note 08 also names "CellKeeper Get Charge Limit"). Every
title starts with a verb and contains "CellKeeper", and none contains the
words "Charge Limit", so in search "limit" lists "Set Charge Limit" (Battery
icon) and "Set CellKeeper Limit" (CellKeeper icon), and "CellKeeper" never
lists two items that differ only in word order. Descriptions (searchable)
say what each action is not:

- Set CellKeeper Limit: "Changes CellKeeper's charge limit, the same setting
  as in its menu and Settings. CellKeeper then applies it with the control
  backend in use; with macOS's Charge Limit, through your “CellKeeper Set
  Charge Limit” shortcut. This is not Apple's Set Charge Limit action."
- Start CellKeeper Full Charge: "Lets the battery charge to 100% once, like
  “Charge to 100% once” in CellKeeper's menu. CellKeeper requests its limit
  again after the battery is full, you unplug, or 12 hours pass."
- Stop CellKeeper Full Charge or Discharge: "Ends a temporary full charge or
  a discharge to the limit, like “Cancel” in CellKeeper's menu."
- Set CellKeeper Manage Charging: "Turns CellKeeper's Manage charging on or
  off, like the toggle in its menu. When off, CellKeeper asks for macOS
  default charging (with macOS's Charge Limit: gives back your own limit)."
- Get CellKeeper Status: "Returns the battery charge and what CellKeeper is
  doing, as of its latest check. Changes nothing."

## Shared commands (one path)

`AppModel` gains one function per command that returns a result instead of
setting UI state; the UI and the intents both call it:

- `changeSettings(_:) -> SettingsChangeResult` (`.saved(previous:)`,
  `.unchanged`, `.refused(String)`): today's body of `updateSettings` (no
  change → unchanged; `validationIssues`; `store.save`; send `.apply`). The
  existing `updateSettings` becomes `changeSettings` plus the banner: it
  sets `settingsError` on a refusal and clears it on success, as now. An
  intent calls `changeSettings` directly, so **its refusal never leaves a
  banner**; its success clears a stale one, as any successful change does.
- `requestChargeLimit(_:) -> SettingsChangeResult`: refuses a value not in
  `chargeLimitChoices` (the choices Settings offers right now: the backend
  in charge, or before any status the chosen backend) with
  `ChargeLimitChoices.refusal(for:)` (Kit), then `changeSettings { $0 =
  $0.withChargeLimit(limit) }`. Because the value is checked first,
  `withChargeLimit` never clamps it; it only moves the resume threshold as
  far as validity needs, as with the slider. The menu and Settings call it
  too (their values always pass the check).
- `requestFullCharge() -> String?` (refusal): `FullChargeStart.refusal
  (settings:status:)` (Kit), else `send(.startFullCharge)`. The menu's
  button uses the same function for `.disabled`, replacing its inline
  predicate (`!isManagementEnabled || chargeLimit >= 100 ||
  snapshot?.isOnExternalPower != true`; the button is hidden while an
  override runs, which the function also refuses).
- `cancelOverride()` (unchanged) is called by both.
- `isTerminating` (new, set by `stopForTermination()`): every action
  refuses once quitting started; queued commands would be dropped anyway.

## Results and refusals

Actions return once the change is saved and the command queued. They never
await the command queue or the backend (a native request runs the user's
shortcut through `/usr/bin/shortcuts`, up to its 20 s deadline per run,
longer on a cold start). So every result is about what CellKeeper saved or
*will request*, worded from the latest status (`ChargeController` is never
asked anything); confirmation is the menu's job, and the result says so
where a confirmation will come.

All wording is in Kit (`ShortcutsActionWording`), built like
`NotificationWording`: fixed phrases, numbers and backend names, the menu's
own sentences where the menu says the same thing, and never an
unavailability reason, error message or log text (Shortcuts may pass the
text anywhere). A backend that accepts no requests is named by a fixed
phrase: Read-only by "Read-only is selected, so CellKeeper changes
nothing", any other by "<backend> is unavailable right now, so CellKeeper
changes nothing; the menu says why."

### Refusals common to all actions

| When | Text |
|---|---|
| The model is not attached within 10 s (see "Launch") | CellKeeper is still starting. Try again in a moment. |
| No status within the same 10 s (actions that need one) | CellKeeper has not finished its first check yet. Try again in a moment. |
| Quitting started | CellKeeper is quitting. |

Refusals are thrown as one error type whose `localizedStringResource` is
the text; Shortcuts shows it and stops the shortcut.

### Set CellKeeper Limit

Allowed: exactly `chargeLimitChoices.values` (20–100 for every backend but
macOS's Charge Limit; 80, 85, 90, 95, 100 for it, or the steps it
advertises). No range in the parameter's metadata, because the range
depends on the backend, and so that Shortcuts cannot clamp a value before
CellKeeper sees it. Allowed while Manage charging is off (owner question
2).

Refusals:
- Outside 20–100: `SettingsIssue.chargeLimitOutOfRange(...).description`,
  the text Settings' validation gives: "Charge limit 15% is outside
  20–100%."
- Not a step: "83% cannot be set with macOS's Charge Limit. It accepts 80,
  85, 90, 95 or 100%." The first clause becomes a Kit function shared with
  the menu's and Settings' existing labels ("83% cannot be set with macOS's
  Charge Limit. Choose one of the values …").
- Saving failed: "Could not save settings: <error>", as Settings.

Results (first sentence, then the notes that apply, in this order):
- Unchanged: "CellKeeper's limit is already 80%."
- Saved, Manage charging off: "CellKeeper saved its limit as 80%. Manage
  charging is off, so the limit is not applied until you turn it on."
- Saved, macOS's Charge Limit accepting requests: "CellKeeper saved its
  limit as 80% and will request a macOS Charge Limit of 80%. The menu shows
  when macOS confirms it." (`ChargeControlMode.nativeLimit(80).description`.)
- Saved, Simulated or Simulated helper: "CellKeeper saved its limit as 80%,
  resuming at 75%. Simulated: nothing on your Mac changes."
- Saved, a real backend that switches charging itself (none yet): "CellKeeper
  saved its limit as 80%, resuming at 75%."
- Saved, a backend that accepts no requests: "CellKeeper saved its limit as
  80%." + the fixed phrase above.
- Notes: a temporary full charge running ("A temporary full charge is
  running, so the new limit applies after it ends."); a fault ("The control
  backend is faulted: until you clear the fault in Settings › Control,
  CellKeeper only asks for normal charging." / "… only gives back your own
  Charge Limit."); deferring to macOS's limit (`ControlStatement.limitNote
  (for:includesOwnRestriction: false)`, the menu's text); with macOS's
  Charge Limit, "no limit" awaiting confirmation (the menu's text) or
  `NativeLimitWording.restoreProblem`; below 50% ("Limits below 50% leave
  little charge for unplugged use.").

### Start CellKeeper Full Charge

Needs the first status. Refusals, checked in this order, exactly the cases
in which the menu hides or disables the button:

| Case | Text |
|---|---|
| A full charge is running | A temporary full charge is already running. |
| A discharge is running | A discharge to the limit is running. Stop it first. |
| Manage charging off | Manage charging is off. Turn it on to charge to 100% once. |
| Limit is 100% | CellKeeper's limit is already 100%. |
| Latest reading shows battery power | The Mac is on battery. Connect power first. |
| No reading, no battery, or unknown power source | CellKeeper has no battery reading that shows a power adapter. |

A refusal ends the user's shortcut; "already running" is a refusal because
the menu does not offer the button then (restarting would move the
deadline, which the menu never does).

Results (the wording of `TemporaryFullChargeWording.buttonHelp`, in the
future tense because the request is still queued):
- macOS's Charge Limit: "CellKeeper will request a macOS Charge Limit of
  100% once. It requests its 80% limit again at a check after the battery
  is full, you unplug, or 12 hours pass. The menu shows when macOS confirms
  100%."
- Simulated: "Simulated: CellKeeper records a temporary full charge. Nothing
  on your Mac changes. It ends at a check after the battery is full, you
  unplug, or 12 hours pass."
- Real backend that switches charging itself: "CellKeeper will ask for none
  of its own restrictions, unless a safety rule such as the temperature
  pause still pauses charging. It requests its 80% limit again at a check
  after …"
- Accepts no requests: "<fixed phrase>; a temporary full charge only shows
  what CellKeeper would do."
- Notes: deferring to macOS's limit ("While macOS's Charge Limit is on, it
  stays in charge and the full charge has no effect.", the schedule's
  text); a fault.

### Stop CellKeeper Full Charge or Discharge

A move toward macOS defaults: no status needed, no refusal except the
common "starting" and "quitting" ones. It always queues `.cancelOverride`,
even when the latest status shows nothing running, so a start queued just
before it (from the menu, a schedule or another action) is ended too; the
controller's `cancelOverride` does nothing when nothing runs.

- Full charge running: "CellKeeper will end the temporary full charge and
  request its 80% limit again." (macOS's Charge Limit: "… and request a
  macOS Charge Limit of 80% again. The menu shows when macOS confirms
  it.") + Simulated / no-requests phrase.
- Discharge running: "CellKeeper will end the discharge to the limit." +
  Simulated / no-requests phrase.
- Nothing running: "No temporary full charge or discharge was running."
- No status yet: "CellKeeper will end any temporary full charge or
  discharge."

### Set CellKeeper Manage Charging

`changeSettings { $0.isManagementEnabled = isOn }`, passing
`handledAdoptionCount` as the toggle does. Off needs no status.

- Off, was on: macOS's Charge Limit: "CellKeeper saved Manage charging as
  off and will give back your own macOS Charge Limit if it changed it. The
  menu shows when macOS confirms it." Otherwise: "CellKeeper saved Manage
  charging as off and will request normal charging." + Simulated /
  no-requests phrase. Notes: "This also ends the temporary full charge." /
  "… the discharge to the limit."; an armed schedule: "The scheduled full
  charge stays set but cannot start while Manage charging is off."
- On, was off: macOS's Charge Limit: "CellKeeper saved Manage charging as on
  and will request a macOS Charge Limit of 80%. The menu shows when macOS
  confirms it." Otherwise: "CellKeeper saved Manage charging as on, with
  its 80% limit." + Simulated / no-requests phrase. Notes as for Set
  CellKeeper Limit, plus a limit that is not a step ("83% cannot be set
  with macOS's Charge Limit; until you choose one of its values, your own
  limit stays in effect.", the menu's text).
- Already in that state: "Manage charging is already on." / "… off."
- If the controller then keeps management off (the adoption marker cannot
  be removed), the menu and Settings show it exactly as after the toggle
  (the banner comes from the controller's refusal, not the intent's), and
  Get CellKeeper Status reports it.

### Get CellKeeper Status

Needs the first status. Reports the latest status as it is; it never sends
an evaluation (that could issue backend requests). Returns a
`TransientAppEntity`, "CellKeeper Status", whose values come from a pure
Kit struct (`ShortcutsStatus`):

| Property | Type | Value |
|---|---|---|
| Battery charge | Int, optional | macOS's percentage; empty with no battery or unknown charge |
| Charging status | Text | What macOS reports, `ChargingStatus.description` ("charging", "not charging", "fully charged", …) |
| State | Text | `PolicyState.description` ("not managing charging", "holding at the limit", …); "control backend faulted" while faulted; with ", not applied" for a backend that accepts no requests, as the menu's "Policy (not applied)" |
| Control | Text | `ControlStatement.text(for:)`; for macOS's Charge Limit, "macOS reports its Charge Limit at 80%" / "macOS's Charge Limit could not be read" / the no-requests phrase |
| Simulated | Bool | `isControlSimulated` |
| Charge limit | Int | CellKeeper's setting |
| Manage charging | Bool | CellKeeper's setting |
| Checked at | Date, optional | `lastEvaluation` |

Display: title "Battery 76%", subtitle the state. Dialog: "Battery 76%,
not charging. CellKeeper: holding at the limit of 80%. <Control>. Checked
at 14:32." For example "… Simulated: CellKeeper records what it would do;
nothing on your Mac changes." or "CellKeeper would be charging to the
limit of 80%, but Read-only is selected, so CellKeeper changes nothing."

The plain words are D89's, reused rather than written again:
`ChargingStatus.description` ("not charging"), `PolicyState.description`
("holding at the limit", "temporary full charge", "fail-safe", …) and, in
the other actions' results, `ChargeControlMode.description` ("a macOS
Charge Limit of 80%", "normal charging"). The properties carry them as they
are (lower case, as in the activity log).

## Confirmations

Mirror the UI exactly. None of the five commands has a confirmation in the
UI today (checked: the Manage charging toggles, the limit slider, picker
and steppers, "Charge to 100% once" and "Cancel" call `AppModel` directly;
the only confirmations are discharge, choosing the native backend, "My
Charge Limit is 100%" and discarding the record, all out of scope). So no
action calls `requestConfirmation`. Turning management off and stopping a
full charge are moves toward macOS defaults and never would.

## Launch and lifecycle

- `openAppWhenRun` is not declared: its default is false, and it is
  deprecated from macOS 26 in favour of `supportedModes` (26.0+, which we
  cannot declare with a macOS 14 target). Nothing opens a window.
- When CellKeeper is not running, macOS launches it to run the action.
  It then starts exactly as when opened: `applicationDidFinishLaunching`
  calls `model.start()` (restoring an earlier session's record of the
  user's Charge Limit first, then managing charging with the saved
  settings and backend), and it stays running in the menu bar. Running any
  action, including Get CellKeeper Status, can therefore start CellKeeper
  managing charging, as opening it would (owner question 5).
- **Never before `start()`.** `AppDelegate` attaches the model to a
  main-actor `ShortcutsActionHost` right after `model.start()`. An action
  waits for it at most 10 s (a bounded wait, `FirstValue` in Core); the
  actions that need a status then wait for the first one within the same
  10 s. A launch evaluation that is itself running the user's shortcut (a
  restore at launch) can take longer; the action then refuses rather than
  wait.
- Quitting: `stopForTermination()` sets `isTerminating`; actions refuse.

## Threading, and why nothing deadlocks

`perform()` is `@MainActor`. It awaits only the bounded wait above; the
rest is synchronous `AppModel` work (validate, save to `UserDefaults`,
`commandSink.yield`). It never awaits the command queue, the controller or
the backend. Hence:

- A user's shortcut that calls an action while CellKeeper is running the
  user's "CellKeeper Set Charge Limit" shortcut gets its answer at once:
  the main actor is free (the backend runs on the controller and process
  runner), and the action does not wait for the run.
- If that shortcut (misconfigured) calls Set CellKeeper Limit with the same
  value, nothing is sent (`unchanged`); with another value, the restricting
  budget (≥ 60 s apart, ≤ 20 per hour) bounds the loop.
- If Shortcuts were to hold CellKeeper's `shortcuts run` until the user's
  shortcut finishes while that shortcut waits for Get CellKeeper Status on
  a cold launch, the 10 s bound breaks the wait.

## Where code lives

- App target (App Intents metadata is extracted from the app's own module;
  intents in a Swift package need `AppIntentsPackage`, which also needs the
  package's metadata built, not worth it for five thin types):
  `CellKeeper/ShortcutsActions.swift`: the five intents, the status entity,
  the error type, `ShortcutsActionHost`, the `AppShortcutsProvider`. Each
  `perform()` is a few lines: get the model, call one `AppModel` function,
  turn its result into a dialog or a thrown refusal.
- `AppModel`: the shared functions above; `isTerminating`.
- `CellKeeperApp.swift`: attach the model after `start()`.
- `MenuBarView` / `SettingsView`: use the shared refusal and label
  functions.
- Kit, `ShortcutsActionWording.swift`: `ShortcutsActionWording`,
  `FullChargeStart`, `ChargeLimitChoices.refusal(for:)`, `ShortcutsStatus`.
- Core, `Support/FirstValue.swift`: a main-actor value awaited with a bound
  (provided once; waiters resume with it, or nil at the bound or on
  cancellation), with an injected sleep for tests.

## Availability (checked in the macOS 27.0 SDK's AppIntents swiftinterface)

- `AppIntent`, `IntentDialog`, `ProvidesDialog`, `ReturnsValue`,
  `TransientAppEntity`, `EntityProperty(title:)`, `Bool.IntentDisplayName`,
  `AppShortcutsProvider`: macOS 13.0. `AppShortcut(intent:phrases:
  shortTitle:systemImageName:)`: macOS 14.0 (the form without them is
  deprecated from 14). `supportedModes`: 26.0. `openAppWhenRun`: deprecated
  26.0 (not declared).
- **Not used:** `AppDependencyManager` / `@Dependency` (macOS 13). Its
  `add` overloads carry `@Sendable` and `@_silgen_name` in the 27 SDK, so
  their shape may differ in the Xcode 16.0 SDK; reading a dependency that
  was never added fails at run time; and it does not express "after
  `start()`". A main-actor reference attached after `start()` does all
  three plainly.
- Swift 6: titles are `static let …: LocalizedStringResource` (Sendable).
  `TypeDisplayRepresentation` is not `Sendable`, so the entity's type name
  is a computed `static var`; the build must show its metadata extracted.
- Only Xcode 27.1 is installed here. Xcode 16.0 and 26.6 are covered by CI
  (16.0 without warnings as errors); nothing above is newer than macOS 14.
- No entitlement: App Intents need none (Siri's entitlement is for SiriKit).
  The CI entitlement check stays unchanged.

## App Shortcuts (Siri, Spotlight)

One `AppShortcutsProvider` with Get CellKeeper Status only: phrases "Get
\(.applicationName) status" and "What is \(.applicationName) doing",
short title "Status", symbol `batteryblock`. Control actions get no phrase
in v1: a phrase works without any setup, and a misheard phrase should not
change charging (owner question 4). All five actions are available in the
Shortcuts app regardless.

## Logging

Each action logs one notice to the unified log (`app` category), with the
values only, e.g. "Shortcuts action set the charge limit to 80% (saved)" or
"… refused: <refusal>". The activity log shows the resulting settings
change or override event as it does for the UI, without the source (owner
question 6).

## Testing

- Kit (Swift Testing), `ShortcutsActionWordingTests`: every result and
  refusal above, per backend (Simulated, Simulated helper, Read-only,
  macOS's Charge Limit available, unavailable, faulted, "no limit"
  awaiting confirmation; the Simulated helper deferring to macOS's limit),
  management on/off, override running; refusals equal the Settings texts
  they reuse (computed from `SettingsIssue`, not copied); `FullChargeStart`
  against a table of the menu's former predicate plus the override cases;
  `ShortcutsStatus` values; no text contains an unavailability reason
  (a status with a distinctive reason string is checked).
- Core, `FirstValueTests`: value before the wait, provided during it, the
  bound reached (injected sleep, no real timing), cancellation, several
  waiters.
- Build: Debug and Release with warnings as errors; the built app's
  `Contents/Resources/Metadata.appintents/` lists the five actions, the
  entity and the App Shortcut; signed entitlements unchanged.
- Not unit-testable (no app test target): the intents and `AppModel` glue,
  kept to a few lines each.

## Needs the owner (cannot be verified here)

Running anything in the Shortcuts app or by Siri needs clicks on the
owner's Mac, which the rules forbid here. To check, with the isolated
preview build (`…CellKeeper.preview`, Simulated backend; Shortcuts may list
it as a second "CellKeeper"):
1. The five actions and their titles in the Shortcuts library; search
   "limit" and "CellKeeper" (no confusion with Apple's Set Charge Limit or
   the user's shortcuts).
2. Each action's dialog and refusals; the status value's properties in a
   later action.
3. With CellKeeper not running: an action launches it, it stays in the menu
   bar, and the action succeeds (or refuses after 10 s).
4. The Siri / Spotlight phrase.
5. Later, with the native backend: a shortcut that calls Set CellKeeper
   Limit while CellKeeper runs "CellKeeper Set Charge Limit" (no hang).

## Provisional decision rows

| # | Decision | Rationale |
|---|---|---|
| D90 | Five App Intents in the app target (set the limit, start a temporary full charge, stop a full charge or discharge, set Manage charging, get the status), each calling the same `AppModel` function as the UI, with the UI's preconditions and validation (`ChargeLimitChoices.refusal`, `FullChargeStart.refusal`, `changeSettings`). A refusal is thrown and never sets the Settings banner. Titles contain "CellKeeper" and not "Charge Limit" | One path for every change; no clamping; no confusion with Apple's Set Charge Limit or the user's "CellKeeper Set Charge Limit" shortcut |
| D91 | Actions return once the change is saved and queued, never awaiting the command queue, controller or backend; results say what CellKeeper saved or will request, from fixed phrases (no reasons or error messages), and say when Manage charging is off, control is simulated, or the backend accepts no requests | A native request can take tens of seconds, and a user's shortcut calling an action while CellKeeper runs theirs must not deadlock; say only what CellKeeper knows |
| D92 | No action asks for confirmation, because none of their UI commands does; discharge, backend switches, the schedule, notifications and the native backend's confirmations stay UI-only | Confirmation parity with the UI, no more, no less |
| D93 | The model is attached for actions only after `start()`; an action waits at most 10 s for it (and, where it needs one, for the first status), then refuses; actions refuse while quitting; `openAppWhenRun` keeps its default (false). Launching for an action is a normal start | No action can run before start-up (and its restore); a bounded wait cannot deadlock |
| D94 | Get CellKeeper Status reports the latest status with its time and never evaluates; it returns a transient entity (charge, macOS's charging status, state, control, simulated, limit, Manage charging, checked at) | A read must not cause backend requests |
| D95 | Stop always queues the cancel and succeeds when nothing runs; it ends a discharge too | A move toward macOS defaults never fails; the menu's Cancel ends either |
| D96 | App Shortcuts: Get CellKeeper Status only | A phrase needs no setup; a misheard one must not change charging |

## Owner questions (with recommendations)

1. **Titles.** Set CellKeeper Limit; Start CellKeeper Full Charge; Stop
   CellKeeper Full Charge or Discharge; Set CellKeeper Manage Charging; Get
   CellKeeper Status. *Recommend as proposed.* (Alternatives for the first:
   "Change CellKeeper Limit"; avoid "Set CellKeeper Charge Limit", the
   user's shortcut name in another order.)
2. **Set the limit while Manage charging is off?** The menu and Settings
   disable the limit controls while it is off. *Recommend allowing it*: the
   setting is validated exactly as in Settings, nothing is applied, the
   result says so, and a shortcut can set the limit before turning
   management on (with macOS's Charge Limit, turning on first would apply
   the old limit and then hit the 60 s budget for the new one).
   Alternative: refuse with "Manage charging is off. Turn it on to change
   the limit."
3. **Should Stop also end a discharge?** *Recommend yes* (the menu's Cancel
   does; it moves toward macOS defaults), with the title saying so.
4. **App Shortcuts:** *recommend Get CellKeeper Status only*; control
   actions only in the Shortcuts app.
5. **Launch by an action** starts CellKeeper fully (it manages charging
   with the saved settings and stays running). *Recommend accepting it*,
   stated in the README: an app-target action cannot run without the app,
   and refusing would not stop the launch.
6. **Activity log source.** *Recommend v1 without it*: the unified log
   names the action; the activity log shows the change as for the UI.
   Naming the source there needs a source parameter on the controller's
   commands (a follow-up if wanted).
