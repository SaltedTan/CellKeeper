import CellKeeperHelperCore
import Testing

@Suite("Helper wire vocabulary")
struct HelperProtocolTests {
    @Test("Raw values are the wire format and never change")
    func rawValuesArePinned() {
        #expect(HelperProtocolVersion.current == 1)
        #expect(HelperProtocolVersion.minimumSupportedClient == 1)

        #expect(HelperControl.chargingInhibited.rawValue == 1)
        #expect(HelperControl.adapterDisabled.rawValue == 2)

        #expect(HelperCapabilities.chargingInhibit.rawValue == 1 << 0)
        #expect(HelperCapabilities.adapterDisable.rawValue == 1 << 1)

        #expect(HelperControlSet.chargingInhibited.rawValue == 1 << 1)
        #expect(HelperControlSet.adapterDisabled.rawValue == 1 << 2)

        let interlocks: [(HelperInterlocks, UInt64)] = [
            (.belowBatteryFloor, 1 << 0),
            (.notOnExternalPower, 1 << 1),
            (.belowAdapterFloor, 1 << 2),
            (.adapterAbsent, 1 << 3),
            (.adapterPresenceUnknown, 1 << 4),
            (.thermalPressure, 1 << 5),
            (.powerStateUnavailable, 1 << 6),
            (.externalModification, 1 << 7),
            (.hardwareFault, 1 << 8),
            (.sleepImminent, 1 << 9),
            (.writeFailed, 1 << 10),
        ]
        for (interlock, raw) in interlocks {
            #expect(interlock.rawValue == raw, "\(interlock)")
        }

        let statuses: [(HelperStatus, Int)] = [
            (.ok, 0), (.incompatibleProtocol, 1), (.notIntroduced, 2), (.unsupportedControl, 3),
            (.invalidArgument, 4), (.noLease, 5), (.leaseHeldByOtherClient, 6), (.rateLimited, 7),
            (.blockedByInterlock, 8), (.hardwareError, 9), (.shuttingDown, 10), (.notReady, 11),
            (.controlChanged, 12),
        ]
        #expect(statuses.count == HelperStatus.allCases.count)
        for (status, raw) in statuses {
            #expect(status.rawValue == raw, "\(status)")
        }

        // 0 on the wire means no change since start.
        let causes: [(HelperChangeCause, Int)] = [
            (.setByClient, 1), (.clearedByClient, 2), (.clearedByRestore, 3), (.leaseExpired, 4), (.interlock, 5),
            (.sessionEnded, 6), (.sessionRevoked, 7), (.shutdown, 8), (.start, 9), (.changedOutside, 10),
            (.restoredAfterOutsideChange, 11), (.restoredAfterWriteFailure, 12), (.restoredAfterReadBackFailure, 13),
            (.restoreRetried, 14), (.activationLimited, 15), (.foundActiveAtStart, 16),
        ]
        #expect(causes.count == HelperChangeCause.allCases.count)
        for (cause, raw) in causes {
            #expect(cause.rawValue == raw, "\(cause)")
        }
        #expect(HelperChangeCause(rawValue: 0) == nil)
    }

    @Test("Unknown raw values are not controls", arguments: [0, 3, -1, Int.max])
    func unknownControls(raw: Int) {
        #expect(HelperControl(rawValue: raw) == nil)
    }

    @Test("Only versions in the supported range are accepted")
    func versionRange() {
        #expect(HelperProtocolVersion.isSupported(client: HelperProtocolVersion.minimumSupportedClient - 1) == false)
        #expect(HelperProtocolVersion.isSupported(client: HelperProtocolVersion.current))
        #expect(HelperProtocolVersion.isSupported(client: HelperProtocolVersion.current + 1) == false)
    }

    @Test("Lease maxima follow rule R3")
    func leaseMaxima() {
        #expect(HelperControl.chargingInhibited.maximumLeaseSeconds == 900)
        #expect(HelperControl.adapterDisabled.maximumLeaseSeconds == 120)
    }

