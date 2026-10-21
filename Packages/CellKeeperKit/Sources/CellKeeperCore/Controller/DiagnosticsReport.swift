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

/// A group of rows: a section of the diagnostics report, and of Settings ›
/// Diagnostics.
public struct DiagnosticsSection: Sendable, Equatable {
    /// Nil for the rows at the top (the app, macOS and the model), which the
    /// report writes under its own heading, without a title line.
    public let title: String?
    public let rows: [DiagnosticsRow]
}

/// A line of the diagnostics report, and a row of Settings › Diagnostics.
public struct DiagnosticsRow: Sendable, Equatable {
    public let label: String
    public let value: DiagnosticsValue
}

/// A value in the diagnostics report, kept in parts so that the report can
/// name identifiers and the Diagnostics view can leave them out, and so
/// that VoiceOver can read units in words.
public struct DiagnosticsValue: Sendable, Equatable, ExpressibleByStringInterpolation {
    enum Part: Sendable, Equatable {
        /// Words the report and the view both show.
        case text(String)
        /// Plain words for a backend, a policy state, a mode, a power source
        /// or a charging status, and the identifier the report adds in
        /// parentheses after them ("holding at the limit (holding)").
        case identified(String, identifier: String)
        /// A moment, which the report writes in ISO 8601, in UTC.
        case time(Date)
        /// A moment with the offset from UTC in force at it where it was
        /// computed, which the report writes in ISO 8601 with that offset
        /// ("2026-10-23T07:00:00+01:00"), so that a change of offset shows
        /// without naming a time zone.
        case offsetTime(Date, utcOffset: Int)
        /// A number and its unit, which the report and the view write with
        /// the unit's symbol ("12427 mV", "31 °C"), and VoiceOver reads in
        /// words ("12,427 millivolts").
        case quantity(Number, unit: QuantityUnit)
    }

    /// The number of a quantity.
    enum Number: Sendable, Equatable {
        /// A whole number, kept exact: the report writes it as is.
        case integer(Int)
        /// A decimal number, and the text the report writes for it.
        case decimal(Double, written: String)

        var written: String {
            switch self {
            case .integer(let value): "\(value)"
            case .decimal(_, let written): written
            }
        }
    }

    /// The most decimals a decimal quantity shows: as many as `formatted()`
    /// shows, which writes it in the report.
    static let decimalPlaces = 6

    let parts: [Part]

    init(parts: [Part]) {
        self.parts = parts
    }

