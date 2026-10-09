import Foundation

/// A session's request budget: a token bucket that starts full, holds
/// ``HelperEngine/requestBurst`` tokens and refills at
/// ``HelperEngine/requestsPerSecond`` on the monotonic clock.
struct RequestBudget {
    private var tokens: Double
    private var refilledAt: TimeInterval

    init(at now: TimeInterval) {
        tokens = Double(HelperEngine.requestBurst)
        refilledAt = now
    }

    /// Takes a token if one is available.
    mutating func take(at now: TimeInterval) -> Bool {
        if now > refilledAt {
            tokens = min(Double(HelperEngine.requestBurst), tokens + (now - refilledAt) * HelperEngine.requestsPerSecond)
            refilledAt = now
        }
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Activation writes, for rule R13: each control at most once per
/// ``HelperEngine/minimumActivationInterval``, and at most
/// ``HelperEngine/maximumActivationsPerHour`` in total per rolling hour.
struct ActivationHistory {
    private static let window: TimeInterval = 60 * 60
    /// The latest records are enough for both limits: if a control's last
    /// activation is older than this many others, the hourly cap refuses
    /// anyway.
    private static let capacity = HelperEngine.maximumActivationsPerHour
    /// At most ``capacity`` records, oldest first.
    private(set) var records: [HelperActivationRecord]

    /// Keeps the latest ``capacity`` records of the last hour, in one pass
    /// over `records`, whatever its size or order. Records from the future
    /// cannot belong to this boot's clock and are dropped.
    init(records: [HelperActivationRecord], at now: TimeInterval) {
        var kept: [HelperActivationRecord] = []
        kept.reserveCapacity(Self.capacity + 1)
        for record in records where record.uptime <= now && now - record.uptime < Self.window {
            if kept.count == Self.capacity, let oldest = kept.first, record.uptime <= oldest.uptime {
                continue
            }
            if let newest = kept.last, record.uptime < newest.uptime {
                let index = kept.firstIndex { $0.uptime > record.uptime } ?? kept.endIndex
                kept.insert(record, at: index)
            } else {
                kept.append(record)
            }
            if kept.count > Self.capacity {
                kept.removeFirst()
            }
        }
        self.records = kept
    }

    func allows(_ control: HelperControl, at now: TimeInterval) -> Bool {
        let recent = records.filter { now - $0.uptime < Self.window }
        if recent.count >= HelperEngine.maximumActivationsPerHour {
            return false
        }
        if let last = recent.last(where: { $0.control == control }), now - last.uptime < HelperEngine.minimumActivationInterval {
            return false
        }
        return true
    }

    mutating func record(_ control: HelperControl, at now: TimeInterval) -> HelperActivationRecord {
        records.removeAll { now - $0.uptime >= Self.window }
        let record = HelperActivationRecord(control: control, uptime: now)
        // At most `capacity`: `allows` refused any activation beyond it.
        records.append(record)
        return record
    }

    /// The records still within the window.
    func current(at now: TimeInterval) -> [HelperActivationRecord] {
        records.filter { now - $0.uptime < Self.window }
    }
}
