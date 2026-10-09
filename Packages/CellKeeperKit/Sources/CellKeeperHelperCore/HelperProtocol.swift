import Foundation

// The vocabulary shared by the app and the privileged helper.
//
// Raw values are the wire format: they never change, and a retired value is
// never reused. Every argument and reply field is an `Int`, `UInt64` or
// `Bool` (or a type whose raw value is one), so each request and reply maps
// one to one onto an NSXPC method with primitive arguments and a single
// reply block. No strings, collections or archived objects cross the wire.

/// Versions of the helper protocol. A breaking change bumps ``current``.
public enum HelperProtocolVersion {
    /// The version this helper speaks.
    public static let current = 1
    /// The oldest client version this helper still serves.
    public static let minimumSupportedClient = 1

    /// True if a client speaking `version` may use this helper.
    public static func isSupported(client version: Int) -> Bool {
        (minimumSupportedClient...current).contains(version)
    }
}

/// The controls the helper can set. The client says what, never how: the
/// mechanism behind each control is compiled into the helper.
public enum HelperControl: Int, Sendable, CaseIterable, Codable, CustomStringConvertible {
    /// External power runs the Mac; battery charging is inhibited.
    case chargingInhibited = 1
    /// The Mac runs from the battery although an adapter is connected.
    case adapterDisabled = 2

    /// The longest lease the helper grants for this control (research rule
    /// R3). A longer request is clamped to it.
    public var maximumLeaseSeconds: Int {
        switch self {
        case .chargingInhibited: 900
        case .adapterDisabled: 120
        }
    }

    /// The capability the helper must report before it accepts the control.
    public var requiredCapability: HelperCapabilities {
        switch self {
        case .chargingInhibited: .chargingInhibit
        case .adapterDisabled: .adapterDisable
        }
    }

    /// The interlocks that clear this control and refuse its activation.
    public var blockingInterlocks: HelperInterlocks {
        let always: HelperInterlocks = [.belowBatteryFloor, .powerStateUnavailable, .externalModification, .hardwareFault, .writeFailed]
        switch self {
        case .chargingInhibited:
            return always.union(.notOnExternalPower)
        case .adapterDisabled:
            // Not `notOnExternalPower`: cutting the adapter makes the Mac
            // report battery power. Physical presence decides instead.
            return always.union([.belowAdapterFloor, .adapterAbsent, .adapterPresenceUnknown, .thermalPressure, .sleepImminent])
        }
    }

    public var description: String {
        switch self {
        case .chargingInhibited: "chargingInhibited"
        case .adapterDisabled: "adapterDisabled"
        }
    }
}

/// A set of controls on the wire: bit `1 << control.rawValue`.
public struct HelperControlSet: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ control: HelperControl) {
        self.init(rawValue: 1 << UInt64(control.rawValue))
    }

    public init(controls: some Sequence<HelperControl>) {
        self.init(rawValue: controls.reduce(0) { $0 | HelperControlSet($1).rawValue })
    }

    public static let chargingInhibited = HelperControlSet(rawValue: 1 << 1)
    public static let adapterDisabled = HelperControlSet(rawValue: 1 << 2)

    /// The known controls in the set. Bits this version does not know are
    /// kept in ``rawValue`` but not listed.
    public var controls: Set<HelperControl> {
        Set(HelperControl.allCases.filter { contains(HelperControlSet($0)) })
    }

    public var description: String {
        "[" + HelperControl.allCases.filter { controls.contains($0) }.map(\.description).joined(separator: ", ") + "]"
    }
}

/// What the helper can do on this Mac. Computed by the helper alone, from
/// its compiled-in allowlist; a client can never add a capability. Empty
/// means monitor-only (research rule R12a).
public struct HelperCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let chargingInhibit = HelperCapabilities(rawValue: 1 << 0)
    public static let adapterDisable = HelperCapabilities(rawValue: 1 << 1)
}

