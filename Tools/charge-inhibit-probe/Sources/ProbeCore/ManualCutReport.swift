import Foundation

/// The report of research note 11's manual adapter cut. Pure, so the
/// executable only has to gather the inputs. It says throughout that the
/// cut, the restore and every read-back are owner-confirmed: the probe
/// reads no SMC key and observes neither write.
public struct ManualCutReport: Sendable {
    public var startedAt: String
    public var machine: Report.MachineInfo
    public var hold: Int
    public var preconditionChecks: [Check]
    /// Nil if the probe refused before the owner was asked anything.
    public var flow: ManualCutFlow?
    public var sleepGuard: Report.SleepGuard?
    public var sleepNotices: [ProbeRun.SleepNotice]
    /// The GO line's restore time, as the console showed it ("10:18:02"),
    /// if the cut was marked.
    public var restoreBy: String?
    public var outcome: ManualCutOutcome?
    public var notes: [String]

    public init(
        startedAt: String,
        machine: Report.MachineInfo,
        hold: Int,
        preconditionChecks: [Check],
        flow: ManualCutFlow? = nil,
        sleepGuard: Report.SleepGuard? = nil,
        sleepNotices: [ProbeRun.SleepNotice] = [],
        restoreBy: String? = nil,
        outcome: ManualCutOutcome? = nil,
        notes: [String] = []
    ) {
        self.startedAt = startedAt
        self.machine = machine
        self.hold = hold
        self.preconditionChecks = preconditionChecks
        self.flow = flow
        self.sleepGuard = sleepGuard
        self.sleepNotices = sleepNotices
        self.restoreBy = restoreBy
        self.outcome = outcome
        self.notes = notes
    }

    public func render(criteria: Criteria = .standard) -> String {
        var out: [String] = []
        func heading(_ title: String) {
            out.append(title)
            out.append(String(repeating: "-", count: title.count))
        }

        let title = "CellKeeper manual adapter-cut probe report"
        out.append(title)
        out.append(String(repeating: "=", count: title.count))
        out.append("")
        out.append("started:   \(startedAt)")
        out.append("machine:   \(machine.line)")
        out.append("test:      research note 11's manual adapter cut. The owner reads and writes the SMC key")
        out.append("           CHIE by hand, with an external tool; this probe reads no SMC key, runs no tool,")
        out.append("           and only observes. Hold \(hold) s from the owner's cut mark.")
        out.append("           The cut time, the restore time and every read-back are owner-confirmed, not")
        out.append("           observed by the probe.")
        out.append("")

        if let reason = outcome?.recoveryReason {
            heading("CHECK RECOVERY FIRST")
            out.append(Report.wrap("\(reason) \(ManualCut.recoverySteps)"))
            out.append("")
        }

        heading("Preconditions")
        out.append(contentsOf: preconditionChecks.map(\.line))
        out.append("")
        out.append(Preconditions.manualCutSummary(preconditionChecks))
        out.append("")

        if let refusal = outcome?.refusal {
            out.append(Report.wrap("Refused to start: \(refusal). Nothing has been written."))
            out.append("")
        }

        if let flow {
            heading("The owner's answers (owner-confirmed; the probe observed no read and no write)")
            if flow.answers.isEmpty {
                out.append("none")
            }
            for answer in flow.answers {
                let typed = answer.word.map { "typed \($0)" } ?? "(no answer word)"
                out.append("+\(seconds(answer.time)): \(answer.question.rawValue): \(typed): \(answer.outcome)")
            }
            out.append(Report.wrap("restore written: \(flow.restoreWrittenSummary)"))
            out.append("")

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
            for entry in flow.log {
                out.append(Report.wrap("+\(seconds(entry.time)): \(entry.text)"))
            }
            if let restoreBy {
                out.append("GO line: restore by \(restoreBy)")
            }
            for notice in sleepNotices {
                out.append("+\(seconds(notice.time)): the system sent \(notice.message)")
            }
            let count = { (phase: Sample.Phase) in flow.samples.filter { $0.phase == phase }.count }
            out.append("""
                readings: \(count(.baseline)) baseline, \(count(.preCut)) pre-cut (between the CUT prompt \
                and the cut mark), \(count(.held)) held, \(count(.after)) after
                """)
            out.append("")
            heading("Samples (every 2 s)")
            out.append(ReportFormat.sampleHeader)
            for sample in flow.samples.sorted(by: { $0.time < $1.time }) {
                out.append(ReportFormat.sampleLine(sample, criteria: criteria))
            }
            out.append("")
            out.append("AC, charging, charged and % come from IOPowerSources, adapter from")
            out.append("IOPSCopyExternalPowerAdapterDetails (its Watts only); mA, reg.charging, reg.ext,")
            out.append("raw.ext (AppleRawExternalConnected), NotChargingReason (undocumented, not decoded),")
            out.append("SysPowerIn and upd.age (seconds since the battery's UpdateTime) from AppleSmartBattery.")
            out.append("Phases: held from the owner's cut mark (cutnow), after from the owner's restore")
            out.append("time (restorenow, or read-first 08 or 00).")
            out.append("")
        }

        heading("Criteria")
        out.append(contentsOf: Self.criteriaLines(criteria))
        out.append("")

        if let verdict = outcome?.verdict {
            heading("Verdict: \(verdict.title)")
            out.append(Report.wrap(verdict.manualCutExplanation(criteria: criteria)))
            out.append("")
        }

        if !notes.isEmpty {
            heading("Notes")
            out.append(contentsOf: notes.map { Report.wrap("- \($0)") })
            out.append("")
        }

        out.append("This report contains no serial numbers, user names or home paths.")
        return out.joined(separator: "\n") + "\n"
    }

