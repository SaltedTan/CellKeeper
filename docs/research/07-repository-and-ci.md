# CellKeeper research 07: repository layout and macOS GitHub Actions CI

Date: 2026-10-06
Workstream: Repository layout and macOS GitHub Actions CI
Local toolchain used for all local verification: Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1, Apple silicon.

Evidence tags used throughout:

- [F] fetched from a primary or named secondary source (see Sources).
- [V] verified locally on Xcode 27.0 with a scratch project that mirrors the planned layout (appendix A contains the files).
- [I] inference or general knowledge that I could not verify here. Treat as a hypothesis.

Nothing could be verified locally on Xcode 16.x or 26.x (only 27.0 is installed). Anything about those toolchains is [F] or [I], and the recommended CI matrix exists precisely to close that gap.

---

## Summary

1. **Runner and Xcode.** Use `macos-26` (arm64, Xcode 26.6 is the image default) as the required job and select Xcode explicitly with a job-level `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`. Add `macos-15` with Xcode 16.0 as the "oldest supported toolchain" job (the README promises 16.0, and Xcode 16.0 to 16.2 are the only 16.x releases that run on macOS 14 hosts [F]) and the `xcode-27` preview image as a non-required job. Do not use `macos-latest` (it moves) or `macos-14` (deprecated, brownouts started 2026-10-05, removed 2026-11-02). [F]
2. **Biggest compatibility trap: the project file format.** Xcode 16.0 is the oldest Xcode that can open `objectVersion = 77` with `PBXFileSystemSynchronizedRootGroup` [F]. Xcode 27.0 writes versions well above 77: its own bundled project prototypes use `objectVersion = 90` [V], and a CocoaPods report says a GUI-created Xcode 27.0 App project got 110 [F]; a reported case says Xcode 26.6 cannot open a 110 project [F]. Xcode 27.2 (beta) adds a JSON `.xcproj` format that "is compatible with Xcode 27 and later" only [F]. So: keep `objectVersion = 77`, never switch the project to the JSON format, and add a CI guard that fails if `objectVersion` changes (included in the workflow below, tested). I could not test whether the Xcode 27 GUI bumps the version on save; the guard makes that safe either way.
3. **Swift tools version 6.0 is the right choice.** It gives Swift 6 language mode by default for package targets [V] and works on Xcode 16.0+. It forbids `.macOS(.v26)`, `.treatAllWarnings(...)` and `.defaultIsolation(...)` in the manifest [V], which is a feature for compatibility. Swift Testing runs under plain `swift test` on Xcode 16+ [F][V].
4. **The planned layout works.** I built a scratch project with exactly the planned shape (hand-written objectVersion 77 pbxproj, synchronized group, `XCLocalSwiftPackageReference` to `Packages/CellKeeperKit`, xcconfig with git-ignored `Local.xcconfig`). A fresh `git clone` built and tested with the exact CI commands and zero setup [V]. Keep `Packages/CellKeeperKit` (do not add a root `Package.swift`). The pitfalls that did bite are listed in section 6, the main ones being: everything non-source inside a synchronized folder is copied into the app bundle, a custom `Info.plist` needs a membership exception, and the package's `platforms` must not exceed the app's deployment target. I then ran the CI commands against three snapshots of the lead's actual worktree (section 6.3): `swift test` passes (101 Swift Testing tests in the latest), strict Debug and Release builds are clean, the ad-hoc signed Release verifies with the sandbox entitlement, and the lead's own `.github/workflows/ci.yml` run-blocks pass under bash 3.2. Problems I found were a flaky test (`Concurrent evaluations never overlap backend requests`, about 7 percent failure under `xcodebuild test`, a test-design flake), a missing `.gitignore` and a missing `contents.xcworkspacedata`; the lead fixed all three while I worked. Still open: **the README promises Xcode 16.0 but CI only tests Xcode 16.4**, which cannot run on macOS 14 (use Xcode 16.0 in the old-toolchain job, section 6.3 finding 8), and one optional two-line hardening of the package reference.
5. **CI design.** `permissions: contents: read`, PR-only cancel-in-progress, job timeouts, SHA-pinned `actions/checkout` (v7.0.1) with Dependabot to keep it current, no third-party actions, no caching (cold local test plus Debug and Release builds is about 30 s), warnings-as-errors on CI only and only on the reference toolchain, ad-hoc signing overrides instead of `CODE_SIGNING_ALLOWED=NO` so entitlements are actually embedded and verifiable. The workflow in section 3.5 was parsed and its `run:` blocks were executed locally under bash 3.2 on a fresh clone and on a copy of the lead's actual project, including negative tests.
6. **Correction to the brief.** Contributor Covenant 3.0 is licensed **CC BY-SA 4.0** (ShareAlike), not CC BY 4.0 [F]. Keep the Attribution section intact.

---

## 1. GitHub-hosted macOS runner images (as of 2026-10-06)

### 1.1 Image matrix [F]

Source: runner-images README, per-image software READMEs, issues #14404, #13518, #14344.

