import Foundation
import ProbeCore

/// `charge-inhibit-probe check`: read-only; prints the preconditions.
/// Exit status 0 if every precondition holds, 1 if any fails.
enum CheckCommand {
    static func main() -> Int32 {
        let machine = SystemReads.machineInfo()
        let names = SystemReads.namesToRedact()
        Console.out("CellKeeper ChargeInhibit probe: check (read-only; creates nothing)")
        Console.out("machine: \(machine.line)")
        Console.out("")

        let state = SystemReads.systemState(redacting: names)
        Console.out("Current reading")
        Console.out(ReportFormat.sampleHeader)
        Console.out(ReportFormat.sampleLine(state.reading))
        Console.out("")

        let checks = Preconditions.evaluate(state)
        Console.out("Preconditions")
        for check in checks {
            Console.out(check.line)
        }
        Console.out("")
        Console.out(Preconditions.summary(checks))
        return checks.contains { $0.status == .fail } ? 1 : 0
    }
}
