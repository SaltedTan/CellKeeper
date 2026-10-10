import Foundation

/// Why a call to the helper over NSXPC failed. Every one of them leaves the
/// ``HelperXPCClient`` unusable: it invalidates its connection, and every
/// later call throws ``invalidated``.
public enum HelperXPCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The connection was interrupted: the helper exited or crashed, or
    /// closed the connection (for example after revoking the session).
    case interrupted
    /// The connection is invalid: the helper could not be reached (not
    /// installed, not running, not allowed), the client was invalidated, or
    /// an earlier call failed.
    case invalidated
    /// The helper's code signature does not satisfy the requirement the
    /// client placed on it.
    case requirementNotMet
    /// No reply arrived within the call's timeout.
    case timedOut
    /// The reply could not be read: a status this version does not know, or
    /// a reply NSXPC could not decode.
    case malformedReply

    /// The error for an `NSError` that NSXPC reported for a call or a
    /// connection.
    public init(_ error: any Error) {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else {
            self = .invalidated
            return
        }
        switch error.code {
        case NSXPCConnectionInterrupted: self = .interrupted
        case NSXPCConnectionReplyInvalid: self = .malformedReply
        case NSXPCConnectionCodeSigningRequirementFailure: self = .requirementNotMet
        default: self = .invalidated
        }
    }

    public var description: String {
        switch self {
        case .interrupted: "the connection to the helper was interrupted"
        case .invalidated: "the connection to the helper is not valid"
        case .requirementNotMet: "the helper's code signature does not meet CellKeeper's requirement"
        case .timedOut: "the helper did not reply in time"
        case .malformedReply: "the helper's reply could not be read"
        }
    }
}
