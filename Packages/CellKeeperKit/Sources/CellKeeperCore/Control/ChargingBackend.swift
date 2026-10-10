import Foundation

/// The charging configuration CellKeeper can ask a backend for.
public enum ChargeControlMode: Hashable, Sendable, CustomStringConvertible {
    /// CellKeeper has no restriction in effect. This is always the fail-safe
    /// mode. For backends that switch charging themselves it means macOS
    /// default behaviour. For a native-limit backend it means the user's own
    /// macOS Charge Limit, exactly as it was before CellKeeper changed it.
    case normal
    /// External power runs the Mac; battery charging is inhibited.
    case inhibitCharging
    /// The Mac runs from the battery even though external power is connected.
    case forceDischarge
    /// macOS's own Charge Limit is set to this percentage by CellKeeper, and
    /// macOS enforces it. Only offered by backends whose
    /// ``ControlCapabilities/style`` is ``ControlStyle/nativeLimit(steps:)``.
    case nativeLimit(percent: Int)

    /// The modes of backends that switch charging themselves.
    public static let chargingModes: Set<ChargeControlMode> = [.normal, .inhibitCharging, .forceDischarge]

    /// How far the mode departs from the fail-safe mode.
    public var restrictionLevel: Int {
        switch self {
        case .normal: 0
        case .inhibitCharging, .nativeLimit: 1
        case .forceDischarge: 2
        }
    }

    /// True if moving from `current` to this mode is a restricting change:
    /// one that moves further from the fail-safe mode, or replaces one
    /// CellKeeper-set native limit with another. Restricting changes are
    /// rate-limited; relaxing changes toward `.normal` are not.
    public func isRestricting(from current: ChargeControlMode?) -> Bool {
        guard self != .normal, self != current else { return false }
        return restrictionLevel >= (current?.restrictionLevel ?? 0)
    }

    public var description: String {
        switch self {
        case .normal: "normal"
        case .inhibitCharging: "inhibitCharging"
        case .forceDischarge: "forceDischarge"
        case .nativeLimit(let percent): "nativeLimit(\(percent)%)"
        }
    }
}

/// How a backend limits charging.
public enum ControlStyle: Sendable, Equatable {
    /// CellKeeper enforces its limit itself by switching charging on and off.
    case chargingModes
    /// macOS enforces a charge limit, and CellKeeper only chooses its value
    /// from `steps` (ascending percentages). Hysteresis, sleep behaviour and
    /// calibration are macOS's.
    case nativeLimit(steps: [Int])
}

/// Whether, and how, a backend can actually change charging behaviour.
public enum ControlAvailability: Sendable, Equatable {
    /// Real hardware control that has been verified for this Mac.
    case available
    /// Real hardware control that is not verified for this Mac. Must only be
    /// used after explicit user opt-in.
    case experimental
    /// No hardware is touched; requests are recorded and reported as simulated.
    case simulated
    /// The backend cannot perform any control.
    case unavailable(reason: String)

    /// True if the backend accepts control requests (real or simulated).
    public var acceptsRequests: Bool {
        switch self {
        case .available, .experimental, .simulated: true
        case .unavailable: false
        }
    }

    /// True if accepted requests change real hardware state.
    public var affectsHardware: Bool {
        switch self {
        case .available, .experimental: true
        case .simulated, .unavailable: false
        }
    }
}

/// What a backend can do right now.
public struct ControlCapabilities: Sendable, Equatable {
    public var availability: ControlAvailability
    /// How the backend limits charging. Kept when the backend is unavailable,
    /// so CellKeeper can still explain what it would do.
    public private(set) var style: ControlStyle
    /// Modes the backend can apply. `.normal` is always included when the
    /// backend accepts requests, so that the fail-safe mode is reachable.
    public private(set) var supportedModes: Set<ChargeControlMode>
    /// macOS's own Charge Limit, as last read by a backend that switches
    /// charging itself and checks it (safety precondition 7); nil for
    /// backends that do not check it. While it ``MacOSChargeLimitStatus/isLimiting``,
    /// such a backend offers only `.normal` and keeps its availability, and
    /// the policy asks for normal charging and withholds every restriction.
    public var macOSChargeLimit: MacOSChargeLimitStatus?

