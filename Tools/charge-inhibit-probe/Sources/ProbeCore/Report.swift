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
        public var listing: AssertionListing?

        public init(moment: String, time: Double, listing: AssertionListing?) {
            self.moment = moment
            self.time = time
            self.listing = listing
        }

        /// Whether the probe's assertion of `kind` was listed; nil if pmset
        /// could not be run.
        public func listed(_ kind: AssertionKind) -> Bool? { listing?.listsProbe(kind) }
    }

    /// The run's public idle-sleep assertion and its sleep notifications.
    public struct SleepGuard: Sendable, Equatable {
        /// Whether `IORegisterForSystemPower` registered the probe.
        public var registered: Bool
        /// When the idle-sleep assertion was created, and its IOReturn; nil
        /// if it was not attempted.
        public var created: (time: Double, result: Int32)?
        /// When it was released, and the IOReturn; nil if it was not.
        public var released: (time: Double, result: Int32)?

        public init(registered: Bool, created: (time: Double, result: Int32)? = nil, released: (time: Double, result: Int32)? = nil) {
            self.registered = registered
            self.created = created
            self.released = released
        }

        public static func == (lhs: SleepGuard, rhs: SleepGuard) -> Bool {
            lhs.registered == rhs.registered
                && lhs.created?.time == rhs.created?.time && lhs.created?.result == rhs.created?.result
                && lhs.released?.time == rhs.released?.time && lhs.released?.result == rhs.released?.result
        }
    }

    public var assertion: AssertionKind
    public var startedAt: String
    public var machine: MachineInfo
    public var hold: Int
    public var preconditionChecks: [Check]
    public var run: ProbeRun?
    public var listings: [ListingCheck]
    public var sleepGuard: SleepGuard?
    public var verdict: Verdict?
    public var notes: [String]

    public init(
        assertion: AssertionKind,
        startedAt: String,
        machine: MachineInfo,
        hold: Int,
        preconditionChecks: [Check],
        run: ProbeRun? = nil,
        listings: [ListingCheck] = [],
        sleepGuard: SleepGuard? = nil,
        verdict: Verdict? = nil,
        notes: [String] = []
    ) {
        self.assertion = assertion
        self.startedAt = startedAt
        self.machine = machine
        self.hold = hold
        self.preconditionChecks = preconditionChecks
        self.run = run
        self.listings = listings
        self.sleepGuard = sleepGuard
        self.verdict = verdict
        self.notes = notes
    }

    /// Whether the report must open with the recovery steps: an assertion
    /// was held, and either its release is not confirmed (no release, a
    /// failed one, or one `pmset -g assertions` still listed or could not
    /// check) or the last reading does not show charging on adapter power.
    public func needsRecovery(criteria: Criteria = .standard) -> Bool {
        recoveryReason(criteria: criteria) != nil
    }

    /// Why the report opens with the recovery steps, or nil.
    func recoveryReason(criteria: Criteria) -> String? {
        guard let run, run.creation?.result == 0 else { return nil }
        let type = assertion.type
        guard let release = run.release else {
            return "The probe did not release its \(type) assertion itself."
        }
        if release.result != 0 {
            return "For the \(type) assertion, \(ReleaseWording.failed(attempts: release.attempts, result: release.result))."
        }
        if release.stillListed != false {
            return """
                The release of the \(type) assertion is not confirmed: pmset -g assertions \
                \(release.stillListed == true ? "still listed it" : "could not be run to check") — \
                powerd releases it at its timeout or when the probe exits.
                """
        }
        guard let last = run.samples.max(by: { $0.time < $1.time }), Verdict.isChargingOnAdapter(last, criteria: criteria) else {
            return "The last reading did not show charging on adapter power."
        }
        return nil
    }

    public func render(criteria: Criteria = .standard) -> String {
        var out: [String] = []
        func heading(_ title: String) {
            out.append(title)
            out.append(String(repeating: "-", count: title.count))
        }
        let type = assertion.type

        let title = "CellKeeper \(type) probe report"
        out.append(title)
        out.append(String(repeating: "=", count: title.count))
        out.append("")
        out.append("started:   \(startedAt)")
        out.append("machine:   \(machine.line)")
        out.append("assertion: type \"\(type)\" (private; Apple open source, IOKitUser IOPMLibPrivate.h)")
        out.append("           name \"\(assertion.name)\", hold \(hold) s, timeout \(ProbeAssertion.timeout(hold: hold)) s with TimeoutActionRelease")
        out.append("")

        if let reason = recoveryReason(criteria: criteria) {
            heading("CHECK RECOVERY FIRST")
            out.append(Self.wrap("\(reason) \(Verdict.recoverySteps(assertion))"))
            out.append("")
        }

        heading("Preconditions")
        out.append(contentsOf: preconditionChecks.map(\.line))
        out.append("")
        out.append(Preconditions.summary(preconditionChecks, assertion: assertion))
        out.append("")

        if let run {
            heading("Events")
            if let sleepGuard {
                out.append("sleep notifications: \(sleepGuard.registered ? "registered (IORegisterForSystemPower)" : "could not be registered")")
                if let created = sleepGuard.created {
                    out.append("+\(seconds(created.time)): IOPMAssertionCreateWithProperties (PreventUserIdleSystemSleep) returned \(IOReturnName.describe(created.result))")
                }
                if let released = sleepGuard.released {
                    out.append("+\(seconds(released.time)): IOPMAssertionRelease (PreventUserIdleSystemSleep) returned \(IOReturnName.describe(released.result))")
                }
            }
            out.append("baseline: \(run.samples.filter { $0.phase == .baseline }.count) readings before the assertion")
            if let creation = run.creation {
                out.append("+\(seconds(creation.time)): IOPMAssertionCreateWithProperties (\(type)) returned \(IOReturnName.describe(creation.result))")
            } else {
                out.append("no \(type) assertion was created")
            }
            if let release = run.release {
                let attempts = release.attempts == 1 ? "" : " (after \(release.attempts) attempts)"
                out.append("+\(seconds(release.time)): IOPMAssertionRelease (\(type)) returned \(IOReturnName.describe(release.result))\(attempts)")
            }
            for check in listings {
                let listed = check.listed(assertion).map { $0 ? "listed" : "did not list" } ?? "could not be run to check"
                out.append("+\(seconds(check.time)): \(check.moment): pmset -g assertions \(listed) the probe's \(type)")
                for holder in check.listing?.holders ?? [] {
                    out.append("    \(holder.description)")
                }
            }
            for notice in run.sleepNotices {
                out.append("+\(seconds(notice.time)): the system sent \(notice.message)")
            }
            out.append("")
            heading("Samples (every 2 s)")
            out.append(ReportFormat.sampleHeader)
            for sample in run.samples.sorted(by: { $0.time < $1.time }) {
                out.append(ReportFormat.sampleLine(sample, criteria: criteria))
            }
            out.append("")
            out.append("AC, charging, charged and % come from IOPowerSources, adapter from")
            out.append("IOPSCopyExternalPowerAdapterDetails (its Watts only); mA, reg.charging, reg.ext,")
            out.append("raw.ext (AppleRawExternalConnected), NotChargingReason (undocumented, not decoded),")
            out.append("SysPowerIn and upd.age (seconds since the battery's UpdateTime) from AppleSmartBattery.")
            out.append("")
        }

        heading("Criteria")
        out.append("(judgment calls, not values from any source)")
        out.append("charging: on AC power, macOS's charging flag on and the battery current above \(criteria.currentThreshold) mA;")
        out.append("         stopped: on AC power, the flag off and the current from -\(criteria.dischargeThreshold - 1) to \(criteria.currentThreshold) mA;")
        out.append("         discharging: the flag off and the current -\(criteria.dischargeThreshold) mA or lower; anything else disagrees")
        out.append("sustained: \(criteria.sustainedReadings) readings in a row, each at least \(seconds(criteria.minimumSpacing)) after the previous counted one,")
        out.append("           spanning at least \(seconds(criteria.sustainedSpan)), of at least \(criteria.distinctUpdates) battery updates (UpdateTime values);")
        out.append("           closer readings are not counted, a contradicting one breaks the run; an update counts as")
        out.append("           made after a moment only if its UpdateTime is in a later second")
        out.append("effect: a sustained stop or discharge beginning within \(seconds(criteria.effectWindow)) of creation, from an update made")
        out.append("           after it, every reading after it the same until the release; the release accepted and")
        out.append("           no longer listed; then a sustained resume beginning within \(seconds(criteria.resumeWindow)) of the release")
        out.append("adapter cut: every discharging reading reports the adapter attached and a system power input of")
        out.append("           at most \(criteria.cutPowerInput) mW; otherwise discharging with adapter attached, or inconclusive")
        out.append("no effect: every reading while held charging, of at least \(criteria.distinctUpdates) updates made after creation")
        out.append("did not resume: no charging reading in at least \(seconds(criteria.resumeWindow)) after the release, over at least")
        out.append("           \(criteria.distinctUpdates) updates made after it")
        out.append("baseline: at least \(ProbeSchedule.baseline) s and \(criteria.distinctUpdates) updates, at most \(ProbeSchedule.baselineLimit) s, all charging; its latest")
        out.append("           update at most \(seconds(criteria.maxBaselineUpdateAge)) old at creation")
        out.append("inconclusive: 100% or charged, unreadable, a battery update older than \(seconds(criteria.maxUpdateAge)) or a charge")
        out.append("           below \(criteria.chargeFloor)% while held, a failed or unconfirmed release, a sleep notification, a gap over")
        out.append("           \(seconds(criteria.maxReadingGap)) between readings, or clocks that disagree by more than \(seconds(criteria.clockTolerance))")
        out.append("")

        if let verdict {
            heading("Verdict: \(verdict.title)")
            out.append(Self.wrap(verdict.explanation(assertion: assertion, criteria: criteria)))
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
