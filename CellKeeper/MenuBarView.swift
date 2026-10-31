import CellKeeperCore
import CellKeeperKit
import SwiftUI

/// The menu's measurements, in one place (design guide): its width, the
/// inset around its content, the gap between its groups and the gaps
/// inside one.
private enum MenuLayout {
    static let width: CGFloat = 340
    static let inset: CGFloat = 14
    static let groupSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let lineSpacing: CGFloat = 4
    /// How far Details' groups sit in from its disclosure.
    static let detailsIndent: CGFloat = 16
}

/// The menu, top to bottom (design guide): the battery's state and what
/// qualifies it; the charge limit, Manage charging and one contextual
/// action; Details, collapsed; and the footer. A warning or a request that
/// asks the user to act stays visible beside the state it qualifies, never
/// only inside Details (rule 2); the backend's routine mechanics are in
/// Details (O6).
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.groupSpacing) {
            if let status = model.status {
                StatusGroup(model: model, status: status, openSettingsWindow: openSettingsWindow)
                Divider()
                VStack(alignment: .leading, spacing: MenuLayout.rowSpacing) {
                    ChargeLimitControl(model: model)
                    FullChargeControl(model: model, status: status)
                        .padding(.top, MenuLayout.lineSpacing)
                }
                Divider()
                DetailsDisclosure(model: model, status: status)
            } else {
                ProgressView("Reading battery…")
                    .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Settings…", action: openSettingsWindow)
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit CellKeeper") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(MenuLayout.inset)
        .frame(width: MenuLayout.width)
    }

    /// Opens the Settings window at the pane `model.settingsTab` names.
    private func openSettingsWindow() {
        NSApp.activate()
        openSettings()
    }
}

// MARK: - Header and attention

/// The header and what qualifies it: the battery's charge, power source
/// and charging status; what controls charging and how far it is trusted;
/// and anything that asks the user to act or explains a charging state
/// that differs from what the limit suggests.
private struct StatusGroup: View {
    let model: AppModel
    let status: ControllerStatus
    /// Opens the Settings window at the pane `model.settingsTab` names.
    let openSettingsWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MenuLayout.rowSpacing) {
            BatteryHeader(snapshot: status.snapshot, telemetryError: status.telemetryError)
            ControlLine(status: status)
            AttentionLines(model: model, status: status, openSettingsWindow: openSettingsWindow)
        }
    }
}

private struct BatteryHeader: View {
    let snapshot: BatterySnapshot?
    let telemetryError: String?
    /// 30 points at the standard text size, scaled with it where macOS
    /// applies one.
    @ScaledMetric(relativeTo: .largeTitle) private var chargeSize: CGFloat = 30

