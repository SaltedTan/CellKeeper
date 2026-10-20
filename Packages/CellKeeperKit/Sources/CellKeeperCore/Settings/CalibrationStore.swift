import Foundation

/// What a calibration store holds: the session in progress, if any, and the
/// report of the latest one that ended. A session that ends is replaced by
/// its report in one write: that report, with the session's ``CalibrationSession/id``,
/// is the session's "ended" mark (note 12 §7.6).
public struct CalibrationStored: Sendable, Equatable, Codable {
    public var session: CalibrationSession?
    public var last: CalibrationReport?

    public init(session: CalibrationSession? = nil, last: CalibrationReport? = nil) {
        self.session = session
        self.last = last
    }

    public var isEmpty: Bool { session == nil && last == nil }
}

/// What a ``CalibrationStoring`` found.
public enum CalibrationLoad: Sendable, Equatable {
    /// Nothing is stored.
    case none
    case stored(CalibrationStored)
    /// Something is stored but it cannot be used; `reason` says why.
    case unusable(reason: String)
}

/// Where a guided calibration is kept, apart from ``ChargingSettings`` and
/// the full-charge schedules, so that one that cannot be read never affects
/// them.
public protocol CalibrationStoring: Sendable {
    func loadCalibration() -> CalibrationLoad
    /// Stores `stored`, or removes the value if it is empty, and reads it
    /// back; throws unless it reads back as written.
    func saveCalibration(_ stored: CalibrationStored) throws
}

/// A write or removal that did not read back as made.
public enum CalibrationStoreError: Error, Sendable, Equatable {
    case notReadBack
    case notRemoved
}

/// Keeps the guided calibration as JSON under its own key in a
/// ``KeyValueStorage`` (`UserDefaults` in the app).
///
/// - The key, `calibration.v1`, is the schema version: a later format is
///   stored under a new key, which this version never reads or removes.
/// - A value that is not JSON data, that cannot be decoded, or whose values
///   are out of range (a limit macOS's Charge Limit cannot have, a time or
///   clock reading that is not finite, a charge outside 0–100%, a step list
///   that does not end at the current step) is unusable; only no value at
///   all counts as none.
/// - Writes are read back and compared. That confirms what this process
///   reads, not that `UserDefaults` has reached the disk: after a crash or
///   power loss, the last write may be missing at the next launch, so a
///   cancelled session can come back. A session found at launch is
///   therefore never resumed without the owner's "continue".
public final class CalibrationStore: CalibrationStoring, @unchecked Sendable {
    public static let key = "calibration.v1"

    // `UserDefaults` is thread-safe; the lock keeps a write and its
    // read-back together, and serialises access for other storages, such as
    // the tests' in-memory one.
    private let lock = NSLock()
    private let defaults: any KeyValueStorage

    public init(defaults: any KeyValueStorage = UserDefaults.standard) {
        self.defaults = defaults
    }

    public func loadCalibration() -> CalibrationLoad {
        lock.withLock {
            guard let stored = defaults.object(forKey: Self.key) else {
                return .none
            }
            guard let data = stored as? Data else {
                return .unusable(reason: "it is not a calibration record")
            }
            let decoded: CalibrationStored
            do {
                decoded = try JSONDecoder().decode(CalibrationStored.self, from: data)
            } catch {
                return .unusable(reason: "it could not be read")
            }
            if let problem = decoded.session?.validationProblem ?? decoded.last?.validationProblem {
                return .unusable(reason: problem)
            }
            return .stored(decoded)
        }
    }

    public func saveCalibration(_ stored: CalibrationStored) throws {
        guard !stored.isEmpty else {
            try lock.withLock {
                defaults.set(nil, forKey: Self.key)
                guard defaults.object(forKey: Self.key) == nil else { throw CalibrationStoreError.notRemoved }
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(stored)
        try lock.withLock {
            defaults.set(data, forKey: Self.key)
            guard let readBack = defaults.object(forKey: Self.key) as? Data, readBack == data else {
                throw CalibrationStoreError.notReadBack
            }
        }
    }
}

extension CalibrationStamp {
    var isFinite: Bool {
        wall.timeIntervalSinceReferenceDate.isFinite && monotonic.isFinite
    }
}

extension CalibrationSession {
    /// Why a stored session cannot be used; nil if it can.
    var validationProblem: String? {
        guard NativeChargeLimitBackend.supportedLimits.contains(ownerLimit) else {
            return "its record of your own Charge Limit is not valid"
        }
        guard ChargingSettings.chargeLimitRange.contains(cellKeeperLimit) else {
            return "its record of CellKeeper's limit is not valid"
        }
        let stamps = [startedAt, stepStartedAt] + [restSleep?.at, restWake].compactMap { $0 }
        let dates = steps.map(\.enteredAt) + resumedAt + [plugInAfter, lastRestReading?.at].compactMap { $0 }
        guard stamps.allSatisfy(\.isFinite), dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            return "its times are not valid"
        }
        guard steps.last?.step == step else {
            return "its steps are not valid"
        }
        guard step != .restAtBottom || plugInAfter != nil else {
            return "its rest has no time to plug in again"
        }
        let percents = [restSleep?.percent, lastRestReading?.percent].compactMap { $0 }
        guard percents.allSatisfy((0...100).contains) else {
            return "its battery readings are not valid"
        }
        return nil
    }
}

extension CalibrationReport {
    /// Why a stored report cannot be used; nil if it can.
    var validationProblem: String? {
        let dates = [startedAt, endedAt] + steps.map(\.enteredAt) + resumedAt
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            return "its report's times are not valid"
        }
        return nil
    }
}
