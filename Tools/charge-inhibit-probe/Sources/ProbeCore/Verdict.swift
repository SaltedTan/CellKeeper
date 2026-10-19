import Foundation

/// The thresholds the verdict applies. They are judgment calls, not values
/// from any source, and are printed in every report.
public struct Criteria: Sendable, Equatable {
    /// The effect (charging stopped, or the battery discharging) must begin
    /// within this many seconds of the assertion's creation to be attributed
    /// to it: one battery update interval (about 60 s) plus margin.
    public var effectWindow: Double
    /// Charging must resume within this many seconds of the release for an
    /// on-time verdict.
    public var resumeWindow: Double
    /// A battery current at or below this many mA counts as not charging.
    public var currentThreshold: Int
    /// A battery current at or below minus this many mA, with the charging
    /// flag off, counts as discharging: the Mac runs from its battery.
    public var dischargeThreshold: Int
    /// An adapter cut needs the system's power input
    /// (`PowerTelemetryData.SystemPowerIn`) at or below this many mW in every
    /// discharging reading; above it, the adapter still delivers power and
    /// the discharge may be a weak adapter or a high load.
    public var cutPowerInput: Int
    /// A run counts only when this many counted readings in a row agree
    /// (N = 5)…
    public var sustainedReadings: Int
    /// …each at least this many seconds after the previous counted one
    /// (closer readings are ignored for counting, but a contradicting one
    /// still breaks the run)…
    public var minimumSpacing: Double
    /// …spanning at least this many seconds from the first to the last
    /// counted reading: (N − 1) × 2 s = 8 s…
    public var sustainedSpan: Double
    /// …and showing at least this many distinct battery updates
    /// (`UpdateTime` values): the battery publishes new values about once a
    /// minute, so readings 2 s apart mostly repeat one update. The baseline,
    /// and a negative verdict after the release, need as many.
    public var distinctUpdates: Int
    /// While the assertion is held, a reading whose battery update is older
    /// than this many seconds (2.5 update intervals) ends the hold at once.
    public var maxUpdateAge: Double
    /// When the assertion is created, the baseline's latest battery update
    /// must be at most this many seconds old.
    public var maxBaselineUpdateAge: Double
    /// `UpdateTime` more than this many seconds ahead of a reading's wall
    /// time, or wall-clock and run-clock intervals between readings that
    /// differ by more than this, make the run inconclusive.
    public var clockTolerance: Double
    /// While the assertion is held, a charge below this many percent ends
    /// the hold at once.
    public var chargeFloor: Int
    /// A gap between consecutive readings longer than this (the Mac slept,
    /// or the probe was stopped) makes the run inconclusive.
    public var maxReadingGap: Double
    /// The baseline needs at least this many readings…
    public var minimumBaselineReadings: Int
    /// …spanning this many seconds from the first to the last: at least the
    /// 20 s minimum less jitter, at most the 150 s limit plus a late
    /// reading…
    public var baselineDuration: ClosedRange<Double>
    /// …with no gap longer than this between readings, nor between the last
    /// reading and the assertion's creation.
    public var maxBaselineGap: Double

    public init(
        effectWindow: Double = 90,
        resumeWindow: Double = 120,
        currentThreshold: Int = 50,
        dischargeThreshold: Int = 100,
        cutPowerInput: Int = 1000,
        sustainedReadings: Int = 5,
        minimumSpacing: Double = 1.5,
        sustainedSpan: Double = 8,
        distinctUpdates: Int = 2,
        maxUpdateAge: Double = 150,
        maxBaselineUpdateAge: Double = 70,
        clockTolerance: Double = 2,
        chargeFloor: Int = 25,
        maxReadingGap: Double = 10,
        minimumBaselineReadings: Int = 5,
        baselineDuration: ClosedRange<Double> = 18...152,
        maxBaselineGap: Double = 4
    ) {
        self.effectWindow = effectWindow
        self.resumeWindow = resumeWindow
        self.currentThreshold = currentThreshold
        self.dischargeThreshold = dischargeThreshold
        self.cutPowerInput = cutPowerInput
        self.sustainedReadings = sustainedReadings
        self.minimumSpacing = minimumSpacing
        self.sustainedSpan = sustainedSpan
        self.distinctUpdates = distinctUpdates
        self.maxUpdateAge = maxUpdateAge
        self.maxBaselineUpdateAge = maxBaselineUpdateAge
        self.clockTolerance = clockTolerance
        self.chargeFloor = chargeFloor
        self.maxReadingGap = maxReadingGap
        self.minimumBaselineReadings = minimumBaselineReadings
        self.baselineDuration = baselineDuration
        self.maxBaselineGap = maxBaselineGap
    }

