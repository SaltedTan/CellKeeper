import CellKeeperHelperCore
import Foundation
import os

/// The helper daemon's unified-logging categories (research note 04, §3.7).
public enum HelperLogCategory: String, Sendable, CaseIterable {
    /// Start, shutdown, sleep and wake, exit.
    case lifecycle
    /// Client connections and the listener.
    case xpc
    /// Leases, writes, activations, deactivations and restores.
    case control
    /// Interlocks, failures, deadlines and the activation history.
    case safety
}

/// How much a log line matters. Routine lines are `info` (kept in memory
/// only); everything a reviewer of an incident needs is `notice` or `fault`,
/// which unified logging persists.
public enum HelperLogLevel: Sendable, Equatable {
    case info
    case notice
    case fault
}

/// Where the daemon writes its audit log. The daemon calls it from its own
/// tasks, never from inside the engine's event sink.
public protocol HelperDaemonLog: Sendable {
    func write(_ level: HelperLogLevel, _ category: HelperLogCategory, _ message: String)
}

/// The daemon's log in unified logging, under ``subsystem``. Nothing the
/// daemon logs is sensitive (battery state, controls, statuses; no
/// identifiers), so every value is `.public`. Read it with
/// `/usr/bin/log show --predicate 'subsystem == "io.github.saltedtan.CellKeeper.Helper"'`.
public struct UnifiedHelperLog: HelperDaemonLog {
    public static let subsystem = "io.github.saltedtan.CellKeeper.Helper"

    private let loggers: [HelperLogCategory: Logger]

    public init() {
        var loggers: [HelperLogCategory: Logger] = [:]
        for category in HelperLogCategory.allCases {
            loggers[category] = Logger(subsystem: Self.subsystem, category: category.rawValue)
        }
        self.loggers = loggers
    }

    public func write(_ level: HelperLogLevel, _ category: HelperLogCategory, _ message: String) {
        guard let logger = loggers[category] else { return }
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
    }
}

extension HelperEvent {
    /// The category and level of this event in the daemon's audit log. The
    /// levels follow the Simulated helper's log: routine events are `info`,
    /// everything else `notice`, and failures to restore defaults or to use
    /// the control `fault`.
    var logPlacement: (level: HelperLogLevel, category: HelperLogCategory) {
        switch self {
        case .sessionOpened, .sessionInvalidated:
            (.info, .xpc)
        case .sessionRevoked, .requestRejected:
            (.notice, .xpc)
        case .leaseGranted, .leaseRenewed, .write, .activationRecorded:
            (.info, .control)
        case .leaseEnded, .activated, .deactivated, .restored:
            (.notice, .control)
        case .interlocksRaised, .interlocksCleared:
            (.notice, .safety)
        case .restoreFailed, .hardwareError:
            (.fault, .safety)
        case .started, .shuttingDown, .safeToExit:
            (.notice, .lifecycle)
        }
    }
}
