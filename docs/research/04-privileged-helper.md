# 04 — Privileged helper architecture and the macOS security model

- **Date:** 2026-10-06
- **Workstream:** Privileged helper (`CellKeeperHelper`): install and registration, IPC, client validation, protocol design, entitlements, alternatives
- **Status:** Research and recommendation only. The lead engineer makes the architecture decisions. Nothing was installed, registered, loaded, or run as root while producing this document.
- **Research environment:** macOS 27.0.1 (build 26A434), Xcode 27.0 (27A266a), Apple M4. The app's deployment target is assumed to be macOS 14+.
- **Placeholder identifiers used below:** app `com.example.CellKeeper`; helper label, Mach service, and code-signing identifier `com.example.CellKeeper.Helper`; team `TEAMID1234`.

**Evidence labels**

| Label | Meaning |
|---|---|
| **[Doc]** | Apple documentation, release notes, technotes, Apple Support, or the Platform Security/Deployment guides |
| **[DTS]** | A post by an Apple engineer (DTS or Frameworks Engineer) on the Apple Developer Forums |
| **[WWDC]** | An Apple WWDC session |
| **[man]** | A man page installed on the research Mac (macOS 27.0.1) |
| **[Inference]** | My reasoning from the sources. Not stated by Apple. |
| **[3P]** | A third-party secondary or anecdotal source. Treat with caution. |

Source IDs in brackets, for example [A4] or [F5], refer to §11.

> Note on forum sources: Apple's forum pages block scripted download. They were read through a summarising fetch tool, so the quotes from [F*] sources are near-verbatim. Re-check the exact wording against the thread before quoting it in user-facing material.

---

## Summary

