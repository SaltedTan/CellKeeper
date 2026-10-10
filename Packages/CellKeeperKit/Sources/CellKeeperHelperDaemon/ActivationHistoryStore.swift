import CellKeeperHelperCore
import Foundation

/// Identifies one boot of the Mac: the boot session UUID, which the kernel
/// generates once at boot (`kern.bootsessionuuid`, read with
/// `sysctlbyname`; read-only, though not declared in the SDK's headers).
///
/// The engine's clock (`CLOCK_MONOTONIC`) starts again at every boot, so
/// activation records are only comparable within one boot (D35). Nothing
/// derived from the wall clock is used: `kern.boottime`, for one, moves
/// when the calendar time is set, which would make one boot look like two.
public struct BootIdentifier: Sendable, Equatable, Codable, CustomStringConvertible {
    public var sessionUUID: UUID

    public init(sessionUUID: UUID) {
        self.sessionUUID = sessionUUID
    }

    /// The identifier in the sysctl's text, or nil if it is not a UUID.
    init?(sysctlValue: String) {
        guard let uuid = UUID(uuidString: sysctlValue) else { return nil }
        self.init(sessionUUID: uuid)
    }

    /// This boot's identifier, or nil if `kern.bootsessionuuid` cannot be
    /// read or is not a UUID. There is no fallback.
    public static func current() -> BootIdentifier? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, (1...64).contains(size) else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0, size <= buffer.count else { return nil }
        let text = String(decoding: buffer.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
        return BootIdentifier(sysctlValue: text)
    }

    public var description: String {
        "boot session \(sessionUUID.uuidString)"
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
/// it belongs to. Version 1 (never released) keyed it by `kern.boottime`.
///
/// ```json
/// {"boot":{"sessionUUID":"23C96BB3-5CF9-4843-B0ED-4348B69A3B48"},"records":[{"control":1,"uptime":5021.5}],"version":2}
/// ```
public enum ActivationHistoryFormat {
    public static let version = 2
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
/// - Loading opens the file without following a symbolic link and without
///   blocking (a FIFO with no writer would otherwise hold the daemon before
///   its start-up restore), refuses anything but a regular file at once,
///   reads at most ``ActivationHistoryFormat/maximumSize`` bytes plus one,
///   refuses a larger file, and discards anything
///   ``ActivationHistoryFormat/decode(_:boot:now:)`` does not accept.
public struct FileActivationHistoryStore: ActivationHistoryStore {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/CellKeeper/Helper/activation-history.json")

    public let url: URL

    public init(url: URL = Self.defaultURL) {
        self.url = url
    }

    public func load(boot: BootIdentifier, now: TimeInterval) -> ActivationHistoryLoad {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
        // A regular file never blocks, with or without O_NONBLOCK.
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
