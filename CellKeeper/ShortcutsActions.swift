import AppIntents
import CellKeeperCore
import CellKeeperKit

// CellKeeper's actions in the Shortcuts app. Each is the same command as the
// menu's or Settings', run by `ShortcutsActionCoordinator` (Kit), which owns
// every check, wait and word; these types only connect it to App Intents.
// `openAppWhenRun` keeps its default, false: no window opens.

/// Runs the actions against the app model, which `AppDelegate` attaches
/// once `start()` has queued its start-up work.
@MainActor
enum ShortcutsActionHost {
    static let coordinator = ShortcutsActionCoordinator(log: { CellKeeperLog.app.notice("\($0, privacy: .public)") })
}

/// A refusal; Shortcuts shows its text and stops the shortcut.
struct ShortcutsActionRefusal: Error, CustomLocalizedStringResourceConvertible {
    let text: String

    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

private extension ShortcutsActionOutcome {
    func dialog() throws -> IntentDialog {
        switch self {
        case .done(let text): IntentDialog("\(text)")
        case .refused(let text): throw ShortcutsActionRefusal(text: text)
        }
    }
}

struct SetCellKeeperLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Set CellKeeper Limit"
    static var description: IntentDescription {
        IntentDescription("Changes CellKeeper's charge limit, the same setting as in its menu and Settings. The limit applies only while Manage charging is on. This is not Apple's Set Charge Limit action, nor your “CellKeeper Set Charge Limit” shortcut. If CellKeeper is not running, it opens and starts managing charging with your saved settings, as when you open it.")
    }

    @Parameter(title: "Limit")
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set CellKeeper's charge limit to \(\.$limit)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ShortcutsActionHost.coordinator.setChargeLimit(limit)
        return .result(dialog: try outcome.dialog())
    }
}

struct StartCellKeeperFullChargeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start CellKeeper Full Charge"
    static var description: IntentDescription {
        IntentDescription("Asks CellKeeper for a temporary full charge, like “Charge to 100% once” in its menu. It does not start while a temporary full charge or a discharge is already running. It ends after the battery is full, you unplug, or 12 hours pass. If CellKeeper is not running, it opens and starts managing charging with your saved settings, as when you open it.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ShortcutsActionHost.coordinator.startFullCharge()
        return .result(dialog: try outcome.dialog())
    }
}

struct StopCellKeeperFullChargeIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop CellKeeper Full Charge or Discharge"
    static var description: IntentDescription {
        IntentDescription("Ends a temporary full charge or a discharge to the limit, like “Cancel” in CellKeeper's menu. If CellKeeper is not running, it opens and starts managing charging with your saved settings, as when you open it.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ShortcutsActionHost.coordinator.stopOverride()
        return .result(dialog: try outcome.dialog())
    }
}

struct SetCellKeeperManageChargingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set CellKeeper Manage Charging"
    static var description: IntentDescription {
        IntentDescription("Turns CellKeeper's Manage charging on or off, like the toggle in its menu. Turning it off also ends a temporary full charge or discharge. If CellKeeper is not running, it opens and starts managing charging with your saved settings, as when you open it.")
    }

    @Parameter(title: "Manage charging", displayName: Bool.IntentDisplayName(true: "On", false: "Off"))
    var isOn: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn CellKeeper's Manage charging \(\.$isOn)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await ShortcutsActionHost.coordinator.setManagement(isOn)
        return .result(dialog: try outcome.dialog())
    }
}

struct GetCellKeeperStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get CellKeeper Status"
    static var description: IntentDescription {
        IntentDescription("Returns the battery charge and what CellKeeper is doing, as of its latest check. It starts no check of its own. If CellKeeper is not running, it opens and starts managing charging with your saved settings, as when you open it.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CellKeeperStatusEntity> & ProvidesDialog {
        switch await ShortcutsActionHost.coordinator.status() {
        case .status(let value):
            return .result(value: CellKeeperStatusEntity(value), dialog: IntentDialog("\(value.dialog)"))
        case .refused(let text):
            throw ShortcutsActionRefusal(text: text)
        }
    }
}

/// The value Get CellKeeper Status returns (`ShortcutsStatus`, Kit).
struct CellKeeperStatusEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "CellKeeper Status")
    }

    @Property(title: "Battery charge")
    var batteryCharge: Int?
    @Property(title: "Charging status")
    var chargingStatus: String
    @Property(title: "State")
    var state: String
    @Property(title: "Control")
    var control: String
    @Property(title: "Simulated")
    var isSimulated: Bool?
    @Property(title: "Charge limit")
    var chargeLimit: Int
    @Property(title: "Manage charging")
    var isManagingCharging: Bool
    @Property(title: "Checked at")
    var checkedAt: Date?

    init() {}

    init(_ value: ShortcutsStatus) {
        batteryCharge = value.batteryCharge
        chargingStatus = value.chargingStatus
        state = value.state
        control = value.control
        isSimulated = value.isSimulated
        chargeLimit = value.chargeLimit
        isManagingCharging = value.isManagingCharging
        checkedAt = value.checkedAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(ShortcutsStatus.title(batteryCharge: batteryCharge))", subtitle: "\(state)")
    }
}

/// Siri and Spotlight: the status only. The phrase sends no control command
/// itself; a misheard one should not change charging.
struct CellKeeperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetCellKeeperStatusIntent(),
            phrases: ["Get \(.applicationName) status", "What is \(.applicationName) doing"],
            shortTitle: "Status",
            systemImageName: "batteryblock"
        )
    }
}