    public init(stringLiteral value: String) {
        parts = [.text(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        parts = stringInterpolation.parts
    }

    /// The value as the report writes it: each identifier in parentheses
    /// after its words, and moments in ISO 8601. Account names in paths are
    /// replaced, as in the report.
    public var reportText: String {
        DiagnosticsReport.redactingAccountNames(parts.map { part in
            switch part {
            case .text(let text): text
            case .identified(let words, let identifier): "\(words) (\(identifier))"
            case .time(let date): DiagnosticsReport.timestamp(date)
            case .offsetTime(let date, let utcOffset): DiagnosticsReport.timestamp(date, utcOffset: utcOffset)
            case .quantity(let number, let unit): "\(number.written) \(unit.symbol)"
            }
        }.joined())
    }

    /// The value in plain words, as the Diagnostics view shows it: no
    /// identifiers, and moments as `formatTime` writes them. Account names in
    /// paths are replaced, as in the report.
    public func plainText(formattingTime formatTime: (Date) -> String) -> String {
        DiagnosticsReport.redactingAccountNames(parts.map { part in
            switch part {
            case .text(let text): text
            case .identified(let words, _): words
            case .time(let date), .offsetTime(let date, _): formatTime(date)
            case .quantity(let number, let unit): "\(number.written) \(unit.symbol)"
            }
        }.joined())
    }

    /// What VoiceOver reads for the value in the Diagnostics view: the plain
    /// text with units in words and numbers in `locale`'s format ("12,427
    /// millivolts", "-12 milliamps", "31 degrees Celsius"), also the
    /// temperatures in the sentences of the policy and the settings check
    /// ("Battery at 41.5 degrees Celsius"), whose numbers are read with
    /// `locale`'s separators. A unit is singular when its number, as shown,
    /// is 1 or -1. Nil if the plain text names no unit, so that the view
    /// leaves the text as it is.
    public func spokenText(formattingTime formatTime: (Date) -> String, locale: Locale = .current) -> String? {
        var pieces: [String] = []
        // Text parts next to each other are read as one, so that a number
        // and its "°C" from different parts are read together.
        var text = ""
        for part in parts {
            if case .text(let next) = part {
                text += next
                continue
            }
            pieces.append(Self.speakingTemperatures(in: text, locale: locale))
            text = ""
            switch part {
            case .text: break
            case .identified(let words, _): pieces.append(words)
            case .time(let date), .offsetTime(let date, _): pieces.append(formatTime(date))
            case .quantity(.integer(let value), let unit): pieces.append(unit.spoken(value, locale: locale))
            case .quantity(.decimal(let value, _), let unit): pieces.append(unit.spoken(value, fractionDigits: 0...Self.decimalPlaces, locale: locale))
            }
        }
        pieces.append(Self.speakingTemperatures(in: text, locale: locale))
        let spoken = DiagnosticsReport.redactingAccountNames(pieces.joined())
        return spoken == plainText(formattingTime: formatTime) ? nil : spoken
    }

    /// `text` with each temperature written after a number ("41.5°C",
    /// "40 °C", "1,000°C") in words. The policy's reasons and the settings
    /// check's messages, which the menu, notifications and the activity log
    /// share, write temperatures so, in the current locale's format, which
    /// is `locale` in the app. The whole number is read with `locale`'s
    /// grouping and decimal separators (a space-like grouping separator in
    /// any of its forms: space, no-break space, narrow no-break space). It
    /// is already rounded as shown, so it is one if the digits of its whole
    /// part are exactly 1 and its decimals are 0, by the digits' values.
    private static func speakingTemperatures(in text: String, locale: Locale) -> String {
        let spaces = [" ", "\u{00A0}", "\u{202F}"]
        let grouping = locale.groupingSeparator.map { spaces.contains($0) ? spaces : [$0] } ?? []
        let decimal = locale.decimalSeparator ?? "."
        // Separators as code points, which need no escaping.
        func anyOf(_ separators: [String]) -> String {
            "(?:" + separators.map { $0.unicodeScalars.map { "\\x{\(String($0.value, radix: 16))}" }.joined() }.joined(separator: "|") + ")"
        }
        let groups = grouping.isEmpty ? "" : "(?:\(anyOf(grouping))\\d+)*"
        guard let number = try? Regex("((\\d+\(groups))(?:\(anyOf([decimal]))(\\d+))?)\\s?°C") else { return text }
        return text.replacing(number) { match in
            let whole = match.output[2].substring?.compactMap(\.wholeNumberValue) ?? []
            let decimals = match.output[3].substring?.compactMap(\.wholeNumberValue) ?? []
            let isOne = whole == [1] && decimals.allSatisfy { $0 == 0 }
            return "\(match.output[1].substring ?? "") \(QuantityUnit.degreesCelsius.name(singular: isOne))"
        }
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var parts: [Part] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            parts.append(.text(literal))
        }

        /// The value's description, as words.
        public mutating func appendInterpolation(_ value: some CustomStringConvertible) {
            parts.append(.text(value.description))
        }

        public mutating func appendInterpolation(_ value: DiagnosticsValue) {
            parts.append(contentsOf: value.parts)
        }

        public mutating func appendInterpolation(_ words: String, identifier: String) {
            parts.append(.identified(words, identifier: identifier))
        }

        public mutating func appendInterpolation(time: Date) {
            parts.append(.time(time))
        }

        public mutating func appendInterpolation(time: Date, utcOffset: Int) {
            parts.append(.offsetTime(time, utcOffset: utcOffset))
        }

        /// A whole number and its unit, the number written as is: "12427 mV".
        public mutating func appendInterpolation(_ value: Int, unit: QuantityUnit) {
            parts.append(.quantity(.integer(value), unit: unit))
        }

        /// A number and its unit, the number in the current locale's format,
        /// as the report writes temperatures: "31.5 °C".
        public mutating func appendInterpolation(_ value: Double, unit: QuantityUnit) {
            parts.append(.quantity(.decimal(value, written: value.formatted()), unit: unit))
        }
    }
}

extension [DiagnosticsValue] {
    /// The values one after another, with `separator` between them.
    func joined(separator: String) -> DiagnosticsValue {
        var parts: [DiagnosticsValue.Part] = []
        for (index, value) in enumerated() {
            if index > 0 { parts.append(.text(separator)) }
            parts.append(contentsOf: value.parts)
        }
        return DiagnosticsValue(parts: parts)
    }
}

/// A plain-text report of what CellKeeper sees and does, for bug reports,
/// and the sections Settings › Diagnostics shows.
///
/// It is built only from a ``ControllerStatus`` and a
/// ``DiagnosticsEnvironment``. Those carry no serial numbers, power source
/// IDs or other device identifiers, because telemetry is read through an
/// allowlist and the activity log never records them. Error messages can
/// contain file paths, which name the macOS account under `/Users`; the
/// report and every value replace that name.
public enum DiagnosticsReport {
    /// The report's text: a heading with the time it was generated, then
    /// ``sections(status:environment:powerFlow:)``, then the activity log.
    public static func text(status: ControllerStatus, environment: DiagnosticsEnvironment, powerFlow: PowerFlowDiagnostics? = nil, generatedAt: Date) -> String {
        var lines = ["CellKeeper diagnostics", "Generated: \(timestamp(generatedAt))"]
        for section in sections(status: status, environment: environment, powerFlow: powerFlow) {
            if let title = section.title {
                lines.append("")
                lines.append("== \(title)")
            }
            for row in section.rows {
                lines.append("\(row.label): \(row.value.reportText)")
            }
        }
        lines.append("")
        lines.append("== Activity (oldest first)")
        if status.events.isEmpty {
            lines.append("none")
        }
        for event in status.events {
            lines.append("\(timestamp(event.date)) [\(event.kind.rawValue)] \(event.message)")
        }
        return redactingAccountNames(lines.joined(separator: "\n") + "\n")
    }