/// Conditions that hold controls cleared and refuse their activation. The
/// helper derives them from its own readings; they are reported, and a
/// client can never set or clear one directly.
/// ``HelperControl/blockingInterlocks`` says which ones affect which control.
public struct HelperInterlocks: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The charge fell to ``HelperEngine/batteryFloor`` and has not yet
    /// recovered to ``HelperEngine/batteryFloorExit`` (rule R5).
    public static let belowBatteryFloor = HelperInterlocks(rawValue: 1 << 0)
    /// The Mac is not running on external power (rule R18).
    public static let notOnExternalPower = HelperInterlocks(rawValue: 1 << 1)
    /// The charge fell to ``HelperEngine/adapterFloor`` and has not yet
    /// recovered to ``HelperEngine/adapterFloorExit``.
    public static let belowAdapterFloor = HelperInterlocks(rawValue: 1 << 2)
    /// No adapter is physically connected.
    public static let adapterAbsent = HelperInterlocks(rawValue: 1 << 3)
    /// Whether an adapter is physically connected is not known.
    public static let adapterPresenceUnknown = HelperInterlocks(rawValue: 1 << 4)
    /// macOS reports high thermal pressure (rule R21).
    public static let thermalPressure = HelperInterlocks(rawValue: 1 << 5)
    /// The power state could not be read, lacks the charge or the power
    /// source, or is older than ``HelperEngine/maximumPowerStateAge`` or
    /// than the last wake (rules R9, R17).
    public static let powerStateUnavailable = HelperInterlocks(rawValue: 1 << 6)
    /// The read-back differed from what the helper had set: another tool
    /// may be controlling charging (rule R27). Lasts until a client's
    /// restore of defaults reads back clean.
    public static let externalModification = HelperInterlocks(rawValue: 1 << 7)
    /// A restore of defaults is owed: one failed or did not read back clean.
    /// Lasts until a restore reads back clean; the engine retries it.
    public static let hardwareFault = HelperInterlocks(rawValue: 1 << 8)
    /// The system announced sleep and has not woken yet (rule R16).
    public static let sleepImminent = HelperInterlocks(rawValue: 1 << 9)
    /// A write to a control failed or read back wrong, so the control is not
    /// trusted (rule R11). Lasts until a client's restore of defaults reads
    /// back clean, or ``HelperEngine/writeFailureBackoff`` after the last
    /// failure.
    public static let writeFailed = HelperInterlocks(rawValue: 1 << 10)

    private static let names: [(HelperInterlocks, String)] = [
        (.belowBatteryFloor, "belowBatteryFloor"),
        (.notOnExternalPower, "notOnExternalPower"),
        (.belowAdapterFloor, "belowAdapterFloor"),
        (.adapterAbsent, "adapterAbsent"),
        (.adapterPresenceUnknown, "adapterPresenceUnknown"),
        (.thermalPressure, "thermalPressure"),
        (.powerStateUnavailable, "powerStateUnavailable"),
        (.externalModification, "externalModification"),
        (.hardwareFault, "hardwareFault"),
        (.sleepImminent, "sleepImminent"),
        (.writeFailed, "writeFailed"),
    ]

    public var description: String {
        "[" + Self.names.filter { contains($0.0) }.map(\.1).joined(separator: ", ") + "]"
    }
}

/// The result of a request.
public enum HelperStatus: Int, Sendable, CaseIterable, CustomStringConvertible {
    case ok = 0
    /// The client's protocol version is outside the supported range.
    case incompatibleProtocol = 1
    /// The session has not completed `hello`, or no longer exists (it was
    /// invalidated or revoked).
    case notIntroduced = 2
    /// This Mac's helper cannot perform the control.
    case unsupportedControl = 3
    /// An unknown control, or a lease duration of zero or less.
    case invalidArgument = 4
    /// The session holds no valid lease for the control.
    case noLease = 5
    /// Another session holds a lease.
    case leaseHeldByOtherClient = 6
    /// The session's request budget or the control's activation limit is
    /// used up.
    case rateLimited = 7
    /// An interlock refuses the activation.
    case blockedByInterlock = 8
    /// A write, read-back or restore failed. Defaults were restored where
    /// possible.
    case hardwareError = 9
    /// The helper is shutting down and serves nothing more.
    case shuttingDown = 10
    /// The helper has not yet restored defaults at start.
    case notReady = 11
    /// For `clearControlIfUnchanged`: the control's latest change is not
    /// the one the client named (another generation, or another helper
    /// process). Nothing was written.
    case controlChanged = 12

    public var description: String {
        switch self {
        case .ok: "ok"
        case .incompatibleProtocol: "incompatibleProtocol"
        case .notIntroduced: "notIntroduced"
        case .unsupportedControl: "unsupportedControl"
        case .invalidArgument: "invalidArgument"
        case .noLease: "noLease"
        case .leaseHeldByOtherClient: "leaseHeldByOtherClient"
        case .rateLimited: "rateLimited"
        case .blockedByInterlock: "blockedByInterlock"
        case .hardwareError: "hardwareError"
        case .shuttingDown: "shuttingDown"
        case .notReady: "notReady"
        case .controlChanged: "controlChanged"
        }
    }
}

