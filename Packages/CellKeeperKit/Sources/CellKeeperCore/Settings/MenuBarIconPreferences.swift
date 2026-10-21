import Foundation

/// What the menu bar icon shows (D113): a battery CellKeeper draws, or
/// CellKeeper's status symbol. The raw value is what ``SettingsStore``
/// saves.
public enum MenuBarIconStyle: String, Sendable, Equatable, CaseIterable {
    /// A battery with a fill for the charge, a bolt while charging and a
    /// plug while on power and not charging, like macOS's own battery icon.
    case battery
    /// CellKeeper's status symbol, the icon before D113.
    case status
}

/// The menu bar icon's appearance settings. Kept apart from
/// ``ChargingSettings``: they change nothing about charging, so they can
/// never make stored charging settings invalid, and stored charging
/// settings that are invalid never change them.
public struct MenuBarIconPreferences: Sendable, Equatable {
    public var style: MenuBarIconStyle
    /// Whether the Battery style shows the charge as text beside the
    /// battery. The status style shows no percentage.
    public var showsPercentage: Bool

    public init(style: MenuBarIconStyle, showsPercentage: Bool) {
        self.style = style
        self.showsPercentage = showsPercentage
    }

    /// The Battery style with the percentage shown: what the owner asked
    /// for, and what saved settings that predate these keys get.
    public static let `default` = MenuBarIconPreferences(style: .battery, showsPercentage: true)
}
