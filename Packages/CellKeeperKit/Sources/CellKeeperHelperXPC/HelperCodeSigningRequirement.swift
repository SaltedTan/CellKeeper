import Foundation
import Security

/// A code-signing requirement that one side of the helper connection places
/// on the other, checked by the XPC runtime for every connection
/// (research note 04, §2.2 and §2.4). Never a process ID: PIDs are reused.
///
/// A value always holds a requirement that Code Signing Services compiled
/// (`SecRequirementCreateWithString`), because NSXPC treats a malformed one
/// as a fatal error. The server and the client take one as a non-optional
/// parameter, so a connection without a requirement cannot be made by
/// accident.
///
/// Production builds use ``forClientApp(identifier:)`` (the helper's
/// requirement on CellKeeper) and ``forHelper(identifier:)`` (CellKeeper's
/// requirement on the helper): Apple-issued certificate, the exact signing
/// identifier, and the team identifier of the process that builds the
/// requirement, read from its own signature. An ad-hoc or unsigned build has
/// no team identifier and cannot build them; a helper built that way must
/// not listen at all.
public struct HelperCodeSigningRequirement: Sendable, Equatable, CustomStringConvertible {
    /// The requirement in the code-signing requirement language.
    public let text: String

    /// Compiles `text`; throws ``HelperCodeSigningRequirementError/malformed(_:status:)``
    /// if Code Signing Services cannot.
    public init(validating text: String) throws {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, requirement != nil else {
            throw HelperCodeSigningRequirementError.malformed(text, status: status)
        }
        self.text = text
    }

    public var description: String { text }

    // MARK: - Production requirements

    /// The helper's requirement on its client (research note 04, §2.4):
    /// CellKeeper with signing identifier `identifier`, signed with an
    /// Apple-issued certificate of team `teamIdentifier`.
    public static func forClientApp(identifier: String, teamIdentifier: String) throws -> HelperCodeSigningRequirement {
        try sameTeam(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    /// CellKeeper's requirement on the helper (research note 04, §2.4): the
    /// same shape, with the helper's signing identifier.
    public static func forHelper(identifier: String, teamIdentifier: String) throws -> HelperCodeSigningRequirement {
        try sameTeam(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    /// ``forClientApp(identifier:teamIdentifier:)`` with this process's own
    /// team identifier; throws ``HelperCodeSigningRequirementError/noTeamIdentifier``
    /// for an ad-hoc or unsigned build.
    public static func forClientApp(identifier: String) throws -> HelperCodeSigningRequirement {
        try forClientApp(identifier: identifier, teamIdentifier: ownTeamIdentifier())
    }

    /// ``forHelper(identifier:teamIdentifier:)`` with this process's own
    /// team identifier; throws ``HelperCodeSigningRequirementError/noTeamIdentifier``
    /// for an ad-hoc or unsigned build.
    public static func forHelper(identifier: String) throws -> HelperCodeSigningRequirement {
        try forHelper(identifier: identifier, teamIdentifier: ownTeamIdentifier())
    }

    /// `anchor apple generic and identifier "<identifier>" and
    /// certificate leaf[subject.OU] = "<teamIdentifier>"`. The certificate
    /// clauses are false for ad-hoc code, and the identifier alone is chosen
    /// by whoever signs, so all three are needed.
    static func sameTeam(identifier: String, teamIdentifier: String) throws -> HelperCodeSigningRequirement {
        guard isValidIdentifier(identifier) else {
            throw HelperCodeSigningRequirementError.invalidIdentifier(identifier)
        }
        guard isValidTeamIdentifier(teamIdentifier) else {
            throw HelperCodeSigningRequirementError.invalidTeamIdentifier(teamIdentifier)
        }
        return try HelperCodeSigningRequirement(
            validating: "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        )
    }

    /// A signing identifier as bundle identifiers are written: letters,
    /// digits, hyphens and dots. Anything else (quotes above all) could
    /// change the requirement it is placed in.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 255 && identifier.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".")
        }
    }

    /// Ten uppercase letters or digits, as Apple issues team identifiers.
    static func isValidTeamIdentifier(_ team: String) -> Bool {
        team.utf8.count == 10 && team.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    private static func ownTeamIdentifier() throws -> String {
        guard let team = currentProcessTeamIdentifier() else {
            throw HelperCodeSigningRequirementError.noTeamIdentifier
        }
        return team
    }

    // MARK: - This process's signature

    /// The team identifier of this process's signature
    /// (`SecCodeCopySelf`, `SecCodeCopySigningInformation`); nil if it is
    /// ad-hoc signed or unsigned, or the signature is not valid and anchored
    /// in an Apple-issued certificate of that team.
    public static func currentProcessTeamIdentifier() -> String? {
        guard let code = selfCode(), let staticCode = staticCode(of: code) else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              isValidTeamIdentifier(team)
        else { return nil }
        // The team identifier is a field of the signature; trust it only if
        // the running code is valid and its certificate says the same.
        var anchored: SecRequirement?
        guard SecRequirementCreateWithString(
                  "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &anchored
              ) == errSecSuccess,
              let anchored,
              SecCodeCheckValidity(code, [], anchored) == errSecSuccess
        else { return nil }
        return team
    }

    /// This process's designated requirement (`SecCodeCopySelf`,
    /// `SecCodeCopyDesignatedRequirement`): the requirement that this very
    /// code satisfies. For ad-hoc code it names the exact build (its cdhash).
    /// Tests use it on both sides of a connection inside one process, so the
    /// requirement checks run for real.
    public static func currentProcessDesignatedRequirement() throws -> HelperCodeSigningRequirement {
        var status = errSecSuccess
        var code: SecCode?
        status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            throw HelperCodeSigningRequirementError.noDesignatedRequirement(status: status)
        }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw HelperCodeSigningRequirementError.noDesignatedRequirement(status: status)
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw HelperCodeSigningRequirementError.noDesignatedRequirement(status: status)
        }
        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else {
            throw HelperCodeSigningRequirementError.noDesignatedRequirement(status: status)
        }
        return try HelperCodeSigningRequirement(validating: text as String)
    }

    private static func selfCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func staticCode(of code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }
}

/// Why a ``HelperCodeSigningRequirement`` could not be made.
public enum HelperCodeSigningRequirementError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Code Signing Services could not compile the requirement.
    case malformed(String, status: OSStatus)
    /// A signing identifier with characters a bundle identifier never has.
    case invalidIdentifier(String)
    /// Not a team identifier (ten uppercase letters or digits).
    case invalidTeamIdentifier(String)
    /// This process is ad-hoc signed or unsigned, so it has no team
    /// identifier to require of its peer.
    case noTeamIdentifier
    /// This process's designated requirement could not be read.
    case noDesignatedRequirement(status: OSStatus)

    public var description: String {
        switch self {
        case .malformed(let text, let status): "the code-signing requirement \"\(text)\" is malformed (status \(status))"
        case .invalidIdentifier(let identifier): "\"\(identifier)\" is not a valid signing identifier"
        case .invalidTeamIdentifier(let team): "\"\(team)\" is not a valid team identifier"
        case .noTeamIdentifier: "this build is not signed with a team identifier (ad-hoc or unsigned)"
        case .noDesignatedRequirement(let status): "this process's designated requirement could not be read (status \(status))"
        }
    }
}
