// CellKeeperHelper: CellKeeper's helper daemon.
//
// In this phase it controls no hardware (UnknownHardwareChargeControl: no
// capabilities, nothing written), serves no clients (no listener exists
// yet), and is neither embedded in the app nor registered with launchd.
// See docs/architecture.md, "Helper daemon".

import CellKeeperHelperDaemon
import Foundation

let log = UnifiedHelperLog()
let daemon = HelperDaemon(environment: .system(frontend: NoFrontend(log: log), log: log))
let status = await daemon.run()
exit(status)
