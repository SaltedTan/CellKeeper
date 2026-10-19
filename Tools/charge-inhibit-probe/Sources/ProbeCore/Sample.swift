/// One reading of the battery's charging state, taken from read-only
/// sources only.
///
/// Every field is optional: nil means the value could not be read. The
/// executable fills it from:
/// - IOPowerSources (public API): `externalPower` (the providing power source
///   is AC power), `batteryPresent`, `percent`, `isCharging`, `isCharged`;
/// - the `AppleSmartBattery` registry entry (read with
///   `IORegistryEntryCreateCFProperty`; no user client): `averageCurrent`
///   (`Amperage`, a public key name in IOPM.h), and the undocumented
///   `InstantAmperage`, `IsCharging`, `ExternalConnected`,
///   `ChargerData.NotChargingReason` and `PowerTelemetryData.SystemPowerIn`.
///
/// The undocumented values are recorded for the report only. The verdict
/// uses `externalPower`, `isCharging`, `isCharged`, `percent` and
/// ``current``.
public struct Sample: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case baseline
        case held
        case after
    }

    /// Seconds since the run started, on a clock that keeps counting while
    /// the Mac sleeps (so a sleep shows up as a gap).
    public var time: Double
    /// The local wall-clock time of the reading ("12:34:56"), for matching
    /// the report against the system log. Not used by the verdict.
    public var wallTime: String?
    public var phase: Phase
    public var externalPower: Bool?
    public var batteryPresent: Bool?
    public var percent: Int?
    public var isCharging: Bool?
    public var isCharged: Bool?
    /// Battery current in mA, positive while charging (registry `Amperage`,
    /// an average).
    public var averageCurrent: Int?
    /// Battery current in mA (registry `InstantAmperage`, undocumented).
    public var instantCurrent: Int?
    public var registryIsCharging: Bool?
    public var registryExternalConnected: Bool?
    /// `ChargerData.NotChargingReason`, an undocumented bit field; recorded,
    /// never decoded.
    public var notChargingReason: UInt64?
    /// `PowerTelemetryData.SystemPowerIn`, undocumented; mW by inference
    /// (research note 01).
    public var systemPowerIn: Int?

    public init(
        time: Double,
        wallTime: String? = nil,
        phase: Phase,
        externalPower: Bool? = nil,
        batteryPresent: Bool? = nil,
        percent: Int? = nil,
        isCharging: Bool? = nil,
        isCharged: Bool? = nil,
        averageCurrent: Int? = nil,
        instantCurrent: Int? = nil,
        registryIsCharging: Bool? = nil,
        registryExternalConnected: Bool? = nil,
        notChargingReason: UInt64? = nil,
        systemPowerIn: Int? = nil
    ) {
        self.time = time
        self.wallTime = wallTime
        self.phase = phase
        self.externalPower = externalPower
        self.batteryPresent = batteryPresent
        self.percent = percent
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.averageCurrent = averageCurrent
        self.instantCurrent = instantCurrent
        self.registryIsCharging = registryIsCharging
        self.registryExternalConnected = registryExternalConnected
        self.notChargingReason = notChargingReason
        self.systemPowerIn = systemPowerIn
    }

    /// The current the verdict uses: the instant reading where there is one,
    /// because the average lags a change; otherwise the average.
    public var current: Int? { instantCurrent ?? averageCurrent }
}
