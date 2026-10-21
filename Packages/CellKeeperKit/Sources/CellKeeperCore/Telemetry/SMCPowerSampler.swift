import Foundation

/// The state of the power flow's SMC source (research note 13 §6.3). Its
/// description names it in plain words for the diagnostics report; the raw
/// value is its identifier.
public enum SMCSourceState: String, Sendable, Equatable, CaseIterable, CustomStringConvertible {
    /// The build has no reader (its switch is off): nothing is ever read.
    case absent
    /// The reader exists and is not yet trusted: the start, and the state
    /// after a successful open while backing off.
    case probing
    /// Three batches in a row were valid: windows are published.
    case available
    /// Recently invalid or stalled.
    case failing
    /// The user client could not be opened; an attempt is made again later.
    case backingOff

    public var description: String {
        switch self {
        case .absent: "absent (not in this build)"
        case .probing: "probing"
        case .available: "available"
        case .failing: "failing"
        case .backingOff: "backing off"
        }
    }
}

/// The average of the valid batches the SMC source read since the last
/// hand-out (research note 13 §6.4), each batch weighted equally.
public struct SMCPowerWindow: Sendable, Equatable {
    /// When the first batch began, on the continuous clock: windows are
    /// ordered by it, among themselves only.
    public let firstBatchBegan: ContinuousClock.Instant
    /// When the last batch returned, on the continuous clock.
    public let lastBatchReturned: ContinuousClock.Instant
    /// When the last batch returned, on the wall clock: a collection time,
    /// not a firmware update time, so that no two windows share one in the
    /// history.
    public let collectedAt: Date
    /// How many batches it averages.
    public let batches: Int
    /// `PSTR`'s average.
    public let macUseWatts: Double
    /// `PDTR`'s average, or nil unless every batch has a valid one.
    public let adapterInputWatts: Double?
    /// `B0AP`'s average, or nil unless every batch has a valid one (and it is
    /// read only once its sign is verified).
    public let batteryWatts: Double?

    public init(
        firstBatchBegan: ContinuousClock.Instant,
        lastBatchReturned: ContinuousClock.Instant,
        collectedAt: Date,
        batches: Int,
        macUseWatts: Double,
        adapterInputWatts: Double?,
        batteryWatts: Double?
    ) {
        self.firstBatchBegan = firstBatchBegan
        self.lastBatchReturned = lastBatchReturned
        self.collectedAt = collectedAt
        self.batches = batches
        self.macUseWatts = macUseWatts
        self.adapterInputWatts = adapterInputWatts
        self.batteryWatts = batteryWatts
    }

    /// The span it averages, from the first batch's start to the last one's
    /// return, rounded up to whole seconds and at least one: each reading
    /// stands for the second until the next, so three batches a second
    /// apart average about 3 s.
    public var averagedOver: Duration {
        let span = lastBatchReturned - firstBatchBegan
        let parts = span.components
        let seconds = (Double(parts.seconds) + Double(parts.attoseconds) / 1e18).rounded(.up)
        return .seconds(max(1, Int(seconds.isFinite ? seconds : 1)))
    }
}

/// What the SMC source hands the refresher at one of its ticks: its state,
/// and the window since the last hand-out if it is available and read at
/// least one valid batch.
public struct SMCPowerPublication: Sendable, Equatable {
    public let state: SMCSourceState
    public let window: SMCPowerWindow?

    public init(state: SMCSourceState, window: SMCPowerWindow?) {
        self.state = state
        self.window = window
    }

    /// A build without a reader.
    public static let absent = SMCPowerPublication(state: .absent, window: nil)
}

/// The SMC source's logic (research note 13 §6.2–§6.4), as a value with
/// every instant given, so that it is deterministic: which batch to start
/// and when, the deadline, the generations, the states and their counts,
/// and the windows. ``SMCPowerCoordinator`` drives it with a timer and runs
/// the batches on the reader's thread. Display only: nothing here reaches
/// the policy, the controller or the calibration.
struct SMCPowerSampler: Sendable, Equatable {
    /// Whether `B0AP`'s sign is known, so that it is asked for and may give
    /// the battery's power. Off until research note 13's O1 settles it: the
    /// battery's power then comes from macOS's battery data.
    static let isBatteryPowerVerified = false

