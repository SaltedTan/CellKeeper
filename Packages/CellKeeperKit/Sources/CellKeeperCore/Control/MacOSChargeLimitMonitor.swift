import CellKeeperHelperCore
import Foundation

/// What CellKeeper last read about macOS's own Charge Limit, for a backend
/// that switches charging itself (safety precondition 7). While macOS may be
/// limiting charging, such a backend withholds its own restrictions and the
/// policy asks for normal charging, so two limits never compete.
public struct MacOSChargeLimitStatus: Sendable, Equatable {
    /// The limit macOS reported, in percent, or nil if the report could not
    /// be read or recognised. 100 when macOS reports no active limit; that
    /// does not establish that the setting is 100% (a temporary full charge
    /// may look the same; research note 08, I2).
    public var reportedLimit: Int?
    /// True if macOS reported no active limit at all ("No battery level
    /// limits set"), rather than a percentage.
    public var isNoLimitReported: Bool
    /// When the report was read.
    public var readAt: Date
    /// Why the report did not give a limit, if it did not.
    public var readProblem: String?

    public init(reportedLimit: Int?, isNoLimitReported: Bool = false, readAt: Date, readProblem: String? = nil) {
        self.reportedLimit = reportedLimit
        self.isNoLimitReported = reportedLimit != nil && isNoLimitReported
        self.readAt = readAt
        self.readProblem = reportedLimit == nil ? (readProblem ?? "no report") : nil
    }

    /// True if macOS may be limiting charging: its Charge Limit is below
    /// 100%, or its report could not be read or recognised (an Optimized
    /// Battery Charging entry or a temporary state would look like that;
    /// research note 08, I3). Nothing is guessed: only a recognised report
    /// of no active limit, or of 100%, counts as off. That still does not
    /// establish that macOS holds nothing: a hold that leaves no entry in the
    /// report is not seen.
    public var isLimiting: Bool {
        guard let reportedLimit else { return true }
        return reportedLimit < 100
    }
}

/// Watches macOS's own Charge Limit for a backend that switches charging
/// itself, through a ``ChargeLimitReading`` (in the app, the read-only
/// `pmset -g battlimit` report).
///
/// - The latest reading is kept with its date. ``status()`` reads again only
///   when it is older than ``maximumAge``, so the several capability checks
///   of one evaluation (evaluations run every 60 s and on events) run the
///   reader at most once.
/// - ``refresh()`` reads again at once, for the user's "check again".
/// - A read under way is shared: ``status()`` and ``refresh()`` wait for it
///   rather than return an older reading, and its result is kept before any
///   of them returns.
/// - A caller that is cancelled (quitting, for example) cancels the read it
///   waits for, so it never waits for the reader's own deadline. A cancelled
///   read is not kept, and the reading before it is dropped too, so the next
///   call reads again.
/// - A failed read is kept like any other: it replaces an earlier reading of
///   "off".
///
/// The monitor never changes anything: CellKeeper never turns macOS's
/// Charge Limit off itself.
public actor MacOSChargeLimitMonitor {
    /// How long a reading is reused before it is read again.
    public static let defaultMaximumAge: TimeInterval = 30

    public nonisolated let maximumAge: TimeInterval
    private let reader: any ChargeLimitReading
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

    private struct Reading {
        var status: MacOSChargeLimitStatus
        /// ``uptime`` when the read started.
        var startedAt: TimeInterval
        var number: Int
    }

    private struct PendingRead {
        var task: Task<MacOSChargeLimitStatus, Never>
        var startedAt: TimeInterval
        var number: Int
    }

    private var latest: Reading?
    private var inFlight: PendingRead?
    private var readCount = 0

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

    /// The latest reading: the one under way if there is one, otherwise the
    /// cached one unless there is none yet or it is older than
    /// ``maximumAge`` (or dated in the future of the monotonic clock), in
    /// which case it is read again.
    public func status() async -> MacOSChargeLimitStatus {
        if let inFlight {
            return await wait(for: inFlight)
        }
        if let latest {
            let age = uptime() - latest.startedAt
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
            return await wait(for: inFlight)
        }
        let reader = reader
        let now = now
        readCount += 1
        let read = PendingRead(task: Task { await Self.read(reader, now: now) }, startedAt: uptime(), number: readCount)
        inFlight = read
        return await wait(for: read)
    }

    /// The latest reading kept, without reading; nil before the first and
    /// after a cancelled read.
    public var lastStatus: MacOSChargeLimitStatus? {
        latest?.status
    }

    /// Waits for `read`, cancelling it if the caller is cancelled, and keeps
    /// its result (unless it was cancelled) before returning it.
    private func wait(for read: PendingRead) async -> MacOSChargeLimitStatus {
        let task = read.task
        let status = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight?.number == read.number {
            inFlight = nil
        }
        if task.isCancelled {
            // Nothing was learned; an older reading must not stand in for it.
            if (latest?.number ?? 0) < read.number {
                latest = nil
            }
        } else if (latest?.number ?? 0) < read.number {
            latest = Reading(status: status, startedAt: read.startedAt, number: read.number)
        }
        return status
    }

    private static func read(_ reader: any ChargeLimitReading, now: @Sendable () -> Date) async -> MacOSChargeLimitStatus {
        let readAt = now()
        do {
            switch try await reader.readChargeLimit() {
            case .limit(let percent):
                return MacOSChargeLimitStatus(reportedLimit: percent, readAt: readAt)
            case .noLimit:
                return MacOSChargeLimitStatus(reportedLimit: 100, isNoLimitReported: true, readAt: readAt)
            case .unrecognized(let detail):
                return MacOSChargeLimitStatus(reportedLimit: nil, readAt: readAt, readProblem: "unrecognised report (\(detail))")
            }
        } catch is CancellationError {
            return MacOSChargeLimitStatus(reportedLimit: nil, readAt: readAt, readProblem: "the read was cancelled")
        } catch {
            return MacOSChargeLimitStatus(reportedLimit: nil, readAt: readAt, readProblem: String(describing: error))
        }
    }
}
