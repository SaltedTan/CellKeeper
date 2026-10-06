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
        Form {
            Section {
                Toggle("Manage charging", isOn: binding(\.isManagementEnabled))
            } footer: {
                Text("When off, Cell Keeper asks for macOS default charging and only shows telemetry.")
            }

            Section("Charge limit") {
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
                if settings.chargeLimit < 50 {
                    Label("Limits below 50% leave little charge for unplugged use.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Discharge to the limit") {
                    Button("Discharge Now…") { isConfirmingDischarge = true }
                        .disabled(!canStartDischarge)
                }
                .confirmationDialog("Discharge to \(settings.chargeLimit)% while plugged in?", isPresented: $isConfirmingDischarge) {
                    Button("Start Discharge") { model.startDischargeToLimit() }
                } message: {
                    if model.status?.capabilities.availability.affectsHardware == true {
                        Text("Cell Keeper will ask the Mac to run from its battery even though it is plugged in, once, until the charge reaches \(settings.chargeLimit)%. It stops at that level, before sleep, if the battery gets warm, or when unplugged.")
                    } else {
                        Text("The current backend only simulates this: Cell Keeper will record a one-time discharge to \(settings.chargeLimit)%, but your Mac's charging will not change.")
                    }
                }
                Text("A one-time session that runs the Mac from its battery while plugged in until the limit is reached. Needs a backend that supports it and a limit of \(ChargingPolicy.dischargeTargetRange.lowerBound)–\(ChargingPolicy.dischargeTargetRange.upperBound)%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isManagementEnabled)

            Section("Temperature protection") {
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
                if model.status?.snapshot?.temperatureCelsius == nil {
                    Label("This Mac does not currently report battery temperature through the interfaces Cell Keeper uses, so this protection cannot trigger.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.isManagementEnabled)

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

private struct ControlSettingsTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Control backend", selection: Binding(get: { model.backendChoice }, set: { model.selectBackend($0) })) {
                    ForEach(ControlBackendChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("No hardware charging-control backend exists in this version. Cell Keeper reads battery telemetry and computes what it would do; the simulated backend records those requests without changing your Mac.")
            }

            if let status = model.status {
                Section("Status") {
                    LabeledContent("Backend", value: status.backend.displayName)
                    LabeledContent("Availability") {
                        StatusBadge(title: status.capabilities.availability.badgeTitle, color: status.capabilities.availability.badgeColor)
                    }
                    Text(status.backend.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Reported mode", value: status.currentMode?.intentTitle ?? "Unknown")
                    LabeledContent("Recent failures", value: "\(status.consecutiveFailures)")
                    if status.isBackendFaulted {
                        Button("Clear fault and retry") { model.resetBackendFault() }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
                Button("Refresh now") { model.refresh() }
            }
            .padding([.horizontal, .bottom])
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cell Keeper \(version)")
                    .font(.title2.weight(.semibold))
                Text("Open-source battery charge management for macOS. Early development: telemetry is real; charging control is simulated.")
                Text("Cell Keeper is an independent open-source project and is not affiliated with Apple, AppHouseKitchen, AlDente, or their respective developers.")
                    .font(.callout)
                Text("Safety: Cell Keeper is experimental software that may eventually interact with hardware-adjacent battery functions. It is provided under the Apache License 2.0 without warranty of any kind. Your Mac's own battery protections always remain in effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