    /// Everything the report says apart from when it was generated and the
    /// activity log: the app, macOS and the model, then Control, Settings,
    /// Battery, Decision, with a native-limit backend macOS Charge Limit,
    /// once there has been one Calibration, and, when given, Power flow.
    public static func sections(status: ControllerStatus, environment: DiagnosticsEnvironment, powerFlow: PowerFlowDiagnostics? = nil) -> [DiagnosticsSection] {
        var sections: [DiagnosticsSection] = []
        var title: String?
        var rows: [DiagnosticsRow] = []
        func section(_ next: String) {
            sections.append(DiagnosticsSection(title: title, rows: rows))
            title = next
            rows = []
        }
        func field(_ name: String, _ value: DiagnosticsValue) {
            rows.append(DiagnosticsRow(label: name, value: value))
        }

        field("App", "\(environment.appVersion)")
        field("macOS", "\(environment.systemVersion)")
        field("Model", "\(environment.modelIdentifier ?? "unknown")")

        section("Control")
        let capabilities = status.capabilities
        // As in the activity log: with macOS's Charge Limit, what CellKeeper
        // restores is the user's own limit.
        let restoreTarget = capabilities.isEnforcedByMacOS
            ? "your own macOS Charge Limit" + (status.nativeLimit?.ownerLimit.map { " of \($0)%" } ?? "")
            : "normal charging"
        // A mode in plain words, then its identifier.
        func describeMode(_ mode: ChargeControlMode) -> DiagnosticsValue {
            "\(mode == .normal ? restoreTarget : mode.description, identifier: mode.identifier)"
        }
        field("Backend", "\(status.backend.displayName, identifier: status.backend.identifier)")
        field("Availability", "\(describe(capabilities.availability))")
        if capabilities.isEnforcedByMacOS {
            field("Style", "macOS Charge Limit, steps \(capabilities.nativeLimitSteps.map(String.init).joined(separator: ", "))")
        } else {
            field("Style", "switches charging, modes \(capabilities.supportedModes.sorted { $0.identifier < $1.identifier }.map(describeMode).joined(separator: ", "))")
        }
        field("Reported mode", status.currentMode.map(describeMode) ?? "unknown")
        if let macOSLimit = capabilities.macOSChargeLimit {
            // While macOS's own Charge Limit may be limiting, the policy asks
            // for normal charging and withholds restrictions; only a
            // read-back says whether CellKeeper's own restriction ended.
            let deferring = macOSLimit.isLimiting ? "; CellKeeper defers to it: it withholds new restrictions and asks for the release of any restriction of its own" : ""
            field("macOS Charge Limit", "\(MacOSChargeLimitWording.summary(macOSLimit)), read \(time: macOSLimit.readAt)\(deferring)")
            if let problem = macOSLimit.readProblem {
                field("macOS Charge Limit read problem", "\(problem)")
            }
            if macOSLimit.isLimiting {
                field("Own restriction", "\(MacOSChargeLimitWording.releaseState(status.ownRestriction, isSimulated: status.isControlSimulated))")
            }
        }
        field("Pending switch", "\(status.pendingBackend.map(\.displayName) ?? "none")")
        field("Consecutive failures", "\(status.consecutiveFailures)\(status.isBackendFaulted ? " (faulted)" : "")")
        if let refusal = status.managementRefusal {
            field("Management refused", "\(refusal)")
        }

        section("Settings")
        let settings = status.settings
        field("Manage charging", settings.isManagementEnabled ? "on" : "off")
        field("Charge limit", "\(settings.chargeLimit)%")
        field("Resume threshold", "\(settings.resumeThreshold)%")
        let protection = settings.temperatureProtection
        field("Temperature protection", "\(protection.isEnabled ? "on" : "off") (pause \(protection.pauseAtCelsius, unit: .degreesCelsius), resume \(protection.resumeAtCelsius, unit: .degreesCelsius))")

        section("Battery")
        if let snapshot = status.snapshot {
            rows.append(contentsOf: batteryRows(snapshot))
        } else {
            field("Telemetry", "unavailable\(status.telemetryError.map { ": \($0)" } ?? "")")
        }

        section("Decision")
        if let decision = status.decision {
            field("State", identified(decision.state))
            field("Wants", describeMode(decision.desiredMode))
            field("Action", "\(ChargeController.describe(decision.action, nativeLimit: capabilities.isEnforcedByMacOS))")
            field("Reason", "\(decision.reason.description(restoring: restoreTarget))")
            for note in decision.notes {
                field("Note", "\(note.description)")
            }
        } else {
            field("State", "not evaluated yet")
        }
        if let override = status.activeOverride {
            let target = override.targetPercent.map { " to \($0)%" } ?? ""
            field("Override", "\(ChargeController.describe(override))\(target), started \(time: override.startedAt), expires \(time: override.expiresAt)")
        }
        if let schedule = status.fullChargeSchedule {
            let waiting = status.fullChargeScheduleWait.map { "; due, waiting: \($0)" } ?? ""
            field("Scheduled full charge", "\(time: schedule.startsAt) to \(time: schedule.endsAt)\(waiting)")
        }
        if let outcome = status.fullChargeScheduleOutcome {
            field("Schedule outcome", describe(outcome))
        }
        rows.append(contentsOf: weeklyRows(status))
        if let execution = status.lastExecution {
            field("Last action", "\(time: execution.date) \(ChargeController.describe(execution.action, nativeLimit: capabilities.isEnforcedByMacOS)): \(describe(execution.result))")
        }
        if let evaluated = status.lastEvaluation {
            field("Last evaluation", "\(time: evaluated)")
        }

        if let native = status.nativeLimit {
            section("macOS Charge Limit")
            let judged: String = native.readDeferral.map { " (not judged: \($0))" } ?? ""
            field("Reported by macOS", "\(native.reportedLimit.map { "\($0)%" } ?? "unknown")\(judged)")
            if let readAt = native.readAt {
                field("Read at", "\(time: readAt)")
            }
            if let problem = native.readProblem {
                field("Read problem", "\(problem)")
            }
            if native.isRecordUnreadable {
                field("Own limit", "record unreadable")
            } else {
                field("Own limit", "\(native.ownerLimit.map { "\($0)% recorded" } ?? "not recorded (in effect)")")
            }
            if let target = native.target {
                field("CellKeeper's limit", "\(target)%")
            }
            field("Shortcut found", "\(native.isShortcutFound.map { $0 ? "yes" : "no" } ?? "not checked")")
            var flags: [String] = []
            if native.needsNoLimitConfirmation { flags.append("needs no-limit confirmation") }
            if native.isRestoreUnfinished { flags.append("restore unfinished") }
            if native.isAdoptionUnsaved { flags.append("adoption marker unsaved") }
            field("Flags", "\(flags.isEmpty ? "none" : flags.joined(separator: ", "))")
            if let adopted = status.adoptedChange {
                field("Kept outside change", "\(adopted.limit)%\(adopted.isNoLimit ? " (no limit)" : "") at \(time: adopted.date); CellKeeper had set \(adopted.expectedLimit)%, own limit was \(adopted.previousOwnerLimit)%\(adopted.isFromEarlierSession ? ", earlier session" : "")")
            }
        }
        let calibration = calibrationRows(status.calibration)
        if !calibration.isEmpty {
            section("Calibration")
            rows.append(contentsOf: calibration)
        }
        if let powerFlow {
            section("Power flow")
            rows.append(contentsOf: powerFlowRows(powerFlow))
        }
        sections.append(DiagnosticsSection(title: title, rows: rows))
        return sections
    }

