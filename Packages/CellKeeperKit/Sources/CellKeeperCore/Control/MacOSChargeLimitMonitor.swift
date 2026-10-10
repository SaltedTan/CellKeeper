import CellKeeperHelperCore
import Foundation

/// What CellKeeper last read about macOS's own Charge Limit, for a backend
/// that switches charging itself (safety precondition 7). While macOS may be
/// limiting charging, such a backend offers no restricting mode, and the
/// policy withholds new restrictions and asks for the release of any of
/// CellKeeper's own; only a read-back says whether that release happened.
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
/// - Reads are numbered, and only the newest one settled counts: a result is
///   kept only if no later read has been kept or cancelled, and a caller
///   whose read was overtaken that way gets the current reading instead (see
///   ``ReadingCache``).
/// - A caller that is cancelled (quitting, for example) cancels the read it
///   waits for, so it never waits for the reader's own deadline. A cancelled
///   read is not kept, and the reading before it is dropped too, so the next
///   call reads again. Another caller still waiting for that read, and not
///   cancelled itself, reads again rather than take the cancelled result.
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

    /// The reading kept, and how far the numbered reads have settled.
    /// Reads start in number order, but their waiters may resume in any
    /// order, so a result is judged against every read settled before it,
    /// not only against the reading kept now.
    struct ReadingCache: Sendable, Equatable {
        struct Reading: Sendable, Equatable {
            var status: MacOSChargeLimitStatus
            /// ``uptime`` when the read started.
            var startedAt: TimeInterval
            var number: Int
        }

        /// The reading kept; nil before the first and after a cancelled read.
        private(set) var latest: Reading?
        /// The newest read kept or cancelled. Nothing older counts any more.
        private(set) var settledThrough = 0

        /// Keeps the result of read `number` unless a later read has been
        /// kept or cancelled. Returns whether it was kept.
        @discardableResult
        mutating func keep(_ status: MacOSChargeLimitStatus, startedAt: TimeInterval, number: Int) -> Bool {
            guard number > settledThrough else { return false }
            settledThrough = number
            latest = Reading(status: status, startedAt: startedAt, number: number)
            return true
        }

        /// Read `number` was cancelled: nothing was learned, so no earlier
        /// reading may stand in for it.
        mutating func cancel(_ number: Int) {
            guard number > settledThrough else { return }
            settledThrough = number
            latest = nil
        }

        /// True if a later read than `number` has been kept or cancelled.
        func isOvertaken(_ number: Int) -> Bool {
            number < settledThrough
        }
    }

    private struct PendingRead {
        var task: Task<MacOSChargeLimitStatus, Never>
        var startedAt: TimeInterval
        var number: Int
    }

    private var cache = ReadingCache()
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
        if let latest = cache.latest {
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
        cache.latest?.status
    }

    /// Waits for `read`, cancelling it if the caller is cancelled, and
    /// settles it before returning. A caller that is not cancelled itself
    /// never gets a cancelled or overtaken result: it reads again, or takes
    /// the current reading.
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
        let wasCancelled = task.isCancelled
        if wasCancelled {
            cache.cancel(read.number)
        } else {
            cache.keep(status, startedAt: read.startedAt, number: read.number)
        }
        if !wasCancelled, !cache.isOvertaken(read.number) {
            return status
        }
        // A cancelled or overtaken read contributes nothing, whatever the
        // reader returned.
        if Task.isCancelled {
            return MacOSChargeLimitStatus(reportedLimit: nil, readAt: now(), readProblem: "the read was cancelled")
        }
        // Another caller's cancellation stopped the read: read again. Or a
        // later read settled first: take the current reading.
        return wasCancelled ? await refresh() : await self.status()
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
