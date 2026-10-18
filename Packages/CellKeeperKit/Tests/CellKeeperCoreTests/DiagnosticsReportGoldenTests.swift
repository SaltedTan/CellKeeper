import CellKeeperCore
import Foundation
import Testing

/// The whole report for fixed statuses, byte for byte, so that a change in
/// how the report is built cannot change what it says unnoticed.
///
/// Each expected report is written out up to its activity section; the
/// activity section is built here from the status's events, one line each.
/// That pins the format of the activity lines but not the controller's event
/// wording, which contains local times.
@Suite("Diagnostics report, whole text")
struct DiagnosticsReportGoldenTests {
    /// `head`, then a blank line, the activity section's title and one line
    /// per event, oldest first, with the fixture's account name in paths
    /// replaced.
    private func expected(_ head: String, events: [ControlEvent]) -> String {
        let lines = events.map { "\($0.date.formatted(.iso8601)) [\($0.kind.rawValue)] \($0.message)" }
        let activity = lines.joined(separator: "\n").replacingOccurrences(of: "/Users/\(DiagnosticsFixture.accountName)/", with: "/Users/<user>/")
        return head + "\n\n== Activity (oldest first)\n" + activity + "\n"
    }

    private func report(_ status: ControllerStatus, environment: DiagnosticsEnvironment = DiagnosticsFixture.environment) -> String {
        DiagnosticsReport.text(status: status, environment: environment, generatedAt: referenceDate)
    }

    @Test("The Simulated backend holding at the limit, with every battery value")
    func simulated() async {
        let status = await DiagnosticsFixture.simulated()
        #expect(!status.events.isEmpty)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: 2027-01-15T08:00:40Z
            Charge: 81%
            Power source: external power (externalPower)
            Charging status: not charging (notCharging)
            Temperature: 31 °C
            Voltage: 12427 mV
            Current: -12 mA
            Adapter: 70 W
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("macOS's Charge Limit with the user's own limit recorded and CellKeeper's in effect")
    func nativeLimit() async {
        let status = await DiagnosticsFixture.nativeLimit()
        #expect(!status.events.isEmpty)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("macOS's Charge Limit changed outside CellKeeper and kept, with the adoption marker unsaved")
    func nativeLimitKeptOutsideChange() async {
        let status = await DiagnosticsFixture.nativeLimitKeptOutsideChange()
        #expect(!status.events.isEmpty)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("No reading, an error whose path names the account, and an unknown model")
    func noTelemetry() async {
        let status = await DiagnosticsFixture.noTelemetry()
        #expect(status.telemetryError?.contains(DiagnosticsFixture.accountName) == true)
        #expect(status.events.contains { $0.message.contains(DiagnosticsFixture.accountName) })
        var environment = DiagnosticsFixture.environment
        environment.modelIdentifier = nil
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Telemetry: unavailable: The file “battery.plist” couldn’t be opened. (NSFilePath=/Users/<user>/Library/Containers/io.github.saltedtan.CellKeeper/Data/battery.plist)

            == Decision
            State: fail-safe (failSafe)
            Wants: normal charging (normal)
            Action: none
            Reason: Battery telemetry is unavailable; using macOS default charging.
            Last evaluation: 2027-01-15T08:00:00Z
            """
        let text = report(status, environment: environment)
        #expect(text == expected(head, events: status.events))
        #expect(!text.contains(DiagnosticsFixture.accountName))
    }

    @Test("A Mac without a battery")
    func noBattery() async {
        let status = await DiagnosticsFixture.noBattery()
        #expect(!status.events.isEmpty)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("Deferring to macOS's own Charge Limit after a restriction of CellKeeper's own")
    func deferringToMacOS() async {
        let status = await DiagnosticsFixture.deferringToMacOS()
        #expect(!status.events.isEmpty)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:02:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("A running full charge with an armed schedule, then the schedule's full charge and its outcome")
    func overrideAndSchedule() async throws {
        let (armed, started) = try await DiagnosticsFixture.overrideAndSchedule()
        #expect(!armed.events.isEmpty)
        let armedHead = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(armed) == expected(armedHead, events: armed.events))

        let startedHead = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(started) == expected(startedHead, events: started.events))
    }

    @Test("A faulted backend after failed requests")
    func faulted() async {
        let status = await DiagnosticsFixture.faulted()
        #expect(status.isBackendFaulted)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:04:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("Read-only, which controls nothing, with a note on the decision")
    func readOnlyConfirming() async {
        let status = await DiagnosticsFixture.readOnlyConfirming()
        #expect(status.decision?.notes.isEmpty == false)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 81%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("A discharge to the limit, with its target")
    func discharging() async {
        let status = await DiagnosticsFixture.discharging()
        #expect(status.activeOverride?.targetPercent != nil)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 90%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("macOS's Charge Limit when neither the limit nor the record can be read")
    func nativeLimitUnreadable() async {
        let status = await DiagnosticsFixture.nativeLimitUnreadable()
        #expect(status.nativeLimit?.isRecordUnreadable == true)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:00:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("A kept change to no limit, with two flags and a switch waiting")
    func nativeLimitPendingSwitch() async {
        let status = await DiagnosticsFixture.nativeLimitPendingSwitch()
        #expect(status.pendingBackend != nil)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 78%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("Deferring while macOS's Charge Limit report cannot be read")
    func macOSLimitUnreadable() async {
        let status = await DiagnosticsFixture.macOSLimitUnreadable()
        #expect(status.capabilities.macOSChargeLimit?.readProblem != nil)
        let head = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T08:01:00Z
            Driver updated: not available
            Charge: 85%
            Power source: external power (externalPower)
            Charging status: charging (charging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(status) == expected(head, events: status.events))
    }

    @Test("A due schedule waiting on battery, then its window passing")
    func scheduleWaitingThenPassed() async throws {
        let (waiting, passed) = try await DiagnosticsFixture.scheduleWaitingThenPassed()
        #expect(waiting.fullChargeScheduleWait != nil)
        let waitingHead = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T09:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: battery power (battery)
            Charging status: discharging (discharging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(waiting) == expected(waitingHead, events: waiting.events))

        let passedHead = """
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
            Temperature protection: on (pause 40 °C, resume 35 °C)

            == Battery
            Read at: 2027-01-15T10:00:00Z
            Driver updated: not available
            Charge: 70%
            Power source: battery power (battery)
            Charging status: discharging (discharging)
            Temperature: 30 °C
            Voltage: not available
            Current: not available
            Adapter: not available
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
            """
        #expect(report(passed) == expected(passedHead, events: passed.events))
    }
}
