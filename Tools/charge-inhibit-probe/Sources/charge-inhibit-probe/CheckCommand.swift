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
}
