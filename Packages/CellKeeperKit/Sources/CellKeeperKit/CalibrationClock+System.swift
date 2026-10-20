import CellKeeperCore
import Darwin
import Foundation

extension CalibrationClock {
    /// The Mac's own clocks, read-only: `CLOCK_MONOTONIC`, which on macOS
    /// keeps counting during sleep and starts again at boot; the boot's
    /// identifier (`kern.bootsessionuuid`), which changes at every boot; and
    /// the boot time (`kern.boottime`). A value that cannot be read is nil,
    /// and the calibration then counts only its own run as the same boot.
    public static func system() -> CalibrationClock {
        CalibrationClock(
            monotonic: { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 },
            bootSession: { bootSessionIdentifier() },
            bootTime: { bootTime() }
        )
    }

    static func bootSessionIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let identifier = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return identifier.isEmpty ? nil : identifier
    }

    static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
