import Foundation
import ProbeCore

// charge-inhibit-probe: see docs/research/11-smc-adapter-cut.md,
// docs/research/10-disable-inflow-probe.md and
// docs/research/09-charge-inhibit-probe.md. `check` reads only. `run`
// refuses unless it is root, and creates at most one private assertion
// (DisableInflow or ChargeInhibit, as the owner chooses), with a timeout,
// which it releases, and one public idle-sleep assertion for the run.
// `watch --mechanism manual-adapter-cut` refuses root, reads no SMC key and
// runs no tool: it observes the owner's manual adapter cut, holding only one
// public idle-sleep assertion for the run.

let arguments = CommandLine.arguments
let status: Int32
do {
    switch try Command.parse(Array(arguments.dropFirst())) {
    case let .check(assertion):
        status = CheckCommand.main(assertion: assertion)
    case let .run(assertion, hold):
        status = RunCommand.main(assertion: assertion, hold: hold, invokedAs: arguments.first ?? "charge-inhibit-probe")
    case .checkManualCut:
        status = CheckCommand.mainManualCut()
    case let .watchManualCut(hold):
        status = WatchCommand.main(hold: hold)
    case .help:
        Console.out(Command.usage)
        status = 0
    }
} catch {
    Console.error("charge-inhibit-probe: \(error)\n")
    Console.error(Command.usage)
    status = 64
}
exit(status)
