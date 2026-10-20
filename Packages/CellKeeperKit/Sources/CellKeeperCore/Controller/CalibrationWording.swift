import Foundation

/// What CellKeeper asks the owner to do during a guided calibration (note 12
/// §7.5): shown in the menu, and posted as a notification if the owner
/// turned notifications on.
public enum CalibrationRequest: Sendable, Equatable {
    /// Step 3.
    case unplug
    /// Step 5, with the time shown to plug in again.
    case rest(plugInAfter: Date)
    /// Step 5, after an early wake: once, until the same time.
    case restAgain(plugInAfter: Date)
    /// Step 6.
    case plugIn
}

/// What a read-back establishes about macOS's Charge Limit after a guided
/// calibration ended (``CalibrationWording/limitAfter(_:)``).
public enum CalibrationLimitAfter: Sendable, Equatable {
    /// CellKeeper's own limit is in effect, as wanted and read back.
    case cellKeeperLimit(Int)
    /// The owner's own limit is in effect: CellKeeper holds nothing. The
    /// value macOS reported, if read.
    case ownLimit(Int?)
    /// Neither is confirmed: macOS's limit may still be at 100%. The value
    /// macOS last reported, if read.
    case unconfirmed(reported: Int?)
}

/// The words of a guided calibration: the requests (§7.5), the menu's and
/// Settings' lines, the activity log, and the report (§7.9). They say what
/// CellKeeper does and asks, never that the gauge relearnt anything: the
/// gauge decides that, and on macOS 27 CellKeeper cannot see it (§3).
public enum CalibrationWording {
    /// Why a full charge, or its schedule, is refused during a session
    /// (§7.4).
    public static let inProgress = "A calibration is in progress."

    /// Said with every report.
    public static let gaugeNote = "The battery's gauge decides what it relearns. “Maximum Capacity” can go up or down afterwards, and on macOS 27 CellKeeper cannot check what the gauge learnt."

    /// What a calibration is and does, for Settings.
    public static let explanation = "A guided calibration helps the battery's gauge relearn how much charge the battery holds, when the percentage misbehaves: your Mac shuts down early, or the percentage jumps. It does not make the battery healthier. It takes about one to two days, three at most, mostly unattended: CellKeeper charges to 100% and rests there for 2 hours, asks you to unplug, watches the battery drain to 20% while you use your Mac, asks you to shut it down unplugged for at least 5 hours, then charges to 100% once more and returns to your limit."

    /// When 100% applies, and when it can last longer (§7.2), for Settings.
    public static let fullLimitDisclosure = "CellKeeper sets macOS's Charge Limit to 100% only in the two charges and the rest at the top, which begin while your Mac is plugged in and CellKeeper is running. It stays at 100% longer if your Mac sleeps in those steps, if returning to your limit is delayed or fails, or if CellKeeper is killed or crashes in them, until CellKeeper runs again or you set the limit yourself."

    /// How often, for Settings (§7.8).
    public static let frequency = "Calibrate only when the percentage misbehaves, or every few months for a battery that rarely leaves a narrow range. macOS already charges to 100% now and then to keep its estimate accurate."

    /// The recovery shown before the start (§7.2, safety precondition 11).
    public static func recovery(ownerLimit: Int?) -> String {
        let value = ownerLimit.map { ": your own limit is \(NativeLimitWording.limit($0))" } ?? ""
        return "If anything goes wrong, CellKeeper gives back your own Charge Limit when it quits or fails, and its normal limit applies again whenever the calibration ends. If CellKeeper cannot, set the limit yourself in System Settings › Battery › Charging\(value)."
    }

    // MARK: - Requests

    /// What CellKeeper asks the owner to do now, if anything: none while
    /// paused or returning, and no rest at 15% or below (§7.6).
    public static func request(_ status: CalibrationStatus, reading: BatterySnapshot?) -> CalibrationRequest? {
        guard let session = status.session, !status.isPaused, !session.isReturning else { return nil }
        switch session.step {
        case .unplug:
            return .unplug
        case .restAtBottom:
            guard let after = session.plugInAfter else { return nil }
            if let percent = reading?.chargePercent, percent <= CalibrationSession.lowBatteryPercent { return nil }
            return session.isRestAgainRequested ? .restAgain(plugInAfter: after) : .rest(plugInAfter: after)
        case .plugIn:
            return .plugIn
        case .chargeToFull, .restAtTop, .drain, .finalCharge:
            return nil
        }
    }

