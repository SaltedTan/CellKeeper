import CellKeeperCore
import Foundation

/// What the menu bar icon shows (D113), from the latest status and the
/// owner's choice of style. The app draws the battery; this decides what it
/// shows. The icon's VoiceOver label is the app's, and does not change with
/// the style.
public enum MenuBarIcon: Sendable, Equatable {
    /// An SF Symbol for CellKeeper's state: the CellKeeper status style,
    /// and the Battery style's fallback when there is no battery or its
    /// charge is unknown.
    case symbol(String)
    /// A battery that the app draws.
    case battery(MenuBarBattery)

    /// The icon for `status`, nil before the first one arrives.
    public init(status: ControllerStatus?, preferences: MenuBarIconPreferences) {
        guard preferences.style == .battery,
              let status, let snapshot = status.snapshot, snapshot.isBatteryPresent,
              let charge = snapshot.chargePercent
        else {
            self = .symbol(Self.statusSymbol(for: status))
            return
        }
        let percent = min(max(charge, 0), 100)
        self = .battery(MenuBarBattery(
            percent: percent,
            glyph: MenuBarBattery.Glyph(snapshot),
            percentageText: preferences.showsPercentage ? "\(percent)%" : nil,
            attentionSymbol: Self.attentionSymbol(for: status)
        ))
    }

    /// CellKeeper's status symbol: `batteryblock` before the first status
    /// and before the first decision, then one symbol per state.
    public static func statusSymbol(for status: ControllerStatus?) -> String {
        guard let status, let decision = status.decision else { return "batteryblock" }
        if status.isBackendFaulted { return "exclamationmark.triangle" }
        switch decision.state {
        case .unmanaged: return "batteryblock.slash"
        case .failSafe: return "exclamationmark.triangle"
        case .temperaturePause: return "thermometer.high"
        case .discharging: return "minus.plus.batteryblock"
        case .holding, .onBattery, .charging, .fullChargeOverride, .safetyFloor, .osEnforcedLimit, .deferringToMacOS, .calibrating:
            // A state that allows charging does not mean the battery is
            // charging (unplugged at the safety floor, full at a 100% limit).
            return status.snapshot?.isCharging == true ? "bolt.batteryblock" : "batteryblock"
        }
    }

    /// The symbol the Battery style keeps beside the battery for a state
    /// that needs attention: a backend fault or the fail-safe, and a
    /// temperature pause. The menu shows every other state, so the battery
    /// is enough for them.
    static func attentionSymbol(for status: ControllerStatus) -> String? {
        if status.isBackendFaulted { return "exclamationmark.triangle" }
        switch status.decision?.state {
        case .failSafe?: return "exclamationmark.triangle"
        case .temperaturePause?: return "thermometer.high"
        default: return nil
        }
    }
}

/// The battery the Battery style draws. Equal batteries draw the same
/// image, so the app can keep one image per value.
public struct MenuBarBattery: Sendable, Hashable {
    /// What the battery shows inside it, as macOS's battery icon does.
    public enum Glyph: Sendable, Hashable, CaseIterable {
        /// On battery, or the power source is unknown.
        case none
        /// The battery is charging.
        case bolt
        /// On external power and not charging: held at a limit, full, or
        /// paused.
        case plug

        /// The bolt only when macOS reports the battery charging; the plug
        /// on external power otherwise.
        init(_ snapshot: BatterySnapshot) {
            if snapshot.isCharging == true {
                self = .bolt
            } else if snapshot.isOnExternalPower {
                self = .plug
            } else {
                self = .none
            }
        }
    }

    /// The charge in whole percent, 0–100: the fill.
    public var percent: Int
    public var glyph: Glyph
    /// The charge as text beside the battery ("80%"), or nil if the owner
    /// turned it off.
    public var percentageText: String?
    /// An SF Symbol beside the battery for a state that needs attention, or
    /// nil.
    public var attentionSymbol: String?

    public init(percent: Int, glyph: Glyph, percentageText: String?, attentionSymbol: String?) {
        self.percent = percent
        self.glyph = glyph
        self.percentageText = percentageText
        self.attentionSymbol = attentionSymbol
    }

    /// The share of the battery's inside the fill covers, 0–1.
    public var fillFraction: Double {
        Double(min(max(percent, 0), 100)) / 100
    }

    /// The fill's width inside a battery `width` points wide: the charge's
    /// share of it in half points (whole pixels on a Retina display), at
    /// least `minimum` above 0%, so a low charge still shows, and none at
    /// 0%. Never wider than `width`.
    public func fillWidth(in width: Double, minimum: Double) -> Double {
        guard percent > 0, width > 0 else { return 0 }
        let proportional = (width * fillFraction * 2).rounded() / 2
        return min(max(proportional, minimum), width)
    }
}
