## Summary

<!-- What does this change do, and why? Link related issues. -->

## Testing

<!-- How was this verified? Unit tests, manual steps, Mac model and macOS version if hardware-related. -->

## Checklist

- [ ] `swift test --package-path Packages/CellKeeperKit` passes
- [ ] The app builds without new warnings (`xcodebuild -project CellKeeper.xcodeproj -scheme CellKeeper build`)
- [ ] New or changed policy behaviour has deterministic unit tests
- [ ] Charging policy code does not call hardware, IOKit, or private APIs directly
- [ ] Any new undocumented/private interface is isolated behind a backend or telemetry adapter and documented in `docs/research/`
- [ ] No hardware writes, privileged operations, or SMC access are added (or: the change follows `docs/safety.md` and has been discussed in an issue first)
- [ ] No serial numbers, identifiers, credentials, signing material, or build products are committed
- [ ] This is my own work (or properly attributed and licence-compatible), not code copied from another battery application
- [ ] Docs updated if behaviour, safety properties, or setup changed