| Label(s) | Arch | macOS (image version) | Xcode installed (default marked) | Status |
|---|---|---|---|---|
| `macos-26`, `macos-latest`, `macos-26-xlarge` | arm64 | 26.6.2 (25G83), image 20260907.0351.1 | **26.6 (default)**, 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1 | GA. `macos-latest` currently points here |
| `macos-26-intel`, `macos-26-large`, `macos-latest-large` | x64 | 26.6.1 (25G76), image 20260824.0517.1 | same list as arm64 | GA |
| `macos-15`, `macos-15-xlarge` | arm64 | 15.7.9 (24G830), image 20260907.0337.1 | 26.3, 26.2, 26.1.1, 26.0.1, **16.4 (default)**, 16.3, 16.2, 16.1, 16.0 | GA (oldest GA image) |
| `macos-15-intel`, `macos-15-large` | x64 | 15.7.9, image 20260824.0482.1 | same list | GA |
| `xcode-27`, `xcode-27-xlarge` | arm64 | macOS 27.0 (26A428), image 20260928.0222.1 | 27.2 (beta), 27.1, **27.0 (default)** | **Preview** (issue #14404) |
| `macos-14`, `macos-14-xlarge` (arm64), `macos-14-large` (x64) | both | 14.8.9 (arm64 image) | 16.2, 16.1, 15.4 (default), 15.3 ... | **Deprecated** (issue #13518) |

Label rules from the README [F]: plain labels (`macos-15`, `macos-26`, `macos-latest`) are arm64. `-intel` and `-large` are x64 (except `macos-14`, where only `-large` exists for x64). `-xlarge` is arm64. `-large`/`-xlarge` are larger runners, offered to organisations and enterprises on Team/Enterprise plans, and are not needed here.

Hardware of the standard runners [F]: arm64 = 3 vCPU (M1), 7 GB RAM, 14 GB SSD; Intel = 4 vCPU, 14 GB RAM, 14 GB SSD. Standard runners are "free and unlimited on public repositories". The free plan allows 5 concurrent macOS jobs (shared with larger runners) [F, limits page].

Tooling on the images that is relevant here [F]: Xcbeautify 3.2.1, SwiftFormat 0.63.0, Git 2.55.0, GitHub CLI 2.100.0 (2.101.0 on `xcode-27`). Nothing else is needed for this project.

Notes on the Xcode column:

- Xcode 27.0 on the `xcode-27` image is build 27A266a, identical to the local toolchain [F][V].
- The `xcode-27` image's base OS changed: the issue's original text says "macOS 26 with Xcode 27", an edit dated 2026-09-16 says it "now uses MacOS 27 OS as its base OS", and the software README shows macOS 27.0 [F].
- The preview is explicitly outside the SLA: "Any workflows that run on a beta image do not fall under the customer SLA", "there could be queueing issues" [F].
- Xcode versions are replaced on patch releases ("when a new patch version is released, the previous patch version will be replaced") and the symlink naming follows that: 26.4.1 lives at `Xcode_26.4.1.app` with `Xcode_26.4.app` as a symlink [F]. So pinning the major.minor path (`Xcode_26.6.app`) survives patch updates.

### 1.2 Deprecation schedule [F]

- Policy: "We support (at maximum) 2 GA images and 1 beta image at a time"; deprecation of the oldest label begins once the newest OS image reaches GA; sequence is announcement with a date, scheduled brownouts, removal. "Only one major version of Xcode will be supported per macOS version" (note the `macos-15` image currently carries both Xcode 16.x and 26.x, so that set can change) [F].
- macOS 14 (`macos-14`, `-large`, `-xlarge`): announced 2026-01-11, deprecation begins 2026-07-06, **fully unsupported 2026-11-02**. Brownouts (jobs fail on purpose, 14:00 UTC to 00:00 UTC the next day): Oct 5, 12, 16, 19, 23, 26, 29, 30. Today (2026-10-06) the first brownout has just ended [F].
- Default Xcode on macOS 26 changed from 26.5 to 26.6 on 2026-07-21 (rollout took 2 to 4 days) [F]. This is exactly why the workflow must not rely on the default Xcode.
- macOS 15 is next in line once macOS 27 reaches GA [I, from the policy above; macOS 14's timeline from announcement to removal was about ten months]. The `xcode-27` preview label presumably becomes a GA `macos-27` label at GA, but I found no announcement of that [I].
- `macos-latest` migrates gradually "over 1-2 months" and users who want to avoid it "can specify a specific OS version" [F].

### 1.3 Recommendation

| Job | Label | Xcode | Role |
|---|---|---|---|
| Reference toolchain | `macos-26` | 26.6 | Required check. Warnings are errors |
| Oldest supported toolchain | `macos-15` | 16.0 | Required check while GitHub still offers `macos-15`. Verifies the "Xcode 16.0+ / Swift 6.0" promise. Xcode 16.0 to 16.2 require macOS 14.5+, 16.3 requires 15.2+, 16.4 requires 15.3 to 26.1 [F], so only a 16.0 to 16.2 job covers contributors still on Sonoma. Raise or drop if the stated minimum changes |
| Next toolchain | `xcode-27` | 27.0 | Informational only. Not required. Catches Xcode 27 breakage early |
| Hygiene | `ubuntu-24.04` | n/a | Seconds on Linux, keeps macOS concurrency free |

Not recommended: `macos-latest` (moves under you), `macos-14` (being removed), Intel images (see risks: they exist as `macos-26-intel` and `macos-15-intel` if Intel Macs are a supported target; the arm64 runner already compiles the x86_64 slice with `generic/platform=macOS`, see 3.4 [V]).

### 1.4 Selecting Xcode robustly

Recommended: a job-level `env: DEVELOPER_DIR: /Applications/Xcode_<major.minor>.app/Contents/Developer`, plus a first step that fails loudly if the directory does not exist and prints `xcodebuild -version`, `swift --version` and the SDK version.

| | `DEVELOPER_DIR` (recommended) | `sudo xcode-select -s <app>` |
|---|---|---|
| Scope | Per process tree, set once at job level, applies to every step including `swift test` | Machine-wide switch, one step must run first |
| Needs sudo | No | Yes (macOS runner VMs have passwordless sudo [F]) |
| Honoured by `swift`, `xcodebuild`, `xcrun` | Yes. With a bogus path both `swift --version` and `xcodebuild -version` fail with `xcrun: error: missing DEVELOPER_DIR path` [V], so a wrong path can never silently fall back to a different Xcode | Yes |
| Failure mode if the Xcode is missing | Immediate, explicit error | Immediate, explicit error |
| Matches GitHub's own guidance | Equivalent | The mitigation in issue #14344 uses `sudo xcode-select -s "/Applications/Xcode_26.4.1.app"` [F] |

Both are fine; `DEVELOPER_DIR` has less global state. Pin `major.minor` (`Xcode_26.6.app`), not `Xcode.app` (the default moves) and not a patch version (patches are replaced). For the `xcode-27` image use the symlink `Xcode_27.0.app` (the real path of 27.0 there is `Xcode_27.app`; 27.1 is `Xcode_27.1_beta.app` with `Xcode_27.1.app` as a symlink) [F]. `maxim-lobanov/setup-xcode` is unnecessary and would add a third-party action.

---

## 2. Compatibility

### 2.1 Project file format: `objectVersion 77` and synchronized groups

**Oldest Xcode: 16.0.** Evidence:

- Apple's Xcode 16 release notes introduce "buildable folders" (the UI name for file-system-synchronized groups): "Buildable folders only record the folder path into the project file without enumerating the contained files" [F].
- The CocoaPods `xcodeproj` gem mapping quoted in CocoaPods issue #12927 lists `77 => 'Xcode 16.0'`, `100 => 'Xcode 26.3'` [F].
- A GitHub PR records that a project with a newer format failed on a runner whose `xcodebuild` was Xcode 15.4 ("project ... is in a future Xcode project file format") and was fixed by setting 77 and moving the runner to Xcode 16+ [F, PR alcolopa/dboard#3].
- I could not run Xcode 16.0 locally [I that 16.0 itself reads a hand-written 77 project with a synchronized group]; the CI job on Xcode 16.0 is the test.

**What each Xcode writes and reads (the dangerous part):**

| Xcode | `objectVersion` it writes | Source |
|---|---|---|
| 16.0 | 77 | [F] gem mapping, [I] for new projects |
| 26.0 to 26.2 | not established; 90 is the likely value | [I]. Xcode 27.0 accepts 90 and rejects 89 and 91 [V], so 90 is a genuine format version, and a PR calls it "a value higher than any released Xcode understands" at the time [F]; I found no source tying 90 to a specific Xcode |
| 26.3 | 100 | [F] gem mapping |
| 27.0 | **90** in Xcode's own bundled `UntitledAppProjectPrototype` and `UntitledToolProjectPrototype` [V]; **110** for a GUI-created App project per one report [F] | Unreconciled. Both are above 77. I could not drive the New Project GUI to see which one it writes |
| 27.2 (beta 2) | JSON `.xcproj` is the **default for new projects**; existing projects can be switched in the File inspector | [F] Apple |

- First-hand evidence from the Xcode 27.0 bundle [V]: `Xcode.app/Contents/Frameworks/IDEFoundation.framework/Versions/A/Resources/UntitledAppProjectPrototype/Project.xcodeproj/project.pbxproj` and the sibling `UntitledToolProjectPrototype` contain `objectVersion = 90;`, `preferredProjectObjectVersion = 90;`, `LastUpgradeCheck = 2700;` and a `PBXFileSystemSynchronizedRootGroup` (the app prototype also records `CreatedOnToolsVersion = 26.3` and `LastSwiftUpdateCheck = 2630`, the tool prototype `27.0`). The visionOS sample template shipped with the same Xcode (`.../XROS.platform/.../CompositorServices_XcodeTemplates.xcodeproj`) is still `objectVersion = 77;`. So Xcode 27 ships and reads old-format templates, and its own default for new projects is above 77.
- Reading: a reported case says Xcode 26.6 (17F113) cannot open and `xcodebuild` cannot parse a project at 110, and lowering it to 100 fixed it with synchronized groups still working [F, qzrzz/Qjiao#1]. Apple's JSON format "is compatible with Xcode 27 and later" [F].
- I tested Xcode 27.0 reading my scratch project with only `objectVersion` changed (`xcodebuild -list`, and full builds for 77, 80, 90 and 100) [V]. **Accepted: 56, 60, 63, 70, 71, 76, 77, 90, 100, 110. Rejected with `Unable to read project`: 78, 79, 80, 81, 89, 91, 99, 101, 111, 120.** So the reader accepts a discrete set of known format versions, not "anything up to N", and an arbitrary number is not safe. Whether 26.x or 16.x accept the same set is untested.
- Whether the Xcode 27 GUI upgrades an existing 77 project to 110 when you edit and save it: **not verified** (I did not drive the GUI). One reporter says saving with beta Xcode raises it, but states it as a warning, not an observation [F]. `xcodebuild` itself never rewrote my pbxproj across the several builds and listings I ran from the scratch directory (file modification time unchanged) [V].

**Actions:**

1. Keep `objectVersion = 77` and `preferredProjectObjectVersion = 77` (mirrors what Xcode 16 writes; `xcodebuild` accepts it [V]; do not rely on it to pin the format, a reporter observed a 77/110 mismatch [F]).
2. Never click "JSON" under Project Format in the File inspector (Xcode 27.2+), and never accept a project-format upgrade prompt.
3. CI guard (in the workflow below, negative-tested [V]) that fails when `objectVersion != 77`. The PR template carries the same checkbox.
4. After any Xcode GUI edit to the project, run `git diff CellKeeper.xcodeproj/project.pbxproj | head` before committing. If the version was bumped, `sed -i '' 's/objectVersion = 110;/objectVersion = 77;/'` and also check for any new object kinds the older Xcode would not understand [I].
5. Third-party tooling that parses pbxproj may lag the format; the CocoaPods `xcodeproj` gem 1.28.1 raises on 110 [F]. Irrelevant while the project has no CocoaPods/fastlane.

### 2.2 Swift Testing with `swift test`

- Xcode 16 release notes: "`swift test` now supports running tests written using Swift Testing. To enable these tests at the command line, pass `--enable-swift-testing`", and later in the same notes "Swift Testing is enabled by default in `swift build` and `swift test`. It can be explicitly disabled with `--disable-swift-testing`" [F]. So plain `swift test` runs it on Xcode 16 and later per those notes [F] (the 16.0 claim rests on the notes alone, since I could only run 27.0 [V]).
- Verified on 27.0: one `swift test` invocation prints the XCTest summary ("Executed 0 tests") and then runs the Swift Testing suites, including a parameterised `@Test(arguments:)` [V]. The "Executed 0 tests" lines are harmless noise.
- Running through Xcode also works: `xcodebuild test -scheme CellKeeperKit-Package -destination 'platform=macOS,arch=arm64'` inside the package directory ran the same Swift Testing tests and produced `** TEST SUCCEEDED **` [V]. That route yields an `.xcresult`; `swift test` is simpler and is what the workflow uses.
- Feature floor: exit tests (`processExitsWith:`) and test attachments arrived with Xcode 26 / Swift 6.2 [F, Xcode 26 release notes]. Xcode 27 adds `swift test --repeat-until` / `--maximum-repetitions` and a failure summary [F]. Using these would raise the minimum toolchain; avoid them if Xcode 16 stays supported. Parameterised tests, traits and tags exist since Xcode 16 [F].
- Do not add `swift-testing` as a package dependency; the toolchain bundles it [I].

### 2.3 `swift-tools-version` 6.0 vs newer

Facts [F]: from tools-version 6.0, `swiftLanguageMode` can be set per target and `swiftLanguageVersions` was renamed `swiftLanguageModes`; 6.2 adds `strictMemorySafety` and `defaultIsolation`; SE-0480 (`treatAllWarnings`/`treatWarning`) is implemented in Swift 6.2. Xcode 16 notes also record a fix so that "packages using `swift-tools-version: 6.0` did not infer the Swift 6 language mode when compiling within Xcode (or `xcodebuild`)" is resolved.

Verified with Xcode 27's SwiftPM on a `// swift-tools-version: 6.0` manifest [V]:

| Manifest feature | Result under tools 6.0 |
|---|---|
| `.macOS(.v15)` | builds |
| `.macOS(.v26)` | error: `'v26' is unavailable` |
| `.treatAllWarnings(as: .error)` | error: unavailable |
| `.defaultIsolation(MainActor.self)` | error: unavailable |
| a mutable global `var` in a target | error (Swift 6 language mode is the default) |

Recommendation: **`// swift-tools-version: 6.0`.** It keeps the package openable by Xcode 16.0+, gets Swift 6 mode for free, and makes it impossible to accidentally use manifest APIs that would silently raise the minimum toolchain. Only raise to 6.2 if the minimum becomes Xcode 26 and you actually want `defaultIsolation`; do not use `.treatAllWarnings(as: .error)` in the manifest (it would make warnings fatal for every contributor and every future compiler, see 3.2).

Manifest `platforms` pitfall [V]: with `platforms: [.macOS(.v14)]` in the package and `MACOSX_DEPLOYMENT_TARGET = 13.0` in the app, the app fails to compile with `compiling for macOS 13.0, but module 'CellKeeperCore' has a minimum deployment target of macOS 14.0`. Keep the two equal (define the number once in the README and review both together).

### 2.4 Swift 6 language mode: does code written on Xcode 27 build on 16.x / 26.x?

Not guaranteed, and I could not test it locally. What is solid:

- Language mode and compiler version are different things. Xcode 16.0 (Swift 6.0 [I]), 26.6 (Swift 6.3 [F]) and 27.0 (Swift 6.4 [F]) can all build in Swift 6 mode, but newer compilers accept more code and add diagnostics. Bundled Swift: Xcode 16.4 does not state it in the release-note line I extracted, Xcode 26.0 to 26.1 = 6.2/6.2.1, 26.2 and 26.3 = 6.2.3, 26.4 to 26.6 = 6.3, 27.0 = 6.4 [F, release notes].
- Things that tie code to a newer toolchain, avoid them while Xcode 16 is supported [I unless stated]: macOS 27 SDK symbols (a reported case shows `#available` does not help, the compile fails with "has no member" on the older SDK [F, Qjiao#1]; gate with `#if compiler(>=6.4)` or similar compile-time checks instead), Xcode 26+ build settings such as default MainActor isolation / approachable concurrency (older Xcode ignores unknown build settings, so semantics could silently differ; write explicit `@MainActor` instead), Swift 6.2+ language features, and Swift Testing exit tests or attachments (needs 6.2 [F]).
- Set `SWIFT_VERSION = 6.0` in the xcconfig for the app target (Xcode 16 notes: "The `SWIFT_VERSION` build setting now allows building with the Swift 6 language mode" [F]; it builds on 27.0 [V]).
- The compile check on the oldest toolchain is the `macOS 15 / Xcode 16.0` matrix job. If you decide the minimum is Xcode 26, delete that entry and say so in the README.

---

## 3. Recommended CI

### 3.1 Decisions

| Topic | Choice | Reason |
|---|---|---|
| Triggers | `push` to `main`, `pull_request`, `workflow_dispatch` | Covers PRs and main. Use `pull_request`, never `pull_request_target`, for building untrusted code [I] |
| Path filters | none | Skipped runs leave required checks "Pending" and block merging [F, workflow syntax docs] |
| Permissions | top-level `permissions: contents: read` | All jobs only read the repo. Specifying any permission sets the rest to `none` [F]. Also set the repo default token to read-only [F, secure-use] |
| Concurrency | `group: ${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` | Superseded PR runs are cancelled (macOS minutes and the 5-job cap matter), but every commit on `main` keeps a result. Expressions are allowed in `cancel-in-progress` [F] |
| Timeouts | job `timeout-minutes: 20` (hygiene: 5) | Default is 360 [F]. Local cold test plus Debug and Release builds is about 30 s [V]; even 3 to 10 times slower on a 3-core M1 runner [I] fits comfortably. Queue time on the preview image does not count against it |
| Action pinning | `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`, Dependabot keeps it current | See 3.6 |
| Third-party actions | none | Everything needed ships on the image (xcodebuild, swift, codesign). Fewer trust boundaries |
| Matrix | `fail-fast: false` | One toolchain failing should not hide results from the others |
| Destination | `generic/platform=macOS` | See 3.4 |
| Caching | none | See 3.3 |

### 3.2 Warnings as errors: pros, cons, verified mechanics

Pros: keeps the baseline at zero warnings, which matters in Swift 6 mode where concurrency diagnostics are the main signal; stops warning debt accumulating in a small codebase.

Cons: every new compiler and every new SDK can add warnings, turning CI red without a code change (the default Xcode on `macos-26` changed on 2026-07-21 [F]); contributors on newer or older Xcode would be blocked if the setting were in the repo's xcconfig; and it hides real failures behind unrelated deprecation noise if applied to preview toolchains.

Recommendation: **CI-only, and only on the pinned reference toolchain** (`werror: true` for `macos-26` / Xcode 26.6, `false` for the others). Do not commit `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` into the shared xcconfig and do not use `.treatAllWarnings(as: .error)` in `Package.swift`.

Verified mechanics [V]:

- `swift test --package-path Packages/CellKeeperKit -Xswiftc -warnings-as-errors` fails on a warning in a package source file and covers test targets too.
- `xcodebuild ... SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` applies to the app target **and** to the local package target compiled by Xcode (an injected warning in either one failed the build with exit code 65 and a file:line message, visible even with `-quiet`).
- Non-compiler "warning:" lines are not affected, for example the AppIntents notice `warning: Metadata extraction skipped, no AppIntents.framework dependency found`, or Xcode build-system warnings such as "The Copy Bundle Resources build phase contains this target's Info.plist". `LM_SKIP_METADATA_EXTRACTION=YES` silences the AppIntents line if you want clean logs [V]. Grepping logs for `warning:` to catch the rest is brittle and not recommended.

### 3.3 Caching: not worthwhile

- No dependencies exist, so there is nothing to download. Only the project's own compile output could be cached.
- Measured locally on an M-series Mac, cold: `swift test` 4.7 to 9.4 s including the build; each `xcodebuild` configuration build about 7 to 12 s [V] (scratch project and the lead's actual project). On a 3-core M1 runner I expect several times that, roughly 2 to 5 minutes per job in total [I].
- DerivedData restore is sensitive to absolute paths and timestamps, so hit rates are unreliable [I]; restore and save overhead is comparable to the build itself; all caches share a 10 GB per-repository quota [F, limits page]; each cached artefact is also another thing to trust.
- Revisit when a build exceeds roughly 5 minutes or when remote packages are added: then cache `-clonedSourcePackagesDirPath` keyed on `hashFiles('**/Package.resolved')` and pass `-disableAutomaticPackageResolution` [F, the flag exists in `xcodebuild -help`].

### 3.4 Build command, destination and signing

`-destination 'platform=macOS'` (the form in the brief) works but on an Apple-silicon host prints `WARNING: Using the first of multiple matching destinations` (arm64 and x86_64 variants) and builds arm64 only [V]. `-destination 'generic/platform=macOS'` has no warning and compiled **both** `x86_64` and `arm64` in Debug [V] (verified with `lipo -archs`), so the arm64 runner also type-checks the Intel slice. Use `generic/platform=macOS` for builds. Tests run through `swift test`, so no run destination is needed.

Signing in CI, verified with a Local.xcconfig that deliberately demands a team and an `Apple Development` identity [V]:

| CI flags | Result |
|---|---|
| nothing | **fails**: `No signing certificate "Mac Development" found` for team ABCDE12345 |
| `CODE_SIGNING_ALLOWED=NO` | builds, but the product is only linker-signed (`flags=0x20002(adhoc,linker-signed)`) and **has no entitlements embedded** (`codesign -d --entitlements` prints nothing) |
| `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` (recommended) | builds, `Signature=adhoc`, `TeamIdentifier=not set`, **entitlements are embedded** (`com.apple.security.app-sandbox` appeared), `codesign --verify --strict` passes, Release gets `flags=0x10002(adhoc,runtime)` (hardened runtime) |

So ad-hoc overrides are strictly better than `CODE_SIGNING_ALLOWED=NO`: no secrets or keychain are needed, they are immune to a contributor-style `Local.xcconfig`, and CI can inspect the entitlements that would otherwise be invisible. Observed side note [V]: ad-hoc builds also get `com.apple.security.get-task-allow`; a real distribution build (separate research stream) must be signed with a Developer ID identity and must not carry it.

Quirk [V]: if `-derivedDataPath` is a sibling directory whose path merely starts with the project directory's path (project in `/tmp/ck_real`, derived data in `/tmp/ck_real_rt`), `xcodebuild` printed `warning: .../SDKExplicitPrecompiledModules/SwiftShims-....pcm: No such file or directory` and the build still succeeded (exit code 0), and the path in the message was mangled to `/tmp/ck_real/_rt/...`. It does not occur with GitHub's layout (`RUNNER_TEMP` is not a string prefix of the workspace) or with a path inside the project directory; it only matters if you reproduce CI locally with such a path.

Both Debug and Release are built: Debug exercises `#if DEBUG` code (for example mock-backend wiring), Release exercises optimised, whole-module compilation, and each can emit different warnings.

### 3.5 Recommended `ci.yml`

This exact text was parsed with Ruby's YAML loader, its `run:` blocks were extracted and executed under macOS bash 3.2 (`bash --noprofile --norc -eo pipefail`, which is what the workflow's `defaults.run.shell: bash` selects [F]) against a fresh clone of the scratch project and against a copy of the lead's actual project, with strict and non-strict settings, including negative tests (injected warning in app and in package, bad `objectVersion`, tracked secrets, missing Xcode path). Not tested: actual GitHub execution, and Xcode 16.0 / 26.6.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

# Least privilege: every job below only needs to read the repository.
permissions:
  contents: read

# Explicit `shell: bash` runs `bash --noprofile --norc -eo pipefail {0}`, so a
# failing command inside a pipeline fails the step. (The default when no shell
# is given is `bash -e {0}`, without pipefail.)
defaults:
  run:
    shell: bash

# One run per ref. A new push to a pull request cancels the superseded run;
# runs on main are never cancelled, so every commit on main keeps a result.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  hygiene:
    name: Repository hygiene
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - name: Check out
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Project file format is still the Xcode 16 format
        run: |
          version=$(grep -E '^[[:space:]]*objectVersion = [0-9]+;' CellKeeper.xcodeproj/project.pbxproj | grep -oE '[0-9]+')
          echo "objectVersion = ${version}"
          if [ "${version}" != "77" ]; then
            echo "::error file=CellKeeper.xcodeproj/project.pbxproj::objectVersion is ${version}, expected 77. A newer Xcode rewrote the project file; revert that change so Xcode 16 and 26 can still open it."
            exit 1
          fi

      - name: Shared scheme is committed
        run: test -f CellKeeper.xcodeproj/xcshareddata/xcschemes/CellKeeper.xcscheme

      - name: No user state, build products, or signing material is tracked
        run: |
          if git ls-files | grep -E '(^|/)xcuserdata/|\.xcuserstate$|\.(p12|pfx|p8|cer|mobileprovision|provisionprofile|keychain|keychain-db)$|(^|/)\.env$|(^|/)Local\.xcconfig$|(^|/)\.DS_Store$|(^|/)(\.build|DerivedData)/'; then
            echo "::error::The files listed above must not be committed."
            exit 1
          fi

  build-test:
    name: ${{ matrix.name }}
    runs-on: ${{ matrix.runner }}
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        include:
          # Reference toolchain: stable Xcode, warnings are errors.
          # Mark this check as required in the branch ruleset.
          - name: macOS 26 / Xcode 26.6
            runner: macos-26
            xcode: "26.6"
            werror: true
          # Oldest toolchain the README promises (Xcode 16.0, Swift 6.0). Xcode
          # 16.0 to 16.2 are the only 16.x releases that run on macOS 14 hosts,
          # so this entry also covers contributors on Sonoma. If it proves too
          # noisy, raise the stated minimum rather than testing a newer Xcode.
          # Mark required only while macos-15 is still offered by GitHub.
          - name: macOS 15 / Xcode 16.0
            runner: macos-15
            xcode: "16.0"
            werror: false
          # Preview runner image: outside the GitHub SLA, may queue or break.
          # Do NOT mark this check as required. (continue-on-error is avoided
          # on purpose: it can make a failing job look green.)
          - name: macOS 27 / Xcode 27.0 (preview image)
            runner: xcode-27
            xcode: "27.0"
            werror: false
    env:
      # Process-scoped toolchain selection: honoured by xcodebuild, xcrun and
      # the swift/clang shims without needing sudo or touching global state.
      DEVELOPER_DIR: /Applications/Xcode_${{ matrix.xcode }}.app/Contents/Developer
      WARNINGS_AS_ERRORS: ${{ matrix.werror }}
    steps:
      - name: Check out
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Show toolchain
        run: |
          if [ ! -d "${DEVELOPER_DIR}" ]; then
            echo "::error::${DEVELOPER_DIR} does not exist on this runner image. Installed:"
            ls -d /Applications/Xcode*.app
            exit 1
          fi
          xcodebuild -version
          swift --version
          xcrun --sdk macosx --show-sdk-version

      - name: Test CellKeeperKit (Swift Testing)
        run: |
          flags=()
          if [ "${WARNINGS_AS_ERRORS}" = "true" ]; then
            flags+=(-Xswiftc -warnings-as-errors)
          fi
          swift test --package-path Packages/CellKeeperKit ${flags[@]+"${flags[@]}"}

      - name: Build CellKeeper (Debug and Release, ad-hoc signed)
        run: |
          flags=()
          if [ "${WARNINGS_AS_ERRORS}" = "true" ]; then
            flags+=(SWIFT_TREAT_WARNINGS_AS_ERRORS=YES)
          fi
          for configuration in Debug Release; do
            xcodebuild build \
              -quiet \
              -project CellKeeper.xcodeproj \
              -scheme CellKeeper \
              -configuration "${configuration}" \
              -destination 'generic/platform=macOS' \
              -derivedDataPath "${RUNNER_TEMP}/DerivedData" \
              CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
              ${flags[@]+"${flags[@]}"}
          done

      - name: Verify signature and entitlements
        run: |
          app="${RUNNER_TEMP}/DerivedData/Build/Products/Release/CellKeeper.app"
          entitlements="${RUNNER_TEMP}/signed-entitlements.plist"
          codesign --verify --strict --verbose=2 "${app}"
          codesign --display --entitlements - --xml "${app}" > "${entitlements}"
          plutil -p "${entitlements}"
          # The App Sandbox entitlement must survive signing. Remove this check
          # only if the app is deliberately shipped without the sandbox.
          test "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "${entitlements}")" = "true"
          lipo -archs "${app}/Contents/MacOS/CellKeeper"
```

Notes on the workflow:

- `hygiene` runs on Linux in seconds. Its `objectVersion` check hard-codes 77; change it deliberately if the project format is ever raised.
- `defaults.run.shell: bash` is set on purpose. Without it the default on macOS and Linux is `bash -e {0}`, which has no `pipefail`, so a failing command on the left of a pipe would not fail the step; with it the step runs `bash --noprofile --norc -eo pipefail {0}` [F, workflow syntax docs]. The macOS images list Bash 3.2.57 [F], which is what I tested with, so avoid bash 4 features (associative arrays, `${var,,}`, `mapfile`) in these scripts.
- "Verify signature and entitlements" asserts that the signed Release app carries `com.apple.security.app-sandbox = true` (`plutil -extract` prints `true`, and exits 1 when the key is absent [V]). It is project policy encoded in CI: delete the assertion only if the app is deliberately shipped unsandboxed.
- Environment values are passed via `env:` and read as shell variables, never interpolated into `run:` bodies, to avoid script injection [I, standard practice].
- The `matrix.name` values become the check names. Branch rulesets match check names exactly, so renaming a matrix entry silently un-requires it [I]. Required: `Repository hygiene`, `macOS 26 / Xcode 26.6`, and `macOS 15 / Xcode 16.0` while it exists. Do not require the preview job.
- `continue-on-error` is deliberately not used for the preview job: a failed job with `continue-on-error: true` can appear green [I, from experience; I did not fetch that part of the docs], which would hide the Xcode 27 signal. An un-required red check is the honest representation.
- If the repository later adds a merge queue, add `merge_group:` to `on:` [I].

### 3.6 Pinning `actions/checkout`

- GitHub's guidance: "Pinning an action to a full-length commit SHA is currently the only way to use an action as an immutable release", and "verify it is from the action's repository and not a repository fork" [F]. The page's wording is under "Using third-party actions"; it does not say whether first-party `actions/*` should be pinned [F].
- Recommendation: pin `actions/checkout` too. With Dependabot the cost is zero: Dependabot updates SHA references and the trailing `# vX.Y.Z` comment on the same line [F]. It also satisfies the optional repository/organisation policy that requires full-length SHA pinning [F].
- Current value: `actions/checkout` release **v7.0.1** (2026-07-20), `v7` and `v7.0.1` both resolve to commit `3d3c42e5aac5ba805825da76410c181273ba90b1` (GitHub marks that commit verified; message "prep v7.0.1 release") [F, GitHub API]. Its `action.yml` runs on `node24` and keeps the `persist-credentials` input (default `true`), which the workflow sets to `false` because no step pushes [F]. Re-resolve the SHA when you create the repo; do not trust this document's value blindly.
- Dependabot does not raise security alerts for SHA-pinned actions but does open version-update PRs for them [F].

---

## 4. Repository hygiene

The recommended `.gitignore` is in section 7. It was exercised in a scratch git repo: user state, `.DS_Store`, a fake `.p12`, `.mobileprovision`, `.env`, `Local.xcconfig`, `.dmg`, `xcuserdata` and `.build/` were all ignored, and nothing else in the tree was [V]. It is a superset of GitHub's `Swift.gitignore` and `Global/Xcode.gitignore` templates, which ignore `xcuserdata/`, `*.hmap`, `*.ipa`, `*.dSYM.zip`, `*.dSYM`, `.build/` and (commented out) `.swiftpm` [F].

**`Package.resolved`:** commit nothing for now. With zero dependencies neither `swift test` nor `xcodebuild` generated a `Package.resolved` anywhere in the scratch project [V]. SwiftPM's docs: the file pins versions only for the top-level (leaf) package; "does not pin dependency versions for packages used as libraries", and a library's own `Package.resolved` is ignored by consumers [F]. Once remote dependencies are added, the leaf project is the Xcode project, so commit `CellKeeper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (that is the file Xcode writes for projects [I]) and build CI with `-disableAutomaticPackageResolution` (equivalent `-onlyUsePackageVersionsFromResolvedFile`) [F]. Do not put `Package.resolved` in `.gitignore`.

**Shared scheme (`xcshareddata/xcschemes/CellKeeper.xcscheme`): commit it.**

- Honest finding: Xcode 27's `xcodebuild` auto-created a scheme when I deleted `xcshareddata` entirely, and the CI command still built [V]. So it is not strictly required today.
- Commit anyway because: a hand-written project has no scheme state anywhere, an explicit file gives a stable name and a fixed Build/Test/Run/Archive configuration; auto-creation is an Xcode setting that can be turned off per project ("disable automatic creation of schemes for new targets" under Manage Schemes [F, Apple doc]); and the scheme's `BlueprintIdentifier` ties it to the target for reviewers. Per-user schemes live in `xcuserdata/` and are ignored.
- Never ignore `xcshareddata/`; ignore only `xcuserdata/`.
- `xcodebuild -list` on the project shows three schemes (`CellKeeper` plus auto-generated `CellKeeperCore` and `CellKeeperKit` from the package products) [V], so always pass `-scheme CellKeeper` explicitly.

**`project.xcworkspace/contents.xcworkspacedata`: commit it** (7-line standard file, appendix A). My hand-written project did not have it, and `xcodebuild` then created an empty `project.xcworkspace/xcshareddata/swiftpm/configuration/` directory in the working tree [V]; git ignores empty directories, so it is harmless but a sign the project was incomplete.

**`IDEWorkspaceChecks.plist`:** optional. It holds one key (`IDEDidComputeMac32BitWarning = true`) and Apple recommended committing it in the Xcode 9.3 release notes [I: I only saw this quoted by secondary sources, I could not fetch Apple's note]. I could not confirm that Xcode 16 to 27 still generates it. Not needed to clone or build; do not hand-write it; if Xcode creates it, commit it rather than ignore it. Avoid ignore patterns like `project.xcworkspace/` that would also hide `xcshareddata` [I].

---

## 5. GitHub community files (conventions as of 2026-10-06)

All locations below are from GitHub Docs [F] unless tagged otherwise. Templates and forms only take effect once merged into the default branch.

**Issue forms.**

- Forms live in `.github/ISSUE_TEMPLATE/NAME.yml`; the chooser config is `.github/ISSUE_TEMPLATE/config.yml`.
- Required top-level keys: `name`, `description`, `body`. Optional: `title`, `labels`, `assignees`, `projects`, `type`. `type` refers to an issue type "defined at the organization level", so omit it for a personal repo. Labels that do not exist in the repo are silently skipped, so create `bug`, `triage`, `enhancement` first.
- Body elements: `markdown`, `input`, `textarea`, `dropdown`, `checkboxes`, `upload`. `validations: required: true` makes a field mandatory; for checkboxes `required` is per option. `textarea` supports `render: shell`.
- Template names must be longer than 3 characters or the template is hidden; files sort alphanumerically with YAML before Markdown, so use numeric prefixes (`1-bug.yml`) for order if wanted.
- `config.yml`: `blank_issues_enabled: false` removes the blank issue option for Read/Triage users (maintainers still see it labelled "Maintainers only"); `contact_links` entries take `name`, `url`, `about`.
- Community-profile checkmark: `.yml` forms need valid `name:` and `description:`; `.md` templates need `name:` and `about:`.
- Issue forms do not apply to pull requests.

**Pull request template.** `.github/pull_request_template.md` (also allowed at the root or in `docs/`). Multiple templates go in a `PULL_REQUEST_TEMPLATE/` directory and are selected with the `?template=` query parameter.

**Dependabot for Actions.** `.github/dependabot.yml`; for `github-actions` the `directory` must be `"/"` (it then scans `.github/workflows` and root `action.yml`); `schedule.interval` accepts `daily|weekly|monthly|quarterly|semiannually|yearly|cron`; `cooldown.default-days` is supported for Actions (the semver-specific cooldown keys are not); `groups` and `commit-message.prefix` (max 50 chars, colon added automatically) are supported. The options reference also says a default 3-day cooldown applies even when none is set, and does not apply to security updates [F]; verify against your repo's behaviour. The `swift` ecosystem exists for SwiftPM dependencies [I]; not needed until there are remote packages.

**CODEOWNERS.** Optional. Location `.github/`, root or `docs/` (first found wins; the file on the PR's base branch applies); last matching pattern wins; owners must have explicit write access; owners are auto-requested on non-draft PRs; approval is only *required* if "Require review from Code Owners" is enabled in the branch rule or ruleset; file must be under 3 MB. For a one-maintainer project it adds little (you cannot approve your own PR); it is useful later to flag security-sensitive paths (`.github/`, entitlements, the IOKit adapter). Sample in section 8.

**Code of conduct.** `CODE_OF_CONDUCT.md` in `.github/`, the root or `docs/` (lookup order `.github`, then root, then `docs`); counts for the community profile if non-empty and not stating there is none.

**Security policy.** The community profile lists a security policy; GitHub's page describes creating `SECURITY.md` from the Security tab. Private vulnerability reporting is a separate feature from `SECURITY.md`; owners/admins of public repos enable it, after which anyone can use Security tab > "Report a vulnerability" [F]. Put `SECURITY.md` at the repo root [I: the allowed locations were not stated on the pages I fetched]. The `config.yml` link `.../security/advisories/new` is the form's URL pattern [I], the documented path is the Security tab button.

### 5.1 Contributor Covenant

- **Use 3.0.** The versions page's "Latest Version" link points to `/version/3/0`; the 3.0 text is in the project's repository under `content/version/3/0/` [F]. Version 2.1 is the previous release (GitHub release dated 2021-08-04) [F].
- **Licence: CC BY-SA 4.0**, not CC BY 4.0: "Contributor Covenant is stewarded by the Organization for Ethical Source and licensed under CC BY-SA 4.0. To view a copy of this license, visit https://creativecommons.org/licenses/by-sa/4.0/" [F, both the rendered 3.0 page and the source file]. I did not verify what licence 2.1 states.
- **Attribution requirement:** keep the Attribution section as published: "This Code of Conduct is adapted from the Contributor Covenant, version 3.0, permanently available at https://www.contributor-covenant.org/version/3/0/." plus the licence sentence and link [F]. ShareAlike means that if you modify the text, your adapted text must carry the same licence [I]; this applies to the document, not to CellKeeper's source licence.
- **Structure of 3.0** [F]: Our Pledge; Encouraged Behaviors; Restricted Behaviors (with Other Restrictions); Reporting an Issue; Addressing and Repairing Harm; Scope; Attribution.
- **Two placeholders you must fill** (search for `[NOTE`) [F]: in "Reporting an Issue", `**[NOTE: describe your means of reporting here.]**`; and at the start of "Addressing and Repairing Harm", the note saying the enforcement ladder is a suggestion to replace with your own process if you have one. You need a real private contact for conduct reports (an address you control); GitHub private vulnerability reporting is for security issues, not conduct [I]. Open question for the lead.

---

## 6. Critique of the planned layout

Verdict: sound; keep it. Verified end to end on a fresh clone [V]. Detailed notes:

**6.1 `Packages/CellKeeperKit` vs a root `Package.swift`.**

- Keep `Packages/CellKeeperKit`. It makes the app project the single root entry point, keeps domain logic (`CellKeeperCore`, no platform imports) testable with plain `swift test`, and Xcode resolves it via `XCLocalSwiftPackageReference` with `relativePath = Packages/CellKeeperKit` [V].
- Cost: SwiftPM commands run at the repo root fail with "Could not find Package.swift in this directory or any of its parent directories" (observed with `swift package tools-version` in a directory without a manifest [V]; `swift test` locates the manifest the same way [I]). Use `--package-path Packages/CellKeeperKit` (as CI does), `cd` into it, or add a tiny `Makefile`/`script/test` and document it in CONTRIBUTING.
- A root `Package.swift` alongside the `.xcodeproj` does not break `xcodebuild` (it picked the project without ambiguity errors when I tested a root `Package.swift` next to it [V]), but it creates two competing entry points, duplicate scheme names and confusion when opening the folder in Xcode [I]. Not worth it.
- Naming: package, library product and target are all named `CellKeeperKit`, and `CellKeeperCore` is a separate product; builds fine [V]. When opening the package folder directly Xcode adds a `CellKeeperKit-Package` scheme [V].
- Split of concerns looks right: `CellKeeperCore` pure, `CellKeeperKit` with IOKit. Keep Swift 6 mode on both.

**6.2 Pitfalls when hand-writing the pbxproj (all verified unless tagged).**

1. **Everything in a synchronized folder that is not source is copied into the app.** With `NOTES.md`, `scratch.txt`, `data.json`, `run.sh` and `Docs/readme.txt` dropped into `CellKeeper/`, the Release bundle contained all of them under `Contents/Resources/` (nested folders were flattened) [V]. Keep `CellKeeper/` for app sources and assets only; keep docs, scripts and READMEs outside it, or add a membership exception. `.entitlements` was **not** copied [V].
2. **A custom `Info.plist` inside the synchronized folder** produces a build-system warning ("The Copy Bundle Resources build phase contains this target's Info.plist file") and a stray `Contents/Resources/Info.plist` in the bundle [V]. Fix with either `GENERATE_INFOPLIST_FILE = YES` plus `INFOPLIST_KEY_*` settings (appendix A; verified, `LSUIElement` ended up in the bundle's Info.plist [V]) or a hand-written exception set, verified to remove both symptoms [V]:

   ```
   /* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
   		CA0000000000000000000031 = {
   			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
   			membershipExceptions = (
   				Info.plist,
   			);
   			target = CA0000000000000000000060 /* CellKeeper */;
   		};
   /* End PBXFileSystemSynchronizedBuildFileExceptionSet section */
   ```
   referenced from the root group via `exceptions = ( CA0000000000000000000031, );`. Paths in `membershipExceptions` are relative to the synchronized folder. `-warnings-as-errors` does not catch this warning (it is not a compiler diagnostic) [V].
3. **Local package wiring has two forms and both build on Xcode 27.0** [V]. (a) Explicit, as Xcode 15 and later write it: an `XCLocalSwiftPackageReference` listed in `PBXProject.packageReferences`, `package = <that id>` on each `XCSwiftPackageProductDependency`, a `PBXBuildFile` with `productRef` in the Frameworks phase, and the products in the target's `packageProductDependencies`. My scratch project used this form, with the `package` key omitted, and built. (b) Legacy: no `XCLocalSwiftPackageReference` at all, only a `PBXFileReference` (`lastKnownFileType = wrapper`) for the package folder plus the product dependencies. The lead's first snapshot used (b) and built on 27.0; the current worktree has since gained the explicit reference, still without the `package` keys (see 6.3). A separate report shows form (b)-like wiring failing with `Missing package product` on Xcode 26.4 when a workspace referenced the package only as a group file reference [F, XcodeBuildMCP#502]; I could not reproduce that failure here and cannot say whether this project is affected on 16.x or 26.x. Recommendation: use form (a), add the `package` key as cheap hardening, and keep the `PBXFileReference` so the folder shows in the Project navigator. The exact two-line patch against the current project is in 6.3 and builds strictly [V]. Dropping the file reference and keeping only the explicit reference also builds [V].
4. **Package `platforms` above the app deployment target breaks the app build** (see 2.3) [V].
5. **Project-level defaults are missing.** A hand-written project lacks the long list of `CLANG_WARN_*` and other defaults Xcode emits. For a pure-Swift app this mostly does not matter, and the xcconfig supplies what matters. `LastUpgradeCheck`/`LastSwiftUpdateCheck` older than the running Xcode may trigger an "Update to recommended settings" suggestion in the GUI [I, not tested].
6. **First open in the GUI will rewrite and reorder the file.** Do this once, review the diff, restore `objectVersion = 77` if it changed, and commit; subsequent diffs stay small. Do it with the oldest Xcode you can if possible (see 2.1).
7. **Object IDs** must be unique 24-hex-digit strings; hand-made patterned IDs (as in appendix A) are fine [V] and Xcode keeps them.
8. **`ENABLE_USER_SCRIPT_SANDBOXING`, `SWIFT_STRICT_CONCURRENCY` etc. are xcconfig-level** here and apply to every build, including the Xcode 16 job [I that older Xcode accepts them; harmless if ignored].

**6.3 Review of the actual worktree (three snapshots, 14:47, 14:59 and 15:10 local on 2026-10-06).**

The lead's worktree holds an uncommitted project (`CellKeeper.xcodeproj`, `CellKeeper/` app sources, `Config/*.xcconfig`, `Packages/CellKeeperKit` with Core/Kit sources and tests) and was changing while I worked. I copied it three times, without `.git`, `.build` and `docs`, to scratch directories outside the worktree and ran the CI commands against the copies. Nothing in the worktree was modified except this document. Between the snapshots the lead had already: added an explicit `XCLocalSwiftPackageReference`, moved the entitlements file to `Config/CellKeeper.entitlements`, deleted `CellKeeper/_TempSnapshot.swift`, and added `LICENSE` (Apache 2.0) and `CODE_OF_CONDUCT.md`.

Results on the second snapshot unless noted [V]:

| Check | Result |
|---|---|
| `plutil -lint`, `xcodebuild -list` | OK; schemes `CellKeeper`, `CellKeeperCore`, `CellKeeperKit`; `objectVersion = 77`, `preferredProjectObjectVersion = 77` |
| `swift test --package-path Packages/CellKeeperKit -Xswiftc -warnings-as-errors` | passes: 92 tests in 11 suites plus 11 tests in 2 suites (first snapshot: 88 + 10); about 9 s including the build. 55 further runs (40 of the single flaky test below, 15 of the whole suite) all passed |
| All four `build-test` workflow steps in strict mode (`werror: true`) | pass: Debug and Release builds with zero warning or error lines, `codesign --verify --strict` valid, sandbox entitlement present, `x86_64 arm64` |
| Release bundle | `Info.plist`, `MacOS/CellKeeper`, `PkgInfo`, `_CodeSignature/CodeResources` only; `flags=0x10002(adhoc,runtime)`; `TeamIdentifier=not set`; the `CK_SNAPSHOT` string from the temporary snapshot hook is no longer in the binary (it was present in the first snapshot's Release binary) |
| `xcodebuild test -scheme CellKeeper -destination 'platform=macOS,arch=arm64'` (the scheme's TestAction lists both package test targets) | **intermittent failure**, see finding 1. First snapshot: passed. Second snapshot: failed 2 of 13 whole-suite runs and 2 of 30 runs of `CellKeeperCoreTests` |
| Workflow hygiene guards 1 and 2 (`objectVersion`, shared scheme) | pass. Guard 3 (tracked secrets) and my `.gitignore` were exercised on the first snapshot in a scratch git repo: `Config/Local.xcconfig` ignored, `Config/Local.xcconfig.example` tracked |
| `CODE_OF_CONDUCT.md` in the worktree | line-for-line the upstream Contributor Covenant 3.0 text except two edits: the reporting placeholder is replaced by a visible `[MAINTAINERS: add a private reporting contact ...]` TODO, and the second `[NOTE: ...]` about the enforcement ladder is removed (adopting the suggested ladder as written). The Attribution section with the CC BY-SA 4.0 licence line is intact |

What is already good: `Shared.xcconfig` (ad-hoc signing by default, empty `DEVELOPMENT_TEAM`, optional `#include? "Local.xcconfig"`, a committed `Local.xcconfig.example`); package `platforms` and the app deployment target are both 14.0; the synchronized folder contains only Swift sources (the `Info.plist` is generated, so no exception set is needed); the scheme is committed with the test targets attached; the project carries the full default `CLANG_WARN_*` set; the entitlements file now lives outside the synchronized folder.

**Status at the third snapshot (15:10).** The lead had by then added `.gitignore`, `contents.xcworkspacedata`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md` and a `.github/` tree (issue forms, PR template, Dependabot, `workflows/ci.yml`), and had redesigned the flaky test. I ran the lead's `ci.yml` run-blocks (extracted with the same harness) on that tree under bash 3.2 in both strict and non-strict mode: all four `build-test` steps pass (`swift test` 90 + 11 tests, clean Debug and Release builds, signature and sandbox entitlement verified) and the three hygiene steps pass on a git repository built from the snapshot (46 tracked files, nothing unwanted). The lead's workflow is my recommended one with a more defensive empty-array idiom (`${flags[@]+"${flags[@]}"}`), a wider tracked-file regex, and Xcode 16.4 in the old-toolchain entry; I have folded the first two into the workflow in 3.5. The redesigned test (percent 50, twenty `.manual` evaluations, asserts 20 total requests and a maximum of 1) passed 40 of 40 runs under `xcodebuild test`. So findings 1, 2 and 4 below are resolved; they are kept because they show what to watch for. Finding 8 is new.

Findings, most important first:

1. **A flaky test will make CI intermittently red: `ChargeControllerTests` "Concurrent evaluations never overlap backend requests".** It failed under `xcodebuild test` in about 7 percent of runs (2 of 30 and 2 of 13) and never under `swift test` (0 of 55) on this machine with Xcode 27.0; a loaded 3-core runner may differ. I instrumented a scratch copy of the test [V]: in both instrumented failures `observedMaximum` was 0, meaning no backend request happened at all in that interleaving, so the assertion `maximumConcurrentRequests == 1` fails. The log of a failing run shows the 85 percent evaluations "refused (Rate-limited until ...)" and the 50 percent ones "action none". The 20 concurrent tasks write alternating 85 and 50 percent telemetry and then evaluate, so the likely mechanism [I] is that the first evaluation to run reads 50 percent, after which the 85 percent evaluations are rate-limited and the probe never records a call. This looks like a test-design flake, not an overlap in the controller: an overlap would give a maximum of 2, which I did not see in the two instrumented failures, and by reading `acquire`/`release` in `ChargeController` the check-and-set of `isBusy` has no suspension point between the two, so mutual exclusion holds [I, by code reading]. Suggested fix, trialled in the scratch copy with 60 passes in 60 runs: add one deterministic call before the task group so at least one request is guaranteed.

   ```swift
   let (controller, telemetry) = makeController(percent: 85, backend: backend)
   await controller.evaluate(.launch)   // at 85% this issues exactly one backend request
   await withTaskGroup(of: Void.self) { group in
       // unchanged
   ```
   Fix this before enabling CI as a required check. I did not modify the worktree; the lead owns the test code.
2. **No `.gitignore` yet.** `git status` shows an untracked `.build/` at the worktree root (created at 14:24 by a process other than my work, which only built under `/tmp`). Add the `.gitignore` from section 7 before the first `git add`.
3. **Package wiring is now the explicit form, optional hardening remains.** The product dependencies have no `package = <reference id>` key. It builds strictly on 27.0 as is [V]; one report says Xcode 26.4 needed the key in a workspace setup [F, XcodeBuildMCP#502]. The two-line patch below was verified to build Debug and Release strictly with a valid ad-hoc signature, and to apply with `patch -p1` to the second snapshot:

   ```diff
   --- a/CellKeeper.xcodeproj/project.pbxproj
   +++ b/CellKeeper.xcodeproj/project.pbxproj
   @@ -314,10 +314,12 @@
    /* Begin XCSwiftPackageProductDependency section */
    		C311E0000000000000000201 /* CellKeeperCore */ = {
    			isa = XCSwiftPackageProductDependency;
   +			package = C311E0000000000000000B01 /* XCLocalSwiftPackageReference "Packages/CellKeeperKit" */;
    			productName = CellKeeperCore;
    		};
    		C311E0000000000000000202 /* CellKeeperKit */ = {
    			isa = XCSwiftPackageProductDependency;
   +			package = C311E0000000000000000B01 /* XCLocalSwiftPackageReference "Packages/CellKeeperKit" */;
    			productName = CellKeeperKit;
    		};
    /* End XCSwiftPackageProductDependency section */
   ```
4. **No `project.xcworkspace/contents.xcworkspacedata`.** `xcodebuild` created an empty `project.xcworkspace/xcshareddata/swiftpm/configuration/` directory in the working tree, which git ignores. Commit the 7-line file from appendix A for completeness [I that Xcode creates it on first GUI open anyway].
5. **Placeholder identity.** `CELLKEEPER_BUNDLE_ID_PREFIX = com.example` yields `com.example.CellKeeper`, fine for contributors. Decide the real identifier before the first distributed build (stream 05); changing it later resets app-scoped state such as preferences [I].
6. **`swift test` versus `xcodebuild test`.** Both work. Keep `swift test` as the CI path: it does not depend on the app project, needs no destination, and `-Xswiftc -warnings-as-errors` is simple. Keep the scheme's TestAction so that Cmd-U works. `xcodebuild test` is the route if you later want an `.xcresult` (`-resultBundlePath`) as an artefact.
8. **The README promises Xcode 16.0 but CI tests 16.4.** `README.md` and `CONTRIBUTING.md` say "Xcode 16.0 or later" and "macOS 14+". Apple's release notes say Xcode 16 to 16.2 require macOS Sonoma 14.5 or later, 16.3 requires Sequoia 15.2 or later, and 16.4 requires Sequoia 15.3 through Tahoe 26.1 [F]. So a contributor on macOS 14 can only use Xcode 16.0 to 16.2 (Swift 6.0 and 6.1 compilers), which an Xcode 16.4 job never exercises. The `macos-15` image has `/Applications/Xcode_16.0.app` (symlink to `Xcode_16.app`) [F]. Recommendation, already applied to the workflow in 3.5: make the old-toolchain job Xcode 16.0, and if it fails on compiler differences, raise the documented minimum (for example to 16.2, the newest Xcode that runs on macOS 14) rather than testing a newer Xcode than you promise. I could not run Xcode 16.0 here, so expect the first run to tell you something.
7. **Resolved since the first snapshot, worth keeping as rules.** `CellKeeper/_TempSnapshot.swift` (marked temporary, with a `CK_SNAPSHOT` hook) had been compiled into the first snapshot's Release binary because a synchronized folder builds every Swift file; keep scratch code out of `CellKeeper/`. The package reference was first the legacy wrapper-only form (6.2 item 3).

**6.4 What could stop another developer from cloning and building.**

Verified: a fresh `git clone` of the scratch repo built Debug and Release, ran all tests, and left no untracked files other than the ignored `.build/` [V], using only Xcode (no `Local.xcconfig`, no team). That works because the scratch `Base.xcconfig` defaults to ad-hoc signing (`CODE_SIGN_IDENTITY = -`) and ends with the optional include `#include? "Local.xcconfig"`, which is silently skipped when absent [V]. The lead's `Shared.xcconfig` has the same design and passed the same checks (6.3). Bundle identifier: see 6.3 finding 5. Remaining blockers to document or decide:

- **Minimum Xcode:** 16.0 to open the project; whatever the CI matrix proves to build. State it in the README.
- **SDK drift:** code using macOS 27-only APIs will not compile for anyone on Xcode 26.6 (see 2.4). Decide whether Xcode 27 is the minimum or whether newer APIs sit behind compile-time gates.
- **Signing the real app:** if the shipped app needs a Developer ID identity, a team-signed privileged helper, or entitlements that require a provisioning profile, contributors cannot run those paths. [I] The mock backend in `CellKeeperCore` is the escape hatch; say in CONTRIBUTING that the app runs unsigned/ad-hoc against the mock backend. This is the most likely real obstacle and depends on research streams I have not seen.
- **Tooling that cannot parse the format:** older CocoaPods/xcodeproj-based tools fail on newer object versions [F]. Irrelevant while none are used.

---

## 7. Recommended `.gitignore`

Tested in a scratch repo as described in section 4.

```gitignore
# --- macOS ---
.DS_Store
.AppleDouble
.LSOverride
._*

# --- Xcode: per-user state and build output ---
xcuserdata/
*.xcuserstate
*.xcscmblueprint
*.xccheckout
DerivedData/
/build/
*.hmap
*.xcresult
*.xcarchive
*.dSYM
*.dSYM.zip
*.ipa

# --- Swift Package Manager ---
.build/
.swiftpm/

# --- Signing material and secrets (never commit) ---
*.p12
*.pfx
*.p8
*.cer
*.certSigningRequest
*.mobileprovision
*.provisionprofile
*.keychain
*.keychain-db
.env
.env.*
!.env.example
Local.xcconfig

# --- Release artefacts ---
*.dmg
*.pkg
/dist/
```

Deliberately not ignored: `Package.resolved`, `xcshareddata/`, `*.xcworkspace` (the committed `project.xcworkspace/contents.xcworkspacedata` is needed), `*.xcconfig` (only `Local.xcconfig` is ignored). `*.cer` is ignored although certificates are public, because stray signing files in a public repo are a recurring mistake.

---

## 8. Recommended `.github/` file list

```
.github/
  workflows/ci.yml            section 3.5
  dependabot.yml              Actions only for now
  ISSUE_TEMPLATE/
    config.yml                blank issues off, contact links
    bug_report.yml            issue form
    feature_request.yml       issue form
  pull_request_template.md
  CODEOWNERS                  optional
(repo root)
  README.md  LICENSE  CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md
```

Create the `bug`, `triage` and `enhancement` labels, enable Discussions and private vulnerability reporting, and replace `OWNER`, before relying on these. YAML files were syntax-checked with Ruby; the two forms were checked against the documented schema (required keys, unique ids, element attributes) but not submitted to GitHub.

`.github/dependabot.yml`

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    # Wait a week before proposing a brand-new release (supply-chain hygiene).
    cooldown:
      default-days: 7
    groups:
      github-actions:
        patterns: ["*"]
    commit-message:
      prefix: "ci"
```

`.github/ISSUE_TEMPLATE/config.yml`

```yaml
blank_issues_enabled: false
contact_links:
  - name: Question or idea
    url: https://github.com/OWNER/CellKeeper/discussions
    about: Ask usage questions and float ideas in Discussions rather than Issues.
  - name: Report a security vulnerability
    url: https://github.com/OWNER/CellKeeper/security/advisories/new
    about: Please report vulnerabilities privately. See SECURITY.md.
```

`.github/ISSUE_TEMPLATE/bug_report.yml`

```yaml
name: Bug report
description: Something in CellKeeper does not work as expected.
title: "[Bug]: "
labels: ["bug", "triage"]
body:
  - type: markdown
    attributes:
      value: |
        Thanks for helping improve CellKeeper. Please do not include serial numbers or other personal identifiers.
  - type: textarea
    id: what-happened
    attributes:
      label: What happened, and what did you expect?
    validations:
      required: true
  - type: textarea
    id: steps
    attributes:
      label: Steps to reproduce
      placeholder: "1. Open the menu ...\n2. ..."
    validations:
      required: true
  - type: input
    id: cellkeeper-version
    attributes:
      label: CellKeeper version
      placeholder: "e.g. 0.3.0 (build 12)"
    validations:
      required: true
  - type: input
    id: macos-version
    attributes:
      label: macOS version
      placeholder: "e.g. 26.6.2"
    validations:
      required: true
  - type: input
    id: mac-model
    attributes:
      label: Mac model
      description: "Apple menu > About This Mac (for example MacBook Pro 14-inch, M3, 2023)."
    validations:
      required: true
  - type: textarea
    id: logs
    attributes:
      label: Relevant log output
      render: shell
  - type: checkboxes
    id: terms
    attributes:
      label: Code of Conduct
      options:
        - label: I agree to follow this project's Code of Conduct
          required: true
```

`.github/ISSUE_TEMPLATE/feature_request.yml`

```yaml
name: Feature request
description: Suggest an improvement or a new capability.
title: "[Feature]: "
labels: ["enhancement"]
body:
  - type: textarea
    id: problem
    attributes:
      label: What problem are you trying to solve?
    validations:
      required: true
  - type: textarea
    id: proposal
    attributes:
      label: What would you like CellKeeper to do?
    validations:
      required: true
  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives you considered
  - type: checkboxes
    id: terms
    attributes:
      label: Code of Conduct
      options:
        - label: I agree to follow this project's Code of Conduct
          required: true
```

`.github/pull_request_template.md`

```markdown
## What and why

<!-- One or two sentences. Link the issue: Fixes #123 -->

## Checklist

- [ ] `swift test --package-path Packages/CellKeeperKit` passes
- [ ] The app builds without warnings
- [ ] Tests added or updated for behaviour changes (Swift Testing)
- [ ] `project.pbxproj` still has `objectVersion = 77` (no accidental Xcode format upgrade)
- [ ] No signing material, `Local.xcconfig`, or `xcuserdata` included
- [ ] Docs / changelog updated if user-visible
```

`.github/CODEOWNERS` (optional)

```
# Optional. Owners need write access. Review is only *required* if the branch
# ruleset enables "Require review from Code Owners".
*                                    @OWNER
/.github/                            @OWNER
/CellKeeper/*.entitlements           @OWNER
/Packages/CellKeeperKit/Sources/CellKeeperKit/ @OWNER
```

---

## 9. Risks and open questions

1. **Xcode 27 GUI may bump `objectVersion` (to 90 or 110) on save** (not verified; I only drove `xcodebuild`). If it does, Xcode 16.x contributors and CI jobs cannot open the project, and Xcode 26.6 cannot open 110 [F]; I did not test whether 26.x opens 90. Mitigation in place: CI guard and PR checkbox. Decide whether this friction is acceptable, or whether the minimum Xcode should simply be 27 (then the format question disappears but contributors on 26.6 are excluded).
2. **Xcode 27.2 makes JSON `.xcproj` the default for new projects.** Never convert; CellKeeper's project is pbxproj. Xcode 26 and earlier cannot open `.xcproj` [F].
3. **Xcode 16.x / 26.x behaviour is untested.** In particular whether Xcode 16.0, the oldest promised toolchain with the Swift 6.0 compiler, opens and builds this exact project. The matrix is the test; expect to fix a few toolchain-specific issues the first time it runs.
4. **`macos-15` will be deprecated** after macOS 27 reaches GA [I]. Plan to drop the Xcode 16.0 job or raise the minimum then. Also `macos-15` currently carries both Xcode 16.x and 26.x although the stated policy is one major per macOS version, so Xcode 16.x could disappear from that image [F, I]; the "Show toolchain" step fails with a clear message if so.
5. **The `xcode-27` image is a preview**: may queue, break or be renamed at GA [F, I]. Its base OS changed from macOS 26 to 27 on 2026-09-16 [F].
6. **Intel support.** Decide whether Intel Macs are supported. The arm64 CI compiles the x86_64 slice but never runs it. `macos-26-intel` and `macos-15-intel` exist if you want runtime tests. I believe macOS 26 is the last release for Intel Macs, which would make this moot for macOS 27 [I: general knowledge, not verified here].
7. **Entitlements/sandbox decision.** The appendix uses a placeholder sandbox entitlement. If the real app is not sandboxed or needs a privileged helper, update the entitlement file and add an assertion for the expected keys in the "Verify signature and entitlements" step.
8. **Code of conduct needs a real private contact.** The worktree's `CODE_OF_CONDUCT.md` carries a visible `[MAINTAINERS: add a private reporting contact ...]` TODO (6.3); fill it before the repository is public, and keep the Attribution section.
9. **Dependabot's default cooldown** (3 days per the options reference) and the new `cooldown` support for Actions should be sanity-checked against actual behaviour after the first PRs [F].
10. **Rename sensitivity.** Branch rulesets match matrix job names exactly; changing a name un-requires the check.
11. **Deployment target.** The scratch project uses macOS 14.0 and `MenuBarExtra`; I did not test lower targets or a different minimum. Keep the app target and the package `platforms` equal.
12. **Temporary files in the synchronized folder get compiled.** `CellKeeper/_TempSnapshot.swift` was built into the first snapshot's Release binary (it has since been deleted; section 6.3). Any scratch file dropped into `CellKeeper/` ships. A flaky test (6.3 finding 1) is the other thing that would make the first CI runs misleading.
13. **Cost.** Public repo, so standard runner minutes are free; three macOS jobs per run use at most three of five free-plan concurrent macOS slots [F]. A private repo would instead draw from the account's free-minute allotment and then bill per minute [F, runners page].

---

## 10. Sources

Fetched primary sources (GitHub, Apple, Swift):

- actions/runner-images README: https://github.com/actions/runner-images
- Same repo, raw files: https://raw.githubusercontent.com/actions/runner-images/main/README.md ; https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md ; .../macos-26-Readme.md ; .../macos-15-arm64-Readme.md ; .../macos-15-Readme.md ; .../macos-14-arm64-Readme.md ; .../xcode-27-arm64-Readme.md
- Issue #14404, Xcode 27 image preview: https://github.com/actions/runner-images/issues/14404
- Issue #13518, macOS 14 deprecation: https://github.com/actions/runner-images/issues/13518
- Issue #14344, default Xcode on macOS 26 becomes 26.6: https://github.com/actions/runner-images/issues/14344
- GitHub-hosted runners reference: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Actions limits: https://docs.github.com/en/actions/reference/limits
- Workflow syntax: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- Secure use reference: https://docs.github.com/en/actions/reference/security/secure-use
- Dependabot for Actions: https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot
- Dependabot options reference (first 100,000 characters read): https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference
- Configuring issue templates: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository
- Syntax for issue forms: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms
- Pull request templates: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository
- About code owners: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners
- Community profiles: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories
- Adding a code of conduct: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/adding-a-code-of-conduct-to-your-project
- Adding a security policy: https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository
- Privately reporting a vulnerability: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability
- actions/checkout release and ref data via the GitHub API: https://api.github.com/repos/actions/checkout/releases/latest ; https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1 ; https://api.github.com/repos/actions/checkout/commits/3d3c42e5aac5ba805825da76410c181273ba90b1 ; action.yml at that commit: https://raw.githubusercontent.com/actions/checkout/3d3c42e5aac5ba805825da76410c181273ba90b1/action.yml
- Apple Xcode release notes, read through the JSON data endpoint of each page (the HTML page itself returned only its title): https://developer.apple.com/tutorials/data/documentation/xcode-release-notes/xcode-16-release-notes.json ; .../xcode-26-release-notes.json ; .../xcode-27-release-notes.json ; .../xcode-16_4-release-notes.json ; .../xcode-26_1-release-notes.json through .../xcode-26_6-release-notes.json ; .../xcode-27_1-release-notes.json ; .../xcode-27_2-release-notes.json
- Apple, "Updating your Xcode project configuration file format": https://developer.apple.com/tutorials/data/documentation/xcode/updating-your-xcode-project-configuration-file-format.json (page: https://developer.apple.com/documentation/xcode/updating-your-xcode-project-configuration-file-format)
- Apple, "Customizing the build schemes for a project": https://developer.apple.com/tutorials/data/documentation/xcode/customizing-the-build-schemes-for-a-project.json
- SwiftPM changelog: https://raw.githubusercontent.com/swiftlang/swift-package-manager/main/CHANGELOG.md
- SwiftPM, resolving package versions (source of docs): https://raw.githubusercontent.com/swiftlang/swift-package-manager/main/Sources/PackageManagerDocs/Documentation.docc/ResolvingPackageVersions.md
- SE-0480 (warning control for SwiftPM): https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0480-swiftpm-warning-control.md
- GitHub gitignore templates: https://raw.githubusercontent.com/github/gitignore/main/Swift.gitignore ; https://raw.githubusercontent.com/github/gitignore/main/Global/Xcode.gitignore
- Contributor Covenant: https://www.contributor-covenant.org/version/ ; https://www.contributor-covenant.org/version/3/0/code_of_conduct/ ; source: https://raw.githubusercontent.com/EthicalSource/contributor_covenant/release/content/version/3/0/code_of_conduct.md ; v2.1 source: https://raw.githubusercontent.com/EthicalSource/contributor_covenant/release/content/version/2/1/code_of_conduct.md ; releases via https://api.github.com/repos/ethicalsource/contributor_covenant/releases

Fetched secondary sources (community reports, weaker evidence, used only where noted):

- CocoaPods issue, a new App project from Xcode 27.0 has `objectVersion = 110`; gem version mapping: https://github.com/CocoaPods/CocoaPods/issues/12927
- Reported: Xcode 26.6 cannot open `objectVersion = 110`, 100 works: https://github.com/qzrzz/Qjiao/issues/1
- Reported: Xcode 15.4 rejects a newer format; fixed by 77 and a newer runner: https://github.com/alcolopa/dboard/pull/3
- Reported: `Missing package product` on Xcode 26.4 when no `XCLocalSwiftPackageReference` existed (workspace referenced the package as a group file reference): https://github.com/getsentry/XcodeBuildMCP/issues/502

Local first-hand evidence (no URL): behaviour of Xcode 27.0 (27A266a) and its SwiftPM on this machine, exercised on scratch copies under `/tmp`; the project prototypes bundled in `Xcode.app/Contents/Frameworks/IDEFoundation.framework/Versions/A/Resources/` (`UntitledAppProjectPrototype`, `UntitledToolProjectPrototype`) and the visionOS sample template under `Xcode.app/Contents/Developer/Platforms/XROS.platform/`; read-only copies of the lead's worktree.

Seen only in search results, not fetched (not relied on): a kxcoding.com article on the Xcode 27.2 JSON project format (fetch returned HTTP 502); secondary pages quoting Apple's Xcode 9.3 note about `IDEWorkspaceChecks.plist`.

---

## Appendix A: verified skeleton (Xcode 27.0)

These files, together with a trivial `CellKeeperApp.swift` (`MenuBarExtra` calling into `CellKeeperKit`), a two-line `CellKeeperCore` type, and one Swift Testing test per package target, form the scratch project that was built from a fresh clone with the CI commands [V]. Placeholders to replace: bundle identifier, sandbox entitlement, deployment target, version numbers, product/target names if they change. Object IDs follow a simple pattern; Xcode will keep them but may renormalise ordering on first save (see 6.2 item 6).

`CellKeeper.xcodeproj/project.pbxproj`

```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		CA0000000000000000000001 /* CellKeeperCore in Frameworks */ = {isa = PBXBuildFile; productRef = CA0000000000000000000011 /* CellKeeperCore */; };
		CA0000000000000000000002 /* CellKeeperKit in Frameworks */ = {isa = PBXBuildFile; productRef = CA0000000000000000000012 /* CellKeeperKit */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		CA0000000000000000000020 /* CellKeeper.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CellKeeper.app; sourceTree = BUILT_PRODUCTS_DIR; };
		CA0000000000000000000021 /* Base.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = "<group>"; };
		CA0000000000000000000022 /* Debug.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Debug.xcconfig; sourceTree = "<group>"; };
		CA0000000000000000000023 /* Release.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Release.xcconfig; sourceTree = "<group>"; };
		CA0000000000000000000024 /* CellKeeperKit */ = {isa = PBXFileReference; lastKnownFileType = wrapper; name = CellKeeperKit; path = Packages/CellKeeperKit; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		CA0000000000000000000030 /* CellKeeper */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = CellKeeper;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		CA0000000000000000000040 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				CA0000000000000000000001 /* CellKeeperCore in Frameworks */,
				CA0000000000000000000002 /* CellKeeperKit in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		CA0000000000000000000050 = {
			isa = PBXGroup;
			children = (
				CA0000000000000000000030 /* CellKeeper */,
				CA0000000000000000000051 /* Config */,
				CA0000000000000000000024 /* CellKeeperKit */,
				CA0000000000000000000052 /* Products */,
			);
			sourceTree = "<group>";
		};
		CA0000000000000000000051 /* Config */ = {
			isa = PBXGroup;
			children = (
				CA0000000000000000000021 /* Base.xcconfig */,
				CA0000000000000000000022 /* Debug.xcconfig */,
				CA0000000000000000000023 /* Release.xcconfig */,
			);
			path = Config;
			sourceTree = "<group>";
		};
		CA0000000000000000000052 /* Products */ = {
			isa = PBXGroup;
			children = (
				CA0000000000000000000020 /* CellKeeper.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		CA0000000000000000000060 /* CellKeeper */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = CA0000000000000000000080 /* Build configuration list for PBXNativeTarget "CellKeeper" */;
			buildPhases = (
				CA0000000000000000000061 /* Sources */,
				CA0000000000000000000040 /* Frameworks */,
				CA0000000000000000000062 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				CA0000000000000000000030 /* CellKeeper */,
			);
			name = CellKeeper;
			packageProductDependencies = (
				CA0000000000000000000011 /* CellKeeperCore */,
				CA0000000000000000000012 /* CellKeeperKit */,
			);
			productName = CellKeeper;
			productReference = CA0000000000000000000020 /* CellKeeper.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		CA0000000000000000000070 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {
					CA0000000000000000000060 = {
						CreatedOnToolsVersion = 16.0;
					};
				};
			};
			buildConfigurationList = CA0000000000000000000081 /* Build configuration list for PBXProject "CellKeeper" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = CA0000000000000000000050;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				CA0000000000000000000010 /* XCLocalSwiftPackageReference "Packages/CellKeeperKit" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = CA0000000000000000000052 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				CA0000000000000000000060 /* CellKeeper */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		CA0000000000000000000062 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		CA0000000000000000000061 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		CA0000000000000000000090 /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = CA0000000000000000000022 /* Debug.xcconfig */;
			buildSettings = {
			};
			name = Debug;
		};
		CA0000000000000000000091 /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = CA0000000000000000000023 /* Release.xcconfig */;
			buildSettings = {
			};
			name = Release;
		};
		CA0000000000000000000092 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
			};
			name = Debug;
		};
		CA0000000000000000000093 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		CA0000000000000000000080 /* Build configuration list for PBXNativeTarget "CellKeeper" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CA0000000000000000000092 /* Debug */,
				CA0000000000000000000093 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		CA0000000000000000000081 /* Build configuration list for PBXProject "CellKeeper" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CA0000000000000000000090 /* Debug */,
				CA0000000000000000000091 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		CA0000000000000000000010 /* XCLocalSwiftPackageReference "Packages/CellKeeperKit" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/CellKeeperKit;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		CA0000000000000000000011 /* CellKeeperCore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = CellKeeperCore;
		};
		CA0000000000000000000012 /* CellKeeperKit */ = {
			isa = XCSwiftPackageProductDependency;
			productName = CellKeeperKit;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = CA0000000000000000000070 /* Project object */;
}
```

`CellKeeper.xcodeproj/xcshareddata/xcschemes/CellKeeper.xcscheme`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "CA0000000000000000000060"
               BuildableName = "CellKeeper.app"
               BlueprintName = "CellKeeper"
               ReferencedContainer = "container:CellKeeper.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "CA0000000000000000000060"
            BuildableName = "CellKeeper.app"
            BlueprintName = "CellKeeper"
            ReferencedContainer = "container:CellKeeper.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

`CellKeeper.xcodeproj/project.xcworkspace/contents.xcworkspacedata`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
```

`Config/Base.xcconfig` (last line is the optional per-developer override)

```
// Shared settings. Optional local overrides (DEVELOPMENT_TEAM etc.) live in git-ignored Local.xcconfig.
PRODUCT_BUNDLE_IDENTIFIER = dev.cellkeeper.CellKeeper
PRODUCT_NAME = CellKeeper
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1
MACOSX_DEPLOYMENT_TARGET = 14.0
SWIFT_VERSION = 6.0
SDKROOT = macosx
GENERATE_INFOPLIST_FILE = YES
INFOPLIST_KEY_LSUIElement = YES
INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = -
CODE_SIGN_ENTITLEMENTS = CellKeeper/CellKeeper.entitlements
ENABLE_HARDENED_RUNTIME = YES
ENABLE_USER_SCRIPT_SANDBOXING = YES
SWIFT_STRICT_CONCURRENCY = complete
CLANG_ENABLE_MODULES = YES
LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/../Frameworks
#include? "Local.xcconfig"
```

`Config/Debug.xcconfig`

```
#include "Base.xcconfig"
ONLY_ACTIVE_ARCH = YES
SWIFT_OPTIMIZATION_LEVEL = -Onone
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
GCC_OPTIMIZATION_LEVEL = 0
DEBUG_INFORMATION_FORMAT = dwarf
```

`Config/Release.xcconfig`

```
#include "Base.xcconfig"
SWIFT_OPTIMIZATION_LEVEL = -O
SWIFT_COMPILATION_MODE = wholemodule
DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
```

`CellKeeper/CellKeeper.entitlements` (placeholder sandbox entitlement)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
```

`Packages/CellKeeperKit/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CellKeeperKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CellKeeperCore", targets: ["CellKeeperCore"]),
        .library(name: "CellKeeperKit", targets: ["CellKeeperKit"]),
    ],
    targets: [
        .target(name: "CellKeeperCore"),
        .target(name: "CellKeeperKit", dependencies: ["CellKeeperCore"]),
        .testTarget(name: "CellKeeperCoreTests", dependencies: ["CellKeeperCore"]),
        .testTarget(name: "CellKeeperKitTests", dependencies: ["CellKeeperKit"]),
    ]
)
```

### A.1 Evidence log (all on Xcode 27.0 unless noted)

| # | Experiment | Result |
|---|---|---|
| 1 | `swift test` in the package (tools 6.0, two test targets, Swift Testing + parameterised test) | passes; XCTest prints "Executed 0 tests" then Swift Testing runs; cold 4.7 to 9 s |
| 2 | `xcodebuild -list` / build of the hand-written objectVersion 77 project with synchronized group and local package | resolves package, lists schemes `CellKeeper`, `CellKeeperCore`, `CellKeeperKit`; `** BUILD SUCCEEDED **` |
| 3 | `-destination platform=macOS` vs `generic/platform=macOS` | first: "Using the first of multiple matching destinations", arm64 only; second: no warning, `x86_64 arm64` |
| 4 | Injected warnings, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `swift test -Xswiftc -warnings-as-errors` | both fail on app-target and package-target warnings (exit 65 / 1) |
| 5 | `objectVersion` sweep with `xcodebuild -list` (16 values) and full builds for 77 / 80 / 90 / 100 | accepted 56, 60, 63, 70, 71, 76, 77, 90, 100, 110; rejected 78, 79, 80, 81, 89, 91, 99, 101, 111, 120 |
| 6 | Signing: no flags vs `CODE_SIGNING_ALLOWED=NO` vs ad-hoc overrides, with an xcconfig demanding a team | fails / builds without entitlements / builds with entitlements and valid ad-hoc signature |
| 7 | Fresh `git clone` of repo with the candidate `.gitignore`, CI commands | builds and tests; only `.build/` untracked (ignored) |
| 8 | Hygiene guards with `objectVersion 110`, tracked `.p12` and `Local.xcconfig` | fail with `::error::` annotations and exit 1 |
| 9 | Stray files in the synchronized folder | `.md`, `.txt`, `.json`, `.sh` and nested files copied to `Contents/Resources/`; `.entitlements` not |
| 10 | Custom `Info.plist` in the synchronized folder, with and without membership exception | warning + duplicate copy; exception set removes both; `preferredProjectObjectVersion = 77` accepted |
| 11 | Tools-version 6.0 manifest using `.macOS(.v26)`, `.treatAllWarnings`, `.defaultIsolation` | all rejected as unavailable; `.macOS(.v15)` fine |
| 12 | Package `.macOS(.v14)` with app deployment target 13.0 | app compile error |
| 13 | Root `Package.swift` next to the `.xcodeproj` | `xcodebuild` still picks the project, no ambiguity error |
| 14 | `DEVELOPER_DIR` set to a nonexistent path | `swift` and `xcodebuild` both fail with `xcrun: error: missing DEVELOPER_DIR path` |
| 15 | Workflow YAML parse and execution of extracted `run:` blocks under bash 3.2 | all steps pass; negative cases fail as intended |
| 16 | Copies of the lead's actual worktree: `swift test -Xswiftc -warnings-as-errors` | snapshot 1: 88 + 10 tests pass, 9.4 s; snapshot 2: 92 + 11 pass; 55 further runs pass |
| 17 | Same copy: `xcodebuild` Debug and Release, ad-hoc overrides, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, `generic/platform=macOS` | zero warnings; `x86_64 arm64`; `codesign --verify --strict` valid; sandbox entitlement present |
| 18 | Snapshot 1: add explicit `XCLocalSwiftPackageReference` and `package =` keys, and a variant that drops the wrapper file reference. Snapshot 2: add only the `package =` keys | all build strictly |
| 19 | `xcodebuild test -scheme CellKeeper -destination 'platform=macOS,arch=arm64'` | snapshot 1: `** TEST SUCCEEDED **`, 12.7 s. Snapshot 2: intermittent failure in `serialized`, 2 of 13 whole-suite runs and 2 of 30 `CellKeeperCoreTests` runs |
| 20 | Entitlement assertion step, positive on both trees and negative with the key stripped | exit 0 / exit 1 |
| 21 | `defaults.run.shell: bash`, strict and non-strict runs of all four build steps on the actual project copy | all pass; empty bash array expansion is fine on bash 3.2 |
| 22 | `-derivedDataPath` whose string starts with the project directory path | cosmetic `.pcm: No such file or directory` warning, exit 0 |
| 23 | `grep objectVersion` in the Xcode 27.0 bundle's project prototypes and templates | App and Tool prototypes: 90 (with `preferredProjectObjectVersion = 90`); visionOS sample template: 77 |
| 24 | Instrumented the flaky test in a scratch copy | failing runs: `observedMaximum = 0` (no request), never 2 |
| 25 | Same scratch copy with one deterministic `evaluate(.launch)` before the task group | 60 passes in 60 runs (baseline 2 failures in 30) |
| 26 | `diff` of the worktree's `CODE_OF_CONDUCT.md` against upstream Contributor Covenant 3.0 | identical except the reporting placeholder text and the removed second `[NOTE]` |