    public static let standard = Criteria()
}

/// What one usable reading says about charging.
public enum ChargeState: Sendable, Equatable {
    /// On AC power; macOS reports charging and the battery current is above
    /// the threshold.
    case charging
    /// On AC power; macOS reports not charging and the current is at or
    /// below the threshold, and above the discharge threshold.
    case stopped
    /// macOS reports not charging and the battery current is at or below
    /// minus the discharge threshold: the Mac runs from its battery,
    /// whatever IOPowerSources reports about the power source.
    case discharging
    /// The charging flag, the current and the power source disagree.
    case mixed
}

/// A run of readings in one state, counted as the verdict counts them: a
/// reading counts only if it is at least `Criteria.minimumSpacing` after the
/// previous counted one; closer readings are ignored for counting, but their
/// battery updates are recorded. Callers end the run on a contradicting
/// reading.
public struct SustainedRun: Sendable, Equatable {
    public private(set) var first: Sample
    public private(set) var lastCounted: Sample
    public private(set) var counted: Int
    /// The distinct `UpdateTime` values of the run's readings. The verdict
    /// rejects runs whose `UpdateTime` goes backward, so these advance
    /// strictly.
    public private(set) var updates: Set<Int>

    public init(first: Sample) {
        self.first = first
        lastCounted = first
        counted = 1
        updates = Set([first.updateTime].compactMap { $0 })
    }

    /// Counts `sample` if it is far enough after the last counted reading;
    /// otherwise ignores it for counting.
    public mutating func add(_ sample: Sample, criteria: Criteria = .standard) {
        if let update = sample.updateTime { updates.insert(update) }
        guard sample.time - lastCounted.time >= criteria.minimumSpacing else { return }
        lastCounted = sample
        counted += 1
    }

    /// Seconds from the first to the last counted reading.
    public var span: Double { lastCounted.time - first.time }

    /// At least `sustainedReadings` counted readings spanning at least
    /// `sustainedSpan`, of at least `distinctUpdates` battery updates.
    public func isSustained(criteria: Criteria = .standard) -> Bool {
        counted >= criteria.sustainedReadings && span >= criteria.sustainedSpan
            && updates.count >= criteria.distinctUpdates
    }

    /// "4 readings at least 1.5 s apart, spanning 6.0 s, of 1 battery update".
    func summary(criteria: Criteria) -> String {
        """
        \(counted) \(counted == 1 ? "reading" : "readings") at least \(seconds(criteria.minimumSpacing)) \
        apart, spanning \(seconds(span)), of \(updates.count) battery \(updates.count == 1 ? "update" : "updates")
        """
    }
}

/// What the readings after the release show so far.
public enum ResumeAnalysis: Sendable, Equatable {
    /// Charging resumed: a sustained run of charging readings, from `start`.
    case resumed(start: Sample)
    /// A reading could not be used before charging had resumed.
    case problem(Sample, ReadingProblem)
    /// No sustained resume yet; whether any reading, of an update made after
    /// the release, showed charging.
    case pending(sawCharging: Bool)
}

/// Why a reading cannot be used. Any of these while it matters makes the
/// run inconclusive.
public enum ReadingProblem: Sendable, Equatable, CustomStringConvertible {
    /// The Mac reported battery power where that cannot be the effect: the
    /// adapter was unplugged, or macOS stopped drawing from it.
    case onBattery
    /// A value the verdict needs could not be read.
    case unreadable
    /// The battery reached 100% or macOS reports it charged.
    case full
    /// The charge fell below this floor while the assertion was held.
    case belowFloor(Int)
    /// The battery's last update was older than this many seconds while
    /// the assertion was held.
    case staleUpdate(Int)

    public var description: String {
        switch self {
        case .onBattery: "the Mac was on battery power (unplugged?)"
        case .unreadable: "the battery's state could not be read"
        case .full: "the battery reached 100% or was reported charged"
        case let .belowFloor(floor): "the charge fell below \(floor)%"
        case let .staleUpdate(limit): "the battery's values had not been updated for more than \(limit) s"
        }
    }
}

/// What happened during a run, as the verdict needs it.
public struct ProbeRun: Sendable, Equatable {
    public struct Creation: Sendable, Equatable {
        /// When `IOPMAssertionCreateWithProperties` returned, in run seconds…
        public var time: Double
        /// …and as Unix time, to compare with the battery's `UpdateTime`.
        public var unixTime: Double
        /// Its IOReturn.
        public var result: Int32
        /// The assertion's `TimeoutSeconds`.
        public var timeout: Int

        public init(time: Double, unixTime: Double, result: Int32, timeout: Int = ProbeAssertion.timeout(hold: Command.defaultHold)) {
            self.time = time
            self.unixTime = unixTime
            self.result = result
            self.timeout = timeout
        }
    }

