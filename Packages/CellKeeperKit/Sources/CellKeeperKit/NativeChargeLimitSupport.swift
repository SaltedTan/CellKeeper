import CellKeeperCore
import CellKeeperHelperCore
import Foundation

/// Whether this Mac can use macOS's Charge Limit.
public enum NativeChargeLimitSupport {
    /// Apple: "Requires macOS Tahoe 26.4 or later and a Mac with Apple
    /// silicon" (support article 102338).
    public static let minimumSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)

    /// Why this Mac cannot use the Charge Limit, or nil if it can.
    public static func platformIssue() -> String? {
        if let featureIssue = featureIssue() {
            return featureIssue
        }
        guard FileManager.default.isExecutableFile(atPath: ShortcutsCommandRunner.defaultExecutable.path) else {
            return "The shortcuts command-line tool was not found."
        }
        guard FileManager.default.isExecutableFile(atPath: PmsetChargeLimitReader.defaultExecutable.path) else {
            return "The pmset command-line tool was not found."
        }
        return nil
    }

    /// Why this Mac has no Charge Limit feature at all (not Apple silicon, or
    /// macOS before 26.4), or nil if it has one, whether or not the tools
    /// CellKeeper uses to set and read it are present.
    public static func featureIssue() -> String? {
        guard isAppleSilicon() else {
            return "macOS's Charge Limit needs a Mac with Apple silicon."
        }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumSystemVersion) else {
            return "macOS's Charge Limit needs macOS Tahoe 26.4 or later."
        }
        return nil
    }

    /// True on Apple silicon, including for a process translated by Rosetta.
    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

extension MacOSChargeLimitMonitor {
    /// A monitor of macOS's own Charge Limit through the undocumented,
    /// read-only `pmset -g battlimit` report, for a backend that switches
    /// charging itself; nil if this Mac has no Charge Limit
    /// (`featureIssue`), so there is nothing to coexist with. If pmset is
    /// missing, its reads fail, the limit counts as unreadable, and the
    /// backend restricts nothing.
    public static func system(
        featureIssue: String? = NativeChargeLimitSupport.featureIssue(),
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime
    ) -> MacOSChargeLimitMonitor? {
        guard featureIssue == nil else { return nil }
        return MacOSChargeLimitMonitor(reader: PmsetChargeLimitReader(), uptime: uptime)
    }
}

extension NativeChargeLimitBackend {
    /// The backend wired to this Mac: the documented `shortcuts` tool for
    /// changes, the undocumented read-only `pmset -g battlimit` report for
    /// read-back, and a durable file for the record of the user's own limit.
    public static func system(store: FileOwnershipRecordStore = .default) -> NativeChargeLimitBackend {
        NativeChargeLimitBackend(
            runner: ShortcutsCommandRunner(),
            reader: PmsetChargeLimitReader(),
            store: store,
            platformIssue: NativeChargeLimitSupport.platformIssue()
        )
    }
}
