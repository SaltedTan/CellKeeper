/// When the probe reads the battery during a run.
public enum ProbeSchedule {
    /// Seconds between readings.
    public static let interval = 2
    /// The baseline before the assertion: readings at 0, 2, … 20 s.
    public static let baseline = 20
    /// Readings after the release, at least.
    public static let after = 60
    /// If charging has not resumed `after` seconds after the release, the
    /// probe keeps reading for up to this much longer, to tell a late resume
    /// from none.
    public static let lateResumeWatch = 120
    /// A reading taken more than this many seconds after its deadline is
    /// late.
    public static let lateness = 0.5

    /// The deadline of the reading after one due at `deadline` and taken at
    /// `readAt`. The sampler never catches up: after an on-time reading the
    /// next is due one interval after the previous deadline; after a late
    /// one, one interval after the late reading itself, so overdue readings
    /// are never taken back to back. Either way the next deadline is at
    /// least `interval - lateness` (1.5 s) after the reading.
    public static func nextDeadline(
        after deadline: Double,
        readAt: Double,
        interval: Double = Double(ProbeSchedule.interval),
        lateness: Double = ProbeSchedule.lateness
    ) -> Double {
        readAt - deadline > lateness ? readAt + interval : deadline + interval
    }
}
