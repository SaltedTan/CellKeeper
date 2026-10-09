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
    private var entries: [(control: HelperControl, uptime: TimeInterval)] = []

    func allows(_ control: HelperControl, at now: TimeInterval) -> Bool {
        let recent = entries.filter { now - $0.uptime < Self.window }
        if recent.count >= HelperEngine.maximumActivationsPerHour {
            return false
        }
        if let last = recent.last(where: { $0.control == control }), now - last.uptime < HelperEngine.minimumActivationInterval {
            return false
        }
        return true
    }

    mutating func record(_ control: HelperControl, at now: TimeInterval) {
        entries.removeAll { now - $0.uptime >= Self.window }
        entries.append((control, now))
    }
}
