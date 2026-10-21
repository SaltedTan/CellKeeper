@testable import CellKeeperCore
import Foundation
import Testing

@Suite("SMC power decoding")
struct SMCPowerDecodingTests {
    @Test("Exactly three keys, each with its four-character code")
    func keys() {
        #expect(SMCPowerKey.allCases.map(\.rawValue) == ["PDTR", "PSTR", "B0AP"])
        #expect(SMCPowerKey.adapterInputPower.fourCharacterCode == 0x5044_5452)
        #expect(SMCPowerKey.systemTotalPower.fourCharacterCode == 0x5053_5452)
        #expect(SMCPowerKey.batteryPower.fourCharacterCode == 0x4230_4150)
    }

    @Test("PDTR and PSTR: a little-endian flt of 4 bytes, finite, within 0–500 W")
    func floats() {
        for key in [SMCPowerKey.adapterInputPower, .systemTotalPower] {
            #expect(SMCPowerDecoding.watts(rawFloat(8.56), for: key) == Double(Float(8.56)))
            #expect(SMCPowerDecoding.watts(rawFloat(0), for: key) == 0)
            #expect(SMCPowerDecoding.watts(rawFloat(500), for: key) == 500)
            // Low byte first: 19.26 W read high byte first is another number.
            let bytes = rawFloat(19.26).bytes
            #expect(SMCPowerDecoding.watts(SMCRawValue(type: "flt ", bytes: bytes), for: key) == Double(Float(19.26)))
            #expect(SMCPowerDecoding.watts(SMCRawValue(type: "flt ", bytes: bytes.reversed()), for: key) != Double(Float(19.26)))
        }
    }

    @Test("A value of the wrong type is refused, never guessed")
    func wrongType() {
        #expect(SMCPowerDecoding.watts(rawFloat(20, type: "si32"), for: .systemTotalPower) == nil)
        #expect(SMCPowerDecoding.watts(rawFloat(20, type: "fpe2"), for: .adapterInputPower) == nil)
        #expect(SMCPowerDecoding.watts(rawFloat(20, type: "flt"), for: .adapterInputPower) == nil)
        #expect(SMCPowerDecoding.watts(rawFloat(20, type: ""), for: .systemTotalPower) == nil)
        #expect(SMCPowerDecoding.watts(rawInt32(10_000, type: "flt "), for: .batteryPower) == nil)
        #expect(SMCPowerDecoding.watts(rawInt32(10_000, type: "ui32"), for: .batteryPower) == nil)
    }

    @Test("A value of the wrong length is refused")
    func wrongLength() {
        let four = rawFloat(20).bytes
        for bytes in [[], Array(four.prefix(3)), four + [0], four + four, [UInt8](repeating: 0, count: 2)] {
            #expect(SMCPowerDecoding.watts(SMCRawValue(type: "flt ", bytes: bytes), for: .systemTotalPower) == nil)
            #expect(SMCPowerDecoding.watts(SMCRawValue(type: "flt ", bytes: bytes), for: .adapterInputPower) == nil)
            #expect(SMCPowerDecoding.watts(SMCRawValue(type: "si32", bytes: bytes), for: .batteryPower) == nil)
        }
    }

    @Test("A value that is not finite is refused")
    func notFinite() {
        for value in [Float.nan, .infinity, -.infinity, .signalingNaN] {
            #expect(SMCPowerDecoding.watts(rawFloat(value), for: .systemTotalPower) == nil)
            #expect(SMCPowerDecoding.watts(rawFloat(value), for: .adapterInputPower) == nil)
        }
    }

    @Test("A value out of range is refused")
    func outOfRange() {
        for value: Float in [-0.01, -20, 500.01, 1_000, .greatestFiniteMagnitude] {
            #expect(SMCPowerDecoding.watts(rawFloat(value), for: .systemTotalPower) == nil)
            #expect(SMCPowerDecoding.watts(rawFloat(value), for: .adapterInputPower) == nil)
        }
        #expect(SMCPowerDecoding.watts(rawInt32(300_001), for: .batteryPower) == nil)
        #expect(SMCPowerDecoding.watts(rawInt32(-300_001), for: .batteryPower) == nil)
        #expect(SMCPowerDecoding.watts(rawInt32(.min), for: .batteryPower) == nil)
        #expect(SMCPowerDecoding.watts(rawInt32(.max), for: .batteryPower) == nil)
    }

    @Test("B0AP: a little-endian si32 of 4 bytes, in mW, signed as read, within ±300 000 mW")
    func batteryPower() {
        #expect(SMCPowerDecoding.watts(rawInt32(15_000), for: .batteryPower) == 15)
        #expect(SMCPowerDecoding.watts(rawInt32(-12_345), for: .batteryPower) == -12.345)
        #expect(SMCPowerDecoding.watts(rawInt32(0), for: .batteryPower) == 0)
        #expect(SMCPowerDecoding.watts(rawInt32(300_000), for: .batteryPower) == 300)
        #expect(SMCPowerDecoding.watts(rawInt32(-300_000), for: .batteryPower) == -300)
        // 10 000 mW low byte first; read high byte first it would be far
        // out of range.
        #expect(SMCPowerDecoding.watts(SMCRawValue(type: "si32", bytes: [0x10, 0x27, 0x00, 0x00]), for: .batteryPower) == 10)
    }

    @Test("A key not read, failed or missing has no value")
    func missing() {
        let values: [SMCPowerKey: Result<SMCRawValue, SMCKeyReadError>] = [
            .systemTotalPower: .failure(.readFailed),
            .adapterInputPower: .failure(.notFound),
        ]
        #expect(SMCPowerDecoding.watts(in: values, for: .systemTotalPower) == nil)
        #expect(SMCPowerDecoding.watts(in: values, for: .adapterInputPower) == nil)
        #expect(SMCPowerDecoding.watts(in: values, for: .batteryPower) == nil)
        #expect(SMCPowerDecoding.watts(in: smcValues(macUse: 12.5), for: .systemTotalPower) == 12.5)
    }
}
