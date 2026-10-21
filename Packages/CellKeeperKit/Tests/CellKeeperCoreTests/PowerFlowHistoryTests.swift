@testable import CellKeeperCore
import Foundation
import Testing

extension PowerFlowHistory {
    /// Records a battery reading's registry values.
    @discardableResult
    mutating func record(_ snapshot: BatterySnapshot) -> Bool {
        record(PowerFlowSample(snapshot))
    }
}

extension PowerFlowState {
    /// Takes a battery reading's registry values.
    mutating func take(snapshot: BatterySnapshot) {
        take(PowerFlowSample(snapshot))
    }
}

/// A sample from a source other than macOS's battery data, as a faster one
/// would give: watts with decimals, updated at `seconds`.
func fastSample(_ seconds: TimeInterval, load: Double = 30, powerIn: Double? = 45, battery: Double? = 15) -> PowerFlowSample {
    PowerFlowSample(
        updatedAt: referenceDate.addingTimeInterval(seconds),
        powerSource: .externalPower,
        adapterRatingWatts: 68,
        chargePercent: 81,
        systemPowerInWatts: powerIn,
        systemLoadWatts: load,
        batteryWatts: battery
    )
}

@Suite("Power flow history")
struct PowerFlowHistoryTests {
    /// `seconds` after the reference date.
    private func time(_ seconds: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(seconds)
    }

    private func times(_ history: PowerFlowHistory) -> [TimeInterval] {
        history.points.map { $0.time.timeIntervalSince(referenceDate) }
    }

    @Test("One point per battery-data update: a second read of the same update adds nothing")
    func dedupesByUpdate() {
        var history = PowerFlowHistory()
        let first = history.record(powerSnapshot(update: time(0), at: time(5)))
        #expect(first)
        let again = history.record(powerSnapshot(update: time(0), at: time(10)))
        #expect(!again)
        let next = history.record(powerSnapshot(update: time(60), at: time(61)))
        #expect(next)
        let expected: [TimeInterval] = [0, 60]
        #expect(times(history) == expected)
    }

    @Test("A point holds the adapter's input, the Mac's use and the battery's signed power")
    func pointValues() throws {
        var history = PowerFlowHistory()
        history.record(powerSnapshot(powerIn: 20_000, load: 30_000, current: -1_000, update: time(0)))
        history.record(powerSnapshot(source: .battery, powerIn: 0, load: 11_500, current: -1_000, update: time(60)))
        let first = try #require(history.points.first)
        #expect(first == PowerFlowHistory.Point(time: time(0), adapterInputWatts: 20, macUseWatts: 30, batteryWatts: -12, updates: 1))
        let second = try #require(history.points.last)
        #expect(second.adapterInputWatts == nil)
        #expect(second.macUseWatts == 11.5)
        #expect(second.batteryWatts == -12)
    }

    @Test("A reading without the driver's update time adds nothing; one without a flow is a gap")
    func needsUpdateAndFlow() {
        var history = PowerFlowHistory()
        let withoutUpdate = history.record(powerSnapshot(update: nil))
        #expect(!withoutUpdate)
        #expect(history.points.isEmpty)
        // Without a flow: a point without values, a gap.
        let withoutFlow = history.record(powerSnapshot(load: nil, update: time(0)))
        #expect(withoutFlow)
        #expect(history.points == [PowerFlowHistory.Point(time: time(0), adapterInputWatts: nil, macUseWatts: nil, batteryWatts: nil, updates: 1)])
    }

    @Test("Points more than two hours older than the newest are dropped")
    func keepsTwoHours() {
        var history = PowerFlowHistory()
        for minute in 0...121 {
            history.record(powerSnapshot(update: time(TimeInterval(minute * 60))))
        }
        // 121 minutes: the point at 1 minute is exactly two hours old and stays.
        #expect(history.points.first?.time == time(60))
        #expect(history.points.count == 121)
        #expect(history.newestTime == time(121 * 60))
    }

