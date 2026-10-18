import CellKeeperCore
import Foundation
import Testing

/// The opt-in to notifications: off by default, saved apart from the
/// charging settings, and a toggle that is on only while macOS shows them.
@Suite("Notification opt-in")
struct NotificationOptInTests {
    // MARK: - Saved choice

    @Test("Notifications are off unless saved as on; anything else stored means off")
    func savedChoice() {
        let storage = InMemoryStorage()
        let store = SettingsStore(defaults: storage)
        #expect(!store.loadNotificationsEnabled())
        store.saveNotificationsEnabled(true)
        #expect(store.loadNotificationsEnabled())
        store.saveNotificationsEnabled(false)
        #expect(!store.loadNotificationsEnabled())
        for unrecognised: Any in ["yes", "ON", "", 1, true, Data("on".utf8)] {
            storage.set(unrecognised, forKey: SettingsStore.notificationsKey)
            #expect(!store.loadNotificationsEnabled())
        }
    }

    @Test("The notification choice and the charging settings never affect each other when loaded")
    func keptApartFromChargingSettings() throws {
        let storage = InMemoryStorage()
        let store = SettingsStore(defaults: storage)
        let settings = ChargingSettings.default.withChargeLimit(70)
        try store.save(settings)

        storage.set("garbage", forKey: SettingsStore.notificationsKey)
        let loaded = store.loadChargingSettings()
        #expect(loaded.settings == settings)
        #expect(loaded.recoveryReason == nil)

        store.saveNotificationsEnabled(true)
        storage.set(Data("not json".utf8), forKey: SettingsStore.chargingSettingsKey)
        #expect(store.loadChargingSettings().settings == SettingsStore.recoverySettings)
        #expect(store.loadNotificationsEnabled())
    }

    // MARK: - State

    @Test("Off by default: no toggle, no delivery, nothing to explain")
    func offByDefault() {
        let optIn = NotificationOptIn(isEnabled: false, permission: .shown)
        #expect(optIn.state == .off)
        #expect(!optIn.isToggleOn)
        #expect(!optIn.isDelivering)
        #expect(optIn.explanation == nil)
        #expect(!optIn.offersSystemSettings)
    }

    /// What a state shows and does.
    struct Shown: Sendable {
        var state: NotificationOptIn.State
        var isToggleOn = false
        var isDelivering = false
        var offersSystemSettings = false
        var offersWithdrawal = false
    }

    @Test("Each answer from macOS gives its own state, toggle, delivery and explanation", arguments: [
        (NotificationOptIn(isEnabled: true), Shown(state: .checking, isDelivering: true, offersWithdrawal: true)),
        (NotificationOptIn(isEnabled: true, isRequesting: true), Shown(state: .requesting, offersWithdrawal: true)),
        (NotificationOptIn(isEnabled: true, permission: .shown), Shown(state: .on, isToggleOn: true, isDelivering: true)),
        (NotificationOptIn(isEnabled: true, permission: .notificationCenterOnly), Shown(state: .on, isToggleOn: true, isDelivering: true)),
        (NotificationOptIn(isEnabled: true, permission: .notDetermined), Shown(state: .notAsked, offersWithdrawal: true)),
        (NotificationOptIn(isEnabled: true, permission: .notDetermined, hasRequested: true), Shown(state: .unanswered, offersSystemSettings: true, offersWithdrawal: true)),
        (NotificationOptIn(isEnabled: true, permission: .denied), Shown(state: .denied, offersSystemSettings: true, offersWithdrawal: true)),
        (NotificationOptIn(isEnabled: true, permission: .shownNowhere), Shown(state: .hiddenByMacOS, offersSystemSettings: true, offersWithdrawal: true)),
        (NotificationOptIn(isEnabled: true, permission: .unrecognized), Shown(state: .unrecognized, offersSystemSettings: true, offersWithdrawal: true)),
    ])
    func states(optIn: NotificationOptIn, shown: Shown) {
        #expect(optIn.state == shown.state)
        #expect(optIn.isToggleOn == shown.isToggleOn)
        #expect(optIn.isDelivering == shown.isDelivering)
        #expect(optIn.offersSystemSettings == shown.offersSystemSettings)
        #expect(optIn.offersWithdrawal == shown.offersWithdrawal)
        // Every state but a plain "on" with banners says something.
        #expect((optIn.explanation == nil) == (shown.state == .on && optIn.permission?.showsBanners == true))
    }

    @Test("The toggle is never on unless the user opted in and macOS shows the notifications, and nothing is delivered that macOS is known not to show")
    func toggleNeverOverclaims() {
        let authorizations: [NotificationPermission.Authorization] = [.notDetermined, .denied, .authorized, .provisional, .unrecognized]
        for authorization in authorizations {
            for banners in [false, true] {
                for center in [false, true] {
                    let permission = NotificationPermission(authorization: authorization, showsBanners: banners, listsInNotificationCenter: center)
                    for isEnabled in [false, true] {
                        for isRequesting in [false, true] {
                            for hasRequested in [false, true] {
                                let optIn = NotificationOptIn(isEnabled: isEnabled, permission: permission, isRequesting: isRequesting, hasRequested: hasRequested)
                                #expect(!optIn.isToggleOn || (isEnabled && permission.isShown && !isRequesting))
                                #expect(!optIn.isDelivering || (isEnabled && permission.isShown))
                                // A saved opt-in the toggle does not show
                                // as on can always be withdrawn.
                                #expect(!isEnabled || optIn.isToggleOn || optIn.offersWithdrawal)
                            }
                        }
                    }
                }
            }
        }
        for isRequesting in [false, true] {
            for hasRequested in [false, true] {
                let unread = NotificationOptIn(isEnabled: true, permission: nil, isRequesting: isRequesting, hasRequested: hasRequested)
                #expect(!unread.isToggleOn)
                #expect(unread.offersWithdrawal)
            }
        }
        #expect(NotificationPermission.shown.isShown)
        #expect(NotificationPermission.notificationCenterOnly.isShown)
        #expect(!NotificationPermission.shownNowhere.isShown)
        #expect(NotificationPermission(authorization: .provisional, showsBanners: false, listsInNotificationCenter: true).isShown)
    }

    @Test("A denial says so plainly and points to System Settings")
    func deniedWording() {
        let optIn = NotificationOptIn(isEnabled: true, permission: .denied, hasRequested: true)
        #expect(optIn.explanation == "You turned notifications on, but macOS does not allow notifications from CellKeeper, so none are shown. To get them, allow CellKeeper in System Settings › Notifications.")
        #expect(optIn.offersSystemSettings)
        #expect(optIn.offersWithdrawal)
    }
}

extension NotificationPermission {
    static let notificationCenterOnly = NotificationPermission(authorization: .authorized, showsBanners: false, listsInNotificationCenter: true)
    static let shownNowhere = NotificationPermission(authorization: .authorized, showsBanners: false, listsInNotificationCenter: false)
    static let unrecognized = NotificationPermission(authorization: .unrecognized, showsBanners: true, listsInNotificationCenter: true)
}
