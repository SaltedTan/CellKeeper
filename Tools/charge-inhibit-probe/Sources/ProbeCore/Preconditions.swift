/// What the precondition rules look at, gathered read-only.
public struct SystemState: Sendable, Equatable {
    /// One reading of the battery (its `time` and `phase` are not used).
    public var reading: Sample
    public var chargeLimit: ChargeLimitReport
    /// Those of ``Preconditions/aldenteHelperPaths`` that exist (checked by
    /// file existence only; their contents are never read).
    public var aldenteHelperFiles: [String]
    /// What `launchctl print system/<AlDente helper label>` reported.
    public var aldenteService: LaunchdServiceState
    /// Running processes that look like AlDente; nil if the process table
    /// could not be listed.
    public var aldenteProcesses: ProcessScan?
    /// File names in ``Preconditions/daemonDirectories`` that suggest a
    /// battery or charge-control tool (names only; contents never read).
    public var otherBatteryDaemons: [String]
    /// Nil if `pmset -g assertions` could not be run.
    public var assertions: AssertionListing?

    public init(
        reading: Sample,
        chargeLimit: ChargeLimitReport,
        aldenteHelperFiles: [String],
        aldenteService: LaunchdServiceState,
        aldenteProcesses: ProcessScan?,
        otherBatteryDaemons: [String],
        assertions: AssertionListing?
    ) {
        self.reading = reading
        self.chargeLimit = chargeLimit
        self.aldenteHelperFiles = aldenteHelperFiles
        self.aldenteService = aldenteService
        self.aldenteProcesses = aldenteProcesses
        self.otherBatteryDaemons = otherBatteryDaemons
        self.assertions = assertions
    }
}

/// One precondition and its result.
public struct Check: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
    }

    public var status: Status
    public var title: String
    public var detail: String

    public init(_ status: Status, _ title: String, _ detail: String) {
        self.status = status
        self.title = title
        self.detail = detail
    }

    /// "PASS  On AC power: …"
    public var line: String { "\(status.rawValue)  \(title): \(detail)" }
}

/// The rules `check` prints and `run` enforces: `run` refuses if any check
/// fails. Anything the verdict depends on that cannot be read fails.
/// Warnings are printed and recorded, and do not stop a run.
public enum Preconditions {
    /// AlDente Pro's (Setapp) helper's launchd label.
    public static let aldenteHelperLabel = "com.apphousekitchen.aldente-pro-setapp.helper"

    /// The AlDente Pro (Setapp) helper's files on this Mac. Only their
    /// existence is checked.
    public static let aldenteHelperPaths = [
        "/Library/PrivilegedHelperTools/\(aldenteHelperLabel)",
        "/Library/LaunchDaemons/\(aldenteHelperLabel).plist",
    ]

    /// Where privileged helpers and launch daemons of third-party tools live.
    /// Only the file names are listed.
    public static let daemonDirectories = ["/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"]

    /// Fragments of a file name that suggest a battery or charge-control
    /// tool. A match is a warning only: the name says nothing certain.
    public static let batteryToolNameFragments = ["aldente", "apphousekit", "batt", "charg", "bclm", "smc"]

    public static let chargeLimitAdvice = "System Settings › Battery › ⓘ next to Charging"

    public static let notChargingAdvice = """
        macOS isn't charging the battery now — raise macOS's Charge Limit to \
        100% (System Settings › Battery) and wait until it charges
        """

    static let aldenteRestartAdvice = """
        restart the Mac only if this check still fails after AlDente has been \
        quit and removed
        """

    /// The names among `fileNames` that suggest a battery tool.
    public static func batteryToolNames(in fileNames: [String]) -> [String] {
        fileNames
            .filter { name in
                let lowered = name.lowercased()
                return batteryToolNameFragments.contains { lowered.contains($0) }
            }
            .sorted()
    }

