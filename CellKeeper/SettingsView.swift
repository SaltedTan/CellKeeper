import CellKeeperCore
import CellKeeperKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
            ChargingSettingsTab(model: model)
                .tabItem { Label("Charging", systemImage: "bolt.batteryblock") }
                .tag(SettingsTab.charging)
            ControlSettingsTab(model: model)
                .tabItem { Label("Control", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.control)
            ActivityTab(model: model)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(SettingsTab.activity)
            DiagnosticsTab(model: model)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)
            AppearanceTab(model: model)
                .tabItem { Label("Appearance", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.appearance)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 520, height: 460)
        // Here rather than on the Diagnostics tab, so that a save that fails
        // after the user moved to another tab is still shown.
        .alert("The diagnostics report was not saved", isPresented: Binding(get: { model.diagnosticsSaveFailure != nil }, set: { if !$0 { model.dismissDiagnosticsSaveFailure() } }), presenting: model.diagnosticsSaveFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure)
        }
    }
}

private struct ChargingSettingsTab: View {
    let model: AppModel
    @State private var isConfirmingDischarge = false

    var body: some View {
        let settings = model.settings
        let resumeRange = ChargingSettings.resumeThresholdRange(forChargeLimit: settings.chargeLimit)
        let isNative = model.usesNativeLimit
        Form {
            Section {
                Toggle("Manage charging", isOn: binding(\.isManagementEnabled))
            } footer: {
                Text(isNative
                     ? "When off, CellKeeper gives back your own macOS Charge Limit if it changed it, and only shows telemetry."
                     : "When off, CellKeeper asks for macOS default charging and only shows telemetry.")
                    .footerParagraph()
            }

            Section("Charge limit") {
                if isNative {
                    Picker("Stop charging at", selection: Binding<Int?>(
                        get: { model.nativeLimitSteps.contains(settings.chargeLimit) ? settings.chargeLimit : nil },
                        set: { if let value = $0 { model.setChargeLimit(value) } }
                    )) {
                        ForEach(model.nativeLimitSteps, id: \.self) { step in
                            Text(Format.chargeLimit(step)).tag(Int?.some(step))
                        }
                    }
                    if !model.nativeLimitSteps.contains(settings.chargeLimit) {
                        Label("\(ChargeLimitChoices.notSettableWithMacOSLimit(settings.chargeLimit)) Choose one of the values offered; until then your own limit stays in effect.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.warningText)
                    }
                    // Settings macOS's Charge Limit cannot express are hidden
                    // rather than shown disabled; this says what macOS does instead.
                    Label("macOS enforces this limit and resumes charging once the battery drops more than 5%. A custom resume threshold, temperature protection and discharging are not available with macOS's Charge Limit; your Mac's own battery protections always stay in effect.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Stepper(value: Binding(get: { settings.chargeLimit }, set: { model.setChargeLimit($0) }),
                            in: ChargingSettings.chargeLimitRange) {
                        LabeledContent("Stop charging at", value: settings.chargeLimit >= 100 ? "100% (no limit)" : "\(settings.chargeLimit)%")
                    }
                    .accessibilityValue(AccessibilityWording.chargeLimit(settings.chargeLimit))
                    Stepper(value: binding(\.resumeThreshold), in: resumeRange) {
                        LabeledContent("Resume charging at", value: "\(settings.resumeThreshold)%")
                    }
                    .accessibilityValue(AccessibilityWording.percent(settings.resumeThreshold))
                    Text("After reaching the limit, charging stays paused until the battery falls to the resume threshold. The gap avoids switching charging on and off repeatedly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let status = model.status, let note = ControlStatement.limitNote(for: status) {
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.warningText)
                    }
                }
                if settings.chargeLimit < 50 {
                    Label("Limits below 50% leave little charge for unplugged use.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.warningText)
                }
                if !isNative {
                    // One predicate enables the button and gives the reason.
                    let dischargeRefusal = DischargeStart.refusal(settings: settings, status: model.status)
                    LabeledContent {
                        Button("Discharge Now…") { isConfirmingDischarge = true }
                            .disabled(dischargeRefusal != nil)
                            .disabledReasonHint(dischargeRefusal)
                    } label: {
                        Text("Discharge to the limit")
                        if let dischargeRefusal {
                            DisabledReason(text: dischargeRefusal)
                        }
                    }
                    .confirmationDialog("Discharge to \(settings.chargeLimit)% while plugged in?", isPresented: $isConfirmingDischarge) {
                        Button("Start Discharge") { model.startDischargeToLimit() }
                    } message: {
                        if model.status?.capabilities.availability.affectsHardware == true {
                            Text("CellKeeper will ask the Mac to run from its battery even though it is plugged in, once, until the charge reaches \(settings.chargeLimit)%. It stops at that level, before sleep, if the battery gets warm, or when unplugged.")
                        } else {
                            Text("The current backend only simulates this: CellKeeper will record a one-time discharge to \(settings.chargeLimit)%, but your Mac's charging will not change.")
                        }
                    }
                    Text("A one-time session that runs the Mac from its battery while plugged in until the limit is reached. Needs a backend that supports it and a limit of \(ChargingPolicy.dischargeTargetRange.lowerBound)–\(ChargingPolicy.dischargeTargetRange.upperBound)%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.isManagementEnabled)

            Section("Scheduled full charge") {
                ScheduledFullChargeSection(model: model)
            }

            Section("Weekly full charge") {
                WeeklyFullChargeSection(model: model)
            }

            Section("Calibration") {
                CalibrationSection(model: model)
            }

            if !isNative {
                Section("Temperature protection") {
                    TemperatureProtectionControls(model: model)
                }
                .disabled(!settings.isManagementEnabled)
            }

            // Not tied to Manage charging: a fault or an unconfirmed restore
            // can happen with management off too.
            NotificationSettingsSection(model: model)

            if let error = model.settingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.criticalText)
            }
            if let recovery = model.settingsRecoveryMessage {
                Label(recovery, systemImage: "info.circle")
                    .foregroundStyle(.warningText)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ChargingSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in model.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// Settings › Charging's scheduled full charge: the armed schedule with
/// Cancel, or an editor for a start and an end, with what a schedule does
/// with the backend in charge (`FullChargeScheduleWording`). Editing needs
/// Manage charging on, like "Charge to 100% once"; cancelling never does.
private struct ScheduledFullChargeSection: View {
    let model: AppModel
    @State private var start: Date
    @State private var end: Date

    init(model: AppModel) {
        self.model = model
        let start = Self.defaultStart()
        _start = State(initialValue: start)
        _end = State(initialValue: start.addingTimeInterval(FullChargeSchedule.defaultWindow))
    }

    /// The next whole hour at least an hour from now.
    static func defaultStart(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(2 * 3600)
    }

    var body: some View {
        let status = model.status
        let now = status?.describedAt ?? Date()
        let isManaged = model.settings.isManagementEnabled
        let isCalibrating = status?.calibration.isInProgress == true
        if let schedule = status?.fullChargeSchedule {
            LabeledContent("Scheduled", value: FullChargeScheduleWording.window(schedule, now: now))
            if let wait = status?.fullChargeScheduleWait {
                Label(FullChargeScheduleWording.armedLine(schedule, wait: wait, now: now), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
            }
            Button("Cancel Schedule") { model.cancelFullChargeSchedule() }
        } else {
            Group {
                DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $end, in: start.addingTimeInterval(FullChargeSchedule.minimumWindow)...start.addingTimeInterval(FullChargeSchedule.maximumWindow), displayedComponents: [.date, .hourAndMinute])
                Button("Schedule Full Charge") { model.setFullChargeSchedule(start: start, end: end) }
                    .disabledReasonHint(isCalibrating ? CalibrationWording.inProgress : nil)
                if isCalibrating {
                    DisabledReason(text: CalibrationWording.inProgress)
                }
            }
            .disabled(!isManaged || isCalibrating)
            .onChange(of: start) { _, newStart in
                let earliest = newStart.addingTimeInterval(FullChargeSchedule.minimumWindow)
                let latest = newStart.addingTimeInterval(FullChargeSchedule.maximumWindow)
                end = min(max(end, earliest), latest)
            }
        }
        if let status, let outcome = status.fullChargeScheduleOutcome, let line = FullChargeScheduleWording.outcomeLine(outcome) {
            Label(line, systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = model.scheduleError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.criticalText)
        }
        if let status {
            Text(FullChargeScheduleWording.explanation(for: status, end: status.fullChargeSchedule?.endsAt ?? end, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint = FullChargeScheduleWording.overnightHint(for: status) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Text("One temporary full charge, starting at most \(Int(FullChargeSchedule.maximumLeadTime / 86_400)) days ahead, with an end 1–\(Int(FullChargeSchedule.maximumWindow / 3600)) hours after the start. \(FullChargeScheduleWording.startConditions)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Settings › Charging's weekly full charge: an editor for the days, the
/// start time and the duration, with Save; the one in use with its next
/// start, an occurrence that is due, the latest one handled, and a store
/// that could not keep up, with Remove (`WeeklyFullChargeWording`). Editing
/// needs Manage charging on, like the scheduled full charge; removing never
/// does.
private struct WeeklyFullChargeSection: View {
    let model: AppModel
    /// The start stays an hour and a minute (`WeeklyFullChargeDraft`), never a
    /// moment in the Mac's time zone, so a skipped hour or a time zone change
    /// cannot move it.
    @State private var draft = WeeklyFullChargeDraft()

    var body: some View {
        let status = model.status
        let now = status?.describedAt ?? Date()
        let weekly = status?.weeklyFullCharge
        Group {
            if let weekly {
                LabeledContent("In use", value: WeeklyFullChargeWording.summary(weekly.pattern))
                if let next = status?.weeklyFullChargeNext {
                    Text(WeeklyFullChargeWording.nextLine(next, now: now))
                        .font(.caption)
                    if let note = WeeklyFullChargeWording.skipNote(next, pattern: weekly.pattern, now: now) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let due = status?.weeklyFullChargeDue {
                    Label(WeeklyFullChargeWording.dueLine(due, now: now), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.warningText)
                }
                if let last = WeeklyFullChargeWording.lastLine(weekly.handled, now: now) {
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let problem = status?.weeklyFullChargeStoreProblem {
                Label(WeeklyFullChargeWording.storeProblemLine(problem), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                LabeledContent("Days") {
                    HStack(spacing: 4) {
                        ForEach(WeeklyFullChargeWording.weekdayOrder(), id: \.self) { day in
                            Toggle(WeeklyFullChargeWording.shortName(of: day), isOn: Binding(
                                get: { draft.weekdays.contains(day) },
                                set: { isOn in
                                    if isOn { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) }
                                }
                            ))
                            .toggleStyle(.button)
                            .accessibilityLabel(WeeklyFullChargeWording.name(of: day))
                        }
                    }
                }
                // Shown and read on a fixed day in GMT, so the picker gives
                // back exactly the hour and minute it shows.
                DatePicker("Start", selection: $draft.pickerTime, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, WeeklyFullChargeDraft.pickerTimeZone)
                    .environment(\.calendar, WeeklyFullChargeDraft.pickerCalendar)
                    // Its value is a moment in GMT; say the time it shows.
                    .accessibilityValue(WeeklyFullChargeWording.timeOfDay(hour: draft.hour, minute: draft.minute))
                Stepper(value: $draft.durationHours, in: WeeklyFullChargePattern.durationHoursRange) {
                    LabeledContent("Duration", value: draft.durationHours == 1 ? "1 hour" : "\(draft.durationHours) hours")
                }
                .accessibilityValue(AccessibilityWording.hours(draft.durationHours))
                Button(weekly == nil ? "Save Weekly Full Charge" : "Save Changes") { model.setWeeklyFullCharge(draft.pattern) }
                    .disabled(!draft.pattern.issues.isEmpty || draft.pattern == weekly?.pattern || status?.calibration.isInProgress == true)
                    .help(WeeklyFullChargeWording.saveHelp)
                    .disabledReasonHint(status?.calibration.isInProgress == true ? CalibrationWording.inProgress : nil, help: WeeklyFullChargeWording.saveHelp)
                if status?.calibration.isInProgress == true {
                    DisabledReason(text: "\(CalibrationWording.inProgress) A weekly full charge that falls due meanwhile is skipped; the schedule continues afterwards.")
                }
            }
            .disabled(!model.settings.isManagementEnabled)
            if weekly != nil {
                Button("Remove Weekly Full Charge") { model.removeWeeklyFullCharge() }
                    .help(WeeklyFullChargeWording.removeHelp)
            }
            if let outcome = status?.weeklyFullChargeOutcome, let line = WeeklyFullChargeWording.outcomeLine(outcome, now: now) {
                Label(line, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.weeklyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.criticalText)
            }
            Text(WeeklyFullChargeWording.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(WeeklyFullChargeWording.record)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // The editor shows the pattern in use once it is known (loaded at
        // launch, saved, or removed), and keeps the user's edits otherwise.
        .onChange(of: weekly?.pattern, initial: true) { _, pattern in
            guard let pattern else { return }
            draft = WeeklyFullChargeDraft(pattern)
        }
    }
}

/// Settings › Charging's guided calibration (research note 12 §7): what it
/// does and when 100% applies, the owner's confirmations and the recovery,
/// and Start, enabled by ``CalibrationAdmission`` with the reason shown when
/// it is not; while a session exists, the step, when it ends at the latest,
/// the recovery, Continue for one found at launch, and Cancel; and the last
/// calibration's report. The wording is `CalibrationWording`'s.
private struct CalibrationSection: View {
    let model: AppModel
    @State private var optimizedCharging: OptimizedChargingConfirmation?
    @State private var isCoolRoomConfirmed = false
    @State private var isRecoverySeen = false
    @State private var isMenuOnlyAcknowledged = false
    @State private var isConfirmingStart = false
    @State private var isConfirmingCancel = false
    @State private var isReportExpanded = false

    private var confirmations: CalibrationConfirmations {
        CalibrationConfirmations(optimizedCharging: optimizedCharging, isCoolRoomConfirmed: isCoolRoomConfirmed, isRecoverySeen: isRecoverySeen, isMenuOnlyAcknowledged: isMenuOnlyAcknowledged)
    }

    var body: some View {
        let status = model.status
        let calibration = status?.calibration ?? CalibrationStatus()
        let now = status?.describedAt ?? Date()
        Group {
            if let status, let session = calibration.session {
                running(session, status: status, calibration: calibration, now: now)
            } else {
                start(status: status)
            }
            if let refusal = calibration.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.criticalText)
            }
            if calibration.isEvidenceRetained {
                Label(CalibrationWording.evidenceRetained, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
            }
            if calibration.isEndUnsaved {
                Label(CalibrationWording.endUnsaved, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
            }
            if let last = calibration.last {
                LabeledContent("Last calibration", value: "\(CalibrationWording.clockTime(last.endedAt, now: now, alwaysWithDay: true)), \(last.end.isCompleted ? "finished" : "ended early")")
                    .accessibilityElement(children: .combine)
                DisclosureGroup("Report", isExpanded: $isReportExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(CalibrationWording.reportLines(last, now: now).enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.label) {
                                Text(line.value)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isStaticText)
                        }
                        Text(CalibrationWording.gaugeNote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func running(_ session: CalibrationSession, status: ControllerStatus, calibration: CalibrationStatus, now: Date) -> some View {
        if let line = CalibrationWording.statusLine(for: status) {
            Text(line)
                .fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Step", value: "\(session.step.rawValue) of \(CalibrationStep.allCases.count), \(session.step)")
            .accessibilityElement(children: .combine)
        if let end = calibration.stepEndsAt {
            LabeledContent(session.step == .restAtBottom ? "Plug in again after" : "This step ends at the latest", value: CalibrationWording.clockTime(end, now: now))
                .accessibilityElement(children: .combine)
        }
        if let cap = calibration.capEndsAt {
            LabeledContent("The calibration ends at the latest", value: CalibrationWording.clockTime(cap, now: now, alwaysWithDay: true))
                .accessibilityElement(children: .combine)
        }
        if session.temperatureCheck == .ownerConfirmedCoolRoom {
            Label(CalibrationWording.temperatureUnknown, systemImage: "thermometer.medium")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text(CalibrationWording.recovery(ownerLimit: session.ownerLimit))
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            if calibration.isPaused {
                if calibration.needsRestAnswer {
                    Button("Yes, It Stayed Off and Unplugged") { model.continueCalibration(restAnswer: true) }
                        .help("Continues the calibration and records your answer in its report.")
                    Button("No, Continue Anyway") { model.continueCalibration(restAnswer: false) }
                        .help("Continues the calibration; its report records the rest as not confirmed.")
                } else {
                    Button("Continue Calibration") { model.continueCalibration() }
                        .help("Continues the calibration from its current step. In the rest at 100%, its 2 hours start again.")
                }
            }
            Button("Cancel Calibration…") { isConfirmingCancel = true }
        }
        .confirmationDialog("Cancel the calibration?", isPresented: $isConfirmingCancel) {
            Button("Cancel Calibration", role: .destructive) { model.cancelCalibration() }
        } message: {
            Text("CellKeeper's own limit applies again at once. The report keeps the steps done so far.")
        }
    }

    @ViewBuilder
    private func start(status: ControllerStatus?) -> some View {
        let refusal = model.calibrationRefusal(confirmations)
        let ownerLimit = status?.nativeLimit?.ownerLimit ?? status?.nativeLimit?.reportedLimit
        let isTemperatureReadable = status.map { CalibrationAdmission.isTemperatureReadable(status: $0, now: Date()) } ?? false
        Text(CalibrationWording.explanation)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        Text(CalibrationWording.fullLimitDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Picker("Optimized Battery Charging", selection: $optimizedCharging) {
            Text("Not confirmed yet").tag(OptimizedChargingConfirmation?.none)
            Text("It is off").tag(OptimizedChargingConfirmation?.some(.off))
            Text("It may be on; step 1 may stop at its 6-hour limit").tag(OptimizedChargingConfirmation?.some(.boundAccepted))
        }
        Text("CellKeeper cannot read this setting (System Settings › Battery › ⓘ next to Charging). With it on, macOS may hold the charge at 80%, and step 1 ends the calibration after 6 hours.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !isTemperatureReadable {
            Toggle("The room is between 10 and 35 °C, and my Mac is out of a bag and off soft surfaces", isOn: $isCoolRoomConfirmed)
            Text("CellKeeper cannot read the battery's temperature on this Mac, so it cannot stop the calibration if the battery gets too warm or too cold; the battery's own protections still apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(CalibrationWording.recovery(ownerLimit: ownerLimit))
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        Toggle("I have read how to get my own Charge Limit back", isOn: $isRecoverySeen)
        if !model.isNotifying {
            Toggle("Notifications are off: I will check the menu for CellKeeper's requests", isOn: $isMenuOnlyAcknowledged)
        }
        LabeledContent {
            Button("Start Calibration…") { isConfirmingStart = true }
                .disabled(refusal != nil)
                .disabledReasonHint(refusal)
        } label: {
            Text("Guided calibration")
            if let refusal {
                DisabledReason(text: refusal)
            }
        }
        .confirmationDialog("Start a guided calibration?", isPresented: $isConfirmingStart) {
            Button("Start Calibration") {
                model.startCalibration(confirmations)
                optimizedCharging = nil
                isCoolRoomConfirmed = false
                isRecoverySeen = false
                isMenuOnlyAcknowledged = false
            }
        } message: {
            Text("CellKeeper will set macOS's Charge Limit to 100% now, and over the next one to two days (three at most) ask you to unplug, rest and plug in your Mac. You can cancel it at any time.")
        }
        Text(CalibrationWording.frequency)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TemperatureProtectionControls: View {
    let model: AppModel

    var body: some View {
        let settings = model.settings
        Group {
            Toggle("Pause charging when the battery is warm", isOn: binding(\.temperatureProtection.isEnabled))
            Stepper(value: Binding(
                        get: { settings.temperatureProtection.pauseAtCelsius },
                        set: { pause in model.updateSettings { $0 = $0.withTemperaturePause(pause) } }
                    ),
                    in: ChargingSettings.temperaturePauseRange, step: 1) {
                LabeledContent("Pause at", value: Format.celsius(settings.temperatureProtection.pauseAtCelsius))
            }
            .accessibilityValue(AccessibilityWording.celsius(settings.temperatureProtection.pauseAtCelsius))
            Stepper(value: binding(\.temperatureProtection.resumeAtCelsius),
                    in: ChargingSettings.minimumTemperatureResume...(settings.temperatureProtection.pauseAtCelsius - ChargingSettings.minimumTemperatureHysteresis),
                    step: 1) {
                LabeledContent("Resume at", value: Format.celsius(settings.temperatureProtection.resumeAtCelsius))
            }
            .accessibilityValue(AccessibilityWording.celsius(settings.temperatureProtection.resumeAtCelsius))
            Text("Once paused, charging stays paused for at least \(Int(ChargingPolicy.minimumTemperaturePause / 60)) minutes unless the temperature reading is lost.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.status?.snapshot?.temperatureCelsius == nil {
                Label("This Mac does not currently report battery temperature through the interfaces CellKeeper uses, so this protection cannot trigger.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ChargingSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in model.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// The opt-in to notifications (``NotificationOptIn``): the toggle is on only
/// while macOS shows them, and says why not otherwise; a saved opt-in that
/// macOS blocks can still be withdrawn.
private struct NotificationSettingsSection: View {
    let model: AppModel

    var body: some View {
        let optIn = model.notificationOptIn
        Section {
            Toggle("Send notifications", isOn: Binding(get: { optIn.isToggleOn }, set: { model.setNotificationsEnabled($0) }))
                .disabled(optIn.isRequesting)
            if let explanation = optIn.explanation {
                Label(explanation, systemImage: optIn.offersSystemSettings ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(optIn.offersSystemSettings ? Color.warningText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if optIn.offersSystemSettings || optIn.offersWithdrawal {
                HStack {
                    if optIn.offersSystemSettings {
                        Button("Open Notification Settings") { model.openNotificationSettings() }
                            .help("Opens System Settings › Notifications. CellKeeper changes nothing there.")
                    }
                    if optIn.offersWithdrawal {
                        Button("Turn Off Notifications") { model.setNotificationsEnabled(false) }
                            .help("Saves that you do not want notifications. CellKeeper asks macOS nothing more.")
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(NotificationWording.settingsSummary)
                .footerParagraph()
        }
        .onAppear { model.refreshNotificationPermission() }
    }
}

private struct ControlSettingsTab: View {
    let model: AppModel
    @State private var isConfirmingNativeLimit = false

    var body: some View {
        Form {
            Section {
                Picker("Control backend", selection: Binding(get: { model.backendChoice }, set: { choose($0) })) {
                    ForEach(ControlBackendChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .confirmationDialog("Let CellKeeper change macOS's Charge Limit?", isPresented: $isConfirmingNativeLimit) {
                    Button("Use macOS Charge Limit") { model.selectBackend(.nativeLimit) }
                } message: {
                    Text("CellKeeper will set macOS's own Charge Limit (80–100%) by running your “\(NativeChargeLimitBackend.defaultShortcutName)” shortcut, and macOS will enforce it. Before its first change CellKeeper records your current limit, and it restores exactly that value when you turn off management, switch backend, quit, or if anything fails. If you change the limit yourself in System Settings, CellKeeper keeps your new value as your own and turns off Manage charging. This backend is experimental.")
                }
            } footer: {
                Text("Simulated records what CellKeeper would do without changing your Mac. Read-only performs no control. macOS Charge Limit lets macOS enforce the limit you choose here; it is the only real control in this version. Simulated helper tries CellKeeper's own charge control at any limit from 20 to 100%, simulated: nothing on your Mac changes. Real control needs a signed helper and a verified mechanism (roadmap milestone 4).")
                    .footerParagraph()
            }

            if let status = model.status {
                Section("Status") {
                    LabeledContent("Backend") {
                        HStack(spacing: 6) {
                            if status.backend.displayName != status.capabilities.availability.badgeTitle {
                                Text(status.backend.displayName)
                            }
                            StatusBadge(title: status.capabilities.availability.badgeTitle, color: status.capabilities.availability.badgeColor)
                        }
                    }
                    ControlStatementText(status: status)
                    // Only for a backend that can act on it: one that controls
                    // nothing has nothing to defer.
                    if let macOSLimit = status.capabilities.macOSChargeLimit, !status.capabilities.isEnforcedByMacOS, status.capabilities.availability.acceptsRequests {
                        MacOSChargeLimitNotice(macOSLimit: macOSLimit, status: status, recheck: { model.recheckBackend() })
                    }
                    if ControlStatement.offersMacOSLimitGuide(status) {
                        DisclosureGroup(MacOSChargeLimitGuide.title, isExpanded: Binding(get: { model.isMacOSLimitGuideExpanded }, set: { model.isMacOSLimitGuideExpanded = $0 })) {
                            MacOSChargeLimitGuideView(isSimulated: status.isControlSimulated, openBatterySettings: { model.openBatterySettings() }, recheck: { model.recheckBackend() })
                                .padding(.top, 4)
                        }
                    }
                    if status.isBackendFaulted {
                        Label(faultExplanation(for: status),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.criticalText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Clear fault and retry") { model.resetBackendFault() }
                            .help(faultResetHelp(for: status))
                    }
                    PendingSwitchNotice(status: status, select: { model.selectBackend($0) })
                }
            }

            if isNativeChosenOrActive {
                NativeLimitSetupSection(model: model)
            }

            if let status = model.status {
                ControlDetailsSection(status: status, isNative: status.capabilities.isEnforcedByMacOS)
            }
        }
        .formStyle(.grouped)
    }

    /// The native backend is chosen or in charge: its setup is shown, also
    /// while a switch to it is pending. Text about the backend in charge
    /// follows `status.capabilities` instead.
    private var isNativeChosenOrActive: Bool {
        model.backendChoice == .nativeLimit || model.status?.capabilities.isEnforcedByMacOS == true
    }

    /// How clearing the fault affects charging, for the backend in use.
    private enum FaultReset {
        case nativeLimit
        /// The Simulated helper: its reset changes only simulated controls.
        case simulatedHelper
        /// A helper that controls hardware (not available yet): its reset
        /// restores macOS's default charging.
        case helper
        case other
    }

    /// Follows the backend in charge, which the reset acts on, not the one
    /// chosen in the picker (a switch may be pending).
    private func faultReset(for status: ControllerStatus) -> FaultReset {
        if status.capabilities.isEnforcedByMacOS { return .nativeLimit }
        guard ControlBackendChoice(backendIdentifier: status.backend.identifier) == .simulatedHelper else { return .other }
        return status.capabilities.availability.affectsHardware ? .helper : .simulatedHelper
    }

    private func faultExplanation(for status: ControllerStatus) -> String {
        switch faultReset(for: status) {
        case .nativeLimit:
            "The control backend failed repeatedly. Until you clear the fault, CellKeeper only gives back your own Charge Limit."
        case .simulatedHelper:
            "The simulated helper failed, found its controls changed outside CellKeeper, or is waiting for you to acknowledge a problem. Until you clear the fault, only normal charging is requested. Clearing it also resets the simulated helper's controls if it is waiting for that; your Mac's charging is not changed."
        case .helper:
            "The helper failed, found charging changed outside CellKeeper, or is waiting for you to acknowledge a problem. Until you clear the fault, only normal charging is requested. Clearing it also has the helper restore macOS's default charging if it is waiting for that, which can undo another tool's change."
        case .other:
            "The control backend failed repeatedly. Until you clear the fault, only normal charging will be requested."
        }
    }

    private func faultResetHelp(for status: ControllerStatus) -> String {
        switch faultReset(for: status) {
        case .simulatedHelper:
            "Clears the fault and resets the simulated helper's controls if it is waiting for that. Your Mac's charging is not changed."
        case .helper:
            "Clears the fault. If the helper is waiting for it, this also restores macOS's default charging, which can undo another tool's change."
        case .nativeLimit, .other:
            "Clears the fault and lets CellKeeper manage charging again."
        }
    }

    private func choose(_ choice: ControlBackendChoice) {
        if choice == .nativeLimit, model.backendChoice != .nativeLimit {
            isConfirmingNativeLimit = true
        } else {
            model.selectBackend(choice)
        }
    }
}

/// How to create the shortcut, and what macOS reports about its limit.
private struct NativeLimitSetupSection: View {
    let model: AppModel
    @State private var isConfirmingNoLimit = false
    @State private var isConfirmingDiscard = false
    /// Nil until the user opens or closes the setup steps themselves.
    @State private var isSetupExpanded: Bool?

    var body: some View {
        let native = model.status?.nativeLimit
        Section("macOS Charge Limit") {
            DisclosureGroup(isExpanded: setupExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Requires macOS Tahoe 26.4 or later on a Mac with Apple silicon, and a shortcut you create once:")
                    Text("1. In Shortcuts, create a shortcut named exactly “\(NativeChargeLimitBackend.defaultShortcutName)”.")
                    Text("2. Search the actions for “charge limit” and add the one that reads “Set charge limit to …”. Set its value to Shortcut Input, so CellKeeper can pass 80–100.")
                    Text("3. Shortcuts then adds “Receive … from Nowhere” at the top; leave it as it is. Leave “Set Until Tomorrow” off.")
                    Text("CellKeeper runs it with the shortcuts command-line tool, then reads the setting back to confirm the change.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            } label: {
                if native?.isShortcutFound == true {
                    Label("Shortcut “\(NativeChargeLimitBackend.defaultShortcutName)” found", systemImage: "checkmark.circle")
                } else {
                    Text("Shortcut setup")
                }
            }
            LabeledContent("Charge Limit reported by macOS", value: native?.reportedLimit.map(Format.chargeLimit) ?? "Unknown")
            if let problem = native?.readProblem {
                Label("Could not read the Charge Limit: \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.warningText)
            }
            LabeledContent("Your own limit") {
                if native?.isRecordUnreadable == true {
                    Text("Unknown: the record cannot be read")
                        .foregroundStyle(.criticalText)
                } else if let owner = native?.ownerLimit, let status = model.status, status.isOwnLimitRestorePending {
                    Text(status.capabilities.availability.acceptsRequests
                         ? "\(Format.chargeLimit(owner)), recorded; restoring it is not confirmed yet, CellKeeper keeps trying"
                         : "\(Format.chargeLimit(owner)), recorded; CellKeeper cannot restore it right now, set it in System Settings")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.criticalText)
                } else if let owner = native?.ownerLimit {
                    Text("\(Format.chargeLimit(owner)), recorded; restored when CellKeeper stops managing it")
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("In effect; CellKeeper has not changed it")
                }
            }
            if native?.needsNoLimitConfirmation == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS reports no Charge Limit. That usually means your limit is 100%, but it can also mean a temporary full charge is in progress. CellKeeper records your limit only once it knows it.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("My Charge Limit is 100%") { isConfirmingNoLimit = true }
                }
                .confirmationDialog("Is your own Charge Limit 100%?", isPresented: $isConfirmingNoLimit) {
                    Button("Yes, my limit is 100%") { model.confirmNoLimitIsOwnerLimit() }
                } message: {
                    Text("Check System Settings › Battery › ⓘ next to Charging. CellKeeper will restore 100% when it stops managing the limit.")
                }
            }
            if native?.isRecordUnreadable == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CellKeeper's record of your own limit cannot be read, so it will neither change nor restore the limit. Set your limit in System Settings › Battery › Charging first, then discard the record.")
                        .font(.caption)
                        .foregroundStyle(.criticalText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("I've Set My Limit — Discard the Record…") { isConfirmingDiscard = true }
                }
                .confirmationDialog("Discard CellKeeper's record of your Charge Limit?", isPresented: $isConfirmingDiscard) {
                    Button("Discard Record", role: .destructive) { model.discardUnreadableRecord() }
                } message: {
                    Text("Only do this after setting your own limit in System Settings. CellKeeper will then treat the current limit as yours.")
                }
            }
            Text("You can always set the limit yourself in System Settings › Battery › Charging.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Check again") { model.recheckBackend() }
        }
    }

    /// The setup steps start open until CellKeeper has found the shortcut.
    private var setupExpanded: Binding<Bool> {
        Binding(
            get: { isSetupExpanded ?? (model.status?.nativeLimit?.isShortcutFound != true) },
            set: { isSetupExpanded = $0 }
        )
    }
}

/// What CellKeeper reads from the backend, for diagnosis. Collapsed by
/// default; nothing here needs the user to act.
private struct ControlDetailsSection: View {
    let status: ControllerStatus
    let isNative: Bool
    @State private var isExpanded = false

    var body: some View {
        Section {
            DisclosureGroup("Details", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Reported mode", value: status.currentMode?.intentTitle(nativeLimit: status.capabilities.isEnforcedByMacOS) ?? "Unknown")
                    LabeledContent("Recent failures", value: "\(status.consecutiveFailures)")
                    if let readAt = status.nativeLimit?.readAt {
                        LabeledContent("Charge Limit read at", value: readAt.formatted(date: .omitted, time: .standard))
                    }
                    Divider()
                    Group {
                        Text(status.backend.summary)
                        if isNative {
                            Text("CellKeeper reads the limit with “pmset -g battlimit”, an undocumented, read-only report that a macOS update could change. If CellKeeper cannot read or recognise it, it sets no new limit; it still tries to give back your own recorded limit, and reports that as unconfirmed until it reads it back.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct ActivityTab: View {
    let model: AppModel

    var body: some View {
        let events = (model.status?.events ?? []).reversed()
        VStack(alignment: .leading) {
            if events.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle")
            } else {
                List(Array(events)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.kind.title)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    // One element per event: kind, time and message. The
                    // trait keeps it a text: combined selectable text would
                    // otherwise have no role.
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
                }
            }
            HStack {
                Text("Also written to the unified log (subsystem \(CellKeeperLog.subsystem)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh now") { model.refresh() }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

/// What CellKeeper sees and does, in the diagnostics report's sections
/// (``DiagnosticsReport/sections(status:environment:powerFlow:)``), in
/// plain words: without the identifiers and the activity log the report
/// adds. It shows the latest status and starts no evaluation of its own.
private struct DiagnosticsTab: View {
    let model: AppModel
    @State private var isCopied = false
    @State private var settingsWindow = HostingWindow()

    var body: some View {
        VStack(alignment: .leading) {
            if let status = model.status {
                let sections = DiagnosticsReport.sections(status: status, environment: model.diagnosticsEnvironment, powerFlow: model.powerFlowDiagnostics)
                Form {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        if let title = section.title {
                            Section {
                                rows(of: section)
                            } header: {
                                Text(title)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        } else {
                            Section {
                                rows(of: section)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No status yet", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let evaluated = model.status?.lastEvaluation {
                    Text("As of the last evaluation, at \(Format.moment(evaluated)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(isCopied ? "Copied" : "Copy Diagnostics") { copyDiagnostics() }
                        .disabled(model.status == nil)
                        .help("Copies a plain-text report of what CellKeeper sees and does, for a bug report. It contains no serial numbers or other identifiers.")
                    Button("Save Diagnostics…") { model.saveDiagnosticsReport(attachingTo: settingsWindow.window) }
                        .disabled(model.status == nil || model.isSavingDiagnostics)
                        .help("Saves the same report as a text file where you choose.")
                    Spacer()
                }
            }
            .padding([.horizontal, .bottom])
        }
        .background(HostingWindowReader(hostingWindow: settingsWindow))
    }

    /// Each row is one accessibility element made of its label and its
    /// value; the value can be selected and copied. VoiceOver reads units
    /// in words ("Voltage, 12,427 millivolts") where the value shows a
    /// symbol ("12427 mV"). The trait keeps the element a text: combined
    /// selectable text would otherwise have no role (AXUnknown).
    private func rows(of section: DiagnosticsSection) -> some View {
        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
            let plain = row.value.plainText(formattingTime: Format.moment)
            LabeledContent(row.label) {
                Text(plain)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    // Combined into the row's element, the label takes the
                    // text's place; set to the text itself, it changes
                    // nothing (verified).
                    .accessibilityLabel(row.value.spokenText(formattingTime: Format.moment) ?? plain)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private func copyDiagnostics() {
        guard let report = model.diagnosticsReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        // The button's title says "Copied", which VoiceOver does not read
        // out by itself.
        Announcement.post(AccessibilityWording.diagnosticsCopied, priority: .medium)
        isCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            isCopied = false
        }
    }
}

/// Settings › Appearance: how the menu bar icon looks (``MenuBarIcon``,
/// D113). Nothing here changes charging, and nothing here needs Manage
/// charging.
private struct AppearanceTab: View {
    let model: AppModel

    var body: some View {
        let preferences = model.menuBarIconPreferences
        let percentageReason = preferences.style == .battery ? nil : "The percentage shows only with the Battery icon."
        Form {
            Section {
                Picker("Menu bar icon", selection: binding(\.style)) {
                    Text("Battery").tag(MenuBarIconStyle.battery)
                    Text("CellKeeper status").tag(MenuBarIconStyle.status)
                }
                .pickerStyle(.radioGroup)
                Toggle("Show percentage", isOn: binding(\.showsPercentage))
                    .disabled(percentageReason != nil)
                    .disabledReasonHint(percentageReason)
                if let percentageReason {
                    DisabledReason(text: percentageReason)
                }
                Text("To see only one battery in the menu bar, you can hide macOS's own battery icon in System Settings › Menu Bar › Battery (Control Center › Battery on older macOS versions). CellKeeper never changes that setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Battery shows the charge as a fill, with a bolt while the battery charges and a plug while your Mac is on power and not charging. Beside it, a warning symbol shows a control fault or a fail-safe, and a thermometer a pause for the battery's temperature. CellKeeper status shows CellKeeper's state as one symbol, as before. Until CellKeeper has read the battery's charge, or on a Mac without a battery, both show the status symbol.")
                    .footerParagraph()
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MenuBarIconPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.menuBarIconPreferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = model.menuBarIconPreferences
                preferences[keyPath: keyPath] = newValue
                model.setMenuBarIconPreferences(preferences)
            }
        )
    }
}

private struct AboutTab: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CellKeeper \(version)")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Open-source battery charge management for macOS. Early development: telemetry is real; charging control is simulated unless you choose macOS Charge Limit, which lets macOS enforce your limit.")
                Text("CellKeeper is an independent open-source project and is not affiliated with Apple, AppHouseKitchen, AlDente, or their respective developers.")
                    .font(.callout)
                Text("Safety: CellKeeper is experimental software. With the macOS Charge Limit backend it changes macOS's own Charge Limit; it never writes to hardware itself. It is provided under the Apache License 2.0 without warranty of any kind. Your Mac's own battery protections always remain in effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The window a view is in, read when it is needed: the Settings window for
/// the save panel's sheet. `NSApp.keyWindow` can be another window, such as
/// the menu's.
@MainActor
private final class HostingWindow {
    weak var view: NSView?
    var window: NSWindow? { view?.window }
}

/// An empty AppKit view behind the content, through which ``HostingWindow``
/// finds the window. It changes no SwiftUI state.
private struct HostingWindowReader: NSViewRepresentable {
    let hostingWindow: HostingWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        hostingWindow.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        hostingWindow.view = view
    }
}

private extension View {
    /// Grouped forms on macOS align section footers to the trailing edge,
    /// which suits buttons, not paragraphs.
    func footerParagraph() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
