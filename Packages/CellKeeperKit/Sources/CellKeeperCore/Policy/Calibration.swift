import Foundation

/// A moment as a guided calibration records it: the wall clock, a monotonic
/// clock that keeps counting during sleep and starts again at boot, and the
/// boot that monotonic reading belongs to (research note 12 §7.3).
public struct CalibrationStamp: Sendable, Equatable, Codable {
    public var wall: Date
    /// Seconds on a clock that counts sleep and restarts at boot.
    public var monotonic: TimeInterval
    /// Identifies the boot ``monotonic`` belongs to; nil if unknown, in
    /// which case no other stamp counts as the same boot.
    public var boot: String?

    public init(wall: Date, monotonic: TimeInterval, boot: String?) {
        self.wall = wall
        self.monotonic = monotonic
        self.boot = boot
    }

    /// True if both stamps carry the same known boot, so their monotonic
    /// readings can be compared.
    public func isSameBoot(as other: CalibrationStamp) -> Bool {
        guard let boot else { return false }
        return boot == other.boot
    }

    /// Seconds from `earlier` to this stamp: by the monotonic clock within
    /// the same boot, so a clock change cannot move it, and by the wall
    /// clock across a restart. Never negative. A clock that gives no usable
    /// number counts as infinitely late, so every bound has passed.
    public func elapsed(since earlier: CalibrationStamp) -> TimeInterval {
        let interval = isSameBoot(as: earlier) ? monotonic - earlier.monotonic : wall.timeIntervalSince(earlier.wall)
        guard interval.isFinite else { return .infinity }
        return max(interval, 0)
    }
}

/// The steps of a guided calibration (note 12 §7.3). Step 0, the start, is
/// admission (``CalibrationAdmission``); step 8, the finish, ends the
/// session. Neither is a step a session is in.
public enum CalibrationStep: Int, Sendable, Equatable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    case chargeToFull = 1
    case restAtTop = 2
    case unplug = 3
    case drain = 4
    case restAtBottom = 5
    case plugIn = 6
    case finalCharge = 7

    /// True for the steps in which the session asks for macOS's Charge
    /// Limit at 100%: 1, 2 and 7 only (§7.2).
    public var asksForFullLimit: Bool {
        switch self {
        case .chargeToFull, .restAtTop, .finalCharge: true
        case .unplug, .drain, .restAtBottom, .plugIn: false
        }
    }

    /// The longest the step may last before the session ends; nil for a
    /// step without its own bound (the 72-hour cap still applies).
    public var bound: TimeInterval? {
        switch self {
        case .chargeToFull, .finalCharge: CalibrationSession.chargeBound
        case .unplug: CalibrationSession.unplugBound
        case .restAtTop, .drain, .restAtBottom, .plugIn: nil
        }
    }

    public static func < (lhs: CalibrationStep, rhs: CalibrationStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .chargeToFull: "charge to full"
        case .restAtTop: "rest at the top"
        case .unplug: "unplug"
        case .drain: "drain"
        case .restAtBottom: "rest at the bottom"
        case .plugIn: "plug in"
        case .finalCharge: "final charge to full"
        }
    }
}

/// The battery's summary capacities and cycle count, before and after a
/// calibration (§7.9). Never a serial number or any other identifier.
public struct CalibrationCapacities: Sendable, Equatable, Codable {
    public var fullChargeMilliampHours: Int?
    public var nominalMilliampHours: Int?
    public var designMilliampHours: Int?
    public var cycleCount: Int?

    public init(fullChargeMilliampHours: Int? = nil, nominalMilliampHours: Int? = nil, designMilliampHours: Int? = nil, cycleCount: Int? = nil) {
        self.fullChargeMilliampHours = fullChargeMilliampHours
        self.nominalMilliampHours = nominalMilliampHours
        self.designMilliampHours = designMilliampHours
        self.cycleCount = cycleCount
    }

    public init(_ health: BatteryHealth) {
        self.init(
            fullChargeMilliampHours: health.fullChargeCapacityMilliampHours,
            nominalMilliampHours: health.nominalChargeCapacityMilliampHours,
            designMilliampHours: health.designCapacityMilliampHours,
            cycleCount: health.cycleCount
        )
    }
}

/// How the temperature condition of note 06 R23 was met at the start (§7.7).
public enum CalibrationTemperatureCheck: String, Sendable, Equatable, Codable {
    /// CellKeeper read the battery's temperature, within 10–40 °C, and
    /// keeps checking it.
    case measured
    /// CellKeeper cannot read the battery's temperature; the owner confirmed
    /// a room at 10–35 °C, with the Mac out of a bag and off soft surfaces.
    case ownerConfirmedCoolRoom
}

/// What the owner confirmed about Optimized Battery Charging, which
/// CellKeeper cannot read (§7.4).
public enum OptimizedChargingConfirmation: String, Sendable, Equatable, Codable {
    /// The owner confirmed it is off.
    case off
    /// The owner accepted that step 1 may reach its bound with it on.
    case boundAccepted
}

