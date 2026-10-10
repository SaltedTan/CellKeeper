import CellKeeperHelperCore
import Foundation

// The NSXPC interface between CellKeeper and its helper daemon.
//
// One method per helper request (``HelperSession``), each with only `Int`,
// `UInt64` and `Bool` arguments and a single reply block of the same
// primitives, so nothing but numbers crosses the wire: no strings,
// collections, archived objects or `NSSecureCoding` classes, and nothing an
// attacker could use to make the helper decode an object. Raw values cross
// unchanged; the helper's engine validates every argument, and the client
// validates every reply (``HelperXPCWire``).

/// The reply to `hello`: the fields of ``HelperHelloReply``, in order.
public typealias HelperXPCHelloReplyBlock = @Sendable (
    _ status: Int,
    _ helperProtocolVersion: Int,
    _ build: Int,
    _ capabilities: UInt64,
    _ isSimulated: Bool,
    _ sessionID: UInt64,
    _ helperInstance: UInt64
) -> Void

/// The reply to `readState`: the fields of ``HelperStateReply``, in order.
public typealias HelperXPCStateReplyBlock = @Sendable (
    _ status: Int,
    _ activeControls: UInt64,
    _ chargingInhibitedLeaseSeconds: Int,
    _ adapterDisabledLeaseSeconds: Int,
    _ isLeaseHolder: Bool,
    _ interlocks: UInt64,
    _ lastHardwareError: Int,
    _ hardwareErrorCount: Int,
    _ chargingInhibitedGeneration: UInt64,
    _ chargingInhibitedChangeCause: Int,
    _ chargingInhibitedChangeInterlocks: UInt64,
    _ chargingInhibitedChangeSession: UInt64,
    _ adapterDisabledGeneration: UInt64,
    _ adapterDisabledChangeCause: Int,
    _ adapterDisabledChangeInterlocks: UInt64,
    _ adapterDisabledChangeSession: UInt64
) -> Void

/// The reply to `acquireOrRenewLease`: the fields of ``HelperLeaseReply``.
public typealias HelperXPCLeaseReplyBlock = @Sendable (_ status: Int, _ grantedSeconds: Int) -> Void

/// A reply that is only a raw ``HelperStatus``.
public typealias HelperXPCStatusReplyBlock = @Sendable (_ status: Int) -> Void

/// The helper's NSXPC interface: the requests of ``HelperSession``, with the
/// same raw arguments. Each connection is one session; see ``HelperSession``
/// for what each request does and when the helper refuses it.
@objc(CellKeeperHelperXPCProtocol)
public protocol CellKeeperHelperXPCProtocol {
    func hello(clientProtocolVersion: Int, reply: @escaping HelperXPCHelloReplyBlock)
    func readState(reply: @escaping HelperXPCStateReplyBlock)
    func acquireOrRenewLease(control: Int, seconds: Int, reply: @escaping HelperXPCLeaseReplyBlock)
    func releaseLease(control: Int, reply: @escaping HelperXPCStatusReplyBlock)
    func setControl(control: Int, active: Bool, reply: @escaping HelperXPCStatusReplyBlock)
    func clearControlIfUnchanged(control: Int, generation: UInt64, helperInstance: UInt64, reply: @escaping HelperXPCStatusReplyBlock)
    func restoreDefaults(reply: @escaping HelperXPCStatusReplyBlock)
    func restoreDefaultsAndExit(reply: @escaping HelperXPCStatusReplyBlock)
}

public enum HelperXPCInterface {
    /// The interface both sides use. Every argument and reply field is a
    /// primitive, so no classes need to be allowed for decoding.
    public static func make() -> NSXPCInterface {
        NSXPCInterface(with: CellKeeperHelperXPCProtocol.self)
    }
}

/// Converts the helper's replies to and from their primitive wire fields.
public enum HelperXPCWire {
    // MARK: Helper side: a reply into its block

    public static func send(_ reply: HelperHelloReply, to block: HelperXPCHelloReplyBlock) {
        block(
            reply.status.rawValue,
            reply.helperProtocolVersion,
            reply.build,
            reply.capabilities.rawValue,
            reply.isSimulated,
            reply.sessionID,
            reply.helperInstance
        )
    }