    /// Note 10's criteria, judged against the owner's cut mark and restore.
    static func criteriaLines(_ criteria: Criteria) -> [String] {
        [
            "(judgment calls, not values from any source; research note 10's, judged against the owner's marks)",
            "charging: on AC power, macOS's charging flag on and the battery current above \(criteria.currentThreshold) mA;",
            "         stopped: on AC power, the flag off and the current from -\(criteria.dischargeThreshold - 1) to \(criteria.currentThreshold) mA;",
            "         discharging: the flag off and the current -\(criteria.dischargeThreshold) mA or lower; anything else disagrees",
            "sustained: \(criteria.sustainedReadings) readings in a row, each at least \(seconds(criteria.minimumSpacing)) after the previous counted one,",
            "           spanning at least \(seconds(criteria.sustainedSpan)), of at least \(criteria.distinctUpdates) battery updates (UpdateTime values);",
            "           an update counts as made after a moment only if its UpdateTime is in a later second",
            "effect: a sustained stop or discharge beginning within \(seconds(criteria.effectWindow)) of the cut mark, from an update",
            "           made after it, every reading from it until the restore time the same; the cut and the",
            "           restore owner-confirmed; then a sustained resume beginning within \(seconds(criteria.resumeWindow)) of the restore time",
            "adapter cut: every discharging reading reports the adapter attached (AppleRawExternalConnected or the",
            "           adapter details; ExternalConnected is not used) and a system power input of at most",
            "           \(criteria.cutPowerInput) mW; otherwise discharging with adapter attached, or inconclusive",
            "no effect: every reading while the cut was held charging, of at least \(criteria.distinctUpdates) updates made after the mark",
            "did not resume: no charging reading in at least \(seconds(criteria.resumeWindow)) after the restore time, over at least",
            "           \(criteria.distinctUpdates) updates made after it",
            "baseline: at least \(ProbeSchedule.baseline) s and \(criteria.distinctUpdates) updates, at most \(ProbeSchedule.baselineLimit) s, all charging, ending at the",
            "           CUT prompt; freshness at the cut: every reading between the CUT prompt and the mark",
            "           charging, no gap over \(seconds(criteria.maxBaselineGap)) up to the mark, the latest update at most",
            "           \(seconds(criteria.maxBaselineUpdateAge)) old at the mark",
            "inconclusive: 100% or charged, unreadable, a battery update older than \(seconds(criteria.maxUpdateAge)) or a charge",
            "           below \(criteria.chargeFloor)% while held, an unconfirmed cut or restore, the read-first steps, a sleep",
            "           notification, a gap over \(seconds(criteria.maxReadingGap)) between readings, or clocks that disagree by more",
            "           than \(seconds(criteria.clockTolerance))",
        ]
    }
}

