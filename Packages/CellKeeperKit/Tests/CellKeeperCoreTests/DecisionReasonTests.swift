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
}