    /// The power flow's rows (D115): where the flow on screen comes from and
    /// the SMC source's state, never a value; then, in a build with the SMC
    /// reader compiled in, the app's line saying so (research note 13
    /// §6.6), split at its first ": " into a label and a value.
    private static func powerFlowRows(_ powerFlow: PowerFlowDiagnostics) -> [DiagnosticsRow] {
        var rows = [
            DiagnosticsRow(label: "Shown from", value: "\(PowerFlowWording.diagnosticsSource(powerFlow.shown, registrySourceName: powerFlow.registrySourceName))"),
            DiagnosticsRow(label: "SMC source", value: identified(powerFlow.smcState)),
        ]
        if let line = powerFlow.readerLine {
            if let separator = line.range(of: ": ") {
                rows.append(DiagnosticsRow(label: String(line[..<separator.lowerBound]), value: "\(String(line[separator.upperBound...]))"))
            } else {
                rows.append(DiagnosticsRow(label: line, value: ""))
            }
        }
        return rows
    }

    /// The guided calibration's rows (research note 12 §7.9): the session
    /// in progress, then the report of the latest one that ended. Only
    /// times, steps, charges, capacities and cycle counts; never an
    /// identifier.
    private static func calibrationRows(_ calibration: CalibrationStatus) -> [DiagnosticsRow] {
        var rows: [DiagnosticsRow] = []
        func field(_ name: String, _ value: DiagnosticsValue) {
            rows.append(DiagnosticsRow(label: name, value: value))
        }
        if let session = calibration.session {
            var state: [String] = []
            if calibration.isPaused { state.append("paused, waiting for you to continue or cancel") }
            if session.isReturning { state.append("returning to CellKeeper's limit, not confirmed yet") }
            if calibration.needsRestAnswer { state.append("asking whether the Mac stayed shut down and unplugged") }
            field("Session", "step \(session.step.rawValue) of \(CalibrationStep.allCases.count), \(session.step)\(state.isEmpty ? "" : "; " + state.joined(separator: "; "))")
            field("Session started", "\(time: session.startedAt.wall)")
            field("Step started", "\(time: session.stepStartedAt.wall)")
            if let end = calibration.stepEndsAt {
                field(session.step == .restAtBottom ? "Plug in again after" : "Step ends at the latest", "\(time: end)")
            }
            if let cap = calibration.capEndsAt {
                field("Session ends at the latest", "\(time: cap)")
            }
            if session.step == .restAtBottom {
                field("Rest", "\(session.isRestAgainRequested ? "asked once to rest again" : "requested")\(session.restSleep.map { "; sleep announced at \($0.percent.map { "\($0)%" } ?? "an unknown charge")" } ?? "")")
            }
            field("Limits", "your own \(session.ownerLimit)%, CellKeeper's \(session.cellKeeperLimit)% when it started; 100% asked for only in steps 1, 2 and 7")
            field("Temperature", "\(temperatureText(session.temperatureCheck))")
        }
        if calibration.isEndUnsaved {
            field("Calibration store", "\("the end of the calibration is not saved yet; it may come back, paused, at the next launch", identifier: "endUnsaved")")
        }
        guard let report = calibration.last else { return rows }
        field("Last calibration", "\(time: report.startedAt) to \(time: report.endedAt); \(report.end.isCompleted ? "finished" : "ended early: \(report.end)")")
        field("Steps", report.steps.map { entry -> DiagnosticsValue in "\(entry.step.rawValue) \(time: entry.enteredAt)" }.joined(separator: ", "))
        if !report.resumedAt.isEmpty {
            field("Continued after a relaunch", report.resumedAt.map { date -> DiagnosticsValue in "\(time: date)" }.joined(separator: ", "))
        }
        field("Steps done", "\(CalibrationWording.stepsDone(report))")
        field("Before", capacities(report.before))
        field("After", report.after.map(capacities) ?? "no reading when it ended")
        field("Rest at the bottom", report.restResult.map(restText) ?? "not reached")
        field("Recorded as short", "\(report.shortRests.isEmpty ? "none" : report.shortRests.map(\.description).joined(separator: ", "))")
        field("Temperature at start", "\(temperatureText(report.temperatureCheck))")
        field("Optimized Battery Charging", "\(report.optimizedCharging == .off ? "confirmed off" : "the owner accepted step 1's limit")")
        field("Gauge", "\(CalibrationWording.gaugeNote)")
        return rows
    }

    private static func capacities(_ capacities: CalibrationCapacities) -> DiagnosticsValue {
        var parts: [DiagnosticsValue] = []
        if let full = capacities.fullChargeMilliampHours { parts.append("full-charge \(full, unit: .milliampHours)") }
        if let nominal = capacities.nominalMilliampHours { parts.append("nominal \(nominal, unit: .milliampHours)") }
        if let design = capacities.designMilliampHours { parts.append("design \(design, unit: .milliampHours)") }
        if let cycles = capacities.cycleCount { parts.append("\(cycles) cycles") }
        return parts.isEmpty ? "not available" : parts.joined(separator: ", ")
    }

    private static func restText(_ result: CalibrationRestResult) -> DiagnosticsValue {
        switch result {
        case .counted(let slept, let from, let to):
            return "counted: slept \(Int(slept / 60)) minutes on battery power, \(from)% to \(to)%"
        case .ownersAccount(let bootTime, let last):
            let boot: DiagnosticsValue = bootTime.map { "; started again at \(time: $0)" } ?? ""
            let reading: DiagnosticsValue = last.map { "; last reading before: \($0.percent)% on \($0.powerSource) at \(time: $0.at)" } ?? ""
            return "by your account\(boot)\(reading)"
        case .notConfirmed(let reason):
            return "\("not confirmed: \(reason)", identifier: reason.rawValue)"
        }
    }

    private static func temperatureText(_ check: CalibrationTemperatureCheck) -> String {
        switch check {
        case .measured: "read, 10–40 °C required"
        case .ownerConfirmedCoolRoom: "not readable; the owner confirmed a room at 10–35 °C"
        }
    }

    /// Replaces the account name in paths such as
    /// `/Users/<name>/Library/Containers/…`, which Foundation's file errors
    /// include.
    static func redactingAccountNames(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s"'“”‘’,;:()\[\]{}<>]+"#, with: "/Users/<user>", options: .regularExpression)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// `date` in ISO 8601 with `utcOffset` ("Z" for zero), or in UTC if the
    /// offset is not one a time zone can have.
    static func timestamp(_ date: Date, utcOffset: Int) -> String {
        guard (-18 * 3600...18 * 3600).contains(utcOffset), let zone = TimeZone(secondsFromGMT: utcOffset) else { return timestamp(date) }
        return date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: zone))
    }

