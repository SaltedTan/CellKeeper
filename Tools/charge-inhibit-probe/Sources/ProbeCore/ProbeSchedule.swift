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
}
