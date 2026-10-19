import Foundation

/// Everything a run records, and the plain-text report it writes. Pure, so
/// the executable only has to gather the inputs.
public struct Report: Sendable {
    public struct MachineInfo: Sendable, Equatable {
        public var model: String
        public var osVersion: String
        public var osBuild: String
        public var firmware: String

        public init(model: String, osVersion: String, osBuild: String, firmware: String) {
            self.model = model
            self.osVersion = osVersion
            self.osBuild = osBuild
            self.firmware = firmware
        }

        public var line: String {
            "\(model), macOS \(osVersion) (\(osBuild)), system firmware \(firmware)"
        }
    }

    /// Whether `pmset -g assertions` listed the probe's assertion at one
    /// moment of the run.
    public struct ListingCheck: Sendable, Equatable {
        public var moment: String
        public var time: Double
        /// Nil if pmset could not be run.
        public var listed: Bool?
        /// The listing's ChargeInhibit lines, redacted.
        public var lines: [String]

        public init(moment: String, time: Double, listed: Bool?, lines: [String]) {
            self.moment = moment
            self.time = time
            self.listed = listed
            self.lines = lines
        }
    }

    public var startedAt: String
    public var machine: MachineInfo
    public var hold: Int
    public var preconditionChecks: [Check]
    public var run: ProbeRun?
    /// The IOReturn of `IOPMAssertionRelease`, nil if it was not called.
    public var releaseResult: Int32?
    public var listings: [ListingCheck]
    public var verdict: Verdict?
    public var notes: [String]

    public init(
        startedAt: String,
        machine: MachineInfo,
        hold: Int,
        preconditionChecks: [Check],
        run: ProbeRun? = nil,
        releaseResult: Int32? = nil,
        listings: [ListingCheck] = [],
        verdict: Verdict? = nil,
        notes: [String] = []
    ) {
        self.startedAt = startedAt
        self.machine = machine
        self.hold = hold
        self.preconditionChecks = preconditionChecks
        self.run = run
        self.releaseResult = releaseResult
        self.listings = listings
        self.verdict = verdict
        self.notes = notes
    }

    public func render(criteria: Criteria = .standard) -> String {
        var out: [String] = []
        func heading(_ title: String) {
            out.append(title)
            out.append(String(repeating: "-", count: title.count))
        }

        out.append("CellKeeper ChargeInhibit probe report")
        out.append(String(repeating: "=", count: 37))
        out.append("")
        out.append("started:   \(startedAt)")
        out.append("machine:   \(machine.line)")
        out.append("assertion: type \"\(ProbeAssertion.type)\" (private; Apple open source, IOKitUser IOPMLibPrivate.h)")
        out.append("           name \"\(ProbeAssertion.name)\", hold \(hold) s, timeout \(ProbeAssertion.timeout(hold: hold)) s with TimeoutActionRelease")
        out.append("")

        heading("Preconditions")
        out.append(contentsOf: preconditionChecks.map(\.line))
        out.append("")
        out.append(Preconditions.summary(preconditionChecks))
        out.append("")

        if let run {
            heading("Events")
            out.append("baseline: \(run.samples.filter { $0.phase == .baseline }.count) readings before the assertion")
            if let creation = run.creation {
                out.append("+\(seconds(creation.time)): IOPMAssertionCreateWithProperties returned \(IOReturnName.describe(creation.result))")
            } else {
                out.append("no assertion was created")
            }
            if let releasedAt = run.releasedAt {
                let result = releaseResult.map { " returned \(IOReturnName.describe($0))" } ?? ""
                out.append("+\(seconds(releasedAt)): IOPMAssertionRelease\(result)")
            }
            for listing in listings {
                let listed = listing.listed.map { $0 ? "listed" : "did not list" } ?? "could not be run to check"
                out.append("+\(seconds(listing.time)): \(listing.moment): pmset -g assertions \(listed) the probe's ChargeInhibit")
                for line in listing.lines {
                    out.append("    \(line)")
                }
            }
            out.append("")
            heading("Samples (every 2 s)")
            out.append(ReportFormat.sampleHeader)
            for sample in run.samples.sorted(by: { $0.time < $1.time }) {
                out.append(ReportFormat.sampleLine(sample, criteria: criteria))
            }
            out.append("")
            out.append("AC, charging, charged and % come from IOPowerSources; mA, reg.charging, reg.ext,")
            out.append("NotChargingReason (undocumented, not decoded) and SysPowerIn from AppleSmartBattery.")
            out.append("")
        }

        heading("Criteria")
        out.append("not charging: macOS's charging flag is off and the battery current is at most \(criteria.currentThreshold) mA")
        out.append("inhibited: stopped within \(seconds(criteria.stopWindow)) of creation, stayed stopped while held, on AC power,")
        out.append("           and charging resumed within \(seconds(criteria.resumeWindow)) of the release")
        out.append("inconclusive: unplugged, 100% or charged, unreadable, or a gap over \(seconds(criteria.maxReadingGap)) between readings")
        out.append("")

        if let verdict {
            heading("Verdict: \(verdict.title)")
            out.append(Self.wrap(verdict.explanation(criteria: criteria)))
            out.append("")
        }

        if !notes.isEmpty {
            heading("Notes")
            out.append(contentsOf: notes.map { Self.wrap("- \($0)") })
            out.append("")
        }

        out.append("This report contains no serial numbers, user names or home paths.")
        return out.joined(separator: "\n") + "\n"
    }

    /// Wraps text to about `width` columns, keeping existing newlines.
    static func wrap(_ text: String, width: Int = 78) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var wrapped = ""
            var column = 0
            for word in line.split(separator: " ") {
                if column > 0, column + 1 + word.count > width {
                    wrapped += "\n"
                    column = 0
                } else if column > 0 {
                    wrapped += " "
                    column += 1
                }
                wrapped += word
                column += word.count
            }
            return wrapped
        }.joined(separator: "\n")
    }
}
