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
    private var _listFails = false
    private var _runInputs: [String] = []
    private var _listCalls = 0

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
            case .applies:
                guard let percent = Int(input) else { throw FakeError(description: "not a number") }
                _reading = percent >= 100 ? .noLimit : .limit(percent)
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
            return _reading
        }
    }
}

let nativeCapabilities = ControlCapabilities.nativeLimit(availability: .experimental, steps: NativeChargeLimitBackend.supportedLimits)

func makeNativeBackend(
    system: FakeChargeLimitSystem,
    storage: InMemoryStorage,
    platformIssue: String? = nil,
    clock: TestClock = TestClock()
) -> NativeChargeLimitBackend {
    NativeChargeLimitBackend(
        runner: system,
        reader: system,
        storage: storage,
        platformIssue: platformIssue,
        now: { clock.now },
        uptime: { clock.uptime }
    )
}

/// Writes an ownership record the way a previous session would have.
func storeOwnershipRecord(owner: Int, target: Int, in storage: InMemoryStorage) {
    let json = #"{"ownerLimit":\#(owner),"target":\#(target),"recordedAt":0}"#
    storage.set(Data(json.utf8), forKey: NativeChargeLimitBackend.ownershipKey)
}
