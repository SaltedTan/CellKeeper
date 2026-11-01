# Design guide

How CellKeeper's interface should look, read and behave: a native macOS
utility, calm and minimal, that never says more than it knows. Every change
to the menu, Settings, the power flow, the menu bar icon or any user-facing
wording follows this guide. It is written for people and for coding agents
alike; agents start from [AGENTS.md](../AGENTS.md).

Researched on 2026-10-31 against Apple's Human Interface Guidelines and
SwiftUI documentation (sources at the end). The rules are CellKeeper's own:
where a number is given (a width, a character budget) it is a project
choice, not an Apple requirement.

## Precedence

When rules conflict, the earlier one wins:

1. **Truth.** Never claim a state CellKeeper has not verified (D116, D118,
   D119): "macOS is enforcing 80%" only after a judged read. Configured,
   requested, reported and confirmed stay distinct: a selected limit is
   CellKeeper's target, not proof that macOS uses it, and policy rows
   describe intent, not outcome. `readDeferral` wins wherever a value is
   called enforced; `isNativeLimitSettled` decides only how compact the
   menu is. Dropping a speculative cause entirely is fine; dropping
   "likely" and keeping the cause is not.
2. **Recovery.** A warning that asks the user to act stays visible, beside
   the state it qualifies, until the state that raised it clears, also with
   Manage charging off. A disclosure or a disabled section never holds the
   only copy of: a restore or record warning, a fault, a pending backend
   switch, a refused action and its reason, a session's request (calibration,
   full charge), an unsaved session or schedule, or the Simulated helper's
   no-replacement caution. A restore that waits for power with nothing
   written is neutral (D119); one written but unconfirmed keeps its warning;
   neither is ever called "restored".
3. **Accessibility.** Keep everything in
   [accessibility-review.md](accessibility-review.md) (D109): labels,
   grouped rows, units in speech, headings, contrast-checked text colours,
   no colour-only signal, keyboard access.
4. **Native and minimal**, the rest of this guide.

Minimalism is achieved by ordering, grouping, disclosure and shorter words,
never by hiding a fact rule 1 or 2 needs.

## Principles

- **The menu answers three questions at a glance:** how charged the battery
  is, whether it is charging (and why not, when known), and what limit
  applies. Everything else is one click away.
- **One idea per line.** A status line is one sentence. If it needs a second
  sentence, the second belongs in a disclosure, a `.help` tag (only for
  optional detail) or Settings.
- **Quiet by default, loud when it matters.** A settled, healthy state shows
  almost nothing beyond the numbers. Colour, symbols and extra lines appear
  only when something needs attention.
- **Native first.** Standard SwiftUI controls, system text styles, system
  colours and SF Symbols. No custom chrome, cards, gradients, shadows or
  fonts to make the app "look designed".
- **Consistent.** The same thing has the same name, symbol and place
  everywhere: menu, Settings, notifications, Shortcuts, Diagnostics.

## Menu panel

- Keep `MenuBarExtra` with `.menuBarExtraStyle(.window)` and a 340 pt
  width. Height is intrinsic; nothing scrolls in the collapsed panel.
