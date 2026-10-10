import Dispatch
import Foundation

/// Delivers the request to terminate (SIGTERM, from launchd at shutdown,
/// at unregistration, or from `launchctl`) to the daemon (R4).
public protocol TerminationSignals: Sendable {
    /// From now on, SIGTERM no longer ends the process; `handler` is called
    /// instead, once per signal, and must return promptly.
    func start(_ handler: @escaping @Sendable () -> Void)
    /// Stops calling the handler. SIGTERM stays ignored, so a late signal
    /// cannot end the process before it exits on its own.
    func stop()
}

/// SIGTERM through a dispatch signal source, with the signal's default
/// action disabled (`signal(SIGTERM, SIG_IGN)`), as `DispatchSource`
/// requires.
public final class SystemTerminationSignals: TerminationSignals, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.saltedtan.CellKeeper.Helper.signals")
    private let lock = NSLock()
    private var source: (any DispatchSourceSignal)?

    public init() {}

    public func start(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard source == nil else { return }
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            self.source = source
        }
    }

    public func stop() {
        lock.withLock {
            source?.cancel()
            source = nil
        }
    }
}
