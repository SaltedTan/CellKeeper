import Foundation

/// `watch`'s report file (code review r5 and r6 of #101). Its name is
/// reserved when the run starts, before the owner is asked anything: the
/// file is created exclusively (`O_CREAT | O_EXCL | O_NOFOLLOW`), so an
/// entry that already has the name (a leftover report, a link, another
/// run's report from the same second) is never opened, truncated or
/// followed, and the run refuses instead (``CreateError/exists``). The
/// placeholder, which asks for the recovery check, is written and synced,
/// and the file closed: it is never opened for writing again.
///
/// The save replaces it atomically: the whole report goes to a fresh
/// temporary file beside it, also created exclusively (``partialPaths``:
/// if a name is taken, the next is tried, up to ``partialNames`` of them;
/// an existing entry is never opened), which is synced and then renamed
/// over the placeholder. Until that rename, the file holds the complete
/// placeholder, so a write that hangs (until the ending's watchdog ends
/// the process, ``EndingWatchdog``), stops part way or fails, and a
/// create, sync or rename that fails, all leave the placeholder in place,
/// and whatever reached the temporary file beside it. The rename replaces
/// the directory entry; it never follows a link.
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

    /// Why the report file could not be created.
    public enum CreateError: Error, Equatable {
        /// Something already has the name: it was not opened, truncated or
        /// followed.
        case exists
        /// Creating it, or writing, syncing or closing the placeholder,
        /// failed with this `errno`; a file the probe created is removed.
        case failed(Int32)
    }

    /// How many temporary names a save tries.
    public static let partialNames = 10

    public let path: String
    /// The names the save may write the report under before renaming it
    /// over ``path``, in order: beside it, so that `.gitignore`'s
    /// `charge-inhibit-probe-*.txt` covers them too.
    public let partialPaths: [String]
    private let hooks: Hooks

    /// Creates the file at `path` exclusively, writes `placeholder`, syncs
    /// it and closes it.
    public init(path: String, placeholder: String, hooks: Hooks = .real) throws(CreateError) {
        self.path = path
        partialPaths = Self.partialPaths(for: path)
        self.hooks = hooks
        let descriptor = Self.createExclusively(path)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? .exists : .failed(errno)
        }
        let written = Self.write(placeholder, to: descriptor, with: Hooks.pwrite) && Darwin.fsync(descriptor) == 0
        let failure = errno
        guard close(descriptor) == 0, written else {
            // The probe created this file; nothing else of it is left.
            unlink(path)
            throw .failed(written ? errno : failure)
        }
    }

    /// `open(2)` with `O_CREAT | O_EXCL | O_NOFOLLOW`: a new file, or -1,
    /// with `EEXIST` if anything, a link included, has the name.
    static func createExclusively(_ path: String) -> Int32 {
        open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    }

    /// "x.partial.txt", then "x.partial-2.txt" … "x.partial-10.txt", for
    /// "x.txt".
    public static func partialPaths(for path: String) -> [String] {
        let stem = path.hasSuffix(".txt") ? String(path.dropLast(".txt".count)) : path
        return (1...partialNames).map { $0 == 1 ? "\(stem).partial.txt" : "\(stem).partial-\($0).txt" }
    }

    /// Saves `text` as the whole report: written in full to a temporary
    /// file created exclusively beside ``path``, synced, closed, and only
    /// then renamed over ``path``. Returns whether all of it succeeded; if
    /// not, ``path`` still holds the placeholder. Called once per run, by
    /// the ending path that settles the end (``ManualCutEnding``), after
    /// the ending's watchdog is armed.
    public func persist(_ text: String) -> Bool {
        guard let (descriptor, partial) = createPartial() else { return false }
        let written = Self.write(text, to: descriptor, with: hooks.write) && hooks.sync(descriptor) == 0
        guard close(descriptor) == 0, written else { return false }
        return hooks.rename(partial, path) == 0
    }

    /// The first of ``partialPaths`` that can be created exclusively; nil
    /// if every name is taken or a create fails otherwise.
    private func createPartial() -> (descriptor: Int32, path: String)? {
        for partial in partialPaths {
            let descriptor = Self.createExclusively(partial)
            if descriptor >= 0 {
                return (descriptor, partial)
            }
            guard errno == EEXIST else { return nil }
        }
        return nil
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
