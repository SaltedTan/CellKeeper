#if CELLKEEPER_SMC_READER

// SMCPowerReader.swift
// CellKeeper — opt-in, read-only AppleSMC power-key reader.
// Implements SMCPowerReading in CellKeeperCore (research note 13 §6.1, §6.6).
//
// Written by the project's owner (SaltedTan), 2026-10-24, from Apple's
// public IOKit documentation and the AppleSMC interface facts in
// docs/research/11-smc-adapter-cut.md §3.2.
//
// Wire-level facts only (the open type, the selector, the command and result
// values, and the parameter block's size, field sizes and offsets) were
// checked against beltex/SMCKit, https://github.com/beltex/SMCKit (MIT), and
// are used as facts under CONTRIBUTING §1. No code, comments or structure was
// taken from SMCKit or any other project.
//
// Claude, CellKeeper's lead agent, gave general Swift syntax help with generic
// examples that the owner used here (the allowlist set, the type-string
// conversion, the per-key result loop, copying bytes out of a tuple). It gave
// no SMC interface details and wrote none of the IOKit calls, constants or the
// parameter block. It drafted this header at the owner's request.
//
// AppleSMC is a private, undocumented interface. This reader performs only
// key-info and key-read operations; it never enumerates or writes SMC keys.

import CellKeeperCore
import IOKit

struct SMCPowerReader: SMCPowerReading {
    // No stored properties: Sendable conformance is synthesized. The caller
    // serializes calls on its dedicated thread; this file keeps no connection.
    // These codes are sent verbatim; there is no caller-controlled command,
    // arbitrary-key probing, or conversion from a user-supplied string.
    private static let allowedCodes: Set<UInt32> = [
        0x5044_5452, // PDTR: input power
        0x5053_5452, // PSTR: system power
        0x4230_4150, // B0AP
    ]

    private static let serviceName = "AppleSMC"
    private static let userClientOpenType: UInt32 = 0
    private static let handleYPCEventSelector: UInt32 = 2
    private static let readKeyCommand: UInt8 = 5
    private static let getKeyInfoCommand: UInt8 = 9
    private static let successResult: UInt8 = 0
    private static let keyNotFoundResult: UInt8 = 132
    private static let byteCapacity = 32
    private static let wireSize = 80

