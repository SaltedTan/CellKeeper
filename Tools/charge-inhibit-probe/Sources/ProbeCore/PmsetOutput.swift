import Foundation

/// macOS's Charge Limit as `pmset -g battlimit` reports it.
///
/// `battlimit` is an undocumented getter (`[PRIVATE/UNDOCUMENTED]`,
/// research notes 02 and 08). Observed on macOS 27.0.1: "No battery level
/// limits set" at 100%, otherwise "Battery level limits:" and a list of
/// entries with `Terminated` and `chargeSocLimitSoc`. This parser is
/// deliberately lenient (the probe only needs to know whether a limit below
/// 100% is active); anything else is `unreadable`.
public enum ChargeLimitReport: Sendable, Equatable {
    /// No limit: the Charge Limit is 100%.
    case noLimit
    /// The active (non-terminated) limits, in percent, without repeats.
    case limits([Int])
    /// The output was missing or not in a recognised shape.
    case unreadable(String)

    static let noLimitLine = "No battery level limits set"
    static let header = "Battery level limits:"

    public static func parse(_ output: String?) -> ChargeLimitReport {
        guard let output else { return .unreadable("pmset -g battlimit could not be run") }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == noLimitLine { return .noLimit }
        guard text.hasPrefix(header) else { return .unreadable("unexpected output") }

        var limits: [Int] = []
        var terminated: String?
        var soc: Int?
        var inEntry = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                inEntry = true
                terminated = nil
                soc = nil
            } else if line == "}" || line == "}," {
                guard inEntry else { return .unreadable("unbalanced entry") }
                inEntry = false
                switch terminated {
                case "0":
                    guard let soc, (1...100).contains(soc) else { return .unreadable("a limit without a percentage") }
                    limits.append(soc)
                case "1":
                    break
                default:
                    return .unreadable("an entry without Terminated")
                }
            } else if inEntry, let value = Self.value(of: "Terminated", in: line) {
                terminated = value
            } else if inEntry, let value = Self.value(of: "chargeSocLimitSoc", in: line) {
                soc = Int(value)
            }
        }
        guard !inEntry else { return .unreadable("unterminated entry") }
        return limits.isEmpty ? .unreadable("a list without an active limit") : .limits(Array(Set(limits)).sorted())
    }

    /// The value in a `key = value;` line, or nil.
    static func value(of key: String, in line: String) -> String? {
        let prefix = key + " = "
        guard line.hasPrefix(prefix), line.hasSuffix(";") else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }
}

/// The `ChargeInhibit` part of `pmset -g assertions`.
///
/// In Apple's published pmset source (PowerManagement-1846.0.25.0.1,
/// `pmset/pmset.m`), the system-wide summary lists `ChargeInhibit` only
/// while its level is non-zero, and the per-process list names the type of
/// every assertion a process holds. Only lines that mention ChargeInhibit
/// are kept; everything else pmset prints (other processes' assertions) is
/// dropped, and kept lines are redacted (``Privacy/redact(_:names:)``).
public struct AssertionListing: Sendable, Equatable {
    public static let type = "ChargeInhibit"

    /// The system-wide ChargeInhibit level, nil if the summary does not list it.
    public var systemWideLevel: Int?
    /// Per-process lines that mention ChargeInhibit, redacted.
    public var lines: [String]

    public init(systemWideLevel: Int?, lines: [String]) {
        self.systemWideLevel = systemWideLevel
        self.lines = lines
    }

    /// Whether any ChargeInhibit assertion is listed.
    public var listsAny: Bool { (systemWideLevel ?? 0) > 0 || !lines.isEmpty }

    /// Whether an assertion with this name is listed as ChargeInhibit.
    public func lists(named name: String) -> Bool {
        lines.contains { $0.contains("\"\(name)\"") }
    }

    public static func parse(_ output: String, redacting names: [String] = []) -> AssertionListing {
        var level: Int?
        var lines: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains(type) else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == type, let value = Int(fields[1]) {
                level = value
            } else {
                lines.append(Privacy.redact(line, names: names))
            }
        }
        return AssertionListing(systemWideLevel: level, lines: lines)
    }
}

/// Keeps user names and home paths out of reports.
public enum Privacy {
    /// Replaces `/Users/<name>` path components, and each of `names` where
    /// it appears as a whole word, with placeholders.
    public static func redact(_ text: String, names: [String]) -> String {
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "/Users/") {
            result += rest[..<range.upperBound] + "[user]"
            rest = rest[range.upperBound...].drop { $0 != "/" && !$0.isWhitespace && $0 != "\"" }
        }
        result += rest
        for name in names where name.count >= 2 {
            result = replacingWholeWord(name, in: result, with: "[user]")
        }
        return result
    }

    static func replacingWholeWord(_ word: String, in text: String, with replacement: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: word) {
            let before = range.lowerBound == rest.startIndex ? nil : rest[rest.index(before: range.lowerBound)]
            let after = range.upperBound == rest.endIndex ? nil : rest[range.upperBound]
            let isWord = !(before.map(isNameCharacter) ?? false) && !(after.map(isNameCharacter) ?? false)
            result += rest[..<range.lowerBound] + (isWord ? replacement : word)
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }
}
