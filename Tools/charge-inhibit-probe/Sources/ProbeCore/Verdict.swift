import Foundation

/// The thresholds the verdict applies. They are printed in every report.
public struct Criteria: Sendable, Equatable {
    /// Charging must stop within this many seconds of the assertion's
    /// creation to be attributed to it.
    public var stopWindow: Double
    /// Charging must resume within this many seconds of the release for an
    /// `inhibited` verdict.
    public var resumeWindow: Double
    /// A battery current at or below this many mA counts as not charging.
    public var currentThreshold: Int
    /// A gap between consecutive readings longer than this (the Mac slept,
    /// or the probe was stopped) makes the run inconclusive.
    public var maxReadingGap: Double
    /// The baseline needs at least this many readings.
    public var minimumBaselineReadings: Int

    public init(
        stopWindow: Double = 30,
        resumeWindow: Double = 60,
        currentThreshold: Int = 50,
        maxReadingGap: Double = 10,
        minimumBaselineReadings: Int = 5
    ) {
        self.stopWindow = stopWindow
        self.resumeWindow = resumeWindow
        self.currentThreshold = currentThreshold
        self.maxReadingGap = maxReadingGap
        self.minimumBaselineReadings = minimumBaselineReadings
    }

    public static let standard = Criteria()
}

/// What one usable reading says about charging.
public enum ChargeState: Sendable, Equatable {
    /// macOS reports charging and the battery current is above the threshold.
    case charging
    /// macOS reports not charging and the current is at or below the threshold.
    case stopped
    /// The charging flag and the current disagree (for example while the
    /// current is still falling).
    case mixed
}

/// Why a reading cannot be used. Any of these while the assertion matters
/// makes the run inconclusive.
public enum ReadingProblem: Sendable, Equatable, CustomStringConvertible {
    /// The Mac reported battery power: the adapter was unplugged, or macOS
    /// stopped drawing from it.
    case onBattery
    /// A value the verdict needs could not be read.
    case unreadable
    /// The battery reached 100% or macOS reports it charged.
    case full

    public var description: String {
        switch self {
        case .onBattery: "the Mac was on battery power (unplugged?)"
        case .unreadable: "the battery's state could not be read"
        case .full: "the battery reached 100% or was reported charged"
        }
    }
}

/// What happened during a run, as the verdict needs it.
public struct ProbeRun: Sendable, Equatable {
    public struct Creation: Sendable, Equatable {
        /// When `IOPMAssertionCreateWithProperties` returned, in run seconds.
        public var time: Double
        /// Its IOReturn.
        public var result: Int32

        public init(time: Double, result: Int32) {
            self.time = time
            self.result = result
        }
    }

    public var samples: [Sample]
    /// Nil when no assertion was attempted (the baseline already failed).
    public var creation: Creation?
    /// When the probe released the assertion, in run seconds; nil if it
    /// never did.
    public var releasedAt: Double?

    public init(samples: [Sample], creation: Creation?, releasedAt: Double?) {
        self.samples = samples
        self.creation = creation
        self.releasedAt = releasedAt
    }
}

/// The result of a run.
public enum Verdict: Sendable, Equatable {
    /// Charging stopped within the stop window of the creation, stayed
    /// stopped while held, on AC power, and resumed within the resume window
    /// of the release.
    case inhibited(stoppedAfter: Double, resumedAfter: Double)
    /// As `inhibited`, but charging resumed later than the resume window.
    case inhibitedResumedLate(stoppedAfter: Double, resumedAfter: Double)
    /// Charging stopped, and had not resumed by the end of the readings.
    case inhibitedDidNotResume(stoppedAfter: Double, watchedFor: Double)
    /// The assertion was created, and charging continued while it was held.
    case noEffect
    /// `IOPMAssertionCreateWithProperties` did not return success.
    case refused(result: Int32)
    /// The run cannot decide; the reason says why.
    case inconclusive(reason: String)

    /// The verdict's name, as printed in the report.
    public var title: String {
        switch self {
        case .inhibited: "inhibited"
        case .inhibitedResumedLate: "inhibited, resumed late"
        case .inhibitedDidNotResume: "inhibited, did not resume"
        case .noEffect: "no effect"
        case .refused: "refused"
        case .inconclusive: "inconclusive"
        }
    }

