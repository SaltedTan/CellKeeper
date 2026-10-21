import CellKeeperCore
import Foundation
import Testing

/// A telemetry provider that counts its reads and gives the next reading
/// from a list (failing for nil), the last one again once the list is
/// used up. It can cancel the task reading it, as a menu closing would.
private actor ScriptedTelemetry: TelemetryProvider {
    private var readings: [BatterySnapshot?]
    private(set) var reads = 0
    private let cancelsOnRead: Int?

    init(_ readings: [BatterySnapshot?], cancelsOnRead: Int? = nil) {
        self.readings = readings
        self.cancelsOnRead = cancelsOnRead
    }

    func currentSnapshot() throws -> BatterySnapshot {
        reads += 1
        if reads == cancelsOnRead {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let next = readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
        guard let next else { throw TelemetryTestError() }
        return next
    }

    nonisolated func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// A faster source than macOS's battery data, as one could later take its
/// place: a new update at every read, a second apart.
private actor FastSource: PowerFlowReading {
    private var second: TimeInterval = 0

    nonisolated var sourceName: String { "a fast source" }
    nonisolated var updateInterval: Duration { .seconds(1) }

    func currentSample() -> PowerFlowSample {
        defer { second += 1 }
        return fastSample(second, load: 20 + second)
    }
}

/// The pauses the refresh asked for; cancels the task after `limit`.
private actor Pauses {
    private(set) var durations: [Duration] = []
    private let limit: Int

    init(cancellingAfter limit: Int) {
        self.limit = limit
    }

    func pause(_ duration: Duration) {
        durations.append(duration)
        if durations.count >= limit {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}

/// The menu's Power flow section, expanded until it is collapsed after a
/// number of pauses. Should reads go on regardless, it cancels the task a
/// few pauses later, so that the test fails rather than hangs.
@MainActor
private final class Section {
    var isExpanded = true
    private(set) var pauses = 0

    func paused(collapsingAfter count: Int) {
        pauses += 1
        if pauses >= count { isExpanded = false }
        if pauses >= count + 3 { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

@MainActor
private final class Deliveries {
    var ticks: [PowerFlowTick] = []
    var state = PowerFlowState()

    /// The ticks' display reads.
    var samples: [PowerFlowSample] {
        ticks.compactMap(\.registrySample)
    }
}

@Suite("Power flow refresh")
@MainActor
struct PowerFlowRefreshTests {
    private func reading(_ seconds: TimeInterval) -> BatterySnapshot {
        powerSnapshot(update: referenceDate.addingTimeInterval(seconds))
    }

    private func times(_ seconds: [TimeInterval]) -> [Date?] {
        seconds.map { referenceDate.addingTimeInterval($0) }
    }

    /// Runs the refresh in a task of its own, which the fakes cancel as the
    /// menu closing would, leaving the test's task alone.
    private func refresh(
        _ source: any PowerFlowReading,
        interval: Duration = PowerFlowRefresh.interval,
        while isWanted: @escaping @MainActor @Sendable () -> Bool = { true },
        smc: (any SMCPowerPublishing)? = nil,
        pauses: Pauses,
        deliver: @escaping @MainActor @Sendable (PowerFlowTick) -> Void
    ) async {
        await Task { @MainActor in
            await PowerFlowRefresh.run(source: source, smc: smc, interval: interval, while: isWanted, pause: { await pauses.pause($0) }, deliver: deliver)
        }.value
    }

    @Test("Reads at once and every 3 s, delivering each sample, until the task is cancelled")
    func readsUntilCancelled() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(0), reading(60)])
        let pauses = Pauses(cancellingAfter: 3)
        let deliveries = Deliveries()
        await refresh(BatteryDataPowerFlowReading(telemetry: telemetry), pauses: pauses) { deliveries.ticks.append($0) }
        #expect(await telemetry.reads == 3)
        #expect(await pauses.durations == [.seconds(3), .seconds(3), .seconds(3)])
        #expect(deliveries.samples.map(\.updatedAt) == times([0, 0, 60]))
        #expect(PowerFlowRefresh.interval == .seconds(3))
    }

    @Test("A failed read delivers an empty tick, not silence, and the next read is made")
    func emptyTicks() async {
        let telemetry = ScriptedTelemetry([nil, nil, reading(60)])
        let pauses = Pauses(cancellingAfter: 3)
        let deliveries = Deliveries()
        await refresh(BatteryDataPowerFlowReading(telemetry: telemetry), interval: .seconds(2), pauses: pauses) { deliveries.ticks.append($0) }
        #expect(await telemetry.reads == 3)
        #expect(await pauses.durations == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(deliveries.ticks.count == 3)
        #expect(deliveries.ticks.prefix(2).allSatisfy { $0.content == .empty && $0.smcState == .absent })
        #expect(deliveries.samples.map(\.updatedAt) == times([60]))
    }

    @Test("Nothing is read once the task is cancelled")
    func cancelledBeforeStart() async {
        let telemetry = ScriptedTelemetry([reading(0)])
        let deliveries = Deliveries()
        let task = Task { @MainActor in
            await PowerFlowRefresh.run(source: BatteryDataPowerFlowReading(telemetry: telemetry), while: { true }, pause: { _ in }) { deliveries.ticks.append($0) }
        }
        task.cancel()
        await task.value
        #expect(await telemetry.reads == 0)
        #expect(deliveries.samples.isEmpty)
    }

    @Test("Nothing is read while the section is collapsed")
    func collapsed() async {
        let telemetry = ScriptedTelemetry([reading(0)])
        let pauses = Pauses(cancellingAfter: 10)
        let deliveries = Deliveries()
        await refresh(BatteryDataPowerFlowReading(telemetry: telemetry), while: { false }, pauses: pauses) { deliveries.ticks.append($0) }
        #expect(await telemetry.reads == 0)
        #expect(await pauses.durations.isEmpty)
        #expect(deliveries.samples.isEmpty)
    }

    @Test("Reads stop when the section collapses, without the task being cancelled")
    func stopsWhenCollapsed() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(60)])
        let section = Section()
        let deliveries = Deliveries()
        // Collapsed during the second pause; never cancelled.
        await Task { @MainActor in
            await PowerFlowRefresh.run(
                source: BatteryDataPowerFlowReading(telemetry: telemetry),
                while: { section.isExpanded },
                pause: { _ in await section.paused(collapsingAfter: 2) }
            ) { deliveries.ticks.append($0) }
        }.value
        #expect(await telemetry.reads == 2)
        #expect(section.pauses == 2)
        #expect(deliveries.samples.map(\.updatedAt) == times([0, 60]))
    }

    @Test("A read that ends after the task was cancelled is not delivered")
    func readEndingAfterCancellation() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(60)], cancelsOnRead: 2)
        let pauses = Pauses(cancellingAfter: 10)
        let deliveries = Deliveries()
        await refresh(BatteryDataPowerFlowReading(telemetry: telemetry), pauses: pauses) { deliveries.ticks.append($0) }
        #expect(await telemetry.reads == 2)
        #expect(await pauses.durations.count == 1)
        #expect(deliveries.samples.map(\.updatedAt) == times([0]))
    }

    @Test("Delivered samples feed the power flow, one point per update")
    func feedsState() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(0), reading(60)])
        let pauses = Pauses(cancellingAfter: 3)
        let deliveries = Deliveries()
        await refresh(BatteryDataPowerFlowReading(telemetry: telemetry), pauses: pauses) { deliveries.state.take($0) }
        #expect(deliveries.state.history.points.count == 2)
        #expect(deliveries.state.flow?.macUseWatts == 30)
    }

    @Test("Another source takes the place of macOS's battery data unchanged, and its history is averaged per 10 s")
    func pluggableSource() async {
        let source = FastSource()
        let pauses = Pauses(cancellingAfter: 25)
        let deliveries = Deliveries()
        await refresh(source, pauses: pauses) { deliveries.state.take($0) }
        // 25 updates, a second apart (0 to 24 s): three buckets.
        #expect(deliveries.state.history.points.map(\.updates) == [10, 10, 5])
        #expect(deliveries.state.flow?.macUseWatts == 44)
        #expect(source.footnote == "From a fast source, updated about every second.")
    }

    @Test("With the SMC source available and a window, the tick carries it and the source is not read; otherwise the source is read")
    func smcWindows() async {
        let window = smcWindow(began: 0)
        let smc = ScriptedPublications([
            SMCPowerPublication(state: .available, window: window),
            SMCPowerPublication(state: .available, window: nil),
            SMCPowerPublication(state: .failing, window: nil),
            // Defensive: a window is used only while the source is available.
            SMCPowerPublication(state: .probing, window: window),
        ])
        let telemetry = ScriptedTelemetry([reading(0), nil, reading(60)])
        let pauses = Pauses(cancellingAfter: 4)
        let deliveries = Deliveries()
        await refresh(BatteryDataPowerFlowReading(telemetry: telemetry), smc: smc, pauses: pauses) { deliveries.ticks.append($0) }
        #expect(deliveries.ticks.map(\.content.kind) == ["window", "registry", "empty", "registry"])
        #expect(deliveries.ticks.first?.content == .window(window))
        #expect(deliveries.ticks.map(\.smcState) == [.available, .available, .failing, .probing])
        #expect(await telemetry.reads == 3)
        #expect(await smc.calls == 4)
        #expect(deliveries.samples.map(\.updatedAt) == times([0, 60]))
    }
}

