import Foundation

/// The assertion the probe creates. Keys and values, other than the type,
/// are the public constants of `IOKit/pwr_mgt/IOPMLib.h`; the type is
/// defined only in Apple's open source (research note 09).
public enum ProbeAssertion {
    /// `kIOPMAssertionTypeInhibitCharging` / `kIOPMChargeInhibitAssertion`
    /// in IOKitUser `pwr_mgt.subproj/IOPMLibPrivate.h`: "Disables battery
    /// charging (requires root to initiate)". `[PRIVATE/UNDOCUMENTED]`.
    public static let type = "ChargeInhibit"
    public static let name = "CellKeeper charge-inhibit probe"
    public static let details = "Owner-run test from CellKeeper's docs/research/09-charge-inhibit-probe.md; released by the probe"
    /// The assertion's timeout exceeds the hold by this much, so powerd
    /// releases it even if the probe stalls.
    public static let timeoutMargin = 30

    public static func timeout(hold: Int) -> Int { hold + timeoutMargin }
}

/// Lines of the report.
public enum ReportFormat {
    /// The column header for ``sampleLine(_:)``.
    public static let sampleHeader =
        "clock          time phase     AC   charging   charged     %  mA instant/avg   reg.charging  reg.ext  NotChargingReason  SysPowerIn mW  state"

    /// One reading as a report line.
    public static func sampleLine(_ sample: Sample, criteria: Criteria = .standard) -> String {
        let state: String
        if let problem = Verdict.problem(of: sample) {
            switch problem {
            case .onBattery: state = "ON BATTERY"
            case .unreadable: state = "UNREADABLE"
            case .full: state = "FULL"
            }
        } else {
            switch Verdict.state(of: sample, criteria: criteria) {
            case .charging: state = "charging"
            case .stopped: state = "stopped"
            case .mixed: state = "mixed"
            }
        }
        let current = "\(int(sample.instantCurrent))/\(int(sample.averageCurrent))"
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
            pad(sample.notChargingReason.map { "0x" + String($0, radix: 16) } ?? "-", 18),
            pad(int(sample.systemPowerIn), 14),
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
