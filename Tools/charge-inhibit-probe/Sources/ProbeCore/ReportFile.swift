import Foundation

/// `watch`'s report file (code review r5, r6 and r7 of #101). Its name is
/// reserved when the run starts, before the owner is asked anything: the
/// file is created exclusively (`O_CREAT | O_EXCL | O_NOFOLLOW`), so an
/// entry that already has the name (a leftover report, a link, another
/// run's report from the same second) is never opened, truncated or
/// followed, and the run refuses instead (``CreateError/exists``). The
/// placeholder, which asks for the recovery check, is written and synced,
/// and the file closed: it is never opened for writing again, and the
/// probe never removes anything. Its identity (device and inode) is kept.
///
/// The save replaces it atomically: the whole report goes to a fresh
/// temporary file beside it, also created exclusively (``partialPaths``:
/// if a name is taken, the next is tried, up to ``partialNames`` of them;
/// an existing entry is never opened, and any other error ends the save),
/// which is synced and then renamed over the placeholder. Until that
/// rename, the file holds the complete placeholder, so a write that hangs
/// (until the ending's watchdog ends the process, ``EndingWatchdog``),
/// stops part way or fails, and a create, sync or rename that fails, all
/// leave the placeholder in place, and whatever reached the temporary file
/// beside it. The rename replaces the directory entry; it never follows a
/// link.
///
/// The threat model (the lead's decision on code review r7): the probe
/// defends against its own failures (crashes, hangs, I/O errors, signals,
/// sleep, terminal problems) and against leftovers from earlier runs. It
/// does not defend against another process renaming or replacing entries in
/// the report's directory during the run; such a process could as easily
/// rewrite the report afterwards. Within that boundary, the save checks
/// identities, so that such interference ends in a failure the console
/// reports, not a claim of success: just before the rename, the report's
/// name must still be the placeholder the probe created, and the temporary
/// name the file the probe wrote (each a regular file with the same device
/// and inode); just after it, the report's name must be the file the probe
/// wrote. What remains is the race between each check and the step after
/// it, which no check made from here can close.
///
/// The placeholder's write, creating the temporary file, the report's
/// write, the sync and the rename are hooks, so the tests can pause or fail
/// each, or replace an entry at a chosen moment.
public final class ReportFile: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// The placeholder's writes; returns what `pwrite(2)` returns.
        public var writePlaceholder: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int
        /// Creates a temporary file exclusively; returns what `open(2)`
        /// returns.
        public var create: @Sendable (_ path: String) -> Int32
        /// One positioned write of the report; returns what `pwrite(2)`
        /// returns.
        public var write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int
        /// Returns what `fsync(2)` returns.
        public var sync: @Sendable (_ descriptor: Int32) -> Int32
        /// Returns what `rename(2)` returns.
        public var rename: @Sendable (_ from: String, _ to: String) -> Int32

        public init(
            writePlaceholder: @escaping @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int = Self.pwrite,
            create: @escaping @Sendable (_ path: String) -> Int32 = Self.create,
            write: @escaping @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int = Self.pwrite,
            sync: @escaping @Sendable (_ descriptor: Int32) -> Int32 = Self.fsync,
            rename: @escaping @Sendable (_ from: String, _ to: String) -> Int32 = Self.rename
        ) {
            self.writePlaceholder = writePlaceholder
            self.create = create
            self.write = write
            self.sync = sync
            self.rename = rename
        }

        /// ``ReportFile/createExclusively(_:)``.
        public static let create: @Sendable (_ path: String) -> Int32 = { ReportFile.createExclusively($0) }

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
        /// followed, and nothing was created.
        case exists
        /// Creating it failed with this `errno`: nothing was created.
        case notCreated(Int32)
        /// It was created, but writing, syncing or closing the placeholder
        /// failed with this `errno`. The probe removes nothing: the file is
        /// left as it is.
        case placeholderNotWritten(Int32)
    }

    /// What became of a save.
    public enum SaveOutcome: Sendable, Equatable {
        /// The report replaced the placeholder, and the report's name was
        /// then the file the probe wrote.
        case saved
        /// Not saved; the report's name was still the placeholder the probe
        /// created, so it still asks for the recovery check.
        case placeholderKept
        /// Not saved, or not confirmed: the report's name was not the file
        /// the probe created or wrote, so the probe cannot say what it holds.
        case unconfirmed
    }

    /// A directory entry's identity.
    struct Identity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    /// How many temporary names a save tries.
    public static let partialNames = 10

    public let path: String
    /// The names the save may write the report under before renaming it
    /// over ``path``, in order: beside it, so that `.gitignore`'s
    /// `charge-inhibit-probe-*.txt` covers them too.
    public let partialPaths: [String]
    private let hooks: Hooks
    /// The placeholder's identity, from its own descriptor.
    private let placeholder: Identity

    /// Creates the file at `path` exclusively, writes `placeholder`, syncs
    /// it and closes it.
    public init(path: String, placeholder: String, hooks: Hooks = .real) throws(CreateError) {
        self.path = path
        partialPaths = Self.partialPaths(for: path)
        self.hooks = hooks
        let descriptor = Self.createExclusively(path)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? .exists : .notCreated(errno)
        }
        let identity = Self.identity(of: descriptor)
        let written = Self.write(placeholder, to: descriptor, with: hooks.writePlaceholder) && Darwin.fsync(descriptor) == 0
        let failure = errno
        guard close(descriptor) == 0, written, let identity else {
            throw .placeholderNotWritten(written ? errno : failure)
        }
        self.placeholder = identity
    }

    /// `open(2)` with `O_CREAT | O_EXCL | O_NOFOLLOW`: a new file, or -1,
    /// with `EEXIST` if anything, a link included, has the name.
    public static func createExclusively(_ path: String) -> Int32 {
        open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    }

    /// "x.partial.txt", then "x.partial-2.txt" … "x.partial-10.txt", for
    /// "x.txt".
    public static func partialPaths(for path: String) -> [String] {
        let stem = path.hasSuffix(".txt") ? String(path.dropLast(".txt".count)) : path
        return (1...partialNames).map { $0 == 1 ? "\(stem).partial.txt" : "\(stem).partial-\($0).txt" }
    }

    /// Saves `text` as the whole report: written in full to a temporary
    /// file created exclusively beside ``path``, synced, closed, checked,
    /// and only then renamed over ``path``, which is checked again. Called
    /// once per run, by the ending path that settles the end
    /// (``ManualCutEnding``), after the ending's watchdog is armed.
    public func persist(_ text: String) -> SaveOutcome {
        guard let (descriptor, partial) = createPartial() else { return notSaved() }
        let identity = Self.identity(of: descriptor)
        let written = Self.write(text, to: descriptor, with: hooks.write) && hooks.sync(descriptor) == 0
        guard close(descriptor) == 0, written, let identity else { return notSaved() }
        // Just before the rename: the report's name is still the
        // placeholder, and the temporary name still the file written.
        guard isEntry(path, placeholder) else { return .unconfirmed }
        guard isEntry(partial, identity) else { return notSaved() }
        guard hooks.rename(partial, path) == 0 else { return notSaved() }
        // Just after it: the report's name is the file written.
        return isEntry(path, identity) ? .saved : .unconfirmed
    }

    /// A save that did not replace the placeholder: whether the report's
    /// name is still the placeholder decides what the console may say.
    private func notSaved() -> SaveOutcome {
        isEntry(path, placeholder) ? .placeholderKept : .unconfirmed
    }

    /// The first of ``partialPaths`` that can be created exclusively; nil
    /// if every name is taken, or at once if a create fails otherwise.
    private func createPartial() -> (descriptor: Int32, path: String)? {
        for partial in partialPaths {
            let descriptor = hooks.create(partial)
            if descriptor >= 0 {
                return (descriptor, partial)
            }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    /// The identity of an open file, or nil.
    static func identity(of descriptor: Int32) -> Identity? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    /// Whether the entry at `path`, not followed if it is a link, is a
    /// regular file with `identity`.
    private func isEntry(_ path: String, _ identity: Identity) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFREG && Identity(device: status.st_dev, inode: status.st_ino) == identity
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
