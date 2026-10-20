import CellKeeperCore
import Foundation
import Testing

private let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1 (Build 26A434)", modelIdentifier: "Mac16,1")

private func calibrationSection(_ status: ControllerStatus) -> DiagnosticsSection? {
    DiagnosticsReport.sections(status: status, environment: environment).first { $0.title == "Calibration" }
}

private func value(_ section: DiagnosticsSection?, _ label: String) -> String? {
    section?.rows.first { $0.label == label }?.value.reportText
}

@Suite("Calibration: report in Diagnostics and the activity log")
struct CalibrationDiagnosticsTests {
    @Test("Without a calibration, the report has no Calibration section, so earlier reports read as before")
    func absent() async {
        let rig = CalibrationRig()
        #expect(calibrationSection(await rig.controller.evaluate(.launch)) == nil)
    }

    @Test("A session in progress shows its step, its times, the limits and the temperature check")
    func inProgress() async throws {
        let rig = CalibrationRig()
        let status = await rig.drive(to: .restAtBottom)
        let section = try #require(calibrationSection(status))
        #expect(value(section, "Session") == "step 5 of 7, rest at the bottom")
        #expect(value(section, "Plug in again after") != nil)
        #expect(value(section, "Session ends at the latest") != nil)
        #expect(value(section, "Limits") == "your own 90%, CellKeeper's 80% when it started; 100% asked for only in steps 1, 2 and 7")
        #expect(value(section, "Temperature") == "not readable; the owner confirmed a room at 10–35 °C")
        #expect(value(section, "Last calibration") == nil)
    }

    @Test("The report lists §7.9's items: steps with times, before and after, the rest's result, short rests, and the gauge's caveat")
    func report() async throws {
        let rig = CalibrationRig()
        _ = await rig.drive(to: .finalCharge)
        rig.clock.advance(by: 2 * 3600)
        let status = await rig.read(calibrationReading(100, charging: false, full: true))
        let section = try #require(calibrationSection(status))
        let last = try #require(value(section, "Last calibration"))
        #expect(last.hasSuffix("; finished"))
        #expect(value(section, "Steps")?.components(separatedBy: ", ").count == 7)
        #expect(value(section, "Steps done")?.hasPrefix("1 (charge to full), 2 (rest at the top)") == true)
        #expect(value(section, "Before") == "not available", "the rig's readings carry no capacities")
        #expect(value(section, "Rest at the bottom") == "counted: slept 306 minutes on battery power, 18% to 17%")
        #expect(value(section, "Recorded as short") == "none")
        #expect(value(section, "Gauge") == CalibrationWording.gaugeNote)
        // The activity log carries the same report at the end.
        let finished = try #require(status.events.last { $0.kind == .calibration && $0.message.hasPrefix("Calibration finished") })
        #expect(finished.message.contains("Steps done: 1 (charge to full)"))
        #expect(finished.message.contains(CalibrationWording.gaugeNote))
        let text = DiagnosticsReport.text(status: status, environment: environment, generatedAt: rig.clock.now)
        #expect(text.contains("== Calibration"))
        #expect(text.contains("[calibration] Calibration finished."))
    }

    @Test("Capacities are written with their unit and read in words; nothing names the battery or the Mac")
    func capacitiesAndPrivacy() async throws {
        let health = BatteryHealth(cycleCount: 56, fullChargeCapacityMilliampHours: 6150, nominalChargeCapacityMilliampHours: 6302, designCapacityMilliampHours: 6249, condition: "Good")
        var reading = calibrationReading(70)
        reading.health = health
        let rig = CalibrationRig(reading: reading)
        _ = await rig.started()
        rig.clock.advance(by: 61)
        var cancelled = reading
        cancelled.health.cycleCount = 57
        await rig.telemetry.set(cancelled)
        _ = await rig.controller.evaluate(.periodic)
        let status = await rig.controller.cancelCalibration()
        let section = try #require(calibrationSection(status))
        #expect(value(section, "Before") == "full-charge 6150 mAh, nominal 6302 mAh, design 6249 mAh, 56 cycles")
        #expect(value(section, "After") == "full-charge 6150 mAh, nominal 6302 mAh, design 6249 mAh, 57 cycles")
        let spoken = section.rows.first { $0.label == "Before" }?.value.spokenText(formattingTime: { _ in "a time" }, locale: Locale(identifier: "en_US"))
        #expect(spoken == "full-charge 6,150 milliamp-hours, nominal 6,302 milliamp-hours, design 6,249 milliamp-hours, 56 cycles")
        #expect(value(section, "Last calibration")?.hasSuffix("ended early: you cancelled it") == true)
        let text = DiagnosticsReport.text(status: status, environment: environment, generatedAt: rig.clock.now)
        for identifier in ["serial", "Serial", "UUID", status.calibration.last!.id.uuidString] {
            #expect(!text.contains(identifier), "\(identifier)")
        }
    }
}
