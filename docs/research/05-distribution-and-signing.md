# 05 — Sandboxing, code signing, notarization and distribution constraints

- **Date:** 2026-10-06
- **Workstream:** 05 (distribution & signing). Research only; no project files changed.
- **Machine used for experiments:** Mac16,1 (Apple silicon), macOS 27.0.1 (`sw_vers` build string 26A434), SIP enabled, Gatekeeper assessments enabled, Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0 SDK.
- **Experiment rules followed:** everything was built in new `/tmp` directories and signed ad hoc only. Nothing opened an IOUserClient or wrote to hardware. No `sudo`. No keychain or certificate changes; the one listing of signing identities was read-only. No notarization submissions. No login items or launchd jobs were registered.

### Evidence labels

| Label | Meaning |
|---|---|
| **[Doc]** | Apple developer documentation, release notes, SDK headers, man pages or tool `--help` output |
| **[Guideline]** | App Review Guidelines |
| **[DTS]** | Apple Developer Forums post by an Apple DTS engineer |
| **[Exp]** | Observed on this machine, in this session |
| **[Inference]** | My reasoning; not verified |
| **[3P]** | Third-party source |
| **[Local-SPI]** | The system sandbox profile files. Apple marks these as "Apple System Private Interface and subject to change"; they are evidence of current behaviour, not a contract. |

---

## Summary

1. **Sandboxed reads work (verified).** I ran an ad-hoc-signed, App Sandbox + Hardened Runtime build with **no entitlements other than `com.apple.security.app-sandbox`**. Sandboxed and unsandboxed builds returned the same results for all of these: [Exp]
   - `IOPSCopyPowerSourcesInfo`, `IOPSCopyPowerSourcesList`, `IOPSGetPowerSourceDescription`, `IOPSGetProvidingPowerSourceType`, `IOPSCopyExternalPowerAdapterDetails`.
   - Creating `IOPSNotificationCreateRunLoopSource`.
   - `IOServiceGetMatchingService("AppleSmartBattery")` with `IORegistryEntryCreateCFProperties` (51 properties) and `IORegistryEntryCreateCFProperty`.
   - `IOServiceAddInterestNotification` and `IOServiceAddMatchingNotification` on `AppleSmartBattery`.

   No IOKit or power-related sandbox denial was logged. The sandbox was confirmed active, because a control read of `~/Library/Preferences` was denied.
2. **What the sandbox blocks:**
   - **Opening IOUserClients**, except a fixed allow-list. AppleSMC is not on it. [Local-SPI]
   - **Mach lookups of arbitrary global services.** A lookup of `com.example.CellKeeper.helper` was denied (`BOOTSTRAP_NOT_PRIVILEGED`) unless the app had either the `mach-lookup.global-name` temporary exception or an App Group whose ID prefixes the service name. Both worked with ad-hoc signing. [Exp]
   - With ad-hoc signing on macOS 27, the **App Group container** itself was rejected because there is no Team ID. [Exp]
3. **Hardened Runtime needs no exceptions** for CellKeeper's phase-1 code. [Exp]
   - Notarization requires it, together with Developer ID signing, a secure timestamp, and no `get-task-allow`. [Doc]
   - **Pitfall (observed):** an ad-hoc main executable with Hardened Runtime **cannot load a separately signed ad-hoc dylib or framework** ("different Team IDs"), even with `get-task-allow`. [Exp] Avoid embedded dynamic frameworks while contributors build ad hoc.
4. **Notarization is a malware and signing scan, not App Review.**
   - Apple: "Notarization of macOS software is not App Review. The Apple notary service is an automated system that scans your software for malicious content, checks for code-signing issues…" [Doc]
   - DTS: the notary service "does not currently do any sort of quality checks". [DTS]
   - Undocumented SMC or IORegistry use does not by itself block notarization. [Inference + DTS]
5. **Mac App Store: not compatible with root-daemon or SMC charge control.**
   - Guideline 2.4.5 requires sandboxing, forbids root escalation and installing code in shared locations. Guideline 2.5.1 requires public APIs. [Guideline]
   - DTS says all code shipped through the Mac App Store must be sandboxed, and App Review "takes a very dim view" of temporary exceptions. [DTS]
   - A sandboxed, daemon-free edition that drives Apple's native Charge Limit through a user-owned Shortcut (workstream 02) *might* be eligible. That is unverified. [Inference]
6. **SMAppService constraints for the daemon phase:**
   - Since macOS 14.2, a **sandboxed app can only register a sandboxed daemon**. [Doc + DTS]
   - The macOS 27 SDK header says "Apps that contain LaunchDaemons must be notarized". [Doc]
   - DTS says ad-hoc ("Sign to Run Locally") signing causes SMAppService problems; app and helper should share the same Apple-issued identity. [DTS]
7. **Contributor workflow verified with Xcode 27.** [Exp]
   - A committed `Base.xcconfig` with `CODE_SIGN_IDENTITY = -`, an empty `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE = Automatic` builds an ad-hoc-signed app with no Apple account.
   - `ENABLE_APP_SANDBOX` and `ENABLE_HARDENED_RUNTIME` build settings produce the sandbox entitlement and runtime flag with **no `.entitlements` file**.
   - A trailing `#include? "Local.xcconfig"` (git-ignored) lets maintainers inject `DEVELOPMENT_TEAM` and identity. CI can override with `xcodebuild -xcconfig`.
8. **Homebrew changed in Sept 2026.** Official `homebrew-cask` now disables casks that fail Gatekeeper, so unsigned or un-notarized builds can't ship there (own tap only). [3P]
9. **Recommendation:**
   - **Phase 1:** ship with **App Sandbox ON** (verified sufficient; keeps a possible Mac App Store edition open) and **Hardened Runtime ON**, with no other entitlements. Sign ad hoc by default; maintainers use Developer ID for releases.
   - **Long term:** Developer ID + notarized, stapled DMG on GitHub Releases, plus an optional Homebrew cask. Add a root daemon via `SMAppService.daemon` **only if** a privileged backend is truly needed. If it is, prefer an **unsandboxed app + unsandboxed daemon** (drop the sandbox at that point and migrate preferences) over a sandboxed root daemon.

---

## Q1. App Sandbox and IOKit, Mach services, and the App Store

### 1.1 What Apple documents

