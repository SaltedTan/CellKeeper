/// Names for the IOReturn values the probe may see, from the public SDK
/// header `IOKit/IOReturn.h` (`iokit_common_err(x)` is `0xE0000000 | x`).
/// Swift does not import those function-like macros, so they are spelled
/// out here.
public enum IOReturnName {
    static let names: [UInt32: String] = [
        0x0000_0000: "kIOReturnSuccess",
        0xE000_02BC: "kIOReturnError",
        0xE000_02BD: "kIOReturnNoMemory",
        0xE000_02BE: "kIOReturnNoResources",
        0xE000_02C1: "kIOReturnNotPrivileged",
        0xE000_02C2: "kIOReturnBadArgument",
        0xE000_02C7: "kIOReturnUnsupported",
        0xE000_02C9: "kIOReturnInternalError",
        0xE000_02D5: "kIOReturnBusy",
        0xE000_02D6: "kIOReturnTimeout",
        0xE000_02D8: "kIOReturnNotReady",
        0xE000_02E2: "kIOReturnNotPermitted",
        0xE000_02F0: "kIOReturnNotFound",
    ]

    /// "0xe00002c1 (kIOReturnNotPrivileged)", or the hex value alone for a
    /// code without a name here.
    public static func describe(_ value: Int32) -> String {
        let bits = UInt32(bitPattern: value)
        let hex = "0x" + String(bits, radix: 16)
        guard let name = names[bits] else { return hex }
        return "\(hex) (\(name))"
    }
}
