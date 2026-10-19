import Foundation
import ProbeCore

/// `sudo charge-inhibit-probe run --assertion … [--hold SECONDS]`: the
/// owner's test.
///
/// Order, and why:
/// 1. Refuse unless the effective user is root. Nothing else happens first.
/// 2. Re-check every precondition; refuse on any failure.
/// 3. Create the report file; refuse if it cannot be written.
/// 4. Install the signal handlers, so a stop during the baseline ends cleanly
///    and latches the holder against a later creation. Register for system
///    sleep notifications and create the public idle-sleep assertion; refuse
///    if either fails, before any private assertion exists.
/// 5. Baseline: readings every 2 s, timed from the baseline's own start, for
///    at least 20 s and until they show 2 battery updates, at most 150 s.
///    Create no assertion unless the readings span 18–152 s with no gap
///    over 4 s, all show steady charging on AC power, and show 2 updates.
/// 6. Create the assertion, unless the last baseline reading is more than
///    4 s old, or the baseline's latest battery update more than 70 s old,
///    at that moment (checked under the holder's lock, immediately before
///    the call); read every 2 s while it is held; release it early if a
///    reading shows the run cannot conclude (unreadable, full, a charge
///    below the floor, a stale battery update) or the system announces
///    sleep.
/// 7. Release it (retrying a failed release), confirm with
///    `pmset -g assertions` that it is gone, read for 180 s more (up to
///    2 minutes beyond that until charging has resumed steadily), then
///    release the idle-sleep assertion, deregister from sleep notifications
///    and write the report.
///
/// Readings never catch up: when a deadline has passed, the probe takes one
/// reading and schedules the next an interval later
/// (`ProbeSchedule.nextDeadline`), so readings are at least 1.5 s apart.
enum RunCommand {
    static func main(assertion kind: AssertionKind, hold: Int, invokedAs program: String) -> Int32 {
        // 1. Root only. This check comes before anything else in the run.
        guard geteuid() == 0 else {
            Console.error("""
                charge-inhibit-probe run must be started by the owner with sudo:
                    sudo \(program) run --assertion \(kind.rawValue)
                It refused before creating anything. `\(program) check --assertion \
                \(kind.rawValue)` needs no privileges.
                """)
            return 1
        }

        let clock = Clock()
        let startedAt = Clock.wallDateTime()
        let machine = SystemReads.machineInfo()
        let names = SystemReads.namesToRedact()
        Console.out("CellKeeper \(kind.type) probe: run (hold \(hold) s)")
        Console.out("machine: \(machine.line)")
        Console.out("")

        // 2. Preconditions.
        let checks = Preconditions.evaluate(SystemReads.systemState(redacting: names), assertion: kind)
        Console.out("Preconditions")
        for check in checks {
            Console.out(check.line)
        }
        Console.out("")
        guard !checks.contains(where: { $0.status == .fail }) else {
            Console.out(Preconditions.summary(checks, assertion: kind))
            Console.out("Refusing to run: fix the failed preconditions, then run `charge-inhibit-probe check --assertion \(kind.rawValue)` again. Nothing was created.")
            return 1
        }

        // 3. The report file, in the current directory.
        let fileName = kind.reportFileName(stamp: Clock.fileStamp())
        let placeholder = "CellKeeper \(kind.type) probe report: run started \(startedAt), still in progress or stopped before it finished.\n"
        guard FileManager.default.createFile(atPath: fileName, contents: Data(placeholder.utf8)) else {
            Console.error("Refusing to run: cannot write \(fileName) in the current directory. Nothing was created.")
            return 1
        }
        giveToInvokingUser(fileName)

        // 4. Signals: latch the stop, release at once, then finish the
        // report. Sleep: the same, before the system is allowed to sleep.
        let holder = AssertionHolder(clock: clock, kind: kind)
        let idleSleep = IdleSleepAssertion()
        let sleepWatch = SleepWatch(clock: clock)
        let stop = StopRequest()
        let signalSources = installSignalHandlers(holder: holder, stop: stop)
        // Cleanup on every path, in this order: the private assertion, the
        // idle-sleep assertion, the sleep notifications.
        defer {
            holder.release()
            idleSleep.release()
            sleepWatch.stop()
            signalSources.forEach { $0.cancel() }
        }

        var samples: [Sample] = []
        var notes: [String] = []
        var listings: [Report.ListingCheck] = []
        let registered = sleepWatch.start(onWillSleep: { message in
            // On the notification queue, before the system may sleep.
            stop.record(.sleep(message))
            holder.cancel()
            Console.error("\n\(message): released the assertion before allowing sleep; the run is inconclusive.")
        })
        var sleepGuard = Report.SleepGuard(registered: registered)

        func writeReport(run: ProbeRun?, verdict: Verdict?) {
            let report = Report(
                assertion: kind,
                startedAt: startedAt,
                machine: machine,
                hold: hold,
                preconditionChecks: checks,
                run: run,
                listings: listings,
                sleepGuard: sleepGuard,
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
        }

        var refusal: String?
        if !sleepGuard.registered {
            refusal = "IORegisterForSystemPower did not register the probe for sleep notifications"
        } else {
            let result = idleSleep.create(hold: hold)
            sleepGuard.created = (clock.now, result)
            Console.out("+\(seconds(clock.now)): IOPMAssertionCreateWithProperties (PreventUserIdleSystemSleep) returned \(IOReturnName.describe(result))")
            if result != kIOReturnSuccess {
                refusal = "creating the PreventUserIdleSystemSleep assertion returned \(IOReturnName.describe(result))"
            }
        }
        if let refusal {
            sleepWatch.stop()
            notes.append("Refused to run: \(refusal). No \(kind.type) assertion was created.")
            Console.out("Refusing to run: \(refusal). No \(kind.type) assertion was created.")
            writeReport(run: nil, verdict: nil)
            return 1
        }

        func read(_ phase: Sample.Phase) -> Sample {
            let sample = SystemReads.sample(time: clock.now, unixTime: Clock.unixNow, phase: phase)
            samples.append(sample)
            Console.out(ReportFormat.sampleLine(sample))
            return sample
        }

        @discardableResult
        func checkListing(_ moment: String) -> Bool? {
            let listing = SystemReads.assertionListing(redacting: names)
            let check = Report.ListingCheck(moment: moment, time: clock.now, listing: listing)
            listings.append(check)
            let text = check.listed(kind).map { $0 ? "lists" : "does not list" } ?? "could not be run to check"
            Console.out("  \(moment): pmset -g assertions \(text) the probe's \(kind.type)")
            return check.listed(kind)
        }

        // 5. Baseline, timed from its own start, until it shows 2 battery
        // updates. Readings never catch up: an overdue one is taken once,
        // and the next is due an interval later.
        Console.out("""
            Baseline: at least \(ProbeSchedule.baseline) s of readings, until they show 2 battery updates \
            (at most \(ProbeSchedule.baselineLimit) s). Ctrl-C stops at any time.
            """)
        Console.out(ReportFormat.sampleHeader)
        let baselineStart = clock.now
        var deadline = baselineStart
        var baseline: [Sample] = []
        while deadline <= baselineStart + Double(ProbeSchedule.baselineLimit) + 0.001 {
            guard clock.pause(until: deadline, stop: stop) else { break }
            let sample = read(.baseline)
            baseline.append(sample)
            // A reading that is not steady charging fails the baseline:
            // nothing will be created, so there is no point waiting.
            if !Verdict.isChargingOnAdapter(sample) { break }
            if Verdict.baselineReady(baseline, minimumSpan: Double(ProbeSchedule.baseline) - ProbeSchedule.lateness) { break }
            deadline = ProbeSchedule.nextDeadline(after: deadline, readAt: sample.time)
        }

        var creation: ProbeRun.Creation?
        var release: ProbeRun.Release?
        var notCreated: String?
        let baselineProblem = Verdict.baselineProblem(baseline)
        if stop.reason == nil, baselineProblem == nil {
            // 6. Create, unless the baseline is stale by now, and hold.
            let outcome = holder.create(hold: hold) {
                Verdict.baselineFreshnessProblem(baseline, at: clock.now, unixTime: Clock.unixNow)
            }
            switch outcome {
            case let .notAttempted(reason):
                notCreated = reason
                Console.out("No assertion was created: \(reason).")
            case let .attempted(result, time, unixTime):
                let created = ProbeRun.Creation(time: time, unixTime: unixTime, result: result, timeout: ProbeAssertion.timeout(hold: hold))
                creation = created
                Console.out("+\(seconds(created.time)): IOPMAssertionCreateWithProperties (\(kind.type)) returned \(IOReturnName.describe(result))")
                if result == kIOReturnSuccess {
                    release = holdAndRelease(
                        kind: kind, created: created, hold: hold, holder: holder, clock: clock, stop: stop,
                        read: read, checkListing: checkListing, notes: &notes
                    )
                }
            }
        } else if let baselineProblem, stop.reason == nil {
            Console.out("No assertion was created: \(baselineProblem).")
        }

        // Cleanup, in order: the private assertion, the idle-sleep
        // assertion, the sleep notifications.
        holder.release()
        if let result = idleSleep.release() {
            sleepGuard.released = (clock.now, result)
        }
        sleepWatch.stop()

        let run = ProbeRun(assertion: kind, samples: samples, creation: creation, release: release, sleepNotices: sleepWatch.notices)
        var verdict = Verdict.evaluate(run)
        if creation == nil, let notCreated {
            verdict = .inconclusive(reason: notCreated)
        }
        if let reason = stop.reason {
            notes.append("Stopped by \(reason) at +\(seconds(clock.now)); the probe released the assertion at once (if it held one).")
            if creation == nil {
                verdict = .inconclusive(reason: "the probe was stopped (\(reason)) before the assertion was created")
            }
        }
        if holder.isHeld {
            notes.append("The probe could not release the assertion itself; powerd releases it when the probe exits, which happens now.")
        }
        writeReport(run: run, verdict: verdict)
        return verdict.exitStatus
    }

    /// Reads every 2 s while the assertion is held (never catching up),
    /// releases it early if a reading shows the run cannot conclude,
    /// releases it at the end of the hold, confirms the release with
    /// `pmset -g assertions`, and watches charging resume. Returns the
    /// release as the verdict needs it, or nil if none was attempted.
    static func holdAndRelease(
        kind: AssertionKind,
        created: ProbeRun.Creation,
        hold: Int,
        holder: AssertionHolder,
        clock: Clock,
        stop: StopRequest,
        read: (Sample.Phase) -> Sample,
        checkListing: (String) -> Bool?,
        notes: inout [String]
    ) -> ProbeRun.Release? {
        Console.out("Holding \(kind.type) for \(hold) s (powerd releases it by itself after \(created.timeout) s).")
        let end = created.time + Double(hold)
        var deadline = created.time + Double(ProbeSchedule.interval)
        var first = true
        var releasedEarly = false
        var discharged = false
        while stop.reason == nil, deadline <= end + 0.001 {
            guard clock.pause(until: deadline, stop: stop) else { break }
            let sample = read(.held)
            deadline = ProbeSchedule.nextDeadline(after: deadline, readAt: sample.time)
            if first {
                _ = checkListing("2 s after creation")
                first = false
            }
            if let problem = Verdict.holdProblem(of: sample) {
                notes.append("Released early, \(seconds(sample.time - created.time)) after creation, because \(problem); the run is inconclusive.")
                Console.out("  \(problem): releasing now")
                releasedEarly = true
                break
            }
            if Verdict.state(of: sample) == .discharging { discharged = true }
        }
        if stop.reason == nil, !releasedEarly {
            // A rescheduled reading can move the last deadline past `end`:
            // the hold still lasts the full requested time.
            _ = clock.pause(until: end, stop: stop)
        }
        if stop.reason == nil, !releasedEarly { _ = checkListing("just before the release") }

        // 7. Release, confirm, then watch charging resume.
        holder.release()
        guard let record = holder.releaseRecord else { return nil }
        let attempts = record.attempts == 1 ? "" : " (after \(record.attempts) attempts)"
        Console.out("+\(seconds(record.time)): IOPMAssertionRelease (\(kind.type)) returned \(IOReturnName.describe(record.result))\(attempts)")
        // Also after a stop: it confirms the release.
        var stillListed = checkListing("just after the release")
        if stillListed == true {
            Thread.sleep(forTimeInterval: 1)
            stillListed = checkListing("1 s after the release")
        }
        if record.result != kIOReturnSuccess || stillListed != false {
            notes.append("""
                The release is not confirmed. powerd releases the assertion at its \
                timeout (\(created.timeout) s after creation) and when the probe \
                exits. After the probe has exited, run `pmset -g assertions`: it \
                must list no \(kind.type). If it does, or if charging does not \
                resume, follow docs/safety.md, "If charging does not resume".
                """)
        }
        watchAfterRelease(
            releasedAt: record.time, releasedAtUnix: record.unixTime, batteryAllowed: discharged,
            extend: !releasedEarly, clock: clock, stop: stop, read: read
        )
        return ProbeRun.Release(
            time: record.time, unixTime: record.unixTime, result: record.result,
            attempts: record.attempts, stillListed: stillListed
        )
    }

    /// Reads every 2 s (never catching up) for `ProbeSchedule.after` seconds
    /// after the release and, if `extend` and the verdict's own resume
    /// analysis (`Verdict.analyzeResume`) is still pending by then, for up to
    /// `ProbeSchedule.lateResumeWatch` seconds more, stopping once it is not.
    static func watchAfterRelease(
        releasedAt: Double,
        releasedAtUnix: Double,
        batteryAllowed: Bool,
        extend: Bool,
        clock: Clock,
        stop: StopRequest,
        read: (Sample.Phase) -> Sample
    ) {
        let window = releasedAt + Double(ProbeSchedule.after)
        let limit = window + (extend ? Double(ProbeSchedule.lateResumeWatch) : 0)
        var after: [Sample] = []
        var deadline = releasedAt + Double(ProbeSchedule.interval)
        var announced = false
        while stop.reason == nil, deadline <= limit + 0.001 {
            if deadline > window + 0.001 {
                guard case .pending = Verdict.analyzeResume(after, releasedAt: releasedAtUnix, batteryAllowed: batteryAllowed) else { break }
                if !announced {
                    Console.out("Charging has not yet resumed steadily. Watching up to \(ProbeSchedule.lateResumeWatch) s more; Ctrl-C stops.")
                    announced = true
                }
            }
            guard clock.pause(until: deadline, stop: stop) else { break }
            let sample = read(.after)
            after.append(sample)
            deadline = ProbeSchedule.nextDeadline(after: deadline, readAt: sample.time)
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
    /// created after it), release the private assertion at once, and ask the
    /// run to finish; a second signal exits immediately (powerd releases
    /// both assertions on exit in any case).
    static func installSignalHandlers(holder: AssertionHolder, stop: StopRequest) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "charge-inhibit-probe.signals")
        return [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                holder.cancel()
                if stop.recordSignal(number) {
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
