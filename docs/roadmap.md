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

## Milestone 2 — macOS charging-state awareness and diagnostics

- Detect and display whether macOS is likely holding the charge (Charge
  Limit, Optimized Battery Charging, battery health management) using only
  public signals; label the cause "not reported" when unknown.
- Diagnostics view and exportable report (no identifiers): telemetry,
  decisions, OS build, model identifier.
- Telemetry freshness via the driver's update timestamp, not only read time.
- `ProcessInfo` thermal and Low Power Mode state in the UI (system-wide, not
  battery temperature).
- Unplug/replug and sleep/wake observation runs on real hardware to measure
  notification cadence (research 01, open question 1).

## Milestone 3 — Delegated native-limit backend (public interfaces only)

- Model "OS-managed limit" as a backend capability: the policy computes a
  desired native limit (80/85/90/95/100) instead of toggling charging.
- Apply it through a user-installed Shortcut run by the documented
  `shortcuts` command-line tool; verify the sandbox can launch it, or document
  the required entitlement change.
- Verify on a clean Mac: does the limit hold across sleep, restart, and
  shutdown? Does the action accept a variable?
- Use it for schedules ("100% before travel on Friday") without root.

## Milestone 4 — Hardware verification lab (no shipped writes)

- Follow the protocol in research note 02 §7 on dedicated test Macs with no
  other battery tools: read-only capability probe of a reviewed allowlist,
  then single reversible writes, then the persistence matrix.
- Evaluate in this order: native limit via Shortcuts; Apple's private
  `ChargeInhibit` power assertion (released automatically when the owning
  process exits); the SMC adapter-cut key only if a genuine need remains.
- Publish results per model, macOS build, and firmware in `docs/research/`.

## Milestone 5 — Privileged helper skeleton (only if milestone 4 finds a viable mechanism)

- `CellKeeperHelper` launch daemon registered with `SMAppService`, XPC with
  code-signing requirements on both sides, typed operations only.
- Lease / dead-man switch, restore-on-start, restore-on-SIGTERM, uninstall
  flow. First version can only *restore defaults* and report state.
- In-process mock helper transport so contributors without a Developer ID can
  test the protocol.
- Developer ID signing, notarization, non-sandboxed app (see research 05).
- Experimental hardware backend behind explicit opt-in, per verified model.

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

## Explicit non-goals

- Mac App Store distribution of a build with privileged control.
- Charge control on Intel Macs.
- Any general-purpose privileged interface.
