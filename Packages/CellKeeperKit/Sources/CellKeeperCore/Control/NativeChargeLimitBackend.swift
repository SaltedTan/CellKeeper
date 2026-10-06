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
/// Outside changes: a recognised limit that CellKeeper did not set (for
/// example one the user chose in System Settings) is adopted as the user's
/// own limit. The record is forgotten and nothing is written, so a
/// deliberate change is never overwritten, not even by a restore.
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
        /// Limits CellKeeper started setting since ``target`` was confirmed.
        /// Any of them may be in effect after an interrupted change.
        var pendingTargets: Set<Int> = []
        /// CellKeeper started restoring ``ownerLimit`` but has not confirmed it.
        var isRestoring = false
        var recordedAt: Date

        init(ownerLimit: Int, target: Int, recordedAt: Date) {
            self.ownerLimit = ownerLimit
            self.target = target
            self.recordedAt = recordedAt
        }

        private enum CodingKeys: String, CodingKey {
            case ownerLimit, target, pendingTargets, isRestoring, recordedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ownerLimit = try container.decode(Int.self, forKey: .ownerLimit)
            target = try container.decode(Int.self, forKey: .target)
            pendingTargets = try container.decodeIfPresent(Set<Int>.self, forKey: .pendingTargets) ?? []
            isRestoring = try container.decodeIfPresent(Bool.self, forKey: .isRestoring) ?? false
            recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        }

        /// True if `percent` may be in effect because of CellKeeper.
        func accepts(_ percent: Int) -> Bool {
            percent == target || pendingTargets.contains(percent) || (isRestoring && percent == ownerLimit)
        }

        /// `percent` was read back: it is now the only value CellKeeper has
        /// in effect, and CellKeeper is about to set it or has just set it.
        mutating func confirm(_ percent: Int) {
            target = percent
            pendingTargets = []
            isRestoring = false
        }

        /// A pending value was found in effect. An unfinished restore stays
        /// unfinished: finding an earlier change does not cancel it.
        mutating func promote(_ percent: Int) {
            target = percent
            pendingTargets = []
        }
    }

    /// Stored in place of the record after an outside change was adopted,
    /// until the app has saved "Manage charging" as off. A crash in between
    /// then cannot let a relaunch override the adopted limit. Holds nothing
    /// to restore.
    struct AdoptionMarker: Codable, Equatable {
        var adoptedLimit: Int
        var isNoLimit: Bool
        var previousOwnerLimit: Int
        var expectedLimit: Int
        var adoptedAt: Date

        func change(fromEarlierSession: Bool) -> AdoptedLimitChange {
            AdoptedLimitChange(limit: adoptedLimit, isNoLimit: isNoLimit, previousOwnerLimit: previousOwnerLimit, expectedLimit: expectedLimit, date: adoptedAt, isFromEarlierSession: fromEarlierSession)
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
    private var isLastReportedStateOwn = false
    private var adoptedChange: AdoptedLimitChange?

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
        self.adoptedChange = Self.loadAdoptionMarker(from: store)?.change(fromEarlierSession: true)
    }

    /// A change adopted in an earlier session whose marker is still stored,
    /// read without a backend. The app turns management off and then
    /// removes the marker with ``removeAdoptionMarker(in:)``.
    public static func pendingAdoption(in store: any OwnershipRecordStore) -> AdoptedLimitChange? {
        loadAdoptionMarker(from: store)?.change(fromEarlierSession: true)
    }

    /// Removes an adoption marker once "Manage charging" has been saved as
    /// off. Does nothing unless the store holds a marker, so it can never
    /// delete a record of the user's own limit.
    public static func removeAdoptionMarker(in store: any OwnershipRecordStore) throws {
        guard loadAdoptionMarker(from: store) != nil else { return }
        try store.remove()
    }

    /// A record in a store, read without a backend.
    public struct OutstandingRecord: Sendable, Equatable {
        /// The user's own limit, or nil if the record cannot be read.
        public var ownerLimit: Int?
    }

    /// The record in `store`, readable or not, or nil if there is none. A
    /// record means CellKeeper may have left macOS's Charge Limit changed.
    public static func outstandingRecord(in store: any OwnershipRecordStore) -> OutstandingRecord? {
        switch loadRecord(from: store) {
        case .none: nil
        case .owned(let owned): OutstandingRecord(ownerLimit: owned.ownerLimit)
        case .unreadable: OutstandingRecord(ownerLimit: nil)
        }
    }

    /// True if `store` holds a record, readable or not.
    public static func hasOutstandingRecord(in store: any OwnershipRecordStore) -> Bool {
        outstandingRecord(in: store) != nil
    }

    // MARK: - ChargingBackend

    public func capabilities() async -> ControlCapabilities {
        let style = ControlStyle.nativeLimit(steps: Self.supportedLimits)
        if let platformIssue {
            return .unavailable(platformIssue, style: style)
        }
        switch record {
        case .unreadable:
            return .unavailable("CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.", style: style)
        case .owned:
            // Restoring must not wait for, or depend on, listing shortcuts; a
            // missing shortcut shows up as a failed run.
            return .nativeLimit(availability: .experimental, steps: Self.supportedLimits)
        case .none:
            break
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
        isLastReportedStateOwn = false
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
            if owned.isRestoring, percent == owned.ownerLimit {
                // A restore that could not be confirmed took effect.
                clearRecord(reason: "your own limit of \(owned.ownerLimit)% is now in effect")
                isLastReportedStateOwn = true
                return .normal
            }
            guard owned.accepts(percent) else {
                adopt(reading, replacing: owned)
                return .normal
            }
            isLastReportedStateOwn = true
            if owned.pendingTargets.contains(percent) {
                // An interrupted change took effect after all. The stored
                // record already accepts this value, so a failed save loses
                // nothing.
                owned.promote(percent)
                saveRecordBestEffort(owned)
            }
            return .nativeLimit(percent: percent)
        }
    }

    public func setMode(_ mode: ChargeControlMode) async throws -> ControlOutcome {
        let isFirstContact = !hasReconciledRecord
        hasReconciledRecord = true
        switch mode {
        case .normal:
            return try await restoreOwnerLimit(isFirstContact: isFirstContact)
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
            status.isRestoreUnfinished = owned.isRestoring
        case .unreadable:
            status.isRecordUnreadable = true
        }
        status.isReportedStateOwn = isLastReportedStateOwn
        return status
    }

    public func takeAdoptedLimitChange() async -> AdoptedLimitChange? {
        defer { adoptedChange = nil }
        return adoptedChange
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
                adopt(current, replacing: existing)
                return .adoptedOutsideChange
            }
            owned = existing
            owned.confirm(currentPercent)
        }

        if currentPercent == percent {
            try saveRecord(owned)
            return .unchanged
        }
        // The record, including the value about to be set, is durable before
        // anything changes.
        owned.pendingTargets.insert(percent)
        try saveRecord(owned)
        try await runShortcut(percent)
        try await confirm(percent, expected: .nativeLimit(percent: percent), owned: owned)
        owned.confirm(percent)
        // The stored record still lists this value as pending, which counts as
        // CellKeeper's own, so a failed save loses nothing.
        saveRecordBestEffort(owned)
        return .applied
    }

    /// - Parameter isFirstContact: true if no earlier read in this session
    ///   could have reconciled the record with macOS.
    private func restoreOwnerLimit(isFirstContact: Bool) async throws -> ControlOutcome {
        switch record {
        case .none:
            return .unchanged
        case .unreadable:
            throw BackendError.unavailable("CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore.")
        case .owned(var owned):
            // Restoring is attempted even if the setting cannot be read first;
            // only the read-back afterwards can confirm it.
            if let current = try? await read(), let percent = current.percent {
                // At first contact the user's limit may be back because a
                // restore finished after an earlier session stopped waiting.
                if percent == owned.ownerLimit, owned.accepts(percent) || isFirstContact {
                    clearRecord(reason: "\(owned.ownerLimit)% already in effect")
                    return .unchanged
                }
                if !owned.accepts(percent) {
                    // The user (or another tool) chose this limit, even if it
                    // is the one recorded: it is now their own, so there is
                    // nothing to give back.
                    adopt(current, replacing: owned)
                    return .adoptedOutsideChange
                }
            }
            // Mark the restore as in progress, so a later reading of the
            // user's limit is recognised as CellKeeper's own doing. Restoring
            // goes ahead even if this cannot be stored.
            owned.isRestoring = true
            saveRecordBestEffort(owned)
            try await runShortcut(owned.ownerLimit)
            try await confirm(owned.ownerLimit, expected: .normal, owned: owned)
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

    /// Reads the setting back. Only this confirms a change. A recognised
    /// value that `owned` does not account for was set by someone else after
    /// CellKeeper's write: it is adopted at once, so no later restore (which
    /// might not manage to read first) can overwrite it.
    private func confirm(_ percent: Int, expected: ChargeControlMode, owned: OwnershipRecord) async throws {
        let reading = try await read()
        guard reading.percent == percent else {
            CellKeeperLog.backend.error("Read-back after setting \(percent)%: \(String(describing: reading), privacy: .public)")
            if let found = reading.percent, !owned.accepts(found) {
                adopt(reading, replacing: owned)
            }
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
        if decodeAdoptionMarker(data) != nil {
            // An adopted change leaves nothing to restore.
            return .none
        }
        guard let owned = try? JSONDecoder().decode(OwnershipRecord.self, from: data),
              supportedLimits.contains(owned.ownerLimit), supportedLimits.contains(owned.target),
              owned.pendingTargets.allSatisfy(supportedLimits.contains)
        else {
            CellKeeperLog.safety.fault("The record of the user's own Charge Limit is invalid; refusing to change the Charge Limit")
            return .unreadable
        }
        return .owned(owned)
    }

    private static func loadAdoptionMarker(from store: any OwnershipRecordStore) -> AdoptionMarker? {
        guard let data = try? store.load() else { return nil }
        return decodeAdoptionMarker(data)
    }

    private static func decodeAdoptionMarker(_ data: Data) -> AdoptionMarker? {
        guard let marker = try? JSONDecoder().decode(AdoptionMarker.self, from: data),
              supportedLimits.contains(marker.adoptedLimit), supportedLimits.contains(marker.previousOwnerLimit),
              supportedLimits.contains(marker.expectedLimit)
        else { return nil }
        return marker
    }

    private func saveRecord(_ owned: OwnershipRecord) throws {
        do {
            try store.save(try JSONEncoder().encode(owned))
        } catch {
            throw BackendError.operationFailed("Could not record your own Charge Limit durably, so nothing was changed: \(error)")
        }
        record = .owned(owned)
    }

    /// Saves the record, keeping the in-memory copy current even if the
    /// store fails. Only for updates the stored record already covers.
    private func saveRecordBestEffort(_ owned: OwnershipRecord) {
        record = .owned(owned)
        do {
            try store.save(try JSONEncoder().encode(owned))
        } catch {
            CellKeeperLog.backend.error("Could not update the Charge Limit record: \(String(describing: error), privacy: .public)")
        }
    }

    /// Adopts a recognised limit that CellKeeper did not set as the user's
    /// own: the record is replaced by an adoption marker (nothing to
    /// restore) and nothing is written to macOS.
    private func adopt(_ reading: NativeChargeLimitReading, replacing owned: OwnershipRecord) {
        guard let percent = reading.percent else { return }
        let marker = AdoptionMarker(
            adoptedLimit: percent,
            isNoLimit: reading == .noLimit,
            previousOwnerLimit: owned.ownerLimit,
            expectedLimit: owned.target,
            adoptedAt: now()
        )
        adoptedChange = marker.change(fromEarlierSession: false)
        isLastReportedStateOwn = false
        let reason = "adopted \(percent)%, set outside CellKeeper, as the user's own limit (CellKeeper had set \(owned.target)%; the recorded limit was \(owned.ownerLimit)%)"
        do {
            try store.save(try JSONEncoder().encode(marker))
        } catch {
            // Without the marker, at least never restore over the change.
            CellKeeperLog.backend.error("Could not store the adoption marker: \(String(describing: error), privacy: .public)")
            clearRecord(reason: reason)
            return
        }
        record = .none
        CellKeeperLog.backend.notice("Released the Charge Limit: \(reason, privacy: .public)")
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
