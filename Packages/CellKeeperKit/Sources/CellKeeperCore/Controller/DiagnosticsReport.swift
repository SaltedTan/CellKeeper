import Foundation

/// Facts about the app and the Mac that a diagnostics report includes. None
/// of them identifies a particular Mac or person.
public struct DiagnosticsEnvironment: Sendable, Equatable {
    /// For example "0.1.0 (1)".
    public var appVersion: String
    /// For example "Version 27.0.1 (Build 26A434)".
    public var systemVersion: String
    /// The model identifier, for example "Mac16,1". Never a serial number.
    public var modelIdentifier: String?

    public init(appVersion: String, systemVersion: String, modelIdentifier: String?) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.modelIdentifier = modelIdentifier
    }
}

/// A plain-text report of what CellKeeper sees and does, for bug reports.
///
/// It is built only from a ``ControllerStatus`` and a
/// ``DiagnosticsEnvironment``. Those carry no serial numbers, power source
/// IDs or other device identifiers, because telemetry is read through an
/// allowlist and the activity log never records them. Error messages can
/// contain file paths, which name the macOS account under `/Users`; the
/// report replaces that name.
public enum DiagnosticsReport {
    public static func text(status: ControllerStatus, environment: DiagnosticsEnvironment, generatedAt: Date) -> String {
        var lines: [String] = []
        func section(_ title: String) {
            lines.append("")
            lines.append("== \(title)")
        }
        func field(_ name: String, _ value: String) {
            lines.append("\(name): \(value)")
        }

        lines.append("CellKeeper diagnostics")
        field("Generated", timestamp(generatedAt))
        field("App", environment.appVersion)
        field("macOS", environment.systemVersion)
        field("Model", environment.modelIdentifier ?? "unknown")

        section("Control")
        let capabilities = status.capabilities
        field("Backend", "\(status.backend.displayName) (\(status.backend.identifier))")
        field("Availability", describe(capabilities.availability))
        if capabilities.isEnforcedByMacOS {
            field("Style", "macOS Charge Limit, steps \(capabilities.nativeLimitSteps.map(String.init).joined(separator: ", "))")
        } else {
            field("Style", "switches charging, modes \(capabilities.supportedModes.map(\.description).sorted().joined(separator: ", "))")
        }
        field("Reported mode", status.currentMode.map(\.description) ?? "unknown")
        if let macOSLimit = capabilities.macOSChargeLimit {
            // A backend that switches charging itself restricts nothing while
            // macOS's own Charge Limit is on or unreadable.
            field("macOS Charge Limit", "\(macOSLimit.reportedLimit.map { "\($0)%" } ?? "unreadable"), read \(timestamp(macOSLimit.readAt))\(macOSLimit.isLimiting ? "; CellKeeper restricts nothing while it is on" : "")")
            if let problem = macOSLimit.readProblem {
                field("macOS Charge Limit read problem", problem)
            }
        }
        field("Pending switch", status.pendingBackend.map(\.displayName) ?? "none")
        field("Consecutive failures", "\(status.consecutiveFailures)\(status.isBackendFaulted ? " (faulted)" : "")")
        if let refusal = status.managementRefusal {
            field("Management refused", refusal)
        }

        section("Settings")
        let settings = status.settings
        field("Manage charging", settings.isManagementEnabled ? "on" : "off")
        field("Charge limit", "\(settings.chargeLimit)%")
        field("Resume threshold", "\(settings.resumeThreshold)%")
        let protection = settings.temperatureProtection
        field("Temperature protection", "\(protection.isEnabled ? "on" : "off") (pause \(protection.pauseAtCelsius.formatted()) °C, resume \(protection.resumeAtCelsius.formatted()) °C)")

        section("Battery")
        if let snapshot = status.snapshot {
            appendBattery(snapshot, to: &lines)
        } else {
            field("Telemetry", "unavailable\(status.telemetryError.map { ": \($0)" } ?? "")")
        }

        section("Decision")
        if let decision = status.decision {
            field("State", decision.state.rawValue)
            field("Wants", decision.desiredMode.description)
            field("Action", ChargeController.describe(decision.action, nativeLimit: capabilities.isEnforcedByMacOS))
            // As in the activity log: with macOS's Charge Limit, what
            // CellKeeper restores is the user's own limit.
            let restoreTarget = capabilities.isEnforcedByMacOS
                ? "your own macOS Charge Limit" + (status.nativeLimit?.ownerLimit.map { " of \($0)%" } ?? "")
                : "normal charging"
            field("Reason", decision.reason.description(restoring: restoreTarget))
            for note in decision.notes {
                field("Note", note.description)
            }
        } else {
            field("State", "not evaluated yet")
        }
        if let override = status.activeOverride {
            let target = override.targetPercent.map { " to \($0)%" } ?? ""
            field("Override", "\(ChargeController.describe(override.kind))\(target), started \(timestamp(override.startedAt)), expires \(timestamp(override.expiresAt))")
        }
        if let execution = status.lastExecution {
            field("Last action", "\(timestamp(execution.date)) \(ChargeController.describe(execution.action, nativeLimit: capabilities.isEnforcedByMacOS)): \(describe(execution.result))")
        }
        if let evaluated = status.lastEvaluation {
            field("Last evaluation", timestamp(evaluated))
        }

        if let native = status.nativeLimit {
            section("macOS Charge Limit")
            field("Reported by macOS", native.reportedLimit.map { "\($0)%" } ?? "unknown")
            if let readAt = native.readAt {
                field("Read at", timestamp(readAt))
            }
            if let problem = native.readProblem {
                field("Read problem", problem)
            }
            if native.isRecordUnreadable {
                field("Own limit", "record unreadable")
            } else {
                field("Own limit", native.ownerLimit.map { "\($0)% recorded" } ?? "not recorded (in effect)")
            }
            if let target = native.target {
                field("CellKeeper's limit", "\(target)%")
            }
            field("Shortcut found", native.isShortcutFound.map { $0 ? "yes" : "no" } ?? "not checked")
            var flags: [String] = []
            if native.needsNoLimitConfirmation { flags.append("needs no-limit confirmation") }
            if native.isRestoreUnfinished { flags.append("restore unfinished") }
            if native.isAdoptionUnsaved { flags.append("adoption marker unsaved") }
            field("Flags", flags.isEmpty ? "none" : flags.joined(separator: ", "))
            if let adopted = status.adoptedChange {
                field("Kept outside change", "\(adopted.limit)%\(adopted.isNoLimit ? " (no limit)" : "") at \(timestamp(adopted.date)); CellKeeper had set \(adopted.expectedLimit)%, own limit was \(adopted.previousOwnerLimit)%\(adopted.isFromEarlierSession ? ", earlier session" : "")")
            }
        }

        section("Activity (oldest first)")
        if status.events.isEmpty {
            lines.append("none")
        }
        for event in status.events {
            lines.append("\(timestamp(event.date)) [\(event.kind.rawValue)] \(event.message)")
        }
        return redactingAccountNames(lines.joined(separator: "\n") + "\n")
    }

