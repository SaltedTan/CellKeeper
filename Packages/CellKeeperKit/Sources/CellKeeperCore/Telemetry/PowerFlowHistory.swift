import Foundation

/// The power flow of the last two hours, one point per battery-data update
/// macOS made, for the menu's chart (D114). In memory only: never written to
/// disk, so it is gone when CellKeeper quits. Display only, like
/// ``PowerFlow``.
public struct PowerFlowHistory: Sendable, Equatable {
    /// One battery-data update.
    public struct Point: Sendable, Equatable {
        /// When macOS updated the battery data (the snapshot's
        /// `sourceTimestamp`).
        public let time: Date
        public let adapterInputWatts: Double?
        public let macUseWatts: Double
        /// Signed: positive while charging, negative while supplying.
        public let batteryWatts: Double?

        public init(time: Date, adapterInputWatts: Double?, macUseWatts: Double, batteryWatts: Double?) {
            self.time = time
            self.adapterInputWatts = adapterInputWatts
            self.macUseWatts = macUseWatts
            self.batteryWatts = batteryWatts
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
    /// updates are far apart.
    public struct Sample: Sendable, Hashable {
        public let series: Series
        public let segment: Int
        public let time: Date
        public let watts: Double
    }

    /// The oldest point kept, before the newest.
    public static let maximumAge: TimeInterval = 2 * 60 * 60
    /// How much older than the newest point an update may be and still be
    /// added in its place: two reads in flight can finish in either order,
    /// at most one update apart. An update older than that means the clock
    /// was set back, and the history starts again from it.
    public static let reorderTolerance: TimeInterval = 5 * 60
    /// The chart's time span, ending at the newest point.
    public static let chartWindow: TimeInterval = 60 * 60
    /// Updates further apart than this break the chart's lines: the Mac
    /// slept, or nothing was read. macOS updates the data every 60 s.
    public static let maximumGap: TimeInterval = 3 * 60

    /// Oldest first, each at its own time.
    public private(set) var points: [Point] = []

    public init() {}

    /// Adds a point for `snapshot` if it carries a battery-data update that
    /// is not yet here, and drops points more than ``maximumAge`` older than
    /// the newest. A snapshot without the driver's update time, or without a
    /// power flow, adds nothing. Returns whether a point was added.
    @discardableResult
    public mutating func record(_ snapshot: BatterySnapshot) -> Bool {
        guard let time = snapshot.sourceTimestamp, let flow = PowerFlow(snapshot) else { return false }
        guard !points.contains(where: { $0.time == time }) else { return false }
        let point = Point(time: time, adapterInputWatts: flow.adapterInputWatts, macUseWatts: flow.macUseWatts, batteryWatts: flow.batteryWatts)
        if let newest = points.last?.time, time < newest {
            if newest.timeIntervalSince(time) > Self.reorderTolerance {
                points = [point]
            } else {
                let index = points.firstIndex { $0.time > time } ?? points.endIndex
                points.insert(point, at: index)
            }
        } else {
            points.append(point)
        }
        if let newest = points.last?.time {
            points.removeAll { newest.timeIntervalSince($0.time) > Self.maximumAge }
        }
        return true
    }

    /// The time the chart ends at: the newest point's.
    public var newestTime: Date? {
        points.last?.time
    }

    /// The points of the ``chartWindow`` ending at the newest point, as the
    /// chart draws them: for each series, its values in time order, numbered
    /// by segment. A segment ends where the series has no value or two
    /// updates are more than ``maximumGap`` apart.
    public func chartSamples(window: TimeInterval = chartWindow, maximumGap: TimeInterval = maximumGap) -> [Sample] {
        guard let newest = newestTime else { return [] }
        let shown = points.filter { newest.timeIntervalSince($0.time) <= window }
        var samples: [Sample] = []
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
                samples.append(Sample(series: series, segment: segment, time: point.time, watts: watts))
                previous = point.time
            }
        }
        return samples
    }
}

/// What the menu's power flow shows: the latest reading's flow and the
/// history. The controller's statuses and the display-only reads made while
/// the menu shows the flow (``PowerFlowRefresh``) both feed it, in whatever
/// order they finish. In memory only.
public struct PowerFlowReadings: Sendable, Equatable {
    /// The latest reading's flow; nil before the first reading, after the
    /// controller's read failed, or when macOS reports no power use.
    public private(set) var flow: PowerFlow?
    /// Whether a reading is in hand: false before the first, and after the
    /// controller's read failed until the next reading.
    public private(set) var hasReading = false
    public private(set) var history = PowerFlowHistory()
    /// The battery-data update the flow shows, so that an older one that
    /// arrives late does not replace it.
    private var shownUpdate: Date?

    public init() {}

    /// Takes a reading: `nil` for a status without one (its read failed).
    /// The flow shows the newest battery-data update; one up to
    /// ``PowerFlowHistory/reorderTolerance`` older than it only joins the
    /// history.
    public mutating func take(_ snapshot: BatterySnapshot?) {
        guard let snapshot else {
            flow = nil
            hasReading = false
            return
        }
        history.record(snapshot)
        if let update = snapshot.sourceTimestamp, let shownUpdate, update < shownUpdate,
           shownUpdate.timeIntervalSince(update) <= PowerFlowHistory.reorderTolerance {
            return
        }
        shownUpdate = snapshot.sourceTimestamp
        flow = PowerFlow(snapshot)
        hasReading = true
    }
}
