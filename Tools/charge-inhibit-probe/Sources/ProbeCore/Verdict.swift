import Foundation

/// The thresholds the verdict applies. They are judgment calls, not values
/// from any source, and are printed in every report.
public struct Criteria: Sendable, Equatable {
    /// Charging must stop within this many seconds of the assertion's
    /// creation to be attributed to it.
    public var stopWindow: Double
    /// Charging must resume within this many seconds of the release for an
    /// `inhibited` verdict.
    public var resumeWindow: Double
    /// A battery current at or below this many mA counts as not charging.
    public var currentThreshold: Int
    /// A stop, and a resume, count only when this many counted readings in
    /// a row agree (N = 5)…
    public var sustainedReadings: Int
    /// …each at least this many seconds after the previous counted one
    /// (closer readings are ignored for counting, but a contradicting one
    /// still breaks the run)…
    public var minimumSpacing: Double
    /// …spanning at least this many seconds from the first to the last
    /// counted reading: (N − 1) × 2 s = 8 s.
    public var sustainedSpan: Double
    /// A gap between consecutive readings longer than this (the Mac slept,
    /// or the probe was stopped) makes the run inconclusive.
    public var maxReadingGap: Double
    /// The baseline needs at least this many readings…
    public var minimumBaselineReadings: Int
    /// …spanning this many seconds from the first to the last…
    public var baselineDuration: ClosedRange<Double>
    /// …with no gap longer than this between readings, nor between the last
    /// reading and the assertion's creation.
    public var maxBaselineGap: Double

    public init(
        stopWindow: Double = 30,
        resumeWindow: Double = 60,
        currentThreshold: Int = 50,
        sustainedReadings: Int = 5,
        minimumSpacing: Double = 1.5,
        sustainedSpan: Double = 8,
        maxReadingGap: Double = 10,
        minimumBaselineReadings: Int = 5,
        baselineDuration: ClosedRange<Double> = 18...24,
        maxBaselineGap: Double = 4
    ) {
        self.stopWindow = stopWindow
        self.resumeWindow = resumeWindow
        self.currentThreshold = currentThreshold
        self.sustainedReadings = sustainedReadings
        self.minimumSpacing = minimumSpacing
        self.sustainedSpan = sustainedSpan
        self.maxReadingGap = maxReadingGap
        self.minimumBaselineReadings = minimumBaselineReadings
        self.baselineDuration = baselineDuration
        self.maxBaselineGap = maxBaselineGap
    }

    public static let standard = Criteria()
}

/// What one usable reading says about charging.
public enum ChargeState: Sendable, Equatable {
    /// macOS reports charging and the battery current is above the threshold.
    case charging
    /// macOS reports not charging and the current is at or below the threshold.
    case stopped
    /// The charging flag and the current disagree.
    case mixed
}

/// A run of readings in one state, counted as the verdict counts them: a
/// reading counts only if it is at least `Criteria.minimumSpacing` after the
/// previous counted one; closer readings are ignored. Callers end the run on
/// a contradicting reading.
public struct SustainedRun: Sendable, Equatable {
    public private(set) var first: Sample
    public private(set) var lastCounted: Sample
    public private(set) var counted: Int

    public init(first: Sample) {
        self.first = first
        lastCounted = first
        counted = 1
    }

    /// Counts `sample` if it is far enough after the last counted reading;
    /// otherwise ignores it.
    public mutating func add(_ sample: Sample, criteria: Criteria = .standard) {
        guard sample.time - lastCounted.time >= criteria.minimumSpacing else { return }
        lastCounted = sample
        counted += 1
    }

    /// Seconds from the first to the last counted reading.
    public var span: Double { lastCounted.time - first.time }

    /// At least `sustainedReadings` counted readings spanning at least
    /// `sustainedSpan`.
    public func isSustained(criteria: Criteria = .standard) -> Bool {
        counted >= criteria.sustainedReadings && span >= criteria.sustainedSpan
    }
}

/// What the readings after the release show so far.
public enum ResumeAnalysis: Sendable, Equatable {
    /// Charging resumed: a sustained run of charging readings, from `start`.
    case resumed(start: Sample)
    /// A reading could not be used before charging had resumed.
    case problem(Sample, ReadingProblem)
    /// No sustained resume yet; whether any reading showed charging.
    case pending(sawCharging: Bool)
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
        /// The assertion's `TimeoutSeconds`.
        public var timeout: Int