    /// A request's words. `atRequest` is true for a notification posted
    /// when the request begins, which can say "from now"; the menu's line
    /// shows it later too, and says what the time counts from.
    public static func text(_ request: CalibrationRequest, atRequest: Bool, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch request {
        case .unplug:
            return "Unplug your Mac now; CellKeeper will watch the battery drain to \(CalibrationSession.targetPercent)%."
        case .rest(let after):
            let time = clockTime(after, now: now, timeZone: timeZone, locale: locale)
            let since = atRequest ? "at least 5 hours from now" : "5 hours after the battery reached \(CalibrationSession.targetPercent)%"
            return "Shut down your Mac now and leave it unplugged. Plug it in again after \(time) (\(since)), even before you open CellKeeper. CellKeeper continues when you open it again. If you cannot shut it down, put it to sleep instead."
        case .restAgain(let after):
            let time = clockTime(after, now: now, timeZone: timeZone, locale: locale)
            return "Your Mac woke before \(time). Shut it down or put it to sleep again, unplugged, and plug it in again after \(time), even before you open CellKeeper."
        case .plugIn:
            return "Plug in your Mac now; CellKeeper will charge it to 100% once more, then return to your limit."
        }
    }

    /// A request's notification title.
    public static func title(_ request: CalibrationRequest) -> String {
        switch request {
        case .unplug: "Calibration: unplug your Mac"
        case .rest, .restAgain: "Calibration: rest your Mac unplugged"
        case .plugIn: "Calibration: plug in your Mac"
        }
    }

    // MARK: - The menu and Settings

    /// The request for `status`, judged on the reading of its latest
    /// evaluation if the policy accepted it.
    public static func request(for status: ControllerStatus) -> CalibrationRequest? {
        request(status.calibration, reading: NotificationPlanner.usableSnapshot(status))
    }

    /// The menu's line for `status`, as of its latest evaluation.
    public static func statusLine(for status: ControllerStatus, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        statusLine(status.calibration, cellKeeperLimit: status.settings.chargeLimit, reading: NotificationPlanner.usableSnapshot(status), now: status.lastEvaluation ?? Date(), timeZone: timeZone, locale: locale)
    }

    /// "Step 4 of 7".
    public static func stepNumber(_ step: CalibrationStep) -> String {
        "Step \(step.rawValue) of \(CalibrationStep.allCases.count)"
    }

    /// The menu's status line for a session in progress: the step, what
    /// CellKeeper does, the next action, and when the step ends at the
    /// latest. Nil without a session.
    public static func statusLine(_ status: CalibrationStatus, cellKeeperLimit: Int, reading: BatterySnapshot?, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let session = status.session else { return nil }
        let step = stepNumber(session.step)
        func time(_ date: Date?) -> String? {
            date.map { clockTime($0, now: now, timeZone: timeZone, locale: locale) }
        }
        if status.isPaused {
            if status.needsRestAnswer, let after = time(session.plugInAfter) {
                return "Calibration paused in step 5 of 7: CellKeeper started again after a restart. Did your Mac stay shut down and unplugged until \(after)?"
            }
            return "Calibration paused in \(step.lowercased()) (\(session.step)): CellKeeper was not running. Continue to go on, or cancel it. Meanwhile your \(NativeLimitWording.limit(cellKeeperLimit)) limit applies."
        }
        if session.isReturning {
            return "Calibration, \(step.lowercased()): returning to your limit. CellKeeper asks macOS for its \(NativeLimitWording.limit(cellKeeperLimit)) limit again and waits for macOS to confirm it."
        }
        if let request = request(status, reading: reading) {
            let words = text(request, atRequest: false, now: now, timeZone: timeZone, locale: locale)
            var line = "Calibration, \(step.lowercased()): \(words.prefix(1).lowercased())\(words.dropFirst())"
            if session.step == .unplug, let end = time(status.stepEndsAt) {
                line += " If your Mac is still plugged in at \(end), the calibration ends."
            }
            return line
        }
        let confirmed = status.isFullLimitConfirmed ? "" : " CellKeeper has asked for 100%; macOS has not confirmed it yet."
        switch session.step {
        case .chargeToFull:
            let end = time(status.stepEndsAt).map { ", at the latest at \($0)" } ?? ""
            return "Calibration, \(step.lowercased()): charging to 100%. Leave your Mac plugged in; this step ends when macOS reports the battery charged\(end).\(confirmed)"
        case .restAtTop:
            let end = time(status.stepEndsAt).map { " until about \($0)" } ?? ""
            return "Calibration, \(step.lowercased()): resting at 100%\(end). Leave your Mac plugged in.\(confirmed)"
        case .drain:
            let now = reading?.chargePercent.map { " (now \($0)%)" } ?? ""
            return "Calibration, \(step.lowercased()): draining to \(CalibrationSession.targetPercent)%\(now). Use your Mac on battery power as usual."
        case .finalCharge:
            let end = time(status.stepEndsAt).map { ", at the latest at \($0)" } ?? ""
            return "Calibration, \(step.lowercased()): charging to 100% once more. Leave your Mac plugged in; this step ends when macOS reports the battery charged\(end).\(confirmed)"
        case .restAtBottom:
            return "Calibration, \(step.lowercased()): plug in your Mac now: the battery is at \(CalibrationSession.lowBatteryPercent)% or below."
        case .unplug, .plugIn:
            return nil
        }
    }

