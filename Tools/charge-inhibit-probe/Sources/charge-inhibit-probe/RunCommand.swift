import Foundation
import ProbeCore

/// `sudo charge-inhibit-probe run [--hold SECONDS]`: the owner's test.
///
/// Order, and why:
/// 1. Refuse unless the effective user is root. Nothing else happens first.
/// 2. Re-check every precondition; refuse on any failure.
/// 3. Create the report file; refuse if it cannot be written.
/// 4. Install the signal handlers, so a stop during the baseline ends cleanly
///    and latches the holder against a later creation.
/// 5. Baseline: readings every 2 s for 20 s, timed from the baseline's own
///    start. Create no assertion unless the readings span 18–24 s with no
///    gap over 4 s and all show steady charging on AC power.
/// 6. Create the assertion; read every 2 s while it is held; release it
///    early if a reading shows the run cannot conclude (unplugged, full,
///    unreadable).
/// 7. Release it (retrying a failed release), confirm with
///    `pmset -g assertions` that it is gone, read for 60 s more (up to
///    2 minutes beyond that until charging has resumed for 5 readings in a
///    row), then write the report.
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

        // 4. Signals: latch the stop, release at once, then finish the report.
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

        @discardableResult
        func checkListing(_ moment: String) -> Bool? {
            let listing = SystemReads.assertionListing(redacting: names)
            let check = Report.ListingCheck(moment: moment, time: clock.now, listing: listing)
            listings.append(check)
            let text = check.listed.map { $0 ? "lists" : "does not list" } ?? "could not be run to check"
            Console.out("  \(moment): pmset -g assertions \(text) the probe's ChargeInhibit")
            return check.listed
        }

        // 5. Baseline, timed from its own start.
        Console.out("Baseline: \(ProbeSchedule.baseline) s of readings before the assertion. Ctrl-C stops at any time.")
        Console.out(ReportFormat.sampleHeader)
        let baselineStart = clock.now
        for step in 0...(ProbeSchedule.baseline / ProbeSchedule.interval) {
            guard clock.pause(until: baselineStart + Double(step) * interval, stop: stop) else { break }
            _ = read(.baseline)
        }

        var creation: ProbeRun.Creation?
        var release: ProbeRun.Release?
        let baselineProblem = Verdict.baselineProblem(samples)
        if stop.signal == nil, baselineProblem == nil, let result = holder.create(hold: hold) {
            // 6. Create and hold.
            let created = ProbeRun.Creation(time: clock.now, result: result, timeout: ProbeAssertion.timeout(hold: hold))
            creation = created
            Console.out("+\(seconds(created.time)): IOPMAssertionCreateWithProperties returned \(IOReturnName.describe(result))")
            if result == kIOReturnSuccess {
                Console.out("Holding ChargeInhibit for \(hold) s (powerd releases it by itself after \(created.timeout) s).")
                var step = 1
                var releasedEarly = false
                while stop.signal == nil, Double(step) * interval <= Double(hold) {
                    guard clock.pause(until: created.time + Double(step) * interval, stop: stop) else { break }
                    let sample = read(.held)
                    if step == 1 { checkListing("2 s after creation") }
                    if let problem = Verdict.problem(of: sample) {
                        notes.append("Released early, \(seconds(sample.time - created.time)) after creation, because \(problem); the run is inconclusive.")
                        Console.out("  \(problem): releasing now")
                        releasedEarly = true
                        break
                    }
                    step += 1
                }
                if stop.signal == nil, !releasedEarly { checkListing("just before the release") }

                // 7. Release, confirm, then watch charging resume.
                holder.release()
                if let record = holder.releaseRecord {
                    let attempts = record.attempts == 1 ? "" : " (after \(record.attempts) attempts)"
                    Console.out("+\(seconds(record.time)): IOPMAssertionRelease returned \(IOReturnName.describe(record.result))\(attempts)")
                    // Also after a stop signal: it confirms the release.
                    var stillListed = checkListing("just after the release")
                    if stillListed == true {
                        Thread.sleep(forTimeInterval: 1)
                        stillListed = checkListing("1 s after the release")
                    }
                    release = ProbeRun.Release(time: record.time, result: record.result, attempts: record.attempts, stillListed: stillListed)
                    if record.result != kIOReturnSuccess || stillListed != false {
                        notes.append("""
                            The release is not confirmed. powerd releases the assertion at its \
                            timeout (\(created.timeout) s after creation) and when the probe \
                            exits. After the probe has exited, run `pmset -g assertions`: it \
                            must list no ChargeInhibit. If it does, or if charging does not \
                            resume, follow docs/safety.md, "If charging does not resume".
                            """)
                    }
                    watchAfterRelease(
                        releasedAt: record.time,
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
        let run = ProbeRun(samples: samples, creation: creation, release: release)
        var verdict = Verdict.evaluate(run)
        if let signal = stop.signal {
            notes.append("Stopped by \(signalName(signal)) at +\(seconds(clock.now)); the probe released the assertion at once (if it held one).")
            if creation == nil {
                verdict = .inconclusive(reason: "the probe was stopped (\(signalName(signal))) before the assertion was created")
            }
        }
        if holder.isHeld {
            notes.append("The probe could not release the assertion itself; powerd releases it when the probe exits, which happens now.")
        }

        let report = Report(
            startedAt: startedAt,
            machine: machine,
            hold: hold,
            preconditionChecks: checks,
            run: run,
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
    /// charging has not resumed for `Criteria.sustainedReadings` readings in
    /// a row by then and `extend`, for up to `ProbeSchedule.lateResumeWatch`
    /// seconds more, stopping once it has.
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
        let needed = Criteria.standard.sustainedReadings
        var inARow = 0
        var announced = false
        var step = 1
        while stop.signal == nil {
            let offset = Double(step) * interval
            if offset > limit || (offset > window && inARow >= needed) { break }
            if offset > window, !announced {
                Console.out("Charging has not yet resumed for \(needed) readings in a row. Watching up to \(Int(limit - window)) s more; Ctrl-C stops.")
                announced = true
            }
            guard clock.pause(until: releasedAt + offset, stop: stop) else { break }
            let sample = read(.after)
            if Verdict.problem(of: sample) == nil, Verdict.state(of: sample) == .charging {
                inARow += 1
            } else if inARow < needed {
                inARow = 0
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

    /// SIGINT, SIGTERM and SIGHUP latch the stop (no assertion can be
    /// created after it), release the assertion at once, and ask the run to
    /// finish; a second signal exits immediately (powerd releases on exit in
    /// any case).
    static func installSignalHandlers(holder: AssertionHolder, stop: StopRequest) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "charge-inhibit-probe.signals")
        return [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                holder.cancel()
                if stop.record(number) {
                    Console.error("\n\(signalName(number)): stopping. No assertion will be created, and any the probe holds is released. Finishing the report; press Ctrl-C again to quit at once.")
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
