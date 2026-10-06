import CellKeeperCore
import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = model.status {
                BatteryHeader(snapshot: status.snapshot, telemetryError: status.telemetryError)
                Divider()
                ControlSummary(status: status)
                Divider()
                ChargeLimitControl(model: model)
                FullChargeControl(model: model, status: status)
                Divider()
                TelemetryDetails(snapshot: status.snapshot)
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
                Spacer()
                Button("Quit Cell Keeper") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct BatteryHeader: View {
    let snapshot: BatterySnapshot?
    let telemetryError: String?

    var body: some View {
        if let snapshot, snapshot.isBatteryPresent {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(snapshot.chargePercent))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Label(snapshot.powerSource.title, systemImage: snapshot.isOnExternalPower ? "powerplug" : "battery.100percent")
                    Text(snapshot.chargingStatus.title)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if snapshot.chargingStatus == .notCharging {
                // macOS does not report why charging is paused.
                Text("macOS reports charging as paused. The cause (for example Charge Limit, Optimized Battery Charging, or another app) is not reported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let snapshot, !snapshot.isBatteryPresent {
            Label("No battery detected on this Mac.", systemImage: "batteryblock.slash")
        } else {
            Label(telemetryError ?? "Battery telemetry unavailable.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

private struct ControlSummary: View {
    let status: ControllerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Charging control")
                    .font(.headline)
                Spacer()
                StatusBadge(title: status.capabilities.availability.badgeTitle, color: status.capabilities.availability.badgeColor)
            }
            Text(status.capabilities.availability.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let decision = status.decision {
                LabeledContent("Policy", value: decision.state.title)
                LabeledContent("Wants", value: decision.desiredMode.intentTitle)
                Text(decision.reason.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let execution = status.lastExecution {
                    LabeledContent("Last action") {
                        Text(execution.result.title)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                }
                ForEach(Array(decision.notes.enumerated()), id: \.offset) { _, note in
                    Label(note.description, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if status.isBackendFaulted {
                Label("The control backend failed repeatedly. Only normal charging will be requested.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Charge-limit slider. Changes are applied when the drag ends, so dragging
/// never produces a burst of control requests.
private struct ChargeLimitControl: View {
    let model: AppModel
    @State private var draftLimit: Double?

    var body: some View {
        let committed = Double(model.settings.chargeLimit)
        let shown = Int(draftLimit ?? committed)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Charge limit")
                    .font(.headline)
                Spacer()
                Text(shown >= 100 ? "No limit" : "\(shown)%")
                    .monospacedDigit()
            }
            Slider(
                value: Binding(get: { draftLimit ?? committed }, set: { draftLimit = $0.rounded() }),
                in: Double(ChargingSettings.chargeLimitRange.lowerBound)...Double(ChargingSettings.chargeLimitRange.upperBound)
            ) {
                Text("Charge limit")
            } onEditingChanged: { editing in
                if !editing, let draftLimit {
                    model.setChargeLimit(Int(draftLimit))
                    self.draftLimit = nil
                }
            }
            .labelsHidden()
            .disabled(!model.settings.isManagementEnabled)
            Text("Resumes charging at \(model.settings.resumeThreshold)%.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if shown < 50 {
                Text("Limits below 50% leave little charge for unplugged use.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Manage charging", isOn: Binding(
                get: { model.settings.isManagementEnabled },
                set: { newValue in model.updateSettings { $0.isManagementEnabled = newValue } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

private struct FullChargeControl: View {
    let model: AppModel
    let status: ControllerStatus

    var body: some View {
        if let override = status.activeOverride {
            HStack {
                switch override.kind {
                case .fullCharge:
                    Label("Charging to 100% until full, unplugged, or \(override.expiresAt.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.up.to.line")
                case .dischargeToLimit:
                    let target = override.targetPercent ?? model.settings.chargeLimit
                    let prefix = status.capabilities.availability.affectsHardware ? "Discharging" : "Simulating a discharge"
                    Label("\(prefix) to \(target)% while plugged in. Stops at the target, on sleep, or when unplugged.", systemImage: "minus.plus.batteryblock")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { model.cancelOverride() }
                    .controlSize(.small)
            }
            .font(.caption)
        } else {
            Button {
                model.startFullCharge()
            } label: {
                Label("Charge to 100% once", systemImage: "arrow.up.to.line")
            }
            .disabled(!model.settings.isManagementEnabled || model.settings.chargeLimit >= 100 || status.snapshot?.isOnExternalPower != true)
            .help("Charges once to 100%, then returns to the limit. Ends when full, when unplugged, or after 12 hours.")
        }
    }
}

private struct TelemetryDetails: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        DisclosureGroup("Battery details") {
            if let snapshot {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Cycle count", snapshot.health.cycleCount.map(String.init) ?? Format.unavailable)
                    row("Capacity", Format.capacity(snapshot.health))
                    if let condition = snapshot.health.condition {
                        row("Condition", condition)
                    }
                    row("Temperature", Format.celsius(snapshot.temperatureCelsius))
                    row("Voltage", Format.volts(fromMillivolts: snapshot.voltageMillivolts))
                    row("Current", Format.milliamps(snapshot.amperageMilliamps))
                    if let watts = snapshot.adapterWatts {
                        row("Adapter", "\(watts) W")
                    }
                    if let toEmpty = Format.minutes(snapshot.timeToEmptyMinutes) {
                        row("Time to empty", toEmpty)
                    }
                    if let toFull = Format.minutes(snapshot.timeToFullMinutes) {
                        row("Time to full", toFull)
                    }
                }
                .font(.caption)
                .padding(.top, 4)
                Text("Read at \(snapshot.timestamp.formatted(date: .omitted, time: .standard)). Capacity percentage is computed by Cell Keeper from full-charge and design capacity, and may differ from the figure macOS shows.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Format.unavailable).font(.caption)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
