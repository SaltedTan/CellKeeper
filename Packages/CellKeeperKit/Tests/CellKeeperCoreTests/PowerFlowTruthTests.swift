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

    @Test("Every check the policy makes, on both clocks: the wall-clock read age, the continuous read age and the driver's update time, each varied alone; the stricter wins")
    func agreesWithPolicy() {
        let now = time(1_000)
        let instant = readInstant(1_000)
        let telemetryAge = ChargingPolicy.maximumTelemetryAge
        let maximumSourceAge = ChargingPolicy.maximumSourceAge
        let skew = ChargingPolicy.maximumClockSkew
        let readAges: [TimeInterval] = [0, 30, telemetryAge, telemetryAge + 0.001, 120, 3_600, -1, -skew, -skew - 0.001]
        let sourceAges: [TimeInterval] = [0, 59, maximumSourceAge, maximumSourceAge + 0.001, 3_600, -1, -skew, -skew - 0.001]
        var rejectedByWallReadAge = 0
        var rejectedByContinuousReadAge = 0
        for wallReadAge in readAges {
            for continuousReadAge in readAges {
                for sourceAge in sourceAges {
                    let snapshot = powerSnapshot(update: now.addingTimeInterval(-sourceAge), at: now.addingTimeInterval(-wallReadAge))
                    let policyAccepts = ChargingPolicy.staleness(of: snapshot, now: now) == nil
                    let continuousAccepts = continuousReadAge <= telemetryAge && continuousReadAge >= -skew
                    var sample = PowerFlowSample(snapshot)
                    sample.readBegan = instant.advanced(by: .seconds(-continuousReadAge))
                    let label = "wall read \(wallReadAge) s, continuous read \(continuousReadAge) s, source \(sourceAge) s"
                    #expect(PowerFlowState.isCurrent(sample, now: now, at: instant) == (policyAccepts && continuousAccepts), "\(label)")
                    let sourceAccepted = ChargingPolicy.staleness(of: powerSnapshot(update: snapshot.sourceTimestamp, at: now), now: now) == nil
                    if !policyAccepts, sourceAccepted, continuousAccepts { rejectedByWallReadAge += 1 }
                    if policyAccepts, !continuousAccepts { rejectedByContinuousReadAge += 1 }
                }
            }
        }
        // Each read-age check rejected some readings that every other check
        // accepted.
        #expect(rejectedByWallReadAge > 0)
        #expect(rejectedByContinuousReadAge > 0)
        // A check whose time the sample lacks is not made.
        var bare = PowerFlowSample(powerSnapshot(update: nil))
        bare.readAt = nil
        #expect(PowerFlowState.isCurrent(bare, now: time(10_000), at: readInstant(10_000)))
        bare.readBegan = readInstant(0)
        #expect(PowerFlowState.isCurrent(bare, now: time(10_000), at: readInstant(telemetryAge)))
        #expect(!PowerFlowState.isCurrent(bare, now: time(10_000), at: readInstant(telemetryAge + 1)))
    }

    /// A state showing a reading made and updated at wall-clock 0 s, whose
    /// read began at 0 s on the continuous clock.
    private func freshState() -> PowerFlowState {
        var state = PowerFlowState()
        state.take(snapshot: powerSnapshot(update: time(0), at: time(0)), began: 0, now: time(0))
        return state
    }

    @Test("The wall clock jumps forward: the policy calls the reading old, and so does the display, though little time passed on the continuous clock")
    func wallClockForward() {
        var state = freshState()
        #expect(state.flow?.macUseWatts == 30)
        // At 10 s on the continuous clock the wall clock jumps to 100 s.
        state.take(PowerFlowTick(content: .empty, at: readInstant(10)), now: time(100), deliveredAt: readInstant(10))
        #expect(ChargingPolicy.staleness(of: powerSnapshot(update: time(0), at: time(0)), now: time(100)) != nil)
        #expect(!state.hasSample)
    }

    @Test("The wall clock is set back: a small change keeps the reading until a minute passes on the continuous clock; a large one makes it from the future")
    func wallClockBack() {
        var small = freshState()
        // Set back 30 s at 10 s: 20 s ahead on the wall clock, within the
        // skew; 10 s old on the continuous clock.
        small.take(PowerFlowTick(content: .empty, at: readInstant(10)), now: time(-20), deliveredAt: readInstant(10))
        #expect(small.hasSample)
        // 61 s on the continuous clock: only 31 s on the wall clock.
        small.take(PowerFlowTick(content: .empty, at: readInstant(61)), now: time(31), deliveredAt: readInstant(61))
        #expect(!small.hasSample)
        // Set back 100 s at 10 s: 90 s ahead on the wall clock.
        var large = freshState()
        large.take(PowerFlowTick(content: .empty, at: readInstant(10)), now: time(-90), deliveredAt: readInstant(10))
        #expect(!large.hasSample)
    }

    @Test("A sleep moves both clocks on: the reading from before it is old by both")
    func sleepMovesBothClocks() {
        var state = freshState()
        state.take(PowerFlowTick(content: .empty, at: readInstant(3_600)), now: time(3_600), deliveredAt: readInstant(3_600))
        #expect(!state.hasSample)
        // Either clock alone would say so.
        var wallOnly = freshState()
        wallOnly.rejudge(now: time(3_600), at: readInstant(0))
        #expect(!wallOnly.hasSample)
        var continuousOnly = freshState()
        continuousOnly.rejudge(now: time(0), at: readInstant(3_600))
        #expect(!continuousOnly.hasSample)
    }

    @Test("Failed display reads keep a cached reading only while its read is under a minute old, also without the driver's update time")
    func cachedReadAge() {
        var state = PowerFlowState()
        var sample = PowerFlowSample(powerSnapshot(update: time(0), at: time(1)))
        sample.readBegan = readInstant(1)
        state.tick(.registry(sample), .absent, at: 1)
        state.tick(.empty, .absent, at: 61)
        #expect(state.hasSample)
        state.tick(.empty, .absent, at: 61.5)
        #expect(!state.hasSample)
        // Without the driver's update time, the read's age still bounds it.
        var bare = PowerFlowState()
        var undated = PowerFlowSample(powerSnapshot(update: nil, at: time(1)))
        undated.readBegan = readInstant(1)
        bare.tick(.registry(undated), .absent, at: 1)
        bare.tick(.empty, .absent, at: 61)
        #expect(bare.flow?.macUseWatts == 30)
        bare.tick(.empty, .absent, at: 3_600)
        #expect(bare.flow == nil)
    }

    @Test("A status delivered again never makes its reading's read look newer")
    func redeliveredStatus() {
        var state = PowerFlowState()
        let reading = powerSnapshot(update: time(0), at: time(1))
        state.takeStatus(snapshot: reading, evaluatedAt: time(1), readBegan: readInstant(1), now: time(1), deliveredAt: readInstant(1))
        // A command at 50 s that read nothing returns the same status.
        state.takeStatus(snapshot: reading, evaluatedAt: time(1), readBegan: readInstant(50), now: time(50), deliveredAt: readInstant(50))
        #expect(state.hasSample)
        state.tick(.empty, .absent, at: 62)
        #expect(!state.hasSample)
    }

    @Test("Wall-clock changes never make an old read look new: its age is on the continuous clock")
    func readAgeIgnoresWallClock() {
        var state = PowerFlowState()
        state.take(snapshot: powerSnapshot(update: nil, at: time(1)), began: 1, now: time(1))
        state.take(PowerFlowTick(content: .empty, at: readInstant(41)), now: time(41), deliveredAt: readInstant(41))
        #expect(state.hasSample)
        // 70 s after the read on the continuous clock, the wall clock set
        // back 30 s meanwhile: by the wall clock the read is 40 s old.
        state.take(PowerFlowTick(content: .empty, at: readInstant(71)), now: time(41), deliveredAt: readInstant(71))
        #expect(!state.hasSample)
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

    @Test("Failed display reads keep a cached reading only while the driver's update is current, for a source that gives no read time")
    func cachedAfterFailedReads() {
        var state = PowerFlowState()
        var sample = PowerFlowSample(powerSnapshot(update: time(0)))
        sample.readAt = nil
        state.tick(.registry(sample), .absent, at: 1)
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

    @Test("A battery power an accepted SMC window borrowed is judged again at every tick: it is dropped when its reading goes stale, and the window's own values stay")
    func borrowedBatteryExpires() {
        var state = PowerFlowState()
        // The registry's update at 0 s, read freshly at 178 s.
        state.status(powerSnapshot(update: time(0), at: time(178)), at: 178)
        // A window without B0AP, accepted at 180 s: the reading is 180 s old,
        // still current, so its battery power is borrowed.
        state.tick(.window(smcWindow(began: 178, span: 2)), at: 180)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.battery == .charging(watts: 15))
        // At 183 s the window is fresh but the reading is not.
        state.tick(.empty, at: 183)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.battery == nil)
        #expect(state.flow?.batteryLink == .unknown)
        #expect(state.flow?.macUseWatts == 20)
        #expect(state.flow?.adapterInputWatts == 30)
        // A window with its own B0AP is not affected by the reading's age.
        var own = PowerFlowState()
        own.status(powerSnapshot(update: time(0), at: time(178)), at: 178)
        own.tick(.window(smcWindow(began: 178, span: 2, battery: -4)), at: 180)
        own.tick(.empty, at: 183)
        #expect(own.flow?.battery == .supplying(watts: 4))
    }

    @Test("A fresh SMC window is shown while the registry track's reading is stale, without the reading's battery power; the registry track then shows nothing")
    func freshSMCOverStaleRegistry() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 300, macUse: 21)), at: 303)
        #expect(state.hasSample)
        #expect(state.flow?.macUseWatts == 21)
        #expect(state.flow?.batteryWatts == nil)
        state.tick(.empty, .failing, at: 304)
        #expect(state.shownTrack == .registry)
        #expect(!state.hasSample)
    }

    @Test("A reading without the driver's update time is judged by its read's age alone")
    func withoutUpdateTime() {
        var state = PowerFlowState()
        state.take(snapshot: powerSnapshot(update: nil, at: time(0)), now: time(60))
        #expect(state.flow?.macUseWatts == 30)
        state.rejudge(now: time(61), at: readClockOrigin)
        #expect(state.flow == nil)
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
        // Placed after the update at 60 s, but recorded at 30 s: a delivery
        // at 45 s is not behind it, and restarts nothing.
        behind.restartIfClockSetBack(now: time(45))
        behind.record(fastSample(120, load: 25))
        #expect(behind.points.map(\.updates) == [1, 1, 1])
        #expect(segments(behind, .macUse) == [[0], [60], [120]])
    }

    @Test("A wall clock set back past a newest break restarts the history, so the chart recovers")
    func rollbackAfterBreak() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        // A failed read at 8,000 s on the wall clock: the break is the
        // newest point, more than two hours after the only update, which it
        // drops as a newer update would.
        state.takeStatus(snapshot: nil, evaluatedAt: time(8_000), readBegan: readInstant(8_000), now: time(8_000), deliveredAt: readInstant(8_000))
        #expect(state.history.points.map(\.updates) == [0])
        // The wall clock is set back; the continuous clock goes on. A fresh
        // update at 60 s arrives.
        state.takeStatus(
            snapshot: powerSnapshot(load: 20_000, update: time(60), at: time(60)),
            evaluatedAt: time(60),
            readBegan: readInstant(8_010),
            now: time(61),
            deliveredAt: readInstant(8_011)
        )
        #expect(state.flow?.macUseWatts == 20)
        #expect(state.history.newestTime == time(60))
        #expect(state.history.points.map(\.updates) == [1])
        let shown = state.history.chartPoints(maximumGap: 180).filter { $0.series == .macUse }.map(\.watts)
        #expect(shown == [20])
        // The chart fills in again.
        state.takeStatus(
            snapshot: powerSnapshot(load: 25_000, update: time(120), at: time(120)),
            evaluatedAt: time(120),
            readBegan: readInstant(8_070),
            now: time(121),
            deliveredAt: readInstant(8_071)
        )
        #expect(state.flow?.macUseWatts == 25)
        // The history starts from a break where the rollback was found
        // (61 s): the update stamped 60 s and read then cannot be told from
        // one cached before the failure, so it stands alone; the line goes
        // on from 120 s.
        #expect(segments(state.history, .macUse) == [[60], [120]])
        state.takeStatus(
            snapshot: powerSnapshot(load: 25_000, update: time(180), at: time(180)),
            evaluatedAt: time(180),
            readBegan: readInstant(8_130),
            now: time(181),
            deliveredAt: readInstant(8_131)
        )
        #expect(segments(state.history, .macUse) == [[60], [120, 180]])
    }

    /// A controller status read and delivered at `wall` on the wall clock
    /// and `continuous` on the continuous clock.
    private func status(_ snapshot: BatterySnapshot?, into state: inout PowerFlowState, wall: TimeInterval, continuous: Double) {
        state.takeStatus(
            snapshot: snapshot,
            evaluatedAt: time(wall),
            readBegan: readInstant(continuous),
            now: time(wall),
            deliveredAt: readInstant(continuous)
        )
    }

    @Test("A small rollback past a failed read restarts the history, and no line joins across the failure")
    func smallRollbackPastBreak() {
        var state = PowerFlowState()
        status(powerSnapshot(update: time(0), at: time(0)), into: &state, wall: 0, continuous: 0)
        // At 10 s the wall clock is 4 minutes fast, and the controller's
        // read fails at 250 s by it.
        status(nil, into: &state, wall: 250, continuous: 10)
        // Time sync corrects it: a clock-change evaluation at 20 s rereads
        // the cached update from 0 s, then a fresh update comes at 60 s.
        status(powerSnapshot(update: time(0), at: time(20)), into: &state, wall: 20, continuous: 20)
        status(powerSnapshot(load: 20_000, update: time(60), at: time(60)), into: &state, wall: 60, continuous: 60)
        #expect(state.flow?.macUseWatts == 20)
        #expect(state.history.newestTime == time(60))
        #expect(state.history.points.map(\.updates) == [1, 0, 1])
        for series in PowerFlowHistory.Series.allCases {
            #expect(segments(state.history, series) == [[0], [60]], "\(series)")
        }
    }

    @Test("A driver update stamped before a failure and read after it restarts nothing: the history and the gap stay")
    func updateStampedBeforeFailure() {
        var state = PowerFlowState()
        status(powerSnapshot(update: time(200), at: time(200)), into: &state, wall: 200, continuous: 200)
        status(nil, into: &state, wall: 250, continuous: 250)
        // The driver updated at 240 s; it is read at 255 s.
        status(powerSnapshot(load: 20_000, update: time(240), at: time(255)), into: &state, wall: 255, continuous: 255)
        status(powerSnapshot(load: 25_000, update: time(300), at: time(300)), into: &state, wall: 300, continuous: 300)
        let times = state.history.points.map { $0.time.timeIntervalSince(referenceDate) }
        let expected: [TimeInterval] = [200, 240, 250, 300]
        #expect(times == expected)
        #expect(state.history.points.map(\.updates) == [1, 1, 0, 1])
        #expect(segments(state.history, .macUse) == [[200, 240], [300]])
    }

    @Test("After a wake, an old driver update following a break restarts nothing")
    func wakeKeepsHistory() {
        var history = PowerFlowHistory()
        history.record(fastSample(0))
        history.record(fastSample(60, load: 20))
        // A failed read on waking two hours later, then the driver's update
        // from before the sleep, not yet refreshed.
        history.recordBreak(at: time(7_260))
        history.restartIfClockSetBack(now: time(7_261))
        history.record(fastSample(70, load: 25))
        // The update at 0 s is more than two hours before the break; the
        // rest stays, and the late update joins it.
        #expect(history.points.map(\.updates) == [1, 1, 0])
    }

    // MARK: - Judged when it could be seen

    @Test("A wake judges the flow again at once, with every read suspended: a reading from before the sleep is never shown")
    func wakeRejudges() {
        var state = freshState()
        var visibility = PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: false)
        visibility.apply({ $0.setMenuVisible(true) }, judging: &state, now: time(0), at: readInstant(0))
        #expect(visibility.isShown)
        #expect(state.hasSample)
        visibility.apply({ $0.willSleep() }, judging: &state, now: time(5), at: readInstant(5))
        // An hour later, no tick and no status yet.
        visibility.apply({ $0.didWake(); return false }, judging: &state, now: time(3_605), at: readInstant(3_605))
        #expect(visibility.isShown)
        #expect(!state.hasSample)
    }

    @Test("Every change that shows the flow judges it again: the menu reopened, the diagram switched on, the section expanded")
    func showingRejudges() {
        let shows: [(PowerFlowVisibility, (inout PowerFlowVisibility) -> Bool)] = [
            (PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: false), { $0.setMenuVisible(true) }),
            (PowerFlowVisibility(showsDiagramAtTop: false, isSectionExpanded: false), { $0.setShowsDiagramAtTop(true) }),
            (PowerFlowVisibility(showsDiagramAtTop: false, isSectionExpanded: false), { $0.setSectionExpanded(true) }),
        ]
        for (index, (initial, show)) in shows.enumerated() {
            var visibility = initial
            var state = freshState()
            if !visibility.isMenuVisible, index > 0 {
                _ = visibility.setMenuVisible(true)
            }
            #expect(!visibility.isShown)
            visibility.apply(show, judging: &state, now: time(120), at: readInstant(120))
            #expect(visibility.isShown, "change \(index)")
            #expect(!state.hasSample, "change \(index)")
        }
        // A change that leaves the flow hidden judges nothing.
        var hidden = PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: false)
        var state = freshState()
        hidden.apply({ $0.setSectionExpanded(true) }, judging: &state, now: time(120), at: readInstant(120))
        #expect(!hidden.isShown)
        #expect(state.hasSample)
    }

    @Test("A tick waiting for its delivery is judged when delivered, not when it was made")
    func queuedDelivery() {
        // A source with no wall-clock read or update time, so that only the
        // continuous clock judges it.
        var sample = PowerFlowSample(powerSnapshot(update: nil))
        sample.readAt = nil
        sample.readBegan = readInstant(1)
        var state = PowerFlowState()
        state.take(sample, now: time(1), deliveredAt: readInstant(1))
        // Made at 60.951 s, its read then 59.951 s old; delivered after a
        // 210 ms wait for the main actor, 60.161 s old.
        state.take(PowerFlowTick(content: .empty, at: readInstant(60.951)), now: time(61.161), deliveredAt: readInstant(61.161))
        #expect(!state.hasSample)
        // A display read delivered late is judged from its delivery too.
        var late = PowerFlowState()
        var slow = sample
        slow.readBegan = readInstant(0)
        late.take(PowerFlowTick(content: .registry(slow), at: readInstant(59.9)), now: time(60.2), deliveredAt: readInstant(60.2))
        #expect(!late.hasSample)
        // Delivered in time, it is shown.
        var prompt = PowerFlowState()
        prompt.take(PowerFlowTick(content: .registry(slow), at: readInstant(59.9)), now: time(59.95), deliveredAt: readInstant(59.95))
        #expect(prompt.hasSample)
    }

    // MARK: - The history's bound

    @Test("At most 721 points, updates and breaks together: two hours of updates, then two hours of breaks")
    func boundedPoints() {
        var history = PowerFlowHistory()
        for index in 0...720 {
            history.record(fastSample(TimeInterval(index * 10)))
        }
        #expect(history.points.count == 721)
        for index in 1...720 {
            history.recordBreak(at: time(TimeInterval(7_200 + index * 10)))
        }
        #expect(history.points.count == 721)
        let oldest = history.points.first?.time.timeIntervalSince(referenceDate)
        #expect(oldest == 7_200)
    }

    // MARK: - Only what is current is recorded

    @Test("An update cached while the clock was fast and reread after it was corrected is from the future: it is neither recorded nor drawn across the failure")
    func futureCachedUpdate() {
        var state = PowerFlowState()
        status(powerSnapshot(update: time(0), at: time(0)), into: &state, wall: 0, continuous: 0)
        // The wall clock jumps 4 minutes ahead; at 61 s on the continuous
        // clock an update stamped 300 s is read at 301 s.
        status(powerSnapshot(update: time(300), at: time(301)), into: &state, wall: 301, continuous: 61)
        // A read fails at 70 s, 310 s by the wall clock.
        status(nil, into: &state, wall: 310, continuous: 70)
        // Corrected: at 80 s the cached update from 300 s is read again,
        // 220 s in the future, then a fresh update at 120 s.
        status(powerSnapshot(update: time(300), at: time(80)), into: &state, wall: 80, continuous: 80)
        #expect(!state.hasSample)
        status(powerSnapshot(load: 20_000, update: time(120), at: time(120)), into: &state, wall: 120, continuous: 120)
        #expect(state.flow?.macUseWatts == 20)
        let times = state.history.points.map { $0.time.timeIntervalSince(referenceDate) }
        let expected: [TimeInterval] = [80, 120]
        #expect(times == expected)
        #expect(state.history.newestTime == time(120))
        #expect(segments(state.history, .macUse) == [[120]])
    }

    @Test("After a long sleep the driver's old update is not recorded; a fresh one records and draws as usual")
    func wakeRecordsOnlyCurrent() {
        var state = PowerFlowState()
        status(powerSnapshot(update: time(0), at: time(0)), into: &state, wall: 0, continuous: 0)
        status(powerSnapshot(update: time(60), at: time(60)), into: &state, wall: 60, continuous: 60)
        // Asleep for two hours; on waking the driver still reports an
        // update from just before the sleep, never read.
        status(powerSnapshot(update: time(90), at: time(7_260)), into: &state, wall: 7_260, continuous: 7_260)
        #expect(!state.hasSample)
        #expect(!state.history.points.contains { $0.time == time(90) })
        status(powerSnapshot(load: 20_000, update: time(7_300), at: time(7_301)), into: &state, wall: 7_301, continuous: 7_301)
        status(powerSnapshot(load: 25_000, update: time(7_360), at: time(7_361)), into: &state, wall: 7_361, continuous: 7_361)
        #expect(state.flow?.macUseWatts == 25)
        #expect(segments(state.history, .macUse).last == [7_300, 7_360])
    }

    @Test("The last break's instant is forgotten when the break is dropped by its age, or when the history starts again")
    func lastBreakForgotten() {
        // Dropped by its age: a later delivery behind it restarts nothing.
        var pruned = PowerFlowHistory()
        pruned.record(fastSample(0))
        pruned.recordBreak(at: time(60))
        pruned.record(fastSample(7_300))
        #expect(pruned.points.map(\.updates) == [1])
        pruned.restartIfClockSetBack(now: time(30))
        #expect(pruned.points.map(\.updates) == [1])
        // The clock rule started the history again from an older update.
        var reset = PowerFlowHistory()
        reset.record(fastSample(0))
        reset.recordBreak(at: time(400))
        reset.record(fastSample(-400))
        #expect(reset.points.map(\.updates) == [1])
        reset.restartIfClockSetBack(now: time(-390))
        #expect(reset.points.map(\.updates) == [1])
    }
}
