import Foundation
import ProbeCore

/// `charge-inhibit-probe check --assertion …`: read-only; prints the
/// preconditions for that assertion's run. Exit status 0 if every
/// precondition holds, 1 if any fails.
enum CheckCommand {
    static func main(assertion: AssertionKind) -> Int32 {
        let machine = SystemReads.machineInfo()
        let names = SystemReads.namesToRedact()
        Console.out("CellKeeper \(assertion.type) probe: check (read-only; creates nothing)")
        Console.out("machine: \(machine.line)")
        Console.out("")

        let state = SystemReads.systemState(redacting: names)
        Console.out("Current reading")
        Console.out(ReportFormat.sampleHeader)
        Console.out(ReportFormat.sampleLine(state.reading))
        Console.out("")

        let checks = Preconditions.evaluate(state, assertion: assertion)
        Console.out("Preconditions")
        for check in checks {
            Console.out(check.line)
        }
        Console.out("")
        Console.out(Preconditions.summary(checks, assertion: assertion))
        return checks.contains { $0.status == .fail } ? 1 : 0
    }

    /// `charge-inhibit-probe check --mechanism manual-adapter-cut` (research
    /// note 11): read-only; prints the preconditions for `watch` and the
    /// owner's tool commands. It reads no SMC key, runs no tool, and makes
    /// no read the assertion checks do not make.
    static func mainManualCut() -> Int32 {
        let machine = SystemReads.machineInfo()
        let names = SystemReads.namesToRedact()
        Console.out("CellKeeper manual adapter-cut probe: check (read-only; creates nothing)")
        Console.out("machine: \(machine.line)")
        Console.out("This probe reads no SMC key and runs no tool: the owner reads and writes CHIE by hand,")
        Console.out("with the external tool, in another terminal (\(ManualCut.note)).")
        Console.out("")

        let state = SystemReads.systemState(redacting: names)
        Console.out("Current reading")
        Console.out(ReportFormat.sampleHeader)
        Console.out(ReportFormat.sampleLine(state.reading))
        Console.out("")

        let checks = Preconditions.evaluateManualCut(state)
        Console.out("Preconditions")
        for check in checks {
            Console.out(check.line)
        }
        Console.out("")
        Console.out("The owner's tool commands (run them yourself, in \(ManualCut.ToolCommand.directory); the probe never does)")
        Console.out("read:    \(ManualCut.ToolCommand.read)")
        Console.out("cut:     \(ManualCut.ToolCommand.cut)")
        Console.out("restore: \(ManualCut.ToolCommand.restore)")
        Console.out("")
        Console.out(Preconditions.manualCutSummary(checks))
        return checks.contains { $0.status == .fail } ? 1 : 0
    }
}