/// A step entered, and when, for the report.
public struct CalibrationStepEntry: Sendable, Equatable, Codable {
    public var step: CalibrationStep
    public var enteredAt: Date

    public init(step: CalibrationStep, enteredAt: Date) {
        self.step = step
        self.enteredAt = enteredAt
    }
}

/// A battery reading as the calibration keeps it.
public struct CalibrationReading: Sendable, Equatable, Codable {
    public var at: Date
    public var percent: Int
    public var powerSource: PowerSource

    public init(at: Date, percent: Int, powerSource: PowerSource) {
        self.at = at
        self.percent = percent
        self.powerSource = powerSource
    }
}

/// The Mac announcing sleep during the rest at the bottom.
public struct CalibrationSleep: Sendable, Equatable, Codable {
    public var at: CalibrationStamp
    /// The run of CellKeeper that saw it.
    public var run: UUID
    /// The charge of a usable reading taken as it was announced; nil if
    /// there was none.
    public var percent: Int?
    public var isOnBattery: Bool

    public init(at: CalibrationStamp, run: UUID, percent: Int?, isOnBattery: Bool) {
        self.at = at
        self.run = run
        self.percent = percent
        self.isOnBattery = isOnBattery
    }
}

/// Why the rest at the bottom was not confirmed (§7.6).
public enum CalibrationRestReason: String, Sendable, Equatable, Codable, CaseIterable, CustomStringConvertible {
    case noSleepSeen
    case noWakeSeen
    case cellKeeperRestarted
    case restartedBeforeTime
    case ownerSaidNo
    case noReadingAtSleep
    case notOnBatteryAtSleep
    case chargeOutsideRangeAtSleep
    case sleptTooShort
    case clockMoved
    case firstReadingOnPower
    case pluggedInAwake
    case chargeChanged

    public var description: String {
        switch self {
        case .noSleepSeen: "CellKeeper saw no sleep during the rest"
        case .noWakeSeen: "CellKeeper saw no wake after the sleep"
        case .cellKeeperRestarted: "CellKeeper was not running for the whole rest"
        case .restartedBeforeTime: "the Mac was started again before the time shown"
        case .ownerSaidNo: "you said the Mac did not stay shut down and unplugged until the time shown"
        case .noReadingAtSleep: "CellKeeper had no usable battery reading when the Mac went to sleep"
        case .notOnBatteryAtSleep: "the Mac was not on battery power when it went to sleep"
        case .chargeOutsideRangeAtSleep: "the charge was not 15–20% when the Mac went to sleep"
        case .sleptTooShort: "the Mac slept for less than 5 hours"
        case .clockMoved: "the clock was changed during the rest"
        case .firstReadingOnPower: "the first reading after waking already showed the Mac on power, so when it was plugged in is not known"
        case .pluggedInAwake: "the Mac was plugged in while awake"
        case .chargeChanged: "the charge after waking was higher, or more than 3 points lower, than before the sleep"
        }
    }
}

/// What CellKeeper records about the rest at the bottom (§7.6). The gauge
/// decides what it learns; this is only what CellKeeper could observe.
public enum CalibrationRestResult: Sendable, Equatable, Codable {
    /// The Mac slept on battery power at 15–20% for at least 5 hours, in
    /// one run of CellKeeper, with the wall clock agreeing, and woke on
    /// battery power with the charge no higher and at most 3 points lower.
    case counted(sleptFor: TimeInterval, fromPercent: Int, toPercent: Int)
    /// After a restart, the owner said the Mac stayed shut down and
    /// unplugged until the time shown; with the boot time and the last
    /// reading before the shutdown, where known.
    case ownersAccount(bootTime: Date?, lastReading: CalibrationReading?)
    case notConfirmed(CalibrationRestReason)
}

/// How a session ended (§7.3, §7.6). Ending means the session is marked
/// ended and CellKeeper's normal policy applies again.
public enum CalibrationEnd: Sendable, Equatable, Codable, CustomStringConvertible {
    /// The final charge reached full and the return to the normal limit
    /// was confirmed.
    case completed
    case cancelled
    /// The step reached its bound.
    case stepBound(CalibrationStep)
    /// 72 hours passed.
    case sessionCap
    /// The Mac was unplugged while a charge to full was not complete.
    case unplugged(CalibrationStep)
    /// The Mac was plugged in before the drain reached its target.
    case pluggedInDuringDrain
    /// The charge was at 15% or below before the rest began: the owner is
    /// asked to plug in now.
    case lowBattery(percent: Int)
    case managementOff
    /// macOS's Charge Limit was changed outside CellKeeper and kept as the
    /// owner's own.
    case outsideChange
    /// CellKeeper's control is no longer macOS's Charge Limit.
    case controlChanged
    /// macOS's Charge Limit cannot be changed right now.
    case controlUnavailable
    case backendFaulted
    /// The return to the normal limit could not be confirmed (§7.2).
    case returnFailed
    case temperatureOutOfRange(celsius: Double)
    /// A temperature reading CellKeeper had seen disappeared.
    case temperatureLost
    /// A write of the session failed or did not read back.
    case storageFailed
    /// At launch, macOS's Charge Limit was not what CellKeeper left.
    case unaccountedLimit(found: Int?, expected: Int)
    /// At launch, a one-shot full charge was scheduled.
    case scheduleFound

