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

    @Test("With simulated controls, the notes first say that the Simulated helper provides no replacement limit, without promising a full charge")
    func simulatedNotes() {
        let notes = MacOSChargeLimitGuide.notes(isSimulated: true)
        #expect(notes.count == MacOSChargeLimitGuide.notes(isSimulated: false).count + 1)
        #expect(notes[0] == "The Simulated helper provides no replacement charge limit; your Mac may charge to 100%. Keep macOS's limit on unless you are trying the simulation.")
        // macOS may still hold charging, so nothing promises a full charge.
        #expect(notes.contains { $0.contains("battery health") })
        #expect(!notes.contains { $0.contains("nothing limits") || $0.contains("charges to 100%") })
    }

    @Test("The notice's guidance cautions, with simulated controls, that the Simulated helper provides no replacement limit; otherwise it does not mention simulation", arguments: [on, unreadable])
    func guidanceCaution(status: MacOSChargeLimitStatus) {
        let simulated = MacOSChargeLimitWording.guidance(status, ownRestriction: .noneInEffect, isSimulated: true)
        #expect(simulated.contains(MacOSChargeLimitWording.simulatedCaution))
        #expect(simulated.contains("To try the simulation, "))
        #expect(!simulated.contains("To let CellKeeper manage charging"))
        #expect(!simulated.contains("nothing limits"))
        #expect(simulated.contains("never changes it itself"))
        let real = MacOSChargeLimitWording.guidance(status, ownRestriction: .noneInEffect, isSimulated: false)
        #expect(!real.contains(MacOSChargeLimitWording.simulatedCaution))
        #expect(!real.contains("simulat"))
        #expect(real.contains("never changes it itself"))
    }

    /// The sentences in `text`, by full stops.
    private func sentenceCount(_ text: String) -> Int {
        text.split(separator: ".", omittingEmptySubsequences: true).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    @Test("The menu's notice is one sentence when nothing else applies: what macOS reports and that CellKeeper withholds its own restrictions")
    func menuSummaryShort() {
        let on = MacOSChargeLimitWording.menuSummary(Self.on, ownRestriction: .noneInEffect, isSimulated: false)
        #expect(on == "macOS reports its Charge Limit on at 80%, so CellKeeper withholds its own restrictions.")
        let unreadable = MacOSChargeLimitWording.menuSummary(Self.unreadable, ownRestriction: .noneInEffect, isSimulated: false)
        #expect(unreadable == "macOS's Charge Limit report could not be read, so CellKeeper withholds its own restrictions.")
        #expect(!unreadable.contains("on at"))
    }

    @Test("The menu's notice adds one sentence only for a restriction of CellKeeper's that may remain and the simulation's caution", arguments: [on, unreadable])
    func menuSummaryCaveats(status: MacOSChargeLimitStatus) {
        let failed = MacOSChargeLimitWording.menuSummary(status, ownRestriction: .unconfirmed(.inhibitCharging), isSimulated: true)
        #expect(sentenceCount(failed) == 2)
        #expect(failed.contains("CellKeeper's own restriction (a charging pause, simulated) may remain until a read-back shows it ended"))
        #expect(failed.contains("the Simulated helper provides no replacement charge limit"))
        let simulated = MacOSChargeLimitWording.menuSummary(status, ownRestriction: .noneInEffect, isSimulated: true)
        #expect(sentenceCount(simulated) == 2)
        #expect(simulated.contains("The Simulated helper provides no replacement charge limit, so keep macOS's limit on unless you are trying the simulation."))
        let held = MacOSChargeLimitWording.menuSummary(status, ownRestriction: .inEffect(.forceDischarge, own: .forceDischarge), isSimulated: false)
        #expect(sentenceCount(held) == 2)
        #expect(held.contains("The last read-back still shows CellKeeper's own restriction (running from battery) in effect."))
        // What is not CellKeeper's is left to Settings' full explanation.
        let other = MacOSChargeLimitWording.menuSummary(status, ownRestriction: .notCellKeepers(.inhibitCharging), isSimulated: false)
        #expect(sentenceCount(other) == 1)
    }

    @Test("What the menu, Settings and the diagnostics report say names restrictions in words, never by their identifiers", arguments: [
        OwnRestrictionState.noneInEffect, .inEffect(.inhibitCharging, own: .inhibitCharging), .inEffect(.forceDischarge, own: .inhibitCharging),
        .unconfirmed(.forceDischarge), .unknown, .noneKnown, .notCellKeepers(.inhibitCharging), .unexplained(.forceDischarge),
    ])
    func readableNames(own: OwnRestrictionState) {
        for isSimulated in [false, true] {
            let texts = [
                MacOSChargeLimitWording.releaseState(own, isSimulated: isSimulated),
                MacOSChargeLimitWording.guidance(Self.on, ownRestriction: own, isSimulated: isSimulated),
                MacOSChargeLimitWording.menuSummary(Self.unreadable, ownRestriction: own, isSimulated: isSimulated),
            ] + [MacOSChargeLimitWording.ownRestrictionCaveat(own, isSimulated: isSimulated)].compactMap { $0 }
            for text in texts {
                #expect(!text.contains("inhibitCharging"))
                #expect(!text.contains("forceDischarge"))
                #expect(!text.contains("nativeLimit"))
            }
        }
        #expect(ChargeControlMode.inhibitCharging.restrictionDescription == "a charging pause")
        #expect(ChargeControlMode.forceDischarge.restrictionDescription == "running from battery")
    }
}
