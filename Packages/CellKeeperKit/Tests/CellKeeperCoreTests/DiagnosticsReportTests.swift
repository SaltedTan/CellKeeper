import CellKeeperCore
import Foundation
import Testing

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    let clock = TestClock()
    let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1 (Build 26A434)", modelIdentifier: "Mac16,1")

    @Test("The report names the app, macOS and model, and every section")
    func header() async {
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        let lines = report.split(separator: "\n").map(String.init)
        #expect(lines.first == "CellKeeper diagnostics")
        #expect(lines.contains("Generated: \(referenceDate.formatted(.iso8601))"))
        #expect(lines.contains("App: 0.1.0 (1)"))
        #expect(lines.contains("macOS: Version 27.0.1 (Build 26A434)"))
        #expect(lines.contains("Model: Mac16,1"))
        for title in ["Control", "Settings", "Battery", "Decision", "Activity (oldest first)"] {
            #expect(lines.contains("== \(title)"))
        }
        #expect(!lines.contains("== macOS Charge Limit"))
    }

    @Test("The report shows the backend, settings, battery, decision and activity")
    func content() async {
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        #expect(report.contains("Backend: Simulated (simulated)"))
        #expect(report.contains("Availability: simulated"))
        #expect(report.contains("Charge limit: 80%"))
        #expect(report.contains("Resume threshold: 75%"))
        #expect(report.contains("Charge: 78%"))
        #expect(report.contains("Power source: externalPower"))
        #expect(report.contains("State: charging"))
        #expect(report.contains("Reason: Charging from 78% toward the 80% limit."))
        // Every activity event appears, in order.
        let activity = report.components(separatedBy: "== Activity (oldest first)\n")[1]
        let messages = status.events.map(\.message)
        #expect(!messages.isEmpty)
        var searchStart = activity.startIndex
        for message in messages {
            guard let range = activity.range(of: message, range: searchStart..<activity.endIndex) else {
                Issue.record("missing or out of order: \(message)")
                return
            }
            searchStart = range.upperBound
        }
    }

    @Test("Missing telemetry and an unknown model are stated, not omitted")
    func missingValues() async {
        let telemetry = StubTelemetry(snapshot(percent: 78), clock: clock)
        await telemetry.fail(with: TelemetryTestError())
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        var unknownModel = environment
        unknownModel.modelIdentifier = nil
        let report = DiagnosticsReport.text(status: status, environment: unknownModel, generatedAt: referenceDate)
        #expect(report.contains("Model: unknown"))
        #expect(report.contains("Telemetry: unavailable: test telemetry failure"))
        #expect(report.contains("State: failSafe"))
    }

    @Test("With macOS's Charge Limit, the report shows what macOS reports and the recorded limit")
    func nativeLimit() async throws {
        let system = FakeChargeLimitSystem(reading: .limit(80))
        let store = InMemoryRecordStore()
        let backend = makeNativeBackend(system: system, store: store, clock: clock)
        let telemetry = StubTelemetry(snapshot(percent: 78, charging: true), clock: clock)
        var settings = ChargingSettings.default
        settings = settings.withChargeLimit(85)
        let controller = ChargeController(telemetry: telemetry, backend: backend, settings: settings, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(.launch)
        #expect(status.nativeLimit?.ownerLimit == 80)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)

        #expect(report.contains("== macOS Charge Limit"))
        #expect(report.contains("Availability: experimental"))
        #expect(report.contains("Style: macOS Charge Limit, steps 80, 85, 90, 95, 100"))
        #expect(report.contains("Reported by macOS: 85%"))
        #expect(report.contains("Own limit: 80% recorded"))
        #expect(report.contains("CellKeeper's limit: 85%"))
        #expect(report.contains("Shortcut found: yes"))
        #expect(report.contains("Flags: none"))
    }
}