- **App Store requirement.** "To distribute a macOS app through the Mac App Store, you must enable the App Sandbox capability." [Doc: App Sandbox]
- **Hardware access.** The documented hardware entitlements for App Sandbox are Camera, Audio Input, USB, Printing and Bluetooth. There is **no documented entitlement for generic IOKit / IORegistry access**. [Doc: Configuring the macOS App Sandbox]
- **IOUserClient exception.** `com.apple.security.temporary-exception.iokit-user-client-class` gives the "Ability to specify additional `IOUserClient` subclasses to open or to set properties on." [Doc: archived Entitlement Key Reference, 2017]
- **Global Mach services.** "With App Sandbox, lookup of global Mach services fails unless you configure the `mach-lookup.global.name` temporary exception entitlement." The key is `com.apple.security.temporary-exception.mach-lookup.global-name`. [Doc: same archive page]
- **Requesting temporary exceptions.** For App Store submissions you must "identify the entitlement and corresponding issue number in the App Sandbox Entitlement Usage Information section in App Store Connect and explain why your app needs the exception." [Doc: same]
- **App Groups and IPC.** "In macOS, use app groups to enable IPC communication between two sandboxed apps, or between a sandboxed app and a nonsandboxed app." For Mach IPC/XPC: "The service name has the format `<group identifier>.<unique name>`." [Doc: App Groups Entitlement]
  - Group IDs are `group.<name>` (registered) or, on macOS, `<team identifier>.<group name>`, which needs no registration. [Doc]
- **App group container protection (macOS 15+).** Group containers are SIP-protected. Access without a prompt requires one of: Mac App Store deployment, a Team-ID-prefixed group ID, or authorization by an embedded provisioning profile. [Doc: macOS 15 release notes; DTS 721701]
- **macOS 27 tightening.** "Accessing files in other developer teams' app data containers and app group containers no longer prompts the user for authorization; such accesses are denied by default…" [Doc: macOS 27 release notes]

### 1.2 What the system sandbox profile shows [Local-SPI]

Source: `/System/Library/Sandbox/Profiles/application.sb` and `appsandbox-common.sb` on macOS 27.0.1. The header says these rules "constitute Apple System Private Interface and are subject to change at any time".

- **Property reads are not restricted.** No `iokit-get-properties` restriction exists for apps, which matches the experiment.
- **Opening user clients is allow-listed.** `iokit-open-user-client` is granted only for named classes, for example `IOHIDParamUserClient`, `IOUserUserClient`, `SCSITaskUserClient`, and `RootDomainUserClient` through the `(power-assertions)` block. **No AppleSMC class appears.**
- **Power services are allowed.** `(power-assertions)` allows `mach-lookup` of `com.apple.PowerManagement.control` and `com.apple.iokit.powerdxpc`. That explains why the IOPS APIs and power assertions work sandboxed.
- **IOUserClient temporary exception.** It expands to `(allow iokit-open-user-client iokit-set-properties (iokit-user-client-class name))`.
- **App Groups.** They grant `(allow mach-lookup mach-register (global-name-prefix "<group>."))`. This is the mechanism behind "App-Group-prefixed Mach service names".
- **Mach-lookup temporary exception.** It grants `(allow mach-lookup (global-name name))` for each listed name.

### 1.3 Experiment: sandboxed reads [Exp]

**Setup.**
- A Swift probe, compiled with `swiftc`, was wrapped in two ad-hoc-signed `.app` bundles. Both used `codesign -s - --options runtime`.
  - Sandboxed bundle: entitlements = `{com.apple.security.app-sandbox: true}`.
  - Plain bundle: no entitlements.
- `sandbox_check(getpid(), NULL, 0)` and `HOME` (which pointed at `~/Library/Containers/<id>/Data`) confirmed the sandbox.
- A control read of `~/Library/Preferences` was **denied** in the sandbox.

**Results.**

| Operation (read-only) | Unsandboxed | Sandboxed |
|---|---|---|
| `IOPSCopyPowerSourcesInfo` + list + description | OK (1 source: InternalBattery, 80%, AC Power) | **OK, identical** |
| `IOPSGetProvidingPowerSourceType` | "AC Power" | **identical** |
| `IOPSCopyExternalPowerAdapterDetails` | OK (17 keys) | **OK, identical** |
| `IOPSNotificationCreateRunLoopSource` (+ 1 s run loop) | source created | **source created** (no power event occurred, so delivery not observed) |
| `IOServiceGetMatchingService(IOServiceMatching("AppleSmartBattery"))` | found | **found** |
| `IORegistryEntryCreateCFProperties` | OK, 51 props (CycleCount 54, Voltage, Amperage, BatteryData, ChargerData, AdapterDetails …) | **OK, identical** |
| `IORegistryEntryCreateCFProperty("CycleCount")` | 54 | **54** |
| `IOServiceAddInterestNotification(…, kIOGeneralInterest)` on AppleSmartBattery | KERN_SUCCESS | **KERN_SUCCESS** |
| `IOServiceAddMatchingNotification(kIOFirstMatchNotification, AppleSmartBattery)` | KERN_SUCCESS | **KERN_SUCCESS** |
| `IOServiceGetMatchingService("AppleSMC")`, lookup only, **not opened** | visible | visible |

**Sandbox log.** I checked `/usr/bin/log show` for kernel `Sandbox:` lines. In zsh, a bare `log` is a builtin, so use `/usr/bin/log`. The only denials for the sandboxed probe were:
- `file-read-data /Users/…/Library/Preferences`: the intentional control.
- `system-info vfs.disk-space`: benign runtime noise, not IOKit.

`secinitd` logged "AppSandbox request successful". **No `iokit-*` or power `mach-lookup` denials were logged.**

**Side observations for workstream 01.** On this Mac (Mac16,1, macOS 27.0.1):
- `AppleSmartBattery` has **no top-level** `DesignCapacity`, `Temperature` or `AppleRawMaxCapacity`.
- `DesignCapacity` (6249) and `NominalChargeCapacity` (6283) appear only nested under `BatteryData`.
- Top-level `MaxCapacity` is 100 (a percentage).

### 1.4 Experiment: Mach lookup from the sandbox (lookup only, no messages) [Exp]

`bootstrap_look_up()` results:

| Service name looked up | Unsandboxed | Sandbox only | Sandbox + App Group `ABCDE12345.com.example.CellKeeper` | Sandbox + temp-exception `mach-lookup.global-name` = `com.example.CellKeeper.helper` |
|---|---|---|---|---|
| `com.example.CellKeeper.helper` (not registered) | 1102 unknown (allowed) | **1100 denied** | 1100 denied | **1102 (allowed)** |
| `ABCDE12345.com.example.CellKeeper.helper` | 1102 | **1100 denied** | **1102 (allowed)** | 1100 denied |
| `com.example.CellKeeper.other` | 1102 | 1100 denied | 1100 denied | 1100 denied |
| `com.apple.PowerManagement.control` | found | found | found | found |
| `com.apple.iokit.powerdxpc` | found | found | found | found |

**Notes.**
- The kernel logged `deny(1) mach-lookup <name>` for each 1100 result.
- With the fake-team App Group, `containermanagerd` logged: "REJECTED. Requestor's signature does not allow it to access a TCC-protected group container. Group containers identifiers should be prefixed by requestor's team ID to allow access on this platform."
- **Conclusion:** the App Group's **Mach-name allowance works even for ad-hoc builds, but the group container does not**. Contributors' ad-hoc builds could still reach a group-prefixed daemon name. Storage in a group container would not work for them. [Exp]

### 1.5 IOUserClients (not exercised, by policy)

- **In the sandbox.** Opening the AppleSMC user client from a sandboxed process is not on the allow-list. It would need `temporary-exception.iokit-user-client-class`, which works outside the App Store. [Local-SPI + Doc]
- **In the App Store.** DTS: "App Review takes a very dim view of folks using temporary exception entitlements". An App Review rejection quoted in that thread reads: "…temporary entitlement exceptions requested for this app are not appropriate and will not be granted". [DTS 663311]
- **Root is required anyway.** Workstream 02 reports that SMC writes need root, and that on macOS 27 firmware most charge keys return `kIOReturnNotPrivileged` even to root. A sandboxed GUI app therefore cannot do SMC control even with the exception. Any SMC control belongs in a root daemon. [Inference, citing 02]

### 1.6 Reaching a privileged daemon's Mach service from a sandboxed app

| Approach | Outside the App Store (Developer ID) | In the Mac App Store |
|---|---|---|
| `temporary-exception.mach-lookup.global-name` = daemon's `MachServices` name | Works [Exp]. DTS: "If you're planning to distribute outside of the Mac App Store using Developer ID, you can use a temporary entitlement…". Put it on an XPC service, not the whole app, to shrink attack surface. [DTS 99602] | "you'd have to get this temporary entitlement approved by App Review, which is going to be tricky. Clause 2.4.5.v … explicitly proscribes privilege escalation." [DTS 99602] |
| App Group prefix: service name = `<TEAMID>.<group>.<name>`, group claimed by app (and daemon) | Works; DTS: "the XPC endpoint name must be an immediate child of one of your app group IDs" [DTS 745009]. Use a Team-ID-prefixed group. | Mechanism allowed, but a root daemon is still disallowed (below). |
| `SMAppService.daemon` registered **by a sandboxed app** | Since macOS 14.2: "The target executable must be sandboxed if the main app is sandboxed." [Doc: 14.2 release notes]. DTS: "We added code to `SMAppService` to explicitly require that, when a sandboxed app registers a daemon, that daemon must be sandboxed." [DTS 748124] | DTS: "all code that you ship via the Mac App Store must be sandboxed"; App Review acceptance of a helper daemon is not guaranteed. [DTS 763977] |

**On sandboxing a root daemon.**
- In 2019, DTS said the App Sandbox "is designed for user programs (app, app extensions, XPC Services) not for daemons… it's not a well-trodden path". [DTS 118718, 2019]
- In 2025, DTS documented sandboxed SMAppService daemons as supported. A Command Line Tool daemon needs a bundle ID and an embedded Info.plist; an app-like wrapper is required if the daemon uses restricted entitlements. [DTS 802443]
- So it is possible, but adds work. [Inference]

---

## Q2. Hardened Runtime

- **What it is.** "The Hardened Runtime, along with System Integrity Protection (SIP), protects the runtime integrity of your software by preventing certain classes of exploits, like code injection, dynamically linked library (DLL) hijacking, and process memory space tampering." [Doc]
- **Notarization requires it.** "To upload a macOS app to be notarized, you must enable the Hardened Runtime capability." [Doc]
- **How to enable.** Use the Xcode capability or the `ENABLE_HARDENED_RUNTIME` build setting, or `codesign -o runtime` / `--options=runtime`. [Doc]
- **Available exceptions.**
  - Runtime exceptions: JIT, unsigned executable memory, DYLD environment variables, disable library validation, disable executable memory protection, debugger.
  - Resource access: audio input, camera, location, contacts, calendars, photos, Apple Events. [Doc]
  - **CellKeeper needs none of them.** [Exp: the IOKit probe ran with `flags=0x10002(adhoc,runtime)` and no exceptions]
- **Rules for entitlements.**
  - "You add entitlements only to executables. Shared libraries, frameworks, and in-process plug-ins inherit the entitlements of their host executable." [Doc]
  - "macOS refuses to load system extensions that use Hardened Runtime exception entitlements." This is not relevant unless CellKeeper ever ships a system extension. [Doc]
- **Library validation pitfall for ad-hoc builds.** [Exp] I signed a main executable ad hoc with `-o runtime` and tried to `dlopen` or link a separately ad-hoc-signed dylib. It failed with "mapping process and mapped file (non-platform) have different Team IDs".
  - It failed with and without `get-task-allow`.
  - It succeeded without the runtime flag, or with `com.apple.security.cs.disable-library-validation`.
  - **Implication:** keep phase 1 free of embedded dynamic frameworks. SwiftPM dependencies link statically by default. When adding one (e.g. Sparkle), either turn Hardened Runtime off for local configurations, or add `disable-library-validation` only in Debug. Never add it in Release.
  - This was not re-tested through Xcode's "Embed & Sign" path. [Open question]
- **Root daemon.** Sign it with Hardened Runtime too. Opening an IOUserClient is not a Hardened Runtime restriction. [Inference; no Hardened Runtime exception covers IOKit]
- **Xcode 27 template default.** The macOS App template sets `ENABLE_APP_SANDBOX = YES` and `ENABLE_USER_SELECTED_FILES = readonly`. I did not find `ENABLE_HARDENED_RUNTIME` in the app template settings, even though "Configuring the hardened runtime" says templates add it. Set it explicitly. [Exp: inspected `TemplateInfo.plist`; Doc]