extension Verdict {
    /// What the verdict means for research note 11's manual adapter cut,
    /// for the owner: the cut and the restore are owner-confirmed, and the
    /// effect is what the readings show.
    public func manualCutExplanation(criteria: Criteria = .standard) -> String {
        let sustained = Self.sustainedNeeded(criteria)
        let confirmed = """
            By the owner's reads, CHIE read back (bytes 08) after the cut and \
            (bytes 00) after the restore; the probe observed neither write.
            """
        let cutInference = """
            That the adapter's power was cut is inferred [INFERRED/UNVERIFIED]: the \
            battery discharged while every reading still reported the adapter \
            attached and a system power input of at most \(criteria.cutPowerInput) mW, \
            from after the cut mark until the restore.
            """
        let powerBack = { (after: Double?) in
            after.map { "Adapter power was back \(seconds($0)) after the restore. " } ?? ""
        }
        let recovery = "Follow the recovery steps now (\(ManualCut.note) §7.1), and send this report to the lead."
        switch self {
        case let .adapterCut(cut, back, resumed):
            return """
                \(confirmed) The Mac ran from its battery from \(seconds(cut)) after the \
                cut mark until the restore, and charging resumed \(seconds(resumed)) \
                after it (each over \(sustained)). \(powerBack(back))\(cutInference) On \
                this Mac, macOS build and firmware, CHIE 08 written by hand then cuts \
                the adapter's power, and CHIE 00 restores it. Confirm that the adapter \
                stayed plugged in.
                """
        case let .adapterCutResumedLate(cut, back, resumed):
            return """
                \(confirmed) The Mac ran from its battery from \(seconds(cut)) after the \
                cut mark until the restore, but charging resumed only \(seconds(resumed)) \
                after it, later than the \(seconds(criteria.resumeWindow)) window. \
                \(powerBack(back))\(cutInference) The slow resume needs a second look \
                before anything is built on it. Confirm that the adapter stayed plugged in.
                """
        case let .inhibited(stopped, resumed), let .inhibitedResumedLate(stopped, resumed):
            return """
                \(confirmed) Charging stopped \(seconds(stopped)) after the cut mark and \
                stayed stopped on AC power until the restore, and resumed \
                \(seconds(resumed)) after it. That is not what the sources report for \
                CHIE (a cut of adapter power, note 11 §3.3), and macOS's own charging \
                and thermal management can also stop charging; it needs a second look.
                """
        case let .inhibitedDidNotResume(stopped, watched):
            return """
                \(confirmed) Charging stopped \(seconds(stopped)) after the cut mark, and \
                had not resumed \(seconds(watched)) after the restore. \(recovery)
                """
        case let .dischargingWithAdapter(discharged, resumed):
            return """
                \(confirmed) The battery discharged from \(seconds(discharged)) after the \
                cut mark until the restore, with the adapter reported attached, and \
                charging resumed \(seconds(resumed)) after it. But in some of those \
                readings the adapter still delivered more than \(criteria.cutPowerInput) mW \
                (or the input could not be read), so the discharge is not attributed to a \
                cut: an adapter too weak for the load, or a high load, looks the same.
                """
        case let .dischargingDidNotResume(discharged, back, watched, looksLikeCut):
            return """
                \(confirmed) The battery discharged from \(seconds(discharged)) after the \
                cut mark, and charging had not resumed \(seconds(watched)) after the \
                restore. \(powerBack(back))The readings while the cut was held \
                \(looksLikeCut ? "looked like an adapter cut" : "did not all look like an adapter cut") \
                (\(criteria.cutPowerInput) mW or less, adapter reported attached). \(recovery)
                """
        case let .noEffect(held):
            return """
                By the owner's read, CHIE read back (bytes 08) after the cut, yet every \
                reading in the \(seconds(held)) after the cut mark showed charging, over \
                at least \(criteria.distinctUpdates) battery updates made after it. No \
                effect was observed during the measured hold on this Mac, macOS build and \
                firmware; read against note 02 §3.4, this firmware may ignore CHIE (for \
                example while a native Charge Limit is on).
                """
        case .refused:
            return "The cut was not accepted. Nothing about the adapter cut is concluded."
        case let .inconclusive(reason):
            return """
                The run cannot decide: \(reason). Nothing about the adapter cut is \
                concluded from it.
                """
        }
    }
}