- **Install mechanism: use `SMAppService.daemon(plistName:)`.** Embed the helper in the app bundle. Put its plist in `Contents/Library/LaunchDaemons/` and point to the binary with `BundleProgram`. This API is macOS 13+, and `SMJobBless` has been deprecated since 13.0 [Doc A3, A9, A11]. An admin must approve the daemon in System Settings › General › Login Items (& Extensions) before launchd will start it [Doc A4, W1]. The app should drive the UX from `status` (`.requiresApproval`, and so on) and `openSystemSettingsLoginItems()` [Doc A7, A8].
- **IPC: use `NSXPCConnection`/`NSXPCListener` over a `MachServices` name.** The helper calls `NSXPCListener.setConnectionCodeSigningRequirement(_:)` (macOS 13+) [Doc A16]. The app calls `NSXPCConnection.setCodeSigningRequirement(_:)` to pin the helper [Doc A15]. Never validate peers by PID [Doc A21, DTS F15, 3P T2]. When the minimum OS reaches 26, the Swift `XPCListener`/`XPCSession` API with `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)` becomes the cleaner option [Doc A19].
- **Validation rule:** "same Apple-issued team as me, **and** signing identifier = the CellKeeper app". The helper derives the team from its own signature at startup [Inference]. An ad-hoc signature has no certificates, so every certificate clause fails for it. An ad-hoc identifier can be forged by anyone [Doc A31]. **The helper must refuse to serve unless it is team-signed.**
- **Protocol: a tiny, closed interface.** Operations are `hello` (version and capabilities), `readState`, `acquireOrRenewLease`/`releaseLease`, `setControl(control: closed enum, active: Bool)`, `restoreDefaults`, and `restoreDefaultsAndExit`. Arguments are primitives only. There are no strings or collections from the client, no SMC key names or values, no paths, no shell, and no "debug passthrough".
- **Fail-safe lifecycle (dead-man's switch).** Every non-default state is held under a lease bound to one XPC connection, with a per-control maximum duration. The helper restores the default (normal charging, adapter enabled) when any of these happens: the lease expires; the connection is invalidated; the helper starts (boot, crash relaunch, update); the helper receives SIGTERM; or the system is about to sleep (adapter-disable only). The helper also enforces its own battery-floor interlock. These rules align with `06-safety-analysis.md` R1–R4, R16.
- **Sandbox.** Since macOS 14.2, a **sandboxed app may only register a sandboxed daemon or agent** via SMAppService [Doc A37 (14.2 RN), DTS F12]. A sandboxed app also needs `com.apple.security.temporary-exception.mach-lookup.global-name`, or an app-group-prefixed service name, to reach the daemon [Doc A30, A29]. **Recommendation for v1:** ship a non-sandboxed, Hardened-Runtime app (Developer ID and notarized) and a non-sandboxed, Hardened-Runtime helper. Revisit sandboxing the *helper* later as defence in depth.
- **Contributor builds.** Apple DTS says ad-hoc ("Sign to Run Locally") signing causes SMAppService daemon problems [DTS F7]. BTM pins the registered daemon to its code identity (designated requirement), and ad-hoc DRs change on every rebuild [Doc A23, DTS F5, 3P T3]. In practice:
  - Contributors without a signing identity work against a mock or in-process helper (TN3113 anonymous listener) [Doc A24].
  - Real-hardware helper testing needs an Apple-issued identity. Free Personal Team support is **unverified**.
  - Shipping the helper requires the project to hold a **Developer ID**.
- **Orphaned helper.** BTM keeps the registration after the app is deleted, "to preserve user intent" [DTS F9]. launchd needs the target executable to exist [DTS F12], so the job should be unable to start once the bundle is gone [Inference]. The design therefore never relies on post-deletion cleanup. The default state is restored whenever the app stops renewing.
- **Key risks:**
  1. The project may not obtain a Developer ID. Without one, the helper cannot ship reliably.
  2. It is unknown whether SMC charging-control state persists across helper death, restart, or shutdown. That question belongs to the SMC workstream.
  3. BTM state is fragile across development rebuilds and upgrades. Never change the helper's code-signing identifier.
  4. macOS 26+ may prompt users when background tasks stay alive after the app quits [Doc A40]. The helper should exit when idle.
  5. A memory-safety bug in the root helper would mean local privilege escalation. Keep the helper small, dependency-free, and primitives-only.

---

## 1. Installing and registering a privileged launch daemon

### 1.1 Mechanism: `SMAppService.daemon(plistName:)` (macOS 13+)

- [Doc A1, A2] `SMAppService` controls helper executables "that live inside an app's main bundle". For daemons, `register()`/`unregister()` replace the old practice of installing plists in `/Library/LaunchDaemons`. Service Management describes LaunchDaemons as processes that run "as root and may run before any users have logged on", which respond to requests via XPC.
- [Doc A3] `daemon(plistName:)`: "The property list name must correspond to a property list in the calling app's `Contents/Library/LaunchDaemons` directory."
- [Doc A9] To migrate: put the executable inside the bundle, put the daemon plist in `Contents/Library/LaunchDaemons`, and "replace the `Program` key with the `BundleProgram` key and make the path relative to the bundle".
- [man L1] `BundleProgram` is "an app-bundle relative path to the executable for the job. This key is only supported for plists that are installed using SMAppService."
- [Doc A9] Agents and daemons in the app bundle "automatically associate with that app in the Login Items panel". `AssociatedBundleIdentifiers` is only *needed* for legacy plists installed outside the bundle. For those, the executable's Team ID must match the app's.
- [WWDC W1] "If your app requires a daemon with elevated permissions, it will require admin approval to enable." The same session says "this works in Mac App Store apps too".
- [Doc A10] Benefit: the plists sit "in a fully codesigned app bundle that neither the system nor a third party can modify without breaking the code signature".

**Recommended bundle layout.** This follows Quinn's DTS walkthrough [DTS F1], which places the tool in `Contents/MacOS`.

```
CellKeeper.app/
  Contents/
    Info.plist                      CFBundleIdentifier = com.example.CellKeeper
    MacOS/
      CellKeeper                    app executable (Hardened Runtime)
      CellKeeperHelper              daemon executable (Hardened Runtime,
                                    codesign identifier com.example.CellKeeper.Helper,
                                    embedded Info.plist via "Create Info.plist Section in Binary")
    Library/
      LaunchDaemons/
        com.example.CellKeeper.Helper.plist
    Resources/ ...
```

Build-system details from [DTS F1] (tested with Xcode 26.0 on macOS 15.6.1):

- Embed the tool with a Copy Files phase. Destination: Executables. Code Sign on Copy: **checked**.
- Copy the plist with a Copy Files phase. Destination: Wrapper, subpath `Contents/Library/LaunchDaemons`. Code Sign on Copy: **unchecked**.
- Set the daemon target's *Enable Debug Dylib Support* to **No**. The post notes a quirk: you have to set it to Yes and then back to No.
- The daemon must be "signed the same way as the app itself" [DTS F6, F8].

### 1.2 launchd property list for the helper

Key semantics come from [man L1].

```xml
<!-- Contents/Library/LaunchDaemons/com.example.CellKeeper.Helper.plist (sketch) -->
<dict>
  <key>Label</key>                 <string>com.example.CellKeeper.Helper</string>
  <key>BundleProgram</key>         <string>Contents/MacOS/CellKeeperHelper</string>
  <key>MachServices</key>
  <dict><key>com.example.CellKeeper.Helper</key><true/></dict>
  <!-- Relaunch after a crash or non-zero exit. Implies RunAtLoad (boot-time restore).
       A clean exit(0) when idle is NOT restarted; MachServices still launch it on demand. -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
    <key>Crashed</key><true/>
  </dict>
  <key>ProcessType</key>           <string>Adaptive</string>
  <key>ExitTimeOut</key>           <integer>10</integer>   <!-- SIGTERM -> SIGKILL grace for restoreDefaults -->
  <!-- Release builds only (needs a Team ID). Constrains WHAT launchd may run for this plist. -->
  <key>SpawnConstraint</key>
  <dict>
    <key>team-identifier</key>     <string>TEAMID1234</string>
    <key>signing-identifier</key>  <string>com.example.CellKeeper.Helper</string>
  </dict>
</dict>
```

Notes:

- **`MachServices`.** The key must equal the name used by `NSXPCListener(machServiceName:)` and by the client. The `plistName` passed to `daemon(plistName:)` must equal the file name [DTS F7].
- **`KeepAlive` semantics** [man L1]. "If false, the job will be restarted in the inverse condition" (that is, restarted on a non-zero exit). `SuccessfulExit` "implies that RunAtLoad is set to true". `Crashed: true` restarts the job after crash signals. "If launchd finds no reason to restart the job, it falls back on demand based invocation." The default `ThrottleInterval` is 10 s, so a relaunch can take up to about 10 s.
  - Whether to keep the implied **RunAtLoad** depends on the SMC persistence question (§10, Q2). If SMC state can survive a restart, the boot-time run is what guarantees a return to defaults. If SMC always resets at restart, plain on-demand is enough and avoids starting a root process at every boot. [Inference]
- **`ExitTimeOut`** [man L1] is the time between SIGTERM and SIGKILL. 0 means infinity and must not be used.
- **`SpawnConstraint`** [Doc A25, A26, WWDC W2]. When the plist is registered via SMAppService, "the OS will enforce that only a process that meets the constraint will be launched on behalf of your plist". It is enforced from macOS 14. Facts include `team-identifier`, `signing-identifier`, `cdhash`, and `is-init-proc`. Quinn's caution applies: "Launch constraints typically cause things to fail rather than make things work" [DTS F8]. Add the constraint only after the basic flow works, and only in team-signed configurations.
- **`AssociatedBundleIdentifiers`** is optional for SMAppService-installed jobs [Doc A9]. It does no harm.
- **Optional parent launch constraint** embedded in the helper binary: `is-init-proc = true`, meaning only launchd may spawn it [Doc A26]. Running it directly from a shell then fails. This is low value, because anyone who can run it as root is already root, but it reduces misuse and confusion. Optional. [Inference]

### 1.3 Approval flow and status values

- [Doc A4] For a daemon, `register()` means "the system won't bootstrap the LaunchDaemon until an admin approves the LaunchDaemon … The system bootstraps LaunchDaemons registered with this method and approved by an admin on each subsequent boot." Errors: `kSMErrorAlreadyRegistered`, and `kSMErrorLaunchDeniedByUser` if not approved.
- [DTS F1] In practice, the first `register()` call logs `SMAppServiceErrorDomain / 1` ("not yet approved"). A **"Background Items Added"** notification appears. The user chooses Options › Allow and authenticates as an admin. To verify, run `sudo launchctl list <label>`. `sudo` is required, otherwise launchctl looks in the GUI domain.
- [Doc A8] `SMAppService.Status` has four cases:
  - `.notRegistered`
  - `.enabled`
  - `.requiresApproval`: "successfully registered, but the user needs to take action in System Preferences". This status is *also* returned "if the user revokes consent".
  - `.notFound`

  Raw values observed by an Apple engineer's correspondent: notRegistered 0, enabled 1, requiresApproval 2 [DTS F9]. `.notFound` is presumably 3 [Inference].
- [Doc A7, A9] `SMAppService.openSystemSettingsLoginItems()` opens the pane. Apple's guidance is to tell users what the helper does, check status at launch, and offer to open Settings if it isn't authorised.
- [Doc A9] "If your app uses launch daemons, it needs to register those first … If the user authorizes the `LaunchDaemon`, the system approves all the other helper executables present in the app bundle."
- **Pane name.** macOS 13/14 call it System Settings › General › Login Items. The macOS 15.x release notes call it "System Settings > General > Login Items & Extensions" [Doc A37 (15.4)]. The per-app toggle is "Allow in the Background" [DTS F5].
- **Standard (non-admin) users** need admin credentials to approve [Doc A4, WWDC W1].
- **Managed Macs.** An MDM Service Management payload can auto-approve items by `TeamIdentifier`, `Label`/`LabelPrefix`, or `BundleIdentifier`/`BundleIdentifierPrefix`. `sfltool dumpbtm` prints the BTM state and `sfltool resetbtm` resets it. Apple recommends restarting after a reset [Doc A40].

**Recommended app UX** [Inference from Doc A4, A7–A9]:

1. Explain what the helper does and why it needs admin approval *before* calling `register()`.
2. Call `register()`. Treat `kSMErrorLaunchDeniedByUser` as "registered, pending approval".
3. If `status == .requiresApproval`, show a "Open Login Items settings" button that calls `openSystemSettingsLoginItems()`.
4. Re-check `status` whenever the app becomes active. No status-change notification API is documented.
5. Keep the app fully functional as a *monitor* when the helper is absent.

### 1.4 Unregistering, uninstalling, and the orphaned daemon

- [Doc A5] `unregister()`: "If the service corresponds to a … LaunchDaemon and the service is currently running it, the system terminates it." If the service is already unregistered, it returns `kSMErrorJobNotFound`.
  - [3P] A third-party report says macOS 26 can return EPERM here instead. That report was not fetched or verified, so handle both errors as "already gone".
- [Doc A10] After removal, the item "may remain visible in the System Settings > General > Login Items for some time … the system removes deleted items as part of its maintenance processes overnight". `sudo sfltool resetbtm` resets *all* third-party login items.
- [DTS F9] On registrations that persist after unregistering and after the app is deleted: "That is the current behavior. The state is persisted to preserve user intent." The approval is also remembered for later re-registration [DTS F1].
- [DTS F10] On deleting app data: "the system doesn't know whether the user has a copy of the app elsewhere". To remove the daemon, Apple's recommendation is: "Ideally you'd use `SMAppService`, where you can uninstall the daemon using `unregister(completionHandler:)`."
- [DTS F11] When an app is deleted via the Finder, Launch Services unregisters *app extensions*, and the Finder prompts about *system extensions*. Nothing is documented for SMAppService daemons.
- [DTS F12, Kevin Elliott] launchd's "only concern is whether or not the target exists".
  - [Inference] Once the bundle is truly gone (Trash emptied), the registered job cannot be spawned. An orphan is therefore a stale BTM record plus a job that can't start, not a running root process.
  - [3P T3] Anecdote: in another project, after the app was replaced, "launchd kept the old one running from the Trash". A helper that is *already running* keeps running, and a bundle that is only in the Trash may still be resolvable. The CellKeeper design must not depend on deletion stopping the helper.

**CellKeeper consequences** [Inference]:

1. Ship an in-app **"Remove helper and restore normal charging"** flow:
   1. XPC `restoreDefaults`, then wait for the read-back to confirm.
   2. Call `SMAppService.daemon(plistName:).unregister()`.
   3. Optionally unregister `SMAppService.mainApp`. Note that unregistering `mainApp` does **not** remove the daemon.
   4. Tell the user they can now delete the app.
2. Because deletion can't be detected reliably, the lease (§3.4) is what makes deletion safe. The app can't renew once it's gone, so the helper reverts within one lease period. When the app quits, the connection is invalidated and the helper reverts immediately.
3. Document manual recovery in the README:
   1. Use the in-app removal if possible.
   2. Otherwise, `sudo launchctl bootout system/com.example.CellKeeper.Helper` stops a running instance.
   3. Restart the Mac. On Apple silicon, Apple's SMC reset procedure *is* a restart or shutdown, and "SMC resets automatically" [Doc A39]. Whether that clears the specific keys CellKeeper writes must be verified (§10, Q2).

### 1.5 Updating the helper when the app updates

Apple documents nothing specific about this. Here is what the evidence supports:

- **[DTS F5] Keep the helper's code-signing identifier (and therefore its DR) stable forever.**
  - Mozilla VPN renamed its daemon executable. That changed its signing identifier. On upgrade the daemon failed with `AMFI: Launch Constraint Violation … c[5]` (a spawn constraint).
  - Neither `unregister()` + `register()` nor `launchctl bootout` fixed it.
  - Restoring the old identifier with `codesign --identifier` fixed it.
  - Quinn's diagnosis was that a changed identifier means a changed DR, which fails the constraint applied when the job was registered.
- **[Inference]** `BundleProgram` is bundle-relative, so after an in-place update launchd will spawn the *new* binary the next time it launches the job. A helper process that is already running keeps running the old code until it exits. Therefore:
  - `hello()` returns the helper's build number.
  - If it doesn't match the build embedded in the app, the app calls `restoreDefaultsAndExit()`. The next connection then spawns the new helper. Allow for the launchd throttle of up to 10 s.
- **[Inference]** Keep the `Label`, `MachServices` name, and plist file name stable as well. Mozilla changed `BundleProgram` and `MachServices` in the same update, and nothing indicated *those* changes were the problem [DTS F5]. Still, every plist change should be tested on a clean VM going from version N to N+1, as Quinn recommends [DTS F6].
- **[DTS F6, F8]** Expect occasional BTM corruption across upgrades and OS upgrades. Quinn suggests filing bugs with repro steps and a sysdiagnose taken *before* `sfltool resetbtm`.

### 1.6 What changed by OS version (13 → 27)

| Version | Change relevant to this design | Source |
|---|---|---|
| 13.0 | `SMAppService` introduced. `SMJobBless` deprecated. `NSXPCConnection.setCodeSigningRequirement` and `NSXPCListener.setConnectionCodeSigningRequirement` added. Login Items notification and pane added. | [Doc A1, A11, A15, A16; WWDC W1] |
| 13.1 → 13.2 | Regression in 13.1 that "prevented daemons from being registered with SMAppService" fixed in 13.2. | [Doc A37 (13.2)] |
| 13.3 | Excessive "Background Items Added" notifications fixed. Launch constraints enforced. | [Doc A37 (13.3); WWDC W2] |
| 14.0 | Swift `XPCListener`/`XPCSession` (no peer-requirement support yet [DTS F4]). launchd plist `SpawnConstraint` and library load constraints enforced. | [Doc A20; WWDC W2] |
| 14.2 | "The target executable must be sandboxed if the main app is sandboxed." Applies to SMAppService agents and daemons. | [Doc A37 (14.2); DTS F12] |
| 14.4 | XPC C API peer requirements: team identity, lightweight code requirement (LWCR), entitlement, platform identity. | [Doc A14, A18] |
| 15.0 | `SMAppServiceErrorDomain` symbol public. Pane named "Login Items & Extensions" (15.x). App-group containers SIP-protected; team-ID-prefixed group IDs keep access. | [Doc A12, A37 (15, 15.4)] |
| 26.0 | `XPCPeerRequirement`; `XPCListener`/`XPCSession` initialisers with `requirement:`; `XPCSession.setPeerRequirement`. Deployment guide: if background tasks "remain active after a user quits the app", the user is prompted to allow them or not. | [Doc A19, A40; DTS F4] |
| 27.0 | "`launchd` no longer supports loading `launchd` property list files with the quarantine extended attribute." | [Doc A37 (27)] |

I scanned the release notes for macOS 26.0–26.6, 27.0, and 27.2 beta 3. None of them mention ServiceManagement or XPC API changes beyond the rows above.

### 1.7 `SMJobBless`: deprecated, and why CellKeeper should not use it

- [Doc A11] Deprecated in macOS 13.0 with "Please use SMAppService instead".
- [Doc A11] It requires an `SMPrivilegedExecutables` requirement map in the app's Info.plist, `SMAuthorizedClients` in the tool's Info.plist, and an embedded launchd plist. The tool sits in `Contents/Library/LaunchServices`. The system *copies* the plist into the system domain, and "you can't specify your own program arguments".
- [Inference] Why not:
  - The deployment target is 14+, where SMAppService is always available.
  - SMJobBless copies the helper outside the app bundle, so an orphaned *runnable* root helper is more likely after the app is deleted.
  - It loses the bundle-relative association and the code-signature-sealed plist [Doc A10].
  - It requires extra Info.plist requirement strings that must stay in sync.
  - Quinn's matrix lists `SMJobBless` only "if you need to deploy to older systems" [DTS F2].

### 1.8 `SMAppService.mainApp` (launch at login)

- [Doc A6] "Use this `SMAppService` to configure the main app to launch at login." [Doc A4] "If the service corresponds to the main application, the application launches on subsequent logins." [Doc A5] Unregistering it does not quit the running app.
- [WWDC W1] Apps are allowed to launch at login by default, and the user is notified.
- [Inference] This is independent of the daemon and needs no admin approval. Unregistering `mainApp` does not unregister the daemon.

---

## 2. IPC and client validation

### 2.1 Transport

- [Doc A13] A launch daemon is "one systemwide process … as the `root` user. LaunchDaemons can't initiate connections to user processes but can respond to requests from them." The helper is therefore a pure responder. The app polls `readState()`.
- [Doc A22] The client uses `NSXPCConnection(machServiceName:options:)` with `.privileged`, which is meant for "a service in the privileged Mach bootstrap". The helper uses `NSXPCListener(machServiceName:)`.
- **Recommendation: Foundation `NSXPC*` while the minimum OS is below 26** [Inference]. Peer requirements are available from macOS 13, and the protocol is a compile-time-checked `@objc` protocol. The Swift `XPCListener`/`XPCSession` API (macOS 14) only gained peer requirements in macOS 26 [Doc A19, DTS F4]. Design the message set as plain value types so it can move to `XPCSession`/`XPCListener` later.

### 2.2 Peer-validation APIs by OS version

| API | Minimum OS | Notes | Source |
|---|---|---|---|
| `NSXPCListener.setConnectionCodeSigningRequirement(_:)` | 13.0 | Applies to every incoming connection. **Recommended for the helper.** | [Doc A16] |
| `NSXPCConnection.setCodeSigningRequirement(_:)` | 13.0 | "If new messages don't match the requirement, the connection becomes invalidated." Call it before `resume()`/`activate()`. Calling it twice is an error. A malformed requirement is "a fatal error in Swift". **Recommended for the app (to pin the helper).** | [Doc A15] |
| `xpc_connection_set_peer_code_signing_requirement` | 12.0 | C API. | [Doc A17; DTS F3] |
| `xpc_connection_set_peer_team_identity_requirement`, `…_lightweight_code_requirement`, `…_entitlement_*`, `…_platform_identity_*` | 14.4 | C API. Checked "every time it sends a message". Setting two requirements on one connection terminates the process. | [Doc A14, A18] |
| `XPCPeerRequirement` (`isFromSameTeam(andMatchesSigningIdentifier:)`, `.hasEntitlement`, LWCR, `codeRequirement`); `XPCListener(service:…requirement:…)`; `XPCSession.setPeerRequirement` | 26.0 | For a listener, "requests that do not satisfy the requirement are dropped". | [Doc A19] |
| `SecCodeCreateWithXPCMessage` | 11.0 | C API only. Per-message. | [DTS F3] |

Quinn's current recommended summary [DTS F3, revised 2025–2026]:

- For `NSXPCConnection`, use `-setCodeSigningRequirement:` (macOS 13).
- For the C API, use `xpc_connection_set_peer_code_signing_requirement` (macOS 12) or the LWCR variant (14.4).
- For `XPCListener`, see the macOS 26 additions.
- He also links a 2026 caveat thread, "Outgoing XPC message goes through to untrusted Peer". I could not fetch that thread. The implication is that the *first outgoing* message may reach the peer before its signature is checked [Inference]. The app sends nothing secret, so this has low impact for CellKeeper.

### 2.3 Why PID-based validation is unsafe

- [Doc A21] `xpc_connection_get_pid`: PIDs are "not guaranteed to be unique … can go stale after the connection is established. macOS recycles PIDs, and therefore another process could spawn and claim the PID before a message is actually received."
- [DTS F15] Quinn in 2017: "it's a bad idea to use a process ID in security-related work". In 2020 he revised his earlier view and noted "a possible vulnerability with the first message for a given connection". The public API offers no audit token from a connection, and using the private audit-token SPI is "not support[ed]" by DTS. `NSXPCConnection` still exposes only `processIdentifier`, `effectiveUserIdentifier`, `effectiveGroupIdentifier`, and `auditSessionIdentifier`, with no public audit token [Doc A22].
- [3P T2] The classic exploit:
  1. The attacker queues privileged messages.
  2. It then calls `posix_spawn(..., POSIX_SPAWN_SETEXEC)` to replace its own image with a legitimately signed binary *under the same PID*.
  3. A server that validates via PID → `SecCodeCopyGuestWithAttributes(kSecGuestAttributePid)` sees the legitimate binary.

  This was demonstrated against a shipping security product's helper.
- **Conclusion:** use only the system-enforced requirement APIs from §2.2. They are evaluated by the XPC runtime per message or connection, without a PID race. Never write a hand-rolled PID check. If a PID appears in logs, it is informational only.

### 2.4 Requirement strings

Background facts:

- [Doc A23] A designated requirement (DR) is "how the code identifies itself". "Ad hoc signed code … has a DR but it's tied to that specific version of the code." Apple advises against hand-writing requirements: dump one with `codesign -d -r-` from a correctly signed build and edit it.
- [Doc A31] Two relevant clauses:
  - `certificate leaf[subject.OU]`: "In Apple issued developer certificates, this field contains the developer's Team Identifier."
  - `anchor apple generic`: code "signed using a signing certificate issued by Apple to other developers".
- [Doc A31] Ad-hoc caveat: "If the code was signed using an ad-hoc signature, there are no certificates at all and all certificate constraints evaluate to false." The `identifier` value is chosen by the signer [Doc A23]. **An `identifier`-only requirement is therefore forgeable by any ad-hoc-signed binary.**

**Helper → client requirement (recommended)** [Inference built on Doc A23, A31]:

```
anchor apple generic
and identifier "com.example.CellKeeper"
and certificate leaf[subject.OU] = "<TEAM_ID_OF_THIS_HELPER>"
```

How the helper builds it:

- At startup, the helper reads its own Team ID from its own signature (Code Signing Services `SecCodeCopySelf` → signing information → team identifier).
- If there is **no** Team ID (ad-hoc or unsigned build), the helper restores defaults, logs a fault, and does **not** start the listener.
- Before passing the string to `setConnectionCodeSigningRequirement`, the helper compiles it with `SecRequirementCreateWithString`. This avoids the documented fatal error on a malformed string [Doc A15].
- This is the NSXPC equivalent of `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier: "com.example.CellKeeper")` on macOS 26 [Doc A19].
- It works unchanged for the project's Developer ID builds and for a contributor's own team builds.

Optional release-only hardening clauses. Each one should be verified with `codesign --verify -R '=<req>'`:

- Require Developer ID Application signing by adding the OIDs that TN3127 decodes: `certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists` [Doc A23]. This excludes development-signed builds, which are typically debuggable.
- Exclude debuggable clients: `!(entitlement["com.apple.security.get-task-allow"] exists)`. The syntax follows the requirement language [Doc A31]. Behaviour is unverified [Inference].
- Raise a minimum app version to limit downgrade attacks: `info[CFBundleVersion] >= "<N>"`. The `info[…]` comparisons are documented [Doc A31]. This only helps if the old version is the vulnerable one [Inference].

**App → helper requirement:** `anchor apple generic and identifier "com.example.CellKeeper.Helper" and certificate leaf[subject.OU] = "<app's own Team ID>"`. Set it with `NSXPCConnection.setCodeSigningRequirement` [Doc A15].

**Plug-in caveat** [DTS F2]: "This authorisation is based on the code signature of the process's main executable. If the process loads plug-ins, the daemon can't tell the difference." CellKeeper.app must not load third-party in-process code, and library validation must stay on (§4).

### 2.5 Ad-hoc and unsigned builds

- **XPC validation.** The certificate clauses fail for ad-hoc code [Doc A31]. With the recommended requirement, an ad-hoc client can never talk to a release helper. A helper refuses to run at all if it is itself ad-hoc. This is intentional.
- **SMAppService.** Quinn on symptoms such as losing background permission at every restart: "you should be signing both your embedded helper and your app with the same Apple-issued code-signing identity. If, for example, you are using ad hoc signing (Sign to Run Locally in Xcode parlance) then you will see problems like this." [DTS F7]
- **Why rebuilds break.** BTM evidently pins the registered daemon to its code identity [DTS F5], and an ad-hoc DR is tied to one exact build [Doc A23]. Every rebuild can therefore produce `Launch Constraint Violation (Constraint not matched)` until BTM is reset [Inference]. [3P T3] reports exactly this ("pins the helper's launch constraint to the cdhash it first approved").
- **Free Personal Team certificates.** Unknown. One forum poster with a free team could not get the *daemon* variant working, and Apple did not say whether free certificates suffice [DTS F7]. See §10, Q1.
- Contributor workflow is covered in §9.

---

## 3. Minimal helper protocol: design recommendation

### 3.1 Principles

1. **A closed vocabulary.** The client says *what* (for example "inhibit charging: on"), never *how*.
   - SMC key names, data types, byte values, and per-model tables are compiled into the helper's `ControlBackend`. They are never received over XPC.
   - This is the only module that contains undocumented operations. It sits behind a Swift protocol so it can be replaced by a mock in tests.
2. **Primitives only on the wire.** Use `Int`, `Bool`, and `UInt64` only, with no strings, arrays, dictionaries, `Data`, or `NSSecureCoding` classes from the client. `NSXPCInterface` otherwise has to whitelist classes for collections [Doc A22]. Avoiding them removes the deserialisation attack surface [Inference].
3. **Validate everything again in the helper.**
   - Unknown enum raw values are rejected with `.invalidArgument`.
   - Durations are clamped to per-control limits.
   - All mutations are idempotent: a request that doesn't change state does no hardware write.
4. **Restrictive-only.** The helper can only make charging *more* conservative than macOS default. `restoreDefaults` is always allowed, needs no lease, and is idempotent. This matches `06-safety-analysis.md` R8.
5. **Report actual state.** `readState` returns read-back hardware state, not intended state (06 R11, R30).
6. **What the helper must never contain:**
   - shell or `posix_spawn`/`NSTask`
   - `dlopen` and plug-ins
   - file reads or writes driven by client input
   - network access
   - general SMC read/write
   - a "debug passthrough" operation, even in debug builds. Exclude it at compile time, and have CI check that release binaries lack it [Inference].
   - GUI frameworks: "Do not run GUI code as root" [DTS F2]
   - third-party dependencies

### 3.2 Operations

| Operation | Lease needed | Side effects | Notes |
|---|---|---|---|
| `hello(clientProtocolVersion)` | no | none | Returns helper protocol version, build number, and capability bitmask. Must be the first call on a connection; other calls before it return `.incompatibleProtocol`. |
| `readState()` | no | none | Returns read-back state of each control, lease remaining, active interlocks, and last hardware error. |
| `acquireOrRenewLease(seconds)` | — | grants or renews | The lease is bound to *this* connection. One holder at a time; others get `.leaseHeldByOtherClient`. |
| `releaseLease()` | holder | restore defaults | |
| `setControl(control, active)` | holder | hardware write and read-back | `control` ∈ {`chargingInhibited`, `adapterDisabled`}. Rejected if the capability is absent, an interlock is active, or the call is rate limited. |
| `restoreDefaults()` | no | restore defaults | Any authorised client may call it, even while another holds the lease. It can only move toward safety. |
| `restoreDefaultsAndExit()` | no | restore, reply, `exit(0)` | Used for updates and uninstall. |

### 3.3 Versioning and capability negotiation

- `protocolVersion` is an integer constant shared by app and helper.
  - The helper accepts clients in `[minSupported … current]`.
  - Breaking changes bump it.
  - New methods are additive and gated by capability bits, because calling a selector an old helper lacks fails the call [Inference].
- `capabilities` (UInt64) is computed *by the helper* from its own hardware probe against a compiled-in allowlist of (model, OS family, key signature).
  - Unknown hardware gives empty capabilities, and the app shows monitor-only mode (06 R12, R12a).
  - The client cannot add capabilities.
- `helperBuild` is compared with the build number embedded in the app. A mismatch leads to `restoreDefaultsAndExit()` and a reconnect (§1.5).

### 3.4 Lease / dead-man's switch

- **Binding.** A lease belongs to one `NSXPCConnection`.
  - When that connection's `invalidationHandler` fires (app quit, crash, kill), the helper restores defaults immediately.
  - The lease also expires on time if it isn't renewed, which covers a hung app or a stalled policy loop.
- **Durations.** These come from `06-safety-analysis.md` R3 and are compile-time constants in the helper:
  - `adapterDisabled`: maximum 120 s
  - `chargingInhibited`: maximum 15 min
  - The app renews at about one third of the granted time.
- **Clock.** Measure expiry on a clock that **counts sleep**: `CLOCK_MONOTONIC`/`mach_continuous_time` "including while the system is asleep" [Doc A36, man L2]. That is the conservative choice, consistent with 06 H14. After a long sleep the lease has expired at wake, the helper restores defaults, and the app re-asserts within seconds.
  - The alternative is `CLOCK_UPTIME_RAW`/`mach_absolute_time`, which "does not increment while the system is asleep" [Doc A36]. It avoids a brief post-wake charge blip but keeps the inhibit for an arbitrarily long time if the app never comes back. Not recommended. [Inference]
- **App side.** The app should hold an `NSProcessInfo` activity while it holds a lease, so App Nap doesn't delay renewals. A late renewal is fail-safe, but it causes needless toggling. [Inference]

### 3.5 Safety interlocks enforced by the helper alone

These run independently of the app:

1. **Restore defaults at helper start**, before the listener starts. This covers boot (implied RunAtLoad), crash relaunch (KeepAlive), and updates (06 R2).
2. **On SIGTERM**: restore defaults, then exit. Handle SIGTERM with a dispatch signal source. Fit the work within `ExitTimeOut` [man L1]. `IORegisterForSystemPower` "does not provide system shutdown and restart notifications" [Doc A35], so SIGTERM is the shutdown hook.
3. **On `kIOMessageSystemWillSleep`**: clear `adapterDisabled`, then call `IOAllowPowerChange`. A sleep notification left unacknowledged only delays sleep, by up to 30 s [Doc A35]. Keep `chargingInhibited` only if the lease is valid (06 R16).
4. **On `kIOMessageSystemHasPoweredOn`**: read back hardware state and compare it with the intended state. Any mismatch, including external modification by another tool (06 R27), leads to defaults and a flag in `readState`.
5. **Battery floor.** The helper reads state of charge and AC status itself via IOKit power-source APIs. If SoC ≤ floor (a compiled constant from 06 §5), it clears both controls and refuses new ones until SoC recovers. If AC disconnects, it clears `adapterDisabled` (06 R18).
6. **Idle exit.** With no connections, no lease, and state at defaults for about 30–60 s, the helper calls `exit(0)`. `SuccessfulExit=false` means it is not respawned, and `MachServices` relaunch it on demand.
   - This keeps a root process from lingering.
   - It likely avoids the macOS 26+ prompt about background tasks that "remain active after a user quits the app" [Doc A40]. That effect is unverified (§10, Q5).
7. **Optional.** On each lease renewal, check that the helper's own containing bundle still exists at its path. If it doesn't, restore defaults and exit. This is cheap protection for the "running from the Trash" case [3P T3; Inference].

### 3.6 Rate limiting

All values are compile-time constants [Inference]:

- **Per-connection request budget.** Token bucket of about 10 requests/s burst and 2/s sustained. Excess requests get `.rateLimited`. Repeated abuse invalidates the connection.
- **Hardware dwell time.** A given control may change state at most once every 10 s and at most about 60 times per hour. Idempotent requests don't count.
- **Single writer.** All hardware access goes through one serial queue or actor. NSXPC delivers each connection's messages on its own queue, so serialisation must be explicit.

### 3.7 Logging and audit

- Use `os.Logger` with subsystem `com.example.CellKeeper.Helper` and categories `lifecycle`, `xpc`, `control`, `safety`.
- Log every connection accept or reject, every lease grant, renewal, and expiry, every hardware write (control, value, read-back, result), every interlock trigger, and every startup or shutdown restore.
- No values are sensitive, so mark them `.public`. PID and euid are recorded for information, not trust (§2.3).
- Users can collect logs with `log show --predicate 'subsystem == "com.example.CellKeeper.Helper"'`. For BTM problems, Apple's predicate covers `smd` and `backgroundtaskmanagementd` [DTS F9], and the deployment guide gives the `com.apple.backgroundtaskmanagement` predicate [Doc A40].

### 3.8 Multiple users and sessions

- The Mach service is in the system bootstrap, so any session's CellKeeper.app can connect, and only one connection can hold the lease [Inference].
- Optional policy: allow writes only from the active console user's session. Treat this as a product decision (§10).

---

## 4. Hardened Runtime, entitlements, and the App Sandbox

### 4.1 Hardened Runtime

- [Doc A27] The Hardened Runtime protects "against … code injection, dynamically linked library (DLL) hijacking, and process memory space tampering". It is required for notarization. Library validation "prevents a program from loading frameworks, plug-ins, or libraries unless they're either signed by Apple or signed with the same Team ID".
- [DTS F14] For a daemon that serves only its own client: "make sure your client enables the hardened runtime and doesn't include any entitlements to disable the security features that the hardened runtime enables by default". For extra assurance, sign with the `kill` flag.

| Target | Hardened Runtime | Entitlements | Notes |
|---|---|---|---|
| CellKeeper.app (release) | ON (`-o runtime[,kill]`) | none; specifically **no** `cs.disable-library-validation`, `cs.allow-dyld-environment-variables`, `cs.allow-jit`, `get-task-allow` | Developer ID signed and notarized. Debug builds get `get-task-allow` from Xcode. |
| CellKeeperHelper | ON | none (unless sandboxed, §4.3) | Same signing identity as the app [DTS F6, F8]. Stable identifier `com.example.CellKeeper.Helper` [DTS F5]. Embedded Info.plist with `CFBundleIdentifier` and version. |

### 4.2 Can the app be sandboxed while talking to the daemon?

- **Lookup.** "With App Sandbox, lookup of global Mach services fails unless you configure the `mach-lookup.global.name` temporary exception entitlement" (`com.apple.security.temporary-exception.mach-lookup.global-name`, an array of service names) [Doc A30].
- **Alternative: app groups.** "Apps within a group can communicate … using … Mach IPC, XPC … In macOS, use app groups to enable IPC communication between two sandboxed apps, or between a sandboxed app and a nonsandboxed app." The service name must be `<group identifier>.<unique name>` [Doc A29]. On macOS, group IDs of the form `<team identifier>.<group name>` need no portal registration [Doc A29]. Since macOS 15, team-prefixed IDs are one of the conditions that keep group-container access without prompts [Doc A37 (15)].
- **Registration constraint (the decisive one).** Since macOS 14.2: "The target executable must be sandboxed if the main app is sandboxed" [Doc A37 (14.2)]. Quinn: "If you're using `SMAppService` to install your daemon and the containing app is sandboxed then the daemon must be sandboxed … a new security restriction added in macOS 14.2" [DTS F12]. A sandboxed daemon needs an Info.plist with a bundle ID, either embedded in `__TEXT,__info_plist` or via an app-like wrapper [DTS F12, F1].
- [Doc A34] Authorization Services "is not supported within an App Sandbox because the API allows privilege escalation".

**Trade-offs** [Inference]:

| Option | Pros | Cons |
|---|---|---|
| **A. App not sandboxed, helper not sandboxed (recommended v1)** | Simplest. Works with SMAppService on 14.2+. No temporary exceptions. Contributor builds stay simple. | No sandbox containment of the UI process. The helper's narrow API still bounds what a compromised app can do (§8). |
| B. App sandboxed, helper sandboxed | Defence in depth for both. Option of a Mac App Store build. | The helper needs a sandbox exception to reach the SMC user client. The only documented candidate is `com.apple.security.temporary-exception.iokit-user-client-class` [Doc A30], and whether it works for writes is untested. The app needs a mach-lookup exception or a team-prefixed app group, which breaks ad-hoc contributor builds. Mac App Store review of undocumented SMC writes is unlikely to pass. |
| C. App not sandboxed, helper sandboxed | Contains the root process: an exploited helper still can't touch files or the network. | The same SMC-access uncertainty as B. Needs a bundle-ID'd helper. Worth evaluating after the SMC workstream establishes the exact IOKit access path. |

The App Sandbox mainly protects the *UI process*. A compromised app could still drive the helper's API, so sandboxing the app adds little against the main threat to the helper. Sandboxing the *helper* (C) is the more valuable hardening later.

---

## 5. Alternatives considered

| Alternative | Verdict | Why |
|---|---|---|
| **On-demand vs `KeepAlive=true`** | On-demand via `MachServices`, plus `KeepAlive {SuccessfulExit=false, Crashed=true}` | Unconditional `KeepAlive=true` keeps a root process alive forever, so the idle-exit rule (§3.5) can never apply. On-demand with crash relaunch gives restore-on-crash and restore-at-boot (implied RunAtLoad) without lingering [man L1; Inference]. |
| **Authorization Services prompts** (`AuthorizationExecuteWithPrivileges`, `do shell script … with administrator privileges`) | No | `AuthorizationExecuteWithPrivileges` has been deprecated since 10.7: "Do not use it in a widely distributed product." AppleScript admin and `sudo` are for ad hoc use or interactive CLIs only [DTS F2]. A prompt on every toggle is unusable, and one-shot root actions can't provide a dead-man's switch. Authorization Services is also not allowed in a sandbox [Doc A34]. An optional custom authorization right *inside* the daemon, for example to require admin approval before enabling adapter-disable, remains possible [DTS F2], but isn't needed. |
| **setuid-root tool** | Never | "Do not use a setuid-root executable. Ever." [DTS F2] |
| **launchd user agent** (`SMAppService.agent`) | Can't do the job | Runs "on behalf of the currently logged-in user", not as root [Doc A2, A13]. Useful only for non-privileged background work. |
| **Installer package (.pkg) installing a legacy daemon** | No | Quinn calls a .pkg "by far the easiest" if privileges are *only* needed at install [DTS F2]. CellKeeper needs ongoing privilege, and a legacy daemon in `/Library/LaunchDaemons` survives app deletion as a *runnable* root job. |
| **`SMJobBless`** | No | §1.7. |
| **DriverKit (dext)** | Not applicable | DriverKit families cover USB, HID, networking, PCI, serial, and audio, and Apple frames a dext as a way to talk to "your company's hardware device" [Doc A32]. No power-management or SMC family appears in the framework index. Dexts also need Apple-granted entitlements (`com.apple.developer.driverkit` and others) [Doc A32]. [Inference] There's no supported way for a dext to attach to Apple's internal SMC driver, and this wouldn't be less "undocumented" anyway. |
| **Kernel extension** | No | Kexts are for services that can't be done in user space, need user approval and a reboot on macOS 11+, and the kernel won't load one "if an equivalent … solution exists" [Doc A32]. Large attack surface. |
| **System Extensions (Endpoint Security, Network Extension)** | Not applicable | System extensions host DriverKit, Endpoint Security, and Network Extension providers [Doc A33]. Endpoint Security monitors process and file events for security products and needs a restricted entitlement [Doc A33]. Neither offers a battery or charging control surface. A "nice" property for comparison: system extensions are deleted with the app [Doc A33], but daemons aren't. |

---

## 6. Recommended architecture

```
+-------------------------- user session (non-root) ---------------------------+
|  CellKeeper.app   (Developer ID, Hardened Runtime, no plug-ins, v1 unsandboxed)|
|                                                                               |
|   UI / menu bar  <-->  Policy engine (decides WHEN to inhibit / discharge)    |
|                              |                                                |
|   HelperInstaller ---------- | ---- SMAppService.daemon(plistName:)           |
|     register / status /      |      .register() .status .unregister()         |
|     openSystemSettingsLoginItems()                                            |
|                              v                                                |
|   HelperClient: NSXPCConnection(machServiceName:"com.example.CellKeeper.Helper",
|                                 options: .privileged)                         |
|     setCodeSigningRequirement(<helper: same team + helper identifier>)        |
|     hello -> lease loop (renew ~1/3 of grant) -> setControl / readState       |
|     interruptionHandler: reconnect, hello, re-assert desired state            |
+------------------------------|------------------------------------------------+
                               |  XPC over Mach service (system bootstrap)
                               |  every message checked against client requirement
+------------------------------v------------ system domain (root) -------------+
|  CellKeeperHelper   (launchd job registered via SMAppService, BundleProgram,  |
|                      KeepAlive{SuccessfulExit=false,Crashed=true}, idle exit) |
|                                                                               |
|   NSXPCListener + setConnectionCodeSigningRequirement(                        |
|        anchor apple generic and identifier "com.example.CellKeeper"           |
|        and certificate leaf[subject.OU] = <own team>)                         |
|        |                                                                      |
|        v                                                                      |
|   Validator (closed enums, Bool, clamps) -> RateLimiter -> LeaseManager       |
|        |                                       (per-connection, CLOCK_MONOTONIC)
|        v                                                                      |
|   SafetySupervisor: start/TERM restore, sleep hook (IORegisterForSystemPower),|
|                     battery floor + AC-loss guard, read-back verification     |
|        |                                                                      |
|        v                                                                      |
|   ControlBackend (protocol)  <-- ONLY module with undocumented operations;    |
|        |                         per-model allowlist of keys/values;          |
|        |                         MockBackend for tests                         |
|   os_log audit trail (subsystem com.example.CellKeeper.Helper)                |
+------------------------------|------------------------------------------------+
                               |  IOKit user client (undocumented)
                               v
                    AppleSMC (kernel)  ->  charger / power path
```

**Lifecycle summary**

- **Install:** explain → `register()` → admin approves → `.enabled`.
- **Use:** connect → `hello` → lease → `setControl` → renew… → `releaseLease`, or quit (connection invalidated, so defaults are restored).
- **Update:** build mismatch → `restoreDefaultsAndExit` → reconnect.
- **Uninstall:** `restoreDefaults` → `unregister()` → delete app.

---

## 7. Minimal XPC protocol sketch (shape only, Swift-like pseudocode)

```swift
// ===== Shared module: CellKeeperHelperProtocol (linked by app AND helper; nothing else shared) =====

enum HelperIdentity {
    static let label           = "com.example.CellKeeper.Helper"   // == plist Label == MachServices key
    static let plistName       = "com.example.CellKeeper.Helper.plist"
    static let appIdentifier   = "com.example.CellKeeper"          // client signing identifier
    static let protocolVersion = 1
    static let minSupportedClientProtocol = 1
}

/// Closed set of controls. Raw values are the wire format; never reuse a retired value.
@objc enum HelperControl: Int {
    case chargingInhibited = 1   // keep battery from charging while on AC
    case adapterDisabled   = 2   // run from battery while on AC (discharge-to-target)
}

/// Capability bits, computed by the helper from its own hardware allowlist probe.
struct HelperCapabilities: OptionSet { let rawValue: UInt64
    static let chargingInhibit   = Self(rawValue: 1 << 0)
    static let adapterDisable    = Self(rawValue: 1 << 1)
    static let batteryFloorGuard = Self(rawValue: 1 << 2)
}

/// Interlocks currently forcing the safe state (reported, never settable).
struct HelperInterlocks: OptionSet { let rawValue: UInt64
    static let belowBatteryFloor   = Self(rawValue: 1 << 0)
    static let acDisconnected      = Self(rawValue: 1 << 1)
    static let externalModification = Self(rawValue: 1 << 2)
    static let unknownHardware     = Self(rawValue: 1 << 3)
}

@objc enum HelperStatus: Int {
    case ok = 0
    case incompatibleProtocol, unsupportedControl, invalidArgument
    case noLease, leaseHeldByOtherClient, rateLimited
    case blockedByInterlock, hardwareError, shuttingDown
}

/// NSXPC interface. Rules: primitive arguments only; exactly one reply block; no strings,
/// collections, Data, or NSSecureCoding objects from the client; every method idempotent.
@objc protocol CellKeeperHelperXPC {

    /// Must be the first call on a connection. No side effects.
    func hello(clientProtocolVersion: Int,
               reply: @escaping (_ status: Int,
                                 _ helperProtocolVersion: Int,
                                 _ helperBuild: Int,            // CFBundleVersion of helper
                                 _ capabilities: UInt64) -> Void)

    /// Read-back hardware state (not intended state). No side effects.
    func readState(reply: @escaping (_ status: Int,
                                     _ activeControls: UInt64,  // bit (1 << control.rawValue)
                                     _ leaseRemainingSeconds: Int,
                                     _ interlocks: UInt64,
                                     _ lastHardwareError: Int) -> Void)

    /// Lease is bound to THIS connection. Helper clamps `seconds` per control limits
    /// (adapterDisabled <= 120 s, chargingInhibited <= 900 s) and returns what it granted.
    func acquireOrRenewLease(seconds: Int,
                             reply: @escaping (_ status: Int, _ grantedSeconds: Int) -> Void)

    /// Ends the lease and restores defaults.
    func releaseLease(reply: @escaping (_ status: Int) -> Void)

    /// The ONLY mutating call that can move away from defaults. Requires the lease.
    /// `control` is validated with HelperControl(rawValue:); unknown -> .invalidArgument.
    func setControl(_ control: Int, active: Bool,
                    reply: @escaping (_ status: Int) -> Void)

    /// Always permitted for any authorised client; can only move toward the safe state.
    func restoreDefaults(reply: @escaping (_ status: Int) -> Void)

    /// Restore defaults, reply, then exit(0) so launchd runs the updated binary next time.
    func restoreDefaultsAndExit(reply: @escaping (_ status: Int) -> Void)
}

// ===== Helper-internal seam (NOT exposed over XPC) =====

/// The only place undocumented operations live. The production implementation holds a
/// per-model allowlist; MockControlBackend is used in tests and in contributor builds.
protocol ControlBackend {
    func probe() -> HelperCapabilities            // from compiled-in allowlist only
    func apply(_ control: HelperControl, active: Bool) throws
    func readBack() throws -> Set<HelperControl>
    func restoreDefaults() throws                  // must be safe to call at any time, repeatedly
}
```

Helper connection acceptance:

1. Compile the requirement once at startup (§2.4).
2. Call `listener.setConnectionCodeSigningRequirement(req)`.
3. In `listener(_:shouldAcceptNewConnection:)`, set `exportedInterface`, set a **per-connection** exported session object (which owns that connection's lease state), set `invalidationHandler` (if this connection is the lease holder, restore defaults), then `resume()` and return true [Doc A22].

---

## 8. Threat model

**Assets**

- The battery's charging state, and therefore the user's expectation of a charged Mac.
- System availability: no unexpected dead battery.
- Integrity of a root process.
- The user's trust in what the UI reports.

**Who can reach the helper**

| Actor | Can look up the Mach service? | Can send messages that get processed? | Notes |
|---|---|---|---|
| Genuine CellKeeper.app (same team, identifier) | yes | **yes** | The only intended client. |
| Any other process of any local user (malware, other apps, scripts) | yes (global name) | **no**: fails the code-signing requirement, so the connection is invalidated or dropped [Doc A15, A16, A19] | Includes ad-hoc binaries claiming the `com.example.CellKeeper` identifier [Doc A31]. |
| A process that injects code into CellKeeper.app | — | only if injection succeeds | Blocked by Hardened Runtime and library validation unless entitlements weaken them [Doc A27, DTS F14]. Debug builds (`get-task-allow`) are attachable, so the release requirement can exclude them (§2.4). |
| An older, validly signed CellKeeper version (downgrade) | yes | yes | Mitigation: a minimum-version clause (§2.4) and keeping old helpers safe. Residual risk. |
| Remote attacker | no direct path | only via compromise of the app | The helper has no network listener. |
| Root / kernel attacker | — | — | Out of scope: already more privileged than the helper. |
| Malicious code change (supply chain, PR) | — | — | Mitigations: CODEOWNERS and mandatory review for `Helper/`; tiny helper; no third-party dependencies; signed and notarized releases (06 H15). |

**What an authorised (or hijacked) client can do**

- Turn `chargingInhibited` and `adapterDisabled` on or off within leases, rate limits, and interlocks.
- Read state.
- Make the helper restore defaults and exit.
- Nothing else: no SMC key choice, no files, no processes, no network.

**Worst cases**

| Scenario | Outcome | Bound |
|---|---|---|
| Hijacked app holds charging inhibited indefinitely by renewing | Mac doesn't charge beyond its current level, which is an inconvenience | Battery floor interlock clears it at SoC ≤ floor. The UI shows actual state. |
| Hijacked app keeps adapter disabled | Battery drains while on AC | Lease ≤ 120 s per renewal, floor interlock, cleared before sleep and on AC loss. The Mac shouldn't die from it. |
| Rapid toggling to stress hardware | Relay or charger chatter | Dwell-time and hourly change caps. |
| Lease squatting (denial of service against the legitimate app) | App can't control charging | `restoreDefaults` still works for everyone. The user can quit the offending process. Low impact. |
| Memory-safety bug in the helper's XPC handling | **Local privilege escalation to root**: the true worst case | Swift, primitives-only interface, small code size, no dependencies, fuzz and unit tests through the anonymous-listener harness [Doc A24]. Optional helper sandbox (§4.2, C). |
| Wrong or unknown SMC semantics on new hardware | Undefined charging behaviour | Per-model allowlist; unknown hardware leads to monitor-only. Read-back verification (06 R11, R12). |
| App deleted while state is non-default | State persists if the helper can't run | The lease reverts within ≤ 120 s or ≤ 15 min, or immediately on app quit. Restore at boot if the job can still start. Residual risk depends on SMC persistence (§10, Q2). |
| Replaced helper binary on disk | Attacker code as root | BTM pins the DR [DTS F5], `SpawnConstraint` [WWDC W2], and the bundle signature [Doc A10] together prevent launching a modified helper [Inference]. |

---

## 9. Developer and contributor workflow

**Signing tiers** [Inference unless cited]:

| Tier | Who | Signing | What works |
|---|---|---|---|
| 0 | Any contributor, no Apple ID setup | Ad-hoc ("Sign to Run Locally") | App, UI, telemetry, policy engine. Helper features use **`MockControlBackend` over an anonymous `NSXPCListener`** in-process (TN3113), so the full XPC protocol is exercised without root [Doc A24]. The real helper refuses to run because it has no Team ID (§2.4). SMAppService registration is unreliable with ad-hoc signing [DTS F7]. |
| 1 | Contributor with a free Apple ID (Personal Team) | Apple Development | Stable DR across rebuilds [Doc A23]. **May** allow SMAppService daemon registration. Unverified (§10, Q1). Same-team validation works automatically because the helper derives the team from itself. |
| 2 | Maintainers / paid team | Apple Development + Developer ID | Full helper path. Release builds are Developer ID signed and notarized. By default, Gatekeeper expects downloaded software to be "signed by a registered developer and notarized by Apple" [Doc A38]. |

**Practices**

- **Separate identities for dev builds.** Use distinct bundle ID, label, and Mach service suffixes for development (for example `com.example.CellKeeper.dev`, `…Helper.dev`), driven by an `.xcconfig`. A dev build and a release build then never collide in BTM. Mixed signings of one identity cause errors [DTS F6, F8].
- **Where to run builds.** Run from the Xcode build directory or `/Applications`, never from Desktop, Documents, or Downloads ("MAC-protected directories … cause all sorts of weird behaviour") [DTS F8].
- **Never change** the helper's code-signing identifier or label after the first release [DTS F5].
- **Debugging commands:**
  - `sudo launchctl list com.example.CellKeeper.Helper` [DTS F1]
  - `sudo launchctl print system/com.example.CellKeeper.Helper`
  - `sudo launchctl kickstart -k system/com.example.CellKeeper.Helper` [man L2]
  - `log stream --predicate 'subsystem == "com.example.CellKeeper.Helper"'`
  - BTM logs via the predicate in [DTS F9]
  - `sfltool dumpbtm` [Doc A40]
- **Resetting BTM.** `sfltool resetbtm` followed by a restart is the documented reset [Doc A10, A40]. It wipes **all** login-item approvals on that Mac, so document it as a last resort.
- **CI** builds unsigned/ad-hoc and runs protocol, validation, lease, and rate-limit tests against the mock backend through the anonymous listener. No CI job ever registers a daemon.
- **Release pipeline.** Sign the app and helper with the same Developer ID with `-o runtime` (consider `kill`). Notarize. Verify that `codesign -d -vvv` on the helper shows the expected identifier, Team ID, and runtime flag, and that there is no `Launch Constraints` field unless one is intended [DTS F8]. Verify that the release requirement strings pass `codesign --verify -R`.
- **macOS 27 quarantine.** launchd won't load plists that carry the quarantine attribute [Doc A37 (27)]. Test that a notarized build downloaded through a browser still registers the daemon (§10, Q4).
- **macOS 26+ background prompt.** Test what users see when the app quits while the helper lingers [Doc A40]. The idle-exit timer should keep this from happening.

---

## 10. Open questions

1. **Signing identity for contributors.** Does SMAppService daemon registration work reliably with (a) a **free Personal Team** Apple Development certificate, and (b) ad-hoc signing on macOS 14–27? Evidence so far: ad-hoc is problematic [DTS F7, 3P T3], and free-team daemons are unconfirmed [DTS F7]. Test on a clean VM.
2. **SMC persistence** (owner: SMC workstream; also 06 §7). Do the charging-inhibit and adapter-disable states persist across helper exit, sleep, wake, restart, shutdown, and power loss on Apple silicon (M4 first)? The answer decides whether boot-time restore (implied RunAtLoad) is *required* or optional. It also decides how bad an orphaned state is.
3. **Root and sandbox needs of the SMC path.** Do the required SMC writes need root, or only access to the IOKit user client? Would a sandboxed helper with `iokit-user-client-class` work (§4.2, C)?
4. **macOS 27 quarantine rule.** Does it affect plists inside quarantined, notarized app bundles registered via SMAppService, or only legacy plists [Doc A37 (27)]?
5. **macOS 26+ "background tasks remain active" prompt** [Doc A40]. Does it apply to daemons? How long after the app quits does it trigger? Does idle exit avoid it?
6. **Developer ID.** Will the project obtain one (paid Apple Developer Program)? Who holds the keys? Without a Developer ID there's no reliable shipping path for the helper (§2.5, §9).
7. **Policy ownership** (product decision). Lease-only (charging is limited only while the app runs; recommended to start) or a helper-autonomous mode where a bounded policy keeps working when the app isn't running? The autonomous mode moves policy, configuration validation, and more code into root and conflicts with "losing the app must not leave the Mac in a non-default state".
8. **Multi-user policy.** Should only the active console user be able to take the lease (§3.8)?
9. **Behaviour when the app is moved or renamed** after registration. Does BTM re-resolve `BundleProgram` via Launch Services? The anecdote of a helper running from the Trash [3P T3] suggests yes.
10. **Release requirement clauses.** Should the release requirement add the Developer ID OIDs, `get-task-allow` exclusion, and a minimum version (§2.4)? Each needs verification with `codesign --verify -R`.
11. **`unregister()` error codes on macOS 26/27.** Is the reported EPERM-instead-of-`kSMErrorJobNotFound` change real? It is unverified third-party information.

---

## 11. Sources

All URLs were fetched during this research on 2026-10-06. Apple documentation pages were retrieved through their public JSON renderings (`developer.apple.com/tutorials/data/documentation/<path>.json`). The human-readable URLs are listed.

**Apple documentation, technotes, release notes, guides**

- **[A1]** SMAppService — https://developer.apple.com/documentation/servicemanagement/smappservice — macOS 13+. Replaces plist installs for agents and daemons.
- **[A2]** Service Management overview — https://developer.apple.com/documentation/servicemanagement — Defines agents and daemons. Daemons run as root and respond via XPC.
- **[A3]** `daemon(plistName:)` — https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:) — Plist must be in `Contents/Library/LaunchDaemons`.
- **[A4]** `register()` — https://developer.apple.com/documentation/servicemanagement/smappservice/register() — Admin approval; bootstrapped every boot; errors.
- **[A5]** `unregister()` — https://developer.apple.com/documentation/servicemanagement/smappservice/unregister() and `unregister(completionHandler:)` — https://developer.apple.com/documentation/servicemanagement/smappservice/unregister(completionhandler:) — Terminates a running daemon; `kSMErrorJobNotFound`.
- **[A6]** `mainApp` — https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp — Launch at login.
- **[A7]** `openSystemSettingsLoginItems()` — https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems()
- **[A8]** `SMAppService.Status` — https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum and `.requiresApproval` — https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval — Status cases; revoked consent also returns `.requiresApproval`.
- **[A9]** Updating helper executables from earlier versions of macOS — https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos — Layout, `BundleProgram`, `AssociatedBundleIdentifiers`, register daemons first, approval cascades, UX guidance.
- **[A10]** Updating your app package installer to use the new Service Management API — https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api — Sealed plists; stale Login Items entries; `sfltool resetbtm`.
- **[A11]** `SMJobBless` — https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:) — Deprecated in 13.0; requirements.
- **[A12]** `SMAppServiceErrorDomain` — https://developer.apple.com/documentation/servicemanagement/smappserviceerrordomain (macOS 15) and Service Management Errors — https://developer.apple.com/documentation/servicemanagement/service-management-errors
- **[A13]** XPC — https://developer.apple.com/documentation/xpc — Daemon process model; daemons can't initiate connections to user processes.
- **[A14]** XPC updates — https://developer.apple.com/documentation/updates/xpc — The March 2024 (14.4) peer-requirement APIs.
- **[A15]** `NSXPCConnection.setCodeSigningRequirement(_:)` — https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:) — macOS 13; invalidation on mismatch; malformed requirement is fatal.
- **[A16]** `NSXPCListener.setConnectionCodeSigningRequirement(_:)` — https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:) — macOS 13.
- **[A17]** `xpc_connection_set_peer_code_signing_requirement` — https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_code_signing_requirement(_:_:) — macOS 12.
- **[A18]** `xpc_connection_set_peer_team_identity_requirement` — https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_team_identity_requirement(_:_:) and `…_lightweight_code_requirement` — https://developer.apple.com/documentation/xpc/xpc_connection_set_peer_lightweight_code_requirement(_:_:) — macOS 14.4; per-message checks.
- **[A19]** `XPCPeerRequirement` — https://developer.apple.com/documentation/xpc/xpcpeerrequirement; `isFromSameTeam(andMatchesSigningIdentifier:)` — https://developer.apple.com/documentation/xpc/xpcpeerrequirement/isfromsameteam(andmatchessigningidentifier:); `XPCListener.init(service:targetQueue:options:requirement:incomingSessionHandler:)` — https://developer.apple.com/documentation/xpc/xpclistener/init(service:targetqueue:options:requirement:incomingsessionhandler:); `XPCSession.setPeerRequirement(_:)` — https://developer.apple.com/documentation/xpc/xpcsession/setpeerrequirement(_:) — macOS 26; non-matching requests dropped.
- **[A20]** `XPCListener` — https://developer.apple.com/documentation/xpc/xpclistener and `XPCSession` — https://developer.apple.com/documentation/xpc/xpcsession — macOS 14.
- **[A21]** `xpc_connection_get_pid` — https://developer.apple.com/documentation/xpc/xpc_connection_get_pid(_:) — PID reuse warning.
- **[A22]** `NSXPCConnection` — https://developer.apple.com/documentation/foundation/nsxpcconnection (security attributes; no public audit token); `init(machServiceName:options:)` — https://developer.apple.com/documentation/foundation/nsxpcconnection/init(machservicename:options:); `.privileged` — https://developer.apple.com/documentation/foundation/nsxpcconnection/options/privileged; `NSXPCInterface` — https://developer.apple.com/documentation/foundation/nsxpcinterface; `listener(_:shouldAcceptNewConnection:)` — https://developer.apple.com/documentation/foundation/nsxpclistenerdelegate/listener(_:shouldacceptnewconnection:)
- **[A23]** TN3127: Inside Code Signing: Requirements — https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements — DRs; ad-hoc DR tied to one version; Developer ID and Apple Development DR anatomy; don't hand-write requirements.
- **[A24]** TN3113: Testing and debugging XPC code with an anonymous listener — https://developer.apple.com/documentation/technotes/tn3113-testing-xpc-code-with-an-anonymous-listener — In-process XPC testing. Can't debug privileged code this way.
- **[A25]** Applying launch environment and library constraints — https://developer.apple.com/documentation/security/applying-launch-environment-and-library-constraints — `SpawnConstraint` in launchd plists; violation log format.
- **[A26]** Defining launch environment and library constraints — https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints — Facts (`team-identifier`, `signing-identifier`, `is-init-proc`, `validation-category`, …).
- **[A27]** Hardened Runtime — https://developer.apple.com/documentation/security/hardened-runtime and Disable Library Validation entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
- **[A28]** App Sandbox — https://developer.apple.com/documentation/security/app-sandbox
- **[A29]** App Groups entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups — Mach/XPC service naming for sandboxed ↔ non-sandboxed IPC.
- **[A30]** App Sandbox Temporary Exception Entitlements (archive, 2017) — https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html — `mach-lookup.global-name`, `iokit-user-client-class`.
- **[A31]** Code Signing Requirement Language (archive) — https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html — `subject.OU` = Team ID; ad-hoc means no certificates; `anchor apple generic`; `entitlement[]`/`info[]` clauses.
- **[A32]** DriverKit — https://developer.apple.com/documentation/driverkit and Implementing drivers, system extensions, and kexts — https://developer.apple.com/documentation/kernel/implementing_drivers_system_extensions_and_kexts
- **[A33]** System Extensions — https://developer.apple.com/documentation/systemextensions and Endpoint Security — https://developer.apple.com/documentation/endpointsecurity
- **[A34]** Authorization Services — https://developer.apple.com/documentation/security/authorization-services — Not supported in App Sandbox.
- **[A35]** `IORegisterForSystemPower` — https://developer.apple.com/documentation/iokit/1557114-ioregisterforsystempower and `kIOMessageSystemWillSleep` — https://developer.apple.com/documentation/iokit/kiomessagesystemwillsleep — Sleep and wake messages; 30 s acknowledgement; no shutdown notifications.
- **[A36]** `mach_absolute_time` — https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time and `mach_continuous_time` — https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time — Which clocks count sleep.
- **[A37]** macOS release notes. Index: https://developer.apple.com/documentation/macos-release-notes
  - 13.2: https://developer.apple.com/documentation/macos-release-notes/macos-13_2-release-notes (SMAppService daemon regression fixed)
  - 13.3: https://developer.apple.com/documentation/macos-release-notes/macos-13_3-release-notes (notification fix)
  - 14.2: https://developer.apple.com/documentation/macos-release-notes/macos-14_2-release-notes (sandboxed app → sandboxed daemon)
  - 15: https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes (app group container protection)
  - 15.4: https://developer.apple.com/documentation/macos-release-notes/macos-15_4-release-notes ("Login Items & Extensions" path)
  - 27: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes (quarantined plists not loaded)
  - Also scanned, nothing relevant found: 26: https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes, 26.1–26.6, 27.2 beta 3.