    /// Capabilities of a backend that switches charging itself.
    public init(availability: ControlAvailability, supportedModes: Set<ChargeControlMode>) {
        self.init(availability: availability, style: .chargingModes, supportedModes: supportedModes)
    }

    private init(availability: ControlAvailability, style: ControlStyle, supportedModes: Set<ChargeControlMode>) {
        self.availability = availability
        self.style = style
        if availability.acceptsRequests {
            self.supportedModes = supportedModes.union([.normal])
        } else {
            self.supportedModes = []
        }
    }

    /// Capabilities of a backend that sets macOS's own charge limit to one of
    /// `steps`.
    public static func nativeLimit(availability: ControlAvailability, steps: [Int]) -> ControlCapabilities {
        let sorted = Array(Set(steps)).sorted()
        return ControlCapabilities(
            availability: availability,
            style: .nativeLimit(steps: sorted),
            supportedModes: Set(sorted.map { ChargeControlMode.nativeLimit(percent: $0) })
        )
    }

    public static func unavailable(_ reason: String, style: ControlStyle = .chargingModes) -> ControlCapabilities {
        ControlCapabilities(availability: .unavailable(reason: reason), style: style, supportedModes: [])
    }

    public func supports(_ mode: ChargeControlMode) -> Bool {
        availability.acceptsRequests && supportedModes.contains(mode)
    }

    /// The same capabilities without any mode other than `.normal`: what a
    /// backend that switches charging itself offers while macOS's own
    /// Charge Limit may be limiting charging. The availability is kept.
    public var withoutRestrictingModes: ControlCapabilities {
        var capabilities = self
        capabilities.supportedModes = supportedModes.intersection([.normal])
        return capabilities
    }

    /// The limits a native-limit backend can set, ascending; empty otherwise.
    public var nativeLimitSteps: [Int] {
        if case .nativeLimit(let steps) = style { return steps }
        return []
    }

    /// True if macOS, not CellKeeper, enforces the limit.
    public var isEnforcedByMacOS: Bool {
        if case .nativeLimit = style { return true }
        return false
    }
}

/// The result of a successful control request.
public enum ControlOutcome: String, Sendable, Equatable {
    /// The requested state is in effect on real hardware, was reached by this
    /// request, and was confirmed.
    case applied
    /// The requested state was already in effect, so nothing was changed. It
    /// was confirmed all the same.
    case unchanged
    /// The request was recorded by a simulated backend. Hardware was not
    /// changed. Simulated backends must never report `.applied`.
    case simulated
    /// Native-limit backends: before changing anything, the backend found a
    /// limit that CellKeeper did not set and adopted it as the user's own
    /// limit. Nothing was changed, and the request was not carried out;
    /// ``ChargingBackend/takeAdoptedLimitChange()`` describes the change.
    case adoptedOutsideChange
}

/// A change to macOS's Charge Limit made outside CellKeeper (for example in
/// System Settings) that a native-limit backend adopted as the user's own
/// limit instead of overwriting it.
public struct AdoptedLimitChange: Sendable, Equatable {
    /// The limit macOS reported, now the user's own (100 for no limit).
    public var limit: Int
    /// True if macOS reported no limit rather than a percentage.
    public var isNoLimit: Bool
    /// The user's own limit as CellKeeper had recorded it before.
    public var previousOwnerLimit: Int
    /// The limit CellKeeper had set.
    public var expectedLimit: Int
    public var date: Date
    /// True if the change was adopted in an earlier session and is reported
    /// again because that session may not have turned management off.
    public var isFromEarlierSession: Bool