    /// Shown throughout a session started without a temperature reading
    /// (§7.7).
    public static let temperatureUnknown = "Battery temperature unknown: this Mac does not report it, so you confirmed a cool room."

    /// What became of the session that ended in this run, with what a
    /// read-back now establishes about macOS's Charge Limit
    /// (``limitAfter(_:)``): never that a limit applies before macOS has
    /// confirmed it (R30).
    public static func outcomeLine(_ report: CalibrationReport, status: ControllerStatus) -> String {
        outcomeLine(report, limit: limitAfter(status), ownerLimit: status.nativeLimit?.ownerLimit ?? report.ownerLimit)
    }

    /// The outcome line for `limit`, what a read-back established;
    /// `ownerLimit` is the value to set by hand if it is not confirmed.
    public static func outcomeLine(_ report: CalibrationReport, limit: CalibrationLimitAfter, ownerLimit: Int) -> String {
        let sentence = limitSentence(limit, ownerLimit: ownerLimit)
        return switch report.end {
        case .completed:
            "Calibration finished. \(sentence) The report is in Settings › Charging."
        case .lowBattery(let percent):
            "Plug in your Mac now: the battery is at \(percent)%. The calibration has ended. \(sentence)"
        case .cancelled:
            "Calibration cancelled. \(sentence) The report is in Settings › Charging."
        default:
            "Calibration ended: \(report.end). \(sentence) The report is in Settings › Charging."
        }
    }

    /// A notification's title and body for a session that ended, as
    /// `status`, the status it is planned from, shows the limit.
    public static func endNotification(_ report: CalibrationReport, status: ControllerStatus) -> (title: String, body: String) {
        let body = outcomeLine(report, status: status)
        return switch report.end {
        case .completed: ("Calibration finished", body)
        case .lowBattery: ("Calibration ended: plug in your Mac now", body)
        default: ("Calibration ended early", body)
        }
    }

    /// What a read-back establishes about macOS's Charge Limit once a
    /// session has ended: CellKeeper's own limit, wanted and read back; the
    /// owner's own limit (CellKeeper holds nothing: it fell back to it, or
    /// does not manage charging); or neither yet, as when the return is
    /// deferred, failed, or its fallback to the owner's limit failed too.
    public static func limitAfter(_ status: ControllerStatus) -> CalibrationLimitAfter {
        let reported = status.nativeLimit?.reportedLimit
        guard let current = status.currentMode, !status.isOwnLimitRestorePending, status.nativeLimit?.isRecordUnreadable != true else {
            return .unconfirmed(reported: reported)
        }
        switch current {
        case .normal:
            return .ownLimit(reported)
        case .nativeLimit(let percent) where status.decision?.desiredMode == current && percent == status.settings.chargeLimit:
            return .cellKeeperLimit(percent)
        default:
            return .unconfirmed(reported: reported)
        }
    }

