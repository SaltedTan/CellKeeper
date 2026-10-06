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
}

public enum BackendError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case unsupportedMode(ChargeControlMode)
    case operationFailed(String)
    /// The backend reported success but a read-back did not match.
    case verificationFailed(expected: ChargeControlMode, actual: ChargeControlMode?)

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
    /// The limit CellKeeper most recently set (or is setting) while
    /// responsible for it.
    public var target: Int?

    public init(reportedLimit: Int? = nil, readAt: Date? = nil, readProblem: String? = nil, ownerLimit: Int? = nil, target: Int? = nil) {
        self.reportedLimit = reportedLimit
        self.readAt = readAt
        self.readProblem = readProblem
        self.ownerLimit = ownerLimit
        self.target = target
    }

    /// True while CellKeeper has changed the setting and must restore it.
    public var isOwnedByCellKeeper: Bool { ownerLimit != nil }
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
///   otherwise `.nativeLimit` with the value macOS reports, read afresh. A
///   value other than the one CellKeeper set means someone else changed it.
/// - Only a fresh read of the setting from macOS confirms a change. A
///   shortcut or command finishing successfully does not.
public protocol ChargingBackend: Sendable {
    var descriptor: BackendDescriptor { get }

    func capabilities() async -> ControlCapabilities

    /// The mode currently in effect, or nil if it cannot be determined.
    func currentMode() async throws -> ChargeControlMode?

    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome

    /// State of macOS's Charge Limit for native-limit backends; nil for
    /// others. Returns what is already known, without new I/O.
    func nativeLimitStatus() async -> NativeLimitStatus?
}

extension ChargingBackend {
    public func nativeLimitStatus() async -> NativeLimitStatus? { nil }
}
