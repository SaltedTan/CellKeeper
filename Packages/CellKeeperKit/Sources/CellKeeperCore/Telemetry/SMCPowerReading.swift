import Foundation

/// The SMC keys the menu's power flow may ask for (research note 13 §3,
/// §6.1, D115), and no others. Their names, meanings, types and units are
/// third-party facts checked on the test Mac (note 13 §4), used under the
/// clean-room exception in CONTRIBUTING §1. Display only, like ``PowerFlow``.
public enum SMCPowerKey: String, Sendable, CaseIterable {
    /// `PDTR`, the adapter's input power: `flt `, 4 bytes, in watts.
    case adapterInputPower = "PDTR"
    /// `PSTR`, the Mac's total power: `flt `, 4 bytes, in watts.
    case systemTotalPower = "PSTR"
    /// `B0AP`, the battery's power: `si32`, 4 bytes, in milliwatts. Its sign
    /// is not yet known (note 13 O1), so it is asked for only once
    /// ``SMCPowerSampler/isBatteryPowerVerified`` says so.
    case batteryPower = "B0AP"

    /// The key's four characters packed into 32 bits, the first in the most
    /// significant byte, as Apple's `FourCharCode` packs them: `PDTR` is
    /// 0x5044_5452.
    public var fourCharacterCode: UInt32 {
        rawValue.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// A key's value as the reader got it, undecoded: its four-character type as
/// the SMC reports it (`flt `, `si32`) and its bytes, in the order read.
/// CellKeeper decodes it (``SMCPowerDecoding``); the reader never does.
public struct SMCRawValue: Sendable, Equatable {
    public var type: String
    public var bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) {
        self.type = type
        self.bytes = bytes
    }
}

/// Why one key of a read has no value; the other keys of the read may have
/// one.
public enum SMCKeyReadError: Error, Sendable, Equatable {
    /// The SMC has no such key.
    case notFound
    /// The key exists but reading it failed.
    case readFailed
}

/// Why a whole read failed: the SMC's user client could not be opened, so no
/// key was read.
public enum SMCOpenError: Error, Sendable, Equatable {
    /// Opening was refused, for example by the App Sandbox.
    case refused
    /// There is nothing to open, or the reader is the placeholder.
    case unavailable
}

/// The owner's reader of the SMC's power keys (research note 13 §6.1): the
/// one piece of CellKeeper that opens the SMC's user client. Agents never
/// write one; this protocol is CellKeeper's side of the contract, and the
/// app compiles a conformer only with its build switch on (note 13 §6.6).
///
/// The contract, which review checks against the owner's file:
/// - **Read-only.** For each key asked for, it asks for the key's
///   information and reads its bytes, nothing else: no write, no command
///   chosen by the caller, no enumeration of keys.
/// - **Its own allowlist.** It refuses any key not on its own list of the
///   three codes before it opens anything.
/// - **Nothing kept.** One call opens the user client, reads the keys in
///   order and closes it before returning, on every path; nothing is kept
///   between calls.
/// - **One call at a time.** CellKeeper never calls it twice at once, from
///   one dedicated thread (``SMCPowerCoordinator``); it must be safe to call
///   from any thread, one call at a time. It is synchronous and cannot be
///   cancelled: CellKeeper handles a call that hangs.
/// - **Nothing else.** No root, no helper, no logging of values, no
///   identifiers read.
public protocol SMCPowerReading: Sendable {
    /// Reads `keys`, in order, and returns for each its raw value or why it
    /// has none. Throws an ``SMCOpenError`` when the user client cannot be
    /// opened (refused, or unavailable): no key was read. A key missing from
    /// the result counts as not read.
    func read(_ keys: [SMCPowerKey]) throws -> [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>]
}

/// Turns the SMC's raw power values into watts (research note 13 §6.3): a
/// value with exactly its key's type and length, decoded little-endian,
/// finite and in range, or nothing. Never a guessed value: any other type,
/// length or value is refused.
public enum SMCPowerDecoding {
    /// The highest adapter input or Mac power accepted, as D114 bounds the
    /// registry's values.
    public static let maximumSystemWatts = 500.0
    /// The largest battery power accepted, either way, in milliwatts.
    public static let maximumBatteryMilliwatts = 300_000

    /// The type and length each key must have.
    static func expectedType(of key: SMCPowerKey) -> String {
        switch key {
        case .adapterInputPower, .systemTotalPower: "flt "
        case .batteryPower: "si32"
        }
    }

    /// Every key's value is 4 bytes long.
    static let expectedLength = 4

    /// `raw` read as `key`, in watts, or nil when it is not exactly what the
    /// key must be: `PDTR` and `PSTR` an IEEE-754 `flt ` of 4 bytes, finite
    /// and within 0–500 W; `B0AP` an `si32` of 4 bytes within ±300 000 mW,
    /// signed as the SMC reports it.
    public static func watts(_ raw: SMCRawValue, for key: SMCPowerKey) -> Double? {
        guard raw.type == expectedType(of: key), raw.bytes.count == expectedLength else { return nil }
        let bits = raw.bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        switch key {
        case .adapterInputPower, .systemTotalPower:
            let watts = Double(Float(bitPattern: bits))
            guard watts.isFinite, (0...maximumSystemWatts).contains(watts) else { return nil }
            return watts
        case .batteryPower:
            let milliwatts = Int(Int32(bitPattern: bits))
            guard (-maximumBatteryMilliwatts...maximumBatteryMilliwatts).contains(milliwatts) else { return nil }
            return Double(milliwatts) / 1000
        }
    }

    /// `key`'s value in `result`, in watts, or nil if it was not read, failed
    /// or is invalid.
    public static func watts(in result: [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>], for key: SMCPowerKey) -> Double? {
        guard case .success(let raw)? = result[key] else { return nil }
        return watts(raw, for: key)
    }
}
