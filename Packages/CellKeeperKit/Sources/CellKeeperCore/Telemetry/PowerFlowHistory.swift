import Foundation

/// The power flow of the last two hours, for the menu's chart (D114): each
/// update a source made, at most one point per ``bucketWidth``, the updates
/// within one averaged. macOS's battery data, updated once a minute, gives
/// a point per update; a source updating every second would give one per
/// 10 s. An update without a power flow (macOS reported no power use) is a
/// point without values, which breaks the chart's lines, and so is a break
/// (``recordBreak(at:)``): readings that disappeared. Everything kept is
/// bounded: at most 721 points, and the update times of the last
/// ``reorderTolerance`` for deduplication, at most
/// ``maximumRecordedUpdates``. In memory only: never written to disk, so it
/// is gone when CellKeeper quits. Display only, like ``PowerFlow``.
public struct PowerFlowHistory: Sendable, Equatable {
    /// One ``bucketWidth`` of updates, averaged.
    public struct Point: Sendable, Equatable {
        /// The newest update averaged into it.
        public let time: Date
        /// The average of the updates that report it; nil if none does.
        public let adapterInputWatts: Double?
        /// Nil if no update in it had a power flow, or it holds only a
        /// break: a gap in every line.
        public let macUseWatts: Double?
        /// Signed: positive while charging, negative while supplying.
        public let batteryWatts: Double?
        /// How many updates it averages, with and without a power flow; 0
        /// for a point that holds only a break.
        public let updates: Int
        /// The series that have a value here although an update averaged in
        /// had none, or a break fell within its ``bucketWidth``: the average
        /// hides a gap, so the chart's line breaks on both sides of this
        /// point.
        public let brokenSeries: Set<Series>

        public init(
            time: Date,
            adapterInputWatts: Double?,
            macUseWatts: Double?,
            batteryWatts: Double?,
            updates: Int = 1,
            brokenSeries: Set<Series> = []
        ) {
            self.time = time
            self.adapterInputWatts = adapterInputWatts
            self.macUseWatts = macUseWatts
            self.batteryWatts = batteryWatts
            self.updates = updates
            self.brokenSeries = brokenSeries
        }

        /// The point's value for `series`.
        public func watts(_ series: Series) -> Double? {
            switch series {
            case .macUse: macUseWatts
            case .adapterInput: adapterInputWatts
            case .battery: batteryWatts
            }
        }
    }

    /// A line of the chart.
    public enum Series: String, Sendable, CaseIterable {
        case macUse
        case adapterInput
        case battery
    }

    /// A point of a series in the chart. `segment` numbers the pieces of
    /// its series' line, which breaks where the series has no value or the
    /// points are far apart.
    public struct ChartPoint: Sendable, Hashable {
        public let series: Series
        public let segment: Int
        public let time: Date
        public let watts: Double
    }

    /// The oldest point kept, before the newest.
    public static let maximumAge: TimeInterval = 2 * 60 * 60
    /// The span of time one point averages: at most 720 points in two
    /// hours, whatever the source's cadence.
    public static let bucketWidth: TimeInterval = 10
    /// How much older than the newest point an update may be and still be
    /// added in its place: reads in flight can finish in either order, and
    /// two sources (the statuses' and the menu's) can be a minute apart. An
    /// update older than that means the clock was set back, and the history
    /// starts again from it.
    public static let reorderTolerance: TimeInterval = 5 * 60
    /// The most update times kept for deduplication, the newest: a second
    /// read of an older update can then count again in its average, but the
    /// memory stays bounded whatever the source's cadence.
    public static let maximumRecordedUpdates = 1_000
    /// The chart's time span, ending at the newest point.
    public static let chartWindow: TimeInterval = 60 * 60

    /// Oldest first, one per bucket.
    private var buckets: [Bucket] = []
    /// The wall clock's time when the last break was recorded, as it was,
    /// whatever its placement: a later delivery earlier than this means the
    /// clock was set back past that failed read. Nil once no break is kept
    /// (dropped by its age, or the history started again).
    private var lastBreakAt: Date?
    /// The updates already averaged in, so that a second read of one counts
    /// once: only those of the last ``reorderTolerance`` (an older update
    /// restarts the history, so it needs none), at most
    /// ``maximumRecordedUpdates``.
    private var recordedUpdates: Set<Date> = []

    /// How many update times are kept for deduplication.
    var recordedUpdateCount: Int {
        recordedUpdates.count
    }

    public init() {}

    /// Oldest first, each a different ``bucketWidth``.
    public var points: [Point] {
        buckets.map(\.point)
    }

