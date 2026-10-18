# Accessibility review

An audit of CellKeeper's user interface for VoiceOver, keyboard use, text
size, contrast, colour, motion and announcements, approved by the owner on
2026-10-19. It covers the menu-bar status item, the menu, every Settings tab
(Charging, Control, Activity, Diagnostics, About), the confirmation
dialogs, the alerts and the save panel, on `main` at bf73eec, and the weekly
full charge UI of PR #90 (`policy/recurring-full-charge` at 735b5b9).

Classes: **must** blocks or misleads a VoiceOver or keyboard user; **should**
makes the app noticeably harder to use with an assistive technology or a
visual impairment; **nit** is a small improvement. Line numbers refer to
bf73eec (`main`) or, for W*, to 735b5b9.

## Method

- **Code review** of `CellKeeper/*.swift` against a checklist: labels,
  values and hints; images and SF Symbols; custom controls; grouping and
  headings; reading order; keyboard access and dialog buttons; text size;
  contrast and Increase Contrast; colour-only signals; Reduce Motion and
  Reduce Transparency; announcements; text selection.
- **Offscreen render harness** (a scratch package outside the repository,
  `/tmp/ckpreview/harness-a11y`): the app's view sources compiled against
  the package with fake telemetry, fake backends (macOS's Charge Limit and
  its read-back are fakes) and in-memory stores, rendered to PNGs in light,
  dark and the (unavailable, see below) high-contrast appearances. Nothing
  touches the real Charge Limit.
- **Accessibility tree dumps** of the same views, read-only: the harness
  keeps them in offscreen windows, and a separate tool reads each element's
  AXRole, AXSubrole, AXTitle, AXDescription, AXValue, AXValueDescription,
  AXHelp, AXEnabled, AXTitleUIElement and a sheet's default and cancel
  buttons through the public accessibility API. It performs no action: no
  AXPress, no focus or value change, no click or keystroke. SwiftUI builds
  no accessibility tree when the harness asks its own views in process; it
  does answer another process. The same dump covered the weekly full charge
  UI of PR #90 from an export of that branch.
- **Contrast** computed from the system colours' sRGB values (WCAG 2
  relative luminance), read with `NSColor` under each appearance.

What the harness cannot do, and what needs the owner's Mac with VoiceOver
and Full Keyboard Access on: actually hearing VoiceOver, moving focus with
Tab, adjusting the slider with the keyboard, and Increase Contrast (macOS
returns plain Aqua for `NSAppearance(named: .accessibilityHighContrastAqua)`,
so the high-contrast colours appear only with the system setting on).
macOS 14 has no system text size that third-party SwiftUI apps follow:
`dynamicTypeSize` changes nothing on macOS (the menu measured 340 × 543
points at the default size and at `.accessibility3`), so a larger-text
render is not possible; Zoom and Hover Text are the system's aids there.

## Findings

### Status item (`CellKeeperApp.swift`, `AppModel.swift`)

| ID | Element | Finding | Class |
|---|---|---|---|
| S1 | Status item image, `CellKeeperApp.swift:12-13`, label `AppModel.swift:792-805` | An SF Symbol with an accessibility label that carries the charge, macOS's charging status and CellKeeper's state ("CellKeeper, 81%, Charging, Holding at limit"); the symbols differ by shape, not only colour. To confirm on the preview build that AppKit exposes the label | pass, to confirm |

### Menu (`MenuBarView.swift`, `Presentation.swift`)

| ID | Element | Finding | Class |
|---|---|---|---|
| M1 | Slider, `MenuBarView.swift:299-311` | VoiceOver reads the value as a bare number ("80"); no unit, and 100 is not said to mean no limit | must |
| M2 | Slider, `MenuBarView.swift:300-309` | A change is applied only in `onEditingChanged(false)`, the end of a drag. Arrow keys (Full Keyboard Access) and VoiceOver's increment move the knob through the binding; if AppKit reports no editing end for them (not verifiable without interaction), the menu shows a limit that is never applied | must |
| M3 | Battery header, `MenuBarView.swift:56-66` | Three separate elements, "81%", "Power adapter", "Charging": the bare percentage has no context | should |
| M4 | "Charging control" and "Charge limit" rows, `MenuBarView.swift:105-110`, `252-258`, `292-298` | Section titles are plain text, not headings, and their value (the status badge, the limit) is a separate element | should |
| M5 | Status badge, `Presentation.swift:352-364` | Coloured text on a 15% tint of the same colour: about 2.2:1 (green, orange) to 4:1 (purple) against white, less on the tint; WCAG asks 4.5:1 for text this small | should |
| M6 | Warning and error text in system orange and red: `MenuBarView.swift:84, 168, 196, 204, 207, 212, 216, 220, 274, 319, 325, 345, 367, 443`, `Presentation.swift:97, 134, 339` | In light mode system orange is 2.3:1 and red 3.6:1 against white, below 4.5:1, and these lines are the important ones (faults, restore problems, the 50% warning). Dark mode passes (7.5:1, 4.9:1) | should |
| M7 | "Read at …" note, `MenuBarView.swift:496-498` | Tertiary label colour, 1.9:1 against white, for the note that the capacity is CellKeeper's own figure and the thermal state is not the battery's temperature | should |
| M8 | Segmented limit picker, `MenuBarView.swift:263-265` | Segments read "80", "85" … "100", without a unit or "no limit" | should |
| M9 | "Cancel" and "OK" beside a line, `MenuBarView.swift:370, 446, 457` | Out of context ("Cancel, button") VoiceOver does not say what is cancelled or dismissed | should |
| M10 | Battery details grid, `MenuBarView.swift:473-493, 506-511` | Each row is two unrelated elements ("Voltage", then "12.43 V"); units are abbreviations ("V", "mA", "mAh", "W") that speech reads letter by letter | should |
| M11 | "Policy", "Wants", "Last action", `MenuBarView.swift:139-154` | Label and value are two elements (linked by a title element) | nit |
| M12 | Charge percentage, `MenuBarView.swift:58` | A fixed point size (`.system(size: 30)`); no effect on macOS today (see Method), but it would not follow a text size | nit |
| M13 | "Settings…" and "Quit CellKeeper", `MenuBarView.swift:34-41` | No ⌘, and ⌘Q on the buttons themselves | nit |
| M14 | "Charge to 100% once" disabled, `MenuBarView.swift:381-382` | Why it is disabled is said only in its help tag, which keyboard users do not see | nit |
| M15 | Icons in `Label`s | Hidden from accessibility by SwiftUI (verified: no image elements in the tree); every icon has text beside it | pass |

