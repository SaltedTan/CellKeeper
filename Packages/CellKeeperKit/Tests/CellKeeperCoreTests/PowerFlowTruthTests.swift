@testable import CellKeeperCore
import Foundation
import Testing

/// The power flow never shows a reading that contradicts the power source,
/// is older than the policy would accept, or is missing, as if it were
/// current: such a value is not known, and missing data is a gap.
@Suite("Power flow truth")
struct PowerFlowTruthTests {
    let english = Locale(identifier: "en_US")

    private func time(_ seconds: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(seconds)
    }

    /// Each series' segments, as times after the reference date.
    private func segments(_ history: PowerFlowHistory, _ series: PowerFlowHistory.Series, maximumGap: TimeInterval = 180) -> [[TimeInterval]] {
        let mine = history.chartPoints(maximumGap: maximumGap).filter { $0.series == series }
        let numbers = Array(Set(mine.map(\.segment))).sorted()
        return numbers.map { number in mine.filter { $0.segment == number }.map { $0.time.timeIntervalSince(referenceDate) } }
    }

    // MARK: - A charge on battery power

    @Test("Unplugged while the driver still reports the charging current: the battery's power is not known, never a charge, and the chart keeps only what was true")
    func unplugTransition() throws {
        var state = PowerFlowState()
        // Charging on external power, then unplugged: macOS reports battery
        // power at once, but the driver's update time and its cached current
        // are unchanged.
        state.take(snapshot: powerSnapshot(source: .externalPower, update: time(0)), began: 0, now: time(1))
        #expect(state.flow?.batteryLink == .flowing(watts: 15, isTowardsMac: false))
        state.take(snapshot: powerSnapshot(source: .battery, powerIn: 0, update: time(0)), began: 10, now: time(10))
        let flow = try #require(state.flow)
        #expect(flow.powerSource == .battery)
        #expect(flow.batteryWatts == nil)
        #expect(flow.battery == nil)
        #expect(flow.batteryLink == .unknown)
        #expect(flow.adapterLink == .idle)
        #expect(flow.adapterToBatteryWatts == nil)
        #expect(flow.batteryToMacWatts == nil)
        #expect(PowerFlowWording.batterySubtitle(flow, locale: english) == "Power not available")
        #expect(PowerFlowWording.batterySpoken(flow, locale: english) == "81%, power not available")
        #expect(PowerFlowWording.summary(flow, locale: english) == "The Mac uses 30 watts. The battery's power is not available. No external power is connected.")
        // The chart has the charge from before the unplug, as it was.
        #expect(state.history.points.map(\.batteryWatts) == [15])
        // A new update that still reports a charge on battery power is a gap
        // in the battery's line, not a charge.
        state.take(snapshot: powerSnapshot(source: .battery, powerIn: 0, update: time(60)), began: 60, now: time(60))
        #expect(state.history.points.map(\.batteryWatts) == [15, nil])
        #expect(state.history.points.map(\.macUseWatts) == [30, 30])
        #expect(segments(state.history, .battery) == [[0]])
        // The driver catches up: the battery supplies the Mac.
        state.take(snapshot: powerSnapshot(source: .battery, powerIn: 0, current: -1_000, update: time(120)), began: 120, now: time(120))
        #expect(state.flow?.batteryLink == .flowing(watts: 12, isTowardsMac: true))
    }

