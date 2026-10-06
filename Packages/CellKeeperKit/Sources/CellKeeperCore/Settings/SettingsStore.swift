import Foundation

/// The subset of `UserDefaults` that ``SettingsStore`` needs. Lets tests use
/// an in-memory store instead of writing to the user's preferences.
public protocol KeyValueStorage {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStorage {}

/// Persists settings in `UserDefaults` as JSON. Loaded values are validated;
/// invalid or unreadable data falls back to defaults rather than being applied.
public struct SettingsStore {
    public static let chargingSettingsKey = "chargingSettings.v1"

    /// What unusable stored settings are replaced with: the defaults, but
    /// with management off, so CellKeeper fails toward macOS defaults rather
    /// than starting to manage charging the user may have turned off.
    public static let recoverySettings: ChargingSettings = {
        var settings = ChargingSettings.default
        settings.isManagementEnabled = false
        return settings
    }()

    public struct LoadResult: Sendable, Equatable {
        public var settings: ChargingSettings
        /// Non-nil when stored data was unreadable or invalid and defaults were used.
        public var recoveryReason: String?
    }

    private let defaults: any KeyValueStorage

    public init(defaults: any KeyValueStorage = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func loadChargingSettings() -> LoadResult {
        guard let data = defaults.data(forKey: Self.chargingSettingsKey) else {
            return LoadResult(settings: .default, recoveryReason: nil)
        }
        let decoded: ChargingSettings
        do {
            decoded = try JSONDecoder().decode(ChargingSettings.self, from: data)
        } catch {
            CellKeeperLog.settings.error("Stored settings unreadable; using defaults with management off: \(String(describing: error), privacy: .public)")
            return LoadResult(settings: Self.recoverySettings, recoveryReason: "Stored settings could not be read. Defaults are in use, with Manage charging off.")
        }
        let issues = decoded.validationIssues
        guard issues.isEmpty else {
            let summary = issues.map(\.description).joined(separator: " ")
            CellKeeperLog.settings.error("Stored settings invalid; using defaults with management off: \(summary, privacy: .public)")
            return LoadResult(settings: Self.recoverySettings, recoveryReason: "Stored settings were invalid: \(summary) Defaults are in use, with Manage charging off.")
        }
        return LoadResult(settings: decoded, recoveryReason: nil)
    }

    /// Saves settings after validating them. Invalid settings are not written.
    public func save(_ settings: ChargingSettings) throws {
        let valid = try settings.validated()
        defaults.set(try JSONEncoder().encode(valid), forKey: Self.chargingSettingsKey)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
