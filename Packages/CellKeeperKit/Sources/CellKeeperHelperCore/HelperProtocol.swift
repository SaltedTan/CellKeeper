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

    public init(status: HelperStatus, helperProtocolVersion: Int, build: Int, capabilities: HelperCapabilities, isSimulated: Bool) {
        self.status = status
        self.helperProtocolVersion = helperProtocolVersion
        self.build = build
        self.capabilities = capabilities
        self.isSimulated = isSimulated
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
    /// Why the latest lease on the charging inhibit ended: a raw
    /// ``HelperLeaseEndReason``, or 0 while a lease on it is active or if
    /// none has ended since the engine started.
    public var chargingInhibitedLeaseEnd: Int
    /// The same for the adapter-disable.
    public var adapterDisabledLeaseEnd: Int

    public init(
        status: HelperStatus,
        activeControls: HelperControlSet,
        chargingInhibitedLeaseSeconds: Int,
        adapterDisabledLeaseSeconds: Int,
        isLeaseHolder: Bool,
        interlocks: HelperInterlocks,
        lastHardwareError: Int,
        hardwareErrorCount: Int,
        chargingInhibitedLeaseEnd: Int,
        adapterDisabledLeaseEnd: Int
    ) {
        self.status = status
        self.activeControls = activeControls
        self.chargingInhibitedLeaseSeconds = chargingInhibitedLeaseSeconds
        self.adapterDisabledLeaseSeconds = adapterDisabledLeaseSeconds
        self.isLeaseHolder = isLeaseHolder
        self.interlocks = interlocks
        self.lastHardwareError = lastHardwareError
        self.hardwareErrorCount = hardwareErrorCount
        self.chargingInhibitedLeaseEnd = chargingInhibitedLeaseEnd
        self.adapterDisabledLeaseEnd = adapterDisabledLeaseEnd
    }

    /// Seconds left on the lease for `control`, rounded up; 0 for none.
    public func leaseSeconds(for control: HelperControl) -> Int {
        switch control {
        case .chargingInhibited: chargingInhibitedLeaseSeconds
        case .adapterDisabled: adapterDisabledLeaseSeconds
        }
    }

    /// Why the latest lease on `control` ended; nil while one is active, if
    /// none has ended, or for a value this version does not know.
    public func leaseEnd(for control: HelperControl) -> HelperLeaseEndReason? {
        switch control {
        case .chargingInhibited: HelperLeaseEndReason(rawValue: chargingInhibitedLeaseEnd)
        case .adapterDisabled: HelperLeaseEndReason(rawValue: adapterDisabledLeaseEnd)
        }
    }
}