    /// The probe's exit status for this verdict.
    public var exitStatus: Int32 {
        switch self {
        case .inhibited, .inhibitedResumedLate, .noEffect, .refused: 0
        case .inconclusive: 2
        case .inhibitedDidNotResume: 3
        }
    }

    /// What the verdict means, for the owner.
    public func explanation(criteria: Criteria = .standard) -> String {
        switch self {
        case let .inhibited(stopped, resumed):
            """
            Charging stopped \(seconds(stopped)) after the assertion was created, \
            stayed stopped while it was held, and resumed \(seconds(resumed)) after \
            it was released, all on AC power. On this Mac, macOS build and \
            firmware, the ChargeInhibit assertion stops charging and releasing \
            it lets charging resume.
            """
        case let .inhibitedResumedLate(stopped, resumed):
            """
            Charging stopped \(seconds(stopped)) after the assertion was created \
            and stayed stopped while it was held, but resumed only \
            \(seconds(resumed)) after it was released, later than the \
            \(seconds(criteria.resumeWindow)) window. The assertion stops \
            charging; the slow resume needs a second look before anything is \
            built on it.
            """
        case let .inhibitedDidNotResume(stopped, watched):
            """
            Charging stopped \(seconds(stopped)) after the assertion was created, \
            and had not resumed \(seconds(watched)) after it was released. When \
            the probe exits, powerd releases every assertion the probe still \
            owns (Apple's published source). Follow the recovery steps now: run \
            `pmset -g assertions` and check that no ChargeInhibit is listed; \
            unplug the adapter and plug it back in; if charging still does not \
            resume, restart the Mac (docs/safety.md, "If charging does not \
            resume"). Then send this report to the lead.
            """
        case .noEffect:
            """
            powerd accepted the assertion, and charging continued while it was \
            held. On this Mac, macOS build and firmware, ChargeInhibit does not \
            stop charging.
            """
        case let .refused(result):
            """
            powerd refused the assertion (IOReturn \(IOReturnName.describe(result))). \
            Nothing was held, and charging was not affected.
            """
        case let .inconclusive(reason):
            """
            The run cannot decide: \(reason). Nothing about the assertion is \
            concluded from it. Fix the condition and run the probe again.
            """
        }
    }

    /// Classifies a run. Pure: depends only on its arguments.
    public static func evaluate(_ run: ProbeRun, criteria: Criteria = .standard) -> Verdict {
        let samples = run.samples.sorted { $0.time < $1.time }
        let baseline = samples.filter { $0.phase == .baseline }
        if let problem = baselineProblem(baseline, criteria: criteria) {
            return .inconclusive(reason: problem)
        }
        guard let creation = run.creation else {
            return .inconclusive(reason: "the assertion was not created")
        }
        guard creation.result == 0 else {
            return .refused(result: creation.result)
        }
        guard let releasedAt = run.releasedAt else {
            return .inconclusive(reason: "the probe did not release the assertion itself")
        }
        if let gap = largestGap(samples: samples, events: [creation.time, releasedAt]),
           gap.length > criteria.maxReadingGap {
            return .inconclusive(reason: """
                there was a gap of \(seconds(gap.length)) between readings at \
                +\(seconds(gap.start)) (longer than \(seconds(criteria.maxReadingGap))); \
                the Mac may have slept
                """)
        }

        // While held.
        let held = samples.filter { $0.phase == .held }
        for sample in held {
            if let problem = problem(of: sample) {
                return .inconclusive(reason: """
                    \(problem) \(seconds(sample.time - creation.time)) after the \
                    assertion was created, while it was held
                    """)
            }
        }
        guard let last = held.last, last.time - creation.time >= criteria.stopWindow else {
            return .inconclusive(reason: """
                the readings while the assertion was held cover less than \
                \(seconds(criteria.stopWindow))
                """)
        }
        guard let firstStop = held.first(where: { state(of: $0, criteria: criteria) == .stopped }) else {
            if held.allSatisfy({ state(of: $0, criteria: criteria) == .charging }) {
                return .noEffect
            }
            return .inconclusive(reason: """
                while the assertion was held, charging never clearly stopped, but \
                the charging flag and the battery current disagreed in some readings
                """)
        }
        let stoppedAfter = firstStop.time - creation.time
        guard stoppedAfter <= criteria.stopWindow else {
            return .inconclusive(reason: """
                charging stopped only \(seconds(stoppedAfter)) after the assertion \
                was created, later than \(seconds(criteria.stopWindow)), so the stop \
                cannot be attributed to it
                """)
        }
        if let restart = held.first(where: { $0.time > firstStop.time && state(of: $0, criteria: criteria) == .charging }) {
            return .inconclusive(reason: """
                charging stopped \(seconds(stoppedAfter)) after the assertion was \
                created but started again \(seconds(restart.time - creation.time)) \
                after it, while it was still held
                """)
        }

        // After the release.
        let after = samples.filter { $0.phase == .after }
        for sample in after {
            if let problem = problem(of: sample) {
                return .inconclusive(reason: """
                    charging stopped \(seconds(stoppedAfter)) after the assertion was \
                    created, but \(problem) \(seconds(sample.time - releasedAt)) after \
                    the release, before charging resumed
                    """)
            }
            if state(of: sample, criteria: criteria) == .charging {
                let resumedAfter = sample.time - releasedAt
                return resumedAfter <= criteria.resumeWindow
                    ? .inhibited(stoppedAfter: stoppedAfter, resumedAfter: resumedAfter)
                    : .inhibitedResumedLate(stoppedAfter: stoppedAfter, resumedAfter: resumedAfter)
            }
        }
        let watched = (after.last?.time ?? releasedAt) - releasedAt
        guard watched >= criteria.resumeWindow else {
            return .inconclusive(reason: """
                charging stopped \(seconds(stoppedAfter)) after the assertion was \
                created, but the readings after the release end \(seconds(watched)) \
                after it, before the \(seconds(criteria.resumeWindow)) window was over
                """)
        }
        return .inhibitedDidNotResume(stoppedAfter: stoppedAfter, watchedFor: watched)
    }