    private static func batteryRows(_ snapshot: BatterySnapshot) -> [DiagnosticsRow] {
        var rows: [DiagnosticsRow] = []
        func field(_ name: String, _ value: DiagnosticsValue) {
            rows.append(DiagnosticsRow(label: name, value: value))
        }
        func optional<T>(_ value: T?, _ format: (T) -> DiagnosticsValue) -> DiagnosticsValue {
            value.map(format) ?? "not available"
        }
        field("Read at", "\(time: snapshot.timestamp)")
        field("Driver updated", optional(snapshot.sourceTimestamp) { "\(time: $0)" })
        guard snapshot.isBatteryPresent else {
            field("Battery", "not present")
            return rows
        }
        field("Charge", optional(snapshot.chargePercent) { "\($0)%" })
        field("Power source", identified(snapshot.powerSource))
        field("Charging status", identified(snapshot.chargingStatus))
        field("Temperature", optional(snapshot.temperatureCelsius) { "\($0, unit: .degreesCelsius)" })
        field("Voltage", optional(snapshot.voltageMillivolts) { "\($0, unit: .millivolts)" })
        field("Current", optional(snapshot.amperageMilliamps) { "\($0, unit: .milliamps)" })
        field("Adapter", optional(snapshot.adapterWatts) { "\($0, unit: .watts)" })
        // macOS's own figures (undocumented, in mW), as the menu's power
        // flow shows them; display only (D114).
        field("System power in", optional(snapshot.systemPowerInMilliwatts) { "\(Double($0) / 1000, unit: .watts)" })
        field("Mac use", optional(snapshot.systemLoadMilliwatts) { "\(Double($0) / 1000, unit: .watts)" })
        let health = snapshot.health
        field("Cycle count", optional(health.cycleCount) { "\($0)" })
        field("Full-charge capacity", optional(health.fullChargeCapacityMilliampHours) { "\($0, unit: .milliampHours)" })
        field("Design capacity", optional(health.designCapacityMilliampHours) { "\($0, unit: .milliampHours)" })
        field("Condition", "\(health.condition ?? "not available")")
        return rows
    }

