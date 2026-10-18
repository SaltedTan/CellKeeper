@testable import CellKeeperCore
import Foundation
import Testing

/// Words written like the identifiers of Swift cases, such as
/// "inhibitCharging": lowercase first, with an uppercase letter later.
/// "macOS" is a name, not an identifier.
private func camelCaseWords(in text: String) -> [String] {
    text.split { !$0.isLetter }.map(String.init).filter { word in
        word != "macOS" && word.first?.isLowercase == true && word.contains(where: \.isUppercase)
    }
}

@Suite("Plain words in user-facing text")
struct PlainWordsTests {
    let clock = TestClock()

    static let modes: [ChargeControlMode] = [.normal, .inhibitCharging, .forceDischarge, .nativeLimit(percent: 85)]

    /// `words` names a case in plain words: never as an identifier, and only
    /// a one-word identifier ("charging", "unknown") is its own plain word.
    private func expectPlainWords(_ words: String, identifier: String) {
        #expect(camelCaseWords(in: words).isEmpty, "\(identifier) is shown as \(words)")
        if identifier.contains(where: \.isUppercase) {
            #expect(words != identifier)
        }
    }

    @Test("Every policy state has plain words of its own", arguments: PolicyState.allCases)
    func policyState(_ state: PolicyState) {
        expectPlainWords(state.description, identifier: state.rawValue)
        #expect(PolicyState.allCases.filter { $0.description == state.description } == [state])
    }

    @Test("Every evaluation trigger has plain words of its own", arguments: EvaluationTrigger.allCases)
    func trigger(_ trigger: EvaluationTrigger) {
        expectPlainWords(trigger.description, identifier: trigger.rawValue)
        #expect(EvaluationTrigger.allCases.filter { $0.description == trigger.description } == [trigger])
    }

    @Test("Every power source has plain words of its own", arguments: PowerSource.allCases)
    func powerSource(_ source: PowerSource) {
        expectPlainWords(source.description, identifier: source.rawValue)
        #expect(PowerSource.allCases.filter { $0.description == source.description } == [source])
    }

    @Test("Every charging status has plain words of its own", arguments: ChargingStatus.allCases)
    func chargingStatus(_ status: ChargingStatus) {
        expectPlainWords(status.description, identifier: status.rawValue)
        #expect(ChargingStatus.allCases.filter { $0.description == status.description } == [status])
    }

    @Test("Every mode has plain words of its own; its identifier is kept for the diagnostics report", arguments: modes)
    func mode(_ mode: ChargeControlMode) {
        expectPlainWords(mode.description, identifier: mode.identifier)
        #expect(Self.modes.filter { $0.description == mode.description } == [mode])
    }

    @Test("The telemetry line names the power source and charging status in plain words")
    func telemetryLine() {
        #expect(ChargeController.describe(snapshot(percent: 70, charging: true, temperature: nil)) == "Battery 70%, on external power, charging, temperature n/a.")
        #expect(ChargeController.describe(snapshot(percent: 70, charging: false, temperature: nil)) == "Battery 70%, on external power, not charging, temperature n/a.")
        #expect(ChargeController.describe(snapshot(percent: 100, charging: false, fullyCharged: true, temperature: nil)) == "Battery 100%, on external power, fully charged, temperature n/a.")
        #expect(ChargeController.describe(snapshot(percent: 70, source: .battery, temperature: nil)) == "Battery 70%, on battery power, discharging, temperature n/a.")
        #expect(ChargeController.describe(snapshot(percent: nil, source: .unknown, temperature: nil)) == "Battery unknown charge, unknown power source, unknown charging status, temperature n/a.")
        for source in PowerSource.allCases {
            for charging in [true, false, nil] as [Bool?] {
                let line = ChargeController.describe(snapshot(percent: 70, source: source, charging: charging, fullyCharged: nil, temperature: 31))
                #expect(camelCaseWords(in: line).isEmpty, "\(line)")
            }
        }
    }

    @Test("The decision line is a sentence: the state, when it was checked, what CellKeeper wants and does, and why", arguments: EvaluationTrigger.allCases)
    func decisionLine(trigger: EvaluationTrigger) async {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 70), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        let status = await controller.evaluate(trigger)
        let decisions = status.events.filter { $0.kind == .decision }.map(\.message)
        let expected = "Charging to the limit (\(trigger)): wants normal charging, action none. Charge 70% is at or below the resume threshold 75%; charging."
        #expect(decisions == [expected])
    }

    @Test("Decision lines and every other activity name states, modes and power in plain words")
    func activityWords() async {
        let clock = clock
        let telemetry = StubTelemetry(snapshot(percent: 85), clock: clock)
        let controller = ChargeController(telemetry: telemetry, backend: MockChargingBackend(), settings: .default, now: { clock.now }, uptime: { clock.uptime })
        await controller.evaluate(.launch)
        clock.advance(by: 60)
        let holding = await controller.evaluate(.periodic)
        #expect(holding.events.contains { $0.kind == .decision && $0.message == "Holding at the limit (at a periodic check): wants a charging pause, action disable charging. Charge 85% has reached the 80% limit; charging paused." })
        #expect(holding.events.contains { $0.kind == .request && $0.message == "Requesting a charging pause from Simulated backend." })

        clock.advance(by: 60)
        await telemetry.set(snapshot(percent: 85, source: .battery))
        await controller.evaluate(.powerSourceChanged)
        clock.advance(by: 60)
        await telemetry.set(snapshot(percent: 85))
        await controller.evaluate(.powerSourceChanged)
        await controller.startDischargeToLimit()
        await controller.cancelOverride()
        await controller.startFullCharge()
        clock.advance(by: 60)
        await telemetry.set(snapshot(percent: 85, temperature: 45))
        await controller.evaluate(.periodic)
        clock.advance(by: 60)
        await telemetry.fail(with: TelemetryTestError())
        let status = await controller.evaluate(.periodic)

        let states = status.events.filter { $0.kind == .decision }.compactMap { event in
            PolicyState.allCases.first { state in event.message.hasPrefix("\(state.description.prefix(1).uppercased())\(state.description.dropFirst()) (") }
        }
        for state in [PolicyState.charging, .holding, .temperaturePause, .onBattery, .discharging, .fullChargeOverride, .failSafe] {
            #expect(states.contains(state), "no decision line for \(state.rawValue)")
        }
        for event in status.events {
            #expect(camelCaseWords(in: event.message).isEmpty, "\(event.message)")
        }
    }
}