        public init(time: Double, result: Int32, timeout: Int = ProbeAssertion.timeout(hold: Command.defaultHold)) {
            self.time = time
            self.result = result
            self.timeout = timeout
        }
    }

    public struct Release: Sendable, Equatable {
        /// When the probe first tried to release the assertion, in run seconds.
        public var time: Double
        /// The IOReturn of the last `IOPMAssertionRelease` attempt.
        public var result: Int32
        public var attempts: Int
        /// Whether `pmset -g assertions` still listed the probe's assertion
        /// after the release; nil if it could not be checked.
        public var stillListed: Bool?

        public init(time: Double, result: Int32, attempts: Int = 1, stillListed: Bool?) {
            self.time = time
            self.result = result
            self.attempts = attempts
            self.stillListed = stillListed
        }
    }

    public var samples: [Sample]
    /// Nil when no assertion was attempted.
    public var creation: Creation?
    /// Nil if the probe never tried to release the assertion.
    public var release: Release?

    public init(samples: [Sample], creation: Creation?, release: Release?) {
        self.samples = samples
        self.creation = creation
        self.release = release
    }
}

/// The result of a run.
public enum Verdict: Sendable, Equatable {
    /// Charging stopped within the stop window of the creation, stayed
    /// stopped while held, on AC power, and resumed within the resume window
    /// of a confirmed release.
    case inhibited(stoppedAfter: Double, resumedAfter: Double)
    /// As `inhibited`, but charging resumed later than the resume window.
    case inhibitedResumedLate(stoppedAfter: Double, resumedAfter: Double)
    /// Charging stopped, and had not resumed by the end of the readings.
    case inhibitedDidNotResume(stoppedAfter: Double, watchedFor: Double)
    /// The assertion was created, and every reading while it was held showed
    /// charging.
    case noEffect(heldFor: Double)
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
        case .noEffect: "no effect observed"
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
        let sustained = Self.sustainedNeeded(criteria)
        switch self {
        case let .inhibited(stopped, resumed):
            return """
                Charging stopped \(seconds(stopped)) after the assertion was created, \
                stayed stopped in every reading while it was held, and resumed \
                \(seconds(resumed)) after a confirmed release (each over \(sustained)), \
                all on AC power. On this Mac, macOS build and firmware, the \
                ChargeInhibit assertion stops charging and releasing it lets \
                charging resume.
                """
        case let .inhibitedResumedLate(stopped, resumed):
            return """
                Charging stopped \(seconds(stopped)) after the assertion was created \
                and stayed stopped while it was held, but resumed only \
                \(seconds(resumed)) after a confirmed release, later than the \
                \(seconds(criteria.resumeWindow)) window. The assertion stops \
                charging; the slow resume needs a second look before anything is \
                built on it.
                """
        case let .inhibitedDidNotResume(stopped, watched):
            return """
                Charging stopped \(seconds(stopped)) after the assertion was created, \
                and had not resumed \(seconds(watched)) after its release, although \
                powerd accepted the release and no longer listed the assertion. \
                Follow the recovery steps now: run `pmset -g assertions` and check \
                that no ChargeInhibit is listed; unplug the adapter and plug it back \
                in; quit any battery tool; if charging still does not resume, \
                restart the Mac (docs/safety.md, "If charging does not resume"). \
                Then send this report to the lead.
                """
        case let .noEffect(held):
            return """
                powerd accepted the assertion, and every reading in the \
                \(seconds(held)) it was held showed charging. No effect was observed \
                during the measured hold on this Mac, macOS build and firmware.
                """
        case let .refused(result):
            return """
                powerd refused the assertion (IOReturn \(IOReturnName.describe(result))). \
                Nothing was held, and charging was not affected.
                """
        case let .inconclusive(reason):
            return """
                The run cannot decide: \(reason). Nothing about the assertion is \
                concluded from it.
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
        if let last = baseline.last, creation.time - last.time > criteria.maxBaselineGap {
            return .inconclusive(reason: """
                the assertion was created \(seconds(creation.time - last.time)) after \
                the last baseline reading (more than \(seconds(criteria.maxBaselineGap)))
                """)
        }
        guard let release = run.release else {
            return .inconclusive(reason: "the probe did not release the assertion itself")
        }
        if let problem = releaseProblem(release, creation: creation) {
            return .inconclusive(reason: problem)
        }
        if let gap = largestGap(samples: samples, events: [creation.time, release.time]),
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
        let states = held.map { state(of: $0, criteria: criteria) }
        guard let stopIndex = states.firstIndex(of: .stopped) else {
            if states.allSatisfy({ $0 == .charging }) {
                return .noEffect(heldFor: last.time - creation.time)
            }
            return .inconclusive(reason: """
                while the assertion was held, charging never clearly stopped, but \
                the charging flag and the battery current disagreed in some readings
                """)
        }
        let firstStop = held[stopIndex]
        let stoppedAfter = firstStop.time - creation.time
        guard stoppedAfter <= criteria.stopWindow else {
            return .inconclusive(reason: """
                charging stopped only \(seconds(stoppedAfter)) after the assertion \
                was created, later than \(seconds(criteria.stopWindow)), so the stop \
                cannot be attributed to it
                """)
        }
        var stopRun = SustainedRun(first: firstStop)
        for index in held.indices.dropFirst(stopIndex + 1) {
            guard states[index] == .stopped else {
                let at = seconds(held[index].time - creation.time)
                return .inconclusive(reason: states[index] == .charging
                    ? """
                        charging stopped \(seconds(stoppedAfter)) after the assertion was \
                        created but started again \(at) after it, while it was still held
                        """
                    : """
                        charging stopped \(seconds(stoppedAfter)) after the assertion was \
                        created, but \(at) after it the charging flag and the battery \
                        current disagreed (\(chargingSummary(held[index]))), while it was \
                        still held
                        """)
            }
            stopRun.add(held[index], criteria: criteria)
        }
        guard stopRun.isSustained(criteria: criteria) else {
            return .inconclusive(reason: """
                charging stopped \(seconds(stoppedAfter)) after the assertion was \
                created, but only \(stopRun.counted) \(stopRun.counted == 1 ? "reading" : "readings") \
                at least \(seconds(criteria.minimumSpacing)) apart, spanning \
                \(seconds(stopRun.span)), showed it stopped before the release \
                (\(sustainedNeeded(criteria)) needed)
                """)
        }

        // After the release.
        let after = samples.filter { $0.phase == .after }
        let sawCharging: Bool
        switch analyzeResume(after, criteria: criteria) {
        case let .resumed(start):
            let resumedAfter = start.time - release.time
            return resumedAfter <= criteria.resumeWindow
                ? .inhibited(stoppedAfter: stoppedAfter, resumedAfter: resumedAfter)
                : .inhibitedResumedLate(stoppedAfter: stoppedAfter, resumedAfter: resumedAfter)
        case let .problem(sample, problem):
            return .inconclusive(reason: """
                charging stopped \(seconds(stoppedAfter)) after the assertion was \
                created, but \(problem) \(seconds(sample.time - release.time)) after \
                the release, before charging had resumed (\(sustainedNeeded(criteria)))
                """)
        case let .pending(saw):
            sawCharging = saw
        }
        let watched = (after.last?.time ?? release.time) - release.time
        guard watched >= criteria.resumeWindow else {
            return .inconclusive(reason: """
                charging stopped \(seconds(stoppedAfter)) after the assertion was \
                created, but the readings after the release end \(seconds(watched)) \
                after it, before the \(seconds(criteria.resumeWindow)) window was over
                """)
        }
        if sawCharging {
            return .inconclusive(reason: """
                charging stopped \(seconds(stoppedAfter)) after the assertion was \
                created; after the release it charged in some readings, but never in \
                \(criteria.sustainedReadings) readings in a row (\(sustainedNeeded(criteria)))
                """)
        }
        return .inhibitedDidNotResume(stoppedAfter: stoppedAfter, watchedFor: watched)
    }

    /// Looks for a sustained run of charging readings after the release:
    /// a non-charging reading breaks a run; a reading closer than
    /// `minimumSpacing` to the last counted one is ignored. The probe's
    /// watch after the release uses the same function.
    public static func analyzeResume(_ after: [Sample], criteria: Criteria = .standard) -> ResumeAnalysis {
        var run: SustainedRun?
        var sawCharging = false
        for sample in after.sorted(by: { $0.time < $1.time }) {
            if let problem = problem(of: sample) {
                return .problem(sample, problem)
            }
            guard state(of: sample, criteria: criteria) == .charging else {
                run = nil
                continue
            }
            sawCharging = true
            if run == nil {
                run = SustainedRun(first: sample)
            } else {
                run?.add(sample, criteria: criteria)
            }
            if let run, run.isSustained(criteria: criteria) {
                return .resumed(start: run.first)
            }
        }
        return .pending(sawCharging: sawCharging)
    }

    /// Why the assertion must not be created now: the last baseline reading
    /// is missing or more than `maxBaselineGap` old. The probe checks this
    /// immediately before it creates the assertion.
    public static func baselineFreshnessProblem(lastBaselineTime: Double?, now: Double, criteria: Criteria = .standard) -> String? {
        guard let last = lastBaselineTime else { return "there was no baseline reading before the assertion" }
        let age = now - last
        guard age <= criteria.maxBaselineGap else {
            return """
                the last baseline reading was \(seconds(age)) old when the assertion \
                was about to be created (more than \(seconds(criteria.maxBaselineGap))), \
                so nothing was created
                """
        }
        return nil
    }

    /// "5 readings at least 1.5 s apart, spanning at least 8.0 s".
    static func sustainedNeeded(_ criteria: Criteria) -> String {
        """
        \(criteria.sustainedReadings) readings at least \(seconds(criteria.minimumSpacing)) \
        apart, spanning at least \(seconds(criteria.sustainedSpan))
        """
    }

    /// Why the release cannot be trusted, or nil if powerd accepted it and
    /// no longer listed the assertion.
    static func releaseProblem(_ release: ProbeRun.Release, creation: ProbeRun.Creation) -> String? {
        let fallback = """
            powerd releases it at its timeout (\(creation.timeout) s after creation) \
            and when the probe exits; check with `pmset -g assertions` after the \
            probe has exited that no ChargeInhibit is listed
            """
        if release.result != 0 {
            return """
                IOPMAssertionRelease returned \(IOReturnName.describe(release.result)) \
                (\(release.attempts) \(release.attempts == 1 ? "attempt" : "attempts")), \
                so the assertion may have stayed held and what charging did after the \
                release says nothing; \(fallback)
                """
        }
        switch release.stillListed {
        case false?:
            return nil
        case true?:
            return """
                pmset -g assertions still listed the probe's ChargeInhibit after the \
                release, so the release is unconfirmed; \(fallback)
                """
        case nil:
            return """
                pmset -g assertions could not be run after the release, so the \
                release is unconfirmed; \(fallback)
                """
        }
    }

    /// Why the readings before the assertion do not show steady charging on
    /// AC power over the whole baseline, or nil if they do. The probe checks
    /// this before it creates the assertion, and creates none if there is a
    /// problem.
    public static func baselineProblem(_ baseline: [Sample], criteria: Criteria = .standard) -> String? {
        let baseline = baseline.sorted { $0.time < $1.time }
        guard baseline.count >= criteria.minimumBaselineReadings, let first = baseline.first, let last = baseline.last else {
            return "there were only \(baseline.count) readings before the assertion (\(criteria.minimumBaselineReadings) needed)"
        }
        let duration = last.time - first.time
        guard criteria.baselineDuration.contains(duration) else {
            return """
                the baseline readings spanned \(seconds(duration)), outside \
                \(seconds(criteria.baselineDuration.lowerBound))–\(seconds(criteria.baselineDuration.upperBound))
                """
        }
        if let gap = largestGap(samples: baseline, events: []), gap.length > criteria.maxBaselineGap {
            return """
                the baseline had a gap of \(seconds(gap.length)) between readings at \
                +\(seconds(gap.start)) (more than \(seconds(criteria.maxBaselineGap)))
                """
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
              sample.batteryPresent == true,
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

    /// The longest interval between consecutive moments (readings and
    /// events), from the first to the last.
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
