import CellKeeperHelperCore
import Foundation

/// What CellKeeper last read about macOS's own Charge Limit, for a backend
/// that switches charging itself (safety precondition 7). While macOS
/// limits charging, or CellKeeper cannot tell whether it does, such a
/// backend restricts nothing, so two limits never compete.
public struct MacOSChargeLimitStatus: Sendable, Equatable {
    /// The limit macOS reported, in percent (100 for no limit), or nil if
    /// the report could not be read or recognised.
    public var reportedLimit: Int?
    /// When the report was read.
    public var readAt: Date
    /// Why the report did not give a limit, if it did not.
    public var readProblem: String?

    public init(reportedLimit: Int?, readAt: Date, readProblem: String? = nil) {
        self.reportedLimit = reportedLimit
        self.readAt = readAt
        self.readProblem = reportedLimit == nil ? (readProblem ?? "no report") : nil
    }

    /// True if macOS may be limiting charging: its Charge Limit is below
    /// 100%, or its report could not be read or recognised (an Optimized
    /// Battery Charging entry or a temporary state would look like that;
    /// research note 08, I3). Nothing is guessed: only a recognised report
    /// of no limit, or of 100%, counts as off.
    public var isLimiting: Bool {
        guard let reportedLimit else { return true }
        return reportedLimit < 100
    }
}

/// Watches macOS's own Charge Limit for a backend that switches charging
/// itself, through a ``ChargeLimitReading`` (in the app, the read-only
/// `pmset -g battlimit` report).
///
/// The latest reading is kept with its date. ``status()`` reads again only
/// when it is older than ``maximumAge``, so the several capability checks of
/// one evaluation (evaluations run every 60 s and on events) run the reader
/// at most once; ``refresh()`` reads again at once, for the user's "check
/// again". Concurrent callers share one read. The monitor never changes
/// anything: CellKeeper never turns macOS's Charge Limit off itself.
public actor MacOSChargeLimitMonitor {
    /// How long a reading is reused before it is read again.
    public static let defaultMaximumAge: TimeInterval = 30

    public nonisolated let maximumAge: TimeInterval
    private let reader: any ChargeLimitReading
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

    private var latest: (status: MacOSChargeLimitStatus, readAtUptime: TimeInterval)?
    private var inFlight: Task<MacOSChargeLimitStatus, Never>?

    /// - Parameters:
    ///   - maximumAge: how long a reading is reused, in seconds of `uptime`.
    ///   - now: wall-clock time, for the reading's date (display only).
    ///   - uptime: monotonic seconds, for the reading's age.
    public init(
        reader: any ChargeLimitReading,
        maximumAge: TimeInterval = MacOSChargeLimitMonitor.defaultMaximumAge,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime
    ) {
        self.reader = reader
        self.maximumAge = maximumAge
        self.now = now
        self.uptime = uptime
    }

    /// The latest reading, read again if there is none yet or it is older
    /// than ``maximumAge`` (or dated in the future of the monotonic clock).
    public func status() async -> MacOSChargeLimitStatus {
        if let latest {
            let age = uptime() - latest.readAtUptime
            if age >= 0, age < maximumAge {
                return latest.status
            }
        }
        return await refresh()
    }

    /// Reads macOS's Charge Limit now, whatever the age of the latest
    /// reading. A read already under way is shared.
    @discardableResult
    public func refresh() async -> MacOSChargeLimitStatus {
        if let inFlight {
            return await inFlight.value
        }
        let reader = reader
        let now = now
        let task = Task { await Self.read(reader, now: now) }
        inFlight = task
        let startedAt = uptime()
        let status = await task.value
        inFlight = nil
        latest = (status, startedAt)
        return status
    }

    /// The latest reading, without reading; nil before the first.
    public var lastStatus: MacOSChargeLimitStatus? {
        latest?.status
    }

    private static func read(_ reader: any ChargeLimitReading, now: @Sendable () -> Date) async -> MacOSChargeLimitStatus {
        let readAt = now()
        do {
            switch try await reader.readChargeLimit() {
            case .limit(let percent):
                return MacOSChargeLimitStatus(reportedLimit: percent, readAt: readAt)
            case .noLimit:
                return MacOSChargeLimitStatus(reportedLimit: 100, readAt: readAt)
            case .unrecognized(let detail):
                return MacOSChargeLimitStatus(reportedLimit: nil, readAt: readAt, readProblem: "unrecognised report (\(detail))")
            }
        } catch {
            return MacOSChargeLimitStatus(reportedLimit: nil, readAt: readAt, readProblem: String(describing: error))
        }
    }
}
