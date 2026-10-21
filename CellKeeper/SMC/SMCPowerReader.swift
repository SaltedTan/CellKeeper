#if CELLKEEPER_SMC_READER
// PLACEHOLDER: the power flow's SMC reader (research note 13 §6.1, §6.6).
//
// This file is to be replaced by the owner's reader, with the same type
// name, `SMCPowerReader`, in this same file (note 13 §7 step 4). Until then
// it reads nothing: every call throws "unavailable", so a build with the
// switch on behaves as one without it, its SMC source backing off.
//
// Agents may not put SMC code here: no IOKit user-client call, no AppleSMC
// service matching, no SMC command bytes or selectors, no parameter-block
// layout (CONTRIBUTING §1, note 11 §2.2, note 13 §5). The owner writes the
// reader against the contract on `SMCPowerReading` in CellKeeperCore, and
// GPT and the lead review it against note 13 §6.1's acceptance list.
//
// The whole file is compiled only with `CELLKEEPER_SMC_READER = YES`
// (Config/Shared.xcconfig, Config/CellKeeper.xcconfig); with it off, no
// reader code is compiled or linked and the SMC source is absent.

import CellKeeperCore

/// The power flow's SMC reader. A placeholder: it reads nothing.
struct SMCPowerReader: SMCPowerReading {
    func read(_ keys: [SMCPowerKey]) throws -> [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>] {
        throw SMCOpenError.unavailable
    }
}
#endif