    /// The time the chart ends at: the newest point's, a break's included.
    public var newestTime: Date? {
        buckets.last?.time
    }

    /// The newest update's time. The clock rule judges updates against it,
    /// not against a break, whose time is the wall clock's at a failed
    /// read: an update the driver had not yet refreshed (after a wake) is
    /// not taken for a clock set back.
    private var newestUpdateTime: Date? {
        buckets.last { $0.updates > 0 }?.time
    }

    /// Averages `sample` into its bucket if it carries an update that is not
    /// yet here, and drops points more than ``maximumAge`` older than the
    /// newest. An update more than ``reorderTolerance`` older than the newest
    /// means the clock was set back: the history, and what deduplication
    /// remembers, start again from it, before it is checked for a repeat. A
    /// sample without a power flow is kept as a gap; one without the
    /// source's update time adds nothing. Returns whether the update was
    /// added.
    @discardableResult
    public mutating func record(_ sample: PowerFlowSample) -> Bool {
        guard let time = sample.updatedAt else { return false }
        if let newest = newestUpdateTime, newest.timeIntervalSince(time) > Self.reorderTolerance {
            buckets = []
            recordedUpdates = []
        }
        guard !recordedUpdates.contains(time) else { return false }
        let flow = PowerFlow(sample)
        let index = Self.bucketIndex(of: time)
        // Searched from the newest end: updates mostly arrive in order.
        if let existing = buckets.lastIndex(where: { $0.index <= index }), buckets[existing].index == index {
            buckets[existing].add(flow, at: time)
        } else {
            let position = buckets.lastIndex { $0.index < index }.map { $0 + 1 } ?? buckets.startIndex
            buckets.insert(Bucket(index: index, flow: flow, time: time), at: position)
        }
        recordedUpdates.insert(time)
        prune()
        return true
    }

    /// Records that usable readings disappeared at `time`, the wall clock's
    /// when a read failed, so that the chart never draws a line across the
    /// missing data: the lines break between the updates before it and
    /// those after. `time` itself is kept (``lastBreakAt``), apart from
    /// where the break is placed.
    /// A break is a point without values, or, within a point's
    /// ``bucketWidth``, makes that point stand alone. It is never earlier
    /// than the newest update, which it follows; it is no update, so it is
    /// not deduplicated and averages nothing. It is a point like any other
    /// for ``maximumAge``: the history spans two hours, whatever its newest
    /// point is.
    public mutating func recordBreak(at time: Date) {
        lastBreakAt = time
        let time = max(time, newestUpdateTime ?? time)
        let index = Self.bucketIndex(of: time)
        if let existing = buckets.lastIndex(where: { $0.index <= index }), buckets[existing].index == index {
            buckets[existing].hasBreak = true
        } else {
            let position = buckets.lastIndex { $0.index < index }.map { $0 + 1 } ?? buckets.startIndex
            buckets.insert(Bucket(index: index, breakAt: time), at: position)
        }
        prune()
    }

    /// Starts the history again if `now`, the wall clock's as something is
    /// delivered, is earlier than the last break was recorded
    /// (``lastBreakAt``): the clock was set back past that failed read, so
    /// the times on either side of it no longer say which updates came
    /// before it. The history starts from a break at `now`, so an update
    /// read afterwards (a cached one from before the failure, reread) is
    /// never joined to a later one across the failure. Only the wall clock
    /// is that evidence: a driver update stamped before a failure and read
    /// after it, or an old one after a wake, restarts nothing; updates are
    /// reordered within ``reorderTolerance`` as before.
    public mutating func restartIfClockSetBack(now: Date) {
        guard let lastBreakAt, now < lastBreakAt else { return }
        buckets = []
        recordedUpdates = []
        recordBreak(at: now)
    }

    /// Drops points more than ``maximumAge`` older than the newest, of
    /// either kind, so at most 721 points are kept, one per ``bucketWidth``
    /// over two hours; and update times outside deduplication's span or
    /// count. A newest break drops the updates more than two hours before
    /// it, as a newer update would; they are outside the chart's hour. Once
    /// the wall clock is found set back past a break, the history starts
    /// again before anything else is recorded
    /// (``restartIfClockSetBack(now:)``), so a break never outlives a
    /// rollback, nor drops an update recorded after one.
    private mutating func prune() {
        if let newest = newestTime {
            buckets.removeAll { newest.timeIntervalSince($0.time) > Self.maximumAge }
            recordedUpdates = recordedUpdates.filter { newest.timeIntervalSince($0) <= Self.reorderTolerance }
        }
        // Without a break kept (dropped by its age, or the clock rule started
        // the history again), the last one's instant says nothing more.
        if !buckets.contains(where: \.hasBreak) {
            lastBreakAt = nil
        }
        if recordedUpdates.count > Self.maximumRecordedUpdates {
            recordedUpdates = Set(recordedUpdates.sorted().suffix(Self.maximumRecordedUpdates))
        }
    }

