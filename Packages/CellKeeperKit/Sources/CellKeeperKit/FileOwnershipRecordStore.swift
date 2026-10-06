import CellKeeperCore
import Foundation

public enum FileOwnershipRecordStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case system(operation: String, errno: Int32)
    case verificationFailed

    public var description: String {
        switch self {
        case .system(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        case .verificationFailed:
            "the record read back differs from what was written"
        }
    }
}

/// Stores the record of the user's own Charge Limit in a small file and
/// makes every save durable before returning: the data is written to a
/// temporary file, flushed to the disk (`F_FULLFSYNC`), renamed into place,
/// the directory is flushed, and the file is read back and compared.
///
/// Inside the App Sandbox the default location is in the app's container.
public struct FileOwnershipRecordStore: OwnershipRecordStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/CellKeeper/native-charge-limit-ownership.json`.
    public static var `default`: FileOwnershipRecordStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return FileOwnershipRecordStore(url: base.appendingPathComponent("CellKeeper", isDirectory: true)
            .appendingPathComponent("native-charge-limit-ownership.json"))
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try Self.writeDurably(data, to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw FileOwnershipRecordStoreError.system(operation: "rename", errno: code)
        }
        try Self.flushDirectory(directory)
        guard try Data(contentsOf: url) == data else {
            throw FileOwnershipRecordStoreError.verificationFailed
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try Self.flushDirectory(url.deletingLastPathComponent())
    }

    private static func writeDurably(_ data: Data, to file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw FileOwnershipRecordStoreError.system(operation: "open", errno: errno)
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FileOwnershipRecordStoreError.system(operation: "write", errno: errno)
                }
                offset += written
            }
        }
        try flush(descriptor)
    }

    private static func flushDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileOwnershipRecordStoreError.system(operation: "open directory", errno: errno)
        }
        defer { close(descriptor) }
        try flush(descriptor)
    }

    /// `F_FULLFSYNC` asks the drive itself to flush; fall back to `fsync`
    /// where the file system does not support it.
    private static func flush(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw FileOwnershipRecordStoreError.system(operation: "fsync", errno: errno)
        }
    }
}