    public var isCompleted: Bool { self == .completed }

    /// True when the owner is asked to plug in at once.
    public var asksToPlugIn: Bool {
        if case .lowBattery = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .completed: "it finished"
        case .cancelled: "you cancelled it"
        case .stepBound(let step): "step \(step.rawValue) (\(step)) reached its \(Int((step.bound ?? 0) / 3600))-hour limit"
        case .sessionCap: "it reached its \(Int(CalibrationSession.maximumDuration / 3600))-hour limit"
        case .unplugged(let step): "the Mac was unplugged during step \(step.rawValue) (\(step)), before the battery was full"
        case .pluggedInDuringDrain: "the Mac was plugged in before the battery drained to \(CalibrationSession.targetPercent)%"
        case .lowBattery(let percent): "the battery was at \(percent)%, at or below \(CalibrationSession.lowBatteryPercent)%, before the rest began"
        case .managementOff: "Manage charging was turned off"
        case .outsideChange: "macOS's Charge Limit was changed outside CellKeeper"
        case .controlChanged: "CellKeeper's control is no longer macOS's Charge Limit"
        case .controlUnavailable: "macOS's Charge Limit could not be changed"
        case .backendFaulted: "the control backend faulted"
        case .returnFailed: "CellKeeper could not confirm the return to its limit"
        case .temperatureOutOfRange(let celsius): "the battery was at \(celsius.formatted(.number.precision(.fractionLength(1))))°C, outside 10–40°C"
        case .temperatureLost: "the battery temperature could no longer be read"
        case .storageFailed: "CellKeeper could not save the calibration"
        case .unaccountedLimit(let found, let expected): "macOS's Charge Limit was \(found.map { "\($0)%" } ?? "unreadable") when CellKeeper started again, not your own \(expected)%"
        case .scheduleFound: "a one-shot full charge was scheduled"
        }
    }
}

/// What a calibration step changed, for the activity log.
public enum CalibrationChange: Sendable, Equatable {
    case entered(CalibrationStep)
    /// The session asks for the normal limit again, leaving a 100% step.
    case returning(from: CalibrationStep)
    case returnConfirmed
    /// The Mac was unplugged during the rest at the top: the session moved
    /// to the drain, the rest short if it had not lasted 2 hours.
    case earlyUnplug(restShort: Bool)
    /// The Mac was plugged in during the rest at the bottom before the time
    /// shown.
    case earlyPlugIn
    case restShort(CalibrationStep)
    case restAgainRequested
    case sleepRecorded(percent: Int?, isOnBattery: Bool)
    case wakeRecorded
    case restResult(CalibrationRestResult)
    case continued
    case topRestRestarted
}

/// A session after one observation: unchanged, changed, or ended.
public struct CalibrationProgress: Sendable, Equatable {
    /// The session as it is now; as it was if ``end`` is set.
    public var session: CalibrationSession
    public var end: CalibrationEnd?
    public var changes: [CalibrationChange]

    public init(session: CalibrationSession, end: CalibrationEnd? = nil, changes: [CalibrationChange] = []) {
        self.session = session
        self.end = end
        self.changes = changes
    }
}

/// What an evaluation saw, for ``CalibrationSession/advanced(by:)``.
public struct CalibrationObservation: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case willSleep
        case didWake
        /// Any other evaluation.
        case check
    }

    public var now: CalibrationStamp
    public var event: Event
    /// A reading the policy accepts (``ChargingPolicy/usableSnapshot(_:now:)``),
    /// or nil; nothing that depends on the battery happens without one.
    public var reading: BatterySnapshot?
    /// macOS's Charge Limit at 100% was confirmed before ``reading`` was
    /// taken, and still is, so the reading shows the battery under it.
    public var isFullLimitHeld: Bool
    /// The run of CellKeeper observing.
    public var run: UUID
    /// The session was found at launch and the owner has not chosen
    /// "continue": only its endings apply.
    public var isPaused: Bool

    public init(now: CalibrationStamp, event: Event = .check, reading: BatterySnapshot?, isFullLimitHeld: Bool = false, run: UUID, isPaused: Bool = false) {
        self.now = now
        self.event = event
        self.reading = reading
        self.isFullLimitHeld = isFullLimitHeld
        self.run = run
        self.isPaused = isPaused
    }
}