- Order, top to bottom:
  1. **Header:** the charge percentage (the only large type), power source
     and charging state.
  2. **Attention:** any warning or request that rule 2 keeps visible.
  3. **Power flow**, when Settings › General › Show power flow is on (the
     default): the diagram only, never above a warning.
  4. **Charge limit:** its control and the Manage charging switch.
  5. **One contextual action** (for example Charge to 100% once, or the
     running session's Cancel).
  6. **Details**, collapsed: power history (or the whole power flow, with
     the switch off), battery details, policy and last action, schedules.
  7. **Footer:** Settings… (⌘,) and Quit CellKeeper (⌘Q).
- Separate groups with `Divider()`, not each row. No boxes, cards or tinted
  backgrounds behind rows.
- At most one prominent (`.borderedProminent` or glass prominent) button,
  and only when the user is being asked to act. Ordinary actions use the
  default button style; secondary menu actions add `.controlSize(.small)`.
  "One contextual action" means one routine start/cancel area; it never
  removes a recovery control, a calibration answer or a pending switch's
  cancel.
- Show backend mechanics (policy state, desired mode, last action, notes)
  only in the collapsed Details or in Settings › Control, unless they
  explain a warning. Schedules are set up in Settings; the menu shows only
  their status, due reasons and outcomes.
- Closing a disclosure stops whatever only it needed, as if its content had
  closed: a persisted "expanded" flag is not proof of visibility (D114,
  D115). Layout work never adds sampling, timers or evaluations.

## Settings

- One `Settings` scene with a `TabView` of panes, each a
  `Form { … }.formStyle(.grouped)` (macOS 13+). Keep the set of panes small;
  merge a pane that holds one or two controls into a related one. The panes
  are General (menu bar icon, notifications, about), Charging, Control,
  Activity and Diagnostics (owner's minimalism request, 2026-10-31).
- Rows are `LabeledContent`, `Toggle`, `Picker`, `Slider` or `Stepper`
  inside `Section`s. Let the Form align and separate rows; don't add colons,
  manual padding or custom row backgrounds.
- A `Section` footer carries the explanation a setting needs, in one or two
  short sentences. Longer explanations (how macOS's Charge Limit works,
  the calibration's steps) go behind a `DisclosureGroup` in that section.
- Size the window to its content; long panes scroll. Keep the selected pane
  while the app runs, and open the pane a menu action needs.
- A consequential Start (calibration, discharge) shows its risk and
  recovery text beside it, never behind a second disclosure.
- Settings hold configuration and history. Frequent actions (the limit,
  Manage charging, a one-off full charge) also live in the menu.

## Controls

- `Toggle` (switch style) for a state that stays on, `Button` for a command,
  `Picker` for one of several values. A switch for a setting that governs a
  group (Manage charging); checkboxes are fine for subordinate options in
  Settings.
- Segmented `Picker` only for a few short values that fit, with units
  (`80%`). A `Slider` shows its exact value beside it; keep the keyboard and
  VoiceOver increments and the edit-commit rules of `ChargeLimitSliderEdit`.
- Regular control size by default; `.small` for secondary actions in the
  menu. Never `.mini` to save space.
- A disabled action shows why, visibly, from the same predicate that
  disables it (`DisabledReason`); a help tag alone is not enough.
- Buttons are named for what they do (Cancel Full Charge, Check Again), in
  title case, with an ellipsis only when more input follows (Settings…,
  Save Diagnostics…). OK only acknowledges.
- Alerts and confirmation dialogs only for decisions with consequences;
  routine status stays inline.

## Layout and type

- Use system text styles: `.title2`/`.headline` for headings, `.body` and
  `.callout` for content, `.caption` for supporting lines. The charge
  percentage is the one custom size (with `@ScaledMetric`). Avoid
  `.caption2` for anything the user must read: a source, an estimate or a
  qualification is content, at least `.caption`, beside the value it
  qualifies.
- Use `.monospacedDigit()` for values that change in place.
- Hierarchy comes from `.foregroundStyle(.primary)` and `.secondary`, and
  from weight, not from extra colours or sizes. Don't use tertiary for text
  that matters.
- Prefer default stack spacing and `.padding()`. Where the menu needs fixed
  values, use the existing ones (14 pt outer inset, 12 pt between groups,
  4–6 pt inside a group) and keep them in one place.

## Colour and symbols

- System and semantic colours only, following light and dark appearance and
  the user's accent colour. Accent marks interaction, not decoration.
- Warning and critical text use `Color.warningText` and
  `Color.criticalText` (contrast-tested, `TextToneTests`), never raw
  `.orange`/`.red`, and always with words and a symbol
  (`exclamationmark.triangle`).
- SF Symbols, monochrome by default, chosen for meaning and used
  consistently (one symbol per concept). Check each symbol exists on
  macOS 14.
- The menu bar icon stays a template image with one accessible label; it
  never turns into a coloured dashboard and never shows a guessed level.

## Power flow and charts

- The diagram is at the top of the menu unless the user turns it off
  (D121); the chart stays under a disclosure. Units on every value; a gap where data is
  missing, never a line across it or a zero in its place; estimated and
  measured kept apart.
- Series are told apart by label or line style as well as colour, and each
  chart has a text summary for VoiceOver. Series use system colours where
  they reach 3:1 against every background in `TextTone.backgrounds`, and
  darker shades where they do not (as the warning text does).
- An unknown charge uses a neutral symbol, never an empty or full battery.
  Each number keeps its own source; never adjust values so the diagram
  balances.
- The diagram: SF Symbols in soft circles, joined by links rather than
  arrows. A flowing link is a solid line in its series' colour (3:1, never
  made transparent), wider for more watts, with a blob that grows longer
  and faster; a link with no power is a thin line in the secondary label
  colour, dashed when its power is not known. With Reduce Motion the blob
  stays still, three quarters of the way towards where the power goes.
  The animation runs only while the menu's window is on screen and shows
  a flowing link: a closed menu's view lives on, so anything that reads or
  animates follows the window's visibility, never the view's lifetime.

## Words

- Plain, short and specific. Sentence case for sentences, labels and
  section headers; title case for buttons, tabs and menu items.
- A routine status line aims for 60 characters or fewer (an English
  drafting budget, not a truncation rule). Warnings may wrap; never
  `.lineLimit`, truncate or shrink a warning to make it fit.
- Lead with the fact, then the cause only if it is known: "Not charging ·
  Cause not reported." rather than two sentences about what macOS does not
  say. Keep the qualifier ("requested", "not confirmed", "simulated") that
  rule 1 needs, and drop everything else.
- Say "you" and "your Mac"; name things as macOS does (Charge Limit,
  System Settings › Battery › Charging, Low Power Mode).
- Wording that the controller's predicates choose lives in the Kit's
  `*Wording` types with tests. Shorten it there, keep the predicates, and
  update the tests with it.

## Liquid Glass and versions

- The app supports macOS 14 and builds with Xcode 16.0 (macOS 15 SDK) and
  Xcode 26.x. Standard controls take on macOS 26's appearance by themselves
  when built with its SDK; rely on that first.
- Don't put glass on content: the header, warnings, telemetry and charts
  stay on the normal background. Glass, if used at all, is for a control,
  through `.buttonStyle(.glass)`/`.glassProminent` rather than raw
  `glassEffect`.
- Any macOS 26 API needs `if #available(macOS 26, *)` and a compile-time
  guard so Xcode 16.0 still builds, with an ordinary fallback. For the
  supported stock Xcode toolchains that guard is `#if compiler(>=6.2)`
  (Xcode 26 pairs Swift 6.2 with the macOS 26 SDK); a compiler version is
  not an SDK check, so verify any other toolchain separately.

## Checking a UI change

- Render the changed views in light and dark with the offscreen harness
  (fake data only; never the real Charge Limit), including the states that
  matter: normal, on battery, simulated, macOS's limit settled and not yet
  judged, a pending switch, a fault, a disabled action and an unconfirmed
  restore. Compare before and after. The harness must never activate the
  app or make a window key: that takes the user's keyboard focus.
- Say for each finding whether it was seen in a render, read from the
  code, or still needs a real window or Mac. Offscreen artefacts (a grey
  switch, a missing version, tab labels) are not product bugs by
  themselves.
- Run the package tests and every CI job; wording changes update their
  tests in the same change.
- In the pull request, say what moved, what was shortened, which warnings
  stay visible, and what was checked by eye versus what needs the owner's
  Mac (VoiceOver, Increase Contrast, keyboard).

## Sources

Apple Human Interface Guidelines:
[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras),
[Settings](https://developer.apple.com/design/human-interface-guidelines/settings),
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Color](https://developer.apple.com/design/human-interface-guidelines/color),
[SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols),
[Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls),
[Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles),
[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons),
[Charts](https://developer.apple.com/design/human-interface-guidelines/charts),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Writing](https://developer.apple.com/design/human-interface-guidelines/writing),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Liquid Glass:
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass),
[Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views),
[WWDC25: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/).
Apple's own Battery menu and settings, as references for restraint:
[Battery status menu](https://support.apple.com/guide/mac-help/what-is-the-battery-status-menu-mchl173fcc57/26/mac/26),
[Battery settings](https://support.apple.com/guide/mac-help/change-battery-settings-mchlfc3b7879/mac).
No third-party design rules or skills are copied here; see CONTRIBUTING
for the clean-room rule, which also covers other battery apps' layouts.