---

## Q3. Code signing

### 3.1 Identity types

| Identity | Requires | Use for CellKeeper | Notes |
|---|---|---|---|
| **Ad hoc** (`-`, Xcode "Sign to Run Locally") | Nothing | Contributor builds, CI test builds | DTS: "macOS on both Intel and Apple silicon will run ad hoc signed code (in Xcode parlance this is Sign to Run Locally"; "Apple silicon code will default to ad hoc signed" via the linker [DTS 703059]. [Exp]: `swiftc` output was `flags=0x20002(adhoc,linker-signed)`. No Team ID, so no Team-ID-based XPC requirements or launch constraints, and no team-prefixed App Group containers. |
| **Apple Development** | Apple ID (free Personal Team or paid team) | Maintainers testing a real daemon | DTS: ad-hoc signing causes SMAppService problems; "you should be signing both your embedded helper and your app with the same Apple-issued code-signing identity" [DTS 799910]. DTS's SMAppService walkthrough uses automatic signing with a team [DTS 802443]. |
| **Developer ID Application** | Paid Apple Developer Program; **Account Holder** creates it (or a cloud-managed cert for admins with that role); max 5 [Doc] | Release builds and DMG signing | "Developer ID certificate lets Gatekeeper verify that you're a trusted developer…" [Doc]. Apps signed while the cert was valid keep running after expiry; revocation stops install and launch [Doc]. |
| Apple Distribution / Mac Installer Distribution | Paid program | Mac App Store only | Not applicable (see Q5). |

### 3.2 Xcode settings layout (verified with Xcode 27) [Exp]

I built a minimal hand-written Xcode project in `/tmp`, a SwiftUI `MenuBarExtra` app calling `IOPSCopyPowerSourcesInfo`, with the project-level base configuration set to:

```xcconfig
// Config/Base.xcconfig — committed. Contributors need no Apple account.
PRODUCT_BUNDLE_IDENTIFIER = com.example.CellKeeper
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM =
CODE_SIGN_IDENTITY = -
ENABLE_HARDENED_RUNTIME = YES
ENABLE_APP_SANDBOX = YES
ENABLE_USER_SELECTED_FILES =
// Maintainer overrides (git-ignored). Keep LAST so it wins.
#include? "Local.xcconfig"
```

**Observed.**
- `xcodebuild … build` succeeded for Debug and Release with no account.
- The product was `Signature=adhoc`, `flags=0x10002(adhoc,runtime)`, with entitlements `{app-sandbox: true, get-task-allow: true}`. **No `.entitlements` file was needed**: Xcode synthesizes the sandbox entitlement from `ENABLE_APP_SANDBOX`.
- `get-task-allow` comes from `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES`, the default, even in Release. The archive/export flow strips it. [Doc: Resolving common notarization issues]
- The missing `Local.xcconfig` produced no warning thanks to `#include?`. Docs: "If Xcode can't find an included build configuration file, it generates build warnings. To suppress these warnings, add a question mark (?)". [Doc]
- A `Config/Local.xcconfig` containing `DEVELOPMENT_TEAM = ABCDE12345` and `CODE_SIGN_IDENTITY = Apple Development` was resolved by `-showBuildSettings` and overrode Base. I did not build with it, to avoid keychain prompts and provisioning traffic.
- **CI override.** `xcodebuild -xcconfig Release-DeveloperID.xcconfig` resolved the following, without touching the project:
  - `CODE_SIGN_STYLE = Manual`
  - `CODE_SIGN_IDENTITY = Developer ID Application`
  - `DEVELOPMENT_TEAM`
  - `OTHER_CODE_SIGN_FLAGS = --timestamp`
  - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
- A rebuilt ad-hoc sandboxed app (new cdhash) relaunched fine against its existing container. [Exp]

**Recommended files.**
- Commit `Config/Base.xcconfig` and `Config/Local.xcconfig.example`.
- Add `Config/Local.xcconfig` to `.gitignore`.
- For releases, either:
  - archive and export with an `ExportOptions.plist` (`method = developer-id`; `signingStyle`, `teamID`; `destination = upload` submits for notarization) [Doc: `xcodebuild -help`], or
  - pass a `-xcconfig` release override in CI.

### 3.3 Signing an embedded daemon or helper

- **Order and identity.** Sign inside-out with the same identity.
  - For non-bundled executables, set an explicit identifier: "If you're signing nonbundled code, add the `-i <BundleID>` option…" [Doc: Creating distribution-signed code]
  - Add `-o runtime` and `--timestamp` for Developer ID.
  - "Don't pass the `--deep` option to `codesign` when you sign code." [Doc]
- **Bundle layout.** Daemon executable in `Contents/MacOS/`. Launchd plist in `Contents/Library/LaunchDaemons/`, using the `BundleProgram` key. [Doc: SMAppService header, `launchd.plist(5)`; DTS 802443]
  - DTS: don't put code in `Contents/Resources`, and "`Contents/Library/LaunchServices/` is meant for tools installed with `SMJobBless`". [DTS 745009]
