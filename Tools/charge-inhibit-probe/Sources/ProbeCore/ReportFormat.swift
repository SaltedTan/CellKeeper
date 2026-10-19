import Foundation

/// The private assertion a run tests, chosen on the command line. Keys and
/// values, other than the type, are the public constants of
/// `IOKit/pwr_mgt/IOPMLib.h`; the types are defined only in Apple's open
/// source, IOKitUser `pwr_mgt.subproj/IOPMLibPrivate.h`
/// (`[PRIVATE/UNDOCUMENTED]`; research notes 09 and 10).
public enum AssertionKind: String, Sendable, Equatable, CaseIterable {
    /// `kIOPMAssertionTypeDisableInflow` / `kIOPMInflowDisableAssertion`:
    /// "Disables AC Power Inflow (requires root to initiate)". Note 10.
    case disableInflow = "disable-inflow"
    /// `kIOPMAssertionTypeInhibitCharging` / `kIOPMChargeInhibitAssertion`:
    /// "Disables battery charging (requires root to initiate)". Note 09.
    case chargeInhibit = "charge-inhibit"

    /// The `AssertType` string.
    public var type: String {
        switch self {
        case .disableInflow: "DisableInflow"
        case .chargeInhibit: "ChargeInhibit"
        }
    }

    /// The `AssertName` the probe gives its assertion; `pmset -g assertions`
    /// shows it, so the probe can tell its own assertion from another.
    public var name: String {
        switch self {
        case .disableInflow: "CellKeeper disable-inflow probe"
        case .chargeInhibit: "CellKeeper charge-inhibit probe"
        }
    }

    /// The research note that describes the test.
    public var note: String {
        switch self {
        case .disableInflow: "docs/research/10-disable-inflow-probe.md"
        case .chargeInhibit: "docs/research/09-charge-inhibit-probe.md"
        }
    }

    public var details: String {
        "Owner-run test from CellKeeper's \(note); released by the probe"
    }

    /// The header constant that defines the type.
    public var constant: String {
        switch self {
        case .disableInflow: "kIOPMAssertionTypeDisableInflow"
        case .chargeInhibit: "kIOPMAssertionTypeInhibitCharging"
        }
    }

    /// The kind whose `AssertType` is `type`, if any.
    public init?(type: String) {
        guard let kind = Self.allCases.first(where: { $0.type == type }) else { return nil }
        self = kind
    }

    /// "charge-inhibit-probe-disable-inflow-20261020-101500.txt". Every name
    /// matches `charge-inhibit-probe-*.txt`, which `.gitignore` covers.
    public func reportFileName(stamp: String) -> String {
        "charge-inhibit-probe-\(rawValue)-\(stamp).txt"
    }
}

/// The probe's power assertions, apart from their type.
public enum ProbeAssertion {
    /// The private assertion's timeout exceeds the hold by this much, so
    /// powerd releases it even if the probe stalls.
    public static let timeoutMargin = 30

    public static func timeout(hold: Int) -> Int { hold + timeoutMargin }

    /// The public idle-sleep assertion the run holds (research note 10 §4).
    public static let idleSleepName = "CellKeeper probe: no idle sleep during the run"

    /// The idle-sleep assertion's timeout: the longest a run can take plus
    /// 120 s, so powerd releases it even if the probe stalls.
    public static func idleSleepTimeout(hold: Int) -> Int {
        ProbeSchedule.longestRun(hold: hold) + 120
    }
}

/// Lines of the report.
public enum ReportFormat {
    /// The column header for ``sampleLine(_:criteria:)``.
    public static let sampleHeader =
        "clock          time phase     AC   charging   charged     %  mA instant/avg   reg.charging  reg.ext  raw.ext  adapter  NotChargingReason  SysPowerIn mW  upd.age  state"

    /// One reading as a report line.
    public static func sampleLine(_ sample: Sample, criteria: Criteria = .standard) -> String {
        let state: String
        if let problem = Verdict.problem(of: sample, batteryAllowed: true) {
            switch problem {
            case .onBattery: state = "ON BATTERY"
            case .unreadable: state = "UNREADABLE"
            case .full: state = "FULL"
            case .belowFloor: state = "BELOW FLOOR"
            case .staleUpdate: state = "STALE"
            }
        } else {
            switch Verdict.state(of: sample, criteria: criteria) {
            case .charging: state = "charging"
            case .stopped: state = "stopped"
            case .discharging: state = sample.externalPower == false ? "discharging, battery power" : "discharging"
            case .mixed: state = "mixed"
            }
        }
        let current = "\(int(sample.instantCurrent))/\(int(sample.averageCurrent))"
        let adapter: String
        switch (sample.adapterAttached, sample.adapterWatts) {
        case (true?, let watts?): adapter = "\(watts) W"
        case (true?, nil): adapter = "yes"
        case (false?, _): adapter = "no"
        case (nil, _): adapter = "-"
        }
        return [
            pad(sample.wallTime ?? "-", 8),
            pad(String(format: "%+.1f", sample.time), 7, right: true),
            pad(sample.phase.rawValue, 9),
            pad(yesNo(sample.externalPower), 4),
            pad(yesNo(sample.isCharging), 10),
            pad(yesNo(sample.isCharged), 7),
            pad(int(sample.percent), 5, right: true),
            "  " + pad(current, 16),
            pad(yesNo(sample.registryIsCharging), 13),
            pad(yesNo(sample.registryExternalConnected), 8),
            pad(yesNo(sample.rawExternalConnected), 8),
            pad(adapter, 8),
            pad(sample.notChargingReason.map { "0x" + String($0, radix: 16) } ?? "-", 18),
            pad(int(sample.systemPowerIn), 14),
            pad(sample.updateAge.map { String(format: "%.0f s", $0) } ?? "-", 8),
            state,
        ].joined(separator: " ")
    }

    static func yesNo(_ value: Bool?) -> String {
        value.map { $0 ? "yes" : "no" } ?? "-"
    }

    static func int(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return right ? padding + text : text + padding
    }
}