    public static func evaluate(_ state: SystemState, criteria: Criteria = .standard) -> [Check] {
        let reading = state.reading
        var checks: [Check] = []

        switch reading.externalPower {
        case true?:
            let registry = reading.registryExternalConnected.map { $0 ? "yes" : "no" } ?? "unknown"
            checks.append(Check(.pass, "On AC power", "IOPowerSources reports AC power (AppleSmartBattery ExternalConnected: \(registry))"))
        case false?:
            checks.append(Check(.fail, "On AC power", "the Mac is on battery power: plug in the power adapter"))
        case nil:
            checks.append(Check(.fail, "On AC power", "the power source could not be read"))
        }

        if reading.batteryPresent == true, reading.percent != nil {
            checks.append(Check(.pass, "Battery present", "the internal battery is present"))
        } else {
            checks.append(Check(.fail, "Battery present", "no internal battery was found, or its charge could not be read"))
        }

        if let percent = reading.percent {
            if percent < 95 {
                checks.append(Check(.pass, "Charge below 95%", "\(percent)%"))
            } else {
                checks.append(Check(.fail, "Charge below 95%", "\(percent)%: use the Mac on battery until the charge is below 95% (ideally below 75%)"))
            }
        } else {
            checks.append(Check(.fail, "Charge below 95%", "the charge could not be read"))
        }

        let current = reading.current.map { "\($0) mA" } ?? "unknown"
        switch (reading.isCharging, reading.current) {
        case (nil, _):
            checks.append(Check(.fail, "macOS is charging now", "macOS's charging state could not be read (IOPowerSources reports no \"Is Charging\")"))
        case (_, nil):
            checks.append(Check(.fail, "macOS is charging now", "the battery current could not be read, so charging cannot be confirmed"))
        case (true?, _?) where Verdict.state(of: reading, criteria: criteria) == .charging:
            checks.append(Check(.pass, "macOS is charging now", "IOPowerSources reports charging; battery current \(current)"))
        case (true?, _?):
            checks.append(Check(.fail, "macOS is charging now", """
                macOS reports charging, but the battery current is \(current) \
                (at most \(criteria.currentThreshold) mA counts as not charging): \
                wait until charging is under way
                """))
        case (false?, _?):
            checks.append(Check(.fail, "macOS is charging now", notChargingAdvice))
        }

        if let instant = reading.instantCurrent {
            let average = reading.averageCurrent.map { ", Amperage \($0) mA" } ?? ""
            checks.append(Check(.pass, "Battery current readable", "InstantAmperage \(instant) mA\(average)"))
        } else if let average = reading.averageCurrent {
            checks.append(Check(.pass, "Battery current readable", "Amperage \(average) mA (InstantAmperage not available; the average lags)"))
        } else {
            checks.append(Check(.fail, "Battery current readable", "AppleSmartBattery reports no battery current"))
        }

        switch state.chargeLimit {
        case .noLimit:
            checks.append(Check(.pass, "macOS's Charge Limit is 100%", "pmset -g battlimit: no battery level limits set"))
        case let .limits(limits) where limits.allSatisfy({ $0 >= 100 }):
            checks.append(Check(.pass, "macOS's Charge Limit is 100%", "pmset -g battlimit: 100%"))
        case let .limits(limits):
            let shown = limits.map { "\($0)%" }.joined(separator: ", ")
            checks.append(Check(.fail, "macOS's Charge Limit is 100%", "pmset -g battlimit reports \(shown): set the Charge Limit to 100% (\(chargeLimitAdvice))"))
        case let .unreadable(reason):
            checks.append(Check(.fail, "macOS's Charge Limit is 100%", """
                pmset -g battlimit could not be read (\(reason)), so a native limit \
                that could stop charging during the run cannot be ruled out
                """))
        }

        if state.aldenteHelperFiles.isEmpty {
            checks.append(Check(.pass, "No AlDente helper files", "neither of its helper files exists"))
        } else {
            checks.append(Check(.fail, "No AlDente helper files", """
                found \(state.aldenteHelperFiles.joined(separator: " and ")): remove \
                AlDente completely (its app and its helper)
                """))
        }

        switch state.aldenteService {
        case .notFound:
            checks.append(Check(.pass, "AlDente helper not loaded", "launchctl print system/\(aldenteHelperLabel): could not find service"))
        case .loaded:
            checks.append(Check(.fail, "AlDente helper not loaded", """
                launchd still has system/\(aldenteHelperLabel): remove AlDente's \
                helper; \(aldenteRestartAdvice)
                """))
        case let .unknown(reason):
            checks.append(Check(.fail, "AlDente helper not loaded", """
                launchctl print system/\(aldenteHelperLabel) did not say (\(reason)), \
                so a loaded helper cannot be ruled out
                """))
        }

        switch state.aldenteProcesses {
        case let scan? where !scan.matches.isEmpty:
            checks.append(Check(.fail, "No AlDente process running", """
                running: \(scan.matches.joined(separator: ", ")). Quit AlDente and \
                remove it; \(aldenteRestartAdvice)
                """))
        case let scan? where scan.unreadable > 0:
            checks.append(Check(.fail, "No AlDente process running", """
                \(scan.unreadable) running \(scan.unreadable == 1 ? "process" : "processes") \
                could not be read, so a running AlDente cannot be ruled out; run \
                check again
                """))
        case .some:
            checks.append(Check(.pass, "No AlDente process running", "no executable path or name in the process table matches AlDente"))
        case nil:
            checks.append(Check(.fail, "No AlDente process running", "the process table could not be listed, so a running AlDente cannot be ruled out"))
        }

        if state.otherBatteryDaemons.isEmpty {
            checks.append(Check(.pass, "No other battery-control daemon", "no file name in \(daemonDirectories.joined(separator: " or ")) suggests one"))
        } else {
            checks.append(Check(.warn, "No other battery-control daemon", """
                these names suggest a battery tool: \(state.otherBatteryDaemons.joined(separator: ", ")). \
                If one controls charging, remove it before the test
                """))
        }

        if let assertions = state.assertions {
            if assertions.listsAny {
                checks.append(Check(.fail, "No ChargeInhibit assertion held", """
                    pmset -g assertions lists \(assertions.summary). In Apple's \
                    published source, powerd passes ChargeInhibit on to the battery \
                    only when the first one is raised, so this probe's assertion \
                    would change nothing: quit the process that holds it first
                    """))
            } else {
                checks.append(Check(.pass, "No ChargeInhibit assertion held", "pmset -g assertions lists none"))
            }
        } else {
            checks.append(Check(.fail, "No ChargeInhibit assertion held", "pmset -g assertions could not be run, so an existing ChargeInhibit cannot be ruled out"))
        }

        if let percent = reading.percent, percent < 95 {
            switch percent {
            case 50..<75:
                checks.append(Check(.pass, "Charge in the recommended 50–74%", "\(percent)%"))
            case 75...:
                checks.append(Check(.warn, "Charge in the recommended 50–74%", """
                    \(percent)%: if Optimized Battery Charging is on, macOS may pause \
                    charging near 80% by itself and confuse the result. Turn it off \
                    for the test (\(chargeLimitAdvice)), or start below 75%
                    """))
            default:
                checks.append(Check(.warn, "Charge in the recommended 50–74%", """
                    \(percent)%: the test works, but research note 02 §7 recommends \
                    starting at 50% or more, for more margin if charging did not resume
                    """))
            }
        }

        return checks
    }

    /// "READY …" or "NOT READY …", for the end of `check`.
    public static func summary(_ checks: [Check]) -> String {
        let failures = checks.filter { $0.status == .fail }.count
        let warnings = checks.filter { $0.status == .warn }.count
        let warned = warnings == 0 ? "" : " Read the \(warnings == 1 ? "warning" : "\(warnings) warnings") above."
        if failures == 0 {
            return "READY: every precondition holds; `sudo charge-inhibit-probe run` may be started.\(warned)"
        }
        return "NOT READY: \(failures) \(failures == 1 ? "precondition fails" : "preconditions fail"); `run` would refuse.\(warned)"
    }
}
