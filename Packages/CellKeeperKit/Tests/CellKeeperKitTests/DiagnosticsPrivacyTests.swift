import CellKeeperCore
import CellKeeperKit
import Foundation
import Testing

@Suite("Diagnostics privacy")
struct DiagnosticsPrivacyTests {
    struct FixedTelemetry: TelemetryProvider {
        let snapshot: BatterySnapshot
        func currentSnapshot() async throws -> BatterySnapshot { snapshot }
        func powerSourceChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    }

    @Test("Identifiers in the raw power data never reach a diagnostics report")
    func noIdentifiers() async {
        // The shapes CellKeeper reads, plus the identifying keys macOS also
        // publishes, with values that are easy to search for.
        let raw = RawPowerData(
            powerSource: [
                "Type": "InternalBattery", "Is Present": true, "Power Source State": "AC Power",
                "Current Capacity": 78, "Max Capacity": 100, "Is Charging": true, "Is Charged": false,
                "Hardware Serial Number": "SECRET-POWER-SOURCE-SERIAL", "Power Source ID": 987_654_321,
                "Name": "SECRET-POWER-SOURCE-NAME",
            ],
            providingPowerSourceType: "AC Power",
            registry: [
                "BatteryInstalled": true, "ExternalConnected": true, "CycleCount": 54, "Voltage": 12_427,
                "Serial": "SECRET-REGISTRY-SERIAL", "BatterySerialNumber": "SECRET-BATTERY-SERIAL",
                "BatteryData": ["FullChargeCapacity": 6131, "DesignCapacity": 6249, "Serial": "SECRET-BATTERY-DATA-SERIAL"],
            ],
            adapter: ["Watts": 70, "SerialString": "SECRET-ADAPTER-SERIAL", "AdapterID": 876_543_219]
        )
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: Date())
        let controller = ChargeController(telemetry: FixedTelemetry(snapshot: snapshot), backend: MockChargingBackend(), settings: .default)
        let status = await controller.evaluate(.launch)
        let environment = DiagnosticsEnvironment(appVersion: "0.1.0 (1)", systemVersion: "Version 27.0.1 (Build 26A434)", modelIdentifier: "Mac16,1")
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: Date())

        #expect(report.contains("Charge: 78%"))
        #expect(report.contains("Cycle count: 54"))
        #expect(!report.contains("SECRET"))
        #expect(!report.contains("987654321"))
        #expect(!report.contains("876543219"))
    }
}

@Suite("Diagnostics environment")
struct DiagnosticsEnvironmentTests {
    @Test("The model identifier is a model name, not a serial number")
    func modelIdentifier() throws {
        let model = try #require(DiagnosticsEnvironment.current().modelIdentifier)
        // For example "Mac16,1", "MacBookPro18,3" or "VirtualMac2,1".
        #expect(model.wholeMatch(of: /[A-Za-z]+[0-9]+,[0-9]+/) != nil)
    }

    @Test("The macOS version is reported")
    func systemVersion() {
        #expect(DiagnosticsEnvironment.current().systemVersion.contains("Version"))
    }
}