    @Test("Each control is blocked by the interlocks that concern it")
    func blockingInterlocks() {
        let shared: HelperInterlocks = [.belowBatteryFloor, .powerStateUnavailable, .externalModification, .hardwareFault, .writeFailed]
        #expect(HelperControl.chargingInhibited.blockingInterlocks == shared.union(.notOnExternalPower))
        #expect(HelperControl.adapterDisabled.blockingInterlocks == shared.union([
            .belowAdapterFloor, .adapterAbsent, .adapterPresenceUnknown, .thermalPressure, .sleepImminent,
        ]))
    }

    @Test("A control set maps controls to bits and keeps unknown bits")
    func controlSet() {
        let both = HelperControlSet(controls: [.chargingInhibited, .adapterDisabled])
        #expect(both.rawValue == 0b110)
        #expect(both.controls == [.chargingInhibited, .adapterDisabled])
        #expect(HelperControlSet(controls: []).rawValue == 0)

        let withUnknownBit = HelperControlSet(rawValue: 0b1010)
        #expect(withUnknownBit.controls == [.chargingInhibited])
        #expect(withUnknownBit.rawValue == 0b1010)
    }
}

@Suite("Helper charge controls")
struct HelperChargeControlTests {
    @Test("The simulated control says it is simulated and counts every write")
    func simulatedControl() throws {
        let control = SimulatedChargeControl(capabilities: [.chargingInhibit])
        #expect(control.probe() == HelperProbe(capabilities: [.chargingInhibit], isSimulated: true))

        try control.apply(.chargingInhibited, active: true)
        #expect(try control.readBack() == [.chargingInhibited])
        #expect(throws: HelperHardwareError.notSupported) {
            try control.apply(.adapterDisabled, active: true)
        }
        try control.restoreDefaults()
        #expect(control.activeControls.isEmpty)
        #expect(control.writes == [
            .apply(.chargingInhibited, active: true),
            .apply(.adapterDisabled, active: true),
            .restoreDefaults,
        ])
    }

    @Test("Injected failures are used up one at a time")
    func simulatedFailures() throws {
        let control = SimulatedChargeControl()
        control.failNextApplies(1)
        #expect(throws: HelperHardwareError.simulatedFailure) {
            try control.apply(.chargingInhibited, active: true)
        }
        try control.apply(.chargingInhibited, active: true)

        control.ignoreNextApplies(1)
        try control.apply(.chargingInhibited, active: false)
        #expect(control.activeControls == [.chargingInhibited])

        control.failNextReadBacks(1)
        #expect(throws: HelperHardwareError.simulatedFailure) {
            _ = try control.readBack()
        }
        #expect(try control.readBack() == [.chargingInhibited])

        control.failNextRestores(1)
        #expect(throws: HelperHardwareError.simulatedFailure) {
            try control.restoreDefaults()
        }
        #expect(control.activeControls == [.chargingInhibited])

        control.simulateOutsideChange(.adapterDisabled, active: true)
        #expect(control.activeControls == [.chargingInhibited, .adapterDisabled])
        #expect(control.writeCount == 4)

        control.ignoreNextRestores(1)
        try control.restoreDefaults()
        #expect(control.activeControls == [.chargingInhibited, .adapterDisabled])
        try control.restoreDefaults()
        #expect(control.activeControls.isEmpty)
        #expect(control.writeCount == 6)
        #expect(control.readBackCount == 2)
    }

    @Test("Partial failures: a write that takes effect and then throws, and one that changes the other control")
    func simulatedPartialFailures() throws {
        let control = SimulatedChargeControl()
        control.failNextAppliesAfterApplying(1)
        #expect(throws: HelperHardwareError.simulatedFailure) {
            try control.apply(.chargingInhibited, active: true)
        }
        #expect(control.activeControls == [.chargingInhibited])

        control.misapplyNextApplies(1)
        try control.apply(.chargingInhibited, active: false)
        #expect(control.activeControls == [.chargingInhibited])
        control.misapplyNextApplies(1)
        try control.apply(.chargingInhibited, active: true)
        #expect(control.activeControls == [.chargingInhibited, .adapterDisabled])
    }

    @Test("Unknown hardware has no capabilities and never writes")
    func unknownHardware() throws {
        let control = UnknownHardwareChargeControl()
        #expect(control.probe() == HelperProbe(capabilities: [], isSimulated: false))
        #expect(throws: HelperHardwareError.notSupported) {
            try control.apply(.chargingInhibited, active: true)
        }
        try control.restoreDefaults()
        try control.restoreDefaults()
        #expect(try control.readBack().isEmpty)
    }
}
