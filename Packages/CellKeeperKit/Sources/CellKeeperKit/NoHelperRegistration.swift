import CellKeeperCore

/// The helper's registration in phase 4a: there is none.
///
/// CellKeeper registers no launchd job and no `SMAppService` item in this
/// phase, so ``status()`` always reports
/// ``HelperRegistrationStatus/notRegistered``, and ``HelperRemoval`` stops
/// there without contacting any helper. ``unregister()`` does nothing; the
/// removal flow never reaches it with this registration. Nothing here calls
/// `SMAppService`.
///
/// Phase 4b (issue #57) replaces it with an implementation on
/// `SMAppService.daemon(plistName:)`; see ``HelperRegistration`` for what
/// that implementation must do.
public struct NoHelperRegistration: HelperRegistration {
    public init() {}

    public func status() async -> HelperRegistrationStatus {
        .notRegistered
    }

    public func unregister() async throws {}
}
