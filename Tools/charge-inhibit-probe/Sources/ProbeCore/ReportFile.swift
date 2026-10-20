import Foundation

/// `watch`'s report file, opened when the run starts and kept open. A save
/// replaces its contents under a deadline that needs no lock, queue or
/// output: in `watch`, SIGALRM's default action, as in ``EmergencyExit``.
/// The deadline and the write are hooks, so the tests can pause a save.
public final class ReportFile: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// Arms the save's deadline, in seconds.
        public var arm: @Sendable (UInt32) -> Void
        /// Disarms it once the save is done.
        public var disarm: @Sendable () -> Void
        /// One positioned write; returns what `pwrite(2)` returns.
        public var write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int

        public init(
            arm: @escaping @Sendable (UInt32) -> Void,
            disarm: @escaping @Sendable () -> Void,
            write: @escaping @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int
        ) {
            self.arm = arm
            self.disarm = disarm
            self.write = write
        }

        /// `watch`'s: SIGALRM back to its default action, which ends the
        /// process, then `alarm(2)`; and `pwrite(2)`.
        public static let real = Hooks(
            arm: { seconds in
                signal(SIGALRM, SIG_DFL)
                alarm(seconds)
            },
            disarm: { _ = alarm(0) },
            write: { descriptor, bytes, offset in pwrite(descriptor, bytes.baseAddress, bytes.count, offset) }
        )
    }

    public let path: String
    private let descriptor: Int32
    private let hooks: Hooks

    /// Creates (or truncates) the file at `path` and writes `placeholder`;
    /// nil if either fails.
    public init?(path: String, placeholder: String, hooks: Hooks = .real) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { return nil }
        self.path = path
        self.descriptor = descriptor
        self.hooks = hooks
        guard Self.write(placeholder, to: descriptor, with: Hooks.real.write) else { return nil }
    }

    deinit {
        close(descriptor)
    }

    /// Saves `text` as the whole report, under the deadline
    /// (``EmergencyExit/deadline`` seconds); returns whether it was saved.
    /// Called once per run, through ``OneShotSave``.
    public func persist(_ text: String) -> Bool {
        hooks.arm(EmergencyExit.deadline)
        defer { hooks.disarm() }
        guard ftruncate(descriptor, 0) == 0 else { return false }
        return Self.write(text, to: descriptor, with: hooks.write)
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

/// The run's one save of its report (code review r2 of #101, must A). The
/// first ending path to get here claims the save and runs it, under the
/// report file's own deadline. Every other path, a second signal's
/// included, never saves: it waits for that save to finish, at most until
/// the save's deadline (and a short margin for the alarm to act), and only
/// then goes on to drain the console and exit. If the save hangs, the
/// deadline's alarm ends the process, as #98's emergency exit does.
public final class OneShotSave: @unchecked Sendable {
    /// The save's deadline, in seconds.
    public let deadline: Double
    /// How long a waiter waits past the deadline, for the alarm to act.
    public let margin: Double
    private let condition = NSCondition()
    private var claimedAt: Date?
    private var finished = false
    private var saved = false

    public init(deadline: Double = Double(EmergencyExit.deadline), margin: Double = 0.5) {
        self.deadline = deadline
        self.margin = margin
    }

    /// Runs `save` if no path has claimed the save yet; otherwise waits for
    /// the claimed one. Returns whether the report was saved.
    public func save(_ save: () -> Bool) -> Bool {
        condition.lock()
        guard let claimedAt else {
            self.claimedAt = Date()
            condition.unlock()
            let result = save()
            condition.withLock {
                saved = result
                finished = true
                condition.broadcast()
            }
            return result
        }
        let limit = claimedAt.addingTimeInterval(deadline + margin)
        while !finished, condition.wait(until: limit) {}
        let result = finished && saved
        condition.unlock()
        return result
    }

    /// Whether the claimed save has finished.
    public var isFinished: Bool {
        condition.withLock { finished }
    }
}
