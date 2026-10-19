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

    @Test("assertions: only the ChargeInhibit level, holders' process names and whether one is the probe's")
    func assertionListing() {
        let listing = AssertionListing.parse(Self.assertions, redacting: ["someone"])
        #expect(listing.systemWideLevel == 1)
        #expect(listing.holders == [.init(process: "charge-inhibit-probe", isProbe: true)])
        #expect(listing.listsAny)
        #expect(listing.listsProbe)

        let none = AssertionListing.parse("Assertion status system-wide:\n   BackgroundTask 0\n")
        #expect(!none.listsAny)
        #expect(!none.listsProbe)
        #expect(none.systemWideLevel == nil)
    }

    /// Assertions whose names and holders carry private text.
    static let privateAssertions = """
        Assertion status system-wide:
           ChargeInhibit                  1
        Listed by owning process:
           pid 77(sometool): [0x0000000100000001] 00:01:00 ChargeInhibit named: "/Volumes/Work/private.txt"
           pid 78(/Users/name/bin/tool): [0x0000000100000002] 00:01:00 ChargeInhibit named: "/Users/name/Projects/private"
           pid 79(name-helper): [0x0000000100000003] 00:01:00 ChargeInhibit named: "CellKeeper charge-inhibit probe (copy)"
           pid 80(other): [0x0000000100000004] 00:01:00 PreventUserIdleSystemSleep named: "ChargeInhibit named: \"x\""
        """

    @Test("Arbitrary assertion names and private process names never reach the listing or the report")
    func privateAssertionText() {
        let listing = AssertionListing.parse(Self.privateAssertions, redacting: ["name"])
        #expect(listing.holders == [
            .init(process: "sometool", isProbe: false),
            .init(process: "[redacted]", isProbe: false),
            .init(process: "[redacted]", isProbe: false),
        ])
        let text = listing.summary + listing.holders.map(\.description).joined()
        for secret in ["/Volumes", "private", "/Users", "Projects", "name", "(copy)"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        #expect(!listing.listsProbe)

        var state = SystemState(
            reading: Sample.Reading.charging.sample(at: 0, .baseline),
            chargeLimit: .noLimit, aldenteHelperFiles: [], aldenteService: .notFound,
            aldenteProcesses: ProcessScan(matches: [], unreadable: 0), otherBatteryDaemons: [],
            assertions: listing
        )
        state.otherBatteryDaemons = ["com.example.battery.plist"]
        let report = Report(
            startedAt: "2026-10-19 12:00:00 +11:00",
            machine: .init(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29"),
            hold: 60,
            preconditionChecks: Preconditions.evaluate(state),
            run: Scenario().run,
            listings: [.init(moment: "2 s after creation", time: 22.6, listing: listing)]
        ).render()
        for secret in ["/Volumes", "private.txt", "/Users", "Projects"] {
            #expect(!report.contains(secret), "\(secret) leaked into the report")
        }
    }

    @Test("Only short, plain names pass; paths and the user's names are redacted")
    func privacy() {
        #expect(Privacy.safeName("com.docker.vmnetd.plist", names: []) == "com.docker.vmnetd.plist")
        #expect(Privacy.safeName("AlDente Pro", names: []) == "AlDente Pro")
        #expect(Privacy.safeName("/Users/someone/x", names: []) == "[redacted]")
        #expect(Privacy.safeName("/Volumes/Work/private.txt", names: []) == "[redacted]")
        #expect(Privacy.safeName("someone-tool", names: ["someone"]) == "[redacted]")
        #expect(Privacy.safeName("Some One's Mac", names: []) == "[redacted]")
        #expect(Privacy.safeName("SOMEONE.helper", names: ["someone"]) == "[redacted]")
        #expect(Privacy.safeName("", names: []) == "[redacted]")
        #expect(Privacy.safeName(String(repeating: "a", count: 65), names: []) == "[redacted]")
    }

    @Test("The command line: check, run with a bounded hold, help")
    func commandLine() throws {
        #expect(try Command.parse(["check"]) == .check)
        #expect(try Command.parse(["run"]) == .run(hold: 60))
        #expect(try Command.parse(["run", "--hold", "120"]) == .run(hold: 120))
        #expect(try Command.parse(["run", "--hold=300"]) == .run(hold: 300))
        #expect(try Command.parse(["--help"]) == .help)
        #expect(throws: Command.ParseError.invalidHold("301")) { try Command.parse(["run", "--hold", "301"]) }
        #expect(throws: Command.ParseError.invalidHold("39")) { try Command.parse(["run", "--hold", "39"]) }
        #expect(try Command.parse(["run", "--hold", "40"]) == .run(hold: 40))
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
                chargeLimit: .noLimit, aldenteHelperFiles: [], aldenteService: .notFound,
                aldenteProcesses: ProcessScan(matches: [], unreadable: 0), otherBatteryDaemons: [],
                assertions: AssertionListing(systemWideLevel: nil, holders: [])
            )),
            run: run,
            listings: [
                .init(moment: "2 s after creation", time: 22.6,
                      listing: AssertionListing(systemWideLevel: 1, holders: [.init(process: "charge-inhibit-probe", isProbe: true)])),
                .init(moment: "just after the release", time: 81.0, listing: AssertionListing(systemWideLevel: nil, holders: [])),
            ],
            verdict: verdict,
            notes: []
        )
        let text = report.render()
        #expect(text.contains("IOPMAssertionCreateWithProperties returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("IOPMAssertionRelease returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("2 s after creation: pmset -g assertions listed the probe's ChargeInhibit"))
        #expect(text.contains("    ChargeInhibit held by charge-inhibit-probe (the probe's assertion)"))
        #expect(text.contains("just after the release: pmset -g assertions did not list the probe's ChargeInhibit"))
        #expect(text.contains("judgment calls"))
        #expect(text.contains("Verdict: inhibited"))
        #expect(text.contains("timeout 90 s with TimeoutActionRelease"))
        #expect(!text.contains("/Users/"))
        #expect(run.samples.allSatisfy { text.contains(ReportFormat.sampleLine($0) + "\n") })
    }
}
