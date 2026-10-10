// CellKeeperHelper: CellKeeper's helper daemon.
//
// In this phase it controls no hardware (UnknownHardwareChargeControl: no
// capabilities, nothing written) and is neither embedded in the app nor
// registered with launchd. It serves CellKeeper over the authenticated NSXPC
// transport only when signed with a team identifier; an ad-hoc or unsigned
// build refuses to listen and exits. See docs/architecture.md, "Helper
// daemon".

import CellKeeperHelperDaemon
import Foundation

let daemon = HelperDaemon(environment: .system(frontend: XPCFrontend()))
let status = await daemon.run()
exit(status)