    func read(_ keys: [SMCPowerKey]) throws
        -> [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>]
    {
        // Reject the entire request before opening a hardware connection.
        for key in keys {
            guard Self.allowedCodes.contains(key.fourCharacterCode) else {
                throw SMCOpenError.unavailable
            }
        }

        guard !keys.isEmpty else { return [:] }

        // Swift struct layout need not match a nested C struct's tail padding.
        // Fail closed if the offsets or total stride ever change.
        guard Self.hasExpectedWireLayout() else {
            throw SMCOpenError.unavailable
        }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Self.serviceName)
        )
        guard service != 0 else { throw SMCOpenError.unavailable }
        defer { _ = IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let openStatus = IOServiceOpen(
            service,
            mach_task_self_,
            Self.userClientOpenType,
            &connection
        )
        guard openStatus == KERN_SUCCESS, connection != 0 else {
            // Be defensive if the call left behind a handle on failure.
            if connection != 0 { _ = IOServiceClose(connection) }
            throw SMCOpenError.refused
        }
        defer { _ = IOServiceClose(connection) }

        var results: [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>] = [:]
        for key in keys {
            results[key] = readKey(key.fourCharacterCode, connection: connection)
        }
        return results
    }

    private func readKey(
        _ code: UInt32,
        connection: io_connect_t
    ) -> Result<SMCRawValue, SMCKeyReadError> {
        var infoRequest = SMCParameterBlock()
        infoRequest.key = code
        infoRequest.command = Self.getKeyInfoCommand

        let info: SMCParameterBlock
        switch Self.callSMC(infoRequest, connection: connection) {
        case .success(let response):
            info = response
        case .failure(let error):
            return .failure(error)
        }

        // The SMC supplies both the type and byte length. Never trust it to
        // fit in the fixed 32-byte payload without validating it first.
        // CellKeeperCore performs type, endianness, and power-range decoding.
        // In particular, the caller gates B0AP until its sign is verified.
        let length = info.dataSize
        guard length > 0,
              length <= UInt32(Self.byteCapacity),
              info.dataType != 0 else {
            return .failure(.readFailed)
        }

        var dataRequest = SMCParameterBlock()
        dataRequest.key = code
        dataRequest.dataSize = length
        dataRequest.command = Self.readKeyCommand

        switch Self.callSMC(dataRequest, connection: connection) {
        case .failure(let error):
            return .failure(error)
        case .success(let response):
            // Preserve the exact SMC byte order for SMCPowerDecoding.
            let bytes = withUnsafeBytes(of: response.bytes) { rawBytes in
                Array(rawBytes.prefix(Int(length)))
            }
            return .success(
                SMCRawValue(type: Self.typeString(info.dataType), bytes: bytes)
            )
        }
    }

    private static func callSMC(
        _ request: SMCParameterBlock,
        connection: io_connect_t
    ) -> Result<SMCParameterBlock, SMCKeyReadError> {
        var input = request
        var output = SMCParameterBlock()
        var outputSize = MemoryLayout<SMCParameterBlock>.stride

        let callStatus = IOConnectCallStructMethod(
            connection,
            Self.handleYPCEventSelector,
            &input,
            Self.wireSize,
            &output,
            &outputSize
        )

        guard callStatus == KERN_SUCCESS, outputSize == Self.wireSize else {
            return .failure(.readFailed)
        }
        if output.result == Self.keyNotFoundResult {
            return .failure(.notFound)
        }
        guard output.result == Self.successResult else {
            return .failure(.readFailed)
        }
        return .success(output)
    }

    private static func typeString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hasExpectedWireLayout() -> Bool {
        MemoryLayout<SMCParameterBlock>.stride == Self.wireSize &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.key) == 0 &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.dataSize) == 28 &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.dataType) == 32 &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.result) == 40 &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.command) == 42 &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.data32) == 44 &&
        MemoryLayout<SMCParameterBlock>.offset(of: \.bytes) == 48
    }
}

// Flattened C-compatible representation of the 80-byte SMC parameter block.
// The original C definition contains SMCVersion (6 bytes), SMCPLimitData
// (16 bytes), and SMCKeyInfoData (12 bytes including 3 bytes of tail padding).
// Their padding must be explicit here: Swift can reuse a nested struct's tail
// padding for subsequent fields, unlike C. All fields are zero-initialized.
private struct SMCParameterBlock {
    var key: UInt32 = 0                         // 0

    var versionMajor: UInt8 = 0                 // 4
    var versionMinor: UInt8 = 0                 // 5
    var versionBuild: UInt8 = 0                 // 6
    var versionReserved: UInt8 = 0              // 7
    var versionRelease: UInt16 = 0              // 8
    var versionPadding: UInt16 = 0              // 10

    var limitVersion: UInt16 = 0                // 12
    var limitLength: UInt16 = 0                 // 14
    var limitCPU: UInt32 = 0                    // 16
    var limitGPU: UInt32 = 0                    // 20
    var limitMemory: UInt32 = 0                 // 24

    var dataSize: UInt32 = 0                    // 28 (IOByteCount)
    var dataType: UInt32 = 0                    // 32
    var dataAttributes: UInt8 = 0               // 36
    var infoPadding: (UInt8, UInt8, UInt8) = (0, 0, 0) // 37–39

    var result: UInt8 = 0                       // 40
    var status: UInt8 = 0                       // 41
    var command: UInt8 = 0                      // 42 (C's data8)
    var scalarPadding: UInt8 = 0                // 43
    var data32: UInt32 = 0                      // 44

    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    ) // 48–79
}

#endif // CELLKEEPER_SMC_READER
