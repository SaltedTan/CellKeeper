import CellKeeperCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ChargingSettingsTab(model: model)
                .tabItem { Label("Charging", systemImage: "bolt.batteryblock") }
            ControlSettingsTab(model: model)
                .tabItem { Label("Control", systemImage: "wrench.and.screwdriver") }
            ActivityTab(model: model)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 460)
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
                        Label("\(settings.chargeLimit)% cannot be set with macOS's Charge Limit. Choose one of the values offered; until then your own limit stays in effect.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
                    Stepper(value: binding(\.resumeThreshold), in: resumeRange) {
                        LabeledContent("Resume charging at", value: "\(settings.resumeThreshold)%")
                    }
                    Text("After reaching the limit, charging stays paused until the battery falls to the resume threshold. The gap avoids switching charging on and off repeatedly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.chargeLimit < 50 {
                    Label("Limits below 50% leave little charge for unplugged use.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !isNative {
                    LabeledContent("Discharge to the limit") {
                        Button("Discharge Now…") { isConfirmingDischarge = true }
                            .disabled(!canStartDischarge)
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

            if !isNative {
                Section("Temperature protection") {
                    TemperatureProtectionControls(model: model)
                }
                .disabled(!settings.isManagementEnabled)
            }

            if let error = model.settingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let recovery = model.settingsRecoveryMessage {
                Label(recovery, systemImage: "info.circle")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    private var canStartDischarge: Bool {
        guard let status = model.status, let snapshot = status.snapshot, let percent = snapshot.chargePercent else { return false }
        return model.settings.isManagementEnabled
            && status.activeOverride == nil
            && snapshot.isOnExternalPower
            && percent > model.settings.chargeLimit
            && ChargingPolicy.dischargeTargetRange.contains(model.settings.chargeLimit)
            && status.capabilities.supports(.forceDischarge)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ChargingSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in model.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
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
            Stepper(value: binding(\.temperatureProtection.resumeAtCelsius),
                    in: ChargingSettings.minimumTemperatureResume...(settings.temperatureProtection.pauseAtCelsius - ChargingSettings.minimumTemperatureHysteresis),
                    step: 1) {
                LabeledContent("Resume at", value: Format.celsius(settings.temperatureProtection.resumeAtCelsius))
            }
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
                    Text(status.capabilities.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.isBackendFaulted {
                        Label(faultExplanation(for: status),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Clear fault and retry") { model.resetBackendFault() }
                            .help(faultResetHelp(for: status))
                    }
                    PendingSwitchNotice(status: status, select: { model.selectBackend($0) })
                }
            }

            if isNative {
                NativeLimitSetupSection(model: model)
            }

            if let status = model.status {
                ControlDetailsSection(status: status, isNative: isNative)
            }
        }
        .formStyle(.grouped)
    }

    private var isNative: Bool {
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

    private func faultReset(for status: ControllerStatus) -> FaultReset {
        if isNative { return .nativeLimit }
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
                    .foregroundStyle(.orange)
            }
            LabeledContent("Your own limit") {
                if native?.isRecordUnreadable == true {
                    Text("Unknown: the record cannot be read")
                        .foregroundStyle(.red)
                } else if let owner = native?.ownerLimit, let status = model.status, status.isOwnLimitRestorePending {
                    Text(status.capabilities.availability.acceptsRequests
                         ? "\(Format.chargeLimit(owner)), recorded; restoring it is not confirmed yet, CellKeeper keeps trying"
                         : "\(Format.chargeLimit(owner)), recorded; CellKeeper cannot restore it right now, set it in System Settings")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.red)
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
                        .foregroundStyle(.red)
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
    @State private var isCopied = false

    var body: some View {
        let events = (model.status?.events ?? []).reversed()
        VStack(alignment: .leading) {
            if events.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle")
            } else {
                List(Array(events)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.kind.rawValue.capitalized)
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
                }
            }
            HStack {
                Text("Also written to the unified log (subsystem \(CellKeeperLog.subsystem)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isCopied ? "Copied" : "Copy Diagnostics") { copyDiagnostics() }
                    .disabled(model.status == nil)
                    .help("Copies a plain-text report of what CellKeeper sees and does, for a bug report. It contains no serial numbers or other identifiers.")
                Button("Refresh now") { model.refresh() }
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func copyDiagnostics() {
        guard let report = model.diagnosticsReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        isCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            isCopied = false
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CellKeeper \(version)")
                    .font(.title2.weight(.semibold))
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