    /// Where the chart's lines break: three times the slowest way points
    /// arrive, the source's cadence or CellKeeper's own check (the history
    /// fills from the statuses unless the flow is shown), and never less
    /// than three buckets.
    public static func lineBreakGap(sourceInterval: Duration, checkInterval: Duration) -> TimeInterval {
        let slowest = max(sourceInterval, checkInterval)
        let parts = slowest.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return 3 * max(seconds, bucketWidth)
    }

    /// The points of the ``chartWindow`` ending at the newest point, as the
    /// chart draws them: for each series, its values in time order, numbered
    /// by segment. A segment ends where the series has no value or two
    /// points are more than `maximumGap` apart (the Mac slept, or nothing
    /// was read); a point whose average hides a gap stands alone.
    public func chartPoints(window: TimeInterval = chartWindow, maximumGap: TimeInterval) -> [ChartPoint] {
        guard let newest = newestTime else { return [] }
        let shown = points.filter { newest.timeIntervalSince($0.time) <= window }
        var chartPoints: [ChartPoint] = []
        for series in Series.allCases {
            var segment = 0
            var previous: Date?
            for point in shown {
                guard let watts = point.watts(series) else {
                    if previous != nil { segment += 1 }
                    previous = nil
                    continue
                }
                if let previous, point.time.timeIntervalSince(previous) > maximumGap || point.brokenSeries.contains(series) {
                    segment += 1
                }
                chartPoints.append(ChartPoint(series: series, segment: segment, time: point.time, watts: watts))
                previous = point.time
                if point.brokenSeries.contains(series) {
                    segment += 1
                    previous = nil
                }
            }
        }
        return chartPoints
    }

    /// The bucket `time` falls in, counted from the reference date.
    static func bucketIndex(of time: Date) -> Int {
        let index = (time.timeIntervalSinceReferenceDate / bucketWidth).rounded(.down)
        // Out-of-range times cannot trap; they share the outermost bucket.
        guard index.isFinite else { return 0 }
        return Int(max(min(index, Double(Int.max / 2)), Double(Int.min / 2)))
    }

    /// The running averages of one bucket.
    private struct Bucket: Sendable, Equatable {
        let index: Int
        /// The newest update's time; a break's while it holds no update.
        var time: Date
        var adapterInput = Mean()
        var macUse = Mean()
        var battery = Mean()
        var updates = 0
        /// Whether a break (``PowerFlowHistory/recordBreak(at:)``) fell
        /// within it.
        var hasBreak = false

        /// `flow` is nil for an update without a power flow, which adds no
        /// value.
        init(index: Int, flow: PowerFlow?, time: Date) {
            self.index = index
            self.time = time
            add(flow, at: time)
        }

        /// A bucket that holds only a break, at `time`.
        init(index: Int, breakAt time: Date) {
            self.index = index
            self.time = time
            hasBreak = true
        }

        mutating func add(_ flow: PowerFlow?, at time: Date) {
            self.time = updates == 0 ? time : max(self.time, time)
            adapterInput.add(flow?.adapterInputWatts)
            macUse.add(flow?.macUseWatts)
            battery.add(flow?.batteryWatts)
            updates += 1
        }

        var point: Point {
            var broken: Set<Series> = []
            if adapterInput.isBroken(by: hasBreak) { broken.insert(.adapterInput) }
            if macUse.isBroken(by: hasBreak) { broken.insert(.macUse) }
            if battery.isBroken(by: hasBreak) { broken.insert(.battery) }
            return Point(
                time: time,
                adapterInputWatts: adapterInput.value,
                macUseWatts: macUse.value,
                batteryWatts: battery.value,
                updates: updates,
                brokenSeries: broken
            )
        }
    }

    /// An average of the values known, ignoring those that are not, and
    /// whether any was not.
    private struct Mean: Sendable, Equatable {
        var sum = 0.0
        var count = 0
        var missing = 0

        mutating func add(_ value: Double?) {
            guard let value else {
                missing += 1
                return
            }
            sum += value
            count += 1
        }

        var value: Double? {
            count > 0 ? sum / Double(count) : nil
        }

        /// A value averaged together with an update that had none, or with
        /// a break in its bucket.
        func isBroken(by hasBreak: Bool) -> Bool {
            count > 0 && (missing > 0 || hasBreak)
        }
    }
}