/// The reply to `hello`.
public struct HelperHelloReply: Sendable, Equatable {
    public var status: HelperStatus
    /// Always filled in, so a client can tell why it is incompatible.
    public var helperProtocolVersion: Int
    /// Always filled in; compared with the app's build to detect an update.
    public var build: Int
    /// Empty until the helper has started.
    public var capabilities: HelperCapabilities
    /// True if the helper's control is simulated and changes no hardware.
    public var isSimulated: Bool
    /// The calling session's number, as ``HelperControlChange/session``
    /// reports it, so a client recognises changes its own sessions made,
    /// also after reconnecting.
    public var sessionID: UInt64
    /// A random number fixed for the life of this helper process. A client
    /// that sees it change knows the helper restarted: generations and
    /// session numbers start again, and the start restored defaults.
    public var helperInstance: UInt64

    public init(
        status: HelperStatus,
        helperProtocolVersion: Int,
        build: Int,
        capabilities: HelperCapabilities,
        isSimulated: Bool,
        sessionID: UInt64,
        helperInstance: UInt64
    ) {
        self.status = status
        self.helperProtocolVersion = helperProtocolVersion
        self.build = build
        self.capabilities = capabilities
        self.isSimulated = isSimulated
        self.sessionID = sessionID
        self.helperInstance = helperInstance
    }
}

/// Why a control last turned on or off, as the helper saw it. Raw values are
/// the wire format; 0 means no change since the helper started. A lease
/// ending is not a change: what clears the control is.
public enum HelperChangeCause: Int, Sendable, Equatable, CaseIterable, CustomStringConvertible {
    /// A session activated it.
    case setByClient = 1
    /// A session deactivated it, or released its lease.
    case clearedByClient = 2
    /// A session's restore of defaults cleared it.
    case clearedByRestore = 3
    /// Its lease ran out.
    case leaseExpired = 4
    /// Interlocks cleared it; ``HelperControlChange/interlocks`` says which.
    case interlock = 5
    /// The lease holder's connection ended.
    case sessionEnded = 6
    /// The engine revoked the lease holder's session.
    case sessionRevoked = 7
    /// The restore of defaults at shutdown.
    case shutdown = 8
    /// The restore of defaults at start.
    case start = 9
    /// It changed without the engine writing it: another tool (rule R27).
    case changedOutside = 10
    /// The restore that follows an outside change.
    case restoredAfterOutsideChange = 11
    /// The restore that follows a failed or mismatched write (`writeFailed`).
    case restoredAfterWriteFailure = 12
    /// The restore that follows a read-back that failed.
    case restoredAfterReadBackFailure = 13
    /// A retry of a restore that was owed.
    case restoreRetried = 14
    /// The restore that follows an activation the activation limits refused.
    case activationLimited = 15

    public var description: String {
        switch self {
        case .setByClient: "setByClient"
        case .clearedByClient: "clearedByClient"
        case .clearedByRestore: "clearedByRestore"
        case .leaseExpired: "leaseExpired"
        case .interlock: "interlock"
        case .sessionEnded: "sessionEnded"
        case .sessionRevoked: "sessionRevoked"
        case .shutdown: "shutdown"
        case .start: "start"
        case .changedOutside: "changedOutside"
        case .restoredAfterOutsideChange: "restoredAfterOutsideChange"
        case .restoredAfterWriteFailure: "restoredAfterWriteFailure"
        case .restoredAfterReadBackFailure: "restoredAfterReadBackFailure"
        case .restoreRetried: "restoreRetried"
        case .activationLimited: "activationLimited"
        }
    }
}

/// The latest change of one control, from ``HelperStateReply``. Not on the
/// wire as such: the reply carries its four fields per control.
public struct HelperControlChange: Sendable, Equatable {
    /// How many times the control has turned on or off since the helper
    /// started. A client that recorded the generation of its own
    /// activation knows from it whether anything happened since.
    public var generation: UInt64
    /// Why it last changed; nil if it has not changed, or for a value this
    /// version does not know.
    public var cause: HelperChangeCause?
    /// For ``HelperChangeCause/interlock``, the interlocks that cleared it,
    /// as they were then.
    public var interlocks: HelperInterlocks
    /// The session that made the change (its ``HelperHelloReply/sessionID``),
    /// for the causes a session makes or ends; 0 for the engine's own changes
    /// and outside ones.
    public var session: UInt64

    public init(generation: UInt64, cause: HelperChangeCause?, interlocks: HelperInterlocks, session: UInt64) {
        self.generation = generation
        self.cause = cause
        self.interlocks = interlocks
        self.session = session
    }
}

/// The reply to `acquireOrRenewLease`.
public struct HelperLeaseReply: Sendable, Equatable {
    public var status: HelperStatus
    /// The duration granted after clamping; 0 unless `status` is `ok`.
    public var grantedSeconds: Int