    public init(limit: Int, isNoLimit: Bool, previousOwnerLimit: Int, expectedLimit: Int, date: Date, isFromEarlierSession: Bool = false) {
        self.limit = limit
        self.isNoLimit = isNoLimit
        self.previousOwnerLimit = previousOwnerLimit
        self.expectedLimit = expectedLimit
        self.date = date
        self.isFromEarlierSession = isFromEarlierSession
    }
}

public enum BackendError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case unsupportedMode(ChargeControlMode)
    case operationFailed(String)
    /// The backend reported success but a read-back did not match.
    case verificationFailed(expected: ChargeControlMode, actual: ChargeControlMode?)
    /// Before making a change, the backend found a state CellKeeper did not
    /// set: someone else changed it. Native-limit backends adopt such a
    /// change instead (``ControlOutcome/adoptedOutsideChange``).
    case changedOutside(expected: ChargeControlMode, found: ChargeControlMode?)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            "Control unavailable: \(reason)"
        case .unsupportedMode(let mode):
            "Mode not supported by this backend: \(mode)"
        case .operationFailed(let message):
            "Operation failed: \(message)"
        case .verificationFailed(let expected, let actual):
            "Read-back mismatch: expected \(expected), got \(actual.map(String.init(describing:)) ?? "unknown")"
        case .changedOutside(let expected, let found):
            "Changed outside CellKeeper: expected \(expected), found \(found.map(String.init(describing:)) ?? "unknown")"
        }
    }
}

/// Static, user-presentable information about a backend.
public struct BackendDescriptor: Sendable, Equatable {
    public var identifier: String
    public var displayName: String
    public var summary: String

    public init(identifier: String, displayName: String, summary: String) {
        self.identifier = identifier
        self.displayName = displayName
        self.summary = summary
    }
}

/// What a native-limit backend knows about macOS's Charge Limit and about
/// the limit it must give back.
public struct NativeLimitStatus: Sendable, Equatable {
    /// The limit macOS reported at the last read, in percent (100 means no
    /// limit), or nil if it could not be read or recognised.
    public var reportedLimit: Int?
    /// When ``reportedLimit`` was read.
    public var readAt: Date?
    /// Why the last read did not produce a limit, if it failed.
    public var readProblem: String?
    /// The user's own limit, recorded before CellKeeper first changed it.
    /// Non-nil exactly while CellKeeper is responsible for the setting.
    public var ownerLimit: Int?
    /// The limit CellKeeper last confirmed while responsible for it.
    public var target: Int?
    /// A record of the user's limit exists but cannot be read. CellKeeper
    /// may have changed the setting and cannot know what to restore.
    public var isRecordUnreadable: Bool
    /// macOS reports no limit, and CellKeeper will record that as a 100%
    /// limit only after the user confirms it (it could also be a temporary
    /// state such as a full charge).
    public var needsNoLimitConfirmation: Bool
    /// CellKeeper started restoring the user's limit and has not confirmed
    /// it, possibly in an earlier session.
    public var isRestoreUnfinished: Bool
    /// An outside change was adopted but its marker could not be stored
    /// yet, so the record it replaced may still be on disk. Until it is
    /// stored, CellKeeper does not switch backend or turn management on.
    public var isAdoptionUnsaved: Bool
    /// Whether the user's shortcut was found when CellKeeper last looked for
    /// it or ran it; nil if it has not checked yet, or the last run failed.
    public var isShortcutFound: Bool?

    public init(
        reportedLimit: Int? = nil,
        readAt: Date? = nil,
        readProblem: String? = nil,
        ownerLimit: Int? = nil,
        target: Int? = nil,
        isRecordUnreadable: Bool = false,
        needsNoLimitConfirmation: Bool = false,
        isRestoreUnfinished: Bool = false,
        isAdoptionUnsaved: Bool = false,
        isShortcutFound: Bool? = nil
    ) {
        self.reportedLimit = reportedLimit
        self.readAt = readAt
        self.readProblem = readProblem
        self.ownerLimit = ownerLimit
        self.target = target
        self.isRecordUnreadable = isRecordUnreadable
        self.needsNoLimitConfirmation = needsNoLimitConfirmation
        self.isRestoreUnfinished = isRestoreUnfinished
        self.isAdoptionUnsaved = isAdoptionUnsaved
        self.isShortcutFound = isShortcutFound
    }