### Settings (`SettingsView.swift`, `Presentation.swift`, `AppModel.swift`)

| ID | Element | Finding | Class |
|---|---|---|---|
| G1 | Steppers, `SettingsView.swift:76-82, 243-254` | VoiceOver reads the stepper's value as a bare number ("80", "40"); the "80%" beside it is a separate element | should |
| G2 | Settings banner and schedule error, `SettingsView.swift:133-140, 215-219`; set in `AppModel.swift:436, 478, 700, 504, 724, 727` | A refused or failed change shows its reason at the bottom of the form or below the editor, away from the control just used, and nothing announces it | should |
| G3 | Diagnostics rows, `SettingsView.swift:663-671` | Combining `LabeledContent` with selectable text gives an element of role AXUnknown (verified), which VoiceOver may skip or read without a role | should |
| G4 | Copy Diagnostics, `SettingsView.swift:647, 674-683` | The title turns to "Copied" for two seconds; VoiceOver does not say so | should |
| G5 | macOS Charge Limit steps, `Presentation.swift:124-131` | The number ("1.") and the step are two elements | should |
| G6 | Warning and error text, `SettingsView.swift:68, 89, 95, 135, 139, 194, 218, 288, 362, 474, 478, 485, 510` | As M6 | should |
| G7 | Activity rows, `SettingsView.swift:578-592` | Kind, time and message are three elements in one row | nit |
| G8 | About title, `SettingsView.swift:691-692` | Not a heading | nit |
| G9 | "Discharge Now…" disabled, `SettingsView.swift:98-101` | Why it is disabled is not shown | nit |
| G10 | Diagnostics values with units, `DiagnosticsReport.swift` (Core) | "12427 mV", "6131 mAh": abbreviations, as in the report the tab mirrors | nit |
| G11 | Form sections, toggles, pickers, buttons, date pickers | Section titles are headings; every control has its label as title element (verified) | pass |
| G12 | Confirmation dialogs, `SettingsView.swift:102-110, 326-330, 500-504, 514-518` | Verified: Escape is Cancel in each; Return is the action in "Start Discharge", "Use macOS Charge Limit" and "Yes, my limit is 100%"; "Discard Record" (`role: .destructive`) has no default button | pass |
| G13 | Diagnostics save failure alert, `SettingsView.swift:29-33`; quit warning `CellKeeperApp.swift:68-77`; save panel `AppModel.swift:605-644` | Standard alerts (announced by VoiceOver, OK or Quit as default) and the standard save panel | pass |
| G14 | Settings window, `SettingsView.swift:9-26` | Tabs are tab buttons; the fixed 520 × 460 window scrolls its forms | pass |

### Across the app

| ID | Topic | Finding | Class |
|---|---|---|---|
| X1 | Colour-only signals | None: every orange or red line says what it warns of, the badge has text, and the scheduled line's colour repeats its words | pass |
| X2 | Reduce Motion, Reduce Transparency | No custom animation, transition or symbol effect; only system materials | pass |
| X3 | Gestures | No tap or drag gestures; every action is a button, toggle, picker, slider or stepper | pass |
| X4 | Live updates | Telemetry and status changes are not announced, by design: they arrive every minute. Only the user's own refused change (G2) and the copy (G4) need one | pass |
| X5 | Text selection | Diagnostics values and activity messages can be selected and copied | pass |

### Weekly full charge (PR #90; to fix after it merges)

| ID | Element | Finding | Class |
|---|---|---|---|
| W1 | Weekday toggles, `SettingsView.swift:289-299` | Toggle buttons named "Mon" … "Sun"; full day names read better | should |
| W2 | Duration stepper, `SettingsView.swift:306-308` | VoiceOver reads "12" without "hours" | should |
| W3 | Due line, store problem and error, `SettingsView.swift:271-285, 323-327`, `MenuBarView.swift:481-490` | Orange and red text, as M6 | should |
| W4 | Weekly outcome "OK", `MenuBarView.swift:499` | As M9 | should |
| W5 | Days, Start, Save, Remove | Labelled; the days have "Days" as title element and their state as value (verified) | pass |
