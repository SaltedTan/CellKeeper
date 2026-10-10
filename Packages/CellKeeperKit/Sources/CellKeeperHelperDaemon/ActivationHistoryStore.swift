import CellKeeperHelperCore
import Foundation

/// Identifies one boot of the Mac: `kern.boottime` (seconds and
/// microseconds), read with `sysctlbyname`, a public, read-only sysctl.
///
/// The engine's clock (`CLOCK_MONOTONIC`) starts again at every boot, so
/// activation records are only comparable within one boot (D35). A boot
/// time that differs means another boot.
public struct BootIdentifier: Sendable, Equatable, Codable, CustomStringConvertible {
    public var seconds: Int64
    public var microseconds: Int32

    public init(seconds: Int64, microseconds: Int32) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    /// This boot's identifier, or nil if `kern.boottime` cannot be read.
    public static func current() -> BootIdentifier? {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size,
              boottime.tv_sec > 0
        else { return nil }
        return BootIdentifier(seconds: Int64(boottime.tv_sec), microseconds: Int32(boottime.tv_usec))
    }

    public var description: String {
        "boot at \(seconds).\(String(format: "%06d", microseconds))"
    }
}

/// What loading the activation history found.
public enum ActivationHistoryLoad: Sendable, Equatable {
    /// Records saved in this boot, at most
    /// ``ActivationHistoryFormat/maximumRecords``, oldest first.
    case loaded([HelperActivationRecord])
    /// Nothing has been saved.
    case missing
    /// Something was saved but cannot be used; the daemon starts with an
    /// empty history.
    case discarded(ActivationHistoryDiscardReason)
}

/// Why a saved activation history was not used.
public enum ActivationHistoryDiscardReason: Sendable, Equatable, CustomStringConvertible {
    /// It was saved in another boot, whose clock cannot be compared.
    case otherBoot
    /// It is larger than ``ActivationHistoryFormat/maximumSize``.
    case tooLarge
    /// It is not a regular file.
    case notARegularFile
    /// It could not be read (an `errno` value).
    case unreadable(errno: Int32)
    /// It is not valid JSON of the expected shape and version.
    case corrupt
    /// A record has a time before boot or later than now.
    case implausible

    public var description: String {
        switch self {
        case .otherBoot: "it was saved in another boot"
        case .tooLarge: "it is larger than \(ActivationHistoryFormat.maximumSize) bytes"
        case .notARegularFile: "it is not a regular file"
        case .unreadable(let errno): "it could not be read (\(String(cString: strerror(errno))))"
        case .corrupt: "it is not a valid activation history"
        case .implausible: "a record has an impossible time"
        }
    }
}

/// Keeps the engine's activation history across helper processes within a
/// boot (D35), so a relaunch cannot reset the activation limits (R13).
public protocol ActivationHistoryStore: Sendable {
    /// The history saved in boot `boot`, judged against `now` on the
    /// engine's clock. Never throws: anything unusable is discarded.
    func load(boot: BootIdentifier, now: TimeInterval) -> ActivationHistoryLoad
    /// Replaces the saved history with the latest
    /// ``ActivationHistoryFormat/maximumRecords`` of `records`.
    func save(_ records: [HelperActivationRecord], boot: BootIdentifier) throws
}

/// The saved form of the activation history: versioned JSON with the boot
/// it belongs to.
///
/// ```json
/// {"boot":{"microseconds":123456,"seconds":1791234567},"records":[{"control":1,"uptime":5021.5}],"version":1}
/// ```
public enum ActivationHistoryFormat {
    public static let version = 1
    /// The engine keeps only this many records; so does the file.
    public static let maximumRecords = HelperEngine.maximumActivationsPerHour
    /// A file larger than this is refused unread. A full history is about
    /// 1 KiB.
    public static let maximumSize = 64 * 1024

    struct Snapshot: Codable {
        var version: Int
        var boot: BootIdentifier
        var records: [HelperActivationRecord]
    }

    /// The latest ``maximumRecords`` of `records`, oldest first.
    static func latest(_ records: [HelperActivationRecord]) -> [HelperActivationRecord] {
        Array(records.sorted { $0.uptime < $1.uptime }.suffix(maximumRecords))
    }

    public static func encode(_ records: [HelperActivationRecord], boot: BootIdentifier) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Snapshot(version: version, boot: boot, records: latest(records)))
    }

    /// Decodes `data` for boot `boot` at `now`. Anything unexpected
    /// discards the whole history: a wrong version or shape, another boot,
    /// or a record whose time is negative, not finite, or later than now
    /// (it cannot belong to this boot's clock).
    public static func decode(_ data: Data, boot: BootIdentifier, now: TimeInterval) -> ActivationHistoryLoad {
        guard data.count <= maximumSize else { return .discarded(.tooLarge) }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == version else {
            return .discarded(.corrupt)
        }
        guard snapshot.boot == boot else { return .discarded(.otherBoot) }
        guard snapshot.records.allSatisfy({ $0.uptime.isFinite && $0.uptime >= 0 && $0.uptime <= now }) else {
            return .discarded(.implausible)
        }
        return .loaded(latest(snapshot.records))
    }
}

/// The activation history in a file, by default
/// ``defaultURL`` (`/Library/Application Support/CellKeeper/Helper/activation-history.json`),
/// which only root can write: the daemon runs as root once it is installed
/// (phase 4b). Run as another user, saving fails and the daemon logs it once.
///
/// - Saving writes a temporary file in the same directory and renames it
///   over the old one, so a reader sees the old history or the new one,
///   never a partial file. The directory is created if needed (mode 0755;
///   the file is 0644: it holds no secrets).
/// - Loading reads at most ``ActivationHistoryFormat/maximumSize`` bytes
///   plus one, refuses a larger file, a symbolic link or anything but a
///   regular file, and discards anything ``ActivationHistoryFormat/decode(_:boot:now:)``
///   does not accept.
public struct FileActivationHistoryStore: ActivationHistoryStore {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/CellKeeper/Helper/activation-history.json")

    public let url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    public func load(boot: BootIdentifier, now: TimeInterval) -> ActivationHistoryLoad {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = errno
            switch error {
            case ENOENT: return .missing
            case ELOOP: return .discarded(.notARegularFile)
            default: return .discarded(.unreadable(errno: error))
            }
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return .discarded(.unreadable(errno: errno)) }
        guard status.st_mode & S_IFMT == S_IFREG else { return .discarded(.notARegularFile) }
        // One byte more than allowed tells a file that is too large.
        let limit = ActivationHistoryFormat.maximumSize + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let count = read(descriptor, &buffer, min(buffer.count, limit - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                return .discarded(.unreadable(errno: errno))
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return ActivationHistoryFormat.decode(data, boot: boot, now: now)
    }

    public func save(_ records: [HelperActivationRecord], boot: BootIdentifier) throws {
        let data = try ActivationHistoryFormat.encode(records, boot: boot)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var renamed = false
        defer {
            if !renamed { unlink(temporary.path) }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        renamed = true
    }
}