    /// True while CellKeeper has changed the setting and must restore it.
    public var isOwnedByCellKeeper: Bool { ownerLimit != nil }

    /// True while CellKeeper may have changed the setting and has not
    /// confirmed giving it back, including when its record is unreadable.
    public var hasUnresolvedOwnership: Bool { ownerLimit != nil || isRecordUnreadable }
}

/// Why a backend ended CellKeeper's hold by itself.
public enum HoldRelease: Sendable, Equatable, CustomStringConvertible {
    /// CellKeeper's lease ran out before CellKeeper renewed it (research rule
    /// R3: a stalled policy loop lets a restriction lapse).
    case leaseExpired
    /// One of the backend's own safety interlocks cleared it; the text names
    /// the interlocks.
    case interlock(String)
    /// The connection to the backend ended, and with it every hold made
    /// through it (rule R1).
    case connectionLost
    /// The backend stopped or restarted, which restores defaults (rules R2,
    /// R4).
    case backendStopped

    public var description: String {
        switch self {
        case .leaseExpired: "its lease expired before CellKeeper renewed it"
        case .interlock(let interlocks): "a safety interlock required it (\(interlocks))"
        case .connectionLost: "the connection to it ended"
        case .backendStopped: "it stopped or restarted, which restores macOS's defaults"
        }
    }
}

/// What a backend knows about how the mode it last reported came about,
/// beyond what the controller can tell by comparing it with the mode
/// CellKeeper last confirmed.
public enum ReportedModeOrigin: Sendable, Equatable {
    /// CellKeeper set or restored it, even if it could not confirm it at the
    /// time.
    case cellKeeper
    /// The backend ended CellKeeper's hold itself, under one of its own
    /// safety rules. It is not an outside change.
    case releasedByBackend(HoldRelease)
    /// The backend found a change that CellKeeper did not make: another tool
    /// may be controlling charging (rule R27). Reported for as long as the
    /// backend still sees it; one it found earlier, for example while
    /// releasing a hold, is reported once, by the next read.
    case changedOutside(String)
    /// The backend stopped making changes until someone acknowledges a
    /// problem it found itself (a failed write, a restore it owes): the
    /// controller faults, so the user can clear the fault (rule R11).
    /// Reported for as long as the backend waits.
    case needsAcknowledgement(String)
}

/// A charging-control backend.
///
/// This is the only boundary through which CellKeeper may change charging
/// behaviour. Implementations that touch hardware or private interfaces must
/// live behind this protocol (and, for privileged operations, behind a narrow
/// helper), never in policy code.
///
/// Contract:
/// - `setMode` must throw rather than return when the requested state was not
///   reached.
/// - Simulated implementations must return ``ControlOutcome/simulated``.
/// - `.normal` must always be accepted when the backend accepts requests.
///
/// Additional contract for native-limit backends (style
/// ``ControlStyle/nativeLimit(steps:)``):
/// - `setMode(.nativeLimit(p))` accepts only `p` in the advertised steps.
///   Before its first change it records the user's own limit, read from
///   macOS, and persists it so that a crash cannot lose it. If that limit
///   cannot be read and recognised, it refuses; it never assumes a value.
/// - `setMode(.normal)` restores exactly the recorded limit and then forgets
///   it. It never maps `.normal` to a fixed value such as 100%. With nothing
///   recorded there is nothing to restore.
/// - `currentMode()` reports `.normal` while nothing is recorded, and
///   otherwise `.nativeLimit` with the value macOS reports, read afresh.
/// - A recognised value that CellKeeper did not set means someone else
///   changed the limit, usually the user in System Settings. The backend
///   adopts it as the user's own limit: it forgets its record without
///   writing anything, so `currentMode()` reports `.normal` and `setMode`
///   returns ``ControlOutcome/adoptedOutsideChange``. The adoption is then
///   reported once by ``takeAdoptedLimitChange()``.
/// - Only a fresh read of the setting from macOS confirms a change. A
///   shortcut or command finishing successfully does not.
///
/// Additional contract for backends whose holds lapse unless renewed (a
/// helper's leases):
/// - `renewHold(_:)` extends the hold on a mode CellKeeper holds. The
///   controller calls it only at the end of an evaluation that still wants
///   that mode, so a stalled policy loop lets the hold lapse (rule R3).
/// - A hold the backend ended itself (lapse, interlock, lost connection) is
///   reported by ``reportedModeOrigin()`` as
///   ``ReportedModeOrigin/releasedByBackend(_:)``, so the controller does not
///   take it for an outside change.
/// - `.normal` releases only what CellKeeper set. The backend never
///   overrides another tool's change by itself: it reports it, as
///   ``BackendError/changedOutside(expected:found:)`` or
///   ``ReportedModeOrigin/changedOutside(_:)``. An outside change found by a
///   request that succeeds stays reported until the next read reports it.
/// - A fault is reported with every read, also one that throws; the
///   controller looks at ``reportedModeOrigin()`` after every call to
///   ``currentMode()``, including the confirmation of a request.
public protocol ChargingBackend: Sendable {
    var descriptor: BackendDescriptor { get }