- **Xcode build phases.** Embed the tool with a Copy Files phase (Destination: Executables, "Code Sign on Copy" checked). Copy the plist with a Wrapper phase (subpath `Contents/Library/LaunchDaemons`, sign-on-copy unchecked). Set `SKIP_INSTALL = YES` on the tool target. [DTS 802443; Doc: Embedding a command-line tool]
- **Entitlements and profiles.** Unrestricted entitlements need no provisioning profile: sandbox, Hardened Runtime, `application-groups`, `get-task-allow`. A daemon claiming *restricted* entitlements must be packaged in an app-like structure. [Doc: Creating distribution-signed code; Signing a daemon with a restricted entitlement]
- **Authenticate XPC peers.** Use `NSXPCListener.setConnectionCodeSigningRequirement(_:)` and `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13+). [Doc]
  - A Team-ID-based requirement such as `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "com.example.CellKeeper"` works for both Apple Development and Developer ID builds. It cannot be satisfied by ad-hoc builds. [Inference]
  - So the real daemon path should be exercised only with Apple-issued identities, and contributors should use the mock backend. [Inference]
- **Launch constraints (optional hardening).** Launchd plists or `codesign --launch-constraint-*` can require `team-identifier`. "`launchd` doesn't start the process" if the constraint fails. [Doc: Defining launch environment and library constraints; `codesign(1)`]

---

## Q4. Notarization

### 4.1 What it is

> "Notarization of macOS software is not App Review. The Apple notary service is an automated system that scans your software for malicious content, checks for code-signing issues, and returns the results to you quickly." [Doc]

- **Verified wording on private API use.** DTS: "notarisation is not App Review and so the notary service does not currently do any sort of quality checks on your product." [DTS 702740, Mar 2022]
  - The same thread's accepted answer (Apple, Matt Eaton) still advises removing private API use, because such APIs "are unsupported and can change without notice".
  - CellKeeper's SMC access would use public IOKit calls (`IOServiceOpen`, `IOConnectCall*`) against undocumented selectors and keys. No private symbols are linked. **Notarization should not be affected; durability is the risk.** [Inference]
- **Which builds need it.** "Beginning in macOS 10.15, all software built after June 1, 2019, and distributed with Developer ID must be notarized." Mac App Store submissions don't need it. [Doc]
- **Daemon-specific requirement.** The macOS 27 SDK `SMAppService.h` says: "Apps that contain LaunchDaemons must be notarized." [Doc: SDK header]
- **Gatekeeper (macOS 15+).** "users will no longer be able to Control-click to override Gatekeeper when opening software that isn't signed correctly or notarized. They'll need to visit System Settings > Privacy & Security…" [Doc: Apple Developer News, 2024-08-06]

### 4.2 What the notary service checks

All of the following are documented requirements. Failure messages are from Resolving common notarization issues. [Doc]

- **Developer ID certificate.** "The binary is not signed with a valid Developer ID certificate."
- **Hardened Runtime on every executable.** "The executable does not have the hardened runtime enabled."
- **Secure timestamp.** "The signature does not include a secure timestamp." The timestamp needs network access to `timestamp.apple.com`. Xcode adds it on archive/export; custom flows need `--timestamp`.
- **No `com.apple.security.get-task-allow`.** "The executable requests the com.apple.security.get-task-allow entitlement."
- **macOS 10.9 SDK or later.**
- **Valid signatures on all nested code.**
- **XML, ASCII entitlements** with no BOM, not a binary plist.

### 4.3 Workflow (`notarytool`)

```sh
# 1. Build distribution-signed app (Developer ID, -o runtime, --timestamp), e.g. archive + export
# 2. Package: sign the DMG with the *Application* identity
hdiutil create -volname CellKeeper -srcfolder dist/CellKeeper.app -format UDZO dist/CellKeeper.dmg
codesign -s "Developer ID Application: <Name> (<TEAMID>)" --timestamp -i com.example.CellKeeper.dmg dist/CellKeeper.dmg
# 3. Submit and wait (API-key auth; see 4.4)
xcrun notarytool submit dist/CellKeeper.dmg --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid> --wait
xcrun notarytool log <submission-id> --key … developer_log.json   # always read it, even on success
# 4. Staple and verify
xcrun stapler staple dist/CellKeeper.dmg
spctl -a -vvv -t exec dist/CellKeeper.app      # or assess the mounted copy
codesign -vvv --deep --strict dist/CellKeeper.app
```

- **Containers.** The service accepts UDIF disk images, signed flat packages and ZIP. "If you distribute your product using nested containers, only notarize the outermost container." [Doc]
- **Stapling.** "While you can notarize a ZIP archive, you can't staple to it directly." Staple the app, then re-zip. DMGs and packages staple directly. Without a staple, "Gatekeeper might block a user from installing or using your product while their Mac is offline." [Doc]
- **Time and limits.** Notarization "completes for most software within 5 minutes" (98% within 15 minutes). "Limit notarizations to 75 per day." [Doc]
- **Translocation.** When an app runs in place from a DMG or ZIP, first launch is translocated. Test both first and subsequent launches. [Doc: Packaging]
  - The SMAppService header recommends that apps registering daemons live in `/Applications`. [Doc]

### 4.4 CI design (design only; nothing configured)

- **Secrets.** Store as CI secrets in a protected release environment, with required reviewers, triggered only on tags, never exposed to fork PRs:
  - Developer ID Application `.p12` and its password.
  - App Store Connect **Team** API key (`.p8`, key ID, issuer ID).
- **Keychain.** Import the certificate into a temporary keychain created per job and deleted afterwards.
- **Team key, not individual.** "Individual keys aren't able to use Provisioning endpoints, access Sales and Finance, or `notaryTool`." [Doc]
  - Local `notarytool submit --help` says `--issuer` is "Required for Team API Keys. Do not provide for Individual API Keys". This is a minor inconsistency with the doc; use a Team key.
  - The minimum role is not documented by Apple. A non-Apple forum poster reports "Developer role is sufficient". [Forum, unverified]
- **Private key handling.** "Don't share your keys, store keys in a code repository…". It can be downloaded once only. [Doc]
- **Alternatives.** Cloud-managed Developer ID certificates are available to admins with that role [Doc]. The Notary REST API avoids an Xcode dependency [Doc].
- **Network.** Builders need access to the S3 upload endpoint, Apple's CloudKit ranges (for stapler), and `timestamp.apple.com`. [Doc]

---

## Q5. Mac App Store

### 5.1 Relevant guidelines (verbatim) [Guideline]

> **2.4.5** Apps distributed via the Mac App Store have some additional requirements to keep in mind:
> (i) They must be appropriately sandboxed, and follow macOS File System Documentation. …
> (ii) They must be packaged and submitted using technologies provided in Xcode; no third-party installers allowed. They must also be self-contained, single app installation bundles and cannot install code or resources in shared locations.
> (iii) They may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app. …
> (iv) They may not download or install standalone apps, kexts, additional code, or resources to add functionality or significantly change the app from what we see during the review process.
> (v) They may not request escalation to root privileges or use setuid attributes.
> (vii) They must use the Mac App Store to distribute updates; other update mechanisms are not allowed.

> **2.5.1** Apps may only use public APIs and must run on the currently shipping OS. … Apps should use APIs and frameworks for their intended purposes …

> **2.5.2** Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app …

> **2.3.1(a)** Don't include any hidden, dormant, or undocumented features in your app …

**Note on the "Notarization (ASR & NR)" marker.** On 2.5.1, 2.5.2 and 4.7 it refers to "Notarization for iOS and iPadOS apps" (EU alternative distribution). It is **not** macOS Developer ID notarization. [Guideline: Introduction]

### 5.2 Verdict

**Real charge control via a privileged daemon and SMC is not compatible with the Mac App Store.**

- **Root.** A root daemon is "escalation to root privileges" (2.4.5(v)). DTS cites 2.4.5.v for exactly this case. [DTS 99602]
- **Sandbox.** Everything shipped must be sandboxed. [Guideline 2.4.5(i); DTS 763977]
  - A sandboxed app's daemon must be sandboxed. [Doc 14.2]
  - A sandboxed process needs an IOUserClient temporary exception for AppleSMC. App Review "takes a very dim view" of temporary exceptions. [DTS 663311]
- **Public APIs.** SMC key and selector semantics are undocumented, which puts them in conflict with 2.5.1 (public APIs) and 2.3.1(a). [Inference]
- **Updates.** Sparkle or other self-updaters are prohibited (2.4.5(vii)).

**Possible exception (unverified).**
- A **sandboxed, daemon-free** edition might be eligible if it does telemetry through public IOPS APIs (plus IORegistry reads; a 2.5.1 risk is low but nonzero, because the API is public but the property keys are undocumented) and control only through Apple's native Charge Limit using a **user-created** Shortcut. Workstream 02 reports this Shortcuts route.
- The Shortcuts URL scheme `shortcuts://run-shortcut?name=…&input=text&text=…` exists so "other apps can run a shortcut in your collection". [Doc: Shortcuts User Guide]
- I did not verify that a sandboxed app can open it, or spawn `/usr/bin/shortcuts`. Spawned children inherit the sandbox. App Review's view is unknown. [Inference / open question]

