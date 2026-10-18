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

    /// Every state, with the rule it names when it takes precedence over a
    /// full charge, or nil when it comes after the full charge in
    /// precedence and cannot keep it from taking effect.
    static let suppressions: [(PolicyState, String?)] = [
        (.unmanaged, "the Manage charging setting takes precedence"),
        (.failSafe, "CellKeeper's fail-safe takes precedence"),
        (.deferringToMacOS, "deferring to macOS's Charge Limit takes precedence"),
        (.safetyFloor, "the safety floor takes precedence"),
        (.onBattery, "being on battery power takes precedence"),
        (.temperaturePause, "temperature protection takes precedence"),
        (.fullChargeOverride, nil),
        (.charging, nil),
        (.holding, nil),
        (.discharging, nil),
        (.osEnforcedLimit, nil),
    ]

    @Test("A suppressed full charge names the rule that takes precedence, never an applied state or an identifier; states that cannot suppress one name nothing", arguments: suppressions)
    func fullChargeSuppression(state: PolicyState, rule: String?) {
        #expect(PolicyNote.fullChargeSuppression(by: state) == rule)
        let note = PolicyNote.fullChargeSuppressed(by: state).description
        if let rule {
            #expect(note == "Temporary full charge is not in effect: \(rule).")
        } else {
            #expect(note == "Temporary full charge is not in effect.")
        }
        for claim in ["paused", "confirmed", "applied"] {
            #expect(!note.lowercased().contains(claim), "\(claim) in: \(note)")
        }
        // A multi-word identifier such as "temperaturePause" is never shown.
        if state.rawValue.contains(where: \.isUppercase) {
            #expect(!note.contains(state.rawValue))
        }
    }
}