    func capabilities() async -> ControlCapabilities

    /// What the backend can do, for restoring `.normal` (quitting, a backend
    /// switch, a safety fallback): like ``capabilities()``, but without
    /// reading anything a request for `.normal` does not depend on, so a
    /// release never waits for it. Default: ``capabilities()``.
    func capabilitiesForRelease() async -> ControlCapabilities

    /// The mode currently in effect, or nil if it cannot be determined.
    func currentMode() async throws -> ChargeControlMode?

    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome

    /// How the mode last reported by ``currentMode()`` came about, when the
    /// backend knows; nil otherwise. After a ``currentMode()`` that threw,
    /// only a fault (``ReportedModeOrigin/changedOutside(_:)``,
    /// ``ReportedModeOrigin/needsAcknowledgement(_:)``) or nil. Returns what
    /// is already known, without new I/O. Default: nil.
    func reportedModeOrigin() async -> ReportedModeOrigin?

    /// Extends CellKeeper's hold on `mode`, which CellKeeper set, confirmed
    /// and still wants. Throws if the hold could not be extended. Default:
    /// nothing, for backends whose holds do not lapse.
    func renewHold(_ mode: ChargeControlMode) async throws

    /// The user cleared the controller's fault, a deliberate act. A backend
    /// that stopped making changes until someone acknowledges a problem (a
    /// helper after an outside change or a hardware error) may restore
    /// macOS's defaults now. Default: nothing.
    func resetAfterFault() async throws

    /// The user asked CellKeeper to check again (for example after creating
    /// the shortcut, or turning macOS's Charge Limit off): the next
    /// ``capabilities()`` must not rely on what the backend cached about
    /// what it depends on. Default: nothing.
    func recheckAvailability() async

    /// State of macOS's Charge Limit for native-limit backends; nil for
    /// others. Returns what is already known, without new I/O.
    func nativeLimitStatus() async -> NativeLimitStatus?

    /// Native-limit backends: the outside change adopted as the user's own
    /// limit since the last call, if any. Each adoption is returned once.
    func takeAdoptedLimitChange() async -> AdoptedLimitChange?
}

extension ChargingBackend {
    public func capabilitiesForRelease() async -> ControlCapabilities { await capabilities() }
    public func reportedModeOrigin() async -> ReportedModeOrigin? { nil }
    public func renewHold(_ mode: ChargeControlMode) async throws {}
    public func resetAfterFault() async throws {}
    public func recheckAvailability() async {}
    public func nativeLimitStatus() async -> NativeLimitStatus? { nil }
    public func takeAdoptedLimitChange() async -> AdoptedLimitChange? { nil }
}
