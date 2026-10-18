import CellKeeperCore
import Testing

@Suite("Decision reasons")
struct DecisionReasonTests {
    static let releases: [DecisionReason] = [
        .invalidConfiguration([]),
        .releaseRequired(.backendSwitch),
        .releaseRequired(.restoreUnfinished),
        .releaseRequired(.stateUnverified),
    ]

    @Test("Reasons that restore normal charging name no backend, and name the restore target when asked", arguments: releases)
    func neutralRestoreTarget(reason: DecisionReason) {
        #expect(!reason.description.contains("Charge Limit"))
        #expect(!reason.description.contains("own limit"))
        #expect(reason.description.contains("normal charging"))
        let native = reason.description(restoring: "your own macOS Charge Limit")
        #expect(native.contains("your own macOS Charge Limit"))
        #expect(!native.contains("normal charging"))
    }

    @Test("Other reasons do not change with the restore target")
    func otherReasonsUnchanged() {
        let reason = DecisionReason.limitReached(percent: 85, limit: 80)
        #expect(reason.description(restoring: "anything") == reason.description)
    }

    static let suppressions: [(PolicyState, String)] = [
        (.unmanaged, "charge management is off"),
        (.failSafe, "CellKeeper is using macOS default charging"),
        (.safetyFloor, "the safety floor applies"),
        (.onBattery, "the Mac is on battery"),
        (.temperaturePause, "charging is paused for battery temperature"),
        (.fullChargeOverride, "a temporary full charge is already in effect"),
        (.charging, "CellKeeper is charging toward its limit"),
        (.holding, "charging is paused at the limit"),
        (.discharging, "a discharge session is running"),
        (.osEnforcedLimit, "macOS enforces its Charge Limit"),
        (.deferringToMacOS, "macOS's Charge Limit is in charge"),
    ]

    @Test("A suppressed full charge is explained in plain words for every state, never by its identifier", arguments: suppressions)
    func fullChargeSuppression(state: PolicyState, words: String) {
        #expect(PolicyNote.fullChargeSuppression(by: state) == words)
        #expect(PolicyNote.fullChargeSuppressed(by: state).description == "Temporary full charge is not in effect: \(words).")
        // A multi-word identifier such as "temperaturePause" is never shown;
        // single words such as "charging" are plain words already.
        if state.rawValue.contains(where: \.isUppercase) {
            #expect(!PolicyNote.fullChargeSuppressed(by: state).description.contains(state.rawValue))
        }
    }
}
