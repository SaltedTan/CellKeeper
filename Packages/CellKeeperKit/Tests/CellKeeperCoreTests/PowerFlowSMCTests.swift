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

@MainActor
private final class Toggle {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

/// Counts the pauses that began and ended.
private actor PauseLog {
    private(set) var started = 0
    private(set) var finished = 0

    func began() {
        started += 1
    }

    func ended() {
        finished += 1
    }
}

/// An action run once, from whichever thread fires it first.
private final class Hook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var fired = false

    var hasFired: Bool { lock.withLock { fired } }

    func arm(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { self.action = action }
    }

    func fire() {
        let pending = lock.withLock {
            defer { action = nil }
            if action != nil { fired = true }
            return action
        }
        pending?()
    }
}

/// A display source whose reads are held until the test releases them, as
/// a registry read stuck in flight would be, and at most 10 s (its
/// watchdog, counted), so that no test can hang on one.
private actor HeldSource: PowerFlowReading {
    private(set) var reads = 0
    private(set) var finished = 0
    private(set) var watchdogReleases = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    nonisolated var sourceName: String { "a held source" }
    nonisolated var updateInterval: Duration { .seconds(60) }

    func currentSample() async -> PowerFlowSample {
        reads += 1
        let read = reads
        if !isReleased {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.watchdog()
            }
            await withCheckedContinuation { waiting.append($0) }
        }
        finished += 1
        return fastSample(TimeInterval(read))
    }

    /// Lets every held read return, and later ones at once.
    func release() {
        isReleased = true
        let held = waiting
        waiting = []
        for read in held { read.resume() }
    }

    private func watchdog() {
        guard !waiting.isEmpty else { return }
        watchdogReleases += 1
        release()
    }
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
        _ = await first.value
        #expect(refresher.isShowing)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await smc.current.isShown)
        second.cancel()
        _ = await second.value
        #expect(!refresher.isShowing)
        await eventually { await smc.current.isShown == false }
        #expect(await smc.current.isShown == false)
        // A run started collapsed ends at once by itself; should it not,
        // cancelling it ends it, so a regression fails rather than hangs.
        let collapsedEnded = Toggle(false)
        let collapsed = Task {
            await refresher.run(while: { false }) { ticks.values.append($0) }
            collapsedEnded.value = true
        }
        await eventually { await MainActor.run { collapsedEnded.value } }
        #expect(collapsedEnded.value)
        collapsed.cancel()
        _ = await collapsed.value
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
        #expect(reader.watchdogReleases == 0)
    }

    /// A refresher reading `source`, with an SMC source on `reader`, its
    /// timer and the refresher's both waiting an hour between ticks.
    private func refresher(_ source: HeldSource, _ reader: FakeSMCReader) -> (PowerFlowRefresher, SMCPowerCoordinator) {
        let smc = SMCPowerCoordinator(reader: reader, configuration: SMCPowerSampler.Configuration(), pause: hour)
        return (PowerFlowRefresher(source: source, smc: smc, pause: hour), smc)
    }

    /// Ends a test: quits, lets every held read return, and expects no
    /// watchdog to have been needed.
    private func finish(_ refresher: PowerFlowRefresher, _ source: HeldSource, _ reader: FakeSMCReader) async {
        refresher.stop()
        await source.release()
        reader.releaseAll()
        #expect(await source.watchdogReleases == 0)
        #expect(reader.watchdogReleases == 0)
    }

    @Test("The menu closing with a display read in flight ends the run at once: SMC sampling stops, and the read's later completion delivers and restarts nothing")
    func closeWithReadInFlight() async {
        let source = HeldSource()
        let reader = FakeSMCReader()
        let (refresher, smc) = refresher(source, reader)
        let ticks = Ticks()
        let ended = Toggle(false)
        let run = Task {
            await refresher.run(while: { true }) { ticks.values.append($0) }
            ended.value = true
        }
        await eventually { await source.reads == 1 }
        await eventually { await smc.current.isShown }
        #expect(await smc.current.isShown)
        run.cancel()
        // The run returns while the read is still held.
        await eventually { await MainActor.run { ended.value } }
        #expect(ended.value)
        #expect(await source.finished == 0)
        #expect(!refresher.isShowing)
        await eventually { await smc.current.isShown == false }
        #expect(await smc.current.isShown == false)
        let smcReads = reader.calls
        // The held read completes.
        await source.release()
        await eventually { await source.finished == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ticks.values.isEmpty)
        #expect(await smc.current.isShown == false)
        #expect(!refresher.isShowing)
        #expect(reader.calls == smcReads)
        await finish(refresher, source, reader)
    }

    @Test("Collapsing with a display read in flight ends the run at once, without the caller being cancelled")
    func collapseWithReadInFlight() async {
        let source = HeldSource()
        let reader = FakeSMCReader()
        let (refresher, smc) = refresher(source, reader)
        let ticks = Ticks()
        let expanded = Toggle(true)
        let ended = Toggle(false)
        let run = Task {
            await refresher.run(while: { expanded.value }) { ticks.values.append($0) }
            ended.value = true
        }
        await eventually { await source.reads == 1 }
        await eventually { await smc.current.isShown }
        expanded.value = false
        refresher.endRuns()
        await eventually { await MainActor.run { ended.value } }
        #expect(ended.value)
        #expect(!run.isCancelled)
        #expect(!refresher.isShowing)
        await eventually { await smc.current.isShown == false }
        #expect(await smc.current.isShown == false)
        await source.release()
        await eventually { await source.finished == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ticks.values.isEmpty)
        #expect(await smc.current.isShown == false)
        await finish(refresher, source, reader)
    }

    @Test("Quitting with a display read in flight returns the run at once")
    func quitWithReadInFlight() async {
        let source = HeldSource()
        let reader = FakeSMCReader()
        let (refresher, smc) = refresher(source, reader)
        let ticks = Ticks()
        let ended = Toggle(false)
        _ = Task {
            await refresher.run(while: { true }) { ticks.values.append($0) }
            ended.value = true
        }
        await eventually { await source.reads == 1 }
        refresher.stop()
        await eventually { await MainActor.run { ended.value } }
        #expect(ended.value)
        #expect(await source.finished == 0)
        await eventually { await smc.isStopped }
        #expect(await smc.isStopped)
        await finish(refresher, source, reader)
        #expect(ticks.values.isEmpty)
    }

    @Test("Ending the runs cancels each run's task: a pause between reads ends at once")
    func endRunsCancelsTheTask() async {
        let pauses = PauseLog()
        let refresher = PowerFlowRefresher(source: ImmediateSource(), pause: { _ in
            await pauses.began()
            try? await Task.sleep(for: .seconds(3_600))
            await pauses.ended()
        })
        let ticks = Ticks()
        let run = Task { await refresher.run(while: { true }) { ticks.values.append($0) } }
        await eventually { await pauses.started == 1 }
        refresher.endRuns()
        await eventually { await pauses.finished == 1 }
        #expect(await pauses.finished == 1)
        _ = await run.value
        #expect(ticks.values.count == 1)
        refresher.stop()
    }

    @Test("A tick read before its run ended and delivered after is dropped")
    func tickOfEndedRun() async {
        let hook = Hook()
        // The tick's moment is taken after its read and before it reaches
        // the main actor: the run ends right there, once.
        let refresher = PowerFlowRefresher(source: ImmediateSource(), pause: hour, now: {
            hook.fire()
            return ContinuousClock.now
        })
        hook.arm {
            if Thread.isMainThread {
                MainActor.assumeIsolated { refresher.endRuns() }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { refresher.endRuns() } }
            }
        }
        let ticks = Ticks()
        let ended = Toggle(false)
        let run = Task {
            await refresher.run(while: { true }) { ticks.values.append($0) }
            ended.value = true
        }
        await eventually { hook.hasFired }
        await eventually { await MainActor.run { ended.value } }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(hook.hasFired)
        #expect(ticks.values.isEmpty)
        run.cancel()
        refresher.stop()
    }

    @Test("A run started while an ended run's read is still in flight shares that read, gets its sample, and shows the SMC source again")
    func reopenWhileReadInFlight() async {
        let source = HeldSource()
        let reader = FakeSMCReader()
        let (refresher, smc) = refresher(source, reader)
        let ticks = Ticks()
        let first = Task { await refresher.run(while: { true }) { ticks.values.append($0) } }
        await eventually { await source.reads == 1 }
        first.cancel()
        _ = await first.value
        await eventually { await smc.current.isShown == false }
        // The menu is opened again before the old read returns.
        let second = Task { await refresher.run(while: { true }) { ticks.values.append($0) } }
        await eventually { await refresher.source.waitingReads == 1 }
        #expect(await source.reads == 1)
        await eventually { await smc.current.isShown }
        #expect(refresher.isShowing)
        await source.release()
        await eventually { await MainActor.run { ticks.values.count == 1 } }
        #expect(ticks.values.map(\.content.kind) == ["registry"])
        #expect(await source.reads == 1)
        second.cancel()
        _ = await second.value
        #expect(!refresher.isShowing)
        await finish(refresher, source, reader)
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
        #expect(section.rows.map { $0.value.plainText(formattingTime: { _ in "" }) } == ["macOS's battery data", "absent (not in this build)"])
        let text = DiagnosticsReport.text(status: status, environment: environment, powerFlow: absent, generatedAt: referenceDate)
        #expect(text.contains("== Power flow\nShown from: macOS's battery data\nSMC source: absent (not in this build) (absent)\n"))
        #expect(!text.contains("SMC reader"))

        // In a build with the reader, the app's line, written as given.
        let line = ["SMC reader", "compiled in"].joined(separator: ": ")
        let compiled = PowerFlowDiagnostics(smcState: .backingOff, shown: .registry, registrySourceName: "macOS's battery data", readerLine: line)
        let withReader = try #require(DiagnosticsReport.sections(status: status, environment: environment, powerFlow: compiled).last)
        #expect(withReader.rows.map(\.label) == ["Shown from", "SMC source", "SMC reader"])
        #expect(withReader.rows.last?.value.plainText(formattingTime: { _ in "" }) == "compiled in")
        #expect(DiagnosticsReport.text(status: status, environment: environment, powerFlow: compiled, generatedAt: referenceDate).contains("\n\(line)\n"))
    }

    @Test("Every state reads in words")
    func states() {
        #expect(SMCSourceState.allCases.map(\.description) == ["absent (not in this build)", "probing", "available", "failing", "backing off"])
    }
}
