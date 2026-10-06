import Foundation
import os

/// Unified-logging categories. View with:
/// `log stream --level info --predicate 'subsystem == "<bundle id>"'`
///
/// Only battery state, settings values, and control decisions are logged.
/// Never log serial numbers or other device identifiers.
public enum CellKeeperLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "CellKeeper"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
    public static let policy = Logger(subsystem: subsystem, category: "policy")
    public static let backend = Logger(subsystem: subsystem, category: "backend")
    public static let safety = Logger(subsystem: subsystem, category: "safety")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
}