    var body: some View {
        if let snapshot, snapshot.isBatteryPresent {
            // One element for VoiceOver: "Charge 81%, Power adapter, Charging".
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(snapshot.chargePercent))
                    .font(.system(size: chargeSize, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Charge \(Format.percent(snapshot.chargePercent))")
                VStack(alignment: .leading, spacing: 2) {
                    // A neutral battery symbol: the percentage says how full
                    // it is, and an unknown source is said in words.
                    Label(snapshot.powerSource.title, systemImage: snapshot.isOnExternalPower ? "powerplug" : "batteryblock")
                    if snapshot.chargingStatus == .notCharging {
                        // macOS does not report why charging is paused; its
                        // Charge Limit, when on, is one possible cause among
                        // others, so none is named (M1).
                        Text("\(snapshot.chargingStatus.title) · Cause not reported.")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(snapshot.chargingStatus.title). Cause not reported.")
                    } else {
                        Text(snapshot.chargingStatus.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            .accessibilityElement(children: .combine)
        } else if let snapshot, !snapshot.isBatteryPresent {
            Label("No battery detected on this Mac.", systemImage: "batteryblock.slash")
        } else {
            Label(telemetryError ?? "Battery telemetry unavailable.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.warningText)
        }
    }
}

/// What controls charging and how far it is trusted, under the header.
/// macOS's Charge Limit shows its name and availability (M4: the mechanism
/// and how far it is verified are in Details › Charging control and
/// Settings › Control) and, when unavailable, the reason. A backend that
/// switches charging itself shows ``ControlStatement``'s line, which names
/// a simulation.
private struct ControlLine: View {
    let status: ControllerStatus

    var body: some View {
        let capabilities = status.capabilities
        if capabilities.isEnforcedByMacOS {
            Text("\(status.backend.displayName) · \(capabilities.availability.badgeTitle)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(status.backend.displayName), \(capabilities.availability.badgeTitle)")
            if case .unavailable = capabilities.availability {
                Label(capabilities.explanation, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ControlStatementText(status: status)
        }
    }
}

/// What asks the user to act, or explains a charging state that differs
/// from what the limit suggests, each under its existing condition: a
/// backend fault, a failed or refused action, macOS's Charge Limit as seen
/// by a backend that switches charging itself, a pending backend switch,
/// the policy's exceptional states, and, with macOS's Charge Limit as the
/// backend, an unjudged read, a restore that is not confirmed, an adopted
/// outside change and a read problem. A settled, healthy state shows
/// nothing here.
private struct AttentionLines: View {
    let model: AppModel
    let status: ControllerStatus
    let openSettingsWindow: () -> Void

    var body: some View {
        Group {
            if status.isBackendFaulted {
                VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
                    Label(status.capabilities.isEnforcedByMacOS
                          ? "The control backend failed repeatedly. Until the fault is cleared, CellKeeper only gives back your own Charge Limit."
                          : "The control backend failed repeatedly. Only normal charging will be requested.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.criticalText)
                    // The fault is cleared in Settings › Control.
                    Button("Control Settings…") {
                        model.settingsTab = .control
                        openSettingsWindow()
                    }
                    .controlSize(.small)
                    .help("Opens Settings › Control, where the fault is cleared.")
                }
            }
            if let execution = status.lastExecution, let tone = execution.result.attentionTone {
                Label(execution.result.title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(tone)
            }
            if status.capabilities.isEnforcedByMacOS {
                NativeLimitAttention(status: status)
            }
            // What macOS reports and how to turn it off, whatever the policy
            // says first (an unfinished restore, for example). Not for a
            // backend that controls nothing: turning macOS's limit off would
            // then leave nothing limiting charging.
            if let macOSLimit = status.capabilities.macOSChargeLimit, ControlStatement.offersMacOSLimitGuide(status) {
                MacOSChargeLimitNotice(macOSLimit: macOSLimit, status: status, recheck: { model.recheckBackend() }, showGuide: {
                    model.showMacOSLimitGuide()
                    openSettingsWindow()
                })
            }
            PendingSwitchNotice(status: status, select: { model.selectBackend($0) })
            // A backend that accepts no requests carries nothing out: its
            // decision is only what CellKeeper would do.
            if let decision = status.decision, ControlStatement.isPolicyApplied(status) {
                PolicyAttention(decision: decision, status: status)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// macOS's Charge Limit as the backend: what keeps the menu from calling
/// the limit enforced, and what asks the user to act. An unjudged read is
/// neutral (D118, D119). A restore that is not confirmed, an outside change
/// adopted with Manage charging off, a "no limit" report to confirm, a read
/// problem and a limit CellKeeper cannot change back are warnings, each
/// with a symbol and words.
private struct NativeLimitAttention: View {
    let status: ControllerStatus

    var body: some View {
        let native = status.nativeLimit
        if let deferral = native?.readDeferral {
            // Not "no limit": macOS clears its active limit on battery power
            // (note 08, O20).
            VStack(alignment: .leading, spacing: 2) {
                Text(NativeLimitWording.deferralTitle(deferral))
                    .font(.callout)
                Text(NativeLimitWording.deferralDetail(deferral))
                    .foregroundStyle(.secondary)
            }
        }
        // Shared with the restore notification.
        if let problem = NativeLimitWording.restoreProblem(status) {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.criticalText)
        }
        if let adopted = status.adoptedChange, !status.settings.isManagementEnabled {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The limit was changed outside CellKeeper to \(Format.chargeLimit(adopted.limit)), so CellKeeper kept it as your own and turned off Manage charging. Turn it on to let CellKeeper manage the limit again.")
                    if adopted.isNoLimit, adopted.previousOwnerLimit != adopted.limit {
                        Text("If that was a temporary full charge rather than your choice, your earlier limit was \(Format.chargeLimit(adopted.previousOwnerLimit)).")
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.warningText)
        }
        if native?.needsNoLimitConfirmation == true {
            Label("macOS reports no limit. If your own limit is 100%, confirm it in Settings › Control before CellKeeper changes anything.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.warningText)
        }
        if let problem = native?.readProblem {
            Label("Could not read the Charge Limit: \(problem)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.warningText)
        }
        if let owner = native?.ownerLimit, !status.capabilities.availability.acceptsRequests, !status.isOwnLimitRestorePending {
            Label("CellKeeper cannot change the limit back right now. Set \(Format.chargeLimit(owner)) in System Settings › Battery › Charging.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.criticalText)
        }
    }
}

/// The policy's state when charging then differs materially from what the
/// limit suggests (a temperature pause, the fail-safe), with its reason,
/// and the notes that explain such a state. Ordinary threshold narration
/// and the other notes are in Details › Charging control. A decision is
/// intent: whether the backend carried it out is said by its own lines.
private struct PolicyAttention: View {
    let decision: PolicyDecision
    let status: ControllerStatus

    var body: some View {
        if decision.state.asksAttention, !Self.isSaidElsewhere(decision.reason) {
            // Labelled as the policy, as in Details: a pause the backend
            // refused is still only what the policy asks for, and the last
            // action's line says what came of it.
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent {
                    Text(decision.state.title(nativeLimit: status.capabilities.isEnforcedByMacOS))
                } label: {
                    Label("Policy", systemImage: "exclamationmark.triangle")
                }
                .accessibilityElement(children: .combine)
                Text(status.displayedReason ?? decision.reason.description)
            }
            .foregroundStyle(.warningText)
        }
        ForEach(Array(decision.notes.filter(\.asksAttention).enumerated()), id: \.offset) { _, note in
            Label(note.description, systemImage: note.isWarning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(note.isWarning ? Color.warningText : Color.secondary)
        }
    }

    /// Whether another visible line already says why the policy is in the
    /// fail-safe: the pending switch's notice, the restore warning, the
    /// header's missing battery, or the limit control's "Not set".
    private static func isSaidElsewhere(_ reason: DecisionReason) -> Bool {
        switch reason {
        case .releaseRequired(.backendSwitch), .releaseRequired(.restoreUnfinished), .batteryNotPresent, .nativeLimitUnsupported: true
        default: false
        }
    }
}

// MARK: - Charge limit

/// The charge-limit control: a slider for CellKeeper's own control, or the
/// values macOS's Charge Limit accepts.
private struct ChargeLimitControl: View {
    let model: AppModel

    var body: some View {
        if model.usesNativeLimit {
            NativeChargeLimitPicker(model: model)
        } else {
            ChargeLimitSlider(model: model)
        }
    }
}

/// Changes are applied immediately; the controller rate-limits them. The
/// heading names CellKeeper's configured target; what macOS established is
/// said under the control, from a judged read only (D118). A selected
/// segment is never evidence of enforcement.
private struct NativeChargeLimitPicker: View {
    let model: AppModel

    var body: some View {
        let steps = model.nativeLimitSteps
        let limit = model.settings.chargeLimit
        VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
            HStack {
                Text("CellKeeper limit")
                    .font(.headline)
                Spacer()
                Text(steps.contains(limit) ? Format.chargeLimit(limit) : "Not set")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Picker("Charge limit", selection: Binding<Int?>(
                get: { steps.contains(limit) ? limit : nil },
                set: { if let value = $0 { model.setChargeLimit(value) } }
            )) {
                ForEach(steps, id: \.self) { step in
                    Text("\(step)%")
                        .accessibilityLabel(AccessibilityWording.chargeLimit(step))
                        .tag(Int?.some(step))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.settings.isManagementEnabled)
            .help("macOS enforces this limit and resumes charging once the battery drops more than 5%; a custom resume point is not available with its Charge Limit.")
            if !steps.contains(limit) {
                Label("\(ChargeLimitChoices.notSettableWithMacOSLimit(limit)) Choose one of the values above; until then your own limit stays in effect.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.status {
                NativeLimitLine(status: status)
            }
            ManageChargingToggle(model: model)
            if let status = model.status {
                OwnLimitLine(status: status)
            }
        }
    }
}

/// What macOS established, under the segments: the limit a judged read
/// showed (M5), or that it could not be read (M6). Nothing while the read
/// is deferred, when the header says why; a write still awaiting its
/// read-back says so here instead (M10).
private struct NativeLimitLine: View {
    let status: ControllerStatus

    var body: some View {
        let native = status.nativeLimit
        Group {
            if native?.readDeferral == nil {
                if let reported = native?.reportedLimit {
                    Text("macOS enforces \(Format.chargeLimit(reported)).")
                } else {
                    Text("macOS Charge Limit could not be read.")
                }
            } else if let execution = status.lastExecution, case .deferred(written: true) = execution.result {
                Text(execution.result.title)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The user's own limit, under Manage charging: saved, so CellKeeper can
/// give it back (M7; when it does is said in Details › Charging control);
/// waiting for power with nothing written, which is neutral (D119); or not
/// changed by CellKeeper (M8). Nothing while a restore is not confirmed:
/// the header's warning names the limit then.
private struct OwnLimitLine: View {
    let status: ControllerStatus

    var body: some View {
        if NativeLimitWording.restoreProblem(status) == nil {
            Group {
                if let owner = status.nativeLimit?.ownerLimit, status.isOwnLimitRestoreWaitingForPower {
                    Text(NativeLimitWording.restoreWaitingForPower(owner))
                } else if let owner = status.nativeLimit?.ownerLimit {
                    Text("Your own limit: \(Format.chargeLimit(owner)) (saved).")
                } else {
                    Text("CellKeeper has not changed this setting.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Charge-limit slider. ``ChargeLimitSliderEdit`` (Kit) decides what is
/// applied and when; this view only feeds it events and carries out what it
/// returns. A drag is applied when it ends, a change made without a drag
/// (the arrow keys, VoiceOver's increment and decrement) once the value has
/// stayed put for a moment, and only if no other settings change came first:
/// a newer command, from anywhere, wins.
private struct ChargeLimitSlider: View {
    let model: AppModel
    /// Made when the slider appears, closed when it goes away.
    @State private var edit: ChargeLimitSliderEdit?
    /// The pause before a change made without a drag is applied.
    @State private var timer: Task<Void, Never>?

    /// How long a value changed without a drag stays put before it is
    /// applied.
    private static let applyDelay = Duration.milliseconds(600)
    private static let range = ChargingSettings.chargeLimitRange

    var body: some View {
        let shown = edit?.draft ?? model.settings.chargeLimit
        VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
            HStack {
                Text("Charge limit")
                    .font(.headline)
                Spacer()
                Text(shown >= 100 ? "No limit" : "\(shown)%")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Slider(
                value: Binding(get: { Double(shown) }, set: { send(.userChanged(Int($0.rounded()))) }),
                in: Double(Self.range.lowerBound)...Double(Self.range.upperBound)
            ) {
                Text("Charge limit")
            } onEditingChanged: { editing in
                send(editing ? .dragBegan : .dragEnded(edit?.draft ?? model.settings.chargeLimit))
            }
            .labelsHidden()
            .disabled(!model.settings.isManagementEnabled)
            .accessibilityValue(AccessibilityWording.chargeLimit(shown))
            .accessibilityAdjustableAction { direction in
                guard model.settings.isManagementEnabled else { return }
                let step: Int
                switch direction {
                case .increment: step = 1
                case .decrement: step = -1
                @unknown default: return
                }
                send(.userChanged(min(max(shown + step, Self.range.lowerBound), Self.range.upperBound)))
            }
            // The configured value (M18): whether charging resumes there is
            // the backend's to establish.
            Text("Resume threshold: \(model.settings.resumeThreshold)%.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The notice above already warns of a restriction that may remain.
            if let status = model.status, let note = ControlStatement.limitNote(for: status, includesOwnRestriction: false) {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shown < 50 {
                Label("Limits below 50% leave little charge for unplugged use.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ManageChargingToggle(model: model)
        }
        .onAppear {
            edit = ChargeLimitSliderEdit(limit: model.settings.chargeLimit, revision: model.settingsRevision)
        }
        .onChange(of: model.settingsRevision) {
            send(.settingsChanged(revision: model.settingsRevision, limit: model.settings.chargeLimit))
        }
        .onDisappear {
            // Applies the current edit once, at once; the timer then does
            // nothing.
            send(.closed)
            timer?.cancel()
            timer = nil
        }
    }

    private func send(_ event: ChargeLimitSliderEdit.Event) {
        guard var current = edit else { return }
        let output = current.handle(event)
        edit = current
        switch output {
        case .nothing:
            break
        case .showModelValue:
            // The draft is gone: the slider shows the model's limit.
            timer?.cancel()
            timer = nil
        case .startTimer(let token):
            timer?.cancel()
            timer = Task {
                try? await Task.sleep(for: Self.applyDelay)
                guard !Task.isCancelled else { return }
                send(.timerFired(token: token))
            }
        case .apply(let limit, let revision):
            timer?.cancel()
            timer = nil
            model.setChargeLimit(limit, ifSettingsRevision: revision)
            // What the model holds now, before any later event: an edit
            // that starts next begins from it.
            send(.settingsChanged(revision: model.settingsRevision, limit: model.settings.chargeLimit))
        }
    }
}

private struct ManageChargingToggle: View {
    let model: AppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.settings.isManagementEnabled },
            set: { newValue in model.updateSettings { $0.isManagementEnabled = newValue } }
        )) {
            // The label fills the row, so the switch sits at its end.
            Text("Manage charging")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        if let error = model.settingsError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Contextual action

/// The one contextual action: Charge to 100% Once, or the running
/// session's line and its cancel. While a calibration runs, its lines and
/// answers take the action's place: its status says why no full charge
/// can start. Beneath, the schedules' status, due reasons, store problems
/// and outcomes; schedules are set up in Settings › Charging (O2).
private struct FullChargeControl: View {
    let model: AppModel
    let status: ControllerStatus

    var body: some View {
        CalibrationLines(model: model, status: status)
        if let override = status.activeOverride {
            VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
                switch override.kind {
                case .fullCharge:
                    Label(TemporaryFullChargeWording.line(for: override, status: status, lastResult: status.lastExecution?.result.title, now: status.describedAt), systemImage: "arrow.up.to.line")
                case .dischargeToLimit:
                    Label(dischargeText(override), systemImage: "minus.plus.batteryblock")
                        .foregroundStyle(.warningText)
                }
                HStack {
                    Spacer()
                    Button(override.kind == .fullCharge ? "Cancel Full Charge" : "Cancel Discharge") { model.cancelOverride() }
                        .controlSize(.small)
                        .accessibilityLabel(override.kind == .fullCharge ? "Cancel the temporary full charge" : "Cancel the discharge")
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } else if !status.calibration.isInProgress {
            // One predicate enables the button and gives the reason.
            let refusal = FullChargeStart.refusal(settings: model.settings, status: status)
            let help = TemporaryFullChargeWording.buttonHelp(for: status)
            Button {
                model.startFullCharge()
            } label: {
                Label("Charge to 100% Once", systemImage: "arrow.up.to.line")
            }
            .disabled(refusal != nil)
            .help(help)
            .disabledReasonHint(refusal, help: help)
            if let refusal {
                DisabledReason(text: refusal)
            }
        }
        ScheduledFullChargeLines(model: model, status: status)
        WeeklyFullChargeLines(model: model, status: status)
    }

    /// Says a discharge is happening only while the policy is running one
    /// and the backend has confirmed the mode it needs (the full charge's
    /// line is `TemporaryFullChargeWording`'s). The session stops at its
    /// target or at the current limit, whichever is higher
    /// (`ChargingPolicy`).
    private func dischargeText(_ override: ChargeOverride) -> String {
        let limit = status.settings.chargeLimit
        let target = max(override.targetPercent ?? limit, limit)
        let stops = "Stops at the target, on sleep, or when unplugged."
        switch overrideProgress(runningIn: .discharging) {
        case .unavailable: return "Discharge to \(target)% requested, but charging control is unavailable"
        case .notInEffect(let why): return "Discharge to \(target)% requested, not in effect\(why). \(stops)"
        case .running(simulated: true): return "Simulating a discharge to \(target)% while plugged in. \(stops)"
        case .running(simulated: false): return "Discharging to \(target)% while plugged in. \(stops)"
        }
    }

    private enum OverrideProgress {
        case unavailable
        /// `why` is the last action, ready to append, or empty.
        case notInEffect(why: String)
        case running(simulated: Bool)
    }

    /// Whether the policy is running the override (`state`) and the backend
    /// has confirmed the mode it needs.
    private func overrideProgress(runningIn state: PolicyState) -> OverrideProgress {
        if case .unavailable = status.capabilities.availability { return .unavailable }
        guard let decision = status.decision, decision.state == state,
              status.currentMode == decision.desiredMode
        else {
            return .notInEffect(why: status.lastExecution.map { " (\($0.result.title))" } ?? "")
        }
        return .running(simulated: status.capabilities.availability == .simulated)
    }
}

/// The menu's lines for a guided calibration (research note 12 §7.5): the
/// step and what to do next, with Continue for a session found at launch
/// (with the owner's answer after a restart in the rest) and Cancel; the
/// temperature note; a store that could not save the end; and what became
/// of the latest session, with OK. The wording is `CalibrationWording`'s.
private struct CalibrationLines: View {
    let model: AppModel
    let status: ControllerStatus

    var body: some View {
        let calibration = status.calibration
        if let session = calibration.session, let line = CalibrationWording.statusLine(for: status) {
            let isRequest = CalibrationWording.request(for: status) != nil || calibration.isPaused
            VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
                Label(line, systemImage: "gauge.with.needle")
                    .fontWeight(isRequest ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
                if session.temperatureCheck == .ownerConfirmedCoolRoom {
                    Text(CalibrationWording.temperatureUnknown)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if calibration.isPaused {
                        if calibration.needsRestAnswer {
                            Button("Yes, Continue") { model.continueCalibration(restAnswer: true) }
                                .accessibilityLabel("Yes, it stayed shut down and unplugged; continue the calibration")
                            Button("No, Continue") { model.continueCalibration(restAnswer: false) }
                                .accessibilityLabel("No, it did not; continue the calibration")
                        } else {
                            Button("Continue") { model.continueCalibration() }
                                .accessibilityLabel("Continue the calibration")
                        }
                    }
                    Button("Cancel Calibration") { model.cancelCalibration() }
                        .accessibilityLabel("Cancel the calibration")
                }
                .controlSize(.small)
                if let refusal = calibration.refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
        if calibration.isEvidenceRetained {
            Label(CalibrationWording.evidenceRetained, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if calibration.isEndUnsaved {
            Label(CalibrationWording.endUnsaved, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if calibration.session == nil, let outcome = calibration.outcome {
            HStack(alignment: .firstTextBaseline) {
                Label(CalibrationWording.outcomeLine(outcome, status: status), systemImage: outcome.end.asksToPlugIn ? "exclamationmark.triangle" : "gauge.with.needle")
                    .foregroundStyle(outcome.end.asksToPlugIn ? Color.warningText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("OK") { model.dismissCalibrationOutcome() }
                    .controlSize(.small)
                    .accessibilityLabel("OK, dismiss the calibration message")
            }
            .font(.caption)
        }
    }
}

/// The menu's lines for a scheduled full charge: the armed window (or why a
/// due one cannot start yet), and what became of the latest one. The wording
/// is `FullChargeScheduleWording`'s.
private struct ScheduledFullChargeLines: View {
    let model: AppModel
    let status: ControllerStatus

    var body: some View {
        if let schedule = status.fullChargeSchedule {
            HStack(alignment: .firstTextBaseline) {
                Label(FullChargeScheduleWording.armedLine(schedule, wait: status.fullChargeScheduleWait, now: status.describedAt), systemImage: status.fullChargeScheduleWait == nil ? "calendar.badge.clock" : "exclamationmark.triangle")
                    .foregroundStyle(status.fullChargeScheduleWait == nil ? Color.primary : Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel Schedule") { model.cancelFullChargeSchedule() }
                    .controlSize(.small)
                    .accessibilityLabel("Cancel the scheduled full charge")
            }
            .font(.caption)
        }
        if let outcome = status.fullChargeScheduleOutcome, let line = FullChargeScheduleWording.outcomeLine(outcome) {
            HStack(alignment: .firstTextBaseline) {
                Label(line, systemImage: "calendar")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("OK") { model.dismissFullChargeScheduleOutcome() }
                    .controlSize(.small)
                    .accessibilityLabel("OK, dismiss the scheduled full charge message")
            }
            .font(.caption)
        }
    }
}

/// The menu's lines for the weekly full charge: its next start, always
/// while one is in use; beneath it, an occurrence that is due but cannot
/// start yet, and a store that could not keep up; and what became of the
/// latest occurrence. The wording is `WeeklyFullChargeWording`'s.
private struct WeeklyFullChargeLines: View {
    let model: AppModel
    let status: ControllerStatus

    var body: some View {
        let now = status.describedAt
        if status.weeklyFullCharge != nil {
            Label(WeeklyFullChargeWording.menuLine(status.weeklyFullChargeNext, now: now), systemImage: "calendar.badge.clock")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let due = status.weeklyFullChargeDue {
                Label(WeeklyFullChargeWording.dueLine(due, now: now), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let problem = status.weeklyFullChargeStoreProblem {
            Label(WeeklyFullChargeWording.storeProblemLine(problem), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let outcome = status.weeklyFullChargeOutcome, let line = WeeklyFullChargeWording.outcomeLine(outcome, now: now) {
            HStack(alignment: .firstTextBaseline) {
                Label(line, systemImage: "calendar")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("OK") { model.dismissWeeklyFullChargeOutcome() }
                    .controlSize(.small)
                    .accessibilityLabel("OK, dismiss the weekly full charge message")
            }
            .font(.caption)
        }
    }
}

// MARK: - Details

/// Everything one click away (design guide): the power flow, the battery's
/// details, the backend's mechanics and the configured schedules, each
/// under its own disclosure. Closed when the menu's view is made. Closing
/// it closes Power flow with it, through the existing collapse path, so
/// nothing samples while hidden (D114, D115): a persisted "expanded" flag
/// is not proof of visibility.
private struct DetailsDisclosure: View {
    let model: AppModel
    let status: ControllerStatus
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Details", isExpanded: Binding(
            get: { isExpanded },
            set: { expanded in
                isExpanded = expanded
                if !expanded, model.isPowerFlowExpanded {
                    model.setPowerFlowExpanded(false)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: MenuLayout.rowSpacing) {
                PowerFlowSection(model: model)
                TelemetryDetails(snapshot: status.snapshot, thermalState: model.thermalState, isLowPowerModeEnabled: model.isLowPowerModeEnabled)
                ChargingControlDetails(status: status)
                SchedulesDetails(status: status)
            }
            // Indented under Details, so the four groups read as its content.
            .padding(.leading, MenuLayout.detailsIndent)
            .padding(.top, MenuLayout.lineSpacing)
        }
    }
}

private struct TelemetryDetails: View {
    let snapshot: BatterySnapshot?
    let thermalState: ProcessInfo.ThermalState
    let isLowPowerModeEnabled: Bool

    var body: some View {
        DisclosureGroup("Battery details") {
            if let snapshot {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Cycle count", snapshot.health.cycleCount.map(String.init) ?? Format.unavailable)
                    row("Capacity", Format.capacity(snapshot.health), spoken: Format.Spoken.capacity(snapshot.health),
                        note: "Computed from full-charge and design capacity; may differ from macOS.")
                    if let condition = snapshot.health.condition {
                        row("Condition", condition)
                    }
                    row("Temperature", Format.celsius(snapshot.temperatureCelsius), spoken: Format.Spoken.celsius(snapshot.temperatureCelsius))
                    row("Voltage", Format.volts(fromMillivolts: snapshot.voltageMillivolts), spoken: Format.Spoken.volts(fromMillivolts: snapshot.voltageMillivolts))
                    row("Current", Format.milliamps(snapshot.amperageMilliamps), spoken: Format.Spoken.milliamps(snapshot.amperageMilliamps))
                    if let watts = snapshot.adapterWatts {
                        row("Adapter", "\(watts) W", spoken: AccessibilityWording.watts(watts))
                    }
                    if let toEmpty = Format.minutes(snapshot.timeToEmptyMinutes) {
                        row("Time to empty", toEmpty, spoken: Format.Spoken.minutes(snapshot.timeToEmptyMinutes))
                    }
                    if let toFull = Format.minutes(snapshot.timeToFullMinutes) {
                        row("Time to full", toFull, spoken: Format.Spoken.minutes(snapshot.timeToFullMinutes))
                    }
                    row("Mac thermal state", thermalState.title, note: "For the whole Mac, not the battery temperature.")
                    row("Low Power Mode", isLowPowerModeEnabled ? "On" : "Off")
                }
                .font(.caption)
                .padding(.top, MenuLayout.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Read at \(snapshot.timestamp.formatted(date: .omitted, time: .standard)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(Format.unavailable).font(.caption)
            }
        }
    }

    /// One element for VoiceOver per row: the value, named by its label,
    /// with its unit in words (`spoken`) where the screen abbreviates it.
    /// A `note` qualifies the value beside it (M17), as its own element.
    private func row(_ label: String, _ value: String, spoken: String? = nil, note: String? = nil) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).monospacedDigit()
                    .accessibilityLabel(label)
                    .accessibilityValue(spoken ?? value)
                if let note {
                    Text(note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The backend's mechanics (O6): what it is and what its availability
/// means, the policy's state and desired mode, which are intent rather
/// than evidence that a request was sent, its ordinary reason and notes,
/// the last action, and, with macOS's Charge Limit, when it was read and
/// when the user's own limit is given back. A backend that accepts no
/// requests carries nothing out: its rows say so.
private struct ChargingControlDetails: View {
    let status: ControllerStatus

    var body: some View {
        let isApplied = ControlStatement.isPolicyApplied(status)
        let isNative = status.capabilities.isEnforcedByMacOS
        DisclosureGroup {
            VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
                // The Simulated backend is named by its availability already.
                LabeledContent("Backend", value: status.backend.displayName == status.capabilities.availability.badgeTitle
                               ? status.backend.displayName
                               : "\(status.backend.displayName) · \(status.capabilities.availability.badgeTitle)")
                    .accessibilityElement(children: .combine)
                Text(status.capabilities.explanation)
                    .foregroundStyle(.secondary)
                if let decision = status.decision {
                    // While the policy defers to macOS's limit, the line
                    // under the header and the notice say all its state and
                    // reason would.
                    if decision.state != .deferringToMacOS {
                        LabeledContent(isApplied ? "Policy" : "Policy (not applied)", value: decision.state.title(nativeLimit: isNative))
                            .accessibilityElement(children: .combine)
                    }
                    LabeledContent(isApplied ? "Desired mode" : "Desired mode (not applied)", value: decision.desiredMode.intentTitle(nativeLimit: isNative))
                        .accessibilityElement(children: .combine)
                    if decision.state != .deferringToMacOS, isApplied {
                        Text(status.displayedReason ?? decision.reason.description)
                            .foregroundStyle(.secondary)
                    }
                    // The notes that explain an exceptional state are under
                    // the header.
                    ForEach(Array((isApplied ? decision.notes.filter { !$0.asksAttention } : []).enumerated()), id: \.offset) { _, note in
                        Label(note.description, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if let execution = status.lastExecution {
                    LabeledContent("Last action", value: execution.result.title)
                        .accessibilityElement(children: .combine)
                }
                if isNative {
                    if let readAt = status.nativeLimit?.readAt {
                        LabeledContent("Charge Limit read", value: readAt.formatted(date: .omitted, time: .standard))
                            .accessibilityElement(children: .combine)
                    }
                    if let owner = status.nativeLimit?.ownerLimit, NativeLimitWording.restoreProblem(status) == nil, !status.isOwnLimitRestoreWaitingForPower {
                        Text("Set by CellKeeper. Your own limit, \(Format.chargeLimit(owner)), is restored when CellKeeper stops managing it, quits, or fails.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, MenuLayout.lineSpacing)
        } label: {
            // A heading, as the section's title was before it moved into
            // Details (D109).
            Text("Charging control")
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The configured schedules (O2): the one-off window and the weekly
/// pattern, set up in Settings › Charging. Their status, due reasons,
/// store problems and outcomes stay in the panel above.
private struct SchedulesDetails: View {
    let status: ControllerStatus

    var body: some View {
        DisclosureGroup("Schedules") {
            VStack(alignment: .leading, spacing: MenuLayout.lineSpacing) {
                if let schedule = status.fullChargeSchedule {
                    LabeledContent("Full charge", value: FullChargeScheduleWording.window(schedule, now: status.describedAt))
                        .accessibilityElement(children: .combine)
                }
                if let weekly = status.weeklyFullCharge {
                    LabeledContent("Weekly", value: WeeklyFullChargeWording.summary(weekly.pattern))
                        .accessibilityElement(children: .combine)
                }
                if status.fullChargeSchedule == nil, status.weeklyFullCharge == nil {
                    Text("No full charge is scheduled.")
                }
                Text("Schedules are set up in Settings › Charging.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, MenuLayout.lineSpacing)
        }
    }
}

// MARK: - What stays visible

extension ExecutionRecord.Result {
    /// The tone of a result the menu keeps visible under the header: a
    /// failure, or a refusal with its reason. Nil for the rest, which
    /// Details › Charging control lists as the last action.
    fileprivate var attentionTone: Color? {
        switch self {
        case .failed: .criticalText
        case .refused: .warningText
        case .applied, .unchanged, .simulated, .adoptedOutsideChange, .deferred: nil
        }
    }
}

extension PolicyState {
    /// Whether charging then differs materially from what the limit
    /// suggests, so the menu explains the state under the header rather
    /// than in Details: a temperature pause and the fail-safe. The deferral
    /// to macOS's Charge Limit has its own line and notice there already.
    fileprivate var asksAttention: Bool {
        switch self {
        case .temperaturePause, .failSafe: true
        case .unmanaged, .safetyFloor, .onBattery, .fullChargeOverride, .charging, .holding, .discharging,
             .osEnforcedLimit, .deferringToMacOS, .calibrating: false
        }
    }
}

extension PolicyNote {
    /// Whether the note explains a charging state that differs from what
    /// the limit suggests, so the menu shows it under the header: a limit
    /// being confirmed before charging pauses, a native limit kept without
    /// telemetry, a discharge the backend cannot run and one that ended for
    /// macOS's Charge Limit, and temperature protection that cannot act
    /// without a reading (losing it can end a temperature pause). A
    /// suppressed full charge is said by the full charge's own line.
    fileprivate var asksAttention: Bool {
        switch self {
        case .confirmingLimit, .nativeLimitKeptWithoutTelemetry, .dischargeUnsupported, .dischargeEndedForMacOSChargeLimit, .temperatureUnavailable: true
        case .fullChargeSuppressed: false
        }
    }

    /// Whether the note is a warning (something is not as asked) rather
    /// than information about what CellKeeper is doing.
    fileprivate var isWarning: Bool {
        switch self {
        case .nativeLimitKeptWithoutTelemetry, .dischargeUnsupported, .dischargeEndedForMacOSChargeLimit, .temperatureUnavailable: true
        case .confirmingLimit, .fullChargeSuppressed: false
        }
    }
}
