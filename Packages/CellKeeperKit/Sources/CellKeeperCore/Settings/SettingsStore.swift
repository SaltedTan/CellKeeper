import Foundation

/// The subset of `UserDefaults` that ``SettingsStore`` needs. Lets tests use
/// an in-memory store instead of writing to the user's preferences.
public protocol KeyValueStorage {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    /// Whatever is stored under `key`, of any type, or nil if nothing is, so
    /// a value of an unexpected type can be told apart from none.
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension KeyValueStorage {
    /// For storages that keep only data and strings.
    public func object(forKey key: String) -> Any? {
        data(forKey: key) ?? string(forKey: key)
    }
}

extension UserDefaults: KeyValueStorage {}

/// Persists settings in `UserDefaults` as JSON. Loaded values are validated;
/// invalid or unreadable data falls back to defaults rather than being applied.
/// The selected backend, the notification choice and the menu bar icon's
/// settings are stored under keys of their own.
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

    /// Whether the user opted in to notifications. Kept apart from
    /// ``ChargingSettings``, so it can never make stored charging settings
    /// invalid, and stored settings that are invalid never turn it off.
    public static let notificationsKey = "notifications.v1"

    /// The user's notification choice: on only if saved as on, so a missing
    /// or unrecognised value means off (the default).
    public func loadNotificationsEnabled() -> Bool {
        defaults.string(forKey: Self.notificationsKey) == "on"
    }

    public func saveNotificationsEnabled(_ enabled: Bool) {
        defaults.set(enabled ? "on" : "off", forKey: Self.notificationsKey)
    }

    /// The menu bar icon's style and whether it shows the percentage, each
    /// under a key of its own, apart from ``ChargingSettings`` like the
    /// notification choice (D113).
    public static let menuBarIconStyleKey = "menuBarIconStyle.v1"
    public static let menuBarPercentageKey = "menuBarPercentage.v1"

    /// The menu bar icon's settings: each one missing or unrecognised gets
    /// its default (``MenuBarIconPreferences/default``), whatever the other
    /// holds, so settings saved before these keys existed show the Battery
    /// style with the percentage.
    public func loadMenuBarIconPreferences() -> MenuBarIconPreferences {
        let defaultPreferences = MenuBarIconPreferences.default
        let style = defaults.string(forKey: Self.menuBarIconStyleKey).flatMap(MenuBarIconStyle.init(rawValue:)) ?? defaultPreferences.style
        let showsPercentage = switch defaults.string(forKey: Self.menuBarPercentageKey) {
        case "on": true
        case "off": false
        default: defaultPreferences.showsPercentage
        }
        return MenuBarIconPreferences(style: style, showsPercentage: showsPercentage)
    }

    public func saveMenuBarIconPreferences(_ preferences: MenuBarIconPreferences) {
        defaults.set(preferences.style.rawValue, forKey: Self.menuBarIconStyleKey)
        defaults.set(preferences.showsPercentage ? "on" : "off", forKey: Self.menuBarPercentageKey)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