---

## Q6. Launch at login (`SMAppService.mainApp`)

- **API.** `SMAppService.mainApp` is "An app service object that corresponds to the main application as a login item". It needs macOS 13+. After `register()`, "the application launches on subsequent logins". [Doc]
- **Sandbox.** The API works for sandboxed and Mac App Store apps. WWDC22: "Your app will be allowed to launch at login by default, and users will be notified … this works in Mac App Store apps too." [Doc: WWDC22 10096]
  - No entitlement is required for either sandboxed or unsandboxed apps. [Doc: none listed; Inference]
- **User control.** Users manage the item in System Settings → General → Login Items & Extensions.
  - If the user disables it, `status` becomes `.requiresApproval`: "the user needs to take action in System Settings before the service is eligible to run. The framework also returns this status if the user revokes consent". [Doc]
  - Use `openSystemSettingsLoginItems()` to send the user there. [Doc]
  - `.notFound` simply means "the system knows nothing about your [service] yet". [DTS 721737]
- **App Store rule.** 2.4.5(iii) requires consent, so make "Launch at login" an **opt-in** toggle that reads live `status` instead of caching it. [Guideline + Inference]
- **Daemons by contrast.** "the system won't bootstrap the LaunchDaemon until an admin approves the LaunchDaemon in System Preferences". [Doc]
  - DTS observed the first `register()` returning error 1 until the user clicked Allow on the "Background Items Added" notification. [DTS 802443]
  - After updating a daemon's plist or executable, "the SMAppService must be re-registered or it may not launch. It is recommended to also call unregister before re-registering if the executable has been changed." [Doc: SDK header]
- **Not tested.** I did not register `mainApp` in this session, to avoid changing the user's login items. Behaviour of ad-hoc builds is unverified. Register from a copy in `/Applications`, not from DerivedData. [Inference]

---

## Q7. Updates for direct distribution (options only)

