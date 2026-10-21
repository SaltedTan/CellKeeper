@testable import CellKeeperCore
import Foundation
import Testing

extension PowerFlowState {
    /// A tick at `seconds` after ``readClockOrigin``.
    mutating func tick(_ content: PowerFlowTick.Content, _ state: SMCSourceState = .available, at seconds: Double) {
        take(PowerFlowTick(content: content, smcState: state, at: readInstant(seconds)))
    }

    /// A controller status whose work began, and was evaluated, at
    /// `seconds`.
    mutating func status(_ snapshot: BatterySnapshot?, at seconds: Double) {
        takeStatus(snapshot: snapshot, evaluatedAt: referenceDate.addingTimeInterval(seconds), readBegan: readInstant(seconds))
    }

    /// The updates the history holds.
    var recordedUpdates: Int {
        history.points.map(\.updates).reduce(0, +)
    }
}

@Suite("Power flow tracks")
struct PowerFlowTracksTests {
    private func time(_ seconds: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(seconds)
    }

    private func footnote(_ state: PowerFlowState) -> String? {
        state.provenance.map {
            PowerFlowWording.footnote(
                $0,
                isOnExternalPower: state.flow?.powerSource == .externalPower,
                registrySourceName: "macOS's battery data",
                registryUpdateInterval: .seconds(60)
            )
        }
    }