    public struct Release: Sendable, Equatable {
        /// When the probe first tried to release the assertion, in run
        /// seconds…
        public var time: Double
        /// …and as Unix time.
        public var unixTime: Double
        /// The IOReturn of the last `IOPMAssertionRelease` attempt.
        public var result: Int32
        public var attempts: Int
        /// Whether `pmset -g assertions` still listed the probe's assertion
        /// after the release; nil if it could not be checked.
        public var stillListed: Bool?

        public init(time: Double, unixTime: Double, result: Int32, attempts: Int = 1, stillListed: Bool?) {
            self.time = time
            self.unixTime = unixTime
            self.result = result
            self.attempts = attempts
            self.stillListed = stillListed
        }
    }

    /// A system power notification the probe received during the run.
    public struct SleepNotice: Sendable, Equatable {
        public var time: Double
        /// "kIOMessageSystemWillSleep", "kIOMessageCanSystemSleep" or
        /// "kIOMessageSystemHasPoweredOn".
        public var message: String

        public init(time: Double, message: String) {
            self.time = time
            self.message = message
        }
    }

    public var assertion: AssertionKind
    public var samples: [Sample]
    /// Nil when no assertion was attempted.
    public var creation: Creation?
    /// Nil if the probe never tried to release the assertion.
    public var release: Release?
    public var sleepNotices: [SleepNotice]

    public init(assertion: AssertionKind, samples: [Sample], creation: Creation?, release: Release?, sleepNotices: [SleepNotice] = []) {
        self.assertion = assertion
        self.samples = samples
        self.creation = creation
        self.release = release
        self.sleepNotices = sleepNotices
    }
}

