@testable import CellKeeperKit
import CellKeeperCore
import Foundation
import Testing
import UserNotifications

/// How the system's notification settings map to Core's permission. Nothing
/// here touches the notification center, which needs an app bundle.
@Suite("System notification poster")
struct SystemNotificationPosterTests {
    @Test("Each authorization maps to its own, and an unknown one to unrecognized", arguments: [
        (UNAuthorizationStatus.notDetermined, NotificationPermission.Authorization.notDetermined),
        (.denied, .denied),
        (.authorized, .authorized),
        (.provisional, .provisional),
        (UNAuthorizationStatus(rawValue: 99) ?? .denied, .unrecognized),
    ])
    func authorization(status: UNAuthorizationStatus, expected: NotificationPermission.Authorization) {
        let permission = SystemNotificationPoster.permission(authorization: status, alertSetting: .enabled, alertStyle: .banner, notificationCenterSetting: .enabled)
        #expect(permission.authorization == expected)
    }

    @Test("Banners count only with alerts enabled and a style other than None; Notification Center only when listing there is enabled")
    func whereShown() {
        func permission(alert: UNNotificationSetting, style: UNAlertStyle, center: UNNotificationSetting) -> NotificationPermission {
            SystemNotificationPoster.permission(authorization: .authorized, alertSetting: alert, alertStyle: style, notificationCenterSetting: center)
        }
        #expect(permission(alert: .enabled, style: .banner, center: .enabled) == NotificationPermission(authorization: .authorized, showsBanners: true, listsInNotificationCenter: true))
        #expect(permission(alert: .enabled, style: .alert, center: .disabled).showsBanners)
        #expect(!permission(alert: .enabled, style: .none, center: .enabled).showsBanners)
        #expect(!permission(alert: .disabled, style: .banner, center: .enabled).showsBanners)
        #expect(!permission(alert: .notSupported, style: .banner, center: .enabled).showsBanners)
        #expect(permission(alert: .enabled, style: .none, center: .enabled).isShown)
        // Allowed, but shown nowhere: not shown.
        #expect(!permission(alert: .enabled, style: .none, center: .disabled).isShown)
        #expect(!permission(alert: .disabled, style: .banner, center: .notSupported).isShown)
    }

    @Test("A failure keeps only the error's numeric code, never its description")
    func errorCodeOnly() {
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "failed at /Users/someone/Library serial C02TESTSERIAL"])
        #expect(SystemNotificationPoster.errorCode(error) == 7)
        #expect(SystemNotificationPoster.errorCode(UNError(.notificationsNotAllowed)) == UNError.Code.notificationsNotAllowed.rawValue)
    }

    @Test("The Notifications pane opens through System Settings' URL scheme")
    func settingsLink() {
        #expect(NotificationSettingsLink.notificationsPane.scheme == "x-apple.systempreferences")
        #expect(NotificationSettingsLink.notificationsPane.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
