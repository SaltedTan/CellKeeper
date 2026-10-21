import Foundation

/// Where the menu's power flow reads its values while the menu is open and
/// its Power flow section expanded (D114). One source exists, macOS's battery data
/// (``BatteryDataPowerFlowReading``); a faster one could take its place
/// without the flow, the history or the menu changing, since none of them
/// assumes a cadence.
///
/// Display only. A source must only read: it never changes anything on the
/// Mac, and the policy, the controller and the safety rules never use what
/// it reads.
public protocol PowerFlowReading: Sendable {
    /// What the values are, for the menu's note: "macOS's battery data".
    var sourceName: String { get }
    /// About how often the source's values change.
    var updateInterval: Duration { get }
    /// Reads the values now.
    func currentSample() async throws -> PowerFlowSample
}

extension PowerFlowReading {
    /// The menu's note under the power flow, from the source: "From macOS's
    /// battery data, updated about once a minute."
    public var footnote: String {
        PowerFlowWording.footnote(sourceName: sourceName, updateInterval: updateInterval)
    }
}

/// The power flow from macOS's battery data: the `AppleSmartBattery`
/// registry entry's `SystemPowerIn` and `SystemLoad`, and the battery's
/// voltage and current, through the telemetry provider
/// (``PowerFlowSample/init(_:)``). macOS updates them about once a minute
/// (research note 01).
public struct BatteryDataPowerFlowReading: PowerFlowReading {
    /// macOS's update interval for this data, observed on the test Mac.
    public static let updateInterval: Duration = .seconds(60)

    private let telemetry: any TelemetryProvider

    public init(telemetry: any TelemetryProvider) {
        self.telemetry = telemetry
    }

    public var sourceName: String { "macOS's battery data" }

    public var updateInterval: Duration { Self.updateInterval }

    public func currentSample() async throws -> PowerFlowSample {
        PowerFlowSample(try await telemetry.currentSnapshot())
    }
}