/// The result of a run.
public enum Verdict: Sendable, Equatable {
    /// Charging stopped within the effect window of the creation, stayed
    /// stopped while held, on AC power, and resumed within the resume window
    /// of a confirmed release.
    case inhibited(stoppedAfter: Double, resumedAfter: Double)
    /// As `inhibited`, but charging resumed later than the resume window.
    case inhibitedResumedLate(stoppedAfter: Double, resumedAfter: Double)
    /// Charging stopped, and had not resumed by the end of the readings,
    /// over at least two battery updates after the release.
    case inhibitedDidNotResume(stoppedAfter: Double, watchedFor: Double)
    /// The battery discharged within the effect window of the creation and
    /// while held, every such reading reporting the adapter attached and a
    /// power input at or below the cut threshold; charging resumed within
    /// the resume window of a confirmed release. `powerBackAfter`: when a
    /// reading first showed adapter power again, if one did.
    case adapterCut(cutAfter: Double, powerBackAfter: Double?, resumedAfter: Double)
    /// As `adapterCut`, but charging resumed later than the resume window.
    case adapterCutResumedLate(cutAfter: Double, powerBackAfter: Double?, resumedAfter: Double)
    /// The battery discharged while held with the adapter reported attached,
    /// but the adapter still delivered power above the cut threshold, so the
    /// discharge is not attributed to a cut; charging then resumed.
    case dischargingWithAdapter(dischargedAfter: Double, resumedAfter: Double)
    /// The battery discharged while held, and charging had not resumed by
    /// the end of the readings, over at least two battery updates after the
    /// release. `looksLikeCut`: every discharging reading met the cut
    /// criteria.
    case dischargingDidNotResume(dischargedAfter: Double, powerBackAfter: Double?, watchedFor: Double, looksLikeCut: Bool)
    /// The assertion was created, and every reading while it was held showed
    /// charging, over at least two battery updates.
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
        case .adapterCut: "adapter cut"
        case .adapterCutResumedLate: "adapter cut, resumed late"
        case .dischargingWithAdapter: "discharging with adapter attached"
        case .dischargingDidNotResume: "discharging, did not resume"
        case .noEffect: "no effect observed"
        case .refused: "refused"
        case .inconclusive: "inconclusive"
        }
    }

    /// The probe's exit status for this verdict.
    public var exitStatus: Int32 {
        switch self {
        case .inhibited, .inhibitedResumedLate, .adapterCut, .adapterCutResumedLate, .dischargingWithAdapter, .noEffect, .refused: 0
        case .inconclusive: 2
        case .inhibitedDidNotResume, .dischargingDidNotResume: 3
        }
    }

    /// The recovery steps, for a run after which charging or adapter power
    /// did not come back (research note 10 §7).
    public static func recoverySteps(_ assertion: AssertionKind) -> String {
        """
        Follow the recovery steps now: if the probe still runs, press Ctrl-C; \
        run `pmset -g assertions` and check that it lists no \(assertion.type); \
        unplug the adapter and plug it back in; quit any battery tool; restart \
        the Mac, and if that does not help, shut it down, wait about 30 seconds \
        and start it again (on Apple silicon there is no SMC reset) \
        (docs/safety.md, "If charging does not resume"). Then send this report \
        to the lead.
        """
    }

    /// What the verdict means, for the owner.
    public func explanation(assertion: AssertionKind, criteria: Criteria = .standard) -> String {
        let sustained = Self.sustainedNeeded(criteria)
        let type = assertion.type
        let attribution = """
            macOS's own charging and thermal management can also stop charging; \
            the stop is attributed to the assertion only because it began after \
            the creation and lasted until the release.
            """
        let cutInference = """
            That the adapter's power was cut is inferred [INFERRED/UNVERIFIED]: the \
            battery discharged while every reading still reported the adapter \
            attached and a system power input of at most \(criteria.cutPowerInput) mW, \
            from after the creation until the release.
            """
        let powerBack = { (after: Double?) in
            after.map { "Adapter power was back \(seconds($0)) after the release. " } ?? ""
        }
        switch self {
        case let .inhibited(stopped, resumed):
            return """
                Charging stopped \(seconds(stopped)) after the assertion was created, \
                stayed stopped in every reading while it was held, and resumed \
                \(seconds(resumed)) after a confirmed release (each over \(sustained)), \
                all on AC power. On this Mac, macOS build and firmware, the \(type) \
                assertion stops charging while the Mac stays on adapter power, and \
                releasing it lets charging resume. \(attribution)
                """
        case let .inhibitedResumedLate(stopped, resumed):
            return """
                Charging stopped \(seconds(stopped)) after the assertion was created \
                and stayed stopped while it was held, on AC power, but resumed only \
                \(seconds(resumed)) after a confirmed release, later than the \
                \(seconds(criteria.resumeWindow)) window. The assertion stops \
                charging; the slow resume needs a second look before anything is \
                built on it. \(attribution)
                """
        case let .inhibitedDidNotResume(stopped, watched):
            return """
                Charging stopped \(seconds(stopped)) after the assertion was created, \
                and had not resumed \(seconds(watched)) after its release, although \
                powerd accepted the release and no longer listed the assertion. \
                \(Self.recoverySteps(assertion))
                """
        case let .adapterCut(cut, back, resumed):
            return """
                The Mac ran from its battery from \(seconds(cut)) after the assertion \
                was created until it was released, and charging resumed \
                \(seconds(resumed)) after a confirmed release (each over \(sustained)). \
                \(powerBack(back))\(cutInference) On this Mac, macOS build and \
                firmware, the \(type) assertion then cuts the adapter's power, and \
                releasing it restores it. Confirm that the adapter stayed plugged in.
                """
        case let .adapterCutResumedLate(cut, back, resumed):
            return """
                The Mac ran from its battery from \(seconds(cut)) after the assertion \
                was created until it was released, but charging resumed only \
                \(seconds(resumed)) after a confirmed release, later than the \
                \(seconds(criteria.resumeWindow)) window. \(powerBack(back))\(cutInference) \
                The slow resume needs a second look before anything is built on it. \
                Confirm that the adapter stayed plugged in.
                """
        case let .dischargingWithAdapter(discharged, resumed):
            return """
                The battery discharged from \(seconds(discharged)) after the assertion \
                was created until it was released, with the adapter reported \
                attached, and charging resumed \(seconds(resumed)) after a confirmed \
                release. But in some of those readings the adapter still delivered \
                more than \(criteria.cutPowerInput) mW (or the input could not be \
                read), so the discharge is not attributed to a cut: an adapter too \
                weak for the load, or a high load, looks the same. See the samples.
                """
        case let .dischargingDidNotResume(discharged, back, watched, looksLikeCut):
            return """
                The battery discharged from \(seconds(discharged)) after the assertion \
                was created, and charging had not resumed \(seconds(watched)) after \
                its release, although powerd accepted the release and no longer \
                listed the assertion. \(powerBack(back))The readings while it was \
                held \(looksLikeCut ? "looked like an adapter cut" : "did not all look like an adapter cut") \
                (\(criteria.cutPowerInput) mW or less, adapter reported attached). \
                \(Self.recoverySteps(assertion))
                """
        case let .noEffect(held):
            return """
                powerd accepted the assertion, and every reading in the \
                \(seconds(held)) it was held showed charging, over at least \
                \(criteria.distinctUpdates) battery updates made after its creation. \
                No effect was observed during the measured hold on this Mac, macOS \
                build and firmware.
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
        if let problem = baselineFreshnessProblem(baseline, at: creation.time, unixTime: creation.unixTime, criteria: criteria) {
            return .inconclusive(reason: problem)
        }
        guard let release = run.release else {
            return .inconclusive(reason: "the probe did not release the assertion itself")
        }
        if let problem = releaseProblem(release, creation: creation, assertion: run.assertion) {
            return .inconclusive(reason: problem)
        }
        if let notice = run.sleepNotices.first {
            return .inconclusive(reason: """
                the system sent \(notice.message) at +\(seconds(notice.time)), and the \
                probe ended the hold; a sleeping Mac's readings say nothing
                """)
        }
        if let gap = largestGap(samples: samples, events: [creation.time, release.time]),
           gap.length > criteria.maxReadingGap {
            return .inconclusive(reason: """
                there was a gap of \(seconds(gap.length)) between readings at \
                +\(seconds(gap.start)) (longer than \(seconds(criteria.maxReadingGap))); \
                the Mac may have slept
                """)
        }
        let events = [(creation.time, creation.unixTime), (release.time, release.unixTime)]
        if let problem = clockProblem(samples: samples, events: events, criteria: criteria) {
            return .inconclusive(reason: problem)
        }

        // While held.
        let held = samples.filter { $0.phase == .held }
        for sample in held {
            if let problem = holdProblem(of: sample, criteria: criteria) {
                return .inconclusive(reason: """
                    \(problem) \(seconds(sample.time - creation.time)) after the \
                    assertion was created, while it was held
                    """)
            }
        }
        guard let last = held.last, last.time - creation.time >= criteria.effectWindow else {
            return .inconclusive(reason: """
                the readings while the assertion was held cover less than \
                \(seconds(criteria.effectWindow))
                """)
        }
        let states = held.map { state(of: $0, criteria: criteria) }
        guard let effectIndex = states.firstIndex(where: { $0 == .stopped || $0 == .discharging }) else {
            guard states.allSatisfy({ $0 == .charging }) else {
                return .inconclusive(reason: """
                    while the assertion was held, charging never clearly stopped and \
                    the battery never clearly discharged, but the charging flag, the \
                    battery current and the power source disagreed in some readings
                    """)
            }
            let updates = updatesMade(after: creation.unixTime, in: held)
            guard updates >= criteria.distinctUpdates else {
                return .inconclusive(reason: """
                    every reading while the assertion was held showed charging, but \
                    they show only \(updates) battery \(updates == 1 ? "update" : "updates") \
                    made after its creation (\(criteria.distinctUpdates) needed), so an \
                    effect the battery reports only at a later update cannot be ruled out
                    """)
            }
            return .noEffect(heldFor: last.time - creation.time)
        }
        let effect = states[effectIndex]
        let firstEffect = held[effectIndex]
        let effectAfter = firstEffect.time - creation.time
        let what = effect == .stopped ? "charging stopped" : "the battery discharged"
        let began = "\(what) \(seconds(effectAfter)) after the assertion was created"
        guard effectAfter <= criteria.effectWindow else {
            return .inconclusive(reason: """
                \(what) only \(seconds(effectAfter)) after the assertion was created, \
                later than \(seconds(criteria.effectWindow)), so it cannot be \
                attributed to it
                """)
        }
        guard madeAfter(firstEffect, creation.unixTime) else {
            return .inconclusive(reason: """
                \(began), but the battery update that first showed it was not \
                clearly made after the creation (it was made in the same second or \
                earlier), so it cannot be attributed to it
                """)
        }
        var effectRun = SustainedRun(first: firstEffect)
        for index in held.indices.dropFirst(effectIndex + 1) {
            guard states[index] == effect else {
                let at = seconds(held[index].time - creation.time)
                let instead: String
                switch states[index] {
                case .charging: instead = "charging started again \(at) after it"
                case .mixed: instead = "\(at) after it the readings disagreed (\(chargingSummary(held[index])))"
                case .stopped, .discharging:
                    instead = "\(at) after it the readings changed (\(chargingSummary(held[index])))"
                }
                return .inconclusive(reason: "\(began), but \(instead), while it was still held")
            }
            effectRun.add(held[index], criteria: criteria)
        }
        guard effectRun.isSustained(criteria: criteria) else {
            return .inconclusive(reason: """
                \(began), but only \(effectRun.summary(criteria: criteria)) showed it \
                before the release (\(sustainedNeeded(criteria)) needed)
                """)
        }
        let discharged = effect == .discharging
        let effectReadings = held[effectIndex...]
        let unreported = effectReadings.filter { !$0.reportsAdapter }.count
        let inputUnknown = effectReadings.filter { $0.systemPowerIn == nil }.count
        let inputHigh = effectReadings.filter { ($0.systemPowerIn ?? 0) > criteria.cutPowerInput }.count
        let looksLikeCut = unreported == 0 && inputUnknown == 0 && inputHigh == 0

        // After the release.
        let after = samples.filter { $0.phase == .after }
        let powerBack = after.first {
            madeAfter($0, release.unixTime) && state(of: $0, criteria: criteria) != .discharging
                && ($0.systemPowerIn ?? 0) > criteria.cutPowerInput
        }.map { $0.time - release.time }
        let sawCharging: Bool
        switch analyzeResume(after, releasedAt: release.unixTime, batteryAllowed: discharged, criteria: criteria) {
        case let .resumed(start):
            let resumedAfter = start.time - release.time
            let late = resumedAfter > criteria.resumeWindow
            guard discharged else {
                return late
                    ? .inhibitedResumedLate(stoppedAfter: effectAfter, resumedAfter: resumedAfter)
                    : .inhibited(stoppedAfter: effectAfter, resumedAfter: resumedAfter)
            }
            guard unreported == 0 else {
                return .inconclusive(reason: """
                    \(began) and until the release, and charging resumed \
                    \(seconds(resumedAfter)) after the release, but \(unreported) of the \
                    \(effectReadings.count) readings while it discharged did not report \
                    the adapter attached (AppleRawExternalConnected or the adapter \
                    details). An adapter unplugged at those moments would look the \
                    same. If the adapter stayed plugged in the whole time, the adapter's \
                    power was cut
                    """)
            }
            guard looksLikeCut else {
                return .dischargingWithAdapter(dischargedAfter: effectAfter, resumedAfter: resumedAfter)
            }
            return late
                ? .adapterCutResumedLate(cutAfter: effectAfter, powerBackAfter: powerBack, resumedAfter: resumedAfter)
                : .adapterCut(cutAfter: effectAfter, powerBackAfter: powerBack, resumedAfter: resumedAfter)
        case let .problem(sample, problem):
            return .inconclusive(reason: """
                \(began), but \(problem) \(seconds(sample.time - release.time)) after \
                the release, before charging had resumed (\(sustainedNeeded(criteria)))
                """)
        case let .pending(saw):
            sawCharging = saw
        }
        let watched = (after.last?.time ?? release.time) - release.time
        guard watched >= criteria.resumeWindow else {
            return .inconclusive(reason: """
                \(began), but the readings after the release end \(seconds(watched)) \
                after it, before the \(seconds(criteria.resumeWindow)) window was over
                """)
        }
        if sawCharging {
            return .inconclusive(reason: """
                \(began); after the release it charged in some readings, but never in \
                \(sustainedNeeded(criteria)) in a row
                """)
        }
        let updatesAfter = updatesMade(after: release.unixTime, in: after)
        guard updatesAfter >= criteria.distinctUpdates else {
            return .inconclusive(reason: """
                \(began), and no reading after the release showed charging, but they \
                show only \(updatesAfter) battery \(updatesAfter == 1 ? "update" : "updates") \
                made after the release (\(criteria.distinctUpdates) needed), so whether \
                charging resumed cannot be told
                """)
        }
        return discharged
            ? .dischargingDidNotResume(dischargedAfter: effectAfter, powerBackAfter: powerBack, watchedFor: watched, looksLikeCut: looksLikeCut)
            : .inhibitedDidNotResume(stoppedAfter: effectAfter, watchedFor: watched)
    }

    /// Looks for a sustained run of charging readings, of battery updates
    /// made after the release (`releasedAt`, Unix time): a non-charging
    /// reading breaks a run; a reading closer than `minimumSpacing` to the
    /// last counted one is ignored for counting; a charging reading of an
    /// update not clearly made after the release does not count. Battery
    /// power is a problem unless `batteryAllowed` (after a discharge, it may
    /// take a moment to end). The probe's watch after the release uses the
    /// same function.
    public static func analyzeResume(
        _ after: [Sample],
        releasedAt: Double,
        batteryAllowed: Bool,
        criteria: Criteria = .standard
    ) -> ResumeAnalysis {
        var run: SustainedRun?
        var sawCharging = false
        for sample in after.sorted(by: { $0.time < $1.time }) {
            if let problem = problem(of: sample, batteryAllowed: batteryAllowed) {
                return .problem(sample, problem)
            }
            guard state(of: sample, criteria: criteria) == .charging, madeAfter(sample, releasedAt) else {
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

    /// Whether the baseline is long enough to create the assertion: at least
    /// `minimumSpan` seconds, of at least `distinctUpdates` battery updates,
    /// with clocks that can be trusted (``clockProblem(samples:events:criteria:)``).
    /// The probe's baseline reads until this holds, or until its time limit;
    /// ``baselineProblem(_:criteria:)`` then decides.
    public static func baselineReady(_ baseline: [Sample], minimumSpan: Double, criteria: Criteria = .standard) -> Bool {
        guard let first = baseline.first, let last = baseline.last, last.time - first.time >= minimumSpan else { return false }
        guard clockProblem(samples: baseline, events: [], criteria: criteria) == nil else { return false }
        return Set(baseline.compactMap(\.updateTime)).count >= criteria.distinctUpdates
    }

    /// Why the assertion must not be created at `now` (run seconds;
    /// `unixTime` is the same moment as Unix time): the last baseline
    /// reading is missing or more than `maxBaselineGap` old, the clocks
    /// cannot be trusted over the baseline and up to this moment
    /// (``clockProblem(samples:events:criteria:)``), or the baseline's latest
    /// battery update is more than `maxBaselineUpdateAge` old. The probe
    /// checks this under the holder's lock immediately before it creates the
    /// assertion, and the verdict again.
    public static func baselineFreshnessProblem(_ baseline: [Sample], at now: Double, unixTime: Double, criteria: Criteria = .standard) -> String? {
        guard let last = baseline.max(by: { $0.time < $1.time }) else { return "there was no baseline reading before the assertion" }
        if let problem = clockProblem(samples: baseline, events: [(now, unixTime)], criteria: criteria) {
            return "\(problem) before the assertion was to be created, so nothing was created"
        }
        let age = now - last.time
        guard age <= criteria.maxBaselineGap else {
            return """
                the last baseline reading was \(seconds(age)) old when the assertion \
                was about to be created (more than \(seconds(criteria.maxBaselineGap))), \
                so nothing was created
                """
        }
        guard let latest = baseline.compactMap(\.updateTime).max() else {
            return "no baseline reading had a battery update time, so nothing was created"
        }
        let updateAge = unixTime - Double(latest)
        guard updateAge <= criteria.maxBaselineUpdateAge else {
            return """
                the baseline's latest battery update was \(seconds(updateAge)) old when \
                the assertion was about to be created (more than \
                \(seconds(criteria.maxBaselineUpdateAge))), so nothing was created
                """
        }
        return nil
    }

    /// "5 readings at least 1.5 s apart, spanning at least 8.0 s, of at least
    /// 2 battery updates".
    static func sustainedNeeded(_ criteria: Criteria) -> String {
        """
        \(criteria.sustainedReadings) readings at least \(seconds(criteria.minimumSpacing)) \
        apart, spanning at least \(seconds(criteria.sustainedSpan)), of at least \
        \(criteria.distinctUpdates) battery updates
        """
    }

    /// Whether the battery update `sample` shows was clearly made after the
    /// moment `unixTime`: `UpdateTime` is cut to whole seconds, so only an
    /// update stamped in a later second than the moment's counts; one in the
    /// same second is ambiguous and never counts. False if the update time is
    /// unknown.
    public static func madeAfter(_ sample: Sample, _ unixTime: Double) -> Bool {
        guard let update = sample.updateTime else { return false }
        return update >= Int(unixTime.rounded(.down)) + 1
    }

    /// How many distinct battery updates clearly made after `unixTime` the
    /// `samples` show.
    static func updatesMade(after unixTime: Double, in samples: [Sample]) -> Int {
        Set(samples.filter { madeAfter($0, unixTime) }.compactMap(\.updateTime)).count
    }

    /// Why the clocks cannot be trusted, or nil: an `UpdateTime` that goes
    /// backward between consecutive readings or lies more than
    /// `clockTolerance` ahead of its reading's wall time, or wall-clock and
    /// run-clock intervals that differ by more than `clockTolerance` (the
    /// wall clock was set while the probe ran). The intervals are compared
    /// between consecutive readings directly, and also between each of the
    /// `events` (run time and Unix time) and the readings just before and
    /// after it; an event between two readings never splits their interval
    /// into two smaller ones.
    public static func clockProblem(samples: [Sample], events: [(Double, Double)], criteria: Criteria = .standard) -> String? {
        let samples = samples.sorted { $0.time < $1.time }
        var previousUpdate: (time: Double, value: Int)?
        for sample in samples {
            guard let update = sample.updateTime else { continue }
            if let previous = previousUpdate, update < previous.value {
                return """
                    the battery's UpdateTime went backward at +\(seconds(sample.time)) \
                    (from \(previous.value) to \(update))
                    """
            }
            if let unix = sample.unixTime, Double(update) > unix + criteria.clockTolerance {
                return """
                    the battery's UpdateTime at +\(seconds(sample.time)) lay \
                    \(seconds(Double(update) - unix)) ahead of the reading's wall time
                    """
            }
            previousUpdate = (sample.time, update)
        }
        let readings = samples.compactMap { sample in sample.unixTime.map { (sample.time, $0) } }
        var pairs = Array(zip(readings, readings.dropFirst()))
        for event in events {
            if let before = readings.last(where: { $0.0 <= event.0 }) { pairs.append((before, event)) }
            if let after = readings.first(where: { $0.0 > event.0 }) { pairs.append((event, after)) }
        }
        for (earlier, later) in pairs {
            let difference = (later.1 - earlier.1) - (later.0 - earlier.0)
            if abs(difference) > criteria.clockTolerance {
                return """
                    the wall clock and the run's clock disagreed by \(seconds(abs(difference))) \
                    between +\(seconds(earlier.0)) and +\(seconds(later.0)); the wall clock \
                    may have been set
                    """
            }
        }
        return nil
    }

    /// Why the release cannot be trusted, or nil if powerd accepted it and
    /// no longer listed the assertion.
    static func releaseProblem(_ release: ProbeRun.Release, creation: ProbeRun.Creation, assertion: AssertionKind) -> String? {
        let fallback = """
            powerd releases it at its timeout (\(creation.timeout) s after creation) \
            and when the probe exits; check with `pmset -g assertions` after the \
            probe has exited that no \(assertion.type) is listed
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
                pmset -g assertions still listed the probe's \(assertion.type) after the \
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
    /// AC power over the whole baseline, of at least `distinctUpdates`
    /// battery updates, or nil if they do. The probe checks this before it
    /// creates the assertion, and creates none if there is a problem.
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
        if let problem = clockProblem(samples: baseline, events: [], criteria: criteria) {
            return "during the baseline, \(problem), so nothing was created"
        }
        let updates = Set(baseline.compactMap(\.updateTime)).count
        guard updates >= criteria.distinctUpdates else {
            return """
                the baseline showed only \(updates) battery \(updates == 1 ? "update" : "updates") \
                in \(seconds(duration)) (\(criteria.distinctUpdates) needed), so nothing was created
                """
        }
        return nil
    }

    /// Why a reading cannot be used, or nil if it can. Battery power is a
    /// problem unless `batteryAllowed`.
    public static func problem(of sample: Sample, batteryAllowed: Bool = false) -> ReadingProblem? {
        if !batteryAllowed, sample.externalPower == false { return .onBattery }
        guard sample.externalPower != nil,
              sample.batteryPresent == true,
              let percent = sample.percent,
              sample.isCharging != nil,
              sample.current != nil,
              sample.updateTime != nil,
              sample.unixTime != nil
        else { return .unreadable }
        if percent >= 100 || sample.isCharged == true { return .full }
        return nil
    }

    /// Why a reading while the assertion is held ends the hold at once, or
    /// nil: an unusable reading, a charge below the floor, or a battery
    /// update older than `maxUpdateAge`. Battery power is not a reason: it
    /// can be the effect.
    public static func holdProblem(of sample: Sample, criteria: Criteria = .standard) -> ReadingProblem? {
        if let problem = problem(of: sample, batteryAllowed: true) { return problem }
        if let percent = sample.percent, percent < criteria.chargeFloor { return .belowFloor(criteria.chargeFloor) }
        if let age = sample.updateAge, age > criteria.maxUpdateAge { return .staleUpdate(Int(criteria.maxUpdateAge)) }
        return nil
    }

    /// What a usable reading says about charging.
    public static func state(of sample: Sample, criteria: Criteria = .standard) -> ChargeState {
        guard let charging = sample.isCharging, let current = sample.current else { return .mixed }
        if !charging, current <= -criteria.dischargeThreshold { return .discharging }
        guard sample.externalPower == true else { return .mixed }
        if charging, current > criteria.currentThreshold { return .charging }
        if !charging, current <= criteria.currentThreshold { return .stopped }
        return .mixed
    }

    /// Whether `sample` shows charging on adapter power, usable.
    public static func isChargingOnAdapter(_ sample: Sample, criteria: Criteria = .standard) -> Bool {
        problem(of: sample) == nil && state(of: sample, criteria: criteria) == .charging
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

    /// "battery power, not charging, -900 mA".
    static func chargingSummary(_ sample: Sample) -> String {
        let source = sample.externalPower.map { $0 ? "AC power" : "battery power" } ?? "power source unknown"
        let flag = sample.isCharging.map { $0 ? "charging" : "not charging" } ?? "charging unknown"
        let current = sample.current.map { "\($0) mA" } ?? "current unknown"
        return "\(source), \(flag), \(current)"
    }
}

/// Seconds with one decimal, for reports: "12.0 s".
public func seconds(_ value: Double) -> String {
    String(format: "%.1f s", value)
}