| Option | Dependency | Notes |
|---|---|---|
| **GitHub Releases + in-app "check for updates"** (GET `releases/latest`, compare version, open the browser) | None | Fewest moving parts. Needs network: fine unsandboxed; sandboxed needs `com.apple.security.network.client`. No auto-install. If a daemon exists, the new app must unregister and re-register it after the user replaces the app. [Doc: SMAppService header] |
| **Homebrew cask** (official `homebrew-cask` or own tap) | None in app | Homebrew 5.0.0 (2025-11-12): "We will disable all Homebrew/homebrew-cask casks that fail Gatekeeper checks in September 2026"; `--no-quarantine` deprecated. FAQ: official casks "must pass Homebrew's Gatekeeper checks without requiring users to bypass them". So official cask = Developer ID + notarized; an own tap can host anything. [3P: brew.sh] |
| **Sparkle 2** | Third-party framework | MIT-style licence, bundling bsdiff (BSD), sais-lite and ed25519 notices [3P: LICENSE]. Latest release 2.10.0 (2026-09-13) [3P: GitHub API]. Sandboxed apps need its Installer XPC service and `mach-lookup` temporary exceptions (`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `-spki`) [3P: Sparkle docs]. As an embedded dynamic framework it hits the ad-hoc + Hardened Runtime library-validation issue in Q2 [Exp + Inference]. |
| Mac App Store | — | Only if the App Store edition exists. 2.4.5(vii) forbids other updaters there. |

**Recommendation.** Start with GitHub Releases plus an optional Homebrew cask, and an in-app check that only notifies. Revisit Sparkle only if silent auto-update becomes a requirement.

---

## Entitlements and capabilities table

| Capability / entitlement | Needed in phase | Sandbox compatible | App Store compatible | Notes |
|---|---|---|---|---|
| `com.apple.security.app-sandbox` (`ENABLE_APP_SANDBOX`) | 1 (recommended ON) | — | **Required** | Verified sufficient for all phase-1 reads [Exp]. Xcode synthesizes it from the build setting. |
| Hardened Runtime (`ENABLE_HARDENED_RUNTIME`, `-o runtime`) | 1 (all releases) | Yes | Allowed (best practice) | Required for notarization. No exceptions needed [Exp]. |
| IOPS reads + `IOPSNotificationCreateRunLoopSource` | 1 | **Yes [Exp]** | Yes (public API) | No entitlement. |
| IORegistry reads of `AppleSmartBattery` (+ interest/matching notifications) | 1 | **Yes [Exp]** | Likely, but property keys are undocumented (2.5.1 risk low) | No entitlement. |
| `com.apple.security.get-task-allow` | Debug only | Yes | Must not ship | Notarization rejects it. Export strips it [Doc]. |
| `com.apple.security.network.client` | Only if sandboxed and checking for updates | Yes | Yes | Not needed in phase 1. |
| `SMAppService.mainApp` (launch at login) | 1–2 (opt-in) | Yes | Yes, with consent (2.4.5(iii)) | No entitlement. User notified; may need approval. |
| `SMAppService.daemon` (root helper) | 3+ (only if a privileged backend is required) | Only if the daemon is also sandboxed (macOS 14.2+) | **No** (2.4.5(v)) | Needs admin approval. Header: app must be notarized. Re-register after updates. |
| `com.apple.security.temporary-exception.iokit-user-client-class` | Only if a *sandboxed* process opens AppleSMC | Yes (it is a sandbox exception) | Practically no | Value is an array of class names. Doesn't grant root. |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | 3, only if sandboxed app → unsandboxed daemon name | Yes [Exp] | "tricky" [DTS] | Prefer to scope it to an XPC service [DTS]. |
| `com.apple.security.application-groups` (`<TEAMID>.…`) | 3, only if sandboxed app ↔ daemon | Yes | Yes | Mach-name prefix works ad hoc [Exp]. Group *container* needs a Team ID on macOS 15+/27 [Exp/Doc]. |
| `com.apple.security.cs.disable-library-validation` | Never in Release | Yes | Avoid | Only as a Debug crutch if ad-hoc builds embed dynamic frameworks [Exp]. |
| Developer ID Application cert + notarization + staple | Release | n/a | n/a (App Store uses Apple Distribution) | Paid program; Account Holder creates the cert. |
| Launch constraints (`team-identifier`) | 3 (optional hardening of the daemon) | n/a | n/a | Not satisfiable by ad-hoc builds. |

---

## Recommended configuration

### Phase 1 (telemetry + mock control)

- **Sandbox:** App Sandbox ON (`ENABLE_APP_SANDBOX = YES`). No other sandbox entitlements: no network, no file access, no temporary exceptions.
  - Rationale: verified to work; zero cost; limits damage if the GUI is compromised; keeps a possible sandboxed or App Store edition open while workstream 02's control path settles.
  - Store settings behind a small abstraction so a later container migration is easy if the sandbox is dropped.
- **Hardened Runtime:** ON, with no exceptions.
- **Signing:** ad hoc by default via the committed `Base.xcconfig` (above). Use an optional git-ignored `Local.xcconfig` for `DEVELOPMENT_TEAM`, identity and bundle-ID overrides. Releases use Developer ID through a CI `-xcconfig` override or an export-options plist.
- **No embedded dynamic frameworks** (keeps ad-hoc + Hardened Runtime working).
- **Launch at login:** `SMAppService.mainApp`, opt-in, reading live status.
- **Distribution, if phase 1 ships publicly:** Developer ID-signed, notarized, stapled DMG on GitHub Releases. Optional Homebrew cask, which must be notarized for official `homebrew-cask`.

### Long term

- **Default:** Developer ID + notarized DMG. Stay sandboxed if control uses only public or user-mediated paths, such as the native Charge Limit through a user-owned Shortcut (02).
- **If a root daemon is truly required** (e.g. an SMC path that still works):
  - **Drop the app sandbox** and ship an **unsandboxed app + unsandboxed root daemon**.
    - The daemon executable lives in `Contents/MacOS/` and is registered with `SMAppService.daemon(plistName:)`. The plist goes in `Contents/Library/LaunchDaemons/`, using `BundleProgram` and `MachServices`.
    - Use the same Developer ID with `-o runtime --timestamp -i <id>`, and an XPC code-signing requirement in both directions.
    - Optionally add a `team-identifier` launch constraint.
    - Keep a minimal, validated command set, fail safe (restore charging on exit or uninstall), and re-register on update. Install to `/Applications`.
  - **Trade-offs:** paid program and Account Holder needed; notarization in the release path; admin approval UX; no App Store.
  - The alternative of a sandboxed app + sandboxed root daemon with an AppleSMC IOUserClient exception and App-Group XPC naming is possible for Developer ID. It is more complex and less trodden [DTS 118718, 802443], and still not App Store-eligible.
- **Contributors:** always on the mock backend with ad-hoc builds. Exercising the real daemon requires an Apple Development identity via `Local.xcconfig`; DTS warns ad-hoc SMAppService is unreliable.

---

## Open questions

1. **Daemon signing in development.** Does `SMAppService.daemon` register and run from Apple Development-signed (non-notarized) or ad-hoc builds on macOS 27, given the header text "Apps that contain LaunchDaemons must be notarized"? DTS's walkthrough suggests development-signed builds work (macOS 15.6.1). Test in the daemon phase.
2. **Quarantine and launchd on macOS 27.** The macOS 27 release note says "`launchd` no longer supports loading `launchd` property list files with the quarantine extended attribute". Does this affect SMAppService plists inside a downloaded, Gatekeeper-approved app bundle? Test with a real notarized DMG download.
3. **Sandboxed Shortcuts access.** Can a sandboxed app open the `shortcuts://run-shortcut` URL, or spawn `/usr/bin/shortcuts`? The latter inherits the sandbox. Not tested, because it was outside this workstream's experiment permission.
4. **Xcode Embed & Sign.** Does Xcode's Embed & Sign of a dynamic framework under "Sign to Run Locally" + Hardened Runtime fail the same way as the raw `codesign` test? Test before adding any dynamic dependency.
5. **Notification delivery.** IOPS notifications under sandbox: registration was verified; delivery was not, because no power event occurred during the test.
6. **Notary API key role.** What is the minimum App Store Connect role for a notarytool Team key? "Developer" is community-reported only.
7. **App Review and IORegistry keys.** Would App Review accept a telemetry-only (or Shortcuts-mediated) edition that reads undocumented IORegistry keys?
8. **Login item from ad-hoc builds.** Behaviour of `SMAppService.mainApp` registered from an ad-hoc build is untested.

## Experiment residue and cleanup

- **Removed:** the temporary directories under `/tmp` (`ck05-sbxprobe.*`, `ck05-xcproj.*`, `ck05-docs`, `ck05-tools`, `ck05-dl`).
- **Could not remove: sandbox container shells.**
  - Five container shells with **metadata only** remain in `~/Library/Containers/`:
    - `com.example.CellKeeper.ck05SandboxProbe`
    - `…ck05LookupA`
    - `…ck05LookupB`
    - `…ck05LookupC`
    - **`com.example.CellKeeper`**, created by the Xcode-built probe, which used the placeholder bundle ID.
  - Their `Data/` directories were deleted. Each `.com.apple.containermanagerd.metadata.plist` (~28 KB) cannot be deleted or read from the shell: "Operation not permitted", container protection. [Exp]
- **Could not remove: one group container.** `~/Library/Group Containers/ABCDE12345.com.example.CellKeeper` also remains.
- **Possible effect on CellKeeper.** The real app, if sandboxed under `com.example.CellKeeper`, will reuse that container. A rebuilt ad-hoc app reused it without issue. [Exp]
- **To remove them:** delete via Finder, or ignore them.

---

## Sources

### Apple documentation

Fetched via the DocC JSON endpoint `developer.apple.com/tutorials/data/documentation/<path>.json` unless noted.
- App Sandbox — https://developer.apple.com/documentation/security/app-sandbox
- Configuring the macOS App Sandbox — https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- App Groups Entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups
- App Sandbox Temporary Exception Entitlements (archive, 2017) — https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html
- Hardened Runtime — https://developer.apple.com/documentation/security/hardened-runtime
- Configuring the hardened runtime — https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime
- Notarizing macOS software before distribution — https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Resolving common notarization issues — https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- Customizing the notarization workflow — https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Creating distribution-signed code for macOS — https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
- Packaging Mac software for distribution — https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
- Adding a build configuration file to your project — https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project
- Embedding a command-line tool in a sandboxed app — https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- SMAppService — https://developer.apple.com/documentation/servicemanagement/smappservice
  - mainApp — https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp
  - daemon(plistName:) — https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:)
  - register() — https://developer.apple.com/documentation/servicemanagement/smappservice/register()
  - Status.requiresApproval — https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval
