import CellKeeperCore
import Foundation

/// Whether this Mac can use macOS's Charge Limit.
public enum NativeChargeLimitSupport {
    /// Apple: "Requires macOS Tahoe 26.4 or later and a Mac with Apple
    /// silicon" (support article 102338).
    public static let minimumSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)

    /// Why this Mac cannot use the Charge Limit, or nil if it can.
    public static func platformIssue() -> String? {
        guard isAppleSilicon() else {
            return "macOS's Charge Limit needs a Mac with Apple silicon."
        }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumSystemVersion) else {
            return "macOS's Charge Limit needs macOS Tahoe 26.4 or later."
        }
        guard FileManager.default.isExecutableFile(atPath: ShortcutsCommandRunner.defaultExecutable.path) else {
            return "The shortcuts command-line tool was not found."
        }
        guard FileManager.default.isExecutableFile(atPath: PmsetChargeLimitReader.defaultExecutable.path) else {
            return "The pmset command-line tool was not found."
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
