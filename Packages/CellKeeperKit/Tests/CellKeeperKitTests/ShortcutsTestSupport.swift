import CellKeeperCore
import CellKeeperKit
import Foundation

/// A monotonic clock that moves only when a test says so. Sleepers wake when
/// it advances past their deadline (or, with `waking: false`, not at all:
/// a timer running late), or when their task is cancelled.
final class ManualDeadlineClock: DeadlineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var sleepers: [Int: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextSleeperID = 0
    private var sleepsStarted = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: ContinuousClock.Instant { lock.withLock { current } }

    func sleep(until deadline: ContinuousClock.Instant) async {
        let id = lock.withLock {
            defer { nextSleeperID += 1 }
            return nextSleeperID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (wakeNow, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    sleepsStarted += 1
                    let ready = takeWatchers()
                    if current >= deadline || Task.isCancelled { return (true, ready) }
                    sleepers[id] = (deadline, continuation)
                    return (false, ready)
                }
                ready.forEach { $0.resume() }
                if wakeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume()
        }
    }

    /// Moves the clock; with `waking`, wakes the sleepers whose deadline it
    /// passed.
    func advance(by duration: Duration, waking: Bool = true) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current = current.advanced(by: duration)
            guard waking else { return [] }
            let ids = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }

    /// Wakes every sleeper without moving the clock, as a timer that fires
    /// early would.
    func wakeAllEarly() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { sleepers.removeAll() }
            return sleepers.values.map(\.continuation)
        }
        all.forEach { $0.resume() }
    }

    /// Returns once `count` sleeps have started in total: as many waiters
    /// have registered and their timers are asleep.
    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if sleepsStarted >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Called with the lock held.
    private func takeWatchers() -> [CheckedContinuation<Void, Never>] {
        let ready = watchers.filter { $0.count <= sleepsStarted }.map(\.continuation)
        watchers.removeAll { $0.count <= sleepsStarted }
        return ready
    }
}

/// The app as Shortcuts actions see it, recording what they ask for.
@MainActor
final class FakeActionTarget: ShortcutsActionTarget {
    var status: ControllerStatus?
    var settings: ChargingSettings
    var isTerminating = false
    var selectedBackendIdentifier: String
    let firstStatus: FirstValue<Bool>
    /// Makes saves fail, as `AppModel` reports a failed save.
    var failsToSave = false
    private(set) var changes: [(settings: ChargingSettings, source: SettingsChangeSource)] = []
    private(set) var fullChargesQueued = 0
    private(set) var cancelsQueued = 0

    init(clock: any DeadlineClock, status: ControllerStatus? = nil, settings: ChargingSettings = .default, selectedBackendIdentifier: String = MockChargingBackend().descriptor.identifier) {
        self.status = status
        self.settings = settings
        self.selectedBackendIdentifier = selectedBackendIdentifier
        self.firstStatus = FirstValue(clock: clock)
        if status != nil { firstStatus.provide(true) }
    }

    var chargeLimitChoices: ChargeLimitChoices {
        ChargeLimitChoices.offered(capabilities: status?.capabilities, isNativeChosen: selectedBackendIdentifier == NativeChargeLimitBackend.identifier)
    }

    /// The first status arrives.
    func receive(_ newStatus: ControllerStatus) {
        status = newStatus
        firstStatus.provide(true)
    }

    func changeSettings(_ proposed: ChargingSettings, source: SettingsChangeSource) -> SettingsChangeResult {
        changes.append((proposed, source))
        guard proposed != settings else { return .unchanged }
        guard !failsToSave else { return .refused(SettingsChangeResult.saveFailed) }
        let previous = settings
        settings = proposed
        return .saved(previous: previous)
    }

    func queueFullCharge() {
        fullChargesQueued += 1
    }

    func queueCancelOverride() {
        cancelsQueued += 1
    }
}

/// A status from a real evaluation with `backend`, at `percent` on external
/// power.
func evaluatedActionStatus(_ backend: any ChargingBackend = MockChargingBackend(), percent: Int = 70, settings: ChargingSettings = .default) async -> ControllerStatus {
    let clock = KitTestClock()
    let controller = ChargeController(telemetry: KitStubTelemetry(percent: percent, clock: clock), backend: backend, settings: settings, now: { clock.now }, uptime: { clock.uptime })
    return await controller.evaluate(.launch)
}

/// `status` as macOS's Charge Limit backend would report it.
func asNativeLimit(_ status: ControllerStatus, availability: ControlAvailability = .experimental, reportedLimit: Int? = 80, readProblem: String? = nil) -> ControllerStatus {
    var native = status
    native.backend = BackendDescriptor(identifier: NativeChargeLimitBackend.identifier, displayName: "macOS Charge Limit", summary: "")
    if case .unavailable(let reason) = availability {
        native.capabilities = .unavailable(reason, style: .nativeLimit(steps: NativeChargeLimitBackend.supportedLimits))
    } else {
        native.capabilities = .nativeLimit(availability: availability, steps: NativeChargeLimitBackend.supportedLimits)
    }
    native.nativeLimit = NativeLimitStatus(reportedLimit: reportedLimit, readAt: Date(timeIntervalSince1970: 1_800_000_000), readProblem: readProblem)
    return native
}
