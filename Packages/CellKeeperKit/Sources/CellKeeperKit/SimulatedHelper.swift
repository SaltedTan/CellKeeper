import CellKeeperCore
import CellKeeperHelperCore
import Foundation

/// The helper's own power state, read from public, read-only sources, as the
/// helper reads it rather than taking the app's word for it.
///
/// - Charge and power source: IOPowerSources (the internal battery's
///   description and the providing power source), through
///   ``BatteryTelemetryParser``.
/// - Adapter presence: whether `IOPSCopyExternalPowerAdapterDetails`
///   describes an attached adapter. Its documentation says it describes the
///   attached adapter, and returns nothing when none is attached or on an
///   error. Present when it returns details; absent when it returns none
///   while the Mac runs on battery; unknown when it returns none while the
///   Mac reports external power. Whether it still describes an adapter that
///   a control has disabled is unverified, because no such control exists
///   yet; `safety.md` precondition 12 requires verifying it before any real
///   adapter control. An adapter wrongly read as absent makes the helper
///   clear the adapter-disable, which is the safe direction.
/// - Thermal pressure: `ProcessInfo.thermalState` serious or critical.
///
/// Each reading is stamped with `uptime` just before it is taken.
public struct SystemHelperPowerReading: HelperPowerReading {
    private let uptime: @Sendable () -> TimeInterval

    public init(uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime) {
        self.uptime = uptime
    }

    public func latestPowerState() -> HelperPowerState? {
        let readAt = uptime()
        return Self.powerState(
            from: SystemTelemetryProvider.readPowerSources(),
            thermalState: ProcessInfo.processInfo.thermalState,
            readAtUptime: readAt
        )
    }

    /// The power state in `raw`; nil if IOPowerSources reported nothing.
    static func powerState(from raw: RawPowerData, thermalState: ProcessInfo.ThermalState, readAtUptime: TimeInterval) -> HelperPowerState? {
        guard raw.powerSource != nil || raw.providingPowerSourceType != nil else { return nil }
        let snapshot = BatteryTelemetryParser.snapshot(from: raw, at: Date())
        let isOnExternalPower: Bool? = switch snapshot.powerSource {
        case .externalPower: true
        case .battery: false
        case .unknown: nil
        }
        let isAdapterPresent: Bool? = if raw.adapter != nil {
            true
        } else if isOnExternalPower == false {
            false
        } else {
            nil
        }
        return HelperPowerState(
            stateOfCharge: snapshot.isBatteryPresent ? snapshot.chargePercent : nil,
            isOnExternalPower: isOnExternalPower,
            isAdapterPresent: isAdapterPresent,
            isThermalPressureHigh: thermalState == .serious || thermalState == .critical,
            readAtUptime: readAtUptime
        )
    }
}

extension HelperChargingBackend {
    public static let simulatedHelperIdentifier = "simulated-helper"

    /// CellKeeper's own charge control, simulated: the helper's logic
    /// (``HelperEngine``) runs inside the app on a ``SimulatedChargeControl``,
    /// with the helper's own read-only power reading, so its leases,
    /// interlocks and rate limits behave as they will in the daemon while
    /// nothing on the Mac changes.
    ///
    /// The engine is started before the first connection and ticked every
    /// `tickInterval` while the backend exists. Releasing the backend ends
    /// its session and stops the ticking. The app forwards sleep and wake to
    /// the engine through the returned backend's
    /// ``InProcessHelperTransport``. While CellKeeper holds a control,
    /// `activity` keeps the app from being napped.
    ///
    /// On a Mac that has macOS's own Charge Limit, the backend withholds its
    /// restrictions while that limit is on or cannot be read (safety
    /// precondition 7), as the real helper backend will.
    ///
    /// - Parameters:
    ///   - control: the simulated control; a test can inject failures
    ///     through it.
    ///   - power: the helper's power reading; the system's by default. It
    ///     must stamp its readings with `uptime`.
    ///   - uptime: one monotonic clock for the engine, the power reading and
    ///     the backend.
    ///   - macOSChargeLimit: watches macOS's own Charge Limit; by default
    ///     through `pmset -g battlimit` (read-only) on a Mac that has the
    ///     Charge Limit, and nil on one that does not.
    public static func simulatedHelper(
        control: SimulatedChargeControl = SimulatedChargeControl(),
        power: (any HelperPowerReading)? = nil,
        tickInterval: Duration = .seconds(5),
        uptime: @escaping @Sendable () -> TimeInterval = HelperEngine.continuousUptime,
        pause: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        activity: any LeaseActivity = ProcessLeaseActivity(),
        macOSChargeLimit: MacOSChargeLimitMonitor? = MacOSChargeLimitMonitor.system()
    ) -> HelperChargingBackend {
        HelperChargingBackend(
            descriptor: BackendDescriptor(
                identifier: simulatedHelperIdentifier,
                displayName: "Simulated helper",
                summary: "CellKeeper's own charge control, at any limit from 20 to 100%, simulated: the helper's logic runs inside CellKeeper with a simulated control, so nothing on your Mac changes. Real control needs a signed helper and a verified mechanism (roadmap milestone 4)."
            ),
            transport: InProcessHelperTransport(
                control: control,
                power: power ?? SystemHelperPowerReading(uptime: uptime),
                build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
                uptime: uptime,
                tickInterval: tickInterval,
                events: { logHelperEvent($0) }
            ),
            uptime: uptime,
            pause: pause,
            activity: activity,
            macOSChargeLimit: macOSChargeLimit
        )
    }

    /// The simulated helper's audit log, in the backend category.
    private static func logHelperEvent(_ event: HelperEvent) {
        let message = "Simulated helper: \(String(describing: event))"
        switch event {
        case .sessionOpened, .sessionInvalidated, .leaseGranted, .leaseRenewed, .write, .activationRecorded:
            CellKeeperLog.backend.info("\(message, privacy: .public)")
        default:
            CellKeeperLog.backend.notice("\(message, privacy: .public)")
        }
    }
}