/// An SMC source that hands out the publications given, then nothing new
/// while failing.
private actor ScriptedPublications: SMCPowerPublishing {
    private var publications: [SMCPowerPublication]
    private(set) var calls = 0

    init(_ publications: [SMCPowerPublication]) {
        self.publications = publications
    }

    func publish() -> SMCPowerPublication {
        calls += 1
        return publications.isEmpty ? SMCPowerPublication(state: .failing, window: nil) : publications.removeFirst()
    }
}

@Suite("Power flow sources")
struct PowerFlowReadingTests {
    @Test("macOS's battery data: its registry values, updated about once a minute")
    func batteryData() async throws {
        let telemetry = StubTelemetry(powerSnapshot(powerIn: 37_304, load: 17_363, voltage: 12_000, current: -500))
        let source = BatteryDataPowerFlowReading(telemetry: telemetry)
        #expect(source.updateInterval == .seconds(60))
        #expect(source.footnote == "From macOS's battery data, updated about once a minute.")
        let sample = try await source.currentSample()
        #expect(sample == PowerFlowSample(
            updatedAt: referenceDate, powerSource: .externalPower, adapterRatingWatts: 68, chargePercent: 81,
            systemPowerInWatts: 37.304, systemLoadWatts: 17.363, batteryWatts: -6
        ))
    }

    @Test("A failed telemetry read fails the sample")
    func failure() async {
        let telemetry = StubTelemetry(powerSnapshot())
        await telemetry.fail(with: TelemetryTestError())
        let source = BatteryDataPowerFlowReading(telemetry: telemetry)
        await #expect(throws: TelemetryTestError.self) { try await source.currentSample() }
    }
}
