import Foundation

/// How the system reports the registration of CellKeeper's helper daemon.
///
/// The cases mirror `SMAppService.Status` (research note 04, §1.3) without
/// importing ServiceManagement, so the removal logic stays testable in
/// `CellKeeperCore`.
public enum HelperRegistrationStatus: Sendable, Equatable, CustomStringConvertible {
    /// No helper is registered.
    case notRegistered
    /// The helper is registered and approved; launchd may run it.
    case enabled
    /// The helper is registered, but the user must approve it in System
    /// Settings › General › Login Items & Extensions. Also reported after
    /// the user revoked an earlier approval.
    case requiresApproval
    /// The system cannot find the helper's service.
    case notFound
    /// A status this version does not know, or one that could not be read;
    /// the text says which.
    case unknown(String)

    /// True if the system reports no helper registered, so there is nothing
    /// to remove. Every other status, including `unknown`, may mean a helper
    /// that runs.
    public var meansNoHelperRegistered: Bool {
        switch self {
        case .notRegistered, .notFound: true
        case .enabled, .requiresApproval, .unknown: false
        }
    }

    public var description: String {
        switch self {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "registered, waiting for approval"
        case .notFound: "not found"
        case .unknown(let detail): "unknown (\(detail))"
        }
    }
}

/// The system's registration of CellKeeper's helper daemon: the seam
/// between the removal logic (``HelperRemoval``) and `SMAppService`.
///
/// Phase 4a has no registration: the only implementation is
/// `NoHelperRegistration` (CellKeeperKit), which always reports
/// ``HelperRegistrationStatus/notRegistered``, so the removal flow stops
/// before it contacts any helper. Phase 4b (issue #57) supplies an
/// implementation on `SMAppService.daemon(plistName:)`:
///
/// - ``status()`` maps `.notRegistered`, `.enabled`, `.requiresApproval`
///   and `.notFound`, and anything else to ``HelperRegistrationStatus/unknown(_:)``.
/// - ``unregister()`` calls `unregister()`, which also terminates a running
///   daemon (research note 04, §1.4); the daemon's SIGTERM path then
///   attempts to restore defaults before it exits, and may exit at its
///   deadline without confirming them (decision D31). It must bound its own
///   completion and clean-up: ``HelperRemoval`` stops waiting at its
///   deadline but cannot stop a call that ignores cancellation. An error
///   that means the
///   helper is already unregistered, `kSMErrorJobNotFound`, and the EPERM
///   that macOS 26 is reported (unverified) to return instead, is treated
///   as already gone: ``unregister()`` returns normally. Any other error is
///   thrown.
///
/// Implementations must not block indefinitely. ``HelperRemoval`` bounds
/// how long it waits for every call, not the call itself.
public protocol HelperRegistration: Sendable {
    /// The helper's registration as the system reports it now.
    func status() async -> HelperRegistrationStatus
    /// Unregisters the helper. ``HelperRemoval`` calls it only after the
    /// helper confirmed that it restored defaults, or for a forced removal
    /// when nothing confirmed the restore because the transport failed or
    /// no reply arrived in time, at any stage (connecting, `hello`, the
    /// restore). An explicit reply to the restore request other than `ok`
    /// is never overridden: the helper is then not unregistered, forced or
    /// not. (A `hello` refused with a status does not count: the restore
    /// request is still sent, and may confirm.)
    func unregister() async throws
}
