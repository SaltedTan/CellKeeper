/// The probe's command line.
public enum Command: Sendable, Equatable {
    case check(assertion: AssertionKind)
    case run(assertion: AssertionKind, hold: Int)
    /// `check --mechanism manual-adapter-cut` (research note 11): read-only.
    case checkManualCut
    /// `watch --mechanism manual-adapter-cut` (research note 11): the
    /// owner's observer, without sudo.
    case watchManualCut(hold: Int)
    case help

    /// What a run tests (`--mechanism`).
    public enum Mechanism: String, Sendable, Equatable, CaseIterable {
        /// One of the private power assertions (notes 09–10); the default.
        case assertion
        /// Research note 11's manual adapter cut, which the probe only
        /// observes.
        case manualAdapterCut = "manual-adapter-cut"
    }

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
               charge-inhibit-probe check --mechanism manual-adapter-cut
               charge-inhibit-probe watch --mechanism manual-adapter-cut [--hold SECONDS]

          --assertion  Required: which private power assertion is tested.
                       disable-inflow: DisableInflow (research note 10).
                       charge-inhibit: ChargeInhibit (research note 09).
          --mechanism  assertion (the default): one of the private power
                       assertions above. manual-adapter-cut: research note
                       11's manual adapter cut, which the owner makes by hand
                       with an external tool while this probe only observes;
                       --assertion is then not allowed.
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
          watch   Owner only, WITHOUT sudo, from a terminal (it refuses to run
                  as root, or if its input or output is not a terminal).
                  Asks the owner, step by step, for the external tool's
                  commands and for what each read showed, judges the battery
                  readings, holds the cut for SECONDS (default \(defaultHold), \(holdRange.lowerBound)–\(holdRange.upperBound))
                  after the owner's cut mark, and writes a report to
                  ./charge-inhibit-probe-manual-adapter-cut-<timestamp>.txt.
                  It reads no SMC key and runs no tool. Exit status: 0
                  verdict reached; 1 refused before the CUT prompt;
                  2 inconclusive; 3 follow the recovery steps the report
                  prints (any end after the CUT prompt without a confirmed
                  restore, or charging did not come back); 64 usage error.

        See docs/research/11-smc-adapter-cut.md, docs/research/10-disable-inflow-probe.md
        and docs/research/09-charge-inhibit-probe.md.
        """

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case missingCommand
        case unknownCommand(String)
        case unexpectedArgument(String)
        case invalidHold(String)
        case missingAssertion
        case invalidAssertion(String)
        case invalidMechanism(String)
        /// `--assertion` with `--mechanism manual-adapter-cut`.
        case assertionWithManualCut
        /// `run --mechanism manual-adapter-cut`: the manual cut is watched,
        /// never run.
        case runWithManualCut
        /// `watch` without `--mechanism manual-adapter-cut`.
        case watchNeedsManualCut

        public var description: String {
            switch self {
            case .missingCommand: "no command given"
            case let .unknownCommand(command): "unknown command \"\(command)\""
            case let .unexpectedArgument(argument): "unexpected argument \"\(argument)\""
            case let .invalidHold(value): "--hold must be a whole number of seconds from \(holdRange.lowerBound) to \(holdRange.upperBound), not \"\(value)\""
            case .missingAssertion: "--assertion \(assertionChoices) is required"
            case let .invalidAssertion(value): "--assertion must be \(AssertionKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")), not \"\(value)\""
            case let .invalidMechanism(value): "--mechanism must be \(Mechanism.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")), not \"\(value)\""
            case .assertionWithManualCut: "--assertion is not allowed with --mechanism manual-adapter-cut"
            case .runWithManualCut: "the manual adapter cut is never run by the probe: use `watch --mechanism manual-adapter-cut`, without sudo"
            case .watchNeedsManualCut: "watch needs --mechanism manual-adapter-cut"
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
            if options.mechanism == .manualAdapterCut {
                guard options.assertion == nil else { throw .assertionWithManualCut }
                return .checkManualCut
            }
            guard let assertion = options.assertion else { throw .missingAssertion }
            return .check(assertion: assertion)
        case "run":
            let options = try parseOptions(rest, allowHold: true)
            guard options.mechanism != .manualAdapterCut else { throw .runWithManualCut }
            guard let assertion = options.assertion else { throw .missingAssertion }
            return .run(assertion: assertion, hold: options.hold ?? defaultHold)
        case "watch":
            let options = try parseOptions(rest, allowHold: true)
            guard options.mechanism == .manualAdapterCut else { throw .watchNeedsManualCut }
            guard options.assertion == nil else { throw .assertionWithManualCut }
            return .watchManualCut(hold: options.hold ?? defaultHold)
        case "help", "-h", "--help":
            return .help
        default:
            throw .unknownCommand(first)
        }
    }

    /// `--assertion VALUE`, `--mechanism VALUE` and, if allowed,
    /// `--hold VALUE` (each also as `--name=VALUE`), in any order, each at
    /// most once.
    static func parseOptions(_ arguments: [String], allowHold: Bool) throws(ParseError) -> (assertion: AssertionKind?, hold: Int?, mechanism: Mechanism?) {
        var assertion: AssertionKind?
        var hold: Int?
        var mechanism: Mechanism?
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
            case "--mechanism" where mechanism == nil:
                guard let chosen = Mechanism(rawValue: value) else { throw .invalidMechanism(value) }
                mechanism = chosen
            case "--hold" where allowHold && hold == nil:
                hold = try parseHold(value)
            default:
                throw .unexpectedArgument(argument)
            }
        }
        return (assertion, hold, mechanism)
    }

    static func parseHold(_ value: String) throws(ParseError) -> Int {
        guard let hold = Int(value), holdRange.contains(hold) else { throw .invalidHold(value) }
        return hold
    }
}