    /// Why the readings before the assertion do not show steady charging on
    /// AC power, or nil if they do. The probe checks this before it creates
    /// the assertion, and creates none if there is a problem.
    public static func baselineProblem(_ baseline: [Sample], criteria: Criteria = .standard) -> String? {
        guard baseline.count >= criteria.minimumBaselineReadings else {
            return "there were only \(baseline.count) readings before the assertion (\(criteria.minimumBaselineReadings) needed)"
        }
        for sample in baseline {
            if let problem = problem(of: sample) {
                return "\(problem) during the baseline, at +\(seconds(sample.time))"
            }
            if state(of: sample, criteria: criteria) != .charging {
                return """
                    macOS was not charging steadily during the baseline: at \
                    +\(seconds(sample.time)) it reported \(chargingSummary(sample))
                    """
            }
        }
        return nil
    }

    /// Why a reading cannot be used, or nil if it can.
    public static func problem(of sample: Sample) -> ReadingProblem? {
        if sample.externalPower == false { return .onBattery }
        guard sample.externalPower == true,
              sample.batteryPresent != false,
              let percent = sample.percent,
              sample.isCharging != nil,
              sample.current != nil
        else { return .unreadable }
        if percent >= 100 || sample.isCharged == true { return .full }
        return nil
    }

    /// What a usable reading says about charging.
    public static func state(of sample: Sample, criteria: Criteria = .standard) -> ChargeState {
        guard let charging = sample.isCharging, let current = sample.current else { return .mixed }
        if charging, current > criteria.currentThreshold { return .charging }
        if !charging, current <= criteria.currentThreshold { return .stopped }
        return .mixed
    }

    struct Gap: Equatable {
        var start: Double
        var length: Double
    }

    /// The longest interval between consecutive moments (readings, creation,
    /// release), from the first reading to the last.
    static func largestGap(samples: [Sample], events: [Double]) -> Gap? {
        let moments = (samples.map(\.time) + events).sorted()
        guard moments.count >= 2 else { return nil }
        var largest = Gap(start: moments[0], length: 0)
        for (earlier, later) in zip(moments, moments.dropFirst()) where later - earlier > largest.length {
            largest = Gap(start: earlier, length: later - earlier)
        }
        return largest
    }

    static func chargingSummary(_ sample: Sample) -> String {
        let flag = sample.isCharging.map { $0 ? "charging" : "not charging" } ?? "charging unknown"
        let current = sample.current.map { "\($0) mA" } ?? "current unknown"
        return "\(flag), \(current)"
    }
}

/// Seconds with one decimal, for reports: "12.0 s".
public func seconds(_ value: Double) -> String {
    String(format: "%.1f s", value)
}
