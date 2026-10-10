import Foundation
import IOKit
import IOKit.pwr_mgt

/// A system sleep or wake, as the daemon receives it (R16, R17).
public enum SleepEvent: Sendable {
    /// The system is about to sleep. It waits until `acknowledge` is called
    /// (macOS waits up to 30 s for an unacknowledged notification). Calling
    /// it more than once is harmless.
    case willSleep(acknowledge: @Sendable () -> Void)
    /// The system has woken and is fully powered on.
    case didWake
}

/// Delivers system sleep and wake to the daemon.
public protocol SleepNotifications: Sendable {
    /// Starts delivering events to `handler`, which must return promptly.
    /// Throws if the notifications cannot be registered.
    func start(_ handler: @escaping @Sendable (SleepEvent) -> Void) throws
    /// Stops delivering events. Harmless if not started.
    func stop()
}

public enum SleepNotificationError: Error, Sendable, CustomStringConvertible {
    case registrationFailed

    public var description: String {
        switch self {
        case .registrationFailed: "IORegisterForSystemPower did not register the daemon for sleep notifications"
        }
    }
}

/// Sleep and wake from the public `IORegisterForSystemPower` interface
/// (`IOPMLib.h`), delivered on a serial dispatch queue
/// (`IONotificationPortSetDispatchQueue`). It reads and writes nothing; it
/// only answers the system's power notifications.
///
/// - `kIOMessageCanSystemSleep` (idle sleep may begin): allowed at once with
///   `IOAllowPowerChange`. The daemon never vetoes sleep.
/// - `kIOMessageSystemWillSleep`: delivered as ``SleepEvent/willSleep(acknowledge:)``;
///   the acknowledgement calls `IOAllowPowerChange` for that notification.
///   The daemon acknowledges once the engine has run its sleep checks, or
///   after ``HelperDaemon/sleepAcknowledgementTimeout`` at the latest.
/// - `kIOMessageSystemHasPoweredOn`: delivered as ``SleepEvent/didWake``.
///
/// `IORegisterForSystemPower` does not report shutdown or restart; SIGTERM
/// is the shutdown hook (``TerminationSignals``).
public final class SystemSleepNotifications: SleepNotifications, @unchecked Sendable {
    /// The `IOMessage.h` values, which Swift cannot import because they are
    /// built with the `iokit_common_msg()` macro:
    /// `sys_iokit | sub_iokit_common | message`, where `sys_iokit` is
    /// `err_system(0x38)` (`0x38 << 26`) and `sub_iokit_common` is 0.
    static let canSystemSleep = iokitCommonMessage(0x270)
    static let systemWillSleep = iokitCommonMessage(0x280)
    static let systemHasPoweredOn = iokitCommonMessage(0x300)

    static func iokitCommonMessage(_ message: UInt32) -> UInt32 {
        (UInt32(0x38) & 0x3F) << 26 | message
    }

    private let queue = DispatchQueue(label: "io.github.saltedtan.CellKeeper.Helper.sleep")
    private let lock = NSLock()
    private var registration: Registration?

    public init() {}

    public func start(_ handler: @escaping @Sendable (SleepEvent) -> Void) throws {
        try lock.withLock {
            guard self.registration == nil else { return }
            let registration = Registration(handler: handler)
            // Balanced in `stop()`; the callback finds the registration
            // through it.
            let refcon = Unmanaged.passRetained(registration).toOpaque()
            var port: IONotificationPortRef?
            var notifier: io_object_t = 0
            let rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(messageType, notificationID: Int(bitPattern: messageArgument))
            }, &notifier)
            guard rootPort != 0, let port else {
                Unmanaged<Registration>.fromOpaque(refcon).release()
                throw SleepNotificationError.registrationFailed
            }
            registration.activate(rootPort: rootPort, port: port, notifier: notifier)
            // Notifications arrive only from here on, on `queue`.
            IONotificationPortSetDispatchQueue(port, queue)
            self.registration = registration
        }
    }

    public func stop() {
        lock.withLock {
            guard let registration else { return }
            self.registration = nil
            // On the queue, so that no callback is running while the
            // registration is torn down and released.
            queue.sync { registration.deactivate() }
            Unmanaged.passUnretained(registration).release()
        }
    }

    /// One registration's ports, and the handler its callbacks call.
    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private let handler: @Sendable (SleepEvent) -> Void
        private var rootPort: io_connect_t = 0
        private var port: IONotificationPortRef?
        private var notifier: io_object_t = 0

        init(handler: @escaping @Sendable (SleepEvent) -> Void) {
            self.handler = handler
        }

        func activate(rootPort: io_connect_t, port: IONotificationPortRef, notifier: io_object_t) {
            lock.withLock {
                self.rootPort = rootPort
                self.port = port
                self.notifier = notifier
            }
        }

        func deactivate() {
            lock.withLock {
                guard rootPort != 0 else { return }
                IODeregisterForSystemPower(&notifier)
                IOServiceClose(rootPort)
                if let port {
                    IONotificationPortDestroy(port)
                }
                rootPort = 0
                port = nil
            }
        }

        /// Answers a notification for this registration, unless it has
        /// been stopped since (the port would no longer be ours).
        private func allowPowerChange(_ notificationID: Int) {
            lock.withLock {
                guard rootPort != 0 else { return }
                _ = IOAllowPowerChange(rootPort, notificationID)
            }
        }

        func handle(_ messageType: UInt32, notificationID: Int) {
            switch messageType {
            case SystemSleepNotifications.canSystemSleep:
                allowPowerChange(notificationID)
            case SystemSleepNotifications.systemWillSleep:
                let once = OnceFlag()
                handler(.willSleep(acknowledge: { [self] in
                    if once.claim() {
                        allowPowerChange(notificationID)
                    }
                }))
            case SystemSleepNotifications.systemHasPoweredOn:
                handler(.didWake)
            default:
                break
            }
        }
    }
}

/// True for the first caller of ``claim()`` only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { isClaimed = true }
            return !isClaimed
        }
    }
}