- **[A38]** Apple Platform Security (August 2026, PDF) — https://help.apple.com/pdf/security/en_US/apple-platform-security-guide.pdf — SIP and MAC apply "regardless of whether that process is running sandboxed or with administrative privileges". Non-platform binaries need valid certificate chains. (No SMAppService or BTM coverage found.)
- **[A39]** Apple Support, Reset the SMC of your Mac — https://support.apple.com/en-us/102605 — On Apple silicon, restart or shut down; "SMC resets automatically".
- **[A40]** Apple Platform Deployment, Manage login items and background tasks on Mac — https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web — MDM auto-approval rules; macOS 26+ prompt for background tasks that remain active after quit; `sfltool dumpbtm`/`resetbtm`; log predicates.

**WWDC**

- **[W1]** WWDC22 10096, What's new in privacy — https://developer.apple.com/videos/play/wwdc2022/10096/ — Login items notification; daemons need admin approval; works in Mac App Store apps.
- **[W2]** WWDC23 10266, Protect your Mac app with environment constraints — https://developer.apple.com/videos/play/wwdc2023/10266/ — Launch, parent, and responsible constraints; `SpawnConstraint` with SMAppService; enforcement versions.

**Apple Developer Forums (Apple engineers)**

- **[F1]** Getting Started with SMAppService (Quinn) — https://developer.apple.com/forums/thread/802443 — Step-by-step daemon embedding, approval, `launchctl` checks, sandbox matrix, `sfltool resetbtm`.
- **[F2]** BSD Privilege Escalation on macOS (Quinn) — https://developer.apple.com/forums/thread/708765 — Options matrix; never setuid; authorise the client via XPC; plug-in caveat; no GUI as root.
- **[F3]** Validating Signature Of XPC Process (Quinn) — https://developer.apple.com/forums/thread/681053 — API-by-OS recommendations; revision history to 2026-07-09.
- **[F4]** macOS 14 XPC vs Foundation XPC (Quinn) — https://developer.apple.com/forums/thread/769138 — `XPCListener` lacked requirements until macOS 26.
- **[F5]** Upgrading an SMAppService daemon and changing the plist (Quinn) — https://developer.apple.com/forums/thread/795022 — Identifier/DR change leads to spawn-constraint violation; fix by keeping the identifier.
- **[F6]** Privileged daemon appears as unsigned in Login Items (Quinn) — https://developer.apple.com/forums/thread/757463 — Sign the daemon the same way as the app; upgrade fragility.
- **[F7]** SMAppService Sample Code seems broken (Quinn) — https://developer.apple.com/forums/thread/799910 — Ad-hoc signing causes problems; same Apple-issued identity; working plist and listener names; TN3113.
- **[F8]** macOS 26 Launch Constraints (Quinn) — https://developer.apple.com/forums/thread/799933 — Constraints cause failures; same identity; avoid MAC-protected folders; `resetbtm` fix.
- **[F9]** SMAppService: How to recover from broken LaunchDaemon registration (Frameworks Engineer) — https://developer.apple.com/forums/thread/707482 — State persisted "to preserve user intent"; reset; debug log predicate; status raw values.
- **[F10]** Deleting app while its running (Quinn) — https://developer.apple.com/forums/thread/736272 — System doesn't know if the app is really deleted; uninstall via `unregister`.
- **[F11]** Are uninstall routines ever run for normal macOS app removal? (Quinn) — https://developer.apple.com/forums/thread/766550 — Launch Services unregisters app extensions; Finder prompts for system extensions.
- **[F12]** System Keychain not available from a Daemon (Kevin Elliott, Quinn) — https://developer.apple.com/forums/thread/759976 — `BundleProgram` semantics; "whether or not the target exists"; sandboxed-app → sandboxed-daemon since 14.2.
- **[F13]** [SMAppService] Is this the expected UX for embedded LaunchDaemons? (Quinn) — https://developer.apple.com/forums/thread/721919 — 13.1 problems (context only).
- **[F14]** Does NSXPCConnection.setCodeSigningRequirement perform dynamic code signature checks? (Quinn) — https://developer.apple.com/forums/thread/797913 — Threat-model framing; Hardened Runtime on the client; `kill` flag.
- **[F15]** XPC restricted to processes with the same code signing? (Quinn) — https://developer.apple.com/forums/thread/72881 — PID reuse; first-message vulnerability; audit token SPI unsupported.

