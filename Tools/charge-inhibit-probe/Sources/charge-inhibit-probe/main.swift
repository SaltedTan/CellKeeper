import Foundation
import ProbeCore

// charge-inhibit-probe: see docs/research/09-charge-inhibit-probe.md.
// `check` reads only. `run` refuses unless it is root, and creates at most
// one ChargeInhibit assertion, with a timeout, which it releases.

let arguments = CommandLine.arguments
let status: Int32
do {
    switch try Command.parse(Array(arguments.dropFirst())) {
    case .check:
        status = CheckCommand.main()
    case let .run(hold):
        status = RunCommand.main(hold: hold, invokedAs: arguments.first ?? "charge-inhibit-probe")
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
