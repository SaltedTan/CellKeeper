# CellKeeper roadmap

Milestones are ordered by risk: everything that can be done with public,
read-only, or simulated interfaces comes before anything that changes
hardware state. Dates are deliberately omitted.

## What the research changed

- **macOS 26.4+ on Apple silicon has a native Charge Limit** (80–100%, set in
  System Settings or via a "Set Battery Charge Limit" Shortcuts action). It is
  the only *supported* charge control on current Macs.
- **No public API** inhibits charging or forces discharge, and the
  undocumented SMC keys community tools relied on are reportedly gated on
  macOS 27 firmware, even for root.
- Therefore CellKeeper's first real control path should **cooperate with**
  the native limit, and anything below 80% or "discharge to target" stays
  experimental until a mechanism is verified on real hardware.

## Current priority

Decided by the owner on 2026-10-09: **CellKeeper's own charge control**
(milestone 4) comes first. CellKeeper will stop and resume charging itself,
so a limit can be set at any level from 20 to 100%, not only at macOS's 80,
85, 90, 95 and 100% steps.

- Everything that needs no hardware write is built first (phase 4a).
- No privileged helper ships to other Macs without an Apple Developer
  ID. For the maintainer's own Mac, the owner chose on 2026-10-19 to sign
  local helper builds with a free Apple ID (Personal Team, Apple
  Development certificate); whether `SMAppService` registers a daemon
  signed that way is unverified, and a manual `sudo` launch-daemon install
  is the fallback. Private
  mechanisms are tried only on a test Mac: on 2026-10-19 the owner decided
  that the maintainer's Mac is that test Mac, and authorized one experiment
  on it, an owner-run test of Apple's private `ChargeInhibit` power
  assertion (phase 4c), and after its result one more, of the private
  `DisableInflow` assertion. After both showed no effect, the owner
  authorized SMC access on this Mac on 2026-10-20 for one mechanism, the
  adapter cut (`CHIE`), in a test the owner makes by hand with an existing
  open-source tool; agents never read or write SMC keys.
