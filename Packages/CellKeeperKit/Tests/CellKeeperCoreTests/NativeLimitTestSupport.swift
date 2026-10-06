import CellKeeperCore
import Foundation

/// Stands in for macOS's Charge Limit, the user's shortcut, and the
/// read-back, so tests never touch the system.
final class FakeChargeLimitSystem: ShortcutRunning, ChargeLimitReading, @unchecked Sendable {
    enum RunBehaviour {
        /// The shortcut sets the limit it is given.
        case applies
        /// The shortcut finishes successfully but changes nothing.
        case hasNoEffect
        /// The shortcut reports an error.
        case fails
        /// The shortcut sets the limit, but the next read fails.
        case appliesButNextReadFails
    }

    struct FakeError: Error, CustomStringConvertible {
        var description: String
    }

    private let lock = NSLock()
    private var _reading: NativeChargeLimitReading
    private var _names: [String]
    private var _runBehaviour: RunBehaviour = .applies
    private var _nextRuns: [RunBehaviour] = []
    private var _readFails = false
    private var _failingReads = 0
    private var _listFails = false
    private var _runInputs: [String] = []
    private var _listCalls = 0
    private var _delayedChange: (remainingReads: Int, reading: NativeChargeLimitReading)?
    private var _delayedFailure: Int?

    init(reading: NativeChargeLimitReading = .limit(80), shortcutNames: [String] = [NativeChargeLimitBackend.defaultShortcutName]) {
        _reading = reading
        _names = shortcutNames
    }

    /// What macOS currently reports.
    var reading: NativeChargeLimitReading {
        get { lock.withLock { _reading } }
        set { lock.withLock { _reading = newValue } }
    }

    var runBehaviour: RunBehaviour {
        get { lock.withLock { _runBehaviour } }
        set { lock.withLock { _runBehaviour = newValue } }
    }

    var readFails: Bool {
        get { lock.withLock { _readFails } }
        set { lock.withLock { _readFails = newValue } }
    }

    var listFails: Bool {
        get { lock.withLock { _listFails } }
        set { lock.withLock { _listFails = newValue } }
    }

    var names: [String] {
        get { lock.withLock { _names } }
        set { lock.withLock { _names = newValue } }
    }

    /// Makes the next `count` reads fail.
    func failNextReads(_ count: Int) {
        lock.withLock { _failingReads += count }
    }

    /// Makes one read fail after `count` more reads.
    func failRead(after count: Int) {
        lock.withLock { _delayedFailure = count }
    }

    /// Behaviours for the next runs, before ``runBehaviour`` applies again.
    func scheduleRuns(_ behaviours: [RunBehaviour]) {
        lock.withLock { _nextRuns.append(contentsOf: behaviours) }
    }

    /// Every input the shortcut was run with, in order.
    var runInputs: [String] { lock.withLock { _runInputs } }
    var listCalls: Int { lock.withLock { _listCalls } }

    /// Changes the limit as if the user or another tool had done it.
    func changeExternally(to percent: Int) {
        reading = percent >= 100 ? .noLimit : .limit(percent)
    }

    /// Changes the limit from outside after `count` more successful reads,
    /// for example between CellKeeper's read and its write.
    func changeExternally(to percent: Int, afterReads count: Int) {
        lock.withLock { _delayedChange = (count, percent >= 100 ? .noLimit : .limit(percent)) }
    }

    func shortcutNames() async throws -> [String] {
        try lock.withLock {
            _listCalls += 1
            if _listFails { throw FakeError(description: "list failed") }
            return _names
        }
    }

    func runShortcut(named name: String, input: String) async throws {
        try lock.withLock {
            guard _names.contains(name) else { throw FakeError(description: "Couldn’t find shortcut") }
            _runInputs.append(input)
            let behaviour = _nextRuns.isEmpty ? _runBehaviour : _nextRuns.removeFirst()
            switch behaviour {
            case .applies, .appliesButNextReadFails:
                guard let percent = Int(input) else { throw FakeError(description: "not a number") }
                _reading = percent >= 100 ? .noLimit : .limit(percent)
                if behaviour == .appliesButNextReadFails {
                    _failingReads += 1
                }
            case .hasNoEffect:
                break
            case .fails:
                throw FakeError(description: "shortcut failed")
            }
        }
    }

    func readChargeLimit() async throws -> NativeChargeLimitReading {
        try lock.withLock {
            if _readFails { throw FakeError(description: "read failed") }
            if _failingReads > 0 {
                _failingReads -= 1
                throw FakeError(description: "read failed")
            }
            if let remaining = _delayedFailure {
                if remaining == 0 {
                    _delayedFailure = nil
                    throw FakeError(description: "read failed")
                }
                _delayedFailure = remaining - 1
            }
            if let delayed = _delayedChange {
                if delayed.remainingReads == 0 {
                    _reading = delayed.reading
                    _delayedChange = nil
                } else {
                    _delayedChange = (delayed.remainingReads - 1, delayed.reading)
                }
            }
            return _reading
        }
    }
}

/// An in-memory ``OwnershipRecordStore`` with failure injection, shared by a
/// backend and the test (and by a second backend, to simulate a relaunch).
final class InMemoryRecordStore: OwnershipRecordStore, @unchecked Sendable {
    struct StoreError: Error {}

    private let lock = NSLock()
    private var stored: Data?
    private var _saveFails = false
    private var _loadFails = false

    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var saveFails: Bool {
        get { lock.withLock { _saveFails } }
        set { lock.withLock { _saveFails = newValue } }
    }

    var loadFails: Bool {
        get { lock.withLock { _loadFails } }
        set { lock.withLock { _loadFails = newValue } }
    }

    func load() throws -> Data? {
        try lock.withLock {
            if _loadFails { throw StoreError() }
            return stored
        }
    }

    func save(_ data: Data) throws {
        try lock.withLock {
            if _saveFails { throw StoreError() }
            stored = data
        }
    }

    func remove() throws {
        lock.withLock { stored = nil }
    }
}

let nativeCapabilities = ControlCapabilities.nativeLimit(availability: .experimental, steps: NativeChargeLimitBackend.supportedLimits)

func makeNativeBackend(
    system: FakeChargeLimitSystem,
    store: InMemoryRecordStore,
    platformIssue: String? = nil,
    clock: TestClock = TestClock()
) -> NativeChargeLimitBackend {
    NativeChargeLimitBackend(
        runner: system,
        reader: system,
        store: store,
        platformIssue: platformIssue,
        now: { clock.now },
        uptime: { clock.uptime }
    )
}

/// Writes an ownership record the way a previous session would have.
func storeOwnershipRecord(owner: Int, target: Int, pending: Int? = nil, restoring: Bool = false, in store: InMemoryRecordStore) {
    let pendingField = pending.map { #","pendingTargets":[\#($0)]"# } ?? ""
    let restoringField = restoring ? #","isRestoring":true"# : ""
    let json = #"{"ownerLimit":\#(owner),"target":\#(target)\#(pendingField)\#(restoringField),"recordedAt":0}"#
    store.data = Data(json.utf8)
}
