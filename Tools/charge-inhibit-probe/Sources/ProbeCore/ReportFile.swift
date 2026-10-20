import Foundation

/// `watch`'s report file, opened when the run starts and kept open. A save
/// replaces its contents. It has no deadline of its own: the ending's
/// watchdog, armed before any save is claimed, bounds it
/// (``EndingWatchdog``, code review r3 of #101, must 1). The write is a
/// hook, so the tests can pause a save.
public final class ReportFile: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// One positioned write; returns what `pwrite(2)` returns.
        public var write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int

        public init(write: @escaping @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) -> Int) {
            self.write = write
        }

        /// `watch`'s: `pwrite(2)`.
        public static let real = Hooks { descriptor, bytes, offset in
            pwrite(descriptor, bytes.baseAddress, bytes.count, offset)
        }
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

    /// Saves `text` as the whole report; returns whether it was saved.
    /// Called once per run, by the ending path that settles the end
    /// (``ManualCutEnding``), after the ending's watchdog is armed.
    public func persist(_ text: String) -> Bool {
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