    /// Replaces the account name in paths such as
    /// `/Users/<name>/Library/Containers/…`, which Foundation's file errors
    /// include.
    static func redactingAccountNames(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s"'“”‘’,;:()\[\]{}<>]+"#, with: "/Users/<user>", options: .regularExpression)
    }

    private static func appendBattery(_ snapshot: BatterySnapshot, to lines: inout [String]) {
        func field(_ name: String, _ value: String) {
            lines.append("\(name): \(value)")
        }
        func optional<T>(_ value: T?, _ format: (T) -> String) -> String {
            value.map(format) ?? "not available"
        }
        field("Read at", timestamp(snapshot.timestamp))
        field("Driver updated", optional(snapshot.sourceTimestamp, timestamp))
        guard snapshot.isBatteryPresent else {
            field("Battery", "not present")
            return
        }
        field("Charge", optional(snapshot.chargePercent) { "\($0)%" })
        field("Power source", snapshot.powerSource.rawValue)
        field("Charging status", snapshot.chargingStatus.rawValue)
        field("Temperature", optional(snapshot.temperatureCelsius) { "\($0.formatted()) °C" })
        field("Voltage", optional(snapshot.voltageMillivolts) { "\($0) mV" })
        field("Current", optional(snapshot.amperageMilliamps) { "\($0) mA" })
        field("Adapter", optional(snapshot.adapterWatts) { "\($0) W" })
        let health = snapshot.health
        field("Cycle count", optional(health.cycleCount) { "\($0)" })
        field("Full-charge capacity", optional(health.fullChargeCapacityMilliampHours) { "\($0) mAh" })
        field("Design capacity", optional(health.designCapacityMilliampHours) { "\($0) mAh" })
        field("Condition", health.condition ?? "not available")
    }

    private static func describe(_ availability: ControlAvailability) -> String {
        switch availability {
        case .available: "available"
        case .experimental: "experimental"
        case .simulated: "simulated"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }

    private static func describe(_ result: ExecutionRecord.Result) -> String {
        switch result {
        case .applied: "applied and confirmed"
        case .unchanged: "already in effect"
        case .simulated: "simulated"
        case .adoptedOutsideChange: "kept a change made outside CellKeeper"
        case .failed(let message): "failed: \(message)"
        case .refused(let reason): "refused: \(reason)"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
