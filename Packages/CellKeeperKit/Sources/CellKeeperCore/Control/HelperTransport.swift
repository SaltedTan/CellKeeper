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
    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus
    func restoreDefaults() async throws -> HelperStatus
    func restoreDefaultsAndExit() async throws -> HelperStatus
    /// Ends the connection. The helper invalidates the session, which clears
    /// every control it holds. Never throws; calling it twice is harmless.
    func invalidate() async
}

/// Opens connections to CellKeeper's helper: in process
/// (``InProcessHelperTransport``, the Simulated helper), or over NSXPC to
/// the daemon (`XPCHelperTransport` in CellKeeperKit, not used by the app
/// until the daemon is registered).
public protocol HelperTransport: Sendable {
    /// A new connection, not yet introduced with `hello`. Throws if the
    /// helper cannot be reached (not installed, not running, not allowed).
    func connect() async throws -> any HelperConnection
}

/// A session used directly is a connection whose transport never fails.
extension HelperSession: HelperConnection {}

/// Why a transport ended a connection. Any of them leaves the connection
/// unusable.
public enum HelperTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The helper revoked the session for exceeding its request budget, and
    /// the transport closed the connection.
    case sessionRevoked
    /// The connection was interrupted: the helper exited or crashed, or
    /// closed the connection.
    case interrupted
    /// The connection is not valid: the helper could not be reached (not
    /// installed, not running, not allowed), or the connection was closed
    /// after an earlier failure.
    case invalidated
    /// The helper's code signature does not satisfy the requirement
    /// CellKeeper places on it.
    case requirementNotMet
    /// The helper did not reply in time.
    case timedOut
    /// The helper's reply could not be read, for example a status this
    /// version does not know.
    case malformedReply

    public var description: String {
        switch self {
        case .sessionRevoked: "the helper revoked the session and the connection was closed"
        case .interrupted: "the connection to the helper was interrupted"
        case .invalidated: "the connection to the helper is not valid"
        case .requirementNotMet: "the helper's code signature does not meet CellKeeper's requirement"
        case .timedOut: "the helper did not reply in time"
        case .malformedReply: "the helper's reply could not be read"
        }
    }
}

/// Runs a ``HelperEngine`` inside the app and connects to it directly.
///
/// This is what the helper daemon and its NSXPC listener will do, without
/// the process boundary: the engine is started (it restores defaults first)
/// before the first connection is served, ticked every `tickInterval` while
/// the transport exists, and told about sleep and wake by the app. When the
/// engine revokes a session (``HelperEvent/sessionRevoked(_:)``), the
/// transport closes that connection: every later request on it, and the
/// request that caused the revocation, throws
/// ``HelperTransportError/sessionRevoked``, as a closed NSXPC connection
/// would. The engine delivers an operation's events when it ends, before
/// the call returns, so the revoking request sees its own revocation; this
/// holds as long as `events` does not call back into the engine.
///
/// The ticking task holds the engine weakly and is cancelled when the
/// transport is released, so nothing keeps running after the backend that
/// owns the transport is gone.
public final class InProcessHelperTransport: HelperTransport {
    public let engine: HelperEngine
    private let revoked: RevokedSessions
    private let ticker: Task<Void, Never>

    /// Builds the engine, so the transport sees the sessions it revokes.
    /// The parameters are ``HelperEngine``'s; `events` receives every event
    /// as well.
    public init(
        control: any HelperChargeControl,
        power: any HelperPowerReading,
        build: Int,
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime,
        activationHistory: [HelperActivationRecord] = [],
        tickInterval: Duration = .seconds(5),
        events: @escaping @Sendable (HelperEvent) -> Void = { _ in }
    ) {
        let revoked = RevokedSessions()
        let engine = HelperEngine(
            control: control,
            power: power,
            build: build,
            uptime: uptime,
            activationHistory: activationHistory,
            events: { event in
                if case .sessionRevoked(let id) = event {
                    revoked.insert(id)
                }
                events(event)
            }
        )
        self.engine = engine
        self.revoked = revoked
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
        return InProcessHelperConnection(session: await engine.openSession(), revoked: revoked)
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

/// The sessions an in-process engine revoked.
final class RevokedSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<HelperSessionID> = []

    func insert(_ id: HelperSessionID) {
        lock.withLock { _ = ids.insert(id) }
    }

    func contains(_ id: HelperSessionID) -> Bool {
        lock.withLock { ids.contains(id) }
    }
}

/// A connection to an in-process engine, closed once the engine revokes its
/// session.
struct InProcessHelperConnection: HelperConnection {
    let session: HelperSession
    let revoked: RevokedSessions

    /// Runs `request` unless the connection is closed, and closes it if the
    /// request got the session revoked.
    private func ifOpen<Reply: Sendable>(_ request: @Sendable (HelperSession) async -> Reply) async throws -> Reply {
        guard !revoked.contains(session.id) else { throw HelperTransportError.sessionRevoked }
        let reply = await request(session)
        guard !revoked.contains(session.id) else { throw HelperTransportError.sessionRevoked }
        return reply
    }

    func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply {
        try await ifOpen { await $0.hello(clientProtocolVersion: clientProtocolVersion) }
    }

    func readState() async throws -> HelperStateReply {
        try await ifOpen { await $0.readState() }
    }

    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await ifOpen { await $0.acquireOrRenewLease(control: control, seconds: seconds) }
    }

    func releaseLease(control: Int) async throws -> HelperStatus {
        try await ifOpen { await $0.releaseLease(control: control) }
    }

    func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        try await ifOpen { await $0.setControl(control: control, active: active) }
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus {
        try await ifOpen { await $0.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance) }
    }

    func restoreDefaults() async throws -> HelperStatus {
        try await ifOpen { await $0.restoreDefaults() }
    }

    func restoreDefaultsAndExit() async throws -> HelperStatus {
        try await ifOpen { await $0.restoreDefaultsAndExit() }
    }

    func invalidate() async {
        await session.invalidate()
    }
}