    struct Configuration: Sendable, Equatable {
        /// A batch not returned this long after it began is stalled.
        var deadline: Duration = .seconds(2)
        /// The batches in a row, valid or invalid, that change the state.
        var batchesToChangeState = 3
        /// The first wait after a failed open, doubled after each further
        /// one up to ``longestBackoff``.
        var firstBackoff: Duration = .seconds(30)
        var longestBackoff: Duration = .seconds(5 * 60)
        /// How long after a power-source change no batch begins.
        var settleAfterPowerSourceChange: Duration = .seconds(1)
        var isBatteryPowerVerified = SMCPowerSampler.isBatteryPowerVerified
    }

    /// What a batch's call to the reader gave.
    enum Outcome: Sendable, Equatable {
        /// The user client opened; each key's value or why it has none.
        case read([SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>])
        /// The user client could not be opened.
        case openFailed
    }

    /// The batch handed to the reader and not yet returned: the physical
    /// in-flight flag.
    struct InFlight: Sendable, Equatable {
        let generation: Int
        let began: ContinuousClock.Instant
        var isStalled = false
    }

    /// A valid batch, waiting in the window.
    struct Batch: Sendable, Equatable {
        let began: ContinuousClock.Instant
        let returned: ContinuousClock.Instant
        let collectedAt: Date
        let macUseWatts: Double
        let adapterInputWatts: Double?
        let batteryWatts: Double?
    }

    let configuration: Configuration
    private(set) var state: SMCSourceState = .probing
    /// The generation a batch must carry for its result to count: retired
    /// at a stall and at every reset, so that a late result is dropped.
    private(set) var generation = 0
    /// Set when a batch is handed to the reader, cleared only when that call
    /// returns, whatever happened meanwhile: no batch starts while it is set.
    private(set) var inFlight: InFlight?
    /// Valid and invalid batches in a row (a stall counts as invalid),
    /// independent of the windows.
    private(set) var consecutiveValid = 0
    private(set) var consecutiveInvalid = 0
    /// Whether the menu is open with the Power flow section expanded.
    private(set) var isShown = false
    /// The registry track's power source: on external power a batch needs a
    /// valid `PDTR`.
    private(set) var powerSource: PowerSource?
    /// The valid batches since the last hand-out, while available.
    private(set) var window: [Batch] = []
    /// While backing off: when to try opening again, and the wait after
    /// which that attempt was set.
    private(set) var nextOpenAttempt: ContinuousClock.Instant?
    private(set) var backoff: Duration?
    /// No batch begins before this, after a power-source change.
    private var settledAt: ContinuousClock.Instant?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The keys each batch asks for: `PSTR` and `PDTR`, and `B0AP` once its
    /// sign is verified.
    var keys: [SMCPowerKey] {
        configuration.isBatteryPowerVerified ? [.systemTotalPower, .adapterInputPower, .batteryPower] : [.systemTotalPower, .adapterInputPower]
    }

    // MARK: - Lifecycle

    /// The section is shown: batches may begin.
    mutating func show() {
        isShown = true
    }

    /// The section collapsed or the menu closed: no batch begins, and the
    /// window resets.
    mutating func hide() {
        isShown = false
        reset()
    }

    /// Clears the window and retires the generation, so that a batch in
    /// flight is dropped when it returns: the section hidden, a wake, a
    /// power-source change. The state, its counts and the in-flight flag
    /// stay.
    mutating func reset() {
        window = []
        generation += 1
    }

    /// The registry track's power source. A change from a known one resets,
    /// and no batch begins for a second after it, so that a window never
    /// mixes plugged-in and battery readings.
    mutating func setPowerSource(_ source: PowerSource?, at now: ContinuousClock.Instant) {
        guard let source else { return }
        defer { powerSource = source }
        guard let previous = powerSource, previous != source else { return }
        reset()
        settledAt = now.advanced(by: configuration.settleAfterPowerSourceChange)
    }

    // MARK: - Batches

    /// The timer's tick, once a second: marks a batch in flight past its
    /// deadline as stalled, and begins a batch if one may begin now,
    /// returning the generation it carries. None begins while one is in
    /// flight, while the section is hidden, within a second of a
    /// power-source change, or while backing off before the next attempt.
    mutating func tick(at now: ContinuousClock.Instant) -> Int? {
        if var flight = inFlight {
            if !flight.isStalled, now - flight.began >= configuration.deadline {
                flight.isStalled = true
                inFlight = flight
                stall(at: now)
            }
            return nil
        }
        guard isShown else { return nil }
        if let settledAt, now < settledAt { return nil }
        if state == .backingOff {
            guard let next = nextOpenAttempt, now >= next else { return nil }
        }
        inFlight = InFlight(generation: generation, began: now)
        return generation
    }

