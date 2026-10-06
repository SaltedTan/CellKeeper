import Foundation

/// Runs shortcuts from the user's Shortcuts library. CellKeeperKit implements
/// it with the documented `shortcuts` command-line tool; tests use a fake.
public protocol ShortcutRunning: Sendable {
    /// The names of the shortcuts in the user's library.
    func shortcutNames() async throws -> [String]

    /// Runs the shortcut `name` with `input` as its input. Throws if the
    /// shortcut could not be run, reported an error, or did not finish in
    /// time. Returning normally says nothing about what the shortcut did.
    func runShortcut(named name: String, input: String) async throws
}

/// Reads macOS's current Charge Limit. CellKeeperKit implements it with the
/// undocumented, read-only `pmset -g battlimit` report; tests use a fake.
public protocol ChargeLimitReading: Sendable {
    func readChargeLimit() async throws -> NativeChargeLimitReading
}

/// Durable storage for the record of the user's own limit. CellKeeperKit
/// implements it as a file; tests use an in-memory fake.
public protocol OwnershipRecordStore: Sendable {
    /// The stored record, or nil if there is none. Throws if a record exists
    /// but cannot be read.
    func load() throws -> Data?

    /// Stores `data` so that it survives a crash or power loss before this
    /// returns, and verifies it. Throws if that cannot be guaranteed.
    func save(_ data: Data) throws

    func remove() throws
}

/// What macOS reports about its Charge Limit.
public enum NativeChargeLimitReading: Sendable, Equatable {
    /// An active Charge Limit of this percentage.
    case limit(Int)
    /// No battery level limit. Observed when the Charge Limit is set to 100%.
    case noLimit
    /// The report could not be interpreted; the detail says why.
    case unrecognized(String)

    /// The limit in percent, 100 for no limit, or nil if unrecognised.
    public var percent: Int? {
        switch self {
        case .limit(let percent): percent
        case .noLimit: 100
        case .unrecognized: nil
        }
    }
}