- Updating helper executables from earlier versions of macOS — https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos
- Updating your app package installer to use the new Service Management API — https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api
- IOPSCopyPowerSourcesInfo — https://developer.apple.com/documentation/iokit/1523839-iopscopypowersourcesinfo
- Defining launch environment and library constraints — https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints
- NSXPCConnection.setCodeSigningRequirement(_:) — https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)
- NSXPCListener.setConnectionCodeSigningRequirement(_:) — https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)
- Creating API Keys for App Store Connect API — https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- macOS 14.2 release notes (ServiceManagement) — https://developer.apple.com/documentation/macos-release-notes/macos-14_2-release-notes
- macOS 15 release notes (app group container SIP) — https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes
- macOS 27 release notes (Gatekeeper, launchd quarantine, SIP containers) — https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- App Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- Developer ID — https://developer.apple.com/developer-id/
- Create Developer ID certificates — https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
- Apple Developer News, "Updates to runtime protection in macOS Sequoia" (2024-08-06) — https://developer.apple.com/news/?id=saqachfa
- WWDC22 "What's new in privacy" (10096) — https://developer.apple.com/videos/play/wwdc2022/10096/
- Apple Platform Security, Gatekeeper and runtime protection — https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
- Shortcuts User Guide, Run a shortcut using a URL scheme — https://support.apple.com/guide/shortcuts-mac/run-a-shortcut-from-a-url-apd624386f42/mac

### Local Apple sources (macOS 27.0.1 / Xcode 27.0)

- `/System/Library/Sandbox/Profiles/application.sb`, `appsandbox-common.sb`
- macOS 27 SDK `ServiceManagement.framework/Headers/SMAppService.h`, `SMErrors.h`
- `man launchd.plist`, `man codesign`
- `xcrun notarytool submit --help`, `xcodebuild -help`
- Xcode 27 `CoreBuildSystem.xcspec` (`ENABLE_APP_SANDBOX`, `ENABLE_HARDENED_RUNTIME`)
- macOS app `TemplateInfo.plist` files

### Apple Developer Forums (DTS = Quinn "The Eskimo!" unless noted)

- 99602 (Apr 2018), sandboxed app → daemon, temporary exception vs App Store — https://developer.apple.com/forums/thread/99602
- 745009 (Jan–Feb 2024), App Group-prefixed XPC names, sandboxed agents — https://developer.apple.com/forums/thread/745009
- 748124 (Mar 2024), sandboxed app ⇒ sandboxed daemon — https://developer.apple.com/forums/thread/748124
- 743395 (Dec 2023), 14.2 release note quoted, "sandbox required" logs — https://developer.apple.com/forums/thread/743395
- 721701 (2022, updated 2025-08-12), App Groups: macOS vs iOS — https://developer.apple.com/forums/thread/721701
- 702740 (Mar 2022), notarization and private API (Quinn; Matt Eaton) — https://developer.apple.com/forums/thread/702740
- 763977 (Sep 2024), non-sandboxed helper from a sandboxed App Store app — https://developer.apple.com/forums/thread/763977
- 703059 (Mar 2022), ad hoc / Sign to Run Locally, linker signing — https://developer.apple.com/forums/thread/703059
- 799910 (Sep 2025), ad hoc signing breaks SMAppService — https://developer.apple.com/forums/thread/799910
- 802443 (Sep 2025), Getting Started with SMAppService — https://developer.apple.com/forums/thread/802443
- 751439 (May 2024), SMAppService.daemon, Developer ID — https://developer.apple.com/forums/thread/751439
- 721737 (Dec 2022), SMAppService status `.notFound` — https://developer.apple.com/forums/thread/721737
- 663311 (Oct 2020), App Review and temporary exceptions — https://developer.apple.com/forums/thread/663311
- 118718 (Jun 2019), App Sandbox for daemons — https://developer.apple.com/forums/thread/118718
- 768634 (Nov 2024), notarytool key role (non-Apple claim) — https://developer.apple.com/forums/thread/768634

### Third-party (secondary)

- [3P] Homebrew 5.0.0 release notes — https://brew.sh/2025/11/12/homebrew-5.0.0/
- [3P] Homebrew FAQ — https://docs.brew.sh/FAQ
- [3P] Sparkle, Sandboxing — https://sparkle-project.org/documentation/sandboxing/
- [3P] Sparkle LICENSE — https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/LICENSE
- [3P] Sparkle latest release (GitHub API) — https://api.github.com/repos/sparkle-project/Sparkle/releases/latest

### Internal cross-references

- `docs/research/01-battery-telemetry.md`
- `docs/research/02-charging-control-apple-silicon.md`