    @Test("An update that arrives late, up to five minutes older than the newest, takes its place in time")
    func reordersLateUpdates() {
        var history = PowerFlowHistory()
        history.record(powerSnapshot(update: time(0)))
        history.record(powerSnapshot(update: time(120)))
        let late = history.record(powerSnapshot(update: time(60)))
        #expect(late)
        // Already there: not added twice.
        let repeated = history.record(powerSnapshot(update: time(0)))
        #expect(!repeated)
        // At the limit.
        let atLimit = history.record(powerSnapshot(update: time(-180)))
        #expect(atLimit)
        let expected: [TimeInterval] = [-180, 0, 60, 120]
        #expect(times(history) == expected)
    }

    @Test("An update more than five minutes older than the newest means the clock was set back: the history starts again")
    func clockSetBack() {
        var history = PowerFlowHistory()
        history.record(powerSnapshot(update: time(0)))
        history.record(powerSnapshot(update: time(600)))
        let added = history.record(powerSnapshot(update: time(299)))
        #expect(added)
        let expected: [TimeInterval] = [299]
        #expect(times(history) == expected)
    }

    @Test("The clock set back to an update already recorded restarts the history, which then takes later updates")
    func clockSetBackToRecordedUpdate() {
        var history = PowerFlowHistory()
        for minute in 0...10 {
            history.record(powerSnapshot(update: time(TimeInterval(minute * 60))))
        }
        // 0 s was recorded, but it is now ten minutes before the newest.
        let rolledBack = history.record(powerSnapshot(update: time(0)))
        #expect(rolledBack)
        let afterRollback: [TimeInterval] = [0]
        #expect(times(history) == afterRollback)
        let next = history.record(powerSnapshot(update: time(60)))
        #expect(next)
        let repeated = history.record(powerSnapshot(update: time(60)))
        #expect(!repeated)
        let expected: [TimeInterval] = [0, 60]
        #expect(times(history) == expected)
        #expect(history.newestTime == time(60))
    }

    @Test("An update without a flow between two with one breaks every line, within the gap allowed")
    func unavailableBreaksLines() throws {
        var history = PowerFlowHistory()
        history.record(powerSnapshot(update: time(0)))
        history.record(powerSnapshot(load: nil, update: time(60)))
        history.record(powerSnapshot(update: time(120)))
        let chartPoints = history.chartPoints(maximumGap: 180)
        for series in PowerFlowHistory.Series.allCases {
            let mine = chartPoints.filter { $0.series == series }
            #expect(mine.map { $0.time.timeIntervalSince(referenceDate) } == [0, 120], "\(series)")
            #expect(mine.map(\.segment) == [0, 1], "\(series)")
        }
        let gap = try #require(history.points.dropFirst().first)
        #expect(gap.macUseWatts == nil)
    }

    @Test("Deduplication keeps only the last five minutes of update times, at most 1,000")
    func boundedDeduplication() {
        var history = PowerFlowHistory()
        // A source updating every second for three hours.
        for second in 0..<(3 * 60 * 60) {
            history.record(fastSample(TimeInterval(second)))
        }
        #expect(history.recordedUpdateCount <= 301)
        #expect(history.recordedUpdateCount >= 300)
        // Ten updates a second for two minutes: the cap holds.
        var fast = PowerFlowHistory()
        for tenth in 0..<1_200 {
            fast.record(fastSample(TimeInterval(tenth) / 10))
        }
        #expect(fast.recordedUpdateCount == PowerFlowHistory.maximumRecordedUpdates)
        // The newest are kept: a repeat of the last update still counts once.
        let repeated = fast.record(fastSample(119.9))
        #expect(!repeated)
    }