/// What the owner choosing "continue" did.
public enum CalibrationContinuation: Sendable, Equatable {
    /// The session stays paused; the text says why.
    case refused(String)
    case progress(CalibrationProgress)
}

/// A guided battery calibration (note 12 §7): the steps CellKeeper guides,
/// with the times and readings it needs to know when each ends. Pure: every
/// clock and reading comes from the caller.
///
/// The session asks for macOS's Charge Limit at 100% only in steps 1, 2 and
/// 7 (``asksForFullLimit``), and leaves step 2 and step 7 only once the
/// normal limit is confirmed (``isReturning``, ``returnConfirmed(at:)``). It
/// never discharges anything. Every step but the drain and the rests has a
/// bound, and the session ends after 72 hours, whatever its step.
public struct CalibrationSession: Sendable, Equatable, Codable {
    /// The longest charge to full, steps 1 and 7.
    public static let chargeBound: TimeInterval = 6 * 3600
    /// The rest at the top, step 2, on the monotonic clock.
    public static let topRest: TimeInterval = 2 * 3600
    /// The longest wait for the owner to unplug, step 3.
    public static let unplugBound: TimeInterval = 4 * 3600
    /// The rest at the bottom, step 5: the time shown is at least this
    /// long after the step began.
    public static let bottomRest: TimeInterval = 5 * 3600
    /// A session ends after this, whatever its step.
    public static let maximumDuration: TimeInterval = 72 * 3600
    /// The drain's target.
    public static let targetPercent = 20
    /// At or below this charge no rest is requested, and before the rest
    /// has begun the session ends (note 06 R23: never below max(floor, 15%)).
    public static let lowBatteryPercent = 15
    /// How far the charge may fall during a counted sleep.
    public static let maximumSleepDrop = 3
    /// How far the wall clock may disagree with the monotonic clock over a
    /// counted sleep.
    public static let clockAgreement: TimeInterval = 10 * 60
    /// Note 06 R23's window for a gauge reading.
    public static let temperatureRange: ClosedRange<Double> = 10...40

    public var id: UUID
    public var startedAt: CalibrationStamp
    public var step: CalibrationStep
    /// When the current step began; for step 2, when its rest timer last
    /// started.
    public var stepStartedAt: CalibrationStamp
    /// Every step entered, in order.
    public var steps: [CalibrationStepEntry]
    /// When the owner chose "continue" after a relaunch.
    public var resumedAt: [Date]
    /// The session has left a 100% step and waits until the normal limit
    /// is confirmed ("returning to your limit").
    public var isReturning: Bool
    /// The owner's own macOS Charge Limit when the session started: the
    /// value to set in System Settings if CellKeeper cannot.
    public var ownerLimit: Int
    /// CellKeeper's own limit when the session started.
    public var cellKeeperLimit: Int
    public var before: CalibrationCapacities
    public var temperatureCheck: CalibrationTemperatureCheck
    /// A reading with a temperature has been seen; from then on a reading
    /// without one ends the session.
    public var hasSeenTemperature: Bool
    public var optimizedCharging: OptimizedChargingConfirmation
    /// The rests recorded as short, in the order they were.
    public var shortRests: [CalibrationStep]
    /// Step 5: the time shown to plug in again, at least
    /// ``bottomRest`` after the step began. Never moved later.
    public var plugInAfter: Date?
    /// Step 5: the owner has been asked once to rest again.
    public var isRestAgainRequested: Bool
    /// Step 5: the latest sleep announced.
    public var restSleep: CalibrationSleep?
    /// Step 5: the wake after ``restSleep``, in the same run.
    public var restWake: CalibrationStamp?
    /// Step 5: a wake was seen and no usable reading since.
    public var isAwaitingReadingAfterWake: Bool
    /// Step 5: the latest reading, for the owner's account after a restart.
    public var lastRestReading: CalibrationReading?
    /// Step 5, after a relaunch: why the rest cannot be confirmed if no
    /// later sleep is.
    public var restFallback: CalibrationRestReason?
    public var restResult: CalibrationRestResult?

    /// A new session, at step 1, started at `now`.
    public static func start(
        id: UUID,
        at now: CalibrationStamp,
        ownerLimit: Int,
        cellKeeperLimit: Int,
        before: CalibrationCapacities,
        temperatureCheck: CalibrationTemperatureCheck,
        optimizedCharging: OptimizedChargingConfirmation
    ) -> CalibrationSession {
        CalibrationSession(
            id: id,
            startedAt: now,
            step: .chargeToFull,
            stepStartedAt: now,
            steps: [CalibrationStepEntry(step: .chargeToFull, enteredAt: now.wall)],
            resumedAt: [],
            isReturning: false,
            ownerLimit: ownerLimit,
            cellKeeperLimit: cellKeeperLimit,
            before: before,
            temperatureCheck: temperatureCheck,
            hasSeenTemperature: temperatureCheck == .measured,
            optimizedCharging: optimizedCharging,
            shortRests: [],
            plugInAfter: nil,
            isRestAgainRequested: false,
            restSleep: nil,
            restWake: nil,
            isAwaitingReadingAfterWake: false,
            lastRestReading: nil,
            restFallback: nil,
            restResult: nil
        )
    }

