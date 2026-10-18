import Foundation

/// What macOS allows for CellKeeper's notifications, as the system's
/// notification settings report them. Mirrors the parts of
/// `UNNotificationSettings` CellKeeper uses, so Core needs no
/// UserNotifications.
public struct NotificationPermission: Sendable, Equatable {
    public enum Authorization: Sendable, Equatable {
        /// macOS has not asked the user yet.
        case notDetermined
        case denied
        case authorized
        /// Delivered quietly to Notification Center (CellKeeper does not ask
        /// for this, but the user's settings may say so).
        case provisional
        /// A value this version does not know; nothing is assumed about it.
        case unrecognized
    }

    public var authorization: Authorization
    /// macOS shows them as banners or alerts.
    public var showsBanners: Bool
    /// macOS lists them in Notification Center.
    public var listsInNotificationCenter: Bool

    public init(authorization: Authorization, showsBanners: Bool, listsInNotificationCenter: Bool) {
        self.authorization = authorization
        self.showsBanners = showsBanners
        self.listsInNotificationCenter = listsInNotificationCenter
    }

    /// True if macOS shows CellKeeper's notifications somewhere: allowed,
    /// and shown as banners or listed in Notification Center.
    public var isShown: Bool {
        switch authorization {
        case .authorized, .provisional: showsBanners || listsInNotificationCenter
        case .notDetermined, .denied, .unrecognized: false
        }
    }
}

/// The user's opt-in to notifications and what macOS allows, as Settings
/// shows it. Off by default. The toggle is on only while the user has opted
/// in and macOS shows CellKeeper's notifications, so it never claims
/// notifications are on when macOS would not show them.
public struct NotificationOptIn: Sendable, Equatable {
    /// The user's choice, saved (``SettingsStore/loadNotificationsEnabled()``).
    public var isEnabled: Bool
    /// What macOS allowed when CellKeeper last asked; nil until it has
    /// asked. CellKeeper asks only while the user has opted in.
    public var permission: NotificationPermission?
    /// CellKeeper asked macOS for permission and is waiting for the answer
    /// (macOS shows its prompt only the first time).
    public var isRequesting: Bool
    /// CellKeeper asked macOS for permission in this session.
    public var hasRequested: Bool

    public init(isEnabled: Bool, permission: NotificationPermission? = nil, isRequesting: Bool = false, hasRequested: Bool = false) {
        self.isEnabled = isEnabled
        self.permission = permission
        self.isRequesting = isRequesting
        self.hasRequested = hasRequested
    }

    public enum State: Sendable, Equatable {
        /// The user has not opted in.
        case off
        /// Opted in; CellKeeper is reading what macOS allows.
        case checking
        /// Opted in; CellKeeper asked macOS and waits for the answer.
        case requesting
        /// Opted in, and macOS shows CellKeeper's notifications.
        case on
        /// Opted in, but macOS has not been asked in this session and has no
        /// answer recorded.
        case notAsked
        /// Opted in and asked, but macOS recorded no answer.
        case unanswered
        /// Opted in, but macOS does not allow CellKeeper's notifications.
        case denied
        /// Opted in and allowed, but macOS shows them nowhere: banners and
        /// Notification Center are both off for CellKeeper.
        case hiddenByMacOS
        /// Opted in, but macOS reports a permission this version does not
        /// know.
        case unrecognized
    }

    public var state: State {
        guard isEnabled else { return .off }
        if isRequesting { return .requesting }
        guard let permission else { return .checking }
        switch permission.authorization {
        case .notDetermined: return hasRequested ? .unanswered : .notAsked
        case .denied: return .denied
        case .unrecognized: return .unrecognized
        case .authorized, .provisional: return permission.isShown ? .on : .hiddenByMacOS
        }
    }

    /// What the toggle shows.
    public var isToggleOn: Bool {
        state == .on
    }

    /// Whether to hand notifications to macOS: opted in, unless the last
    /// answer showed that macOS would not show them. While the answer is
    /// still being read, notifications are handed over, and the poster
    /// checks the permission again before each one, so nothing at launch is
    /// lost to the order in which the first reads finish.
    public var isDelivering: Bool {
        guard isEnabled, !isRequesting else { return false }
        return permission?.isShown ?? true
    }

    /// Whether to offer withdrawing the saved opt-in while the toggle is
    /// off: the user opted in, but macOS does not show the notifications,
    /// has not been asked, has not answered, or its answer is still being
    /// read. The user can always withdraw it, whatever macOS allows;
    /// clicking the toggle would ask macOS again instead.
    public var offersWithdrawal: Bool {
        switch state {
        case .checking, .requesting, .notAsked, .unanswered, .denied, .hiddenByMacOS, .unrecognized: true
        case .off, .on: false
        }
    }

    /// Whether to offer opening System Settings › Notifications: macOS
    /// refuses, hides, or did not answer.
    public var offersSystemSettings: Bool {
        switch state {
        case .denied, .hiddenByMacOS, .unanswered, .unrecognized: true
        case .off, .checking, .requesting, .on, .notAsked: false
        }
    }

    /// One line under the toggle; nil when the toggle says it all.
    public var explanation: String? {
        switch state {
        case .off:
            return nil
        case .checking:
            return "Checking whether macOS shows CellKeeper's notifications…"
        case .requesting:
            return "Waiting for your answer to macOS's request to allow CellKeeper's notifications."
        case .on:
            guard let permission, !permission.showsBanners else { return nil }
            return "macOS lists CellKeeper's notifications in Notification Center without showing banners, as set in System Settings › Notifications."
        case .notAsked:
            return "You turned notifications on, but macOS has not been asked to allow them yet. Turn this on to ask."
        case .unanswered:
            return "You turned notifications on, but macOS recorded no answer, so it does not show them. Turn this on to ask again, or allow CellKeeper in System Settings › Notifications."
        case .denied:
            return "You turned notifications on, but macOS does not allow notifications from CellKeeper, so none are shown. To get them, allow CellKeeper in System Settings › Notifications."
        case .hiddenByMacOS:
            return "You turned notifications on, and macOS allows them but shows them nowhere: banners and Notification Center are both off for CellKeeper in System Settings › Notifications."
        case .unrecognized:
            return "You turned notifications on, but macOS reports a notification permission this version of CellKeeper does not recognise, so it does not count on them being shown. Check System Settings › Notifications."
        }
    }
}
