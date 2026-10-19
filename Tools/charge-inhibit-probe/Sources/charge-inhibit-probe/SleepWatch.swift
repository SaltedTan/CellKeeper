import Foundation
import IOKit
import IOKit.pwr_mgt
import ProbeCore

/// System sleep notifications for the run, from the public
/// `IORegisterForSystemPower` interface (`IOPMLib.h`), delivered on a
/// serial dispatch queue (`IONotificationPortSetDispatchQueue`), as the
/// helper daemon's `SystemSleepNotifications` does. In Apple's published
/// IOKitUser source, `IORegisterForSystemPower` opens a connection to the
/// power-management root domain (`IOPMrootDomain`) to receive these
/// notifications and to answer them with `IOAllowPowerChange`; it is not
/// the battery manager's or the SMC's user client (research note 10 §4).
///
/// - `kIOMessageSystemWillSleep`: `onWillSleep` decides
///   (`SleepResponse.willSleep`): the run latches its stop and releases the
///   private assertion, and calls the acknowledgement it is given only once
///   the assertion is released; if the release fails, it exits without
///   acknowledging. Without a handler, the sleep is allowed.
/// - `kIOMessageCanSystemSleep`: allowed at once; the idle-sleep assertion
///   already covers idle sleep, and the probe does not fight a forced one.
/// - `kIOMessageSystemHasPoweredOn`: recorded.
///
/// Every notification is recorded, and any makes the run inconclusive.
final class SleepWatch: @unchecked Sendable {
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

    private let clock: Clock
    private let queue = DispatchQueue(label: "charge-inhibit-probe.sleep")
    private let lock = NSLock()
    private var onWillSleep: (@Sendable (_ acknowledge: () -> Void) -> Void)?
    private var rootPort: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var received: [ProbeRun.SleepNotice] = []

    init(clock: Clock) {
        self.clock = clock
    }

    /// Registers for sleep notifications; returns false if
    /// `IORegisterForSystemPower` did not register the probe. `onWillSleep`
    /// runs on the notification queue and is given the acknowledgement
    /// (`IOAllowPowerChange`) to call, or not.
    func start(onWillSleep: @escaping @Sendable (_ acknowledge: () -> Void) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard rootPort == 0 else { return true }
        self.onWillSleep = onWillSleep
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var newPort: IONotificationPortRef?
        var newNotifier: io_object_t = 0
        let newRoot = IORegisterForSystemPower(refcon, &newPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<SleepWatch>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType, notificationID: Int(bitPattern: messageArgument))
        }, &newNotifier)
        guard newRoot != 0, let newPort else { return false }
        rootPort = newRoot
        port = newPort
        notifier = newNotifier
        // Notifications arrive only from here on, on `queue`.
        IONotificationPortSetDispatchQueue(newPort, queue)
        return true
    }

    /// Deregisters. Harmless if not registered. The probe keeps the watch
    /// alive until this has returned.
    func stop() {
        // On the queue, so that no callback is running while the ports are
        // torn down.
        queue.sync {
            lock.lock()
            defer { lock.unlock() }
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

    /// The notifications received so far.
    var notices: [ProbeRun.SleepNotice] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private func record(_ message: String) {
        lock.lock()
        received.append(ProbeRun.SleepNotice(time: clock.now, message: message))
        lock.unlock()
    }

    private func allowPowerChange(_ notificationID: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard rootPort != 0 else { return }
        _ = IOAllowPowerChange(rootPort, notificationID)
    }

    private func handle(_ messageType: UInt32, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            record("kIOMessageCanSystemSleep")
            allowPowerChange(notificationID)
        case Self.systemWillSleep:
            record("kIOMessageSystemWillSleep")
            lock.lock()
            let handler = onWillSleep
            lock.unlock()
            if let handler {
                handler { allowPowerChange(notificationID) }
            } else {
                allowPowerChange(notificationID)
            }
        case Self.systemHasPoweredOn:
            record("kIOMessageSystemHasPoweredOn")
        default:
            break
        }
    }
}
