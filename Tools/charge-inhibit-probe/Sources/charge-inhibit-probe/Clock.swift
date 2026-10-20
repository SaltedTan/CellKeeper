import Foundation
import ProbeCore

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

    /// Seconds since 1970, on the wall clock, for comparison with the
    /// battery's `UpdateTime`.
    static var unixNow: Double {
        Date().timeIntervalSince1970
    }

    /// Sleeps until `target` run seconds, in short steps so a stop request
    /// is seen quickly. Returns false if a stop was requested.
    func pause(until target: Double, stop: StopRequest) -> Bool {
        while true {
            if stop.reason != nil { return false }
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

/// Why the run stopped early.
enum StopReason: Equatable, CustomStringConvertible {
    /// SIGINT, SIGTERM or SIGHUP.
    case signal(Int32)
    /// A system sleep notification, by its `IOMessage.h` name.
    case sleep(String)

    var description: String {
        switch self {
        case let .signal(number): signalName(number)
        case let .sleep(message): "the system's \(message)"
        }
    }
}

/// The first reason the probe was asked to stop, if any, and how many
/// signals it received.
final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var first: StopReason?
    private var signals = 0

    /// Records `reason` if it is the first.
    func record(_ reason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = reason }
    }

    /// Records a signal; returns false if a signal was already received.
    func recordSignal(_ number: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = .signal(number) }
        signals += 1
        return signals == 1
    }

    var reason: StopReason? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }
}

/// Writes to standard output or standard error at once, unbuffered, but
/// never from the sleep queue: such a write is dropped (`ProbeConsole`). A
/// write that fails (a terminal that has gone away) is dropped too, rather
/// than raising, so the run still finishes and writes its report.
enum Console {
    static let output = ProbeConsole { try? FileHandle.standardOutput.write(contentsOf: Data(($0 + "\n").utf8)) }
    static let errors = ProbeConsole { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) }

    static func out(_ line: String = "") {
        output.write(line)
    }

    static func error(_ line: String) {
        errors.write(line)
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
