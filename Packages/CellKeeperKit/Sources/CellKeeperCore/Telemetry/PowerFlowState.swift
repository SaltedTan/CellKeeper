import Foundation

/// One delivery of the menu's refresher, every 3 s while it reads
/// (``PowerFlowRefresh``): an SMC window, a display read of the registry
/// track's source, or nothing (that read failed), with the SMC source's
/// state and the moment of delivery. Every tick is delivered, so that the
/// display is decided again at each (research note 13 §6.4).
public struct PowerFlowTick: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// The SMC source's window since the last tick.
        case window(SMCPowerWindow)
        /// A display read of the registry track's source.
        case registry(PowerFlowSample)
        /// The read failed, or nothing else was there.
        case empty
    }

    public var content: Content
    /// The SMC source's state at this tick; ``SMCSourceState/absent``
    /// without a reader.
    public var smcState: SMCSourceState
    /// When the tick was delivered, on the continuous clock.
    public var at: ContinuousClock.Instant

    public init(content: Content, smcState: SMCSourceState = .absent, at: ContinuousClock.Instant) {
        self.content = content
        self.smcState = smcState
        self.at = at
    }
}

/// What the menu's power flow shows: the flow of the sample on screen, where
/// it came from, and the history. In memory only; display only (D114, D115).
///
/// Two tracks (research note 13 §6.4):
/// - **The registry track** is kept by D114's rules whatever the SMC does:
///   every controller status goes through it, with its ordering and its
///   repeat rule, and so does every display read of the source.
/// - **The SMC track** holds the last accepted SMC window and the moment it
///   was accepted. Windows are ordered among themselves only, by when their
///   first batch began, never against registry readings.
///
/// One rule decides what is shown: the SMC track while the SMC source is
/// available and its window was accepted less than ``smcFreshness`` ago;
/// otherwise the registry track. It is decided again at every tick, an
/// empty one included, so a stalled or failing SMC cannot keep an old
/// average on screen.
///
/// The registry track's reading is judged too, at every tick and status,
/// at the moment it is delivered: one the charging policy would not accept
/// as current (``isCurrent(_:now:at:)``), a frozen driver's or a cached one
/// after failed reads, is not shown on the registry track, and an SMC
/// window neither borrows its battery power nor keeps a borrowed one once
/// it is no longer current. A fresh SMC window still shows its own values.
public struct PowerFlowState: Sendable, Equatable {
    /// Which track is on screen.
    public enum Track: Sendable, Equatable {
        case registry
        case smc
    }

    /// How long an accepted SMC window may stay on screen: two of the
    /// refresher's ticks.
    public static let smcFreshness: Duration = .seconds(6)

    /// The registry track: the reading shown on it, ordered by when its read
    /// began, and the last controller status taken.
    private struct RegistryTrack: Sendable, Equatable {
        /// Nil before the first sample, and after the controller's read
        /// failed until the next sample.
        var sample: PowerFlowSample?
        /// When the read shown began, on the continuous clock: a read that
        /// began earlier never replaces it, whatever the wall clock did
        /// meanwhile.
        var shownReadBegan: ContinuousClock.Instant?
        /// The evaluation time and reading of the last controller status
        /// taken: one delivered again, by a command that read nothing, adds
        /// nothing.
        var lastStatusEvaluation: Date?
        var lastStatusSnapshot: BatterySnapshot?
    }

    /// The SMC track: the accepted window, as a sample with the registry
    /// track's metadata.
    private struct SMCTrack: Sendable, Equatable {
        var sample: PowerFlowSample
        let acceptedAt: ContinuousClock.Instant
        /// The registry reading whose battery power the window borrowed
        /// (it had no `B0AP`), judged again at every tick and status like
        /// that track; nil when the battery power is the SMC's own, or was
        /// dropped once the reading was no longer current.
        var batterySource: PowerFlowSample?
    }

    /// The last SMC window recorded in the history: registry readings
    /// updated before it are not recorded while it is recent, so that the
    /// chart never puts a minute's snapshot among 3 s averages.
    private struct RecordedWindow: Sendable, Equatable {
        let collectedAt: Date
        let acceptedAt: ContinuousClock.Instant
    }

