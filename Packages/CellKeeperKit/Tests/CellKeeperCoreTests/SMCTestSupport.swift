@testable import CellKeeperCore
import Foundation

// Test doubles for the SMC source. Nothing here talks to the SMC: the fake
// reader conforms to CellKeeper's own protocol and returns the values a test
// gives it.

/// A raw `flt ` value: `watts` as an IEEE-754 single, low byte first.
func rawFloat(_ watts: Float, type: String = "flt ") -> SMCRawValue {
    SMCRawValue(type: type, bytes: littleEndian(watts.bitPattern))
}

/// A raw `si32` value: `milliwatts`, low byte first.
func rawInt32(_ milliwatts: Int32, type: String = "si32") -> SMCRawValue {
    SMCRawValue(type: type, bytes: littleEndian(UInt32(bitPattern: milliwatts)))
}

private func littleEndian(_ bits: UInt32) -> [UInt8] {
    [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
}

/// A read's values: each key given is read, each nil one failed.
func smcValues(macUse: Float? = 20, adapterInput: Float? = 30, battery: Int32? = nil) -> [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>] {
    func value(_ raw: SMCRawValue?, missing: SMCKeyReadError) -> Result<SMCRawValue, SMCKeyReadError> {
        guard let raw else { return .failure(missing) }
        return .success(raw)
    }
    return [
        .systemTotalPower: value(macUse.map { rawFloat($0) }, missing: .readFailed),
        .adapterInputPower: value(adapterInput.map { rawFloat($0) }, missing: .readFailed),
        .batteryPower: value(battery.map { rawInt32($0) }, missing: .notFound),
    ]
}

extension PowerFlowTick {
    /// The tick's display read, if it carries one.
    var registrySample: PowerFlowSample? {
        guard case .registry(let sample) = content else { return nil }
        return sample
    }
}

/// A window whose first batch began `began` seconds after
/// ``readClockOrigin`` and whose last returned `span` seconds later.
func smcWindow(
    began: Double,
    span: Double = 3,
    collected: TimeInterval? = nil,
    batches: Int = 3,
    macUse: Double = 20,
    adapterInput: Double? = 30,
    battery: Double? = nil
) -> SMCPowerWindow {
    SMCPowerWindow(
        firstBatchBegan: readInstant(began),
        lastBatchReturned: readInstant(began + span),
        collectedAt: referenceDate.addingTimeInterval(collected ?? began + span),
        batches: batches,
        macUseWatts: macUse,
        adapterInputWatts: adapterInput,
        batteryWatts: battery
    )
}

extension PowerFlowTick.Content {
    /// The case, for comparing sequences of ticks.
    var kind: String {
        switch self {
        case .window: "window"
        case .registry: "registry"
        case .empty: "empty"
        }
    }
}

/// A continuous clock the test moves by hand, from ``readClockOrigin``, and
/// a wall clock that moves with it from ``referenceDate``.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero

    var now: ContinuousClock.Instant {
        lock.withLock { readClockOrigin.advanced(by: elapsed) }
    }

    var wallNow: Date {
        lock.withLock {
            let parts = elapsed.components
            return referenceDate.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
    }

    func set(_ seconds: Double) {
        lock.withLock { elapsed = .milliseconds(Int((seconds * 1_000).rounded())) }
    }
}

/// A fake reader. Each call takes the next scripted result (the last one
/// again once used up), records the keys asked for and the thread it ran
/// on, and can be held until the test releases it, as a read that hangs
/// would be. Once released, later calls return at once, so that no test
/// leaves a thread blocked.
final class FakeSMCReader: SMCPowerReading, @unchecked Sendable {
    enum Step: Sendable {
        case values([SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>])
        case openFails(SMCOpenError)
    }

    private let lock = NSLock()
    private var script: [Step]
    private var holds = false
    private var held = 0
    private let release = DispatchSemaphore(value: 0)
    private var keysAsked: [[SMCPowerKey]] = []
    private var threadNames: [String?] = []
    private var mainThreadCalls = 0
    private var inCall = 0
    private var mostInCall = 0

    init(_ script: [Step] = [.values(smcValues())]) {
        self.script = script
    }

    /// Calls made so far, begun or finished.
    var calls: Int { lock.withLock { keysAsked.count } }
    var keys: [[SMCPowerKey]] { lock.withLock { keysAsked } }
    var threads: [String?] { lock.withLock { threadNames } }
    var callsOnMainThread: Int { lock.withLock { mainThreadCalls } }
    /// The most calls in progress at once.
    var mostAtOnce: Int { lock.withLock { mostInCall } }

    /// Holds every call from now on until ``releaseAll()``.
    func hold() {
        lock.withLock { holds = true }
    }

    /// Lets every held call return, and every later one at once.
    func releaseAll() {
        let count = lock.withLock {
            holds = false
            defer { held = 0 }
            return held
        }
        for _ in 0..<count { release.signal() }
    }

    /// Replaces the script.
    func script(_ steps: [Step]) {
        lock.withLock { script = steps }
    }

    func read(_ keys: [SMCPowerKey]) throws -> [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>] {
        let (step, waits) = lock.withLock {
            keysAsked.append(keys)
            threadNames.append(Thread.current.name)
            if Thread.isMainThread { mainThreadCalls += 1 }
            inCall += 1
            mostInCall = max(mostInCall, inCall)
            if holds { held += 1 }
            let step = script.count > 1 ? script.removeFirst() : script[0]
            return (step, holds)
        }
        if waits { release.wait() }
        lock.withLock { inCall -= 1 }
        switch step {
        case .values(let values):
            return values.filter { keys.contains($0.key) }
        case .openFails(let error):
            throw error
        }
    }
}

extension SMCPowerCoordinator {
    /// Whether `reader` has had `calls` calls and none is in flight.
    func isIdle(afterCalls calls: Int, of reader: FakeSMCReader) -> Bool {
        reader.calls == calls && current.inFlight == nil
    }
}

/// Waits, a bounded time, until `condition` holds; a test then fails on its
/// own expectation rather than hanging.
func eventually(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<5_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
