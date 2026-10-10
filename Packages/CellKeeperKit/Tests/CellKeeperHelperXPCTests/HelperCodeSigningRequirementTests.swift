@testable import CellKeeperHelperXPC
import Foundation
import Testing

@Suite("Helper code-signing requirements")
struct HelperCodeSigningRequirementTests {
    @Test("The helper's requirement on CellKeeper pins Apple's anchor, the identifier and the team (research note 04, §2.4)")
    func clientRequirement() throws {
        let requirement = try HelperCodeSigningRequirement.forClientApp(identifier: "io.github.saltedtan.CellKeeper", teamIdentifier: "AB12CD34EF")
        #expect(requirement.text == #"anchor apple generic and identifier "io.github.saltedtan.CellKeeper" and certificate leaf[subject.OU] = "AB12CD34EF""#)
    }

    @Test("CellKeeper's requirement on the helper has the same shape, with the helper's identifier")
    func helperRequirement() throws {
        let requirement = try HelperCodeSigningRequirement.forHelper(identifier: "io.github.saltedtan.CellKeeper.Helper", teamIdentifier: "0123456789")
        #expect(requirement.text == #"anchor apple generic and identifier "io.github.saltedtan.CellKeeper.Helper" and certificate leaf[subject.OU] = "0123456789""#)
    }

    @Test("Identifiers that could change the requirement are refused", arguments: [
        "", "io.github.x\" or anchor apple", "id with space", "id\\escape", "idé", "id\n",
    ])
    func invalidIdentifier(identifier: String) {
        #expect(throws: HelperCodeSigningRequirementError.invalidIdentifier(identifier)) {
            try HelperCodeSigningRequirement.forClientApp(identifier: identifier, teamIdentifier: "AB12CD34EF")
        }
        #expect(throws: HelperCodeSigningRequirementError.invalidIdentifier(identifier)) {
            try HelperCodeSigningRequirement.forHelper(identifier: identifier, teamIdentifier: "AB12CD34EF")
        }
    }

    @Test("Only ten uppercase letters or digits are a team identifier", arguments: [
        "", "AB12CD34E", "AB12CD34EFG", "ab12cd34ef", "AB12CD34E\"", "AB12 CD34E",
    ])
    func invalidTeam(team: String) {
        #expect(throws: HelperCodeSigningRequirementError.invalidTeamIdentifier(team)) {
            try HelperCodeSigningRequirement.forClientApp(identifier: "io.github.saltedtan.CellKeeper", teamIdentifier: team)
        }
    }

    @Test("Every requirement is compiled before use; a malformed one is an error, not NSXPC's fatal error")
    func malformed() throws {
        let text = #"identifier "unterminated"#
        #expect(throws: HelperCodeSigningRequirementError.self) {
            try HelperCodeSigningRequirement(validating: text)
        }
        #expect(throws: HelperCodeSigningRequirementError.self) {
            try HelperCodeSigningRequirement(validating: "")
        }
        #expect(try HelperCodeSigningRequirement(validating: #"identifier "a.b" and anchor apple"#).text == #"identifier "a.b" and anchor apple"#)
    }

    @Test("This process's team identifier is read from its signature; an ad-hoc build has none and cannot build production requirements")
    func ownTeam() {
        // `swift test` runs in an ad-hoc signed host, which has no team; a
        // host signed by a team must report a well-formed identifier.
        if let team = HelperCodeSigningRequirement.currentProcessTeamIdentifier() {
            #expect(HelperCodeSigningRequirement.isValidTeamIdentifier(team))
            #expect((try? HelperCodeSigningRequirement.forHelper(identifier: "io.github.saltedtan.CellKeeper.Helper"))?.text.hasSuffix("= \"\(team)\"") == true)
        } else {
            #expect(throws: HelperCodeSigningRequirementError.noTeamIdentifier) {
                try HelperCodeSigningRequirement.forClientApp(identifier: "io.github.saltedtan.CellKeeper")
            }
            #expect(throws: HelperCodeSigningRequirementError.noTeamIdentifier) {
                try HelperCodeSigningRequirement.forHelper(identifier: "io.github.saltedtan.CellKeeper.Helper")
            }
        }
    }

    @Test("This process's designated requirement can be read and compiled (the requirement tests rely on it)")
    func ownDesignatedRequirement() throws {
        let requirement: HelperCodeSigningRequirement
        do {
            requirement = try HelperCodeSigningRequirement.currentProcessDesignatedRequirement()
        } catch {
            Issue.record("The test host has no readable designated requirement (\(error)); the NSXPC requirement tests cannot run.")
            return
        }
        #expect(!requirement.text.isEmpty)
    }
}