    private var registry = RegistryTrack()
    private var smc: SMCTrack?
    /// When the first batch of the last accepted window began.
    private var lastWindowBegan: ContinuousClock.Instant?
    /// When the SMC track was last cleared (the section hidden, a wake, the
    /// read that showed a new power source): a window whose first batch
    /// began before then holds readings from before that reset and is never
    /// accepted, even if it was published before the reset and arrives after
    /// it.
    private var smcCutoff: ContinuousClock.Instant?
    private var lastRecordedWindow: RecordedWindow?
    /// Whether the registry track's reading was current
    /// (``isCurrent(_:now:at:)``) when last judged, at the moment the last
    /// tick or status was delivered; true without a reading. Kept rather
    /// than that moment, so that the menu redraws only when the judgment
    /// changes.
    private var isRegistryCurrent = true
    /// The registry track's power source, kept after a failed read.
    public private(set) var registryPowerSource: PowerSource?
    /// The SMC source's state at the last tick; nil before the first.
    public private(set) var smcState: SMCSourceState?
    public private(set) var shownTrack: Track = .registry
    public private(set) var history = PowerFlowHistory()

    public init() {}

    /// The sample on screen, from the track shown; nil on the registry
    /// track while its reading is not current (``isCurrent(_:now:at:)``).
    /// A fresh SMC window is shown whatever the registry track's reading,
    /// without a battery power borrowed from one that is not current.
    public var shownSample: PowerFlowSample? {
        switch shownTrack {
        case .registry: isRegistryCurrent ? registry.sample : nil
        case .smc: smc?.sample
        }
    }

    /// The flow on screen; nil before the first sample, after the
    /// controller's read failed, while the registry track is shown and its
    /// reading is not current, or when the sample has no power use for the
    /// Mac.
    public var flow: PowerFlow? {
        shownSample.flatMap(PowerFlow.init)
    }

    /// Whether a sample is on screen: false before the first, after the
    /// controller's read failed until the next one, and while the registry
    /// track is shown and its reading is not current.
    public var hasSample: Bool {
        shownSample != nil
    }

    /// Where the sample on screen came from, for the menu's note.
    public var provenance: PowerFlowProvenance? {
        shownSample?.provenance
    }

    // MARK: - Freshness

    /// Whether `sample`'s values may be shown as current when delivered at
    /// `now` on the wall clock and `instant` on the continuous clock, by
    /// both of the charging policy's checks (``ChargingPolicy/staleness(of:now:)``)
    /// with its own limits, so that the display never shows as current a
    /// value the policy would not act on:
    /// - **The read's age**, from when it began (``PowerFlowSample/readBegan``)
    ///   to `instant`: at most ``ChargingPolicy/maximumTelemetryAge``, and
    ///   no more than ``ChargingPolicy/maximumClockSkew`` ahead. On the
    ///   continuous clock, which the track already orders reads by, so that
    ///   a change of the wall clock never makes an old read look new; and
    ///   from when the read began, never from a redelivery.
    /// - **The driver's update time** (``PowerFlowSample/updatedAt``) to
    ///   `now`: at most ``ChargingPolicy/maximumSourceAge`` old and
    ///   ``ChargingPolicy/maximumClockSkew`` ahead.
    ///
    /// A check whose time the sample lacks is not made.
    static func isCurrent(_ sample: PowerFlowSample, now: Date, at instant: ContinuousClock.Instant) -> Bool {
        if let began = sample.readBegan {
            let parts = (instant - began).components
            let readAge = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            if readAge > ChargingPolicy.maximumTelemetryAge || readAge < -ChargingPolicy.maximumClockSkew { return false }
        }
        if let updated = sample.updatedAt {
            let sourceAge = now.timeIntervalSince(updated)
            if sourceAge > ChargingPolicy.maximumSourceAge || sourceAge < -ChargingPolicy.maximumClockSkew { return false }
        }
        return true
    }

    /// Judges the registry track's reading, and the battery power the SMC
    /// track borrowed from it, delivered at `now` and `instant`. A borrowed
    /// power no longer current is dropped; the window's own values stay.
    private mutating func judge(now: Date, at instant: ContinuousClock.Instant) {
        isRegistryCurrent = registry.sample.map { Self.isCurrent($0, now: now, at: instant) } ?? true
        if let source = smc?.batterySource, !Self.isCurrent(source, now: now, at: instant) {
            smc?.sample.batteryWatts = nil
            smc?.batterySource = nil
        }
    }

    // MARK: - Ticks

