/// One reading of the battery's charging state, taken from read-only
/// sources only.
///
/// Every field is optional: nil means the value could not be read. The
/// executable fills it from:
/// - IOPowerSources (public API): `externalPower` (the providing power source
///   is AC power), `batteryPresent`, `percent`, `isCharging`, `isCharged`,
///   and, from `IOPSCopyExternalPowerAdapterDetails`, `adapterAttached` and
///   `adapterWatts` only (``adapter(from:)``);
/// - the `AppleSmartBattery` registry entry (read with
///   `IORegistryEntryCreateCFProperty`; no user client): `averageCurrent`
///   (`Amperage`, a public key name in IOPM.h), and the undocumented
///   `InstantAmperage`, `IsCharging`, `ExternalConnected`,
///   `AppleRawExternalConnected`, `UpdateTime`,
///   `ChargerData.NotChargingReason` and `PowerTelemetryData.SystemPowerIn`.
///
/// The verdict uses `externalPower`, `isCharging`, `isCharged`, `percent`,
/// ``current``, the update time and, for an adapter cut, whether the adapter
/// is still reported attached. The other undocumented values are recorded
/// for the report only.
public struct Sample: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case baseline
        /// Research note 11's manual adapter cut only: readings between the
        /// CUT prompt and the owner's cut mark, judged only for freshness at
        /// the cut (note 11 §4.5, check b). The assertion probes take none.
        case preCut = "pre-cut"
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
    /// `AppleRawExternalConnected`, undocumented. In Apple's published
    /// driver it is read from the SMC separately from `ExternalConnected`
    /// (research note 10 §3).
    public var rawExternalConnected: Bool?
    /// Whether `IOPSCopyExternalPowerAdapterDetails` returned an adapter.
    public var adapterAttached: Bool?
    /// The adapter's `Watts` (`kIOPSPowerAdapterWattsKey`).
    public var adapterWatts: Int?
    /// `UpdateTime`, undocumented: the Unix time, in whole seconds, at which
    /// the battery's last poll finished (research note 10 §3). Readings with
    /// the same value repeat one update.
    public var updateTime: Int?
    /// The Unix time of this reading, to place `updateTime` on the run's
    /// clock.
    public var unixTime: Double?
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
        rawExternalConnected: Bool? = nil,
        adapterAttached: Bool? = nil,
        adapterWatts: Int? = nil,
        updateTime: Int? = nil,
        unixTime: Double? = nil,
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
        self.rawExternalConnected = rawExternalConnected
        self.adapterAttached = adapterAttached
        self.adapterWatts = adapterWatts
        self.updateTime = updateTime
        self.unixTime = unixTime
        self.notChargingReason = notChargingReason
        self.systemPowerIn = systemPowerIn
    }

    /// The current the verdict uses: the instant reading where there is one,
    /// because the average lags a change; otherwise the average.
    public var current: Int? { instantCurrent ?? averageCurrent }

    /// Seconds from the battery's last update to this reading.
    public var updateAge: Double? {
        guard let updateTime, let unixTime else { return nil }
        return unixTime - Double(updateTime)
    }

    /// When the battery's last update was made, on the run's clock. Since
    /// `UpdateTime` is cut to whole seconds, the update was made up to 1 s
    /// after this.
    public var updateRunTime: Double? {
        updateAge.map { time - $0 }
    }

    /// Whether any read still reports the adapter attached:
    /// `AppleRawExternalConnected`, or the public adapter details.
    public var reportsAdapter: Bool {
        rawExternalConnected == true || adapterAttached == true
    }

    /// What the probe keeps of `IOPSCopyExternalPowerAdapterDetails`:
    /// whether it returned a dictionary, and its `Watts`. Nothing else in
    /// the dictionary (it also carries a serial number) is kept.
    public static func adapter(from details: [String: Any]?) -> (attached: Bool, watts: Int?) {
        guard let details else { return (false, nil) }
        let watts = (details["Watts"] as? Int).flatMap { (0...1000).contains($0) ? $0 : nil }
        return (true, watts)
    }
}
