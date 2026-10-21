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

@MainActor
private final class Deliveries {
    var snapshots: [BatterySnapshot] = []
}

@Suite("Power flow refresh")
@MainActor
struct PowerFlowRefreshTests {
    private func reading(_ seconds: TimeInterval) -> BatterySnapshot {
        powerSnapshot(update: referenceDate.addingTimeInterval(seconds))
    }

    /// Runs the refresh in a task of its own, which the fakes cancel as the
    /// menu closing would, leaving the test's task alone.
    private func refresh(
        _ telemetry: ScriptedTelemetry,
        interval: Duration = PowerFlowRefresh.interval,
        pauses: Pauses,
        deliver: @escaping @MainActor @Sendable (BatterySnapshot) -> Void
    ) async {
        await Task { @MainActor in
            await PowerFlowRefresh.run(telemetry: telemetry, interval: interval, pause: { await pauses.pause($0) }, deliver: deliver)
        }.value
    }

    @Test("Reads at once and after every pause, delivering each reading, until the task is cancelled")
    func readsUntilCancelled() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(0), reading(60)])
        let pauses = Pauses(cancellingAfter: 3)
        let deliveries = Deliveries()
        await refresh(telemetry, pauses: pauses) { deliveries.snapshots.append($0) }
        #expect(await telemetry.reads == 3)
        #expect(await pauses.durations == [.seconds(5), .seconds(5), .seconds(5)])
        #expect(deliveries.snapshots.map(\.sourceTimestamp) == [0, 0, 60].map { referenceDate.addingTimeInterval($0) })
        #expect(PowerFlowRefresh.interval == .seconds(5))
    }

    @Test("A failed read is skipped and the next one is made")
    func skipsFailures() async {
        let telemetry = ScriptedTelemetry([nil, nil, reading(60)])
        let pauses = Pauses(cancellingAfter: 3)
        let deliveries = Deliveries()
        await refresh(telemetry, interval: .seconds(2), pauses: pauses) { deliveries.snapshots.append($0) }
        #expect(await telemetry.reads == 3)
        #expect(await pauses.durations == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(deliveries.snapshots.map(\.sourceTimestamp) == [referenceDate.addingTimeInterval(60)])
    }

    @Test("Nothing is read once the task is cancelled")
    func cancelledBeforeStart() async {
        let telemetry = ScriptedTelemetry([reading(0)])
        let deliveries = Deliveries()
        let task = Task { @MainActor in
            await PowerFlowRefresh.run(telemetry: telemetry, pause: { _ in }) { deliveries.snapshots.append($0) }
        }
        task.cancel()
        await task.value
        #expect(await telemetry.reads == 0)
        #expect(deliveries.snapshots.isEmpty)
    }

    @Test("A read that ends after the task was cancelled is not delivered")
    func readEndingAfterCancellation() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(60)], cancelsOnRead: 2)
        let pauses = Pauses(cancellingAfter: 10)
        let deliveries = Deliveries()
        await refresh(telemetry, pauses: pauses) { deliveries.snapshots.append($0) }
        #expect(await telemetry.reads == 2)
        #expect(await pauses.durations.count == 1)
        #expect(deliveries.snapshots.map(\.sourceTimestamp) == [referenceDate])
    }

    @Test("Delivered readings feed the power flow without touching anything else")
    func feedsReadings() async {
        let telemetry = ScriptedTelemetry([reading(0), reading(0), reading(60)])
        let pauses = Pauses(cancellingAfter: 3)
        let box = ReadingsBox()
        await refresh(telemetry, pauses: pauses) { box.readings.take($0) }
        #expect(box.readings.history.points.count == 2)
        #expect(box.readings.flow?.macUseWatts == 30)
    }
}

@MainActor
private final class ReadingsBox {
    var readings = PowerFlowReadings()
}