    /// `limit` in a sentence; when it is not confirmed, with the recovery:
    /// the owner's own limit to set in System Settings › Battery.
    public static func limitSentence(_ limit: CalibrationLimitAfter, ownerLimit: Int) -> String {
        switch limit {
        case .cellKeeperLimit(let percent):
            return "CellKeeper's \(NativeLimitWording.limit(percent)) limit applies again, confirmed by macOS."
        case .ownLimit(let percent):
            return "Your own Charge Limit\(percent.map { " of \(NativeLimitWording.limit($0))" } ?? "") applies again, confirmed by macOS."
        case .unconfirmed(let reported):
            let report: String = switch reported {
            case 100?: ": it still reports its Charge Limit at 100%"
            case let value?: ": it reports \(NativeLimitWording.limit(value))"
            case nil: ", so its Charge Limit may still be at 100%"
            }
            return "macOS has not confirmed CellKeeper's limit back yet\(report). CellKeeper keeps asking; if it does not change, set your own limit, \(NativeLimitWording.limit(ownerLimit)), in System Settings › Battery › Charging."
        }
    }

    /// A store that could not save a session's end.
    public static let endUnsaved = "CellKeeper could not save that the calibration ended. It tries again at its next check; until then, the calibration may come back, paused, if CellKeeper opens again."

    // MARK: - The report

