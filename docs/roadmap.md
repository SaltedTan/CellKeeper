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

## Milestone 3 — Diagnostics and observability

- Diagnostics view and exportable report (no identifiers): telemetry,
  decisions, OS build, model identifier.
- `ProcessInfo` thermal and Low Power Mode state in the UI (system-wide, not
  battery temperature). Done: shown in the menu's Battery details (#19).
- Unplug/replug and sleep/wake observation runs on real hardware to measure
  notification cadence (research 01, open question 1).

## Milestone 4 — Charge limits below 80% (gated)

Tracked in [issue #1](https://github.com/SaltedTan/CellKeeper/issues/1). No public
mechanism exists; every candidate is private and needs root. This milestone
is **blocked** until all of the following are available:

- **A dedicated test Mac** with no other battery tools. Hardware experiments
  with private mechanisms must not run on a daily-use Mac, and the maintainer
  currently has only one.
- **A verified mechanism.** Follow research note 02 §7 (read-only,
  allowlisted capability probe, then single reversible writes, then the
  persistence matrix). Evaluate Apple's private `ChargeInhibit` power
  assertion first (released automatically when the owning process exits),
  and the SMC adapter-cut key only if a genuine need remains.
- **An Apple Developer ID**, because a privileged helper must be signed and
  notarized to be installed reliably.

Then:

- `CellKeeperHelper` launch daemon registered with `SMAppService`, XPC with
  code-signing requirements on both sides, typed operations only.
- Per-control leases, restore-on-start, restore-on-SIGTERM, uninstall flow;
  first version can only *restore defaults* and report state.
- In-process mock helper transport so contributors without a Developer ID can
  test the protocol.
- Non-sandboxed, notarized app (see research 05); experimental backend behind
  explicit opt-in, per verified model; every precondition in `safety.md`.
- Owner's direction (2026-10-06): in the long run CellKeeper controls
  charging itself, and the user turns macOS's own Charge Limit off. The app
  should then guide the user through turning it off, and detect it if it is
  turned back on, so two limits never compete.

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
