/// The probe's command line.
public enum Command: Sendable, Equatable {
    case check
    case run(hold: Int)
    case help

    public static let defaultHold = 60
    /// At least the 30 s stop window plus the 8 s that five readings 2 s
    /// apart span, and one reading of margin.
    public static let holdRange = 40...300

    public static let usage = """
        usage: charge-inhibit-probe check
               sudo charge-inhibit-probe run [--hold SECONDS]

          check   Read-only. Prints the preconditions for a run and exits 0 if
                  all hold, 1 if any fails. Needs no privileges.
          run     Owner only, with sudo. Re-checks the preconditions, records a
                  20 s baseline, holds one ChargeInhibit power assertion for
                  SECONDS (default 60, \(holdRange.lowerBound)–\(holdRange.upperBound)), releases it, watches
                  charging for 60 s or more, and writes a report to
                  ./charge-inhibit-probe-<timestamp>.txt.
                  Exit status: 0 verdict reached; 1 refused to start;
                  2 inconclusive; 3 inhibited, did not resume (follow the
                  recovery steps the report prints); 64 usage error.

        See docs/research/09-charge-inhibit-probe.md.
        """

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case missingCommand
        case unknownCommand(String)
        case unexpectedArgument(String)
        case invalidHold(String)

        public var description: String {
            switch self {
            case .missingCommand: "no command given"
            case let .unknownCommand(command): "unknown command \"\(command)\""
            case let .unexpectedArgument(argument): "unexpected argument \"\(argument)\""
            case let .invalidHold(value): "--hold must be a whole number of seconds from \(holdRange.lowerBound) to \(holdRange.upperBound), not \"\(value)\""
            }
        }
    }

    /// Parses the arguments after the program name.
    public static func parse(_ arguments: [String]) throws(ParseError) -> Command {
        guard let first = arguments.first else { throw .missingCommand }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "check":
            if let extra = rest.first { throw .unexpectedArgument(extra) }
            return .check
        case "run":
            var hold = defaultHold
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                if argument == "--hold" {
                    guard index + 1 < rest.count else { throw .invalidHold("") }
                    hold = try parseHold(rest[index + 1])
                    index += 2
                } else if argument.hasPrefix("--hold=") {
                    hold = try parseHold(String(argument.dropFirst("--hold=".count)))
                    index += 1
                } else {
                    throw .unexpectedArgument(argument)
                }
            }
            return .run(hold: hold)
        case "help", "-h", "--help":
            return .help
        default:
            throw .unknownCommand(first)
        }
    }

    static func parseHold(_ value: String) throws(ParseError) -> Int {
        guard let hold = Int(value), holdRange.contains(hold) else { throw .invalidHold(value) }
        return hold
    }
}