    @Test("The 6 s rule: a window shows until 6 s after it was accepted, then the registry track's cached reading, also after a failed read")
    func freshness() {
        var state = PowerFlowState()
        state.status(powerSnapshot(load: 30_000, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, macUse: 20)), at: 5)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.macUseWatts == 20)
        state.tick(.empty, at: 8)
        state.tick(.empty, at: 10.99)
        #expect(state.shownTrack == .smc)
        state.tick(.empty, at: 11)
        #expect(state.shownTrack == .registry)
        #expect(state.flow?.macUseWatts == 30)
        // A failed display read (an empty tick) keeps the cached reading.
        state.tick(.empty, .failing, at: 14)
        #expect(state.hasSample)
        #expect(state.flow?.macUseWatts == 30)
    }

    @Test("The 6 s rule with an empty registry track: no reading")
    func freshnessWithoutRegistry() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2)), at: 5)
        // The controller's read fails while the SMC is shown.
        state.status(nil, at: 6)
        #expect(state.shownTrack == .smc)
        #expect(state.hasSample)
        state.tick(.empty, at: 8)
        #expect(state.hasSample)
        state.tick(.empty, at: 11)
        #expect(state.shownTrack == .registry)
        #expect(!state.hasSample)
        #expect(state.flow == nil)
    }

    @Test("Only while the source is available: any other state shows the registry track at that tick")
    func onlyWhileAvailable() {
        for other in [SMCSourceState.failing, .probing, .backingOff, .absent] {
            var state = PowerFlowState()
            state.status(powerSnapshot(load: 30_000, update: time(0)), at: 1)
            state.tick(.window(smcWindow(began: 2, macUse: 20)), at: 5)
            state.tick(.empty, other, at: 6)
            #expect(state.shownTrack == .registry, "\(other)")
            #expect(state.flow?.macUseWatts == 30, "\(other)")
            // A window offered in that state is not accepted.
            state.tick(.window(smcWindow(began: 6, macUse: 10)), other, at: 9)
            #expect(state.shownTrack == .registry, "\(other)")
            #expect(state.recordedUpdates == 2, "\(other)")
        }
    }

    @Test("A reset clears the accepted SMC track: after an unplug the registry track shows at once, never the old adapter diagram")
    func unplugClearsSMC() {
        var state = PowerFlowState()
        state.status(powerSnapshot(source: .externalPower, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, adapterInput: 30)), at: 5)
        #expect(state.flow?.adapterInputWatts == 30)
        // Unplugged: the power-source change's status arrives before the
        // next tick.
        state.status(powerSnapshot(source: .battery, powerIn: 0, load: 11_000, current: -900, update: time(6)), at: 6)
        #expect(state.shownTrack == .registry)
        #expect(state.flow?.powerSource == .battery)
        #expect(state.flow?.adapterInputWatts == nil)
        #expect(state.registryPowerSource == .battery)
        // A window whose batches began before the read that saw the unplug
        // is refused, even though the source is still available.
        state.tick(.window(smcWindow(began: 5.5, adapterInput: 30)), at: 8)
        #expect(state.shownTrack == .registry)
        // A later one is shown, on battery.
        state.tick(.window(smcWindow(began: 7.5, macUse: 11)), at: 11)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.powerSource == .battery)
        #expect(state.flow?.macUseWatts == 11)
    }

    @Test("Hiding the section or a wake clears the SMC track")
    func clearSMCTrack() {
        var state = PowerFlowState()
        state.status(powerSnapshot(load: 30_000, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, macUse: 20)), at: 5)
        state.clearSMCTrack(at: readInstant(5.5))
        #expect(state.shownTrack == .registry)
        #expect(state.flow?.macUseWatts == 30)
        // The same window is not shown again at the next tick.
        state.tick(.empty, at: 6)
        #expect(state.shownTrack == .registry)
    }

    @Test("Delivered late across a wake: a window published before the wake and arriving after it is dropped, and a later one is shown")
    func delayedDeliveryAcrossWake() {
        var state = PowerFlowState()
        state.status(powerSnapshot(load: 30_000, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, macUse: 20)), at: 5)
        let recorded = state.recordedUpdates
        // The refresher took a window (its batches began at 5 s) from the
        // source just before the Mac slept; the wake at 600 s clears the SMC
        // track, and only then does that tick reach the state.
        state.clearSMCTrack(at: readInstant(600))
        state.tick(.window(smcWindow(began: 5, macUse: 99)), at: 600.1)
        #expect(state.shownTrack == .registry)
        #expect(state.flow?.macUseWatts == 30)
        #expect(state.recordedUpdates == recorded)
        // So is a window whose batches straddle the wake.
        state.tick(.window(smcWindow(began: 599.5, macUse: 98)), at: 603)
        #expect(state.shownTrack == .registry)
        // A window read after the wake is shown.
        state.tick(.window(smcWindow(began: 601, macUse: 21)), at: 604)
        #expect(state.shownTrack == .smc)
        #expect(state.flow?.macUseWatts == 21)
        #expect(state.recordedUpdates == recorded + 1)
    }

    @Test("Every reset drops windows from before it: hiding the section, a wake, and a power-source change")
    func everyResetDropsOlderWindows() {
        for reset in ["hide", "wake", "power source"] {
            var state = PowerFlowState()
            state.status(powerSnapshot(source: .externalPower, update: time(0)), at: 1)
            state.tick(.window(smcWindow(began: 2, adapterInput: 30)), at: 5)
            switch reset {
            case "power source":
                state.status(powerSnapshot(source: .battery, current: -900, update: time(10)), at: 10)
            default:
                // Hiding and a wake both clear the track at that moment.
                state.clearSMCTrack(at: readInstant(10))
            }
            #expect(state.shownTrack == .registry, "\(reset)")
            // Published before the reset (its batches began at 8 s),
            // delivered after it.
            state.tick(.window(smcWindow(began: 8, adapterInput: 30)), at: 11)
            #expect(state.shownTrack == .registry, "\(reset)")
            state.tick(.window(smcWindow(began: 10.5)), at: 14)
            #expect(state.shownTrack == .smc, "\(reset)")
        }
    }

    @Test("A later clear never moves the cutoff back")
    func cutoffOnlyMovesForward() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.clearSMCTrack(at: readInstant(20))
        state.clearSMCTrack(at: readInstant(10))
        state.tick(.window(smcWindow(began: 15)), at: 21)
        #expect(state.shownTrack == .registry)
        state.tick(.window(smcWindow(began: 20)), at: 24)
        #expect(state.shownTrack == .smc)
    }

    @Test("Repeats across tracks: a status delivered while the SMC is shown, delivered again after it fails, changes nothing")
    func repeatsAcrossTracks() {
        var state = PowerFlowState()
        state.status(powerSnapshot(load: 30_000, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, collected: 5)), at: 5)
        // The 60 s check's status, while the SMC is shown: kept in the
        // registry track, not recorded.
        let check = powerSnapshot(load: 25_000, update: time(60))
        state.status(check, at: 61)
        #expect(state.shownTrack == .smc)
        state.tick(.window(smcWindow(began: 62, collected: 64)), at: 64)
        let before = state.recordedUpdates
        // The SMC fails; the registry track, with the check's reading, is
        // shown.
        state.tick(.empty, .failing, at: 67)
        #expect(state.flow?.macUseWatts == 25)
        let shown = state
        // A command that read nothing delivers the same status again.
        state.takeStatus(snapshot: check, evaluatedAt: time(61), readBegan: readInstant(70))
        #expect(state == shown)
        #expect(state.recordedUpdates == before)
    }

    @Test("Metadata and battery power come from the registry track; B0AP's average replaces only the battery's power")
    func metadata() {
        var state = PowerFlowState()
        state.status(powerSnapshot(load: 30_000, current: 1_250, adapter: 96, percent: 64, update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, macUse: 21, adapterInput: 40)), at: 5)
        #expect(state.flow?.powerSource == .externalPower)
        #expect(state.flow?.adapterRatingWatts == 96)
        #expect(state.flow?.chargePercent == 64)
        #expect(state.flow?.batteryWatts == 15)
        #expect(state.flow?.macUseWatts == 21)
        #expect(state.flow?.adapterInputWatts == 40)
        #expect(state.provenance == PowerFlowProvenance(system: .smc(averagedOver: .seconds(3)), battery: .registry))
        // After O1, a window whose every batch had a valid B0AP.
        state.tick(.window(smcWindow(began: 5, battery: 9.5)), at: 8)
        #expect(state.flow?.batteryWatts == 9.5)
        #expect(state.provenance == PowerFlowProvenance(system: .smc(averagedOver: .seconds(3)), battery: .smc))
        // A window with one invalid B0AP has none (``SMCPowerSampler``):
        // the whole window takes the registry track's battery power.
        state.tick(.window(smcWindow(began: 8, battery: nil)), at: 11)
        #expect(state.flow?.batteryWatts == 15)
        #expect(state.provenance?.battery == .registry)
        // A newer registry reading's metadata is used from the next window.
        state.status(powerSnapshot(load: 30_000, current: -500, adapter: 96, percent: 65, update: time(60)), at: 12)
        #expect(state.flow?.chargePercent == 64)
        state.tick(.window(smcWindow(began: 11)), at: 14)
        #expect(state.flow?.chargePercent == 65)
        #expect(state.flow?.batteryWatts == -6)
    }

    @Test("A window is refused without a known power source in the registry track, out of order, or from before the power source's read")
    func refusedWindows() {
        var empty = PowerFlowState()
        empty.tick(.window(smcWindow(began: 2)), at: 5)
        #expect(empty.shownTrack == .registry)
        #expect(!empty.hasSample)
        #expect(empty.history.points.isEmpty)

        var unknown = PowerFlowState()
        unknown.status(powerSnapshot(source: .unknown, update: time(0)), at: 1)
        unknown.tick(.window(smcWindow(began: 2)), at: 5)
        #expect(unknown.shownTrack == .registry)

        var failed = PowerFlowState()
        failed.status(powerSnapshot(update: time(0)), at: 1)
        failed.status(nil, at: 2)
        failed.tick(.window(smcWindow(began: 3)), at: 6)
        #expect(failed.shownTrack == .registry)

        var ordered = PowerFlowState()
        ordered.status(powerSnapshot(update: time(0)), at: 1)
        ordered.tick(.window(smcWindow(began: 5, macUse: 20)), at: 8)
        ordered.tick(.window(smcWindow(began: 5, macUse: 10)), at: 9)
        ordered.tick(.window(smcWindow(began: 4, macUse: 10)), at: 10)
        #expect(ordered.flow?.macUseWatts == 20)
        #expect(ordered.recordedUpdates == 2)

        // A status whose work began before the window's batches does not
        // hold it back: windows are never compared with registry readings.
        var late = PowerFlowState()
        late.status(powerSnapshot(update: time(0)), at: 1)
        late.status(powerSnapshot(update: time(0), at: time(9)), at: 9)
        late.tick(.window(smcWindow(began: 6)), at: 10)
        #expect(late.shownTrack == .smc)
    }

    @Test("Provenance and the footnote follow the sample on screen at every switch")
    func provenanceSwitches() {
        var state = PowerFlowState()
        let registry = "From macOS's battery data, updated about once a minute."
        let smc = "Adapter and Mac from the SMC, averaged over 3 seconds; battery from macOS's battery data, updated about once a minute."
        #expect(footnote(state) == nil)
        state.status(powerSnapshot(update: time(0)), at: 1)
        #expect(state.provenance == .registry)
        #expect(footnote(state) == registry)
        state.tick(.window(smcWindow(began: 2)), at: 5)
        #expect(footnote(state) == smc)
        state.tick(.empty, at: 11)
        #expect(footnote(state) == registry)
        state.tick(.window(smcWindow(began: 9, span: 2)), at: 12)
        #expect(footnote(state) == "Adapter and Mac from the SMC, averaged over 2 seconds; battery from macOS's battery data, updated about once a minute.")
        state.tick(.window(smcWindow(began: 12, battery: 10)), at: 15)
        #expect(footnote(state) == "Adapter, Mac and battery from the SMC, averaged over 3 seconds.")
        state.tick(.empty, .failing, at: 16)
        #expect(footnote(state) == registry)
        // On battery the adapter has no value to name.
        state.status(powerSnapshot(source: .battery, current: -900, update: time(60)), at: 17)
        state.tick(.window(smcWindow(began: 18, span: 1)), at: 20)
        #expect(footnote(state) == "Mac from the SMC, averaged over 1 second; battery from macOS's battery data, updated about once a minute.")
        state.tick(.window(smcWindow(began: 21, battery: -10)), at: 24)
        #expect(footnote(state) == "Mac and battery from the SMC, averaged over 3 seconds.")
        state.clearSMCTrack(at: readInstant(25))
        #expect(footnote(state) == registry)
    }

    @Test("The history: one point per accepted window, and no registry points while the SMC is shown")
    func history() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        #expect(state.recordedUpdates == 1)
        state.tick(.window(smcWindow(began: 2, collected: 5)), at: 5)
        #expect(state.recordedUpdates == 2)
        // A window kept on screen is not recorded again.
        state.tick(.empty, at: 8)
        #expect(state.recordedUpdates == 2)
        // A status and a display read while the SMC is shown: kept in the
        // registry track, not recorded.
        state.status(powerSnapshot(load: 25_000, update: time(60)), at: 61)
        state.tick(.window(smcWindow(began: 62, collected: 65)), at: 65)
        state.tick(.registry(PowerFlowSample(powerSnapshot(load: 26_000, update: time(66)))), at: 67.9)
        #expect(state.shownTrack == .smc)
        #expect(state.recordedUpdates == 3)
        #expect(state.history.points.last?.time == time(65))
        // The SMC fails. A registry update from before the last window
        // would land among its points, and is not recorded; a newer one is.
        state.tick(.registry(PowerFlowSample(powerSnapshot(load: 26_000, update: time(60)))), .failing, at: 71)
        #expect(state.shownTrack == .registry)
        #expect(state.recordedUpdates == 3)
        state.tick(.registry(PowerFlowSample(powerSnapshot(load: 27_000, update: time(120)))), .failing, at: 121)
        #expect(state.recordedUpdates == 4)
        #expect(state.history.points.last?.time == time(120))
    }

    @Test("Long after the last window, registry readings are recorded as D114 records them, so a clock set back cannot stop the history")
    func historyAfterWindowsAge() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, collected: 5)), at: 5)
        state.tick(.empty, .failing, at: 8)
        // More than 5 minutes later, the wall clock was set back ten
        // minutes: the history starts again from the reading.
        state.status(powerSnapshot(update: time(-600)), at: 400)
        #expect(state.history.points.map(\.time) == [time(-600)])
    }

    @Test("The status that shows an unplug while the SMC is shown is recorded: it puts the registry track on screen")
    func unplugIsRecorded() {
        var state = PowerFlowState()
        state.status(powerSnapshot(update: time(0)), at: 1)
        state.tick(.window(smcWindow(began: 2, collected: 5)), at: 5)
        state.status(powerSnapshot(source: .battery, current: -900, update: time(6)), at: 6)
        #expect(state.recordedUpdates == 3)
        #expect(state.history.points.last?.time == time(6))
    }

    @Test("Without the SMC every tick and status behaves as D114's registry reads")
    func absent() {
        var state = PowerFlowState()
        state.tick(.registry(PowerFlowSample(powerSnapshot(update: time(0)))), .absent, at: 1)
        state.tick(.empty, .absent, at: 4)
        state.status(powerSnapshot(load: 20_000, update: time(60)), at: 61)
        #expect(state.shownTrack == .registry)
        #expect(state.smcState == .absent)
        #expect(state.flow?.macUseWatts == 20)
        #expect(state.provenance == .registry)
        #expect(state.recordedUpdates == 2)
    }
}