    public static func send(_ reply: HelperStateReply, to block: HelperXPCStateReplyBlock) {
        block(
            reply.status.rawValue,
            reply.activeControls.rawValue,
            reply.chargingInhibitedLeaseSeconds,
            reply.adapterDisabledLeaseSeconds,
            reply.isLeaseHolder,
            reply.interlocks.rawValue,
            reply.lastHardwareError,
            reply.hardwareErrorCount,
            reply.chargingInhibitedGeneration,
            reply.chargingInhibitedChangeCause,
            reply.chargingInhibitedChangeInterlocks.rawValue,
            reply.chargingInhibitedChangeSession,
            reply.adapterDisabledGeneration,
            reply.adapterDisabledChangeCause,
            reply.adapterDisabledChangeInterlocks.rawValue,
            reply.adapterDisabledChangeSession
        )
    }

    public static func send(_ reply: HelperLeaseReply, to block: HelperXPCLeaseReplyBlock) {
        block(reply.status.rawValue, reply.grantedSeconds)
    }

    public static func send(_ status: HelperStatus, to block: HelperXPCStatusReplyBlock) {
        block(status.rawValue)
    }

    // MARK: Client side: wire fields into a reply

    /// A status this version knows; any other raw value is a reply the
    /// client cannot interpret, never guessed as `ok` or any other status.
    public static func status(_ raw: Int) throws -> HelperStatus {
        guard let status = HelperStatus(rawValue: raw) else { throw HelperXPCError.malformedReply }
        return status
    }

    public static func helloReply(
        status: Int,
        helperProtocolVersion: Int,
        build: Int,
        capabilities: UInt64,
        isSimulated: Bool,
        sessionID: UInt64,
        helperInstance: UInt64
    ) throws -> HelperHelloReply {
        HelperHelloReply(
            status: try Self.status(status),
            helperProtocolVersion: helperProtocolVersion,
            build: build,
            capabilities: HelperCapabilities(rawValue: capabilities),
            isSimulated: isSimulated,
            sessionID: sessionID,
            helperInstance: helperInstance
        )
    }

    // The field order is the wire format: keep it in step with
    // ``HelperXPCStateReplyBlock`` and `send(_:to:)` above.
    public static func stateReply(
        status: Int,
        activeControls: UInt64,
        chargingInhibitedLeaseSeconds: Int,
        adapterDisabledLeaseSeconds: Int,
        isLeaseHolder: Bool,
        interlocks: UInt64,
        lastHardwareError: Int,
        hardwareErrorCount: Int,
        chargingInhibitedGeneration: UInt64,
        chargingInhibitedChangeCause: Int,
        chargingInhibitedChangeInterlocks: UInt64,
        chargingInhibitedChangeSession: UInt64,
        adapterDisabledGeneration: UInt64,
        adapterDisabledChangeCause: Int,
        adapterDisabledChangeInterlocks: UInt64,
        adapterDisabledChangeSession: UInt64
    ) throws -> HelperStateReply {
        // The raw cause is kept as it came: `HelperStateReply.change(for:)`
        // reads a cause this version does not know as nil, which a client
        // never mistakes for one of its own changes.
        var reply = HelperStateReply(
            status: try Self.status(status),
            activeControls: HelperControlSet(rawValue: activeControls),
            chargingInhibitedLeaseSeconds: chargingInhibitedLeaseSeconds,
            adapterDisabledLeaseSeconds: adapterDisabledLeaseSeconds,
            isLeaseHolder: isLeaseHolder,
            interlocks: HelperInterlocks(rawValue: interlocks),
            lastHardwareError: lastHardwareError,
            hardwareErrorCount: hardwareErrorCount,
            chargingInhibitedChange: HelperControlChange(
                generation: chargingInhibitedGeneration,
                cause: nil,
                interlocks: HelperInterlocks(rawValue: chargingInhibitedChangeInterlocks),
                session: chargingInhibitedChangeSession
            ),
            adapterDisabledChange: HelperControlChange(
                generation: adapterDisabledGeneration,
                cause: nil,
                interlocks: HelperInterlocks(rawValue: adapterDisabledChangeInterlocks),
                session: adapterDisabledChangeSession
            )
        )
        reply.chargingInhibitedChangeCause = chargingInhibitedChangeCause
        reply.adapterDisabledChangeCause = adapterDisabledChangeCause
        return reply
    }

    public static func leaseReply(status: Int, grantedSeconds: Int) throws -> HelperLeaseReply {
        HelperLeaseReply(status: try Self.status(status), grantedSeconds: grantedSeconds)
    }
}