/// Sets macOS's own Charge Limit (macOS 26.4 or later, Apple silicon) by
/// running a shortcut that the user created around Apple's "Set Battery
/// Charge Limit" action. macOS, not CellKeeper, then enforces the limit.
///
/// Ownership: before its first change the backend reads the user's own
/// limit and stores it durably. Restoring `.normal` sets exactly that value
/// again and forgets it only once the restore is read back. If the user's
/// limit cannot be read and recognised, the backend refuses to change
/// anything. A report of "no limit" is recorded as 100% only after the user
/// has confirmed it in this session, because it could also be temporary.
///
/// Confirmation: running a shortcut proves nothing. Every change is
/// confirmed by reading the setting back from macOS.
///
/// The backend is an actor, but its operations contain suspension points.
/// The controller serialises all calls into it, which the record logic
/// relies on.
public actor NativeChargeLimitBackend: ChargingBackend {
    public static let identifier = "native-charge-limit"
    public static let defaultShortcutName = "CellKeeper Set Charge Limit"
    /// The values Apple's Charge Limit accepts: 80–100% in 5% steps.
    public static let supportedLimits = [80, 85, 90, 95, 100]
    /// How long a successful check that the shortcut exists is trusted.
    public static let shortcutCheckValidity: TimeInterval = 5 * 60

    /// The persisted record of the user's own limit.
    struct OwnershipRecord: Codable, Equatable {
        /// The user's own limit, read before CellKeeper's first change.
        var ownerLimit: Int
        /// The limit CellKeeper last confirmed.
        var target: Int
        /// A limit CellKeeper started setting but has not confirmed. Either
        /// it or ``target`` may be in effect after an interrupted change.
        var pendingTarget: Int?
        var recordedAt: Date

        func accepts(_ percent: Int) -> Bool {
            percent == target || percent == pendingTarget
        }
    }

    private enum RecordState {
        case none
        case owned(OwnershipRecord)
        case unreadable
    }

    public nonisolated let descriptor: BackendDescriptor
    public nonisolated let shortcutName: String

    private let runner: any ShortcutRunning
    private let reader: any ChargeLimitReading
    private let store: any OwnershipRecordStore
    private let platformIssue: String?
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval

    private var record: RecordState
    private var hasReconciledRecord = false
    private var isNoLimitConfirmed = false
    private var shortcutConfirmedAtUptime: TimeInterval?
    private var lastReading: NativeChargeLimitReading?
    private var lastReadAt: Date?
    private var lastReadProblem: String?

    /// - Parameters:
    ///   - store: where the user's own limit is recorded.
    ///   - platformIssue: why this Mac cannot use the Charge Limit, or nil.
    public init(
        shortcutName: String = NativeChargeLimitBackend.defaultShortcutName,
        runner: any ShortcutRunning,
        reader: any ChargeLimitReading,
        store: any OwnershipRecordStore,
        platformIssue: String?,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.shortcutName = shortcutName
        self.runner = runner
        self.reader = reader
        self.store = store
        self.platformIssue = platformIssue
        self.now = now
        self.uptime = uptime
        self.descriptor = BackendDescriptor(
            identifier: Self.identifier,
            displayName: "macOS Charge Limit",
            summary: "Sets macOS's own Charge Limit (80–100%) by running your “\(shortcutName)” shortcut, and macOS enforces it. Your own limit is recorded first and restored when CellKeeper stops managing it."
        )
        self.record = Self.loadRecord(from: store)
    }

    /// True if `store` holds a record, readable or not: an earlier session
    /// may have left macOS's Charge Limit changed.
    public static func hasOutstandingRecord(in store: any OwnershipRecordStore) -> Bool {
        do {
            return try store.load() != nil
        } catch {
            return true
        }
    }

    // MARK: - ChargingBackend

    public func capabilities() async -> ControlCapabilities {
        let style = ControlStyle.nativeLimit(steps: Self.supportedLimits)
        if let platformIssue {
            return .unavailable(platformIssue, style: style)
        }
        if case .unreadable = record {
            return .unavailable("CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.", style: style)
        }
        if let checked = shortcutConfirmedAtUptime, uptime() - checked < Self.shortcutCheckValidity {
            return .nativeLimit(availability: .experimental, steps: Self.supportedLimits)
        }
        let names: [String]
        do {
            names = try await runner.shortcutNames()
        } catch {
            return .unavailable("Could not list your shortcuts: \(error)", style: style)
        }
        guard names.contains(shortcutName) else {
            return .unavailable("No shortcut named “\(shortcutName)” was found. Create it as described in Settings › Control.", style: style)
        }
        if case .none = record {
            // Without a record CellKeeper must be able to read and recognise
            // the user's limit before it may change it.
            switch try? await read() {
            case .limit:
                break
            case .noLimit:
                if !isNoLimitConfirmed {
                    return .unavailable("macOS reports no Charge Limit. That usually means 100%, but could be a temporary full charge. If your limit is 100%, confirm it in Settings › Control.", style: style)
                }
            case .unrecognized(let detail):
                return .unavailable("macOS reported its Charge Limit in a form CellKeeper does not recognise (\(detail)).", style: style)
            case nil:
                return .unavailable("Could not read macOS's current Charge Limit\(lastReadProblem.map { ": \($0)" } ?? ".")", style: style)
            }
        }
        shortcutConfirmedAtUptime = uptime()
        return .nativeLimit(availability: .experimental, steps: Self.supportedLimits)
    }

    public func currentMode() async throws -> ChargeControlMode? {
        switch record {
        case .unreadable:
            _ = try? await read()
            return nil
        case .none:
            // CellKeeper holds nothing, so the user's own limit is in effect
            // whatever it is. The read only keeps the status current.
            _ = try? await read()
            return .normal
        case .owned(var owned):
            let reading = try await read()
            guard let percent = reading.percent else { return nil }
            if !hasReconciledRecord {
                hasReconciledRecord = true
                if percent == owned.ownerLimit {
                    // A restore finished after an earlier session stopped
                    // waiting for it, or the user restored their own limit.
                    clearRecord(reason: "your own limit of \(owned.ownerLimit)% is already in effect")
                    return .normal
                }
            }
            if let pending = owned.pendingTarget, percent == pending {
                // An interrupted change took effect after all.
                owned.target = pending
                owned.pendingTarget = nil
                try? saveRecord(owned)
            }
            return .nativeLimit(percent: percent)
        }
    }

    public func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        hasReconciledRecord = true
        switch mode {
        case .normal:
            return try await restoreOwnerLimit()
        case .nativeLimit(let percent):
            return try await setLimit(percent)
        case .inhibitCharging, .forceDischarge:
            throw BackendError.unsupportedMode(mode)
        }
    }

    public func nativeLimitStatus() async -> NativeLimitStatus? {
        var status = NativeLimitStatus(reportedLimit: lastReading?.percent, readAt: lastReadAt, readProblem: lastReadProblem)
        switch record {
        case .none:
            status.needsNoLimitConfirmation = lastReading == .noLimit && !isNoLimitConfirmed
        case .owned(let owned):
            status.ownerLimit = owned.ownerLimit
            status.target = owned.target
        case .unreadable:
            status.isRecordUnreadable = true
        }
        return status
    }

    /// Forgets the cached result of the shortcut check, so the next
    /// capability check looks again (for example after the user created it).
    public func recheckAvailability() {
        shortcutConfirmedAtUptime = nil
    }

    /// The user confirmed that their own Charge Limit is 100%, so a report of
    /// "no limit" may be recorded as 100% during this session.
    public func confirmNoLimitIsOwnerLimit() {
        isNoLimitConfirmed = true
        shortcutConfirmedAtUptime = nil
    }

    /// Discards a record that cannot be read, after the user has set their
    /// own limit by hand. Does nothing if the record is readable or absent.
    public func discardUnreadableRecord() throws {
        guard case .unreadable = record else { return }
        try store.remove()
        record = .none
        hasReconciledRecord = true
        CellKeeperLog.safety.notice("The unreadable record of the user's Charge Limit was discarded at the user's request")
    }

    // MARK: - Changes

    private func setLimit(_ percent: Int) async throws -> ControlOutcome {
        guard Self.supportedLimits.contains(percent) else {
            throw BackendError.unsupportedMode(.nativeLimit(percent: percent))
        }
        if let platformIssue {
            throw BackendError.unavailable(platformIssue)
        }
        if case .unreadable = record {
            throw BackendError.unavailable("CellKeeper's record of your own Charge Limit cannot be read.")
        }
        let current = try await read()
        guard let currentPercent = current.percent else {
            throw BackendError.operationFailed("macOS's current Charge Limit could not be recognised, so CellKeeper will not change it.")
        }

        var owned: OwnershipRecord
        switch record {
        case .unreadable:
            throw BackendError.unavailable("CellKeeper's record of your own Charge Limit cannot be read.")
        case .none:
            guard Self.supportedLimits.contains(currentPercent) else {
                throw BackendError.operationFailed("macOS reports an unexpected Charge Limit of \(currentPercent)%, so CellKeeper will not change it.")
            }
            if current == .noLimit, !isNoLimitConfirmed {
                throw BackendError.operationFailed("macOS reports no Charge Limit; CellKeeper records that as 100% only after you confirm it.")
            }
            owned = OwnershipRecord(ownerLimit: currentPercent, target: currentPercent, recordedAt: now())
            CellKeeperLog.backend.notice("Recording the user's own Charge Limit: \(currentPercent)%")
        case .owned(let existing):
            guard existing.accepts(currentPercent) else {
                throw BackendError.changedOutside(expected: .nativeLimit(percent: existing.target), found: .nativeLimit(percent: currentPercent))
            }
            owned = existing
            owned.target = currentPercent
        }

        if currentPercent == percent {
            owned.target = percent
            owned.pendingTarget = nil
            try saveRecord(owned)
            return .unchanged
        }
        // The record, including the value about to be set, is durable before
        // anything changes.
        owned.pendingTarget = percent
        try saveRecord(owned)
        try await runShortcut(percent)
        try await confirm(percent, expected: .nativeLimit(percent: percent))
        owned.target = percent
        owned.pendingTarget = nil
        do {
            try saveRecord(owned)
        } catch {
            // The stored record still lists this value as pending, which
            // counts as CellKeeper's own; nothing is lost.
            CellKeeperLog.backend.error("Could not update the Charge Limit record after a confirmed change: \(String(describing: error), privacy: .public)")
        }
        return .applied
    }

    private func restoreOwnerLimit() async throws -> ControlOutcome {
        switch record {
        case .none:
            return .unchanged
        case .unreadable:
            throw BackendError.unavailable("CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore.")
        case .owned(let owned):
            // Restoring is attempted even if the setting cannot be read first;
            // only the read-back afterwards can confirm it.
            if let current = try? await read(), current.percent == owned.ownerLimit {
                clearRecord(reason: "\(owned.ownerLimit)% already in effect")
                return .unchanged
            }
            try await runShortcut(owned.ownerLimit)
            try await confirm(owned.ownerLimit, expected: .normal)
            clearRecord(reason: "restored \(owned.ownerLimit)%")
            return .applied
        }
    }

    private func runShortcut(_ percent: Int) async throws {
        let started = uptime()
        do {
            try await runner.runShortcut(named: shortcutName, input: String(percent))
        } catch {
            // The shortcut may have gone; look for it again next time.
            shortcutConfirmedAtUptime = nil
            CellKeeperLog.backend.error("Shortcut run for \(percent)% failed after \(self.uptime() - started, format: .fixed(precision: 2)) s: \(String(describing: error), privacy: .public)")
            throw BackendError.operationFailed("The “\(shortcutName)” shortcut failed: \(error)")
        }
        CellKeeperLog.backend.notice("Shortcut run for \(percent)% finished in \(self.uptime() - started, format: .fixed(precision: 2)) s; reading the setting back")
    }

    /// Reads the setting back. Only this confirms a change.
    private func confirm(_ percent: Int, expected: ChargeControlMode) async throws {
        let reading = try await read()
        guard reading.percent == percent else {
            CellKeeperLog.backend.error("Read-back after setting \(percent)%: \(String(describing: reading), privacy: .public)")
            throw BackendError.verificationFailed(expected: expected, actual: reading.percent.map { .nativeLimit(percent: $0) })
        }
    }

    private func read() async throws -> NativeChargeLimitReading {
        lastReadAt = now()
        do {
            let reading = try await reader.readChargeLimit()
            lastReading = reading
            if case .unrecognized(let detail) = reading {
                lastReadProblem = "unrecognised report (\(detail))"
            } else {
                lastReadProblem = nil
            }
            return reading
        } catch {
            lastReading = nil
            lastReadProblem = String(describing: error)
            throw BackendError.operationFailed("Could not read macOS's Charge Limit: \(error)")
        }
    }

    // MARK: - Record

    private static func loadRecord(from store: any OwnershipRecordStore) -> RecordState {
        let data: Data?
        do {
            data = try store.load()
        } catch {
            CellKeeperLog.safety.fault("The record of the user's own Charge Limit cannot be read: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
        guard let data else { return .none }
        guard let owned = try? JSONDecoder().decode(OwnershipRecord.self, from: data),
              supportedLimits.contains(owned.ownerLimit), supportedLimits.contains(owned.target),
              owned.pendingTarget.map(supportedLimits.contains) ?? true
        else {
            CellKeeperLog.safety.fault("The record of the user's own Charge Limit is invalid; refusing to change the Charge Limit")
            return .unreadable
        }
        return .owned(owned)
    }

    private func saveRecord(_ owned: OwnershipRecord) throws {
        do {
            try store.save(try JSONEncoder().encode(owned))
        } catch {
            throw BackendError.operationFailed("Could not record your own Charge Limit durably, so nothing was changed: \(error)")
        }
        record = .owned(owned)
    }

    private func clearRecord(reason: String) {
        do {
            try store.remove()
        } catch {
            // The next launch finds the record and sees the user's limit in
            // effect, which clears it.
            CellKeeperLog.backend.error("Could not delete the Charge Limit record: \(String(describing: error), privacy: .public)")
        }
        record = .none
        CellKeeperLog.backend.notice("Released the Charge Limit: \(reason, privacy: .public)")
    }
}