    /// True while the session asks for macOS's Charge Limit at 100%: in
    /// steps 1, 2 and 7, and not once it is returning to the normal limit.
    /// A paused session asks for nothing; the caller checks that.
    public var asksForFullLimit: Bool {
        step.asksForFullLimit && !isReturning
    }

    /// The time shown to plug in again, rounded up to the next whole
    /// minute, so it is at least ``bottomRest`` after `start`.
    public static func plugInTime(after start: Date) -> Date {
        let seconds = start.addingTimeInterval(bottomRest).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.up) * 60)
    }

    // MARK: - Observations

    /// The session after `observation`: a step that ends, an ending, or no
    /// change. Endings come first and apply also while paused: the 72-hour
    /// cap, a step's bound (not while returning, as the step's work is
    /// done), the temperature (R23), an unexpected change of power (an
    /// unplug in step 1 or 7, a plug-in in step 4), and a charge at 15% or
    /// below before the rest has begun. Nothing else happens while paused.
    public func advanced(by observation: CalibrationObservation) -> CalibrationProgress {
        var session = self
        var changes: [CalibrationChange] = []
        let now = observation.now
        func ended(_ end: CalibrationEnd) -> CalibrationProgress {
            CalibrationProgress(session: self, end: end, changes: changes)
        }

        if now.elapsed(since: startedAt) >= Self.maximumDuration {
            return ended(.sessionCap)
        }
        if let bound = step.bound, !isReturning, now.elapsed(since: stepStartedAt) >= bound {
            return ended(.stepBound(step))
        }
        // A wake during the rest is noted whatever its reading: the first
        // usable reading after it, now or later, decides the rest.
        if step == .restAtBottom, !observation.isPaused, observation.event == .didWake,
           let sleep = restSleep, sleep.run == observation.run, sleep.at.isSameBoot(as: now) {
            session.restWake = now
            session.isAwaitingReadingAfterWake = true
            changes.append(.wakeRecorded)
        }
        guard let reading = observation.reading, let percent = reading.chargePercent else {
            return CalibrationProgress(session: session, changes: changes)
        }
        if let celsius = reading.temperatureCelsius.flatMap({ $0.isFinite ? $0 : nil }) {
            guard Self.temperatureRange.contains(celsius) else { return ended(.temperatureOutOfRange(celsius: celsius)) }
            session.hasSeenTemperature = true
        } else if hasSeenTemperature {
            return ended(.temperatureLost)
        }

        let isOnBattery = reading.powerSource == .battery
        let isPaused = observation.isPaused
        let isCharged = reading.isFullyCharged == true || (percent >= 100 && reading.isCharging == false)
        switch step {
        case .chargeToFull:
            if isOnBattery { return ended(.unplugged(.chargeToFull)) }
            if !isPaused, observation.isFullLimitHeld, isCharged {
                session.enter(.restAtTop, at: now, changes: &changes)
            }
        case .restAtTop:
            guard !isPaused else { break }
            if isOnBattery {
                session.leaveTopRestEarly(at: now, isRestComplete: isReturning || now.elapsed(since: stepStartedAt) >= Self.topRest, changes: &changes)
            } else if !isReturning, now.elapsed(since: stepStartedAt) >= Self.topRest {
                session.isReturning = true
                changes.append(.returning(from: .restAtTop))
            }
        case .unplug:
            if !isPaused, isOnBattery {
                session.enter(.drain, at: now, changes: &changes)
            }
        case .drain:
            if !isOnBattery { return ended(.pluggedInDuringDrain) }
            if percent <= Self.lowBatteryPercent { return ended(.lowBattery(percent: percent)) }
            if !isPaused, percent <= Self.targetPercent {
                session.enter(.restAtBottom, at: now, changes: &changes)
                // A sleep announced as the drain reaches its target begins
                // the rest at once.
                if observation.event == .willSleep {
                    _ = session.observeRest(observation, reading: reading, percent: percent, changes: &changes)
                }
            }
        case .restAtBottom:
            if let end = session.observeRest(observation, reading: reading, percent: percent, changes: &changes) {
                return ended(end)
            }
        case .plugIn:
            if !isPaused, !isOnBattery {
                session.enter(.finalCharge, at: now, changes: &changes)
            }
        case .finalCharge:
            if isOnBattery, !isReturning { return ended(.unplugged(.finalCharge)) }
            if !isPaused, !isReturning, observation.isFullLimitHeld, isCharged {
                session.isReturning = true
                changes.append(.returning(from: .finalCharge))
            }
        }
        return CalibrationProgress(session: session, changes: changes)
    }

    /// Step 5 (§7.6). In order: a wake is noted; the first usable reading
    /// after it decides the rest; a plug-in moves to step 7; a charge at
    /// 15% or below ends the session before the rest has begun, and moves
    /// to step 6 after; a sleep is noted; and the time shown, reached while
    /// awake on battery power, moves to step 6. While paused nothing
    /// applies: CellKeeper was not running, so the rest may have begun, and
    /// "continue" judges it.
    private mutating func observeRest(_ observation: CalibrationObservation, reading: BatterySnapshot, percent: Int, changes: inout [CalibrationChange]) -> CalibrationEnd? {
        guard !observation.isPaused else { return nil }
        let now = observation.now
        let isOnBattery = reading.powerSource == .battery
        let hasRestBegun = restSleep != nil
        let latest = CalibrationReading(at: now.wall, percent: percent, powerSource: reading.powerSource)
        if lastRestReading?.percent != percent || lastRestReading?.powerSource != reading.powerSource || observation.event == .willSleep {
            lastRestReading = latest
        }
        let isReached = isRestTimeReached(at: now)

        if isAwaitingReadingAfterWake {
            isAwaitingReadingAfterWake = false
            guard isOnBattery else {
                leaveRest(to: .finalCharge, result: .notConfirmed(.firstReadingOnPower), isShort: !isReached, at: now, changes: &changes)
                if !isReached { changes.append(.earlyPlugIn) }
                return nil
            }
            let result = countedResult(firstReading: percent, run: observation.run)
            if isReached || result.isCounted {
                leaveRest(to: .plugIn, result: result, isShort: !isReached && !result.isCounted, at: now, changes: &changes)
            } else if percent > Self.lowBatteryPercent, !isRestAgainRequested {
                isRestAgainRequested = true
                restFallback = restFallback ?? result.notConfirmedReason
                changes.append(.restAgainRequested)
            } else {
                leaveRest(to: .plugIn, result: result, isShort: true, at: now, changes: &changes)
            }
            return nil
        }
        if !isOnBattery {
            let reason: CalibrationRestReason = restSleep == nil ? (restFallback ?? .noSleepSeen) : .pluggedInAwake
            leaveRest(to: .finalCharge, result: .notConfirmed(reason), isShort: !isReached, at: now, changes: &changes)
            if !isReached { changes.append(.earlyPlugIn) }
            return nil
        }
        if percent <= Self.lowBatteryPercent {
            guard hasRestBegun else { return .lowBattery(percent: percent) }
            leaveRest(to: .plugIn, result: .notConfirmed(restWake == nil ? .noWakeSeen : (restFallback ?? .sleptTooShort)), isShort: !isReached, at: now, changes: &changes)
            return nil
        }
        if observation.event == .willSleep {
            restSleep = CalibrationSleep(at: now, run: observation.run, percent: percent, isOnBattery: isOnBattery)
            restWake = nil
            changes.append(.sleepRecorded(percent: percent, isOnBattery: isOnBattery))
            return nil
        }
        if isReached {
            let reason: CalibrationRestReason = restSleep == nil ? (restFallback ?? .noSleepSeen) : .noWakeSeen
            leaveRest(to: .plugIn, result: .notConfirmed(reason), isShort: false, at: now, changes: &changes)
        }
        return nil
    }

    /// Whether the last sleep, ended by the wake just seen, counts, judged
    /// with the first usable reading after that wake (on battery power).
    func countedResult(firstReading percent: Int, run: UUID) -> CalibrationRestResult {
        guard let sleep = restSleep else { return .notConfirmed(restFallback ?? .noSleepSeen) }
        guard let wake = restWake else { return .notConfirmed(.noWakeSeen) }
        guard sleep.run == run, wake.isSameBoot(as: sleep.at) else { return .notConfirmed(.cellKeeperRestarted) }
        guard let before = sleep.percent else { return .notConfirmed(.noReadingAtSleep) }
        guard sleep.isOnBattery else { return .notConfirmed(.notOnBatteryAtSleep) }
        guard (Self.lowBatteryPercent...Self.targetPercent).contains(before) else { return .notConfirmed(.chargeOutsideRangeAtSleep) }
        let slept = wake.monotonic - sleep.at.monotonic
        guard slept.isFinite, slept >= Self.bottomRest else { return .notConfirmed(.sleptTooShort) }
        let wallSlept = wake.wall.timeIntervalSince(sleep.at.wall)
        guard wallSlept.isFinite, abs(wallSlept - slept) <= Self.clockAgreement else { return .notConfirmed(.clockMoved) }
        guard percent <= before, percent >= before - Self.maximumSleepDrop else { return .notConfirmed(.chargeChanged) }
        return .counted(sleptFor: slept, fromPercent: before, toPercent: percent)
    }

    /// Step 5: whether the time shown has come, by the wall clock (what the
    /// owner reads) or, within the same boot, by the monotonic clock, so a
    /// clock set back never lengthens the time at a low charge.
    public func isRestTimeReached(at now: CalibrationStamp) -> Bool {
        guard step == .restAtBottom, let plugInAfter else { return false }
        if now.wall >= plugInAfter { return true }
        let length = plugInAfter.timeIntervalSince(stepStartedAt.wall)
        return now.isSameBoot(as: stepStartedAt) && now.monotonic - stepStartedAt.monotonic >= length
    }

    /// Step 5 after a relaunch: the Mac was started again since the step
    /// began, and the time shown has come, so the owner is asked whether it
    /// stayed shut down and unplugged until then.
    public func needsRestAnswer(at now: CalibrationStamp) -> Bool {
        step == .restAtBottom && !now.isSameBoot(as: stepStartedAt) && isRestTimeReached(at: now)
    }

    // MARK: - The owner's actions

    /// The session after the owner chose "continue", following a relaunch
    /// (§7.6 step 4), with `reading`, a usable one. Step 2's rest timer
    /// starts again; an unplug found then is the early unplug. In step 5
    /// the rest is judged as after a restart (`restAnswer`, the owner's
    /// answer, is needed once the time shown has come) or a relaunch in
    /// the same boot. The endings of ``advanced(by:)`` apply first.
    public func continued(at now: CalibrationStamp, reading: BatterySnapshot?, run: UUID, restAnswer: Bool?, bootTime: Date?) -> CalibrationContinuation {
        guard let reading, let percent = reading.chargePercent else {
            return .refused("CellKeeper has no current battery reading. Try again in a moment.")
        }
        let paused = advanced(by: CalibrationObservation(now: now, reading: reading, run: run, isPaused: true))
        if paused.end != nil { return .progress(paused) }
        var session = paused.session
        var changes = paused.changes
        let isOnBattery = reading.powerSource == .battery
        switch step {
        case .restAtTop:
            if isOnBattery {
                // Only a rest already complete before the relaunch counts:
                // CellKeeper cannot know whether the Mac stayed plugged in
                // while it was not running.
                session.leaveTopRestEarly(at: now, isRestComplete: isReturning, changes: &changes)
            } else {
                session.stepStartedAt = now
                session.isReturning = false
                changes.append(.topRestRestarted)
            }
        case .restAtBottom:
            let isRestarted = !now.isSameBoot(as: stepStartedAt)
            let isReached = isRestTimeReached(at: now)
            let result: CalibrationRestResult
            if isRestarted, isReached {
                guard let restAnswer else {
                    return .refused("Answer whether your Mac stayed shut down and unplugged until the time shown.")
                }
                result = restAnswer ? .ownersAccount(bootTime: bootTime, lastReading: lastRestReading) : .notConfirmed(.ownerSaidNo)
            } else {
                result = .notConfirmed(isRestarted ? .restartedBeforeTime : .cellKeeperRestarted)
            }
            session.restSleep = nil
            session.restWake = nil
            session.isAwaitingReadingAfterWake = false
            if !isOnBattery {
                session.leaveRest(to: .finalCharge, result: result, isShort: !isReached, at: now, changes: &changes)
                if !isReached { changes.append(.earlyPlugIn) }
            } else if isReached {
                session.leaveRest(to: .plugIn, result: result, isShort: false, at: now, changes: &changes)
            } else if percent > Self.lowBatteryPercent, !isRestAgainRequested {
                session.isRestAgainRequested = true
                session.restFallback = result.notConfirmedReason
                changes.append(.restAgainRequested)
            } else {
                session.leaveRest(to: .plugIn, result: result, isShort: true, at: now, changes: &changes)
            }
        case .chargeToFull, .unplug, .drain, .plugIn, .finalCharge:
            break
        }
        session.resumedAt.append(now.wall)
        changes.insert(.continued, at: 0)
        return .progress(CalibrationProgress(session: session, changes: changes))
    }

    /// The normal limit is confirmed by read-back while returning: step 2
    /// moves on to step 3, step 7 completes the session, and an early
    /// unplug's return in step 4 is done.
    public func returnConfirmed(at now: CalibrationStamp) -> CalibrationProgress {
        guard isReturning else { return CalibrationProgress(session: self) }
        var session = self
        var changes: [CalibrationChange] = [.returnConfirmed]
        session.isReturning = false
        switch step {
        case .restAtTop:
            session.enter(.unplug, at: now, changes: &changes)
        case .finalCharge:
            return CalibrationProgress(session: session, end: .completed, changes: changes)
        case .chargeToFull, .unplug, .drain, .restAtBottom, .plugIn:
            break
        }
        return CalibrationProgress(session: session, changes: changes)
    }

    // MARK: - Display

    /// When the current step ends at the latest, as a wall-clock estimate
    /// derived at `now`: the bound of steps 1, 3 and 7, the end of the rest
    /// at the top, and the time shown in step 5. Nil for steps that end on
    /// the battery's state, and while returning.
    public func stepEndEstimate(at now: CalibrationStamp) -> Date? {
        if step == .restAtBottom { return plugInAfter }
        guard !isReturning else { return nil }
        let length: TimeInterval
        if let bound = step.bound {
            length = bound
        } else if step == .restAtTop {
            length = Self.topRest
        } else {
            return nil
        }
        return now.wall.addingTimeInterval(max(length - now.elapsed(since: stepStartedAt), 0))
    }

    /// When the 72-hour cap ends the session, as a wall-clock estimate at
    /// `now`.
    public func capEstimate(at now: CalibrationStamp) -> Date {
        now.wall.addingTimeInterval(max(Self.maximumDuration - now.elapsed(since: startedAt), 0))
    }

    // MARK: - Moving between steps

    private mutating func enter(_ next: CalibrationStep, at now: CalibrationStamp, changes: inout [CalibrationChange]) {
        step = next
        stepStartedAt = now
        steps.append(CalibrationStepEntry(step: next, enteredAt: now.wall))
        if next == .restAtBottom {
            plugInAfter = Self.plugInTime(after: now.wall)
            isRestAgainRequested = false
            restSleep = nil
            restWake = nil
            isAwaitingReadingAfterWake = false
            restFallback = nil
            restResult = nil
        }
        changes.append(.entered(next))
    }

    /// An unplug in step 2, accepted (owner, 2026-10-21): on to the drain,
    /// the rest short unless it had already lasted its 2 hours
    /// (`isRestComplete`, judged by the caller on the monotonic clock), and
    /// the return to the normal limit requested at once if it was not
    /// already.
    private mutating func leaveTopRestEarly(at now: CalibrationStamp, isRestComplete: Bool, changes: inout [CalibrationChange]) {
        let isShort = !isRestComplete
        if isShort, !shortRests.contains(.restAtTop) {
            shortRests.append(.restAtTop)
        }
        changes.append(.earlyUnplug(restShort: isShort))
        if !isReturning {
            changes.append(.returning(from: .restAtTop))
        }
        isReturning = true
        enter(.drain, at: now, changes: &changes)
    }

    private mutating func leaveRest(to next: CalibrationStep, result: CalibrationRestResult, isShort: Bool, at now: CalibrationStamp, changes: inout [CalibrationChange]) {
        restResult = result
        isAwaitingReadingAfterWake = false
        changes.append(.restResult(result))
        if isShort {
            if !shortRests.contains(.restAtBottom) { shortRests.append(.restAtBottom) }
            changes.append(.restShort(.restAtBottom))
        }
        enter(next, at: now, changes: &changes)
    }
}