    /// Takes the refresher's tick, delivered at `now` on the wall clock and
    /// at its instant on the continuous clock: judges what is shown then,
    /// decides the display, takes its content (a window into the SMC track,
    /// a display read into the registry track), and decides again.
    public mutating func take(_ tick: PowerFlowTick, now: Date) {
        smcState = tick.smcState
        history.restartIfClockSetBack(now: now)
        judge(now: now, at: tick.at)
        decideDisplay(at: tick.at)
        switch tick.content {
        case .window(let window): accept(window, at: tick.at)
        case .registry(let sample): take(sample, now: now, deliveredAt: tick.at)
        case .empty: break
        }
        decideDisplay(at: tick.at)
    }

    /// The one rule: the SMC track while the source is available and its
    /// window is under ``smcFreshness`` old, otherwise the registry track.
    private mutating func decideDisplay(at now: ContinuousClock.Instant) {
        if smcState == .available, let smc, now - smc.acceptedAt < Self.smcFreshness {
            shownTrack = .smc
        } else {
            shownTrack = .registry
        }
    }

    /// Takes an SMC window into the SMC track, with the registry track's
    /// power source, adapter rating and charge, and its battery power unless
    /// every batch had a valid `B0AP`. While the registry track's reading is
    /// not current, that battery power is not known instead, and a borrowed
    /// one is judged again with that reading at every later tick and status
    /// (``SMCTrack/batterySource``), so a fresh window never makes an old
    /// value look current. Not accepted while the source is not available,
    /// without a known power source in the registry track, when it began no
    /// later than the last window, or before the last reset of the SMC
    /// track, which includes the read that showed the current power source.
    /// Recorded in the history once, here.
    private mutating func accept(_ window: SMCPowerWindow, at now: ContinuousClock.Instant) {
        guard smcState == .available,
              let reading = registry.sample,
              reading.powerSource == .externalPower || reading.powerSource == .battery
        else { return }
        if let lastWindowBegan, window.firstBatchBegan <= lastWindowBegan { return }
        if let smcCutoff, window.firstBatchBegan < smcCutoff { return }
        lastWindowBegan = window.firstBatchBegan
        let borrowsBattery = window.batteryWatts == nil && isRegistryCurrent && reading.batteryWatts != nil
        let sample = PowerFlowSample(
            updatedAt: window.collectedAt,
            readBegan: window.firstBatchBegan,
            powerSource: reading.powerSource,
            adapterRatingWatts: reading.adapterRatingWatts,
            chargePercent: reading.chargePercent,
            systemPowerInWatts: window.adapterInputWatts,
            systemLoadWatts: window.macUseWatts,
            batteryWatts: window.batteryWatts ?? (borrowsBattery ? reading.batteryWatts : nil),
            provenance: PowerFlowProvenance(
                system: .smc(averagedOver: window.averagedOver),
                battery: window.batteryWatts == nil ? .registry : .smc
            )
        )
        smc = SMCTrack(sample: sample, acceptedAt: now, batterySource: borrowsBattery ? reading : nil)
        history.record(sample)
        lastRecordedWindow = RecordedWindow(collectedAt: window.collectedAt, acceptedAt: now)
    }

    /// Clears the SMC track at `now`, on the continuous clock, so that the
    /// registry track is shown at once: every reset of the SMC source (the
    /// section hidden, a wake) and a power-source change, so that a diagram
    /// accepted just before an unplug never stays on screen after it. A
    /// window whose first batch began before `now` is not accepted later
    /// either: one published before the reset may still be on its way. A
    /// window read after `now` (the menu reopened before a late clear) stays.
    public mutating func clearSMCTrack(at now: ContinuousClock.Instant) {
        raiseCutoff(to: now)
        if let began = smc?.sample.readBegan, began >= now { return }
        dropSMCTrack()
    }

    private mutating func raiseCutoff(to cutoff: ContinuousClock.Instant) {
        smcCutoff = max(smcCutoff ?? cutoff, cutoff)
    }

    private mutating func dropSMCTrack() {
        smc = nil
        shownTrack = .registry
    }

    // MARK: - The registry track

    /// Takes a display read into the registry track. The track shows the
    /// read that began last: a sample whose read began before the one it
    /// shows only joins the history, even when both carry the same update.
    /// One whose start is unknown is taken. Recorded in the history only
    /// while the registry track is on screen (a power-source change it
    /// shows puts it there at once). What is shown is then judged as
    /// delivered at `now` on the wall clock and `instant` on the continuous
    /// clock (``isCurrent(_:now:at:)``).
    public mutating func take(_ sample: PowerFlowSample, now: Date, deliveredAt instant: ContinuousClock.Instant) {
        history.restartIfClockSetBack(now: now)
        defer { judge(now: now, at: instant) }
        var isNewest = true
        if let began = sample.readBegan, let shownReadBegan = registry.shownReadBegan, began < shownReadBegan {
            isNewest = false
        }
        if isNewest {
            notePowerSource(sample.powerSource, since: sample.readBegan)
        }
        if shownTrack == .registry, !predatesRecordedWindow(sample) {
            history.record(sample)
        }
        guard isNewest else { return }
        if let began = sample.readBegan {
            registry.shownReadBegan = began
        }
        registry.sample = sample
    }

