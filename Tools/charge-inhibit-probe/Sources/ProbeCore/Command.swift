/// The probe's command line.
public enum Command: Sendable, Equatable {
    case check(assertion: AssertionKind)
    case run(assertion: AssertionKind, hold: Int)
    case help

    public static let defaultHold = 180
    /// At least the 90 s effect window plus one battery update interval
    /// (about 60 s) and 15 s of sampling margin, so that an effect first
    /// seen late in the window can still show a second update before the
    /// release; closer cases are inconclusive.
    public static let holdRange = 165...300

    static let assertionChoices = AssertionKind.allCases.map(\.rawValue).joined(separator: "|")

    public static let usage = """
        usage: charge-inhibit-probe check --assertion \(assertionChoices)
               sudo charge-inhibit-probe run --assertion \(assertionChoices) [--hold SECONDS]

          --assertion  Required: which private power assertion is tested.
                       disable-inflow: DisableInflow (research note 10).
                       charge-inhibit: ChargeInhibit (research note 09).
          check   Read-only. Prints the preconditions for a run and exits 0 if
                  all hold, 1 if any fails. Needs no privileges.
          run     Owner only, with sudo. Re-checks the preconditions, records a
                  baseline (\(ProbeSchedule.baseline)–\(ProbeSchedule.baselineLimit) s, until it shows 2 battery updates),
                  holds the assertion for SECONDS (default \(defaultHold), \(holdRange.lowerBound)–\(holdRange.upperBound)),
                  releases it, watches charging for \(ProbeSchedule.after) s or more, and
                  writes a report to
                  ./charge-inhibit-probe-<assertion>-<timestamp>.txt.
                  Exit status: 0 verdict reached; 1 refused to start;
                  2 inconclusive; 3 did not resume (follow the recovery
                  steps the report prints); 64 usage error.

        See docs/research/10-disable-inflow-probe.md and
        docs/research/09-charge-inhibit-probe.md.
        """

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case missingCommand
        case unknownCommand(String)
        case unexpectedArgument(String)
        case invalidHold(String)
        case missingAssertion
        case invalidAssertion(String)

        public var description: String {
            switch self {
            case .missingCommand: "no command given"
            case let .unknownCommand(command): "unknown command \"\(command)\""
            case let .unexpectedArgument(argument): "unexpected argument \"\(argument)\""
            case let .invalidHold(value): "--hold must be a whole number of seconds from \(holdRange.lowerBound) to \(holdRange.upperBound), not \"\(value)\""
            case .missingAssertion: "--assertion \(assertionChoices) is required"
            case let .invalidAssertion(value): "--assertion must be \(AssertionKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")), not \"\(value)\""
            }
        }
    }

    /// Parses the arguments after the program name.
    public static func parse(_ arguments: [String]) throws(ParseError) -> Command {
        guard let first = arguments.first else { throw .missingCommand }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "check":
            let options = try parseOptions(rest, allowHold: false)
            guard let assertion = options.assertion else { throw .missingAssertion }
            return .check(assertion: assertion)
        case "run":
            let options = try parseOptions(rest, allowHold: true)
            guard let assertion = options.assertion else { throw .missingAssertion }
            return .run(assertion: assertion, hold: options.hold ?? defaultHold)
        case "help", "-h", "--help":
            return .help
        default:
            throw .unknownCommand(first)
        }
    }

    /// `--assertion VALUE` (or `--assertion=VALUE`) and, if allowed,
    /// `--hold VALUE` (or `--hold=VALUE`), in any order, each at most once.
    static func parseOptions(_ arguments: [String], allowHold: Bool) throws(ParseError) -> (assertion: AssertionKind?, hold: Int?) {
        var assertion: AssertionKind?
        var hold: Int?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let name: String
            let value: String
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                name = String(argument[..<equals])
                value = String(argument[argument.index(after: equals)...])
                index += 1
            } else {
                name = argument
                value = index + 1 < arguments.count ? arguments[index + 1] : ""
                index += 2
            }
            switch name {
            case "--assertion" where assertion == nil:
                guard let kind = AssertionKind(rawValue: value) else { throw .invalidAssertion(value) }
                assertion = kind
            case "--hold" where allowHold && hold == nil:
                hold = try parseHold(value)
            default:
                throw .unexpectedArgument(argument)
            }
        }
        return (assertion, hold)
    }

    static func parseHold(_ value: String) throws(ParseError) -> Int {
        guard let hold = Int(value), holdRange.contains(hold) else { throw .invalidHold(value) }
        return hold
    }
}
