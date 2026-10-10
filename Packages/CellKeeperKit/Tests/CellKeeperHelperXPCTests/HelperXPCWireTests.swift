import CellKeeperHelperCore
import CellKeeperHelperXPC
import Foundation
import Testing

/// Captures what a reply block was called with.
final class Captured<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.withLock { stored }
    }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }
}

@Suite("Helper NSXPC wire format")
struct HelperXPCWireTests {
    /// Sends `reply` as the helper does and reads it back as the client does.
    private func roundTrip(_ reply: HelperHelloReply) throws -> HelperHelloReply {
        let captured = Captured<Result<HelperHelloReply, HelperXPCError>>()
        HelperXPCWire.send(reply, to: { status, version, build, capabilities, isSimulated, session, instance in
            captured.set(Result {
                try HelperXPCWire.helloReply(
                    status: status, helperProtocolVersion: version, build: build, capabilities: capabilities,
                    isSimulated: isSimulated, sessionID: session, helperInstance: instance
                )
            }.mapError { $0 as? HelperXPCError ?? .malformedReply })
        })
        return try #require(captured.value).get()
    }

    private func roundTrip(_ reply: HelperStateReply) throws -> HelperStateReply {
        let captured = Captured<Result<HelperStateReply, HelperXPCError>>()
        HelperXPCWire.send(reply, to: { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p in
            captured.set(Result {
                try HelperXPCWire.stateReply(
                    status: a, activeControls: b, chargingInhibitedLeaseSeconds: c, adapterDisabledLeaseSeconds: d,
                    isLeaseHolder: e, interlocks: f, lastHardwareError: g, hardwareErrorCount: h,
                    chargingInhibitedGeneration: i, chargingInhibitedChangeCause: j, chargingInhibitedChangeInterlocks: k,
                    chargingInhibitedChangeSession: l, adapterDisabledGeneration: m, adapterDisabledChangeCause: n,
                    adapterDisabledChangeInterlocks: o, adapterDisabledChangeSession: p
                )
            }.mapError { $0 as? HelperXPCError ?? .malformedReply })
        })
        return try #require(captured.value).get()
    }

    @Test("A hello reply crosses the wire unchanged, extreme values included")
    func hello() throws {
        for status in HelperStatus.allCases {
            let reply = HelperHelloReply(
                status: status, helperProtocolVersion: -3, build: Int.max,
                capabilities: HelperCapabilities(rawValue: UInt64.max), isSimulated: true,
                sessionID: UInt64.max, helperInstance: 1
            )
            #expect(try roundTrip(reply) == reply)
        }
    }

    @Test("A state reply crosses the wire unchanged, field by field, including causes and bits this version does not know")
    func state() throws {
        var reply = HelperStateReply(
            status: .hardwareError,
            activeControls: HelperControlSet(rawValue: 0b1110),
            chargingInhibitedLeaseSeconds: 899,
            adapterDisabledLeaseSeconds: 1,
            isLeaseHolder: true,
            interlocks: HelperInterlocks(rawValue: 1 << 63 | 1 << 6),
            lastHardwareError: -10,
            hardwareErrorCount: Int.max,
            chargingInhibitedChange: HelperControlChange(generation: UInt64.max, cause: .interlock, interlocks: [.thermalPressure], session: 7),
            adapterDisabledChange: HelperControlChange(generation: 3, cause: .changedOutside, interlocks: [], session: 0)
        )
        #expect(try roundTrip(reply) == reply)
        // A cause added later, such as foundActiveAtStart, crosses as it is.
        var found = reply
        found.chargingInhibitedChangeCause = HelperChangeCause.foundActiveAtStart.rawValue
        let foundDecoded = try roundTrip(found)
        #expect(foundDecoded.change(for: .chargingInhibited).cause == .foundActiveAtStart)
        // An unknown cause is carried as it came and read as no known cause.
        reply.adapterDisabledChangeCause = 999
        let decoded = try roundTrip(reply)
        #expect(decoded == reply)
        #expect(decoded.change(for: .adapterDisabled).cause == nil)
        #expect(decoded.change(for: .chargingInhibited) == HelperControlChange(generation: UInt64.max, cause: .interlock, interlocks: [.thermalPressure], session: 7))
    }

    @Test("Lease and status replies cross the wire unchanged")
    func leaseAndStatus() throws {
        for status in HelperStatus.allCases {
            let captured = Captured<HelperLeaseReply>()
            HelperXPCWire.send(HelperLeaseReply(status: status, grantedSeconds: 120), to: { raw, granted in
                captured.set((try? HelperXPCWire.leaseReply(status: raw, grantedSeconds: granted)) ?? HelperLeaseReply(status: .ok, grantedSeconds: -1))
            })
            #expect(captured.value == HelperLeaseReply(status: status, grantedSeconds: 120))

            let raw = Captured<Int>()
            HelperXPCWire.send(status, to: { raw.set($0) })
            #expect(try HelperXPCWire.status(try #require(raw.value)) == status)
        }
    }

    @Test("A status this version does not know is never guessed: the reply cannot be read", arguments: [-1, 13, 1000, Int.min])
    func unknownStatus(raw: Int) {
        #expect(throws: HelperXPCError.malformedReply) { try HelperXPCWire.status(raw) }
        #expect(throws: HelperXPCError.malformedReply) { try HelperXPCWire.leaseReply(status: raw, grantedSeconds: 900) }
        #expect(throws: HelperXPCError.malformedReply) {
            try HelperXPCWire.helloReply(status: raw, helperProtocolVersion: 1, build: 1, capabilities: 3, isSimulated: true, sessionID: 1, helperInstance: 1)
        }
        #expect(throws: HelperXPCError.malformedReply) {
            try HelperXPCWire.stateReply(
                status: raw, activeControls: 0, chargingInhibitedLeaseSeconds: 0, adapterDisabledLeaseSeconds: 0,
                isLeaseHolder: false, interlocks: 0, lastHardwareError: 0, hardwareErrorCount: 0,
                chargingInhibitedGeneration: 0, chargingInhibitedChangeCause: 0, chargingInhibitedChangeInterlocks: 0,
                chargingInhibitedChangeSession: 0, adapterDisabledGeneration: 0, adapterDisabledChangeCause: 0,
                adapterDisabledChangeInterlocks: 0, adapterDisabledChangeSession: 0
            )
        }
    }

    @Test("NSXPC's errors map to the client's failures")
    func errorMapping() {
        #expect(HelperXPCError(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)) == .interrupted)
        #expect(HelperXPCError(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)) == .invalidated)
        #expect(HelperXPCError(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid)) == .malformedReply)
        #expect(HelperXPCError(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionCodeSigningRequirementFailure)) == .requirementNotMet)
        #expect(HelperXPCError(NSError(domain: NSCocoaErrorDomain, code: 1)) == .invalidated)
        #expect(HelperXPCError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))) == .invalidated)
    }
}