    @Test("An SMC battery power that says the battery charges on battery power is not known either")
    func smcChargeOnBattery() {
        var state = PowerFlowState()
        state.status(powerSnapshot(source: .battery, powerIn: 0, current: -1_000, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 20, adapterInput: nil, battery: 5)), at: 23)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.battery == nil)
        #expect(state.flow?.batteryLink == .unknown)
        #expect(state.history.points.map(\.batteryWatts) == [-12, nil])
    }

    // MARK: - Stale readings

    @Test("The display judges the driver's update time by the policy's own limits")
    func agreesWithPolicy() {
        let now = time(1_000)
        let maximumAge = ChargingPolicy.maximumSourceAge
        let maximumSkew = ChargingPolicy.maximumClockSkew
        let ages: [TimeInterval] = [0, 59, maximumAge, maximumAge + 0.001, maximumAge + 1, 3_600, -1, -maximumSkew, -maximumSkew - 0.001, -3_600]
        for age in ages {
            let snapshot = powerSnapshot(update: now.addingTimeInterval(-age), at: now)
            let policyAccepts = ChargingPolicy.staleness(of: snapshot, now: now) == nil
            #expect(PowerFlowState.isCurrent(PowerFlowSample(snapshot), at: now) == policyAccepts, "age \(age)")
        }
        #expect(PowerFlowState.isCurrent(PowerFlowSample(powerSnapshot(update: time(0))), at: time(ChargingPolicy.maximumSourceAge)))
        #expect(!PowerFlowState.isCurrent(PowerFlowSample(powerSnapshot(update: time(0))), at: time(ChargingPolicy.maximumSourceAge + 1)))
        // Without the driver's update time, the read time is the
        // controller's to judge.
        #expect(PowerFlowState.isCurrent(PowerFlowSample(powerSnapshot(update: nil)), at: time(10_000)))
    }

    @Test("A frozen driver's reading is not shown as current once older than the policy accepts, and a fresh one shows again")
    func frozenDriver() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        #expect(state.flow?.macUseWatts == 30)
        // The controller reads every minute; the driver's update time stays.
        state.status(powerSnapshot(update: time(0), at: time(120)), at: 120)
        #expect(state.flow?.macUseWatts == 30)
        state.status(powerSnapshot(update: time(0), at: time(181)), at: 181)
        #expect(state.flow == nil)
        #expect(!state.hasSample)
        #expect(state.shownSample == nil)
        #expect(state.provenance == nil)
        // The history has the update once, at its own time.
        #expect(state.history.points.map(\.updates) == [1])
        state.status(powerSnapshot(load: 20_000, update: time(240), at: time(241)), at: 241)
        #expect(state.flow?.macUseWatts == 20)
    }

    @Test("Failed display reads keep the cached reading only while it is current")
    func cachedAfterFailedReads() {
        var state = PowerFlowState()
        state.tick(.registry(PowerFlowSample(powerSnapshot(update: time(0)))), .absent, at: 1)
        state.tick(.empty, .absent, at: 120)
        #expect(state.flow?.macUseWatts == 30)
        state.tick(.empty, .absent, at: 180)
        #expect(state.hasSample)
        state.tick(.empty, .absent, at: 181)
        #expect(state.flow == nil)
        #expect(!state.hasSample)
    }

    @Test("A reading from too far ahead of the clock is not shown as current")
    func fromTheFuture() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(60)), at: 0)
        #expect(state.hasSample)
        state.status(powerSnapshot(update: time(61), at: time(0)), at: 0)
        #expect(!state.hasSample)
    }

    @Test("A fresh SMC window never carries a stale registry battery power; its own B0AP is shown")
    func smcDoesNotLaunderStaleBattery() {
        var state = PowerFlowState()
        state.status(powerSnapshot(load: 30_000, current: -1_000, update: time(0)), at: 1)
        // The driver froze; the SMC goes on.
        state.tick(.window(smcWindow(began: 200, macUse: 21)), at: 203)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.macUseWatts == 21)
        #expect(state.flow?.adapterInputWatts == 30)
        #expect(state.flow?.batteryWatts == nil)
        #expect(state.flow?.batteryLink == .unknown)
        #expect(state.history.points.last?.batteryWatts == nil)
        // With B0AP, the window's own battery power is shown.
        state.tick(.window(smcWindow(began: 203, macUse: 22, battery: -4)), at: 206)
        #expect(state.flow?.battery == .supplying(watts: 4))
        // While the registry reading was current, it was carried.
        var fresh = PowerFlowState()
        fresh.status(powerSnapshot(load: 30_000, current: -1_000, update: time(0)), at: 1)
        fresh.tick(.window(smcWindow(began: 2, macUse: 21)), at: 5)
        #expect(fresh.flow?.battery == .supplying(watts: 12))
        // Once the SMC window is older than 6 s, the stale registry track
        // shows nothing.
        state.tick(.empty, at: 213)
        #expect(state.shownTrack == .registry)
        #expect(state.flow == nil)
    }

    @Test("A reading without the driver's update time is shown whatever the wall clock says")
    func withoutUpdateTime() {
        var state = PowerFlowState()
        state.take(snapshot: powerSnapshot(update: nil), now: time(10_000))
        #expect(state.flow?.macUseWatts == 30)
    }

    // MARK: - Failed reads in the chart

    @Test("A failed controller read between two readings breaks the chart's lines, though they are within the line-break gap, and keeps the history")
    func failureBreaksLines() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.status(nil, at: 60)
        #expect(!state.hasSample)
        state.status(powerSnapshot(load: 20_000, update: time(120)), at: 121)
        #expect(state.flow?.macUseWatts == 20)
        #expect(state.history.points.map(\.updates) == [1, 0, 1])
        #expect(state.history.points.map(\.macUseWatts) == [30, nil, 20])
        for series in PowerFlowHistory.Series.allCases {
            #expect(segments(state.history, series) == [[0], [120]], "\(series)")
        }
        // A failure records one break; another in a row, with nothing left
        // to clear, records none.
        state.status(nil, at: 180)
        state.status(nil, at: 240)
        #expect(state.history.points.map(\.updates) == [1, 0, 1, 0])
    }

    @Test("A failure within one ten-second bucket breaks the lines on both sides of that point")
    func failureInsideBucket() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.status(nil, at: 5)
        state.status(powerSnapshot(load: 20_000, update: time(120)), at: 121)
        #expect(state.history.points.count == 2)
        #expect(state.history.points.first?.updates == 1)
        #expect(state.history.points.first?.brokenSeries == Set(PowerFlowHistory.Series.allCases))
        #expect(segments(state.history, .macUse) == [[0], [120]])
        // A faster source: updates at 1 s and 7 s around a failure at 4 s,
        // all in one bucket, averaged into a point that stands alone.
        var history = PowerFlowHistory()
        history.record(fastSample(1, load: 30))
        history.recordBreak(at: time(4))
        history.record(fastSample(7, load: 40))
        history.record(fastSample(12, load: 50))
        #expect(history.points.map(\.updates) == [2, 1])
        #expect(history.points.first?.macUseWatts == 35)
        #expect(segments(history, .macUse) == [[7], [12]])
    }

    @Test("A break never resets the history or lands before the newest update")
    func breakPlacement() {
        var history = PowerFlowHistory()
        history.record(fastSample(0))
        // A failed read at 400 s, then an update from 60 s that arrives
        // late: within the reorder tolerance of the newest update, so it
        // joins the history, before the break.
        history.recordBreak(at: time(400))
        let added = history.record(fastSample(60, load: 20))
        #expect(added)
        let times = history.points.map { $0.time.timeIntervalSince(referenceDate) }
        let expected: [TimeInterval] = [0, 60, 400]
        #expect(times == expected)
        #expect(segments(history, .macUse) == [[0, 60]])
        // A break stamped before the newest update (the wall clock behind
        // the driver's) follows that update instead.
        var behind = PowerFlowHistory()
        behind.record(fastSample(0))
        behind.record(fastSample(60, load: 20))
        behind.recordBreak(at: time(30))
        behind.record(fastSample(120, load: 25))
        #expect(behind.points.map(\.updates) == [1, 1, 1])
        #expect(segments(behind, .macUse) == [[0], [60], [120]])
    }
}
