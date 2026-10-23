import CellKeeperCore
import CellKeeperKit
import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = model.status {
                BatteryHeader(snapshot: status.snapshot, telemetryError: status.telemetryError, nativeLimit: status.nativeLimit)
                Divider()
                ControlSummary(status: status, selectBackend: { model.selectBackend($0) }, recheck: { model.recheckBackend() }, showMacOSLimitGuide: {
                    model.showMacOSLimitGuide()
                    NSApp.activate()
                    openSettings()
                })
                Divider()
                ChargeLimitControl(model: model)
                FullChargeControl(model: model, status: status, openScheduleSettings: {
                    model.settingsTab = .charging
                    NSApp.activate()
                    openSettings()
                })
                Divider()
                PowerFlowSection(model: model)
                TelemetryDetails(snapshot: status.snapshot, thermalState: model.thermalState, isLowPowerModeEnabled: model.isLowPowerModeEnabled)
            } else {
                ProgressView("Reading battery…")
                    .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit CellKeeper") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct BatteryHeader: View {
    let snapshot: BatterySnapshot?
    let telemetryError: String?
    let nativeLimit: NativeLimitStatus?
    /// 30 points at the standard text size, scaled with it where macOS
    /// applies one.
    @ScaledMetric(relativeTo: .largeTitle) private var chargeSize: CGFloat = 30

    var body: some View {
        if let snapshot, snapshot.isBatteryPresent {
            // One element for VoiceOver: "Charge 81%, Power adapter, Charging".
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(snapshot.chargePercent))
                    .font(.system(size: chargeSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("Charge \(Format.percent(snapshot.chargePercent))")
                VStack(alignment: .leading, spacing: 2) {
                    Label(snapshot.powerSource.title, systemImage: snapshot.isOnExternalPower ? "powerplug" : "battery.100percent")
                    Text(snapshot.chargingStatus.title)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .accessibilityElement(children: .combine)
            if snapshot.chargingStatus == .notCharging {
                // macOS does not report why charging is paused.
                Group {
                    if let limit = nativeLimit?.reportedLimit, limit < 100 {
                        Text("macOS reports charging as paused. Its Charge Limit is \(limit)%, the likely reason, but macOS does not report the cause.")
                    } else {
                        Text("macOS reports charging as paused. The cause (for example Charge Limit, Optimized Battery Charging, or another app) is not reported.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if let snapshot, !snapshot.isBatteryPresent {
            Label("No battery detected on this Mac.", systemImage: "batteryblock.slash")
        } else {
            Label(telemetryError ?? "Battery telemetry unavailable.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.warningText)
        }
    }
}

private struct ControlSummary: View {
    let status: ControllerStatus
    /// Selects a backend, to cancel a pending switch.
    let selectBackend: (ControlBackendChoice) -> Void
    /// Checks again what the backend depends on, such as macOS's Charge Limit.
    let recheck: () -> Void
    /// Opens Settings › Control with the steps for turning macOS's Charge
    /// Limit off.
    let showMacOSLimitGuide: () -> Void

    var body: some View {
        // When macOS's Charge Limit is settled, its summary says it all; the
        // details return as soon as anything differs (Settings › Control,
        // Activity and Diagnostics always have them).
        let isSettled = status.isNativeLimitSettled
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Charging control")
                    .font(.headline)
                Spacer()
                StatusBadge(title: status.capabilities.availability.badgeTitle, color: status.capabilities.availability.badgeColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !isSettled {
                // What controls charging, in one line (macOS's Charge Limit:
                // what its availability means).
                ControlStatementText(status: status)
            }

            if status.capabilities.isEnforcedByMacOS {
                NativeLimitSummary(status: status)
            }
            // What macOS reports and how to turn it off, whatever the policy
            // says first (an unfinished restore, for example). Not for a
            // backend that controls nothing: turning macOS's limit off would
            // then leave nothing limiting charging.
            if let macOSLimit = status.capabilities.macOSChargeLimit, ControlStatement.offersMacOSLimitGuide(status) {
                MacOSChargeLimitNotice(macOSLimit: macOSLimit, status: status, recheck: recheck, showGuide: showMacOSLimitGuide)
                    .font(.caption)
            }
            PendingSwitchNotice(status: status, select: selectBackend)

            if let decision = status.decision, !isSettled {
                // A backend that accepts no requests carries nothing out:
                // the decision is only what CellKeeper would do, so its
                // reason and notes, which speak of pausing charging, are not
                // shown.
                let isApplied = ControlStatement.isPolicyApplied(status)
                // While the policy defers to macOS's limit, the line and the
                // notice above say all its state and reason would.
                if decision.state != .deferringToMacOS {
                    LabeledContent(isApplied ? "Policy" : "Policy (not applied)", value: decision.state.title(nativeLimit: status.capabilities.isEnforcedByMacOS))
                        .accessibilityElement(children: .combine)
                }
                LabeledContent(isApplied ? "Wants" : "Would want", value: decision.desiredMode.intentTitle(nativeLimit: status.capabilities.isEnforcedByMacOS))
                    .accessibilityElement(children: .combine)
                if decision.state != .deferringToMacOS, isApplied {
                    Text(status.displayedReason ?? decision.reason.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let execution = status.lastExecution {
                    LabeledContent("Last action") {
                        Text(execution.result.title)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
                ForEach(Array((isApplied ? decision.notes : []).enumerated()), id: \.offset) { _, note in
                    Label(note.description, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if status.isBackendFaulted {
                Label(status.capabilities.isEnforcedByMacOS
                      ? "The control backend failed repeatedly. Until the fault is cleared, CellKeeper only gives back your own Charge Limit."
                      : "The control backend failed repeatedly. Only normal charging will be requested.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.criticalText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Who enforces the limit, what macOS reports, and what will be restored.
private struct NativeLimitSummary: View {
    let status: ControllerStatus

    var body: some View {
        let native = status.nativeLimit
        VStack(alignment: .leading, spacing: 4) {
            Label {
                if let deferral = native?.readDeferral {
                    // Not "no limit": macOS clears its active limit on
                    // battery power (note 08, O20).
                    Text(NativeLimitWording.deferralTitle(deferral))
                } else if let reported = native?.reportedLimit {
                    Text("macOS is enforcing its Charge Limit: \(Format.chargeLimit(reported))")
                } else {
                    Text("macOS enforces its own Charge Limit; its current value could not be read.")
                }
            } icon: {
                Image(systemName: "laptopcomputer")
            }
            .font(.callout)
            Group {
                if let deferral = native?.readDeferral {
                    Text(NativeLimitWording.deferralDetail(deferral))
                }
                // Shared with the restore notification.
                if let problem = NativeLimitWording.restoreProblem(status) {
                    Text(problem)
                        .foregroundStyle(.criticalText)
                } else if let owner = native?.ownerLimit, status.isOwnLimitRestoreWaitingForPower {
                    // Nothing was written: the restore waits for a judged
                    // read, on power (D116, D119).
                    Text(NativeLimitWording.restoreWaitingForPower(owner))
                } else if let owner = native?.ownerLimit {
                    Text("Set by CellKeeper. Your own limit, \(Format.chargeLimit(owner)), is restored when CellKeeper stops managing it, quits, or fails.")
                } else {
                    Text("This is your own setting; CellKeeper has not changed it.")
                }
                if let adopted = status.adoptedChange, !status.settings.isManagementEnabled {
                    Text("The limit was changed outside CellKeeper to \(Format.chargeLimit(adopted.limit)), so CellKeeper kept it as your own and turned off Manage charging. Turn it on to let CellKeeper manage the limit again.")
                        .foregroundStyle(.warningText)
                    if adopted.isNoLimit, adopted.previousOwnerLimit != adopted.limit {
                        Text("If that was a temporary full charge rather than your choice, your earlier limit was \(Format.chargeLimit(adopted.previousOwnerLimit)).")
                            .foregroundStyle(.warningText)
                    }
                }
                if native?.needsNoLimitConfirmation == true {
                    Text("macOS reports no limit. If your own limit is 100%, confirm it in Settings › Control before CellKeeper changes anything.")
                        .foregroundStyle(.warningText)
                }
                if let problem = native?.readProblem {
                    Text("Could not read the Charge Limit: \(problem)")
                        .foregroundStyle(.warningText)
                }
                if let owner = native?.ownerLimit, !status.capabilities.availability.acceptsRequests, !status.isOwnLimitRestorePending {
                    Text("CellKeeper cannot change the limit back right now. Set \(Format.chargeLimit(owner)) in System Settings › Battery › Charging.")
                        .foregroundStyle(.criticalText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

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

/// Changes are applied immediately; the controller rate-limits them.
private struct NativeChargeLimitPicker: View {
    let model: AppModel

    var body: some View {
        let steps = model.nativeLimitSteps
        let limit = model.settings.chargeLimit
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Charge limit")
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
                    Text("\(step)")
                        .accessibilityLabel(AccessibilityWording.chargeLimit(step))
                        .tag(Int?.some(step))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.settings.isManagementEnabled)
            .help("macOS enforces this limit and resumes charging once the battery drops more than 5%; a custom resume point is not available with its Charge Limit.")
            if !steps.contains(limit) {
                Text("\(ChargeLimitChoices.notSettableWithMacOSLimit(limit)) Choose one of the values above; until then your own limit stays in effect.")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ManageChargingToggle(model: model)
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
        VStack(alignment: .leading, spacing: 4) {
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
            Text("Resumes charging at \(model.settings.resumeThreshold)%.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The notice above already warns of a restriction that may remain.
            if let status = model.status, let note = ControlStatement.limitNote(for: status, includesOwnRestriction: false) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shown < 50 {
                Text("Limits below 50% leave little charge for unplugged use.")
                    .font(.caption)
                    .foregroundStyle(.warningText)
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
        Toggle("Manage charging", isOn: Binding(
            get: { model.settings.isManagementEnabled },
            set: { newValue in model.updateSettings { $0.isManagementEnabled = newValue } }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        if let error = model.settingsError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FullChargeControl: View {
    let model: AppModel
    let status: ControllerStatus
    /// Opens Settings › Charging, where a full charge is scheduled.
    let openScheduleSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CalibrationLines(model: model, status: status)
            if let override = status.activeOverride {
                HStack {
                    switch override.kind {
                    case .fullCharge:
                        Label(TemporaryFullChargeWording.line(for: override, status: status, lastResult: status.lastExecution?.result.title, now: status.describedAt), systemImage: "arrow.up.to.line")
                            .fixedSize(horizontal: false, vertical: true)
                    case .dischargeToLimit:
                        Label(dischargeText(override), systemImage: "minus.plus.batteryblock")
                            .foregroundStyle(.warningText)
                    }
                    Spacer()
                    Button("Cancel") { model.cancelOverride() }
                        .controlSize(.small)
                        .accessibilityLabel(override.kind == .fullCharge ? "Cancel the temporary full charge" : "Cancel the discharge")
                }
                .font(.caption)
            } else {
                // One predicate enables the button and gives the reason.
                let refusal = FullChargeStart.refusal(settings: model.settings, status: status)
                let help = TemporaryFullChargeWording.buttonHelp(for: status)
                HStack {
                    Button {
                        model.startFullCharge()
                    } label: {
                        Label("Charge to 100% once", systemImage: "arrow.up.to.line")
                    }
                    .disabled(refusal != nil)
                    .help(help)
                    .disabledReasonHint(refusal, help: help)
                    Spacer()
                    if status.fullChargeSchedule == nil {
                        Button("Schedule…") { openScheduleSettings() }
                            .controlSize(.small)
                            .help("Schedule a temporary full charge in Settings › Charging.")
                    }
                }
                if let refusal {
                    DisabledReason(text: refusal)
                }
            }
            ScheduledFullChargeLines(model: model, status: status)
            WeeklyFullChargeLines(model: model, status: status)
        }
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
            VStack(alignment: .leading, spacing: 4) {
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
                    Button("Cancel") { model.cancelCalibration() }
                        .accessibilityLabel("Cancel the calibration")
                }
                .controlSize(.small)
                if let refusal = calibration.refusal {
                    Text(refusal)
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
                Label(FullChargeScheduleWording.armedLine(schedule, wait: status.fullChargeScheduleWait, now: status.describedAt), systemImage: "calendar.badge.clock")
                    .foregroundStyle(status.fullChargeScheduleWait == nil ? Color.primary : Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { model.cancelFullChargeSchedule() }
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

private struct TelemetryDetails: View {
    let snapshot: BatterySnapshot?
    let thermalState: ProcessInfo.ThermalState
    let isLowPowerModeEnabled: Bool

    var body: some View {
        DisclosureGroup("Battery details") {
            if let snapshot {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Cycle count", snapshot.health.cycleCount.map(String.init) ?? Format.unavailable)
                    row("Capacity", Format.capacity(snapshot.health), spoken: Format.Spoken.capacity(snapshot.health))
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
                    row("Mac thermal state", thermalState.title)
                    row("Low Power Mode", isLowPowerModeEnabled ? "On" : "Off")
                }
                .font(.caption)
                .padding(.top, 4)
                Text("Read at \(snapshot.timestamp.formatted(date: .omitted, time: .standard)). Capacity percentage is computed by CellKeeper from full-charge and design capacity, and may differ from the figure macOS shows. The thermal state is macOS's reading for the whole Mac, not the battery's temperature.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Format.unavailable).font(.caption)
            }
        }
    }

    /// One element for VoiceOver per row: the value, named by its label,
    /// with its unit in words (`spoken`) where the screen abbreviates it.
    private func row(_ label: String, _ value: String, spoken: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value).monospacedDigit()
                .accessibilityLabel(label)
                .accessibilityValue(spoken ?? value)
        }
    }
}