    @Test("Updates within one 10 s bucket are averaged into one point; a second read of one counts once")
    func averagesWithinBucket() throws {
        var history = PowerFlowHistory()
        // A source updating every second, from 0 to 29 s: three buckets.
        for second in 0..<30 {
            history.record(fastSample(TimeInterval(second), load: Double(second)))
        }
        // The same update read again.
        let again = history.record(fastSample(5, load: 1_000))
        #expect(!again)
        let points = history.points
        #expect(points.count == 3)
        let first = try #require(points.first)
        #expect(first.updates == 10)
        #expect(first.time == referenceDate.addingTimeInterval(9))
        let averages: [Double] = [4.5, 14.5, 24.5]
        #expect(points.map(\.macUseWatts) == averages)
        #expect(history.newestTime == referenceDate.addingTimeInterval(29))
    }

    @Test("A value some updates in a bucket lack is averaged over those that have it")
    func averagesKnownValues() throws {
        var history = PowerFlowHistory()
        history.record(fastSample(0, powerIn: 40, battery: nil))
        history.record(fastSample(1, powerIn: nil, battery: -6))
        history.record(fastSample(2, powerIn: 50, battery: -8))
        let point = try #require(history.points.first)
        #expect(history.points.count == 1)
        #expect(point.adapterInputWatts == 45)
        #expect(point.batteryWatts == -7)
        #expect(point.updates == 3)
        var empty = PowerFlowHistory()
        empty.record(fastSample(0, powerIn: nil, battery: nil))
        #expect(empty.points.first?.adapterInputWatts == nil)
        #expect(empty.points.first?.batteryWatts == nil)
    }

    @Test("A source updating every second keeps at most one point per 10 s over two hours")
    func capsFastSources() {
        var history = PowerFlowHistory()
        for second in 0..<(3 * 60 * 60) {
            history.record(fastSample(TimeInterval(second)))
        }
        let points = history.points
        // Two hours, and the bucket the newest update is in.
        #expect(points.count <= 721)
        #expect(points.count >= 720)
        let first = points.first?.time.timeIntervalSince(referenceDate) ?? 0
        let last = points.last?.time.timeIntervalSince(referenceDate) ?? 0
        #expect(last - first <= PowerFlowHistory.maximumAge)
        let buckets = Set(points.map { Int(($0.time.timeIntervalSinceReferenceDate / 10).rounded(.down)) })
        #expect(buckets.count == points.count)
    }

    @Test("The lines break at three times the slowest arrival: the source's cadence or CellKeeper's check")
    func lineBreakGap() {
        #expect(PowerFlowHistory.lineBreakGap(sourceInterval: .seconds(60), checkInterval: .seconds(60)) == 180)
        #expect(PowerFlowHistory.lineBreakGap(sourceInterval: .seconds(1), checkInterval: .seconds(60)) == 180)
        #expect(PowerFlowHistory.lineBreakGap(sourceInterval: .seconds(120), checkInterval: .seconds(60)) == 360)
        #expect(PowerFlowHistory.lineBreakGap(sourceInterval: .seconds(1), checkInterval: .seconds(1)) == 30)
        #expect(PowerFlowHistory.lineBreakGap(sourceInterval: .milliseconds(1_500), checkInterval: .seconds(20)) == 60)
    }

    @Test("The chart shows the hour before the newest point")
    func chartWindow() {
        var history = PowerFlowHistory()
        for minute in [0, 1, 30, 61] {
            history.record(powerSnapshot(update: time(TimeInterval(minute * 60))))
        }
        let shown = Set(history.chartPoints(maximumGap: 180).map(\.time))
        #expect(shown == [time(60), time(30 * 60), time(61 * 60)])
        #expect(PowerFlowHistory().chartPoints(maximumGap: 180).isEmpty)
    }