    public init(status: HelperStatus, grantedSeconds: Int) {
        self.status = status
        self.grantedSeconds = grantedSeconds
    }
}

/// The reply to `readState`. Every field reports what the helper read or
/// knows, never what a client asked for.
public struct HelperStateReply: Sendable, Equatable {
    /// `ok` if the controls were read back; `hardwareError` if the read-back
    /// failed, in which case ``activeControls`` is empty and means unknown.
    public var status: HelperStatus
    /// The controls the hardware reports active, read back for this reply.
    public var activeControls: HelperControlSet
    /// Seconds left on the charging-inhibit lease, rounded up; 0 for none.
    public var chargingInhibitedLeaseSeconds: Int
    /// Seconds left on the adapter-disable lease, rounded up; 0 for none.
    public var adapterDisabledLeaseSeconds: Int
    /// True if the leases above belong to the calling session.
    public var isLeaseHolder: Bool
    public var interlocks: HelperInterlocks
    /// The last hardware error code, 0 if there has been none. See
    /// ``HelperHardwareError``.
    public var lastHardwareError: Int
    /// How many hardware errors the engine has recorded since it started, so
    /// that a repeat of the same code is visible.
    public var hardwareErrorCount: Int
    /// The charging inhibit's change generation; see
    /// ``HelperControlChange/generation``.
    public var chargingInhibitedGeneration: UInt64
    /// Why the charging inhibit last changed: a raw ``HelperChangeCause``,
    /// 0 for none.
    public var chargingInhibitedChangeCause: Int
    /// The interlocks behind that change, if an interlock caused it.
    public var chargingInhibitedChangeInterlocks: HelperInterlocks
    /// The session behind that change, or 0.
    public var chargingInhibitedChangeSession: UInt64
    /// The same four for the adapter-disable.
    public var adapterDisabledGeneration: UInt64
    public var adapterDisabledChangeCause: Int
    public var adapterDisabledChangeInterlocks: HelperInterlocks
    public var adapterDisabledChangeSession: UInt64

    public init(
        status: HelperStatus,
        activeControls: HelperControlSet,
        chargingInhibitedLeaseSeconds: Int,
        adapterDisabledLeaseSeconds: Int,
        isLeaseHolder: Bool,
        interlocks: HelperInterlocks,
        lastHardwareError: Int,
        hardwareErrorCount: Int,
        chargingInhibitedChange: HelperControlChange,
        adapterDisabledChange: HelperControlChange
    ) {
        self.status = status
        self.activeControls = activeControls
        self.chargingInhibitedLeaseSeconds = chargingInhibitedLeaseSeconds
        self.adapterDisabledLeaseSeconds = adapterDisabledLeaseSeconds
        self.isLeaseHolder = isLeaseHolder
        self.interlocks = interlocks
        self.lastHardwareError = lastHardwareError
        self.hardwareErrorCount = hardwareErrorCount
        self.chargingInhibitedGeneration = chargingInhibitedChange.generation
        self.chargingInhibitedChangeCause = chargingInhibitedChange.cause?.rawValue ?? 0
        self.chargingInhibitedChangeInterlocks = chargingInhibitedChange.interlocks
        self.chargingInhibitedChangeSession = chargingInhibitedChange.session
        self.adapterDisabledGeneration = adapterDisabledChange.generation
        self.adapterDisabledChangeCause = adapterDisabledChange.cause?.rawValue ?? 0
        self.adapterDisabledChangeInterlocks = adapterDisabledChange.interlocks
        self.adapterDisabledChangeSession = adapterDisabledChange.session
    }

    /// Seconds left on the lease for `control`, rounded up; 0 for none.
    public func leaseSeconds(for control: HelperControl) -> Int {
        switch control {
        case .chargingInhibited: chargingInhibitedLeaseSeconds
        case .adapterDisabled: adapterDisabledLeaseSeconds
        }
    }

    /// The latest change of `control`.
    public func change(for control: HelperControl) -> HelperControlChange {
        switch control {
        case .chargingInhibited:
            HelperControlChange(
                generation: chargingInhibitedGeneration,
                cause: HelperChangeCause(rawValue: chargingInhibitedChangeCause),
                interlocks: chargingInhibitedChangeInterlocks,
                session: chargingInhibitedChangeSession
            )
        case .adapterDisabled:
            HelperControlChange(
                generation: adapterDisabledGeneration,
                cause: HelperChangeCause(rawValue: adapterDisabledChangeCause),
                interlocks: adapterDisabledChangeInterlocks,
                session: adapterDisabledChangeSession
            )
        }
    }
}