extension CalibrationRestResult {
    var isCounted: Bool {
        if case .counted = self { return true }
        return false
    }

    var notConfirmedReason: CalibrationRestReason? {
        if case .notConfirmed(let reason) = self { return reason }
        return nil
    }
}

/// What remains of a session once it ended: what Settings, the activity
/// log and the diagnostics report show (§7.9).
public struct CalibrationReport: Sendable, Equatable, Codable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var end: CalibrationEnd
    /// The step the session was in when it ended.
    public var lastStep: CalibrationStep
    public var steps: [CalibrationStepEntry]
    public var resumedAt: [Date]
    public var before: CalibrationCapacities
    /// From the latest usable reading when it ended; nil if there was none.
    public var after: CalibrationCapacities?
    public var restResult: CalibrationRestResult?
    public var shortRests: [CalibrationStep]
    public var temperatureCheck: CalibrationTemperatureCheck
    public var optimizedCharging: OptimizedChargingConfirmation
    public var ownerLimit: Int
    public var cellKeeperLimit: Int

    public init(_ session: CalibrationSession, end: CalibrationEnd, at endedAt: Date, after: CalibrationCapacities?) {
        id = session.id
        startedAt = session.startedAt.wall
        self.endedAt = endedAt
        self.end = end
        lastStep = session.step
        steps = session.steps
        resumedAt = session.resumedAt
        before = session.before
        self.after = after
        restResult = session.restResult
        shortRests = session.shortRests
        temperatureCheck = session.temperatureCheck
        optimizedCharging = session.optimizedCharging
        ownerLimit = session.ownerLimit
        cellKeeperLimit = session.cellKeeperLimit
    }

    /// The steps finished: every step entered before the last one, and the
    /// last one too if the session completed.
    public var stepsDone: [CalibrationStep] {
        var done = steps.dropLast().map(\.step)
        if end.isCompleted, let last = steps.last?.step { done.append(last) }
        var seen = Set<CalibrationStep>()
        return done.filter { seen.insert($0).inserted }
    }
}