    /// Takes a controller status into the registry track, for work that
    /// began at `readBegan` on the continuous clock, so that no read made
    /// for it began earlier: its reading, ordered from then, or its failed
    /// read, which empties the track unless the read it shows began after
    /// that work did. A status with the evaluation time and the reading (or
    /// failed read) of the last one taken is that one delivered again (a
    /// command that read nothing returns the last status), and adds nothing,
    /// whichever track is shown, so a failure or a reading never moves
    /// forward in time. Two evaluations stamped alike that read differently
    /// both count. A failed read that empties the track records a break in
    /// the history at `now`, so the chart never draws across it. What is
    /// shown is then judged as delivered at `now` on the wall clock and
    /// `instant` on the continuous clock (``isCurrent(_:now:at:)``): a
    /// status delivered again changes nothing, so it never makes its
    /// reading look newer.
    public mutating func takeStatus(
        snapshot: BatterySnapshot?,
        evaluatedAt: Date?,
        readBegan: ContinuousClock.Instant,
        now: Date,
        deliveredAt instant: ContinuousClock.Instant
    ) {
        history.restartIfClockSetBack(now: now)
        defer { judge(now: now, at: instant) }
        if let evaluatedAt {
            guard evaluatedAt != registry.lastStatusEvaluation || snapshot != registry.lastStatusSnapshot else { return }
            registry.lastStatusEvaluation = evaluatedAt
            registry.lastStatusSnapshot = snapshot
        }
        if let snapshot {
            var sample = PowerFlowSample(snapshot)
            sample.readBegan = readBegan
            take(sample, now: now, deliveredAt: instant)
            return
        }
        if let shownReadBegan = registry.shownReadBegan, readBegan < shownReadBegan { return }
        registry.shownReadBegan = readBegan
        if registry.sample != nil {
            history.recordBreak(at: now)
        }
        registry.sample = nil
    }

    /// Notes the registry track's power source. A new one, the first
    /// included, clears the SMC track from when the read that showed it
    /// began: a window whose batches began earlier may hold readings from
    /// another power source, or ones judged before any was known (the app
    /// also resets the SMC source on a change). The accepted window goes
    /// whenever it was read: its metadata is from the old power source.
    private mutating func notePowerSource(_ source: PowerSource, since began: ContinuousClock.Instant?) {
        guard source != registryPowerSource else { return }
        registryPowerSource = source
        if let began {
            raiseCutoff(to: began)
        }
        dropSMCTrack()
    }

    /// Whether `sample` was updated no later than the last SMC window
    /// recorded, while that window is recent (within the history's
    /// ``PowerFlowHistory/reorderTolerance`` of the read's start): such a
    /// reading would land among the window's points. Older windows no
    /// longer hold readings back, so a clock set back cannot stop the
    /// history for long.
    private func predatesRecordedWindow(_ sample: PowerFlowSample) -> Bool {
        guard let window = lastRecordedWindow, let updated = sample.updatedAt, updated <= window.collectedAt else { return false }
        guard let began = sample.readBegan else { return true }
        return began - window.acceptedAt <= .seconds(PowerFlowHistory.reorderTolerance)
    }
}

/// What the diagnostics report and Settings › Diagnostics say about the
/// power flow's source: no values, only where the flow on screen comes from
/// and the SMC source's state.
public struct PowerFlowDiagnostics: Sendable, Equatable {
    public var smcState: SMCSourceState
    /// Where the sample on screen came from; nil without one.
    public var shown: PowerFlowProvenance?
    /// The registry track's source, for its name: "macOS's battery data".
    public var registrySourceName: String
    /// The line the app adds when the SMC reader is compiled in, written
    /// "label: value"; nil in a build without it.
    public var readerLine: String?

    public init(smcState: SMCSourceState, shown: PowerFlowProvenance?, registrySourceName: String, readerLine: String?) {
        self.smcState = smcState
        self.shown = shown
        self.registrySourceName = registrySourceName
        self.readerLine = readerLine
    }
}
