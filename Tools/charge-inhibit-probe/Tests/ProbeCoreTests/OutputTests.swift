import ProbeCore
import Testing

@Suite("pmset output, the command line, privacy and the report")
struct OutputTests {
    /// The shape `pmset -g battlimit` printed on macOS 27.0.1 with an 80%
    /// limit (research note 08), with the owner PID changed.
    static let eightyPercent = """
        Battery level limits:
        (
                {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitIsEOC = 1;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitOwner = 1234;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 80;
            },
                {
                Terminated = 1;
                chargeSocLimitOwner = 0;
                chargeSocLimitSoc = 90;
            },
                {
                Terminated = 0;
                chargeSocLimitOwner = 0;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 80;
            }
        )
        """

    @Test("battlimit: no limit, an active limit, and unrecognised output")
    func chargeLimitReport() {
        #expect(ChargeLimitReport.parse("No battery level limits set\n") == .noLimit)
        #expect(ChargeLimitReport.parse(Self.eightyPercent) == .limits([80]))
        #expect(ChargeLimitReport.parse(nil) == .unreadable("pmset -g battlimit could not be run"))
        #expect(ChargeLimitReport.parse("something else") == .unreadable("unexpected output"))
        #expect(ChargeLimitReport.parse("Battery level limits:\n(\n)") == .unreadable("a list without an active limit"))
    }

    /// The shape of `pmset -g assertions` (observed on macOS 27.0.1), with a
    /// ChargeInhibit added as Apple's published pmset source prints it.
    static let assertions = """
        2026-10-19 12:23:40 +1100
        Assertion status system-wide:
           BackgroundTask                 0
           ChargeInhibit                  1
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 351(powerd): [0x000ad29400018e0a] 01:53:06 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
           pid 4242(charge-inhibit-probe): [0x0000000100001234] 00:00:02 ChargeInhibit named: "CellKeeper charge-inhibit probe"
        \tDetails: Owner-run test from /Users/someone/Developer/x
        Kernel Assertions: 0x104=USB,MAGICWAKE
        """

    @Test("assertions: the ChargeInhibit level and lines, nothing else")
    func assertionListing() {
        let listing = AssertionListing.parse(Self.assertions, redacting: ["someone"])
        #expect(listing.systemWideLevel == 1)
        #expect(listing.lines == [
            "pid 4242(charge-inhibit-probe): [0x0000000100001234] 00:00:02 ChargeInhibit named: \"CellKeeper charge-inhibit probe\"",
        ])
        #expect(listing.listsAny)
        #expect(listing.lists(named: ProbeAssertion.name))
        #expect(!listing.lists(named: "something else"))

        let none = AssertionListing.parse("Assertion status system-wide:\n   BackgroundTask 0\n")
        #expect(!none.listsAny)
        #expect(none.systemWideLevel == nil)
    }

    @Test("User names and home paths are redacted")
    func privacy() {
        #expect(Privacy.redact("/Users/someone/Developer/x and /Users/other", names: []) == "/Users/[user]/Developer/x and /Users/[user]")
        #expect(Privacy.redact("pid 1(someone-tool) someone ran", names: ["someone"]) == "pid 1(someone-tool) [user] ran")
        #expect(Privacy.redact("Some One's Mac", names: ["Some One"]) == "[user]'s Mac")
    }

    @Test("The command line: check, run with a bounded hold, help")
    func commandLine() throws {
        #expect(try Command.parse(["check"]) == .check)
        #expect(try Command.parse(["run"]) == .run(hold: 60))
        #expect(try Command.parse(["run", "--hold", "120"]) == .run(hold: 120))
        #expect(try Command.parse(["run", "--hold=300"]) == .run(hold: 300))
        #expect(try Command.parse(["--help"]) == .help)
        #expect(throws: Command.ParseError.invalidHold("301")) { try Command.parse(["run", "--hold", "301"]) }
        #expect(throws: Command.ParseError.invalidHold("29")) { try Command.parse(["run", "--hold", "29"]) }
        #expect(throws: Command.ParseError.invalidHold("")) { try Command.parse(["run", "--hold"]) }
        #expect(throws: Command.ParseError.unexpectedArgument("now")) { try Command.parse(["check", "now"]) }
        #expect(throws: Command.ParseError.unknownCommand("hold")) { try Command.parse(["hold"]) }
        #expect(throws: Command.ParseError.missingCommand) { try Command.parse([]) }
    }

    @Test("The assertion's timeout exceeds the hold by 30 s")
    func timeout() {
        #expect(ProbeAssertion.timeout(hold: 60) == 90)
        #expect(ProbeAssertion.timeout(hold: Command.holdRange.upperBound) == 330)
        #expect(ProbeAssertion.type == "ChargeInhibit")
    }

    @Test("IOReturn values are named where the SDK names them")
    func ioReturnNames() {
        #expect(IOReturnName.describe(0) == "0x0 (kIOReturnSuccess)")
        #expect(IOReturnName.describe(Int32(bitPattern: 0xE000_02C1)) == "0xe00002c1 (kIOReturnNotPrivileged)")
        #expect(IOReturnName.describe(Int32(bitPattern: 0xE000_1234)) == "0xe0001234")
    }

    @Test("The report has the IOReturn, every sample, the verdict and no home path")
    func report() {
        let run = Scenario().run
        let verdict = Verdict.evaluate(run)
        let report = Report(
            startedAt: "2026-10-19 12:00:00 +11:00",
            machine: .init(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29"),
            hold: 60,
            preconditionChecks: Preconditions.evaluate(SystemState(
                reading: Sample.Reading.charging.sample(at: 0, .baseline),
                chargeLimit: .noLimit, aldenteHelperFiles: [], otherBatteryDaemons: [],
                assertions: AssertionListing(systemWideLevel: nil, lines: [])
            )),
            run: run,
            releaseResult: 0,
            listings: [.init(moment: "2 s after creation", time: 22.6, listed: true, lines: [])],
            verdict: verdict,
            notes: []
        )
        let text = report.render()
        #expect(text.contains("IOPMAssertionCreateWithProperties returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("IOPMAssertionRelease returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("2 s after creation: pmset -g assertions listed the probe's ChargeInhibit"))
        #expect(text.contains("Verdict: inhibited"))
        #expect(text.contains("timeout 90 s with TimeoutActionRelease"))
        #expect(!text.contains("/Users/"))
        #expect(run.samples.allSatisfy { text.contains(ReportFormat.sampleLine($0) + "\n") })
    }
}