- Phase 4a was completed on 2026-10-11, and its follow-ups on
  2026-10-17: the request pacer (#67) and three timing-sensitive tests
  ([issue #1](https://github.com/SaltedTan/CellKeeper/issues/1)). The
  other tests that depended on real time were fixed by 2026-10-18
  ([issue #74](https://github.com/SaltedTan/CellKeeper/issues/74)). The
  removal button and in-app recovery help moved to phase 4b (owner
  decision, 2026-10-18): until a helper is registered, there is nothing
  real to remove. Phase 4b's distributable form stays blocked on an
  Apple Developer ID; a local build for the maintainer's Mac can use the
  free Personal Team signing. Phase
  4c has had a test Mac since 2026-10-19; its first step, the
  `ChargeInhibit` probe, ran that day and showed no effect on charging.
  Its second, a `DisableInflow` probe, ran on 2026-10-20 and showed no
  effect either. The only mechanism left that is reported to work here,
  the SMC adapter cut, needed new owner decisions (SMC writes and the
  clean-room rule); the owner made them on 2026-10-20, and the owner's
  manual test, observed by the probe, ran that day: the cut worked, by the
  owner's account that the adapter stayed plugged in
  ([research note 11](research/11-smc-adapter-cut.md) §10). The owner
  then decided not to use it, because a cut runs the Mac from its battery
  instead of stopping charging, and an owner-run read showed the older
  charge-inhibit keys empty on this firmware. On this Mac, macOS's own
  Charge Limit (80–100%) is the only verified, usable control found so
  far that stops charging on adapter power. Any further experiment (for
  example the firmware-limit keys, which were not read) needs new
  evidence and new owner decisions.
- While both were blocked, the owner approved three smaller features on
  2026-10-18, all done: Save Diagnostics… (milestone 3), opt-in
  notifications (milestone 3) and a one-shot scheduled full charge
  (milestone 2).
- On 2026-10-19 the owner approved four more, all done: Shortcuts
  actions, the diagnostics view (milestone 3), a weekly scheduled full
  charge and an accessibility review.

## Milestone 1 — Architecture and vertical slice ✅

- Swift package (`CellKeeperCore`, `CellKeeperKit`) and menu-bar app.
- Read-only telemetry (IOPowerSources + allowlisted IORegistry), sandboxed.
- Pure, deterministic charging policy with hysteresis, temporary full charge,
  temperature protection, sleep/unplug handling, rate limiting, fail-safe
  states.
- Controller with read-back, fallback to normal, and fault handling.
- Simulated and read-only backends; honest UI status.
- Unit tests, CI, research notes, safety model.

## Milestone 2 — Native Charge Limit backend (80–100%, public interfaces only)

Decided 2026-10-06: CellKeeper's first real control builds on Apple's
native Charge Limit.

Status: implemented as an experimental, opt-in backend
(`NativeChargeLimitBackend`; [research note 08](research/08-native-charge-limit.md)).
Done: the policy computes the native limit; ownership with restore on quit,
management off, backend switch and failure; Shortcuts write path verified
from the App Sandbox with no new entitlements; read-back through
`pmset -g battlimit` (read-only); rate limiting and logging; UI for
80/85/90/95/100 with unsupported features hidden; a limit changed in
System Settings is kept as the user's own and management turns off (owner
decision). Observed on the maintainer's Mac: the walk-through, one sleep run
and one restart. A one-shot scheduled full charge is implemented (below).
Still open: shutdown observations.
Candidate follow-up: confirm changes through Shortcuts' documented "Get
charge limit" action instead of `pmset -g battlimit` (note 08, O18).

- Model "OS-managed limit" as a backend capability: the policy computes a
  desired native limit (80/85/90/95/100) instead of toggling charging.
- Ownership: record the user's own native limit before changing it, and
  restore *that* value on release rather than assuming 100%.
- Apply it through a user-installed Shortcut run by the documented
  `shortcuts` command-line tool; verify the sandbox can launch it, or document
  the required entitlement change.
- Detect and display whether macOS is holding the charge (Charge Limit,
  Optimized Battery Charging, battery health management) from public signals;
  label the cause "not reported" when unknown.
- Verify on the maintainer's Mac, which already uses the native limit: does
  it hold across sleep, restart, and shutdown? Does the Shortcuts action
  accept a variable? This is a supported, user-level setting, so testing it
  on a daily-use Mac is acceptable.
- Use it for schedules ("100% before travel on Friday") without root.
  *Done as a one-shot scheduled full charge* (owner approval 2026-10-18):
  one schedule, a start up to 7 days ahead and an end 1–48 h later, that
  starts the existing temporary full charge (see `architecture.md`,
  "Scheduled full charge"). It works with every backend, simulated where
  the backend is, and starts only while the Mac is awake and CellKeeper
  is running. A weekly full charge followed (owner approval 2026-10-19;
  see "Weekly full charge" there).

## Milestone 3 — Diagnostics and observability (after phase 4a)

- Diagnostics view and exportable report (no identifiers): telemetry,
  decisions, OS build, model identifier. Done: Settings › Diagnostics
  shows the report's sections in plain words (D99); there, Copy
  Diagnostics copies a plain-text report (#20), and Save Diagnostics…
  saves it to a text file the user chooses (D76).
- `ProcessInfo` thermal and Low Power Mode state in the UI (system-wide, not
  battery temperature). Done: shown in the menu's Battery details (#19).
- Unplug/replug and sleep/wake observation runs on real hardware to measure
  notification cadence (research 01, open question 1).
- Notifications (limit reached, temperature pause, fault or an unconfirmed
  restore, override ended), opt-in. Done: Settings › Charging, off by
  default; each says only what CellKeeper confirmed, and that simulated
  controls change nothing (architecture, "Notifications").

## Milestone 4 — CellKeeper's own charge control: limits at any level (current priority)

Tracked in [issue #1](https://github.com/SaltedTan/CellKeeper/issues/1).
CellKeeper enforces the limit itself. Settings accept every whole
percentage from 20 to 100. Below 100%, CellKeeper stops charging at the
limit and lets it charge again at the resume threshold; at 100%, it removes
its own restriction. Temperature protection and discharge sessions work as
the policy already defines them. The policy and controller already do this
with the simulated backend. What is
missing is a mechanism that changes charging on real hardware, and the
privileged helper that would run it.

No public mechanism exists; every candidate is private and needs root
([research note 02](research/02-charging-control-apple-silicon.md)). The
owner's long-term direction (2026-10-06): CellKeeper controls charging
itself, and the user turns macOS's own Charge Limit off. The app should then
guide the user through turning it off, and detect it if it is turned back
on: while it is on, CellKeeper withholds new restrictions and asks for the
release of existing holds until a read-back confirms it.

### Phase 4a — Foundations without hardware writes (done)

Needs no test Mac and no Developer ID. Nothing in this phase writes to
hardware.

- Helper logic (`CellKeeperHelperCore`), implemented and unit-tested
  against a simulated charge control: a closed vocabulary of typed
  operations; per-control leases; rate limits; the helper's own guards
  (telemetry freshness, battery floor, AC loss, adapter presence, thermal
  pressure, sleep); restore on start and on exit; detection of changes made
  by someone else.
- An app-side `ChargingBackend` that drives the helper: leases renewed only
  by successful policy evaluations, and a read-back after every change. With
  an in-process transport, the app can offer a **Simulated helper** that
  shows limits at any level without changing anything.
- An XPC transport with code-signing requirements on both sides, tested over
  an anonymous listener in `swift test`.
- The `CellKeeperHelper` daemon executable and its launchd property list,
  with SIGTERM and sleep handling and its own power reading. It contains no
  hardware control: it reports that it controls nothing, writes nothing, and
  never reports hardware defaults as restored. Its logic is tested without
  registering a privileged service; installing and distributing it belong
  to phase 4b. Done: the daemon host (`CellKeeperHelperDaemon`) and
  executable, with restore at start, SIGTERM, acknowledged sleep, its own
  power reading, the activation history file and the property list (not
  installed or embedded). The daemon serves its engine over the
  authenticated XPC transport, and refuses to listen when built without a
  team identifier.
- The `safety.md` preconditions that do not depend on the mechanism:
  debounce and dwell (6, done); coexistence with macOS's Charge Limit and
  Optimized Battery Charging (7: done for macOS's Charge Limit with
  backends that switch charging themselves, which ask for normal charging,
  withhold their restrictions and ask the user to turn it off while it is
  on or its report cannot be read; coexistence with Optimized Battery
  Charging and battery health management is partial and unverified, as
  they are visible only through that report); an uninstall flow that
  restores defaults (9, done in logic: the removal flow, `HelperRemoval`
  and `ChargeController.removeHelper`, confirms normal charging, then the
  helper's restore, and only then unregisters, tested against fakes, and
  the daemon restores defaults on `restoreDefaultsAndExit` and SIGTERM);
  a documented recovery procedure (research rule R31, done in
  `safety.md`). Still to come for 9, in phase 4b: its button and the
  real unregistration.
- UI: limits at any level with the helper backend, honest status
  (Simulated or Unavailable), and guidance for turning macOS's Charge Limit
  off. Done: the menu and Settings › Control say in one line what controls
  charging (the Simulated helper, deferring to macOS's Charge Limit, or
  Unavailable with the reason); step-by-step guidance for turning macOS's
  Charge Limit and Optimized Battery Charging off, from the menu's notice
  and in Settings › Control, with Open Battery Settings and Check Again;
  and every whole percentage from 20 to 100 with CellKeeper's own control.
  Still to come, in phase 4b: a way to remove the helper, after which the
  app switches to the Simulated backend, and a backend choice for the real
  helper.

### Phase 4b — Signed helper (needs an Apple Developer ID)

Tracked in [issue #57](https://github.com/SaltedTan/CellKeeper/issues/57).
Distribution needs a Developer ID. For the maintainer's own Mac only, the
owner decided on 2026-10-19 to use a free Personal Team (Apple
Development) signature for local helper builds first ([research note 04](research/04-privileged-helper.md)
§10 Q1: unverified with `SMAppService`; fallback: a manual `sudo`
launch-daemon install).

- Register the daemon with `SMAppService` and guide the user through
  approving it. Non-sandboxed, Hardened Runtime, notarized app and helper
  ([research notes 04](research/04-privileged-helper.md) and
  [05](research/05-distribution-and-signing.md)).
- Release code-signing requirements checked with `codesign --verify -R`;
  separate identities for development builds.
- Installation, update and uninstall verified on a clean Mac. Uninstall
  supplies the `SMAppService` implementation of `HelperRegistration`
  ("already unregistered" errors count as gone), and verifies steps 3 and
  4 of the recovery procedure in `safety.md` (whether turning off the
  background item and `launchctl bootout` stop the helper, and whether its
  exit restore then confirms defaults).
- A button in Settings that removes the helper through the removal flow
  built in phase 4a (`ChargeController.removeHelper`), with in-app help
  for the recovery procedure in `safety.md`. After a removal the app
  switches to the Simulated backend. Moved here from phase 4a's
  follow-ups (owner decision, 2026-10-18): until a helper is registered,
  the removal flow reports "nothing to remove" and leaves the Simulated
  helper running.

### Phase 4c — A verified mechanism (on a test Mac)

Tracked in [issue #58](https://github.com/SaltedTan/CellKeeper/issues/58).

Until 2026-10-19, hardware experiments with private mechanisms were not to
run on a daily-use Mac, and the maintainer has only one (owner decision,
confirmed 2026-10-09). On 2026-10-19 the owner decided to use that Mac
(Mac16,1, Apple M4, macOS 27.0.1, firmware 20457.1.29) as the test Mac,
once AlDente's helper is removed, and authorized one experiment: a test of
`ChargeInhibit` that the owner runs with `sudo`. SMC reads and writes, the
adapter cut, and any other private mechanism each need a separate owner
decision after that result. After it, the owner authorized one more
owner-run experiment, with Apple's private `DisableInflow` assertion, and
after that one, on 2026-10-20, SMC access for the adapter cut (`CHIE`),
with a narrow clean-room exception for the facts it needs
([`CONTRIBUTING.md`](../CONTRIBUTING.md) §1).

- **First step: the `ChargeInhibit` probe**
  ([research note 09](research/09-charge-inhibit-probe.md)). A standalone
  tool in `Tools/charge-inhibit-probe`, outside the app: `check` reads the
  preconditions without privileges; `sudo … run` holds one `ChargeInhibit`
  assertion for 60 s with a timeout, releases it, and reports whether
  charging stopped and resumed. Nothing ships from it. *Run by the owner on
  2026-10-19: no effect observed.* powerd accepted and released the
  assertion, and every reading while it was held showed charging, so
  `ChargeInhibit` stays unverified and is not added to the helper's
  allowlist.
- **Second step: the `DisableInflow` probe**
  ([research note 10](research/10-disable-inflow-probe.md)). The same
  tool, now run with `--assertion disable-inflow`: it holds one
  `DisableInflow` assertion for 180 s with a timeout and tells three
  outcomes apart: no effect, charging stopped on adapter power, and the
  adapter's power cut, with the Mac running from its battery while plugged
  in. Its criteria now need readings of at least two battery updates,
  which came a minute apart on this Mac. Read literally, Apple's published source predicts no effect on
  Apple silicon (note 10 §3). *Run by the owner on 2026-10-20: no effect
  observed.* powerd accepted and released the assertion, and every reading
  while it was held, over three battery updates, showed adapter power and
  charging, so `DisableInflow` stays unverified and is not added to the
  helper's allowlist.
- **Third step: the SMC adapter cut, by hand**
  ([research note 11](research/11-smc-adapter-cut.md)). The owner reads
  and writes the one SMC key `CHIE` with an existing open-source tool,
  smcFanControl's `smc` command (GPL-2.0-or-later), built and run outside
  the repository. CellKeeper's probe, run without `sudo` as
  `watch --mechanism manual-adapter-cut`, only observes: it opens no SMC
  connection, never runs the tool, tells the owner what to type and when,
  and judges the readings with note 10's rules for an adapter cut. The
  start rule: before the cut, the owner's read must show `CHIE` as `00`
  (type `hex_`, one byte); on anything else, the test stops and nothing
  is written. Then the owner writes `08`, reads it back, and after the
  hold (180 s) writes `00` and reads it back; no other value is written.
  A written key is not released when anything exits, so the restore is
  the owner's; the probe prints the time to restore by and rings until
  the restore is confirmed. The key's values come from third-party
  open-source projects under the owner's clean-room exception, and are
  claims until this test. *Run by the owner on 2026-10-20: the adapter's
  power was cut.* With `CHIE` at `08` the adapter stopped being reported
  before the owner's read-back, and from about 76 s after the cut mark
  until the restore the Mac ran from its battery with the adapter plugged
  in and about 0.5 W of input; `00` brought adapter power and charging
  back. The cut also made macOS report no adapter at all, so the probe's
  verdict is `inconclusive` by its rule, and the owner's account that the
  adapter stayed plugged in decides it (note 11 §10). It is not added to
  the helper's allowlist. (A first design, in which the probe wrote
  `CHIE` itself, was replaced on 2026-10-20: an
  automated safety check stopped an agent's response as it began writing
  the SMC client code, and the lead decided not to route around it.)
  *Not used (owner decision, 2026-10-20):* CellKeeper's purpose is to stop
  charging at a limit while the Mac runs from its adapter, and a cut does
  the opposite while it is set. So no SMC write layer and no persistence
  run are needed. The owner also read the older charge-inhibit keys
  (`CHTE`, `CH0B`, `CH0C`) once, read-only, with the same tool: each
  printed `no data` (note 11 §10).
- Follow research note 02 §7: a read-only, allowlisted capability probe,
  then single reversible writes, then the persistence matrix. Evaluate
  Apple's private `ChargeInhibit` power assertion first: Apple's published
  source releases it when the owning process exits, and the test Mac must
  show whether it works, and is released, on shipping Apple silicon. Try the
  SMC adapter-cut key only if a genuine need remains. (Both assertions
  showed no effect on this Mac; the adapter cut, the third step above,
  worked but is not used, and the inhibit keys read empty.)
- Record the results per Mac model and firmware in `docs/research/`. Add a
  verified mechanism to the helper's allowlist, with behavioural
  verification in independent telemetry (`safety.md` precondition 5) and a
  tested independent recovery (precondition 11).
- Then offer the backend as experimental and opt-in, per verified model,
  with every precondition in `safety.md`.

There has been a test Mac since 2026-10-19 (the maintainer's, once no
other battery tool is installed). Distributing a helper backend to other
Macs still needs an Apple Developer ID (phase 4b); a local build on the
maintainer's Mac can use the free Personal Team signing (unverified with
`SMAppService`; a manual `sudo` launch-daemon install is the fallback).

## Later

- Launch at login (`SMAppService.mainApp`).
- App Intents / Shortcuts actions for CellKeeper's own controls. *Done*
  (owner approval 2026-10-19): five actions, the same commands as the menu
  (set the limit, start or stop a temporary full charge, turn Manage
  charging on or off, get the status), and a Siri and Spotlight phrase for
  the status only (see `architecture.md`, "Shortcuts actions"). Not yet
  tried in the Shortcuts app on a Mac. A "schedule a full charge" action is
  left until someone asks: on macOS 26+ a Shortcuts automation at a time
  of day can run Start CellKeeper Full Charge.
- Recurring schedules. *Done as a weekly full charge* (owner approval
  2026-10-19): one weekly schedule of the temporary full charge (the days,
  a local start time, 1–48 hours) alongside the one-shot schedule, in
  floating local time with RFC 5545's rules for skipped and repeated times
  and a record of the last occurrence handled (see `architecture.md`,
  "Weekly full charge"). Still later: scheduled limits, other recurrences,
  more than one weekly schedule, and skipping one occurrence.
- Calibration workflow (never below 15%, only within 10–40 °C, user-initiated
  and abortable). *Designed as a guided calibration with no SMC writes*
  ([research note 12](research/12-guided-calibration.md), 2026-10-21): the
  owner unplugs and plugs in when asked, and the Mac rests asleep or shut
  down at about 20%. The owner approved the design on 2026-10-21; it is
  being built.
- Battery temperature, if a public source returns or a reviewed source is
  verified.
- Distribution: notarized DMG on GitHub Releases, Homebrew cask, optional
  update mechanism.
- Accessibility review. *Done* (owner approval 2026-10-19): the menu and
  every Settings tab audited for VoiceOver, the keyboard, contrast, colour,
  motion and announcements, and the findings fixed (see
  [accessibility-review.md](accessibility-review.md), D109). Still to try
  on a Mac with VoiceOver, Full Keyboard Access and Increase Contrast on.
- Localization.
- A tidier Settings window ([issue #4](https://github.com/SaltedTan/CellKeeper/issues/4)).

## Explicit non-goals

- Mac App Store distribution of a build with privileged control.
- Charge control on Intel Macs.
- Any general-purpose privileged interface.
