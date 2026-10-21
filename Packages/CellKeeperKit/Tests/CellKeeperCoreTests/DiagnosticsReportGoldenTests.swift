import CellKeeperCore
import Foundation
import Testing

/// The whole report for fixed statuses, byte for byte, so that a change in
/// how the report is built cannot change what it says unnoticed.
///
/// Each expected report is written out up to its activity section; the
/// activity section is built here from the status's events, one line each.
/// That pins the format of the activity lines but not the controller's event
/// wording, which contains local times. Temperatures are the only numbers
/// the report formats for the current locale; the expected reports format
/// them the same way (``number(_:)``), so that they hold in any locale.
@Suite("Diagnostics report, whole text")
struct DiagnosticsReportGoldenTests {
    /// A number as the report formats it, for the current locale.
    private static func number(_ value: Double) -> String {
        value.formatted()
    }

    /// Expects the report on `status` to be `head`, then a blank line, the
    /// activity section's title and one line per event, oldest first, or
    /// "none", with the fixture's account name in paths replaced: the same
    /// UTF-8 bytes, not only equal strings, which Swift also calls canonically
    /// equivalent text with different bytes.
    private func expectReport(
        _ status: ControllerStatus,
        environment: DiagnosticsEnvironment = DiagnosticsFixture.environment,
        head: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let lines = status.events.map { "\($0.date.formatted(.iso8601)) [\($0.kind.rawValue)] \($0.message)" }
        let activity = (lines.isEmpty ? "none" : lines.joined(separator: "\n"))
            .replacingOccurrences(of: "/Users/\(DiagnosticsFixture.accountName)/", with: "/Users/<user>/")
        let expected = head + "\n\n== Activity (oldest first)\n" + activity + "\n"
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)
        let isIdentical = report.utf8.elementsEqual(expected.utf8)
        #expect(isIdentical, "The report's UTF-8 bytes differ from the expected report's.", sourceLocation: sourceLocation)
        if !isIdentical {
            // Shows where they differ.
            #expect(report == expected, sourceLocation: sourceLocation)
        }
    }

    @Test("The Simulated backend holding at the limit, with every battery value")
    func simulated() async {
        let status = await DiagnosticsFixture.simulated()
        #expect(!status.events.isEmpty)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: a charging pause (inhibitCharging)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: 2027-01-15T08:00:40Z
            Charge: 81%
            Power source: external power (externalPower)
            Charging status: not charging (notCharging)
            Temperature: \(Self.number(31)) °C
            Voltage: 12427 mV
            Current: -12 mA
            Adapter: 70 W
            System power in: \(Self.number(36.25)) W
            Mac use: \(Self.number(34.848)) W
            Cycle count: 54
            Full-charge capacity: 6131 mAh
            Design capacity: 6249 mAh
            Condition: Good

            == Decision
            State: holding at the limit (holding)
            Wants: a charging pause (inhibitCharging)
            Action: disable charging
            Reason: Charge 81% has reached the 80% limit; charging paused.
            Last action: 2027-01-15T08:01:00Z disable charging: simulated
            Last evaluation: 2027-01-15T08:01:00Z
            """)
    }

    @Test("macOS's Charge Limit with the user's own limit recorded and CellKeeper's in effect")
    func nativeLimit() async {
        let status = await DiagnosticsFixture.nativeLimit()
        #expect(!status.events.isEmpty)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: a macOS Charge Limit of 85% (nativeLimit(85%))
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 85%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 85% (nativeLimit(85%))
            Action: set macOS Charge Limit to 85%
            Reason: CellKeeper wants macOS's Charge Limit at 85%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:00:00Z set macOS Charge Limit to 85%: applied and confirmed
            Last evaluation: 2027-01-15T08:00:00Z

            == macOS Charge Limit
            Reported by macOS: 85%
            Read at: 2027-01-15T08:00:00Z
            Own limit: 80% recorded
            CellKeeper's limit: 85%
            Shortcut found: yes
            Flags: none
            """)
    }

    @Test("macOS's Charge Limit changed outside CellKeeper and kept, with the adoption marker unsaved")
    func nativeLimitKeptOutsideChange() async {
        let status = await DiagnosticsFixture.nativeLimitKeptOutsideChange()
        #expect(!status.events.isEmpty)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: your own macOS Charge Limit (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: off
            Charge limit: 90%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: not managing charging (unmanaged)
            Wants: your own macOS Charge Limit (normal)
            Action: none
            Reason: Charge management is off; macOS manages charging.
            Last action: 2027-01-15T08:00:00Z set macOS Charge Limit to 90%: applied and confirmed
            Last evaluation: 2027-01-15T08:01:00Z

            == macOS Charge Limit
            Reported by macOS: 95%
            Read at: 2027-01-15T08:01:00Z
            Own limit: not recorded (in effect)
            Shortcut found: yes
            Flags: adoption marker unsaved
            Kept outside change: 95% at 2027-01-15T08:01:00Z; CellKeeper had set 90%, own limit was 80%
            """)
    }

    @Test("No reading, an error whose path names the account, and an unknown model")
    func noTelemetry() async {
        let status = await DiagnosticsFixture.noTelemetry()
        #expect(status.telemetryError?.contains(DiagnosticsFixture.accountName) == true)
        #expect(status.events.contains { $0.message.contains(DiagnosticsFixture.accountName) })
        var environment = DiagnosticsFixture.environment
        environment.modelIdentifier = nil
        expectReport(status, environment: environment, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: unknown

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Telemetry: unavailable: The file “battery.plist” couldn’t be opened. (NSFilePath=/Users/<user>/Library/Containers/io.github.saltedtan.CellKeeper/Data/battery.plist)

            == Decision
            State: fail-safe (failSafe)
            Wants: normal charging (normal)
            Action: none
            Reason: Battery telemetry is unavailable; using macOS default charging.
            Last evaluation: 2027-01-15T08:00:00Z
            """)
        let report = DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)
        #expect(!report.contains(DiagnosticsFixture.accountName))
    }

    @Test("A Mac without a battery")
    func noBattery() async {
        let status = await DiagnosticsFixture.noBattery()
        #expect(!status.events.isEmpty)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Battery: not present

            == Decision
            State: fail-safe (failSafe)
            Wants: normal charging (normal)
            Action: none
            Reason: No battery detected.
            Last evaluation: 2027-01-15T08:00:00Z
            """)
    }

    @Test("Deferring to macOS's own Charge Limit after a restriction of CellKeeper's own")
    func deferringToMacOS() async {
        let status = await DiagnosticsFixture.deferringToMacOS()
        #expect(!status.events.isEmpty)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Test helper (test-helper)
            Availability: simulated
            Style: switches charging, modes normal charging (normal)
            Reported mode: normal charging (normal)
            macOS Charge Limit: On at 80%, read 2027-01-15T08:02:00Z; CellKeeper defers to it: it withholds new restrictions and asks for the release of any restriction of its own
            Own restriction: The last read-back shows no restriction in effect. These are the simulated helper's controls; your Mac's charging is not changed.
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:02:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: deferring to macOS's Charge Limit (deferringToMacOS)
            Wants: normal charging (normal)
            Action: enable charging
            Reason: macOS reports its own Charge Limit on at 80%. While it is on, CellKeeper does not enforce its own limit: it withholds new restrictions and asks for the release of any restriction of its own. To let CellKeeper manage charging, turn macOS's Charge Limit off in System Settings › Battery › Charging (set it to 100%).
            Last action: 2027-01-15T08:02:00Z enable charging: simulated
            Last evaluation: 2027-01-15T08:02:00Z
            """)
    }

    @Test("A running full charge with an armed schedule, then the schedule's full charge and its outcome")
    func overrideAndSchedule() async throws {
        let (armed, started) = try await DiagnosticsFixture.overrideAndSchedule()
        #expect(!armed.events.isEmpty)
        expectReport(armed, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Temporary full charge, started 2027-01-15T08:00:00Z, expires 2027-01-15T20:00:00Z
            Scheduled full charge: 2027-01-15T09:00:00Z to 2027-01-15T11:00:00Z
            Last evaluation: 2027-01-15T08:00:00Z
            """)
        expectReport(started, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Scheduled full charge, started 2027-01-15T09:00:00Z, expires 2027-01-15T11:00:00Z
            Schedule outcome: started (window 2027-01-15T09:00:00Z to 2027-01-15T11:00:00Z)
            Last evaluation: 2027-01-15T09:00:00Z
            """)
    }

    @Test("A faulted backend after failed requests")
    func faulted() async {
        let status = await DiagnosticsFixture.faulted()
        #expect(status.isBackendFaulted)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 4 (faulted)

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:04:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: holding at the limit (holding)
            Wants: a charging pause (inhibitCharging)
            Action: disable charging
            Reason: Charge 85% has reached the 80% limit; charging paused.
            Last action: 2027-01-15T08:04:00Z disable charging: failed: Operation failed: injected failure
            Last evaluation: 2027-01-15T08:04:00Z
            """)
    }

    @Test("Read-only, which controls nothing, with a note on the decision")
    func readOnlyConfirming() async {
        let status = await DiagnosticsFixture.readOnlyConfirming()
        #expect(status.decision?.notes.isEmpty == false)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Read-only (read-only)
            Availability: unavailable: Read-only is selected, so CellKeeper changes nothing.
            Style: switches charging, modes\u{20}
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 81%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: charging to the limit (charging)
            Wants: normal charging (normal)
            Action: none
            Reason: Charge 81% has reached the 80% limit on one reading; charging continues until the next reading confirms it.
            Note: CellKeeper is confirming the limit with the next battery reading before it pauses charging, so a single wrong reading cannot pause it.
            Last evaluation: 2027-01-15T08:00:00Z
            """)
    }

    @Test("A discharge to the limit, with its target")
    func discharging() async {
        let status = await DiagnosticsFixture.discharging()
        #expect(status.activeOverride?.targetPercent != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: a discharge while plugged in (forceDischarge)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 90%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: discharging to the limit (discharging)
            Wants: a discharge while plugged in (forceDischarge)
            Action: request discharge
            Reason: Discharging from 90% to the 80% limit while plugged in.
            Override: Discharge to limit to 80%, started 2027-01-15T08:00:00Z, expires 2027-01-15T14:00:00Z
            Last action: 2027-01-15T08:00:00Z request discharge: simulated
            Last evaluation: 2027-01-15T08:00:00Z
            """)
    }

    @Test("macOS's Charge Limit when neither the limit nor the record can be read")
    func nativeLimitUnreadable() async {
        let status = await DiagnosticsFixture.nativeLimitUnreadable()
        #expect(status.nativeLimit?.isRecordUnreadable == true)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: unavailable: CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 85%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 85% (nativeLimit(85%))
            Action: refused (Control unavailable: CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.)
            Reason: CellKeeper wants macOS's Charge Limit at 85%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:00:00Z refused (Control unavailable: CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.): refused: Control unavailable: CellKeeper's record of your own Charge Limit cannot be read, so it does not know what to restore. Set your limit in System Settings › Battery › Charging, then discard the record in Settings › Control.
            Last evaluation: 2027-01-15T08:00:00Z

            == macOS Charge Limit
            Reported by macOS: unknown
            Read at: 2027-01-15T08:00:00Z
            Read problem: read failed
            Own limit: record unreadable
            Shortcut found: not checked
            Flags: none
            """)
    }

    @Test("A kept change to no limit, with two flags and a switch waiting")
    func nativeLimitPendingSwitch() async {
        let status = await DiagnosticsFixture.nativeLimitPendingSwitch()
        #expect(status.pendingBackend != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: your own macOS Charge Limit (normal)
            Pending switch: Simulated
            Consecutive failures: 0

            == Settings
            Manage charging: off
            Charge limit: 90%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: not managing charging (unmanaged)
            Wants: your own macOS Charge Limit (normal)
            Action: none
            Reason: Charge management is off; macOS manages charging.
            Last action: 2027-01-15T08:00:00Z set macOS Charge Limit to 90%: applied and confirmed
            Last evaluation: 2027-01-15T08:01:00Z

            == macOS Charge Limit
            Reported by macOS: 100%
            Read at: 2027-01-15T08:01:00Z
            Own limit: not recorded (in effect)
            Shortcut found: yes
            Flags: needs no-limit confirmation, adoption marker unsaved
            Kept outside change: 100% (no limit) at 2027-01-15T08:01:00Z; CellKeeper had set 90%, own limit was 80%
            """)
    }

    @Test("Deferring while macOS's Charge Limit report cannot be read")
    func macOSLimitUnreadable() async {
        let status = await DiagnosticsFixture.macOSLimitUnreadable()
        #expect(status.capabilities.macOSChargeLimit?.readProblem != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Test helper (test-helper)
            Availability: simulated
            Style: switches charging, modes normal charging (normal)
            Reported mode: normal charging (normal)
            macOS Charge Limit: Could not be read, read 2027-01-15T08:01:00Z; CellKeeper defers to it: it withholds new restrictions and asks for the release of any restriction of its own
            macOS Charge Limit read problem: pmset -g battlimit failed: exit status 1
            Own restriction: The last read-back shows no restriction in effect. These are the simulated helper's controls; your Mac's charging is not changed.
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: deferring to macOS's Charge Limit (deferringToMacOS)
            Wants: normal charging (normal)
            Action: none
            Reason: CellKeeper could not read macOS's Charge Limit report (pmset -g battlimit failed: exit status 1), so macOS may be limiting charging, for example with its Charge Limit or Optimized Battery Charging. Until the report shows no active limit, CellKeeper does not enforce its own limit: it withholds new restrictions and asks for the release of any restriction of its own. Check that macOS's Charge Limit is off in System Settings › Battery › Charging (set to 100%).
            Last evaluation: 2027-01-15T08:01:00Z
            """)
    }

    @Test("A due schedule waiting on battery, then its window passing")
    func scheduleWaitingThenPassed() async throws {
        let (waiting, passed) = try await DiagnosticsFixture.scheduleWaitingThenPassed()
        #expect(waiting.fullChargeScheduleWait != nil)
        expectReport(waiting, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: battery power (battery)
            Charging status: discharging (discharging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: on battery power (onBattery)
            Wants: normal charging (normal)
            Action: none
            Reason: Running on battery; CellKeeper's restrictions are cleared until power is reconnected.
            Scheduled full charge: 2027-01-15T09:00:00Z to 2027-01-15T10:00:00Z; due, waiting: the Mac is on battery
            Last evaluation: 2027-01-15T09:00:00Z
            """)
        expectReport(passed, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T10:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: battery power (battery)
            Charging status: discharging (discharging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: on battery power (onBattery)
            Wants: normal charging (normal)
            Action: none
            Reason: Running on battery; CellKeeper's restrictions are cleared until power is reconnected.
            Schedule outcome: window passed before it could start (2027-01-15T09:00:00Z to 2027-01-15T10:00:00Z); last checked: the Mac is on battery
            Last evaluation: 2027-01-15T10:00:00Z
            """)
    }

    @Test("Before the first evaluation: no reading and no error, no decision, no evaluation, and no activity")
    func beforeFirstEvaluation() async {
        let status = await DiagnosticsFixture.beforeFirstEvaluation()
        #expect(status.snapshot == nil && status.telemetryError == nil)
        #expect(status.decision == nil && status.lastEvaluation == nil)
        #expect(status.events.isEmpty)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: unavailable: Not evaluated yet.
            Style: switches charging, modes\u{20}
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Telemetry: unavailable

            == Decision
            State: not evaluated yet
            """)
    }

    @Test("An available backend, temperature protection off, and a reading without a charge or a temperature")
    func availableBackend() async {
        let status = await DiagnosticsFixture.availableBackend()
        #expect(status.capabilities.availability == .available)
        #expect(!status.settings.temperatureProtection.isEnabled)
        #expect(status.snapshot?.isBatteryPresent == true)
        #expect(status.snapshot?.chargePercent == nil && status.snapshot?.temperatureCelsius == nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Test hardware (test-available)
            Availability: available
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: off (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: not available
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: not available
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: fail-safe (failSafe)
            Wants: normal charging (normal)
            Action: none
            Reason: Battery telemetry is unavailable; using macOS default charging.
            Last evaluation: 2027-01-15T08:00:00Z
            """)
    }

    @Test("macOS's Charge Limit read and not limiting, with a backend that switches charging")
    func macOSLimitOff() async {
        let status = await DiagnosticsFixture.macOSLimitOff()
        #expect(status.capabilities.macOSChargeLimit?.isLimiting == false)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Test helper (test-helper)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: a charging pause (inhibitCharging)
            macOS Charge Limit: No active limit reported, read 2027-01-15T08:01:00Z
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: holding at the limit (holding)
            Wants: a charging pause (inhibitCharging)
            Action: disable charging
            Reason: Charge 85% has reached the 80% limit; charging paused.
            Last action: 2027-01-15T08:01:00Z disable charging: simulated
            Last evaluation: 2027-01-15T08:01:00Z
            """)
    }

    @Test("A refused attempt to turn management on")
    func managementRefused() async throws {
        let status = try await DiagnosticsFixture.managementRefused()
        #expect(status.managementRefusal != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: your own macOS Charge Limit (normal)
            Pending switch: none
            Consecutive failures: 0
            Management refused: Manage charging stays off: CellKeeper could not remove its record of the Charge Limit it kept, so it leaves the limit as it is. Try again later.

            == Settings
            Manage charging: off
            Charge limit: 90%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: not managing charging (unmanaged)
            Wants: your own macOS Charge Limit (normal)
            Action: none
            Reason: Charge management is off; macOS manages charging.
            Last action: 2027-01-15T08:00:00Z set macOS Charge Limit to 90%: applied and confirmed
            Last evaluation: 2027-01-15T08:01:00Z

            == macOS Charge Limit
            Reported by macOS: 95%
            Read at: 2027-01-15T08:01:00Z
            Own limit: not recorded (in effect)
            Shortcut found: yes
            Flags: none
            Kept outside change: 95% at 2027-01-15T08:01:00Z; CellKeeper had set 90%, own limit was 80%
            """)
    }

    @Test("A request already in effect")
    func nativeLimitUnchanged() async {
        let status = await DiagnosticsFixture.nativeLimitUnchanged()
        #expect(status.lastExecution?.result == .unchanged)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: a macOS Charge Limit of 80% (nativeLimit(80%))
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 80% (nativeLimit(80%))
            Action: set macOS Charge Limit to 80%
            Reason: CellKeeper wants macOS's Charge Limit at 80%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:00:00Z set macOS Charge Limit to 80%: already in effect
            Last evaluation: 2027-01-15T08:00:00Z

            == macOS Charge Limit
            Reported by macOS: 80%
            Read at: 2027-01-15T08:00:00Z
            Own limit: 80% recorded
            CellKeeper's limit: 80%
            Shortcut found: yes
            Flags: none
            """)
    }

    @Test("macOS's Charge Limit status without a read time")
    func nativeLimitNotRead() async {
        let status = await DiagnosticsFixture.nativeLimitNotRead()
        #expect(status.nativeLimit != nil)
        #expect(status.nativeLimit?.readAt == nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Test Charge Limit (test-unread-native)
            Availability: unavailable: The test backend reads nothing.
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 85%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 85% (nativeLimit(85%))
            Action: refused (Control unavailable: The test backend reads nothing.)
            Reason: CellKeeper wants macOS's Charge Limit at 85%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:00:00Z refused (Control unavailable: The test backend reads nothing.): refused: Control unavailable: The test backend reads nothing.
            Last evaluation: 2027-01-15T08:00:00Z

            == macOS Charge Limit
            Reported by macOS: unknown
            Own limit: not recorded (in effect)
            Shortcut found: not checked
            Flags: none
            """)
    }

    @Test("macOS's Charge Limit without the shortcut")
    func nativeLimitNoShortcut() async {
        let status = await DiagnosticsFixture.nativeLimitNoShortcut()
        #expect(status.nativeLimit?.isShortcutFound == false)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: unavailable: No shortcut named “CellKeeper Set Charge Limit” was found. Create it as described in Settings › Control.
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: your own macOS Charge Limit (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 85%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 85% (nativeLimit(85%))
            Action: refused (Control unavailable: No shortcut named “CellKeeper Set Charge Limit” was found. Create it as described in Settings › Control.)
            Reason: CellKeeper wants macOS's Charge Limit at 85%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:00:00Z refused (Control unavailable: No shortcut named “CellKeeper Set Charge Limit” was found. Create it as described in Settings › Control.): refused: Control unavailable: No shortcut named “CellKeeper Set Charge Limit” was found. Create it as described in Settings › Control.
            Last evaluation: 2027-01-15T08:00:00Z

            == macOS Charge Limit
            Reported by macOS: 80%
            Read at: 2027-01-15T08:00:00Z
            Own limit: not recorded (in effect)
            Shortcut found: no
            Flags: none
            """)
    }

    @Test("An unfinished restore of the user's own limit")
    func nativeLimitRestoreUnfinished() async {
        let status = await DiagnosticsFixture.nativeLimitRestoreUnfinished()
        #expect(status.nativeLimit?.isRestoreUnfinished == true)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 1

            == Settings
            Manage charging: on
            Charge limit: 90%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 90% (nativeLimit(90%))
            Action: set macOS Charge Limit to 90%
            Reason: CellKeeper wants macOS's Charge Limit at 90%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:00:00Z set macOS Charge Limit to 90%: applied and confirmed
            Last evaluation: 2027-01-15T08:00:00Z

            == macOS Charge Limit
            Reported by macOS: 90%
            Read at: 2027-01-15T08:01:00Z
            Own limit: 80% recorded
            CellKeeper's limit: 90%
            Shortcut found: not checked
            Flags: restore unfinished
            """)
    }

    @Test("Wanting the user's own recorded limit back, not yet restored")
    func nativeLimitRestorePending() async throws {
        let status = try await DiagnosticsFixture.nativeLimitRestorePending()
        #expect(status.decision?.desiredMode == .normal)
        #expect(status.nativeLimit?.ownerLimit != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: unknown
            Pending switch: none
            Consecutive failures: 1

            == Settings
            Manage charging: off
            Charge limit: 90%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: not managing charging (unmanaged)
            Wants: your own macOS Charge Limit of 80% (normal)
            Action: restore your own limit
            Reason: Charge management is off; macOS manages charging.
            Last action: 2027-01-15T08:01:00Z restore your own limit: failed: Operation failed: The “CellKeeper Set Charge Limit” shortcut failed: shortcut failed
            Last evaluation: 2027-01-15T08:01:00Z

            == macOS Charge Limit
            Reported by macOS: 90%
            Read at: 2027-01-15T08:01:00Z
            Own limit: 80% recorded
            CellKeeper's limit: 90%
            Shortcut found: not checked
            Flags: restore unfinished
            """)
    }

    @Test("A change outside CellKeeper kept from an earlier session")
    func nativeLimitEarlierSessionAdoption() async {
        let status = await DiagnosticsFixture.nativeLimitEarlierSessionAdoption()
        #expect(status.adoptedChange?.isFromEarlierSession == true)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: your own macOS Charge Limit (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: off
            Charge limit: 90%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:02:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: not managing charging (unmanaged)
            Wants: your own macOS Charge Limit (normal)
            Action: none
            Reason: Charge management is off; macOS manages charging.
            Last evaluation: 2027-01-15T08:02:00Z

            == macOS Charge Limit
            Reported by macOS: 95%
            Read at: 2027-01-15T08:02:00Z
            Own limit: not recorded (in effect)
            Shortcut found: yes
            Flags: none
            Kept outside change: 95% at 2027-01-15T08:01:00Z; CellKeeper had set 90%, own limit was 80%, earlier session
            """)
    }

    @Test("A request that ended by keeping a change made outside CellKeeper")
    func nativeLimitAdoptedBeforeWrite() async throws {
        let status = try await DiagnosticsFixture.nativeLimitAdoptedBeforeWrite()
        #expect(status.lastExecution?.result == .adoptedOutsideChange)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: macOS Charge Limit (native-charge-limit)
            Availability: experimental
            Style: macOS Charge Limit, steps 80, 85, 90, 95, 100
            Reported mode: your own macOS Charge Limit (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: off
            Charge limit: 95%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: limit enforced by macOS (osEnforcedLimit)
            Wants: a macOS Charge Limit of 95% (nativeLimit(95%))
            Action: set macOS Charge Limit to 95%
            Reason: CellKeeper wants macOS's Charge Limit at 95%; macOS enforces it, including its own resume point.
            Last action: 2027-01-15T08:01:00Z set macOS Charge Limit to 95%: kept a change made outside CellKeeper
            Last evaluation: 2027-01-15T08:01:00Z

            == macOS Charge Limit
            Reported by macOS: 85%
            Read at: 2027-01-15T08:01:00Z
            Own limit: not recorded (in effect)
            Shortcut found: yes
            Flags: none
            Kept outside change: 85% at 2027-01-15T08:01:00Z; CellKeeper had set 90%, own limit was 80%
            """)
    }

    @Test("A schedule that starts with the battery already full")
    func scheduleAlreadyFull() async throws {
        let status = try await DiagnosticsFixture.scheduleAlreadyFull()
        #expect(status.fullChargeScheduleOutcome != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: a charging pause (inhibitCharging)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 100%
            Power source: external power (externalPower)
            Charging status: fully charged (fullyCharged)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: holding at the limit (holding)
            Wants: a charging pause (inhibitCharging)
            Action: disable charging
            Reason: Charge 100% has reached the 80% limit; charging paused.
            Schedule outcome: already full at the start (window 2027-01-15T09:00:00Z to 2027-01-15T11:00:00Z)
            Last action: 2027-01-15T09:00:00Z disable charging: simulated
            Last evaluation: 2027-01-15T09:00:00Z
            """)
    }

    @Test("A schedule that extends a running full charge")
    func scheduleExtendedRunning() async throws {
        let status = try await DiagnosticsFixture.scheduleExtendedRunning()
        #expect(status.fullChargeScheduleOutcome != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Scheduled full charge, started 2027-01-15T08:50:00Z, expires 2027-01-15T11:00:00Z
            Schedule outcome: extended the deadline of a running full charge
            Last evaluation: 2027-01-15T09:00:00Z
            """)
    }

    @Test("A schedule that leaves a longer running full charge as it is")
    func scheduleKeptRunning() async throws {
        let status = try await DiagnosticsFixture.scheduleKeptRunning()
        #expect(status.fullChargeScheduleOutcome != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Temporary full charge, started 2027-01-15T08:00:00Z, expires 2027-01-15T20:00:00Z
            Schedule outcome: a running full charge already had a later deadline
            Last evaluation: 2027-01-15T09:00:00Z
            """)
    }

    @Test("A saved schedule that could not be read and was removed")
    func scheduleDiscarded() async {
        let status = await DiagnosticsFixture.scheduleDiscarded()
        #expect(status.fullChargeScheduleOutcome != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: charging to the limit (charging)
            Wants: normal charging (normal)
            Action: none
            Reason: Charge 70% is at or below the resume threshold 75%; charging.
            Schedule outcome: a saved schedule was removed: it is not a schedule record
            Last evaluation: 2027-01-15T08:00:00Z
            """)
    }

    @Test("A schedule whose window passed with no check during it")
    func scheduleWindowPassedUnseen() async throws {
        let status = try await DiagnosticsFixture.scheduleWindowPassedUnseen()
        #expect(status.fullChargeScheduleOutcome != nil)
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T11:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: charging to the limit (charging)
            Wants: normal charging (normal)
            Action: none
            Reason: Charge 70% is at or below the resume threshold 75%; charging.
            Schedule outcome: window passed before it could start (2027-01-15T09:00:00Z to 2027-01-15T10:00:00Z)
            Last evaluation: 2027-01-15T11:00:00Z
            """)
    }

    @Test("A schedule that leaves a running full charge whose deadline is exactly its own as it is")
    func scheduleKeptRunningSameDeadline() async throws {
        let status = try await DiagnosticsFixture.scheduleKeptRunningSameDeadline()
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Temporary full charge, started 2027-01-15T08:00:00Z, expires 2027-01-15T11:00:00Z
            Schedule outcome: a running full charge already had the same deadline
            Last evaluation: 2027-01-15T09:00:00Z
            """)
    }

    @Test("A weekly occurrence due while on battery, whose window runs from EDT into EST: each end with its own offset")
    func weeklyDueAcrossOffsetChange() async throws {
        let status = try await DiagnosticsFixture.weeklyDueAcrossOffsetChange()
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2026-11-01T00:30:00Z
            Driver updated: not available
            Charge: 70%
            Power source: battery power (battery)
            Charging status: discharging (discharging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: on battery power (onBattery)
            Wants: normal charging (normal)
            Action: none
            Reason: Running on battery; CellKeeper's restrictions are cleared until power is reconnected.
            Weekly full charge: every Sat at 20:00 for 12 hours
            Weekly due: 2026-10-31 (nominal), 2026-10-31T20:00:00-04:00 to 2026-11-01T07:00:00-05:00; waiting: the Mac is on battery
            Weekly next: 2026-11-07 (nominal), 2026-11-07T20:00:00-05:00 to 2026-11-08T08:00:00-05:00
            Weekly handled: 2026-10-24 (nominal), began before the schedule was saved (beforeSave), starting 2026-10-24T20:00:00-04:00
            Last evaluation: 2026-11-01T00:30:00Z
            """)
    }

    @Test("A weekly occurrence started in London, then the Mac in New York: the record's offset and the next one's differ")
    func weeklyStartedThenTravelled() async throws {
        let status = try await DiagnosticsFixture.weeklyStartedThenTravelled()
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2026-10-23T06:00:30Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Scheduled full charge, started 2026-10-23T06:00:30Z, expires 2026-10-23T18:00:00Z
            Weekly full charge: every Fri at 07:00 for 12 hours
            Weekly next: 2026-10-30 (nominal), 2026-10-30T07:00:00-04:00 to 2026-10-30T19:00:00-04:00
            Weekly handled: 2026-10-23 (nominal), started (started), starting 2026-10-23T07:00:00+01:00
            Weekly outcome: started (window 2026-10-23T07:00:00+01:00 to 2026-10-23T19:00:00+01:00)
            Last evaluation: 2026-10-23T06:00:30Z
            """)
    }

    @Test("A weekly full charge in use that its store could not save")
    func weeklyStoreNotSaved() async throws {
        let status = try await DiagnosticsFixture.weeklyStoreNotSaved()
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2026-10-22T12:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: charging to the limit (charging)
            Wants: normal charging (normal)
            Action: none
            Reason: Charge 70% is at or below the resume threshold 75%; charging.
            Weekly full charge: every Mon, Wed, Fri at 07:30 for 1 hour
            Weekly next: 2026-10-23 (nominal), 2026-10-23T07:30:00+01:00 to 2026-10-23T08:30:00+01:00
            Weekly handled: 2026-10-21 (nominal), began before the schedule was saved (beforeSave), starting 2026-10-21T07:30:00+01:00
            Weekly store: not saved; the weekly full charge in use differs from the stored one (notSaved)
            Last evaluation: 2026-10-22T12:00:00Z
            """)
    }

    @Test("A removed weekly full charge leaves only its latest outcome")
    func weeklyRemovedAfterPassing() async throws {
        let status = try await DiagnosticsFixture.weeklyRemovedAfterPassing()
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2026-10-23T19:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: charging to the limit (charging)
            Wants: normal charging (normal)
            Action: none
            Reason: Charge 70% is at or below the resume threshold 75%; charging.
            Weekly outcome: window passed before it could start (2026-10-23T07:00:00+01:00 to 2026-10-23T19:00:00+01:00)
            Last evaluation: 2026-10-23T19:00:00Z
            """)
    }

    @Test("The one-shot and the weekly full charge due with the same end: the weekly one keeps the one-shot's full charge")
    func bothDueSameDeadline() async throws {
        let status = try await DiagnosticsFixture.bothDueSameDeadline()
        expectReport(status, head: """
            CellKeeper diagnostics
            Generated: 2027-01-15T08:00:00Z
            App: 0.1.0 (1)
            macOS: Version 27.0.1 (Build 26A434)
            Model: Mac16,1

            == Control
            Backend: Simulated (simulated)
            Availability: simulated
            Style: switches charging, modes a discharge while plugged in (forceDischarge), a charging pause (inhibitCharging), normal charging (normal)
            Reported mode: normal charging (normal)
            Pending switch: none
            Consecutive failures: 0

            == Settings
            Manage charging: on
            Charge limit: 80%
            Resume threshold: 75%
            Temperature protection: on (pause \(Self.number(40)) °C, resume \(Self.number(35)) °C)

            == Battery
            Read at: 2026-10-23T06:00:30Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: \(Self.number(30)) °C
            Voltage: not available
            Current: not available
            Adapter: not available
            System power in: not available
            Mac use: not available
            Cycle count: not available
            Full-charge capacity: not available
            Design capacity: not available
            Condition: not available

            == Decision
            State: temporary full charge (fullChargeOverride)
            Wants: normal charging (normal)
            Action: none
            Reason: Temporary full charge requested (now 70%).
            Override: Scheduled full charge, started 2026-10-23T06:00:30Z, expires 2026-10-23T18:00:00Z
            Schedule outcome: started (window 2026-10-23T06:00:00Z to 2026-10-23T18:00:00Z)
            Weekly full charge: every Fri at 07:00 for 12 hours
            Weekly next: 2026-10-30 (nominal), 2026-10-30T07:00:00Z to 2026-10-30T19:00:00Z
            Weekly handled: 2026-10-23 (nominal), started (started), starting 2026-10-23T07:00:00+01:00
            Weekly outcome: a running full charge already had the same deadline
            Last evaluation: 2026-10-23T06:00:30Z
            """)
    }
}