    /// `value` in plain words, then its identifier, as the report shows the
    /// backend.
    private static func identified<Value: RawRepresentable & CustomStringConvertible>(_ value: Value) -> DiagnosticsValue where Value.RawValue == String {
        "\(value.description, identifier: value.rawValue)"
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
        case .deferred(let written): written ? "set, not confirmed yet: macOS's Charge Limit not judged" : "waiting: macOS's Charge Limit not judged, nothing changed"
        case .failed(let message): "failed: \(message)"
        case .refused(let reason): "refused: \(reason)"
        }
    }

    private static func describe(_ outcome: FullChargeScheduleOutcome) -> DiagnosticsValue {
        switch outcome {
        case .started(let schedule):
            "started (window \(time: schedule.startsAt) to \(time: schedule.endsAt))"
        case .alreadyFull(let schedule):
            "already full at the start (window \(time: schedule.startsAt) to \(time: schedule.endsAt))"
        case .extendedRunning:
            "extended the deadline of a running full charge"
        case .keptRunning(_, let deadline):
            "a running full charge already had \(describe(deadline))"
        case .windowPassed(let schedule, let lastWait):
            "window passed before it could start (\(time: schedule.startsAt) to \(time: schedule.endsAt))\(lastWait.map { "; last checked: \($0)" } ?? "")"
        case .discarded(let reason):
            "a saved schedule was removed: \(reason)"
        }
    }

