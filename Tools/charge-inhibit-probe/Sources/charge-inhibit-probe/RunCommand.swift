import Foundation
import ProbeCore

/// `sudo charge-inhibit-probe run [--hold SECONDS]`: the owner's test.
///
/// Order, and why:
/// 1. Refuse unless the effective user is root. Nothing else happens first.
/// 2. Re-check every precondition; refuse on any failure.
/// 3. Create the report file; refuse if it cannot be written.
/// 4. Install the signal handlers, so a stop during the baseline ends cleanly.
/// 5. Baseline: 20 s of readings. Create no assertion unless it shows steady
///    charging on AC power.
/// 6. Create the assertion; read every 2 s while it is held; release it
///    early if a reading shows the run cannot conclude (unplugged, full,
///    unreadable).
/// 7. Release it, read for 60 s more (up to 2 minutes beyond that if
///    charging has not resumed), then write the report.
enum RunCommand {
    static func main(hold: Int, invokedAs program: String) -> Int32 {
        // 1. Root only. This check comes before anything else in the run.
        guard geteuid() == 0 else {
            Console.error("""
                charge-inhibit-probe run must be started by the owner with sudo:
                    sudo \(program) run
                It refused before creating anything. `\(program) check` needs no \
                privileges.
                """)
            return 1
        }

        let clock = Clock()
        let startedAt = Clock.wallDateTime()
        let machine = SystemReads.machineInfo()
        let names = SystemReads.namesToRedact()
        Console.out("CellKeeper ChargeInhibit probe: run (hold \(hold) s)")
        Console.out("machine: \(machine.line)")
        Console.out("")

        // 2. Preconditions.
        let checks = Preconditions.evaluate(SystemReads.systemState(redacting: names))
        Console.out("Preconditions")
        for check in checks {
            Console.out(check.line)
        }
        Console.out("")
        guard !checks.contains(where: { $0.status == .fail }) else {
            Console.out(Preconditions.summary(checks))
            Console.out("Refusing to run: fix the failed preconditions, then run `charge-inhibit-probe check` again. Nothing was created.")
            return 1
        }

        // 3. The report file, in the current directory.
        let fileName = "charge-inhibit-probe-\(Clock.fileStamp()).txt"
        let placeholder = "CellKeeper ChargeInhibit probe report: run started \(startedAt), still in progress or stopped before it finished.\n"
        guard FileManager.default.createFile(atPath: fileName, contents: Data(placeholder.utf8)) else {
            Console.error("Refusing to run: cannot write \(fileName) in the current directory. Nothing was created.")
            return 1
        }
        giveToInvokingUser(fileName)

        // 4. Signals: release at once, then let the run finish its report.
        let holder = AssertionHolder(clock: clock)
        let stop = StopRequest()
        let signalSources = installSignalHandlers(holder: holder, stop: stop)
        defer {
            holder.release()
            signalSources.forEach { $0.cancel() }
        }

        var samples: [Sample] = []
        var notes: [String] = []
        var listings: [Report.ListingCheck] = []
        let interval = Double(ProbeSchedule.interval)

        func read(_ phase: Sample.Phase) -> Sample {
            let sample = SystemReads.sample(time: clock.now, phase: phase)
            samples.append(sample)
            Console.out(ReportFormat.sampleLine(sample))
            return sample
        }

        func checkListing(_ moment: String) {
            let output = Pmset.run(["-g", "assertions"])
            let listing = output.map { AssertionListing.parse($0, redacting: names) }
            let listed = listing.map { $0.lists(named: ProbeAssertion.name) }
            listings.append(Report.ListingCheck(moment: moment, time: clock.now, listed: listed, lines: listing?.lines ?? []))
            let text = listed.map { $0 ? "lists" : "does not list" } ?? "could not be run to check"
            Console.out("  \(moment): pmset -g assertions \(text) the probe's ChargeInhibit")
        }

        // 5. Baseline.
        Console.out("Baseline: \(ProbeSchedule.baseline) s of readings before the assertion. Ctrl-C stops at any time.")
        Console.out(ReportFormat.sampleHeader)
        for step in 0...(ProbeSchedule.baseline / ProbeSchedule.interval) {
            guard clock.pause(until: Double(step) * interval, stop: stop) else { break }
            _ = read(.baseline)
        }

        var creation: ProbeRun.Creation?
        let baselineProblem = Verdict.baselineProblem(samples)
        if stop.signal == nil, baselineProblem == nil {
            // 6. Create and hold.
            let result = holder.create(hold: hold)
            let created = ProbeRun.Creation(time: clock.now, result: result)
            creation = created
            Console.out("+\(seconds(created.time)): IOPMAssertionCreateWithProperties returned \(IOReturnName.describe(result))")
            if result == kIOReturnSuccess {
                Console.out("Holding ChargeInhibit for \(hold) s (powerd releases it by itself after \(ProbeAssertion.timeout(hold: hold)) s).")
                var step = 1
                while stop.signal == nil, Double(step) * interval <= Double(hold) {
                    guard clock.pause(until: created.time + Double(step) * interval, stop: stop) else { break }
                    let sample = read(.held)
                    if step == 1 { checkListing("2 s after creation") }
                    if let problem = Verdict.problem(of: sample) {
                        notes.append("Released early, \(seconds(sample.time - created.time)) after creation, because \(problem); the run is inconclusive.")
                        Console.out("  \(problem): releasing now")
                        break
                    }
                    step += 1
                }
                let releasedEarly = !notes.isEmpty
                if stop.signal == nil, !releasedEarly { checkListing("just before the release") }

                // 7. Release, then watch charging resume.
                holder.release()
                if let releasedAt = holder.releasedAt {
                    let result = holder.releaseResult.map(IOReturnName.describe) ?? "?"
                    Console.out("+\(seconds(releasedAt)): IOPMAssertionRelease returned \(result)")
                    if let code = holder.releaseResult, code != kIOReturnSuccess {
                        notes.append("""
                            IOPMAssertionRelease returned \(IOReturnName.describe(code)). powerd \
                            releases the assertion at its timeout (\(ProbeAssertion.timeout(hold: hold)) s after creation) \
                            and when the probe exits.
                            """)
                    }
                    // Also after a stop signal: it confirms the release.
                    checkListing("just after the release")
                    watchAfterRelease(
                        releasedAt: releasedAt,
                        extend: !releasedEarly,
                        clock: clock,
                        stop: stop,
                        read: read
                    )
                }
            }
        } else if let baselineProblem, stop.signal == nil {
            Console.out("No assertion was created: \(baselineProblem).")
        }

        holder.release()
        let run = ProbeRun(samples: samples, creation: creation, releasedAt: holder.releasedAt)
        var verdict = Verdict.evaluate(run)
        if let signal = stop.signal {
            notes.append("Stopped by \(signalName(signal)) at +\(seconds(clock.now)); the probe released the assertion at once (if it held one).")
            if creation == nil {
                verdict = .inconclusive(reason: "the probe was stopped (\(signalName(signal))) before the assertion was created")
            }
        }

        let report = Report(
            startedAt: startedAt,
            machine: machine,
            hold: hold,
            preconditionChecks: checks,
            run: run,
            releaseResult: holder.releaseResult,
            listings: listings,
            verdict: verdict,
            notes: notes
        )
        let text = report.render()
        Console.out("")
        Console.out(text)
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: fileName))
            Console.out("Report written to ./\(fileName). Please send it to the lead.")
        } catch {
            Console.error("Could not write ./\(fileName): \(error.localizedDescription). Copy the report above instead.")
        }
        return verdict.exitStatus
    }

    /// Reads for `ProbeSchedule.after` seconds after the release and, if
    /// charging has not resumed by then and `extend`, for up to
    /// `ProbeSchedule.lateResumeWatch` seconds more, stopping at the first
    /// reading that shows charging.
    static func watchAfterRelease(
        releasedAt: Double,
        extend: Bool,
        clock: Clock,
        stop: StopRequest,
        read: (Sample.Phase) -> Sample
    ) {
        let interval = Double(ProbeSchedule.interval)
        let window = Double(ProbeSchedule.after)
        let limit = window + (extend ? Double(ProbeSchedule.lateResumeWatch) : 0)
        var resumed = false
        var announced = false
        var step = 1
        while stop.signal == nil {
            let offset = Double(step) * interval
            if offset > limit || (offset > window && resumed) { break }
            if offset > window, !announced {
                Console.out("Charging has not resumed \(ProbeSchedule.after) s after the release. Watching up to \(ProbeSchedule.lateResumeWatch) s more; Ctrl-C stops.")
                announced = true
            }
            guard clock.pause(until: releasedAt + offset, stop: stop) else { break }
            let sample = read(.after)
            if Verdict.problem(of: sample) == nil, Verdict.state(of: sample) == .charging {
                resumed = true
            }
            step += 1
        }
    }

    /// Hands the report file to the user who ran sudo, so they can move or
    /// delete it without sudo. Best effort.
    static func giveToInvokingUser(_ fileName: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let uid = environment["SUDO_UID"].flatMap(uid_t.init),
              let gid = environment["SUDO_GID"].flatMap(gid_t.init)
        else { return }
        _ = chown(fileName, uid, gid)
    }

    /// SIGINT, SIGTERM and SIGHUP release the assertion at once and ask the
    /// run to finish; a second signal exits immediately (powerd releases on
    /// exit in any case).
    static func installSignalHandlers(holder: AssertionHolder, stop: StopRequest) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "charge-inhibit-probe.signals")
        return [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                holder.release()
                if stop.record(number) {
                    Console.error("\n\(signalName(number)): the assertion is released; finishing the report. Press Ctrl-C again to quit at once.")
                } else {
                    Console.error("\n\(signalName(number)) again: quitting.")
                    exit(128 + number)
                }
            }
            source.resume()
            return source
        }
    }
}
