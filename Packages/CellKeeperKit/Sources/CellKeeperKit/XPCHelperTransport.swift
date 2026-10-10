import CellKeeperCore
import CellKeeperHelperCore
import CellKeeperHelperXPC
import Foundation

/// Connects to CellKeeper's helper daemon over NSXPC: each connection is a
/// ``HelperXPCClient`` with the code-signing requirement CellKeeper places
/// on the helper.
///
/// A connection throws a ``HelperTransportError`` when the transport fails
/// (interrupted, invalidated, a helper that does not meet the requirement, a
/// reply that did not arrive in time or cannot be read); the helper's
/// refusals stay reply statuses. After a failure the connection is
/// unusable, and ``HelperChargingBackend`` connects again and reads the
/// state afresh. A reply with a status this version does not know is such
/// a failure, never read as `ok`.
///
/// Not used by the app yet: the daemon is not registered (roadmap
/// milestone 4, phase 4b).
public struct XPCHelperTransport: HelperTransport {
    public let destination: HelperXPCClient.Destination
    public let helperRequirement: HelperCodeSigningRequirement
    public let timeout: Duration

    /// - Parameters:
    ///   - destination: the daemon's Mach service, or an anonymous
    ///     listener's endpoint in tests.
    ///   - helperRequirement: what the helper's code signature must satisfy:
    ///     ``HelperCodeSigningRequirement/forHelper(identifier:)``.
    ///   - timeout: how long each request waits for its reply.
    public init(
        destination: HelperXPCClient.Destination,
        helperRequirement: HelperCodeSigningRequirement,
        timeout: Duration = HelperXPCClient.defaultTimeout
    ) {
        self.destination = destination
        self.helperRequirement = helperRequirement
        self.timeout = timeout
    }

    /// A new connection. Nothing is sent until its first request, so a
    /// helper that cannot be reached makes that request throw.
    public func connect() async throws -> any HelperConnection {
        XPCHelperConnection(client: HelperXPCClient(destination: destination, helperRequirement: helperRequirement, timeout: timeout))
    }
}

/// One NSXPC connection to the helper, as a ``HelperConnection``.
struct XPCHelperConnection: HelperConnection {
    let client: HelperXPCClient

    func hello(clientProtocolVersion: Int) async throws -> HelperHelloReply {
        try await translated { try await client.hello(clientProtocolVersion: clientProtocolVersion) }
    }

    func readState() async throws -> HelperStateReply {
        try await translated { try await client.readState() }
    }

    func acquireOrRenewLease(control: Int, seconds: Int) async throws -> HelperLeaseReply {
        try await translated { try await client.acquireOrRenewLease(control: control, seconds: seconds) }
    }

    func releaseLease(control: Int) async throws -> HelperStatus {
        try await translated { try await client.releaseLease(control: control) }
    }

    func setControl(control: Int, active: Bool) async throws -> HelperStatus {
        try await translated { try await client.setControl(control: control, active: active) }
    }

    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64) async throws -> HelperStatus {
        try await translated {
            try await client.clearControlIfUnchanged(control: control, generation: generation, helperInstance: helperInstance)
        }
    }

    func restoreDefaults() async throws -> HelperStatus {
        try await translated { try await client.restoreDefaults() }
    }

    func restoreDefaultsAndExit() async throws -> HelperStatus {
        try await translated { try await client.restoreDefaultsAndExit() }
    }

    func invalidate() async {
        client.invalidate()
    }

    private func translated<Reply: Sendable>(_ request: () async throws -> Reply) async throws -> Reply {
        do {
            return try await request()
        } catch let error as HelperXPCError {
            throw HelperTransportError(error)
        }
    }
}

extension HelperTransportError {
    /// The transport error for an NSXPC failure.
    init(_ error: HelperXPCError) {
        switch error {
        case .interrupted: self = .interrupted
        case .invalidated: self = .invalidated
        case .requirementNotMet: self = .requirementNotMet
        case .timedOut: self = .timedOut
        case .malformedReply: self = .malformedReply
        }
    }
}
