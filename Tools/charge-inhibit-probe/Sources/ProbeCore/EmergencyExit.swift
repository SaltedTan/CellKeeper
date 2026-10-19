import Foundation

/// The last resort when the release fails on a sleep notification
/// (research note 10 §4): arm an exit deadline that needs no lock, queue or
/// output, record one line in the report file, and exit. Nothing goes to
/// the console, and no descriptor's flags are changed: the console's pipe
/// or terminal is shared with the main thread and the shell. Each step is a
/// closure, so the tests drive the order with fakes; ``writeReport(_:to:)``
/// is the real writer.
public enum EmergencyExit {
    /// Seconds until the deadline ends the process (SIGALRM's default
    /// action, set with `alarm(2)`), whatever the report write does.
    public static let deadline: UInt32 = 2

    public struct Steps {
        public var armDeadline: () -> Void
        public var writeReport: (String) -> Void
        public var exit: (Int32) -> Void

        public init(
            armDeadline: @escaping () -> Void,
            writeReport: @escaping (String) -> Void,
            exit: @escaping (Int32) -> Void
        ) {
            self.armDeadline = armDeadline
            self.writeReport = writeReport
            self.exit = exit
        }
    }

    /// The deadline first, then the report line, then the exit. In the
    /// probe, `exit` does not return.
    public static func perform(_ line: String, status: Int32, steps: Steps) {
        steps.armDeadline()
        steps.writeReport(line)
        steps.exit(status)
    }

    /// One `write(2)` of `text`, between newlines, to `descriptor`: the
    /// report file, already open with `O_APPEND`. A regular file does not
    /// wait for a reader; on the emergency path, the deadline covers a disk
    /// that hangs. Returns `write`'s result, -1 for a file that could not be
    /// opened.
    @discardableResult
    public static func writeReport(_ text: String, to descriptor: Int32) -> Int {
        guard descriptor >= 0 else { return -1 }
        let bytes = Array(("\n" + text + "\n").utf8)
        return bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }
}

/// How the console and the report describe the private assertion's
/// release: "released" only when it is confirmed, by the IOReturn and,
/// where the probe checks it, by `pmset -g assertions` no longer listing
/// it.
public enum ReleaseWording {
    /// "release attempted (3 tries) and failed (0xe00002f0 (kIOReturnNotFound)) —
    /// powerd releases it at its timeout or when the probe exits".
    public static func failed(attempts: Int, result: Int32) -> String {
        """
        release attempted (\(attempts) \(attempts == 1 ? "try" : "tries")) and failed \
        (\(IOReturnName.describe(result))) — powerd releases it at its timeout or when \
        the probe exits
        """
    }

    /// The console line after a stop signal.
    public static func signalLine(_ signal: String, outcome: ReleaseOutcome, assertion: AssertionKind) -> String {
        let held: String
        switch outcome {
        case .released: held = "the probe released its \(assertion.type) assertion"
        case .nothingHeld: held = "the probe held no \(assertion.type) assertion"
        case let .failed(result, attempts):
            held = "for its \(assertion.type) assertion, \(failed(attempts: attempts, result: result)); the probe tries again as it finishes"
        }
        return """
            \(signal): stopping. No assertion will be created, and \(held). Finishing the \
            report; press Ctrl-C again to quit at once.
            """
    }

    /// The report's note for a run that stopped early (`reason`, at `time`
    /// run seconds), from the final release record and whether the probe
    /// still holds the assertion.
    public static func stopNote(_ reason: String, at time: Double, release: ProbeRun.Release?, stillHeld: Bool, assertion: AssertionKind) -> String {
        let type = assertion.type
        let state: String
        if let release, stillHeld || release.result != 0 {
            state = "for the \(type) assertion, \(failed(attempts: release.attempts, result: release.result)). Follow the recovery steps"
        } else if stillHeld {
            state = "the probe still holds its \(type) assertion — powerd releases it at its timeout or when the probe exits. Follow the recovery steps"
        } else if let release {
            switch release.stillListed {
            case false?:
                state = "the probe released its \(type) assertion, and pmset -g assertions no longer listed it"
            case true?:
                state = """
                    IOPMAssertionRelease returned \(IOReturnName.describe(release.result)), but pmset -g \
                    assertions still listed the \(type) assertion — powerd releases it at its timeout \
                    or when the probe exits. Follow the recovery steps
                    """
            case nil:
                state = """
                    IOPMAssertionRelease returned \(IOReturnName.describe(release.result)), but pmset -g \
                    assertions could not be run to confirm it — powerd releases the \(type) assertion \
                    at its timeout or when the probe exits. Follow the recovery steps
                    """
            }
        } else {
            state = "no \(type) assertion was held"
        }
        return "Stopped by \(reason) at +\(seconds(time)); \(state)."
    }
}
