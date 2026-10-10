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
- The hardware gates are unchanged. No private mechanism is tried until a
  dedicated test Mac is available, and no privileged helper ships without an
  Apple Developer ID.
- The open items of milestone 3 wait until phase 4a is done.

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
and one restart. Still open: shutdown observations, and schedules (below).
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

## Milestone 3 — Diagnostics and observability (after phase 4a)

- Diagnostics view and exportable report (no identifiers): telemetry,
  decisions, OS build, model identifier. Done: Settings › Activity › Copy
  Diagnostics copies a plain-text report (#20). Still open: a dedicated
  diagnostics view and saving the report to a file.
- `ProcessInfo` thermal and Low Power Mode state in the UI (system-wide, not
  battery temperature). Done: shown in the menu's Battery details (#19).
- Unplug/replug and sleep/wake observation runs on real hardware to measure
  notification cadence (research 01, open question 1).

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
on, so two limits never compete.

### Phase 4a — Foundations without hardware writes (in progress)

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
  installed or embedded). Still open: wiring in the XPC listener.
- The `safety.md` preconditions that do not depend on the mechanism:
  debounce and dwell (6); coexistence with macOS's Charge Limit and
  Optimized Battery Charging (7); an uninstall flow that restores defaults
  (9); a documented recovery procedure (research rule R31).
- UI: limits at any level with the helper backend, honest status
  (Simulated or Unavailable), and guidance for turning macOS's Charge Limit
  off.

### Phase 4b — Signed helper (needs an Apple Developer ID)

Tracked in [issue #57](https://github.com/SaltedTan/CellKeeper/issues/57).

- Register the daemon with `SMAppService` and guide the user through
  approving it. Non-sandboxed, Hardened Runtime, notarized app and helper
  ([research notes 04](research/04-privileged-helper.md) and
  [05](research/05-distribution-and-signing.md)).
- Release code-signing requirements checked with `codesign --verify -R`;
  separate identities for development builds.
- Installation, update and uninstall verified on a clean Mac.

### Phase 4c — A verified mechanism (needs a dedicated test Mac)

Tracked in [issue #58](https://github.com/SaltedTan/CellKeeper/issues/58).

Hardware experiments with private mechanisms must not run on a daily-use
Mac, and the maintainer currently has only one (owner decision, confirmed
2026-10-09).

- Follow research note 02 §7: a read-only, allowlisted capability probe,
  then single reversible writes, then the persistence matrix. Evaluate
  Apple's private `ChargeInhibit` power assertion first: Apple's published
  source releases it when the owning process exits, and the test Mac must
  show whether it works, and is released, on shipping Apple silicon. Try the
  SMC adapter-cut key only if a genuine need remains.
- Record the results per Mac model and firmware in `docs/research/`. Add a
  verified mechanism to the helper's allowlist, with behavioural
  verification in independent telemetry (`safety.md` precondition 5) and a
  tested independent recovery (precondition 11).
- Then offer the backend as experimental and opt-in, per verified model,
  with every precondition in `safety.md`.

Blocked until both exist: a dedicated test Mac with no other battery tools,
and an Apple Developer ID.

## Later

- Notifications (limit reached, temperature pause, fault, override ended).
- Launch at login (`SMAppService.mainApp`).
- App Intents / Shortcuts actions for CellKeeper's own controls.
- Scheduling of overrides and limits (monotonic-clock expiries, re-evaluated
  on clock change and wake).
- Calibration workflow (never below 15%, only within 10–40 °C, user-initiated
  and abortable).
- Battery temperature, if a public source returns or a reviewed source is
  verified.
- Distribution: notarized DMG on GitHub Releases, Homebrew cask, optional
  update mechanism.
- Localization and accessibility review.
- A tidier Settings window ([issue #4](https://github.com/SaltedTan/CellKeeper/issues/4)).

## Explicit non-goals

- Mac App Store distribution of a build with privileged control.
- Charge control on Intel Macs.
- Any general-purpose privileged interface.
