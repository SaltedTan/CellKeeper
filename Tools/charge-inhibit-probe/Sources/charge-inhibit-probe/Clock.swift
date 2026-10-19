import Foundation

/// Run time on `CLOCK_MONOTONIC`, which on macOS keeps counting while the
/// system sleeps (clock_gettime(3)), so a sleep shows up as a gap between
/// readings.
struct Clock: Sendable {
    let start: UInt64

    init() {
        start = Self.nanoseconds()
    }

    static func nanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    /// Seconds since the run started.
    var now: Double {
        Double(Self.nanoseconds() &- start) / 1_000_000_000
    }

    /// Sleeps until `target` run seconds, in short steps so a stop request
    /// is seen quickly. Returns false if a stop was requested.
    func pause(until target: Double, stop: StopRequest) -> Bool {
        while true {
            if stop.signal != nil { return false }
            let remaining = target - now
            if remaining <= 0 { return true }
            Thread.sleep(forTimeInterval: min(remaining, 0.1))
        }
    }

    /// "12:34:56", local time.
    static func wallTime(_ date: Date = Date()) -> String {
        format(date, "HH:mm:ss")
    }

    /// "2026-10-19 12:34:56 +11:00", local time.
    static func wallDateTime(_ date: Date = Date()) -> String {
        format(date, "yyyy-MM-dd HH:mm:ss xxx")
    }

    /// "20261019-123456", for file names.
    static func fileStamp(_ date: Date = Date()) -> String {
        format(date, "yyyyMMdd-HHmmss")
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// The first SIGINT, SIGTERM or SIGHUP the probe received, if any.
final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?

    /// Records `signal`; returns false if one was already recorded.
    func record(_ signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard received == nil else { return false }
        received = signal
        return true
    }

    var signal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

/// Writes to standard output or standard error at once, unbuffered.
enum Console {
    static func out(_ line: String = "") {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func error(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGINT: "SIGINT"
    case SIGTERM: "SIGTERM"
    case SIGHUP: "SIGHUP"
    default: "signal \(signal)"
    }
}
