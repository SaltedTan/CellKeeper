# Notes for coding agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/safety.md](docs/safety.md)
before any change: the clean-room rule, no hardware writes, and every
failure path returning to macOS default charging apply to agents as to
people.

## Interface changes

Before changing a view (`CellKeeper/*View.swift`, `Presentation.swift`, the
menu bar icon) or any user-facing wording, including the Kit's `*Wording`
types, read:

- [docs/design.md](docs/design.md): the design rules (native, minimal,
  truthful);
- [docs/accessibility-review.md](docs/accessibility-review.md): what must
  not regress.

Truthful state and visible recovery warnings win over minimalism. Keep the
macOS 14 deployment target and the Xcode 16.0 build working. Use native
components, put optional detail behind disclosure, and never hide a warning
that asks the user to act. In the pull request, say what you checked by eye
and what still needs a Mac with VoiceOver.
