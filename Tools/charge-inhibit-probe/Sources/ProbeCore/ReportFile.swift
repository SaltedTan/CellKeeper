import Foundation

/// `watch`'s report file (code review r5 of #101). It is created when the
/// run starts with a placeholder that asks for the recovery check, written
/// and synced before the owner is asked anything, and the file is then
/// closed: the placeholder is never truncated, and the file never opened
/// for writing again.
///
/// The save replaces it atomically: the whole report goes to a temporary
/// file in the same directory (``partialPath``), which is synced and then
/// renamed over the placeholder. Until that rename, the file holds the
/// complete placeholder, so a write that hangs (until the ending's
/// watchdog ends the process, ``EndingWatchdog``), stops part way or
/// fails, and a sync or a rename that fails, all leave the placeholder in
/// place, and whatever reached the temporary file beside it.
///
/// The write, the sync and the rename are hooks, so the tests can pause or
/// fail each.
public final class ReportFile: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// One positioned write; returns what `pwrite(2)` returns.
        public var write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int
        /// Returns what `fsync(2)` returns.
        public var sync: @Sendable (_ descriptor: Int32) -> Int32
        /// Returns what `rename(2)` returns.
        public var rename: @Sendable (_ from: String, _ to: String) -> Int32

        public init(
            write: @escaping @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int = Self.pwrite,
            sync: @escaping @Sendable (_ descriptor: Int32) -> Int32 = Self.fsync,
            rename: @escaping @Sendable (_ from: String, _ to: String) -> Int32 = Self.rename
        ) {
            self.write = write
            self.sync = sync
            self.rename = rename
        }

        /// `pwrite(2)`.
        public static let pwrite: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int = { descriptor, bytes, offset in
            Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, offset)
        }

        /// `fsync(2)`.
        public static let fsync: @Sendable (_ descriptor: Int32) -> Int32 = { Darwin.fsync($0) }

        /// `rename(2)`.
        public static let rename: @Sendable (_ from: String, _ to: String) -> Int32 = { Darwin.rename($0, $1) }

        /// `watch`'s.
        public static let real = Hooks()
    }

    public let path: String
    /// Where the save writes the report before renaming it over ``path``:
    /// beside it, so that `.gitignore`'s `charge-inhibit-probe-*.txt`
    /// covers it too.
    public let partialPath: String
    private let hooks: Hooks

    /// Creates (or truncates) the file at `path`, writes `placeholder`,
    /// syncs it and closes it; nil if any of these fails.
    public init?(path: String, placeholder: String, hooks: Hooks = .real) {
        self.path = path
        partialPath = Self.partialPath(for: path)
        self.hooks = hooks
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return nil }
        let written = Self.write(placeholder, to: descriptor, with: Hooks.pwrite) && Darwin.fsync(descriptor) == 0
        guard close(descriptor) == 0, written else { return nil }
    }

    /// "x-20261020-101500.partial.txt" for "x-20261020-101500.txt".
    public static func partialPath(for path: String) -> String {
        guard path.hasSuffix(".txt") else { return path + ".partial.txt" }
        return String(path.dropLast(".txt".count)) + ".partial.txt"
    }

    /// Saves `text` as the whole report: written in full to
    /// ``partialPath``, synced, closed, and only then renamed over
    /// ``path``. Returns whether all of it succeeded; if not, ``path``
    /// still holds the placeholder. Called once per run, by the ending path
    /// that settles the end (``ManualCutEnding``), after the ending's
    /// watchdog is armed.
    public func persist(_ text: String) -> Bool {
        let descriptor = open(partialPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return false }
        let written = Self.write(text, to: descriptor, with: hooks.write) && hooks.sync(descriptor) == 0
        guard close(descriptor) == 0, written else { return false }
        return hooks.rename(partialPath, path) == 0
    }

    static func write(
        _ text: String,
        to descriptor: Int32,
        with write: (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int
    ) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0, off_t(offset)) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
