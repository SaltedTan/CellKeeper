import CellKeeperCore
import Foundation
import Testing

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
        #expect(first == PowerFlowHistory.Point(time: time(0), adapterInputWatts: 20, macUseWatts: 30, batteryWatts: -12))
        let second = try #require(history.points.last)
        #expect(second.adapterInputWatts == nil)
        #expect(second.macUseWatts == 11.5)
        #expect(second.batteryWatts == -12)
    }

    @Test("A reading without the driver's update time or without a flow adds nothing")
    func needsUpdateAndFlow() {
        var history = PowerFlowHistory()
        let withoutUpdate = history.record(powerSnapshot(update: nil))
        #expect(!withoutUpdate)
        let withoutFlow = history.record(powerSnapshot(load: nil))
        #expect(!withoutFlow)
        #expect(history.points.isEmpty)
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

    @Test("The chart shows the hour before the newest point")
    func chartWindow() {
        var history = PowerFlowHistory()
        for minute in [0, 1, 30, 61] {
            history.record(powerSnapshot(update: time(TimeInterval(minute * 60))))
        }
        let shown = Set(history.chartSamples().map(\.time))
        #expect(shown == [time(60), time(30 * 60), time(61 * 60)])
        #expect(PowerFlowHistory().chartSamples().isEmpty)
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
        let samples = history.chartSamples()
        func segments(_ series: PowerFlowHistory.Series) -> [[TimeInterval]] {
            let mine = samples.filter { $0.series == series }
            let numbers = Array(Set(mine.map(\.segment))).sorted()
            return numbers.map { number in mine.filter { $0.segment == number }.map { $0.time.timeIntervalSince(referenceDate) } }
        }
        // 240 to 420 is exactly three minutes: one line; 420 to 601 is more.
        #expect(segments(.macUse) == [[0, 60, 120, 180, 240, 420], [601]])
        #expect(segments(.adapterInput) == [[0, 60], [240, 420], [601]])
        #expect(segments(.battery) == [[0, 60, 120], [240, 420], [601]])
        let battery = samples.filter { $0.series == .battery }.map(\.watts)
        #expect(battery == [15, 15, -12, 15, 15, 15])
    }
}

@Suite("Power flow readings")
struct PowerFlowReadingsTests {
    private func time(_ seconds: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(seconds)
    }

    @Test("The flow shows the latest reading and the history records it")
    func takesReadings() {
        var readings = PowerFlowReadings()
        #expect(!readings.hasReading)
        #expect(readings.flow == nil)
        readings.take(powerSnapshot(update: time(0)))
        readings.take(powerSnapshot(load: 20_000, update: time(60)))
        #expect(readings.hasReading)
        #expect(readings.flow?.macUseWatts == 20)
        #expect(readings.history.points.count == 2)
    }

    @Test("A status without a reading clears the flow and keeps the history")
    func failedRead() {
        var readings = PowerFlowReadings()
        readings.take(powerSnapshot(update: time(0)))
        readings.take(nil)
        #expect(!readings.hasReading)
        #expect(readings.flow == nil)
        #expect(readings.history.points.count == 1)
        // The same update read again shows again.
        readings.take(powerSnapshot(update: time(0), at: time(5)))
        #expect(readings.hasReading)
        #expect(readings.flow != nil)
    }

    @Test("An older update that arrives late joins the history but does not replace the flow")
    func lateUpdate() {
        var readings = PowerFlowReadings()
        readings.take(powerSnapshot(load: 30_000, update: time(60)))
        readings.take(powerSnapshot(load: 20_000, update: time(0)))
        #expect(readings.flow?.macUseWatts == 30)
        #expect(readings.history.points.count == 2)
        // A newer read of the update shown replaces it.
        readings.take(powerSnapshot(load: 30_000, adapter: 96, update: time(60), at: time(65)))
        #expect(readings.flow?.adapterRatingWatts == 96)
    }

    @Test("After the clock is set back, the flow shows the new readings")
    func clockSetBack() {
        var readings = PowerFlowReadings()
        readings.take(powerSnapshot(load: 30_000, update: time(600)))
        readings.take(powerSnapshot(load: 20_000, update: time(299)))
        #expect(readings.flow?.macUseWatts == 20)
        #expect(readings.history.points.count == 1)
    }

    @Test("A reading without the update time, or without a flow, is shown but not recorded")
    func unrecordedReadings() {
        var readings = PowerFlowReadings()
        readings.take(powerSnapshot(load: 20_000, update: nil))
        #expect(readings.flow?.macUseWatts == 20)
        #expect(readings.history.points.isEmpty)
        readings.take(powerSnapshot(load: nil, update: time(0)))
        #expect(readings.hasReading)
        #expect(readings.flow == nil)
        #expect(readings.history.points.isEmpty)
    }
}