    /// The report's lines, label and value, for Settings (§7.9).
    public static func reportLines(_ report: CalibrationReport, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [(label: String, value: String)] {
        func moment(_ date: Date) -> String { clockTime(date, now: now, timeZone: timeZone, locale: locale, alwaysWithDay: true) }
        var lines: [(String, String)] = [
            ("Started", moment(report.startedAt)),
            ("Ended", "\(moment(report.endedAt)): \(report.end)"),
        ]
        for entry in report.steps {
            lines.append(("\(stepNumber(entry.step)), \(entry.step)", "began \(moment(entry.enteredAt))"))
        }
        if !report.resumedAt.isEmpty {
            lines.append(("Continued after a relaunch", report.resumedAt.map(moment).joined(separator: ", ")))
        }
        lines.append(("Steps done", stepsDone(report)))
        lines.append(("Before", capacities(report.before)))
        lines.append(("After", report.after.map(capacities) ?? "no reading when it ended"))
        lines.append(("Rest at the bottom", report.restResult.map { restResult($0, now: now, timeZone: timeZone, locale: locale) } ?? "not reached"))
        lines.append(("Recorded as short", report.shortRests.isEmpty ? "none" : report.shortRests.map { "\($0)" }.joined(separator: ", ")))
        lines.append(("Temperature", report.temperatureCheck == .measured ? "checked: 10–40 °C throughout" : "not checked: this Mac does not report it; you confirmed a cool room"))
        lines.append(("Optimized Battery Charging", report.optimizedCharging == .off ? "you confirmed it was off" : "you accepted that step 1 might reach its limit"))
        return lines
    }

    /// The report in one paragraph, for the activity log.
    public static func reportSummary(_ report: CalibrationReport) -> String {
        var parts = ["Steps done: \(stepsDone(report))."]
        parts.append("Before: \(capacities(report.before)).")
        parts.append("After: \(report.after.map(capacities) ?? "no reading when it ended").")
        if let rest = report.restResult {
            parts.append("Rest at the bottom: \(restResult(rest, now: report.endedAt, timeZone: .current, locale: .current)).")
        }
        if !report.shortRests.isEmpty {
            parts.append("Recorded as short: \(report.shortRests.map { "\($0)" }.joined(separator: ", ")).")
        }
        parts.append(report.temperatureCheck == .measured ? "Temperature checked." : "Temperature not checked: you confirmed a cool room.")
        parts.append(gaugeNote)
        return parts.joined(separator: " ")
    }

    static func stepsDone(_ report: CalibrationReport) -> String {
        let done = report.stepsDone
        guard !done.isEmpty else { return "none" }
        return done.map { "\($0.rawValue) (\($0))" }.joined(separator: ", ")
    }

    /// The summary capacities and cycle count, never an identifier.
    public static func capacities(_ capacities: CalibrationCapacities) -> String {
        var parts: [String] = []
        if let full = capacities.fullChargeMilliampHours { parts.append("full-charge capacity \(full) mAh") }
        if let nominal = capacities.nominalMilliampHours { parts.append("nominal \(nominal) mAh") }
        if let design = capacities.designMilliampHours { parts.append("design \(design) mAh") }
        if let cycles = capacities.cycleCount { parts.append("\(cycles) cycles") }
        return parts.isEmpty ? "not available" : parts.joined(separator: ", ")
    }

    public static func restResult(_ result: CalibrationRestResult, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch result {
        case .counted(let slept, let from, let to):
            let duration = Duration.seconds(slept).formatted(.units(allowed: [.hours, .minutes], width: .wide))
            return "counted: your Mac slept for \(duration) on battery power, from \(from)% to \(to)%"
        case .ownersAccount(let bootTime, let lastReading):
            var text = "by your account: your Mac stayed shut down and unplugged until the time shown"
            var details: [String] = []
            if let bootTime { details.append("it started again at \(clockTime(bootTime, now: now, timeZone: timeZone, locale: locale, alwaysWithDay: true))") }
            if let lastReading {
                details.append("the last reading before was \(lastReading.percent)% on \(lastReading.powerSource) at \(clockTime(lastReading.at, now: now, timeZone: timeZone, locale: locale, alwaysWithDay: true))")
            }
            if !details.isEmpty { text += " (\(details.joined(separator: "; ")))" }
            return text
        case .notConfirmed(let reason):
            return "not confirmed: \(reason)"
        }
    }

    // MARK: - The activity log

    /// A change's line in the activity log; nil for a change another line
    /// already says.
    public static func logLine(_ change: CalibrationChange) -> String? {
        switch change {
        case .entered(.chargeToFull):
            return nil
        case .entered(.restAtTop):
            return "Calibration: macOS reports the battery charged. Step 2 (rest at the top) began: 2 hours at 100%."
        case .entered(.unplug):
            return "Calibration: step 3 (unplug) began; CellKeeper asks you to unplug your Mac."
        case .entered(.drain):
            return "Calibration: step 4 (drain) began: the battery drains to \(CalibrationSession.targetPercent)% while you use your Mac on battery power."
        case .entered(.restAtBottom):
            return "Calibration: the battery reached \(CalibrationSession.targetPercent)%. Step 5 (rest at the bottom) began: CellKeeper asks you to shut down your Mac, or put it to sleep, unplugged, and to plug it in again after the time shown."
        case .entered(.plugIn):
            return "Calibration: step 6 (plug in) began; CellKeeper asks you to plug in your Mac."
        case .entered(.finalCharge):
            return "Calibration: step 7 (final charge to full) began: CellKeeper asks for macOS's Charge Limit at 100% once more."
        case .returning(let step):
            return "Calibration: step \(step.rawValue) (\(step)) is done; CellKeeper asks for its own limit again and waits for macOS to confirm it."
        case .returnConfirmed:
            return "Calibration: macOS confirms CellKeeper's own limit again."
        case .earlyUnplug(let short):
            return "Calibration: your Mac was unplugged during the rest at 100%\(short ? ", before its 2 hours, so the rest is recorded as short" : ""). The drain begins now."
        case .earlyPlugIn:
            return "Calibration: your Mac was plugged in before the time shown, so the rest at the bottom is recorded as short. The final charge begins now."
        case .restShort:
            return nil
        case .restAgainRequested:
            return "Calibration: your Mac woke before the time shown; CellKeeper asks once to rest it again until then."
        case .sleepRecorded(let percent, let isOnBattery):
            return "Calibration: your Mac is going to sleep at \(percent.map { "\($0)%" } ?? "an unknown charge")\(isOnBattery ? " on battery power" : " on power")."
        case .wakeRecorded:
            return "Calibration: your Mac woke from sleep."
        case .restResult(let result):
            return "Calibration: the rest at the bottom: \(restResult(result, now: Date()))."
        case .continued:
            return "Calibration continued at your request."
        case .topRestRestarted:
            return "Calibration: the rest at 100% starts again, for 2 hours: CellKeeper cannot know whether your Mac stayed plugged in while it was not running."
        }
    }

    // MARK: - Times

    /// A time as the requests show it: the time of day, with the weekday
    /// when it is not on `now`'s day in `timeZone`, or always with
    /// `alwaysWithDay`.
    public static func clockTime(_ date: Date, now: Date, timeZone: TimeZone = .current, locale: Locale = .current, alwaysWithDay: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle.dateTime.hour().minute()
        if alwaysWithDay || !calendar.isDate(date, inSameDayAs: now) {
            style = style.weekday(.abbreviated).day().month(.abbreviated)
        }
        style.timeZone = timeZone
        return date.formatted(style.locale(locale))
    }
}