**Local man pages (macOS 27.0.1, read on the research Mac; not URLs)**

- **[L1]** `launchd.plist(5)` — `BundleProgram`, `KeepAlive` (`SuccessfulExit`, `Crashed`), `RunAtLoad`, `MachServices`, `ExitTimeOut`, `ThrottleInterval`, `ProcessType`, `AssociatedBundleIdentifiers`.
- **[L2]** `launchctl(1)` (`kickstart`, `print`, `bootout`) and `clock_gettime(3)` (`CLOCK_MONOTONIC` vs `CLOCK_UPTIME_RAW`). Referenced in the text as [man L2].

**Third-party, secondary (labelled [3P])**

- **[T1]** Csaba Fitzl, "macOS Service Management – The SMAppService API – Quick Notes" (2023-09-28) — https://theevilbit.github.io/posts/smappservice/ — BTM records track Team ID and DR; daemon state transitions. Background only; not cited for any claim above.
- **[T2]** Wojciech Reguła, "Learn XPC exploitation – Part 2: Say no to the PID!" (2020-04-23) — https://wojciechregula.blog/post/learn-xpc-exploitation-part-2-say-no-to-the-pid/ — `POSIX_SPAWN_SETEXEC` PID-reuse attack on XPC helpers.
- **[T3]** johnlofty/portkeeper PR #4 (GitHub; a port-mapping tool, not a battery app) — https://github.com/johnlofty/portkeeper/pull/4 — Anecdote: an ad-hoc-signed SMAppService helper was pinned to its first cdhash, so later builds hit a launch-constraint violation; the old daemon kept running from the Trash.

No code was copied from any battery-management app, and no proprietary battery app was used as a source.