    @Test("Each series' line breaks where it has no value or updates are more than three minutes apart")
    func chartSegments() {
        var history = PowerFlowHistory()
        let readings: [(TimeInterval, PowerSource, Int?)] = [
            (0, .externalPower, 1_250), (60, .externalPower, 1_250),
            (120, .battery, -1_000), (180, .battery, nil),
            (240, .externalPower, 1_250), (420, .externalPower, 1_250), (601, .externalPower, 1_250),
        ]
        for (seconds, source, current) in readings {
            history.record(powerSnapshot(source: source, current: current, update: time(seconds)))
        }
        let chartPoints = history.chartPoints(maximumGap: 180)
        func segments(_ series: PowerFlowHistory.Series) -> [[TimeInterval]] {
            let mine = chartPoints.filter { $0.series == series }
            let numbers = Array(Set(mine.map(\.segment))).sorted()
            return numbers.map { number in mine.filter { $0.segment == number }.map { $0.time.timeIntervalSince(referenceDate) } }
        }
        // 240 to 420 is exactly three minutes: one line; 420 to 601 is more.
        #expect(segments(.macUse) == [[0, 60, 120, 180, 240, 420], [601]])
        #expect(segments(.adapterInput) == [[0, 60], [240, 420], [601]])
        #expect(segments(.battery) == [[0, 60, 120], [240, 420], [601]])
        let battery = chartPoints.filter { $0.series == .battery }.map(\.watts)
        #expect(battery == [15, 15, -12, 15, 15, 15])
    }
}

@Suite("Power flow state")
struct PowerFlowStateTests {
    private func time(_ seconds: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(seconds)
    }

    @Test("The flow shows the latest reading and the history records it")
    func takesReadings() {
        var readings = PowerFlowState()
        #expect(!readings.hasSample)
        #expect(readings.flow == nil)
        readings.take(snapshot: powerSnapshot(update: time(0)))
        readings.take(snapshot: powerSnapshot(load: 20_000, update: time(60)))
        #expect(readings.hasSample)
        #expect(readings.flow?.macUseWatts == 20)
        #expect(readings.history.points.count == 2)
    }

    @Test("A status without a reading clears the flow and keeps the history")
    func failedRead() {
        var readings = PowerFlowState()
        readings.take(snapshot: powerSnapshot(update: time(0)))
        readings.take(nil)
        #expect(!readings.hasSample)
        #expect(readings.flow == nil)
        #expect(readings.history.points.count == 1)
        // The same update read again shows again.
        readings.take(snapshot: powerSnapshot(update: time(0), at: time(5)))
        #expect(readings.hasSample)
        #expect(readings.flow != nil)
    }

    @Test("An older update that arrives late joins the history but does not replace the flow")
    func lateUpdate() {
        var readings = PowerFlowState()
        readings.take(snapshot: powerSnapshot(load: 30_000, update: time(60)))
        readings.take(snapshot: powerSnapshot(load: 20_000, update: time(0)))
        #expect(readings.flow?.macUseWatts == 30)
        #expect(readings.history.points.count == 2)
        // A newer read of the update shown replaces it.
        readings.take(snapshot: powerSnapshot(load: 30_000, adapter: 96, update: time(60), at: time(65)))
        #expect(readings.flow?.adapterRatingWatts == 96)
    }

    @Test("After the clock is set back, the flow shows the new readings")
    func clockSetBack() {
        var readings = PowerFlowState()
        readings.take(snapshot: powerSnapshot(load: 30_000, update: time(600)))
        readings.take(snapshot: powerSnapshot(load: 20_000, update: time(299)))
        #expect(readings.flow?.macUseWatts == 20)
        #expect(readings.history.points.count == 1)
    }

    @Test("A reading without the update time is shown but not recorded; one without a flow is recorded as a gap")
    func unrecordedReadings() {
        var readings = PowerFlowState()
        readings.take(snapshot: powerSnapshot(load: 20_000, update: nil))
        #expect(readings.flow?.macUseWatts == 20)
        #expect(readings.history.points.isEmpty)
        readings.take(snapshot: powerSnapshot(load: nil, update: time(0), at: time(1)))
        #expect(readings.hasSample)
        #expect(readings.flow == nil)
        #expect(readings.history.points.map(\.macUseWatts) == [nil])
    }
}
