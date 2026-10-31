---
name: cellkeeper-design
description: CellKeeper's native, minimal macOS design rules. Use before changing any SwiftUI view, control, chart, the menu bar icon, layout, or user-facing wording (including the Kit's *Wording types).
---

1. Read `docs/design.md` and `docs/accessibility-review.md` from the
   repository root. They are the rules; this skill only points to them.
2. Apply the guide's precedence: truthful state, then visible recovery
   warnings, then accessibility, then native minimal design.
3. Render the views you changed, before and after, in light and dark, with
   fake data only (never the real Charge Limit), covering the states the
   guide lists.
4. Report what you moved, shortened or hid behind disclosure, which
   warnings stay visible, and any rule you could not follow and why.
