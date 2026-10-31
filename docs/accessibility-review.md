# Accessibility review

An audit of CellKeeper's user interface for VoiceOver, keyboard use, text
size, contrast, colour, motion and announcements, approved by the owner on
2026-10-19, and the fixes made for it (D109). It covers the menu-bar status
item, the menu, every Settings tab (Charging, Control, Activity,
Diagnostics, About), the Appearance tab, added later and reviewed in the
D113 follow-up below (the battery-style menu bar icon; Appearance and About
became sections of a General pane on 2026-10-31), the confirmation
dialogs, the alerts and the save panel, including the weekly full charge
(#90).

Classes: **must** blocks or misleads a VoiceOver or keyboard user; **should**
makes the app noticeably harder to use with an assistive technology or a
visual impairment; **nit** is a small improvement. Line numbers refer to
the code as audited: bf73eec for S, M, G and X, and f5caacd (#90 merged)
for W.

## Method

- **Code review** of `CellKeeper/*.swift` against a checklist: labels,
  values and hints; images and SF Symbols; custom controls; grouping and
  headings; reading order; keyboard access and dialog buttons; text size;
  contrast and Increase Contrast; colour-only signals; Reduce Motion and
  Reduce Transparency; announcements; text selection.
- **Offscreen render harness**, a scratch package outside the repository:
  the app's view sources compiled against the package with fake telemetry,
  fake backends (macOS's Charge Limit and its read-back are fakes) and
  in-memory stores, rendered to PNGs in light and dark mode. Nothing
  touches the real Charge Limit.
- **Accessibility tree dumps** of the same views, read-only: the harness
  keeps them in offscreen windows, and a separate tool reads each
  element's AXRole, AXSubrole, AXTitle, AXDescription, AXValue,
  AXValueDescription, AXHelp, AXEnabled and AXTitleUIElement, and a
  sheet's default and cancel buttons, through the public accessibility
  API. It performs no action: no AXPress, no focus or value change, no
  click or keystroke. SwiftUI builds no accessibility tree when the
  harness asks its own views in process; it does answer another process.
  Dumps were taken before and after the fixes, and of #90's UI before it
  merged.
- **The status item** of an isolated preview build
  (`io.github.saltedtan.CellKeeper.preview`, Simulated backend, its own
  sandbox container), read the same way and then quit.
- **Contrast** computed from the system colours' sRGB values under each
  appearance, with WCAG 2's relative luminance; the new colours are
  checked by unit tests (`TextToneTests`).

What the harness cannot do, and what needs a Mac with VoiceOver, Full
Keyboard Access and Increase Contrast on (the owner's checks, below):
hearing VoiceOver, moving focus with Tab, adjusting the slider with the
keyboard, hearing announcements, and seeing Increase Contrast: macOS
returns plain Aqua for `NSAppearance(named: .accessibilityHighContrastAqua)`,
so the high-contrast colours appear only with the system setting on.
macOS 14 has no system text size that third-party SwiftUI apps follow:
`dynamicTypeSize` changes nothing on macOS (the menu measured 340 × 543
points at the default size and at `.accessibility3`), so no larger-text
render is possible; Zoom and Hover Text are the system's aids there.

## Results

All must and should findings are fixed, and so is every nit: M14 and G9
in one follow-up (D110), G10 in another (D111), both below. Verified in
the accessibility tree after the fixes: the slider and steppers carry
their value with its unit; the battery header, the menu's labelled
values, the Battery details rows, the diagnostics rows and the activity
events are one element each, and no element has an unknown role (33
before, 0 after); "Charging control" and "Charge limit" are headings; the
limit segments, Cancel and OK buttons and weekday buttons have their full
names; the dialogs' default and cancel buttons are as before. The status
item reads "CellKeeper, 80%, Not charging, Charging to limit" on the
preview build. `swift test` (1,280 tests in five test targets) and the
Debug and Release builds pass with warnings as errors.

The code review of #93 found two problems in the first fixes, both fixed:

- **The slider's pending edit could undo a newer command.** An edit made
  without a drag waited 0.6 s and then saved its value, even if a Shortcuts
  action or Settings had set the limit meanwhile. The slider is now a
  state machine in Kit (`ChargeLimitSliderEdit`), and `AppModel` counts
  every settings change it accepts (`settingsRevision`). An edit is
  applied only at the revision it began from, and the model checks that
  revision again when it applies: any settings change the edit did not
  make wins, even one to the same value. A superseded edit is dropped at
  once, or at the end of a drag; closing the menu applies the current edit
  once.
- **A refusal repeated was not announced again.** The announcement
  followed changes of the problem line, so a second identical refusal
  (Schedule Full Charge twice with a past start, a retried save) said
  nothing. Each action now announces where it ends refused or failed,
  every time; steps that keep or clear the line, Shortcuts actions'
  changes, CellKeeper's own and status updates announce nothing
  (`BannerChange.announcement`).

### Follow-up: why a button is disabled (M14, G9)

A disabled "Charge to 100% once" (menu) or "Discharge Now…" (Settings ›
Charging) now says why, in secondary text under the button in the menu
and under the row's label in Settings, and as the button's accessibility
hint; an enabled one shows nothing extra and keeps its help tag. One
function in Kit enables each button and gives the reason, the first that
applies in a fixed order: `FullChargeStart.refusal`, unchanged and shared
with Start CellKeeper Full Charge, and `DischargeStart.refusal`, which
enables "Discharge Now…" under exactly the conditions it had (a test
compares it with the former predicate over more than 9,000 combinations
of settings, backends, readings and overrides). Verified in the
accessibility tree for eight statuses: a disabled button's AXHelp is the
reason and the reason is also a text element; an enabled "Charge to 100%
once" keeps its help tag as AXHelp, and an enabled "Discharge Now…" has
none, as before; the Settings button's title element is still "Discharge
to the limit" (D110).

### Follow-up: units in Settings › Diagnostics (G10)

The section model keeps a number with a unit as a quantity, which the
report and the tab write as before ("12427 mV", "31 °C"; the golden tests
are unchanged) and VoiceOver reads in words, with the menu's words and the
locale's numbers: "Voltage, 12,427 millivolts", "Current, -845
milliamps", "Full-charge capacity, 6,131 milliamp-hours", "Adapter, 70
watts", "Temperature protection, on (pause 40 degrees Celsius, resume 35
degrees Celsius)", and a unit in the singular when its number, as shown,
is one, in any locale's digits ("1 milliamp", "١ milliamp"). Temperatures
in the policy's sentences are read so too ("Reason, Battery at 41.5
degrees Celsius (pause at 40 degrees Celsius); charging paused.").
Verified in the accessibility tree of the harness, before and after: the
rows with a unit read their units in words, and every other row and
every element's role are as before. A test over every diagnostics fixture
requires words for each row whose value writes a unit's symbol (D111).

### Follow-up: the battery-style menu bar icon (D113)

The status item can now show a battery that CellKeeper draws, the default,
or the status symbol as before (Settings › General › Menu bar). In both styles it
is one image with the same accessibility label, which already says the
charge, the charging status and CellKeeper's state: the Battery style
draws its percentage into the image rather than adding a `Text`, which
the status item would show as a title, so VoiceOver has nothing more to
read. The image is a template, so the menu bar draws it in the colour of
its appearance; a warning or a temperature pause keeps a symbol beside the
battery, and its meaning is in the label too, so no state depends on
colour. The new tab follows the others: a `Label` whose title names the
tab, with an SF Symbol (`menubar.rectangle`). Show percentage is disabled
with the CellKeeper status style, and says why below it and as its hint
(D110). Checked in offscreen renders in light, dark and a tinted bar, at
1× and 2×; the status item itself was not run, because a calibration was
running on the owner's Mac.

### For the owner's Mac

With VoiceOver: the slider's value and its 1% steps (M1, M2), the
announcements of a refused setting and of Copy Diagnostics (G2, G4), the
weekly Start picker reading the time it shows (W6), a disabled "Charge to
100% once" or "Discharge Now…" giving its reason as a hint (M14, G9), the
Diagnostics rows reading their units in words (G10), and the status item
reading only its label in the Battery style, once, without the
percentage a second time (D113). With Full
Keyboard Access: Tab through the menu and Settings, and the slider with
the arrow keys (M2). With Increase Contrast: the warning and error text
(M6). These belong with the other owner-only checks in issue #89.

## Findings

### Status item (`CellKeeperApp.swift`, `AppModel.swift`)

| ID | Element | Finding | Class | Result |
|---|---|---|---|---|
| S1 | Status item image, `CellKeeperApp.swift:12-13`, label `AppModel.swift:792-805` | An SF Symbol with an accessibility label that carries the charge, macOS's charging status and CellKeeper's state; the symbols differ by shape, not only colour | pass | Confirmed: AppKit exposes the label as the status item's title |

### Menu (`MenuBarView.swift`, `Presentation.swift`)

| ID | Element | Finding | Class | Result |
|---|---|---|---|---|
| M1 | Slider, `MenuBarView.swift:299-311` | VoiceOver reads the value as a bare number ("80"); no unit, and 100 is not said to mean no limit | must | Fixed: "80%", "100% (no limit)" |
| M2 | Slider, `MenuBarView.swift:300-309` | A change is applied only in `onEditingChanged(false)`, the end of a drag. Arrow keys and VoiceOver's increment move the knob through the binding; if AppKit reports no editing end for them (not verifiable without interaction), the menu shows a limit that is never applied | must | Fixed: a change made without a drag is applied once the value has stayed put for 0.6 s, a drag when it ends, either only if no other settings change came first (`ChargeLimitSliderEdit`); VoiceOver's increment and decrement move 1% (D109) |
| M3 | Battery header, `MenuBarView.swift:56-66` | Three separate elements, "81%", "Power adapter", "Charging": the bare percentage has no context | should | Fixed: "Charge 81%, Power adapter, Charging" |
| M4 | "Charging control" and "Charge limit" rows, `MenuBarView.swift:105-110`, `252-258`, `292-298` | Section titles are plain text, not headings, and their value (the badge, the limit) is a separate element | should | Fixed: headings with their value ("Charging control, Simulated") |
| M5 | Status badge, `Presentation.swift:352-364` | Coloured text on a 15% tint of the same colour: about 2.2:1 (green, orange) to 4:1 (purple) against white, less on the tint; WCAG asks 4.5:1 for text this small | should | Fixed: label-coloured text on a tinted capsule with a border of the colour |
| M6 | Warning and error text in system orange and red: `MenuBarView.swift:84, 168, 196, 204, 207, 212, 216, 220, 274, 319, 325, 345, 367, 443`, `Presentation.swift:97, 134, 339` | In light mode system orange is 2.3:1 and red 3.6:1 against white, and these lines are the important ones (faults, restore problems, the 50% warning). Dark mode passes (7.5:1, 4.9:1) | should | Fixed: `TextTone` colours, at least 4.5:1, and 7:1 with Increase Contrast (D109) |
| M7 | "Read at …" note, `MenuBarView.swift:496-498` | Tertiary label colour, 1.9:1 against white, for the note that the capacity is CellKeeper's own figure and the thermal state is not the battery's temperature | should | Fixed: secondary colour |
| M8 | Segmented limit picker, `MenuBarView.swift:263-265` | Segments read "80" … "100", without a unit or "no limit" | should | Fixed: "80%" … "100% (no limit)" |
| M9 | "Cancel" and "OK" beside a line, `MenuBarView.swift:370, 446, 457` | Out of context VoiceOver does not say what is cancelled or dismissed | should | Fixed: "Cancel the temporary full charge", "Cancel the discharge", "Cancel the scheduled full charge", "OK, dismiss the scheduled full charge message" |
| M10 | Battery details grid, `MenuBarView.swift:473-493, 506-511` | Each row is two unrelated elements; units are abbreviations ("V", "mA", "mAh", "W") that speech reads letter by letter | should | Fixed: one element per row, units in words ("12.43 volts") |
| M11 | "Policy", "Wants", "Last action", `MenuBarView.swift:139-154` | Label and value are two elements (linked by a title element) | nit | Fixed: one element each |
| M12 | Charge percentage, `MenuBarView.swift:58` | A fixed point size; no effect on macOS today, but it would not follow a text size | nit | Fixed: `@ScaledMetric`, 30 points at the standard size |
| M13 | "Settings…" and "Quit CellKeeper", `MenuBarView.swift:34-41` | No ⌘, and ⌘Q on the buttons themselves (the hidden main menu has them) | nit | Fixed |
| M14 | "Charge to 100% once" disabled, `MenuBarView.swift:381-382` | Why it is disabled is said only in its help tag, which keyboard users do not see | nit | Fixed in the follow-up: the reason under the button and as its hint (D110) |
| M15 | Icons in `Label`s | Hidden from accessibility by SwiftUI (verified); every icon has text beside it | pass | |

### Settings (`SettingsView.swift`, `Presentation.swift`, `AppModel.swift`)

| ID | Element | Finding | Class | Result |
|---|---|---|---|---|
| G1 | Steppers, `SettingsView.swift:76-82, 243-254` | VoiceOver reads the stepper's value as a bare number ("80", "40"); the "80%" beside it is a separate element | should | Fixed: "80%", "75%", "40 degrees Celsius" |
| G2 | Settings banner and schedule error, `SettingsView.swift:133-140, 215-219`; set in `AppModel.swift:436, 478, 504, 700, 724, 727` | A refused or failed change shows its reason at the foot of the form or below the editor, away from the control just used, and nothing announces it | should | Fixed: the action that ends refused or failed announces it, every time, even with the same text (D109) |
| G3 | Diagnostics rows, `SettingsView.swift:663-671` | Combining `LabeledContent` with selectable text gives an element of role AXUnknown (verified), which VoiceOver may skip or read without a role | should | Fixed: static-text trait; the rows are AXStaticText |
| G4 | Copy Diagnostics, `SettingsView.swift:647, 674-683` | The title turns to "Copied" for two seconds; VoiceOver does not say so | should | Fixed: "Diagnostics report copied." is announced |
| G5 | macOS Charge Limit steps, `Presentation.swift:124-131` | The number ("1.") and the step are two elements | should | Fixed |
| G6 | Warning and error text, `SettingsView.swift:68, 89, 95, 135, 139, 194, 218, 288, 362, 474, 479, 485, 510` | As M6 | should | Fixed, as M6 |
| G7 | Activity rows, `SettingsView.swift:578-592` | Kind, time and message are three elements in one row | nit | Fixed: one element |
| G8 | About title, `SettingsView.swift:691-692` | Not a heading | nit | Fixed |
| G9 | "Discharge Now…" disabled, `SettingsView.swift:98-101` | Why it is disabled is not shown | nit | Fixed in the follow-up: the reason under the row's label and as the button's hint (D110) |
| G10 | Diagnostics values with units, `DiagnosticsReport.swift` (Core) | "12427 mV", "6131 mAh": abbreviations, as in the report the tab mirrors | nit | Fixed in a follow-up: units in words ("Voltage, 12,427 millivolts"), the report unchanged (D111) |
| G11 | Form sections, toggles, pickers, buttons, date pickers | Section titles are headings; every control has its label as title element (verified) | pass | |
| G12 | Confirmation dialogs, `SettingsView.swift:102-110, 326-330, 500-504, 514-518` | Verified: Escape is Cancel in each; Return is the action in "Start Discharge", "Use macOS Charge Limit" and "Yes, my limit is 100%"; "Discard Record" (`role: .destructive`) has no default button | pass | |
| G13 | Diagnostics save failure alert, `SettingsView.swift:29-33`; quit warning `CellKeeperApp.swift:68-77`; save panel `AppModel.swift:605-644` | Standard alerts (announced by VoiceOver, OK or Quit as default) and the standard save panel | pass | |
| G14 | Settings window, `SettingsView.swift:9-26` | Tabs are tab buttons; the fixed 520 × 460 window scrolls its forms | pass | |

### Across the app

| ID | Topic | Finding | Class |
|---|---|---|---|
| X1 | Colour-only signals | None: every orange or red line says what it warns of, the badge has text, and the scheduled line's colour repeats its words | pass |
| X2 | Reduce Motion, Reduce Transparency | No custom animation, transition or symbol effect; only system materials | pass |
| X3 | Gestures | No tap or drag gestures; every action is a button, toggle, picker, slider or stepper | pass |
| X4 | Live updates | Telemetry and status changes are not announced, by design: they arrive every minute. Only the user's own refused change (G2) and the copy (G4) need one | pass |
| X5 | Text selection | Diagnostics values and activity messages can be selected and copied | pass |

### Weekly full charge (#90)

| ID | Element | Finding | Class | Result |
|---|---|---|---|---|
| W1 | Weekday toggles, `SettingsView.swift:289-299` | Toggle buttons named "Mon" … "Sun" | should | Fixed: full day names (`WeeklyFullChargeWording.name(of:)`) |
| W2 | Duration stepper, `SettingsView.swift:306-308` | VoiceOver reads "12" without "hours" | should | Fixed: "12 hours" |
| W3 | Due line, store problem and error, `SettingsView.swift:271-285, 323-327`, `MenuBarView.swift:481-490` | Orange and red text, as M6 | should | Fixed, as M6 |
| W4 | Weekly outcome "OK", `MenuBarView.swift:499` | As M9 | should | Fixed: "OK, dismiss the weekly full charge message" |
| W5 | Days, Save, Remove | Labelled; the days have "Days" as title element and their state as value (verified) | pass | |
| W6 | Start picker, `SettingsView.swift:303-305` | Its value is a moment on a fixed day in GMT; an assistive app that reads that moment in the Mac's time zone would say another time (not verifiable without VoiceOver) | should | Fixed: its value is the time it shows ("7:00 AM") |