    /// A batch past its deadline: it is not cancelled (a read cannot be),
    /// but its result will be dropped, and it counts as a failure. An open
    /// attempt that hangs while backing off counts as a failed open.
    private mutating func stall(at now: ContinuousClock.Instant) {
        generation += 1
        if state == .backingOff {
            backOff(at: now)
            return
        }
        countInvalid()
        if state == .available {
            fail()
        }
    }

    /// The reader's call returned. The in-flight flag clears whatever the
    /// batch's generation; a retired generation's result is dropped.
    mutating func batchReturned(generation batchGeneration: Int, outcome: Outcome, at now: ContinuousClock.Instant, collectedAt: Date) {
        guard let flight = inFlight else { return }
        inFlight = nil
        guard batchGeneration == generation else { return }
        switch outcome {
        case .openFailed:
            backOff(at: now)
        case .read(let values):
            if state == .backingOff {
                state = .probing
                nextOpenAttempt = nil
                backoff = nil
                consecutiveValid = 0
                consecutiveInvalid = 0
            }
            guard isValid(values), let macUse = SMCPowerDecoding.watts(in: values, for: .systemTotalPower) else {
                countInvalid()
                if state == .available, consecutiveInvalid >= configuration.batchesToChangeState {
                    fail()
                }
                return
            }
            countValid(Batch(
                began: flight.began,
                returned: now,
                collectedAt: collectedAt,
                macUseWatts: macUse,
                adapterInputWatts: SMCPowerDecoding.watts(in: values, for: .adapterInputPower),
                batteryWatts: configuration.isBatteryPowerVerified ? SMCPowerDecoding.watts(in: values, for: .batteryPower) : nil
            ))
        }
    }

    /// A valid batch has a valid `PSTR` and, on external power, a valid
    /// `PDTR`. On battery `PDTR` is not used, so a small reading there is
    /// not a fault; `B0AP` never makes a batch invalid.
    func isValid(_ values: [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>]) -> Bool {
        guard SMCPowerDecoding.watts(in: values, for: .systemTotalPower) != nil else { return false }
        if powerSource == .externalPower {
            return SMCPowerDecoding.watts(in: values, for: .adapterInputPower) != nil
        }
        return true
    }

    /// A valid batch: the third in a row makes the source available, and
    /// while it is, the batch joins the window (the third included).
    private mutating func countValid(_ batch: Batch) {
        consecutiveValid += 1
        consecutiveInvalid = 0
        if state != .available, consecutiveValid >= configuration.batchesToChangeState {
            state = .available
        }
        if state == .available {
            window.append(batch)
        }
    }

    private mutating func countInvalid() {
        consecutiveInvalid += 1
        consecutiveValid = 0
    }

    private mutating func fail() {
        state = .failing
        window = []
    }

    /// The user client could not be opened: back off, 30 s after the first
    /// failure, twice as long after each further one, at most 5 minutes.
    private mutating func backOff(at now: ContinuousClock.Instant) {
        let wait = backoff.map { min($0 * 2, configuration.longestBackoff) } ?? configuration.firstBackoff
        state = .backingOff
        backoff = wait
        nextOpenAttempt = now.advanced(by: wait)
        consecutiveValid = 0
        consecutiveInvalid = 0
        window = []
    }

    // MARK: - Windows

    /// Hands out the window, once: while available, the average of its valid
    /// batches if it has any, otherwise nothing new. The window is then
    /// empty; the counts stay.
    mutating func publish() -> SMCPowerPublication {
        defer { window = [] }
        guard state == .available, let first = window.first, let last = window.last else {
            return SMCPowerPublication(state: state, window: nil)
        }
        func average(_ values: [Double]) -> Double {
            values.reduce(0, +) / Double(values.count)
        }
        func averageOfAll(_ values: [Double?]) -> Double? {
            let known = values.compactMap { $0 }
            return known.count == values.count ? average(known) : nil
        }
        return SMCPowerPublication(state: state, window: SMCPowerWindow(
            firstBatchBegan: first.began,
            lastBatchReturned: last.returned,
            collectedAt: last.collectedAt,
            batches: window.count,
            macUseWatts: average(window.map(\.macUseWatts)),
            adapterInputWatts: averageOfAll(window.map(\.adapterInputWatts)),
            batteryWatts: averageOfAll(window.map(\.batteryWatts))
        ))
    }
}
