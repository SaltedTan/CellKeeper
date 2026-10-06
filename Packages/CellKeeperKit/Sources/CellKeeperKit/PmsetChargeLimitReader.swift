import CellKeeperCore
import Foundation

public enum PmsetChargeLimitError: Error, Sendable, Equatable, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let message): "pmset -g battlimit failed: \(message)"
        }
    }
}

/// Reads macOS's Charge Limit with `pmset -g battlimit`.
///
/// **Undocumented, read-only.** `battlimit` is not in pmset(1) and may change
/// or disappear in any macOS update; anything this reader does not recognise
/// is reported as unrecognised, never guessed. CellKeeper runs only this
/// fixed getter and never a pmset command that changes a setting.
///
/// Every pmset invocation, including the documented `pmset -g batt`, tries to
/// open the SMC user client as it starts. Inside the App Sandbox that attempt
/// is denied and the report is unaffected (research note 08).
public struct PmsetChargeLimitReader: ChargeLimitReading {
    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/pmset")
    /// The only arguments CellKeeper ever passes to pmset.
    static let arguments = ["-g", "battlimit"]
    public static let timeout: TimeInterval = 5

    public let executable: URL

    public init(executable: URL = PmsetChargeLimitReader.defaultExecutable) {
        self.executable = executable
    }

    public func readChargeLimit() async throws -> NativeChargeLimitReading {
        let result = try await ProcessRunner.run(executable, arguments: Self.arguments, timeout: Self.timeout)
        guard result.status == 0 else {
            throw PmsetChargeLimitError.failed(result.errorSummary)
        }
        guard result.isOutputComplete else {
            throw PmsetChargeLimitError.failed("incomplete output")
        }
        return ChargeLimitReportParser.parse(result.standardOutput)
    }
}

/// Parses the text printed by `pmset -g battlimit`.
///
/// Formats observed on macOS 27.0.1 (26A434), Apple M4:
///
/// - With a Charge Limit below 100%: `Battery level limits:` followed by a
///   parenthesised list of `{ key = value; … }` entries. Every non-terminated
///   entry had `chargeSocLimitReason = manualChargeLimit` and the limit in
///   `chargeSocLimitSoc`.
/// - With the Charge Limit at 100%: the single line
///   `No battery level limits set`.
///
/// The parser accepts only these shapes, rejects repeated keys, requires
/// every active entry to be a manual Charge Limit, and requires them to
/// agree. Anything else is `.unrecognized`.
public enum ChargeLimitReportParser {
    static let noLimitLine = "No battery level limits set"
    static let header = "Battery level limits:"
    static let manualReason = "manualChargeLimit"

    public static func parse(_ text: String) -> NativeChargeLimitReading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == noLimitLine {
            return .noLimit
        }
        guard trimmed.hasPrefix(header) else {
            return .unrecognized("unexpected heading")
        }
        let list = trimmed.dropFirst(header.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard list.hasPrefix("("), list.hasSuffix(")") else {
            return .unrecognized("no list of limits")
        }

        var entries: [[String: String]] = []
        var entry: [String: String]?
        for rawLine in list.dropFirst().dropLast().split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch line {
            case "":
                continue
            case "{":
                guard entry == nil else { return .unrecognized("nested entry") }
                entry = [:]
            case "}", "},":
                guard let finished = entry else { return .unrecognized("unbalanced entry") }
                entries.append(finished)
                entry = nil
            default:
                guard entry != nil, line.hasSuffix(";"), let separator = line.range(of: " = ") else {
                    return .unrecognized("unexpected line")
                }
                let key = String(line[..<separator.lowerBound])
                let value = String(line[separator.upperBound...].dropLast())
                guard entry?[key] == nil else { return .unrecognized("repeated key \(key)") }
                entry?[key] = value
            }
        }
        guard entry == nil else { return .unrecognized("unterminated entry") }

        var limits = Set<Int>()
        for item in entries {
            switch item["Terminated"] {
            case "1":
                continue
            case "0":
                guard item["chargeSocLimitReason"] == manualReason else {
                    return .unrecognized("a limit with reason \(item["chargeSocLimitReason"] ?? "missing")")
                }
                guard let soc = item["chargeSocLimitSoc"].flatMap({ Int($0) }), (1...100).contains(soc) else {
                    return .unrecognized("a limit without a valid percentage")
                }
                limits.insert(soc)
            default:
                return .unrecognized("an entry without a valid Terminated flag")
            }
        }
        guard let limit = limits.first else {
            return .unrecognized("no active limit")
        }
        guard limits.count == 1 else {
            return .unrecognized("active limits disagree")
        }
        return .limit(limit)
    }
}
