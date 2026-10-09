import CellKeeperCore
import Foundation

let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

func snapshot(
    percent: Int?,
    source: PowerSource = .externalPower,
    charging: Bool? = nil,
    fullyCharged: Bool? = false,
    temperature: Double? = 30,
    at timestamp: Date = referenceDate,
    sourceTimestamp: Date? = nil,
    present: Bool = true
) -> BatterySnapshot {
    BatterySnapshot(
        timestamp: timestamp,
        sourceTimestamp: sourceTimestamp,
        isBatteryPresent: present,
        chargePercent: percent,
        powerSource: source,
        isCharging: charging ?? (source == .externalPower),
        isFullyCharged: fullyCharged,
        temperatureCelsius: temperature
    )
}

let simulatedCapabilities = ControlCapabilities(availability: .simulated, supportedModes: ChargeControlMode.chargingModes)

func input(
    _ snapshot: BatterySnapshot?,
    settings: ChargingSettings = .default,
    override: ChargeOverride? = nil,
    capabilities: ControlCapabilities = simulatedCapabilities,
    currentMode: ChargeControlMode? = .normal,
    memory: PolicyMemory = PolicyMemory(),
    faulted: Bool = false,
    recentRestrictingRequests: [TimeInterval] = [],
    sleepImminent: Bool = false,
    restoreRetryNotBefore: TimeInterval? = nil,
    now: Date = referenceDate,
    uptime: TimeInterval = 10_000
) -> PolicyInput {
    PolicyInput(
        now: now,
        uptime: uptime,
        settings: settings,
        snapshot: snapshot,
        activeOverride: override,
        capabilities: capabilities,
        currentMode: currentMode,
        memory: memory,
        isBackendFaulted: faulted,
        recentRestrictingRequests: recentRestrictingRequests,
        isSleepImminent: sleepImminent,
        restoreRetryNotBefore: restoreRetryNotBefore
    )
}

/// The policy memory after one earlier reading of `percent`, a minute before
/// `referenceDate`. A reading at or above the limit at `referenceDate` is
/// then the second in a row, so it confirms the limit (rule R14).
func memoryAfterReading(_ percent: Int, settings: ChargingSettings = .default, memory: PolicyMemory = PolicyMemory()) -> PolicyMemory {
    let earlier = referenceDate.addingTimeInterval(-60)
    let reading = snapshot(percent: percent, at: earlier)
    return ChargingPolicy.evaluate(input(reading, settings: settings, memory: memory, now: earlier, uptime: 10_000 - 60)).memory
}

/// A telemetry provider whose readings are set by the test. When given a
/// clock, readings are stamped with the clock's time, like real telemetry.
actor StubTelemetry: TelemetryProvider {
    private var next: Result<BatterySnapshot, any Error>
    private let clock: TestClock?

    init(_ snapshot: BatterySnapshot, clock: TestClock? = nil) {
        next = .success(snapshot)
        self.clock = clock
    }

    func set(_ snapshot: BatterySnapshot) {
        next = .success(snapshot)
    }

    func fail(with error: any Error) {
        next = .failure(error)
    }

    func currentSnapshot() throws -> BatterySnapshot {
        var reading = try next.get()
        if let clock { reading.timestamp = clock.now }
        return reading
    }

    nonisolated func powerSourceChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

struct TelemetryTestError: Error, CustomStringConvertible {
    var description: String { "test telemetry failure" }
}

/// A mutable clock for controller tests: wall time plus a monotonic uptime
/// that advance together.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var elapsed: TimeInterval = 0

    init(_ start: Date = referenceDate) {
        self.start = start
    }

    var now: Date {
        lock.withLock { start.addingTimeInterval(elapsed) }
    }

    var uptime: TimeInterval {
        lock.withLock { 10_000 + elapsed }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { elapsed += interval }
    }
}

/// In-memory ``KeyValueStorage`` so tests never write to ~/Library/Preferences.
/// Thread-safe, so a backend, the test, and a second backend (simulating a
/// relaunch) can share it.
final class InMemoryStorage: KeyValueStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] as? Data }
    }

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] as? String }
    }

    func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}
