import Foundation

/// macOS's Charge Limit as `pmset -g battlimit` reports it.
///
/// `battlimit` is an undocumented getter (`[PRIVATE/UNDOCUMENTED]`,
/// research notes 02 and 08). Observed on macOS 27.0.1: "No battery level
/// limits set" at 100%, otherwise "Battery level limits:" and a list of
/// entries with `Terminated` and `chargeSocLimitSoc`. This parser only needs
/// to know whether a limit below 100% is active; anything else is
/// `unreadable`.
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

/// The `ChargeInhibit` part of `pmset -g assertions`, reduced to structured
/// fields.
///
/// In Apple's published pmset source (PowerManagement-1846.0.25.0.1,
/// `pmset/pmset.m`), the system-wide summary lists `ChargeInhibit` only
/// while its level is non-zero, and the per-process list prints, for every
/// assertion, `pid N(process): [id] time Type named: "name"`. Only the level
/// and, per ChargeInhibit, the holder's process name (if it is a safe name)
/// and whether it is the probe's own assertion are kept. Assertion names,
/// details and every other line are dropped, so nothing arbitrary reaches a
/// report.
public struct AssertionListing: Sendable, Equatable {
    public static let type = "ChargeInhibit"

    public struct Holder: Sendable, Equatable {
        /// The holding process's name, or "[redacted]" (``Privacy/safeName(_:names:)``).
        public var process: String
        /// Whether the assertion's name is exactly the probe's.
        public var isProbe: Bool

        public init(process: String, isProbe: Bool) {
            self.process = process
            self.isProbe = isProbe
        }

        public var description: String {
            "ChargeInhibit held by \(process) (\(isProbe ? "the probe's assertion" : "another assertion"))"
        }
    }

    /// The system-wide ChargeInhibit level, nil if the summary does not list it.
    public var systemWideLevel: Int?
    public var holders: [Holder]

    public init(systemWideLevel: Int?, holders: [Holder]) {
        self.systemWideLevel = systemWideLevel
        self.holders = holders
    }

    /// Whether any ChargeInhibit assertion is listed.
    public var listsAny: Bool { (systemWideLevel ?? 0) > 0 || !holders.isEmpty }

    /// Whether the probe's own assertion is listed.
    public var listsProbe: Bool { holders.contains { $0.isProbe } }

    /// A one-line summary for reports.
    public var summary: String {
        if holders.isEmpty {
            return systemWideLevel.map { "a system-wide ChargeInhibit level of \($0) with no holder listed" } ?? "no ChargeInhibit"
        }
        return holders.map(\.description).joined(separator: "; ")
    }

    public static func parse(_ output: String, redacting names: [String] = []) -> AssertionListing {
        var level: Int?
        var holders: [Holder] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains(type) else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == type, let value = Int(fields[1]) {
                level = value
            } else if let holder = holder(in: line, names: names) {
                holders.append(holder)
            }
        }
        return AssertionListing(systemWideLevel: level, holders: holders)
    }

    /// The holder in a per-process line whose assertion type is exactly
    /// ChargeInhibit, or nil.
    static func holder(in line: String, names: [String]) -> Holder? {
        guard line.hasPrefix("pid "),
              let open = line.firstIndex(of: "("),
              let close = line.range(of: "): [", range: open..<line.endIndex),
              let idEnd = line.range(of: "] ", range: close.upperBound..<line.endIndex)
        else { return nil }
        let process = String(line[line.index(after: open)..<close.lowerBound])
        // After the id: "time Type named: "name"".
        let parts = line[idEnd.upperBound...].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[1] == type, parts[2].hasPrefix("named: \"") else { return nil }
        let quoted = parts[2].dropFirst("named: \"".count)
        let isProbe = quoted.hasSuffix("\"") && quoted.dropLast() == Substring(ProbeAssertion.name)
        return Holder(process: Privacy.safeName(process, names: names), isProbe: isProbe)
    }
}

/// What `launchctl print system/<label>` said about a launchd service.
public enum LaunchdServiceState: Sendable, Equatable {
    /// launchctl reported that the service could not be found.
    case notFound
    /// launchctl printed the service: it is loaded.
    case loaded
    /// Anything else; the reason says what.
    case unknown(String)

    /// From launchctl's exit status (nil if it could not be run) and its
    /// standard output and error together. Observed on macOS 27.0.1: a
    /// missing service exits 113 with `Could not find service "<label>" in
    /// domain for system`; a loaded one exits 0 and prints it.
    public static func parse(status: Int32?, output: String) -> LaunchdServiceState {
        guard let status else { return .unknown("launchctl could not be run") }
        if status == 0 { return .loaded }
        if output.contains("Could not find service") { return .notFound }
        return .unknown("launchctl exited with status \(status)")
    }
}

/// Processes whose executable path or name matched, from a scan of the
/// process table (names only; no process memory is read).
public struct ProcessScan: Sendable, Equatable {
    /// The matching processes' executable names (last path component),
    /// safe names only.
    public var matches: [String]
    /// Processes that were listed but whose path and name could not be read
    /// (and that had not simply exited).
    public var unreadable: Int

    public init(matches: [String], unreadable: Int) {
        self.matches = matches
        self.unreadable = unreadable
    }

    /// Fragments that identify AlDente in an executable path or name.
    /// "apphousekit" also matches a name cut to 15 characters
    /// ("com.apphousekit"), as short process names are.
    public static let aldenteFragments = ["aldente", "apphousekit"]

    /// Whether an executable path or name looks like AlDente.
    public static func isAlDente(_ pathOrName: String) -> Bool {
        let lowered = pathOrName.lowercased()
        return aldenteFragments.contains { lowered.contains($0) }
    }
}

/// Keeps user names, paths and arbitrary text out of reports.
public enum Privacy {
    static let safeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-+")

    /// `text` if it is a short name made only of letters, digits, spaces and
    /// `._-+` (so never a path) that contains none of `names`
    /// (case-insensitive); otherwise "[redacted]".
    public static func safeName(_ text: String, names: [String]) -> String {
        guard !text.isEmpty, text.count <= 64,
              text.allSatisfy({ safeCharacters.contains($0) }),
              !names.contains(where: { $0.count >= 2 && text.range(of: $0, options: .caseInsensitive) != nil })
        else { return "[redacted]" }
        return text
    }
}
