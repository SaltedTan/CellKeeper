import Foundation

/// The power flow of the last two hours, for the menu's chart (D114): each
/// update a source made, at most one point per ``bucketWidth``, the updates
/// within one averaged. macOS's battery data, updated once a minute, gives
/// a point per update; a source updating every second would give one per
/// 10 s. In memory only: never written to disk, so it is gone when
/// CellKeeper quits. Display only, like ``PowerFlow``.
public struct PowerFlowHistory: Sendable, Equatable {
    /// One ``bucketWidth`` of updates, averaged.
    public struct Point: Sendable, Equatable {
        /// The newest update averaged into it.
        public let time: Date
        /// The average of the updates that report it.
        public let adapterInputWatts: Double?
        public let macUseWatts: Double
        /// Signed: positive while charging, negative while supplying.
        public let batteryWatts: Double?
        /// How many updates it averages.
        public let updates: Int

        public init(time: Date, adapterInputWatts: Double?, macUseWatts: Double, batteryWatts: Double?, updates: Int = 1) {
            self.time = time
            self.adapterInputWatts = adapterInputWatts
            self.macUseWatts = macUseWatts
            self.batteryWatts = batteryWatts
            self.updates = updates
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
    /// The chart's time span, ending at the newest point.
    public static let chartWindow: TimeInterval = 60 * 60

    /// Oldest first, one per bucket.
    private var buckets: [Bucket] = []
    /// The updates already averaged in, so that a second read of one counts
    /// once.
    private var recordedUpdates: Set<Date> = []

    public init() {}

    /// Oldest first, each a different ``bucketWidth``.
    public var points: [Point] {
        buckets.map(\.point)
    }

    /// The time the chart ends at: the newest point's.
    public var newestTime: Date? {
        buckets.last?.time
    }

    /// Averages `sample` into its bucket if it carries an update that is not
    /// yet here, and drops points more than ``maximumAge`` older than the
    /// newest. A sample without the source's update time, or without a power
    /// flow, adds nothing. Returns whether the update was added.
    @discardableResult
    public mutating func record(_ sample: PowerFlowSample) -> Bool {
        guard let time = sample.updatedAt, let flow = PowerFlow(sample) else { return false }
        guard !recordedUpdates.contains(time) else { return false }
        if let newest = newestTime, newest.timeIntervalSince(time) > Self.reorderTolerance {
            buckets = []
            recordedUpdates = []
        }
        let index = Self.bucketIndex(of: time)
        // Searched from the newest end: updates mostly arrive in order.
        if let existing = buckets.lastIndex(where: { $0.index <= index }), buckets[existing].index == index {
            buckets[existing].add(flow, at: time)
        } else {
            let position = buckets.lastIndex { $0.index < index }.map { $0 + 1 } ?? buckets.startIndex
            buckets.insert(Bucket(index: index, flow: flow, time: time), at: position)
        }
        recordedUpdates.insert(time)
        if let newest = newestTime {
            let count = buckets.count
            buckets.removeAll { newest.timeIntervalSince($0.time) > Self.maximumAge }
            // Updates of dropped buckets can no longer be added: forget them.
            if buckets.count < count, let oldest = buckets.first {
                let start = Date(timeIntervalSinceReferenceDate: Double(oldest.index) * Self.bucketWidth)
                recordedUpdates = recordedUpdates.filter { $0 >= start }
            }
        }
        return true
    }

    /// Where the chart's lines break: three times the slowest way points
    /// arrive, the source's cadence or CellKeeper's own check (the history
    /// fills from the statuses unless the section is shown), and never less
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
    /// was read).
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
                if let previous, point.time.timeIntervalSince(previous) > maximumGap {
                    segment += 1
                }
                chartPoints.append(ChartPoint(series: series, segment: segment, time: point.time, watts: watts))
                previous = point.time
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
        var time: Date
        var adapterInput = Mean()
        var macUse = Mean()
        var battery = Mean()
        var updates = 0

        init(index: Int, flow: PowerFlow, time: Date) {
            self.index = index
            self.time = time
            add(flow, at: time)
        }

        mutating func add(_ flow: PowerFlow, at time: Date) {
            self.time = max(self.time, time)
            adapterInput.add(flow.adapterInputWatts)
            macUse.add(flow.macUseWatts)
            battery.add(flow.batteryWatts)
            updates += 1
        }

        var point: Point {
            Point(time: time, adapterInputWatts: adapterInput.value, macUseWatts: macUse.value ?? 0, batteryWatts: battery.value, updates: updates)
        }
    }

    /// An average of the values known, ignoring those that are not.
    private struct Mean: Sendable, Equatable {
        var sum = 0.0
        var count = 0

        mutating func add(_ value: Double?) {
            guard let value else { return }
            sum += value
            count += 1
        }

        var value: Double? {
            count > 0 ? sum / Double(count) : nil
        }
    }
}

/// What the menu's power flow shows: the latest sample's flow and the
/// history. The controller's statuses and the display-only reads made while
/// the menu shows the expanded section (``PowerFlowRefresh``) both feed it,
/// in whatever order they finish. In memory only.
public struct PowerFlowState: Sendable, Equatable {
    /// The latest sample's flow; nil before the first sample, after the
    /// controller's read failed, or when it has no power use for the Mac.
    public private(set) var flow: PowerFlow?
    /// Whether a sample is in hand: false before the first, and after the
    /// controller's read failed until the next sample.
    public private(set) var hasSample = false
    public private(set) var history = PowerFlowHistory()
    /// The update the flow shows, so that an older one that arrives late
    /// does not replace it.
    private var shownUpdate: Date?

    public init() {}

    /// Takes a sample: `nil` for a status without a reading (its read
    /// failed). The flow shows the newest update; one up to
    /// ``PowerFlowHistory/reorderTolerance`` older than it only joins the
    /// history.
    public mutating func take(_ sample: PowerFlowSample?) {
        guard let sample else {
            flow = nil
            hasSample = false
            return
        }
        history.record(sample)
        if let update = sample.updatedAt, let shownUpdate, update < shownUpdate,
           shownUpdate.timeIntervalSince(update) <= PowerFlowHistory.reorderTolerance {
            return
        }
        shownUpdate = sample.updatedAt
        flow = PowerFlow(sample)
        hasSample = true
    }
}
