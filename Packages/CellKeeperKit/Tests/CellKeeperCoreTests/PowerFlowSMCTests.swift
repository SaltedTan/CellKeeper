@testable import CellKeeperCore
import Foundation
import Testing

/// A source whose reads always succeed at once.
private struct ImmediateSource: PowerFlowReading {
    var sourceName: String { "an immediate source" }
    var updateInterval: Duration { .seconds(60) }

    func currentSample() -> PowerFlowSample {
        fastSample(0)
    }
}

@MainActor
private final class Ticks {
    var values: [PowerFlowTick] = []
}

@Suite("Power flow with the SMC source")
@MainActor
struct PowerFlowSMCTests {
    private let hour: @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3_600)) }

    @Test("The SMC source counts as shown while a run reads, through overlapping runs, and is hidden when the last ends; a collapsed run never shows it")
    func shownWhileReading() async {
        let reader = FakeSMCReader()
        let smc = SMCPowerCoordinator(reader: reader, configuration: SMCPowerSampler.Configuration(), pause: hour)
        let refresher = PowerFlowRefresher(source: ImmediateSource(), smc: smc, pause: hour)
        let ticks = Ticks()
        let first = Task { await refresher.run(while: { true }) { ticks.values.append($0) } }
        await eventually { await smc.current.isShown }
        #expect(await smc.current.isShown)
        #expect(refresher.isShowing)
        let second = Task { await refresher.run(while: { true }) { ticks.values.append($0) } }
        await eventually { await MainActor.run { refresher.readingRuns == 2 } }
        first.cancel()
        await first.value
        #expect(refresher.isShowing)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await smc.current.isShown)
        second.cancel()
        await second.value
        #expect(!refresher.isShowing)
        await eventually { await smc.current.isShown == false }
        #expect(await smc.current.isShown == false)
        await refresher.run(while: { false }) { ticks.values.append($0) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await smc.current.isShown == false)
        // Every tick carried the source's state.
        #expect(!ticks.values.isEmpty)
        #expect(ticks.values.allSatisfy { $0.smcState == .probing })
        // Quitting stops the source too.
        refresher.stop()
        await eventually { await smc.isStopped }
        #expect(await smc.isStopped)
        reader.releaseAll()
    }

    @Test("The controller, the policy and the calibration never receive the power flow's values: no file of theirs names them")
    func displayOnly() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CellKeeperCore")
        let names = ["SMCPower", "SMCRaw", "SMCSource", "SMCKey", "SMCOpen", "PowerFlowState", "PowerFlowTick", "PowerFlowSample", "PowerFlowRefresh", "PowerFlowProvenance"]
        let files = try #require(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)?.allObjects as? [URL])
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Telemetry/") }
        let checked = files.map(\.lastPathComponent)
        #expect(checked.contains("ChargeController.swift"))
        #expect(checked.contains("CalibrationRunner.swift"))
        #expect(checked.contains("ChargingPolicy.swift"))
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in names {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
    }
}

@Suite("Power flow SMC wording and diagnostics")
struct PowerFlowSMCWordingTests {
    @Test("Spans are read in words")
    func seconds() {
        #expect(PowerFlowWording.seconds(.seconds(1)) == "1 second")
        #expect(PowerFlowWording.seconds(.seconds(3)) == "3 seconds")
    }

    @Test("The diagnostics name where the flow on screen comes from, never a value")
    func diagnosticsSource() {
        let name = "macOS's battery data"
        #expect(PowerFlowWording.diagnosticsSource(nil, registrySourceName: name) == "none")
        #expect(PowerFlowWording.diagnosticsSource(.registry, registrySourceName: name) == "macOS's battery data")
        #expect(PowerFlowWording.diagnosticsSource(PowerFlowProvenance(system: .smc(averagedOver: .seconds(3)), battery: .registry), registrySourceName: name)
            == "the SMC, averaged over 3 seconds (adapter and Mac); macOS's battery data (battery)")
        #expect(PowerFlowWording.diagnosticsSource(PowerFlowProvenance(system: .smc(averagedOver: .seconds(2)), battery: .smc), registrySourceName: name)
            == "the SMC, averaged over 2 seconds")
    }

    @Test("The report's Power flow section: the source shown and the SMC source's state, and the reader's line only when the app gives it")
    func diagnosticsSection() async throws {
        let status = await DiagnosticsFixture.simulated()
        let environment = DiagnosticsFixture.environment
        #expect(!DiagnosticsReport.sections(status: status, environment: environment).contains { $0.title == "Power flow" })
        let absent = PowerFlowDiagnostics(smcState: .absent, shown: .registry, registrySourceName: "macOS's battery data", readerLine: nil)
        let section = try #require(DiagnosticsReport.sections(status: status, environment: environment, powerFlow: absent).last)
        #expect(section.title == "Power flow")
        #expect(section.rows.map(\.label) == ["Shown from", "SMC source"])
        #expect(section.rows.map(\.value.reportText) == ["macOS's battery data", "absent (not in this build) (absent)"])
        #expect(section.rows.map { $0.value.plainText { _ in "" } } == ["macOS's battery data", "absent (not in this build)"])
        let text = DiagnosticsReport.text(status: status, environment: environment, powerFlow: absent, generatedAt: referenceDate)
        #expect(text.contains("== Power flow\nShown from: macOS's battery data\nSMC source: absent (not in this build) (absent)\n"))
        #expect(!text.contains("SMC reader"))

        // In a build with the reader, the app's line, written as given.
        let line = ["SMC reader", "compiled in"].joined(separator: ": ")
        let compiled = PowerFlowDiagnostics(smcState: .backingOff, shown: .registry, registrySourceName: "macOS's battery data", readerLine: line)
        let withReader = try #require(DiagnosticsReport.sections(status: status, environment: environment, powerFlow: compiled).last)
        #expect(withReader.rows.map(\.label) == ["Shown from", "SMC source", "SMC reader"])
        #expect(withReader.rows.last?.value.plainText { _ in "" } == "compiled in")
        #expect(DiagnosticsReport.text(status: status, environment: environment, powerFlow: compiled, generatedAt: referenceDate).contains("\n\(line)\n"))
    }

    @Test("Every state reads in words")
    func states() {
        #expect(SMCSourceState.allCases.map(\.description) == ["absent (not in this build)", "probing", "available", "failing", "backing off"])
    }
}
