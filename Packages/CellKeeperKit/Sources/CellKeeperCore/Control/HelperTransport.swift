import CellKeeperHelperCore
import Foundation

/// One client connection to CellKeeper's helper: the operations of a
/// ``HelperSession``, with the same primitive arguments and replies.
///
/// A method throws only when the transport fails (for NSXPC: the connection
/// was interrupted or invalidated, or a reply did not arrive in time). The
/// helper's own refusals are reply statuses, not errors. After a transport
/// failure the connection is unusable: the client invalidates it and
/// connects again, and the helper has already ended the old session and
/// cleared what it held.
public protocol HelperConnection: Sendable {
    func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply
    func readState() async throws -> HelperStateReply
    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply
    func releaseLease(control: Int) async throws -> HelperStatus
    func setControl(control: Int, active: Bool) async throws -> HelperStatus
    func restoreDefaults() async throws -> HelperStatus
    func restoreDefaultsAndExit() async throws -> HelperStatus
    /// Ends the connection. The helper invalidates the session, which clears
    /// every control it holds. Never throws; calling it twice is harmless.
    func invalidate() async
}

/// Opens connections to CellKeeper's helper: in process today
/// (``InProcessHelperTransport``), over NSXPC to the daemon later.
public protocol HelperTransport: Sendable {
    /// A new connection, not yet introduced with `hello`. Throws if the
    /// helper cannot be reached (not installed, not running, not allowed).
    func connect() async throws -> any HelperConnection
}

/// An in-process session is a connection whose transport never fails.
extension HelperSession: HelperConnection {}

/// Runs a ``HelperEngine`` inside the app and connects to it directly.
///
/// This is what the helper daemon and its NSXPC listener will do, without
/// the process boundary: the engine is started (it restores defaults first)
/// before the first connection is served, ticked every `tickInterval` while
/// the transport exists, and told about sleep and wake by the app. Each
/// connection is a ``HelperSession``.
///
/// The ticking task holds the engine weakly and is cancelled when the
/// transport is released, so nothing keeps running after the backend that
/// owns the transport is gone.
public final class InProcessHelperTransport: HelperTransport {
    public let engine: HelperEngine
    private let ticker: Task<Void, Never>

    public init(engine: HelperEngine, tickInterval: Duration = .seconds(5)) {
        self.engine = engine
        ticker = Task { [weak engine] in
            await engine?.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled, let engine else { return }
                await engine.tick()
            }
        }
    }

    deinit {
        ticker.cancel()
    }

    public func connect() async throws -> any HelperConnection {
        // Idempotent: the engine restores defaults before serving anything.
        await engine.start()
        return await engine.openSession()
    }

    /// Forwards the system's sleep announcement (rule R16).
    public func systemWillSleep() async {
        await engine.systemWillSleep()
    }

    /// Forwards the system's wake (rule R17).
    public func systemDidWake() async {
        await engine.systemDidWake()
    }
}
