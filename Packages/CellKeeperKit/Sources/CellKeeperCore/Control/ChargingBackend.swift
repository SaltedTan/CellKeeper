/// The hardware charging configuration CellKeeper can ask a backend for.
public enum ChargeControlMode: String, Sendable, Codable, CaseIterable {
    /// macOS default behaviour: external power runs the Mac and charges the
    /// battery as macOS sees fit. This is always the fail-safe mode.
    case normal
    /// External power runs the Mac; battery charging is inhibited.
    case inhibitCharging
    /// The Mac runs from the battery even though external power is connected.
    case forceDischarge

    /// How far the mode departs from macOS defaults. Moving to a higher level
    /// is a restricting change (rate-limited); moving lower is a relaxing
    /// change toward the fail-safe mode (never rate-limited).
    public var restrictionLevel: Int {
        switch self {
        case .normal: 0
        case .inhibitCharging: 1
        case .forceDischarge: 2
        }
    }
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
    /// Modes the backend can apply. `.normal` is always included when the
    /// backend accepts requests, so that the fail-safe mode is reachable.
    public private(set) var supportedModes: Set<ChargeControlMode>

    public init(availability: ControlAvailability, supportedModes: Set<ChargeControlMode>) {
        self.availability = availability
        if availability.acceptsRequests {
            self.supportedModes = supportedModes.union([.normal])
        } else {
            self.supportedModes = []
        }
    }

    public static func unavailable(_ reason: String) -> ControlCapabilities {
        ControlCapabilities(availability: .unavailable(reason: reason), supportedModes: [])
    }

    public func supports(_ mode: ChargeControlMode) -> Bool {
        availability.acceptsRequests && supportedModes.contains(mode)
    }
}

/// The result of a successful control request.
public enum ControlOutcome: String, Sendable, Equatable {
    /// The request changed real hardware state and was confirmed.
    case applied
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
            "Mode not supported by this backend: \(mode.rawValue)"
        case .operationFailed(let message):
            "Operation failed: \(message)"
        case .verificationFailed(let expected, let actual):
            "Read-back mismatch: expected \(expected.rawValue), got \(actual?.rawValue ?? "unknown")"
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
public protocol ChargingBackend: Sendable {
    var descriptor: BackendDescriptor { get }

    func capabilities() async -> ControlCapabilities

    /// The mode currently in effect, or nil if it cannot be determined.
    func currentMode() async throws -> ChargeControlMode?

    func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome
}
