import notify
import Dispatch
import IOKit.ps

/// Power-source change notifications via notify(3), as recommended by
/// `IOPowerSources.h`.
enum PowerSourceNotifications {
    /// The public notification names observed: power-source switches,
    /// time-remaining/percentage changes, and any attribute change (which the
    /// driver posts on each refresh). Registering all three keeps working if
    /// the cadence of any one of them changes.
    static let names = [kIOPSNotifyPowerSource, kIOPSNotifyTimeRemaining, kIOPSNotifyAnyPowerSource]

    /// Yields whenever any of ``names`` is posted. Bursts are coalesced.
    /// Cancelling the consuming task unregisters the observers.
    static func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let queue = DispatchQueue(label: "CellKeeper.PowerSourceNotifications", qos: .utility)
            var tokens: [Int32] = []
            for name in names {
                var token: Int32 = NOTIFY_TOKEN_INVALID
                let status = notify_register_dispatch(name, &token, queue) { _ in
                    continuation.yield()
                }
                if status == UInt32(NOTIFY_STATUS_OK) {
                    tokens.append(token)
                }
            }
            guard !tokens.isEmpty else {
                continuation.finish()
                return
            }
            let registeredTokens = tokens
            continuation.onTermination = { _ in
                for token in registeredTokens {
                    notify_cancel(token)
                }
            }
        }
    }
}