    private static func describe(_ deadline: RunningDeadline) -> String {
        switch deadline {
        case .later: "a later deadline"
        case .same: "the same deadline"
        }
    }

    /// The weekly full charge's rows: the pattern, the occurrence that is
    /// due, the next one and the record while one is in use; a store that
    /// is not in line; the latest outcome, also after removal. Times carry
    /// the UTC offset they were computed with, never a time zone's name.
    private static func weeklyRows(_ status: ControllerStatus) -> [DiagnosticsRow] {
        var rows: [DiagnosticsRow] = []
        func field(_ name: String, _ value: DiagnosticsValue) {
            rows.append(DiagnosticsRow(label: name, value: value))
        }
        func window(_ occurrence: WeeklyFullChargeOccurrence) -> DiagnosticsValue {
            "\(occurrence.day) (nominal), \(time: occurrence.startsAt, utcOffset: occurrence.startUTCOffset) to \(time: occurrence.endsAt, utcOffset: occurrence.endUTCOffset)"
        }
        if let weekly = status.weeklyFullCharge {
            field("Weekly full charge", "\(ChargeController.describe(weekly.pattern))")
        }
        if let due = status.weeklyFullChargeDue {
            field("Weekly due", "\(window(due.occurrence)); waiting: \(due.wait)")
        }
        if let next = status.weeklyFullChargeNext {
            field("Weekly next", window(next))
        }
        if let handled = status.weeklyFullCharge?.handled {
            field("Weekly handled", "\(handled.day) (nominal), \(ChargeController.describe(handled.result), identifier: handled.result.rawValue), starting \(time: handled.startsAt, utcOffset: handled.utcOffset)")
        }
        if let problem = status.weeklyFullChargeStoreProblem {
            switch problem {
            case .notSaved: field("Weekly store", "\("not saved; the weekly full charge in use differs from the stored one", identifier: "notSaved")")
            case .notRemoved: field("Weekly store", "\("removal not saved; a weekly full charge may still be stored", identifier: "notRemoved")")
            }
        }
        if let outcome = status.weeklyFullChargeOutcome {
            field("Weekly outcome", describe(outcome))
        }
        return rows
    }

    private static func describe(_ outcome: WeeklyFullChargeOutcome) -> DiagnosticsValue {
        func window(_ occurrence: WeeklyFullChargeOccurrence) -> DiagnosticsValue {
            "\(time: occurrence.startsAt, utcOffset: occurrence.startUTCOffset) to \(time: occurrence.endsAt, utcOffset: occurrence.endUTCOffset)"
        }
        return switch outcome {
        case .started(let occurrence):
            "started (window \(window(occurrence)))"
        case .alreadyFull(let occurrence):
            "already full at the start (window \(window(occurrence)))"
        case .extendedRunning:
            "extended the deadline of a running full charge"
        case .keptRunning(_, let deadline):
            "a running full charge already had \(describe(deadline))"
        case .windowPassed(let occurrence, let lastWait):
            "window passed before it could start (\(window(occurrence)))\(lastWait.map { "; last checked: \($0)" } ?? "")"
        case .discarded(let reason):
            "a saved weekly full charge could not be used and is removed: \(reason)"
        case .skippedForCalibration(let occurrence):
            "skipped: a calibration was in progress (window \(window(occurrence)))"
        }
    }
}
