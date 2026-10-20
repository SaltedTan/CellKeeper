import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

@Suite("Calibration: system clock and refusals")
struct CalibrationKitTests {
    @Test("The system's calibration clock reads a monotonic clock, the boot's identifier and its time, read-only")
    func systemClock() throws {
        let clock = CalibrationClock.system()
        let first = clock.monotonic()
        let second = clock.monotonic()
        #expect(first > 0)
        #expect(second >= first)
        let boot = try #require(clock.bootSession())
        #expect(!boot.isEmpty)
        #expect(clock.bootSession() == boot)
        let started = try #require(clock.bootTime())
        #expect(started < Date())
        // The monotonic clock counts from boot, so the boot time is about
        // now minus it, within the clock's own drift and sleep.
        #expect(started.timeIntervalSinceNow < 0)
    }

    @Test("“Charge to 100% once” and Start CellKeeper Full Charge are refused during a calibration, first of all reasons")
    func fullChargeRefused() async {
        var status = await evaluatedActionStatus()
        #expect(FullChargeStart.refusal(settings: .default, status: status) == nil)
        status.calibration = CalibrationStatus(
            isAvailable: true,
            session: CalibrationSession.start(id: UUID(), at: CalibrationStamp(wall: Date(), monotonic: 0, boot: "b"), ownerLimit: 90, cellKeeperLimit: 80, before: CalibrationCapacities(), temperatureCheck: .ownerConfirmedCoolRoom, optimizedCharging: .off),
            isPaused: true
        )
        #expect(FullChargeStart.refusal(settings: .default, status: status) == "A calibration is in progress.")
        var off = ChargingSettings.default
        off.isManagementEnabled = false
        #expect(FullChargeStart.refusal(settings: off, status: status) == "A calibration is in progress.")
    }
}
