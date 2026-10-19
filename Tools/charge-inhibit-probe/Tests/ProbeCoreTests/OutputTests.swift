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

    static let machine = Report.MachineInfo(model: "Mac16,1", osVersion: "27.0.1", osBuild: "26A434", firmware: "mBoot-20457.1.29")

    @Test("battlimit: no limit, an active limit, and unrecognised output")
    func chargeLimitReport() {
        #expect(ChargeLimitReport.parse("No battery level limits set\n") == .noLimit)
        #expect(ChargeLimitReport.parse(Self.eightyPercent) == .limits([80]))
        #expect(ChargeLimitReport.parse(nil) == .unreadable("pmset -g battlimit could not be run"))
        #expect(ChargeLimitReport.parse("something else") == .unreadable("unexpected output"))
        #expect(ChargeLimitReport.parse("Battery level limits:\n(\n)") == .unreadable("a list without an active limit"))
    }

    /// The shape of `pmset -g assertions` (observed on macOS 27.0.1), with a
    /// DisableInflow and a ChargeInhibit added as Apple's published pmset
    /// source prints them.
    static let assertions = """
        2026-10-19 12:23:40 +1100
        Assertion status system-wide:
           BackgroundTask                 0
           ChargeInhibit                  1
           DisableInflow                  1
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 351(powerd): [0x000ad29400018e0a] 01:53:06 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
           pid 4242(charge-inhibit-probe): [0x0000000100001234] 00:00:02 DisableInflow named: "CellKeeper disable-inflow probe"
           pid 4242(charge-inhibit-probe): [0x0000000100001235] 00:00:02 PreventUserIdleSystemSleep named: "CellKeeper probe: no idle sleep during the run"
           pid 77(othertool): [0x0000000100001236] 00:05:00 ChargeInhibit named: "CellKeeper disable-inflow probe"
        \tDetails: Owner-run test from /Users/someone/Developer/x
        Kernel Assertions: 0x104=USB,MAGICWAKE
        """

    @Test("assertions: only the two types' levels, holders' process names and whether one is the probe's")
    func assertionListing() {
        let listing = AssertionListing.parse(Self.assertions, redacting: ["someone"])
        #expect(listing.systemWideLevels == ["ChargeInhibit": 1, "DisableInflow": 1])
        #expect(listing.holders == [
            .init(type: "DisableInflow", process: "charge-inhibit-probe", isProbe: true),
            // The probe's name on the other type is not the probe's assertion.
            .init(type: "ChargeInhibit", process: "othertool", isProbe: false),
        ])
        #expect(listing.listsAny)
        #expect(listing.listsProbe(.disableInflow))
        #expect(!listing.listsProbe(.chargeInhibit))

        let none = AssertionListing.parse("Assertion status system-wide:\n   BackgroundTask 0\n")
        #expect(!none.listsAny)
        #expect(!none.listsProbe(.disableInflow))
        #expect(none.systemWideLevels.isEmpty)
        #expect(none.summary == "no DisableInflow or ChargeInhibit")
    }

    /// Assertions whose names and holders carry private text.
    static let privateAssertions = """
        Assertion status system-wide:
           ChargeInhibit                  1
        Listed by owning process:
           pid 77(sometool): [0x0000000100000001] 00:01:00 ChargeInhibit named: "/Volumes/Work/private.txt"
           pid 78(/Users/name/bin/tool): [0x0000000100000002] 00:01:00 DisableInflow named: "/Users/name/Projects/private"
           pid 79(name-helper): [0x0000000100000003] 00:01:00 ChargeInhibit named: "CellKeeper charge-inhibit probe (copy)"
           pid 80(other): [0x0000000100000004] 00:01:00 PreventUserIdleSystemSleep named: "DisableInflow named: \"x\""
        """

    @Test("Arbitrary assertion names and private process names never reach the listing or the report")
    func privateAssertionText() {
        let listing = AssertionListing.parse(Self.privateAssertions, redacting: ["name"])
        #expect(listing.holders == [
            .init(type: "ChargeInhibit", process: "sometool", isProbe: false),
            .init(type: "DisableInflow", process: "[redacted]", isProbe: false),
            .init(type: "ChargeInhibit", process: "[redacted]", isProbe: false),
        ])
        let text = listing.summary + listing.holders.map(\.description).joined()
        for secret in ["/Volumes", "private", "/Users", "Projects", "name", "(copy)"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        #expect(!listing.listsProbe(.chargeInhibit))
        #expect(!listing.listsProbe(.disableInflow))

        var state = SystemState(
            reading: Sample.Reading.charging.sample(at: 0, .baseline),
            chargeLimit: .noLimit, aldenteHelperFiles: [], aldenteService: .notFound,
            aldenteProcesses: ProcessScan(matches: [], unreadable: 0), otherBatteryDaemons: [],
            assertions: listing
        )
        state.otherBatteryDaemons = ["com.example.battery.plist"]
        let report = Report(
            assertion: .disableInflow,
            startedAt: "2026-10-19 12:00:00 +11:00",
            machine: Self.machine,
            hold: 180,
            preconditionChecks: Preconditions.evaluate(state, assertion: .disableInflow),
            run: Scenario().run,
            listings: [.init(moment: "2 s after creation", time: 22.6, listing: listing)]
        ).render()
        for secret in ["/Volumes", "private.txt", "/Users", "Projects"] {
            #expect(!report.contains(secret), "\(secret) leaked into the report")
        }
    }

    @Test("Only the adapter's presence and Watts are kept; its serial number and names never reach a report")
    func adapterDetails() {
        let details: [String: Any] = [
            "Watts": 68, "Current": 3250, "AdapterID": 7, "FamilyCode": -536_854_528,
            "SerialNumber": "C0SERIAL1234XYZ", "SerialString": "C0SERIAL1234XYZ",
            "Name": "70W USB-C Power Adapter ", "Manufacturer": "Apple Inc.", "Model": "0x7019",
        ]
        let adapter = Sample.adapter(from: details)
        #expect(adapter.attached)
        #expect(adapter.watts == 68)
        #expect(Sample.adapter(from: nil) == (false, nil))
        #expect(Sample.adapter(from: ["Name": "x"]) == (true, nil))
        #expect(Sample.adapter(from: ["Watts": 99_999]).watts == nil)

        var sample = Sample.Reading.charging.sample(at: 0, .held)
        sample.adapterAttached = adapter.attached
        sample.adapterWatts = adapter.watts
        let line = ReportFormat.sampleLine(sample)
        #expect(line.contains("68 W"))
        let report = Report(
            assertion: .disableInflow, startedAt: "2026-10-19 12:00:00 +11:00", machine: Self.machine, hold: 180,
            preconditionChecks: Preconditions.evaluate(SystemState(
                reading: sample, chargeLimit: .noLimit, aldenteHelperFiles: [], aldenteService: .notFound,
                aldenteProcesses: ProcessScan(matches: [], unreadable: 0), otherBatteryDaemons: [],
                assertions: AssertionListing()
            ), assertion: .disableInflow),
            run: ProbeRun(assertion: .disableInflow, samples: [sample], creation: nil, release: nil)
        ).render()
        for secret in ["C0SERIAL", "USB-C Power Adapter", "Apple Inc.", "0x7019", "3250"] {
            #expect(!line.contains(secret), "\(secret) leaked into a sample line")
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

    @Test("The command line: the assertion is required for check and run; a bounded hold; help")
    func commandLine() throws {
        #expect(try Command.parse(["check", "--assertion", "disable-inflow"]) == .check(assertion: .disableInflow))
        #expect(try Command.parse(["check", "--assertion=charge-inhibit"]) == .check(assertion: .chargeInhibit))
        #expect(try Command.parse(["run", "--assertion", "disable-inflow"]) == .run(assertion: .disableInflow, hold: 180))
        #expect(try Command.parse(["run", "--hold", "240", "--assertion", "charge-inhibit"]) == .run(assertion: .chargeInhibit, hold: 240))
        #expect(try Command.parse(["run", "--assertion=disable-inflow", "--hold=300"]) == .run(assertion: .disableInflow, hold: 300))
        #expect(try Command.parse(["run", "--assertion", "disable-inflow", "--hold", "165"]) == .run(assertion: .disableInflow, hold: 165))
        #expect(try Command.parse(["--help"]) == .help)
        #expect(throws: Command.ParseError.missingAssertion) { try Command.parse(["run"]) }
        #expect(throws: Command.ParseError.missingAssertion) { try Command.parse(["check"]) }
        #expect(throws: Command.ParseError.missingAssertion) { try Command.parse(["run", "--hold", "180"]) }
        #expect(throws: Command.ParseError.invalidAssertion("DisableInflow")) { try Command.parse(["run", "--assertion", "DisableInflow"]) }
        #expect(throws: Command.ParseError.invalidAssertion("")) { try Command.parse(["check", "--assertion"]) }
        #expect(throws: Command.ParseError.unexpectedArgument("--assertion")) {
            try Command.parse(["run", "--assertion", "disable-inflow", "--assertion", "charge-inhibit"])
        }
        #expect(throws: Command.ParseError.invalidHold("301")) { try Command.parse(["run", "--assertion", "disable-inflow", "--hold", "301"]) }
        #expect(throws: Command.ParseError.invalidHold("164")) { try Command.parse(["run", "--assertion", "disable-inflow", "--hold", "164"]) }
        #expect(throws: Command.ParseError.invalidHold("")) { try Command.parse(["run", "--assertion", "disable-inflow", "--hold"]) }
        #expect(throws: Command.ParseError.unexpectedArgument("--hold")) { try Command.parse(["check", "--assertion", "disable-inflow", "--hold", "180"]) }
        #expect(throws: Command.ParseError.unexpectedArgument("now")) { try Command.parse(["check", "now"]) }
        #expect(throws: Command.ParseError.unknownCommand("hold")) { try Command.parse(["hold"]) }
        #expect(throws: Command.ParseError.missingCommand) { try Command.parse([]) }
        #expect(Command.usage.contains("--assertion disable-inflow|charge-inhibit"))
    }

    @Test("The timeouts: the private assertion's exceeds the hold by 30 s; the idle-sleep one covers the longest run")
    func timeouts() {
        #expect(ProbeAssertion.timeout(hold: 180) == 210)
        #expect(ProbeAssertion.timeout(hold: Command.holdRange.upperBound) == 330)
        #expect(ProbeSchedule.longestRun(hold: 180) == 150 + 180 + 180 + 120)
        #expect(ProbeAssertion.idleSleepTimeout(hold: 180) == ProbeSchedule.longestRun(hold: 180) + 120)
        #expect(AssertionKind.disableInflow.type == "DisableInflow")
        #expect(AssertionKind.chargeInhibit.type == "ChargeInhibit")
        // Note 09's assertion name is unchanged, so its run stays reproducible.
        #expect(AssertionKind.chargeInhibit.name == "CellKeeper charge-inhibit probe")
    }

    @Test("Report file names name the assertion and match the .gitignore pattern")
    func reportFileNames() {
        for kind in AssertionKind.allCases {
            let name = kind.reportFileName(stamp: "20261020-101500")
            #expect(name.hasPrefix("charge-inhibit-probe-"))
            #expect(name.hasSuffix(".txt"))
            #expect(name.contains(kind.rawValue))
        }
        #expect(AssertionKind.disableInflow.reportFileName(stamp: "20261020-101500") == "charge-inhibit-probe-disable-inflow-20261020-101500.txt")
    }

    @Test("IOReturn values are named where the SDK names them")
    func ioReturnNames() {
        #expect(IOReturnName.describe(0) == "0x0 (kIOReturnSuccess)")
        #expect(IOReturnName.describe(Int32(bitPattern: 0xE000_02C1)) == "0xe00002c1 (kIOReturnNotPrivileged)")
        #expect(IOReturnName.describe(Int32(bitPattern: 0xE000_1234)) == "0xe0001234")
    }

    func report(_ run: ProbeRun, listings: [Report.ListingCheck] = [], sleepGuard: Report.SleepGuard? = nil) -> Report {
        Report(
            assertion: run.assertion,
            startedAt: "2026-10-19 12:00:00 +11:00",
            machine: Self.machine,
            hold: 180,
            preconditionChecks: Preconditions.evaluate(SystemState(
                reading: Sample.Reading.charging.sample(at: 0, .baseline),
                chargeLimit: .noLimit, aldenteHelperFiles: [], aldenteService: .notFound,
                aldenteProcesses: ProcessScan(matches: [], unreadable: 0), otherBatteryDaemons: [],
                assertions: AssertionListing()
            ), assertion: run.assertion),
            run: run,
            listings: listings,
            sleepGuard: sleepGuard,
            verdict: Verdict.evaluate(run),
            notes: []
        )
    }

    @Test("The report has both assertions' IOReturns, every sample, the verdict and no home path")
    func reportContents() {
        let run = Scenario().run
        let text = report(
            run,
            listings: [
                .init(moment: "2 s after creation", time: 22.6, listing: AssertionListing(
                    systemWideLevels: ["DisableInflow": 1],
                    holders: [.init(type: "DisableInflow", process: "charge-inhibit-probe", isProbe: true)]
                )),
                .init(moment: "just after the release", time: 201.1, listing: AssertionListing()),
            ],
            sleepGuard: .init(registered: true, created: (0.4, 0), released: (382, 0))
        ).render()
        #expect(text.hasPrefix("CellKeeper DisableInflow probe report"))
        #expect(text.contains("sleep notifications: registered (IORegisterForSystemPower)"))
        #expect(text.contains("+0.4 s: IOPMAssertionCreateWithProperties (PreventUserIdleSystemSleep) returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("+382.0 s: IOPMAssertionRelease (PreventUserIdleSystemSleep) returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("IOPMAssertionCreateWithProperties (DisableInflow) returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("IOPMAssertionRelease (DisableInflow) returned 0x0 (kIOReturnSuccess)"))
        #expect(text.contains("2 s after creation: pmset -g assertions listed the probe's DisableInflow"))
        #expect(text.contains("    DisableInflow held by charge-inhibit-probe (the probe's assertion)"))
        #expect(text.contains("just after the release: pmset -g assertions did not list the probe's DisableInflow"))
        #expect(text.contains("judgment calls"))
        #expect(text.contains("at most 1000 mW"))
        #expect(text.contains("Verdict: inhibited"))
        #expect(text.contains("timeout 210 s with TimeoutActionRelease"))
        #expect(!text.contains("CHECK RECOVERY FIRST"))
        #expect(!text.contains("/Users/"))
        #expect(run.samples.allSatisfy { text.contains(ReportFormat.sampleLine($0) + "\n") })
    }

    @Test("A report whose last reading is not charging on adapter power opens with the recovery steps")
    func recoveryFirst() {
        var scenario = Scenario()
        scenario.held = { $0 < 4 ? .charging : .cut }
        scenario.after = { _ in .cut }
        scenario.afterDuration = 300
        let text = report(scenario.run).render()
        let recovery = text.range(of: "CHECK RECOVERY FIRST")
        let preconditions = text.range(of: "Preconditions")
        #expect(recovery != nil)
        if let recovery, let preconditions {
            #expect(recovery.lowerBound < preconditions.lowerBound)
        }
        #expect(text.contains("lists no DisableInflow"))
        #expect(text.contains("Verdict: discharging, did not resume"))

        // Nothing created: no recovery section.
        var refused = Scenario()
        refused.creationResult = Scenario.notPrivileged
        #expect(!report(refused.run).needsRecovery())
    }

    @Test("The report title and listing name ChargeInhibit for note 09's test")
    func chargeInhibitReport() {
        var scenario = Scenario()
        scenario.assertion = .chargeInhibit
        let text = report(scenario.run, listings: [
            .init(moment: "just after the release", time: 201.1, listing: AssertionListing()),
        ]).render()
        #expect(text.hasPrefix("CellKeeper ChargeInhibit probe report"))
        #expect(text.contains("name \"CellKeeper charge-inhibit probe\""))
        #expect(text.contains("did not list the probe's ChargeInhibit"))
    }
}
