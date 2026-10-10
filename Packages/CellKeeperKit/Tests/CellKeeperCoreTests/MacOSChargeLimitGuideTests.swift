import CellKeeperCore
import Foundation
import Testing

@Suite("Turning macOS's Charge Limit off")
struct MacOSChargeLimitGuideTests {
    static let on = MacOSChargeLimitStatus(reportedLimit: 80, readAt: Date(timeIntervalSince1970: 1_800_000_000))
    static let unreadable = MacOSChargeLimitStatus(reportedLimit: nil, readAt: Date(timeIntervalSince1970: 1_800_000_000), readProblem: "pmset -g battlimit failed: exit status 1")

    @Test("The steps follow Apple's: Battery settings, the info button next to Charging, a 100% limit, Optimized Battery Charging off, then Check Again")
    func steps() {
        let steps = MacOSChargeLimitGuide.steps
        #expect(steps.count == 5)
        #expect(steps[0].contains("System Settings") && steps[0].contains("Battery"))
        #expect(steps[1].contains("ⓘ") && steps[1].contains("Charging"))
        #expect(steps[2].contains("Charge Limit to 100%") && steps[2].contains("no active limit"))
        #expect(steps[3].contains("Optimized Battery Charging"))
        #expect(steps[4].contains("Check Again"))
    }

    @Test("The notes say CellKeeper never changes the settings, that macOS may still hold charging, and that CellKeeper withholds its restrictions meanwhile")
    func notes() {
        let notes = MacOSChargeLimitGuide.notes(isSimulated: false)
        #expect(notes.contains("CellKeeper never changes these settings itself."))
        #expect(notes.contains { $0.contains("withholds its own restrictions") && $0.contains("asks for the release") })
        #expect(notes.contains { $0.contains("battery health") && $0.contains("warm") })
        #expect(!notes.contains { $0.contains("simulat") })
    }

    @Test("With simulated controls, the notes first say that nothing would limit charging with macOS's limit off")
    func simulatedNotes() {
        let notes = MacOSChargeLimitGuide.notes(isSimulated: true)
        #expect(notes.count == MacOSChargeLimitGuide.notes(isSimulated: false).count + 1)
        #expect(notes[0].contains("changes nothing on your Mac"))
        #expect(notes[0].contains("charges to 100%"))
        #expect(notes[0].contains("Leave macOS's limit on unless you want to try"))
    }

    @Test("The notice's guidance warns, with simulated controls, that nothing would limit charging; otherwise it does not mention simulation", arguments: [on, unreadable])
    func guidanceCaution(status: MacOSChargeLimitStatus) {
        let simulated = MacOSChargeLimitWording.guidance(status, ownRestriction: .noneInEffect, isSimulated: true)
        #expect(simulated.contains("Keep macOS's limit on unless you want to try CellKeeper's own control in simulation: with it off, nothing limits your Mac's charging."))
        #expect(simulated.contains("To try it, "))
        #expect(!simulated.contains("To let CellKeeper manage charging"))
        #expect(simulated.contains("never changes it itself"))
        let real = MacOSChargeLimitWording.guidance(status, ownRestriction: .noneInEffect, isSimulated: false)
        #expect(!real.contains("nothing limits your Mac's charging"))
        #expect(!real.contains("simulat"))
        #expect(real.contains("never changes it itself"))
    }
}
