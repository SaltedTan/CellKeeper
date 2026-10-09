import CellKeeperHelperCore
import Testing

@Suite("Helper engine: interlocks")
struct HelperInterlockTests {
    /// An engine with both controls active, at 60% on external power.
    private func activeHarness() async -> (Harness, HelperSession) {
        let h = Harness()
        let session = await h.startedSession()
        #expect(await h.activate(.chargingInhibited, on: session) == .ok)
        #expect(await h.activate(.adapterDisabled, on: session) == .ok)
        return (h, session)
    }

    /// Renews the lease and asks for `control` again, after the activation
    /// interval so the rate limit cannot be the reason for a refusal.
    private func reactivate(_ control: HelperControl, _ h: Harness, _ session: HelperSession) async -> HelperStatus {
        h.clock.advance(by: HelperEngine.minimumActivationInterval)
        return await h.activate(control, on: session)
    }

    @Test("A missing power state clears every control and refuses activation (R9)")
    func powerStateUnavailable() async {
        let (h, session) = await activeHarness()
        h.power.update { $0.isUnavailable = true }
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.interlocksRaised(.powerStateUnavailable)))
        #expect(h.recorder.contains(.deactivated(.chargingInhibited, .interlock(.powerStateUnavailable))))
        #expect(await session.readState().interlocks == .powerStateUnavailable)
        #expect(await reactivate(.chargingInhibited, h, session) == .blockedByInterlock)
        #expect(h.recorder.contains(.requestRejected(session.id, .setControl, .blockedByInterlock)))

        h.power.update { $0.isUnavailable = false }
        await h.engine.tick()
        #expect(h.recorder.contains(.interlocksCleared(.powerStateUnavailable)))
        #expect(await session.readState().interlocks.isEmpty)
        #expect(await reactivate(.chargingInhibited, h, session) == .ok)
    }

    @Test("A power state older than 60 s, or from the future, is unavailable (R9)")
    func stalePowerState() async {
        let (h, session) = await activeHarness()
        let readAt = h.clock.uptime
        h.power.update { $0.readAtUptime = readAt }

        h.clock.advance(by: HelperEngine.maximumPowerStateAge - 1)
        await h.engine.tick()
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])

        h.clock.advance(by: 2)
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.readState().interlocks == .powerStateUnavailable)

        h.power.update { $0.readAtUptime = readAt + 1_000 }
        await h.engine.tick()
        #expect(await session.readState().interlocks == .powerStateUnavailable)

        h.power.update { $0.readAtUptime = nil }
        await h.engine.tick()
        #expect(await session.readState().interlocks.isEmpty)
    }

    @Test("A power state without a usable charge or power source is unavailable", arguments: [
        StubPowerReading.Values(stateOfCharge: nil),
        StubPowerReading.Values(stateOfCharge: -1),
        StubPowerReading.Values(stateOfCharge: 101),
        StubPowerReading.Values(isOnExternalPower: nil),
    ])
    func incompletePowerState(values: StubPowerReading.Values) async {
        let (h, session) = await activeHarness()
        h.power.update { $0 = values }
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(await session.readState().interlocks == .powerStateUnavailable)
    }

    @Test("At the battery floor every control is cleared until the charge recovers to 15% (R5)")
    func batteryFloor() async {
        let (h, session) = await activeHarness()

        h.power.update { $0.stateOfCharge = 11 }
        await h.engine.tick()
        // The adapter floor has already cleared the adapter-disable.
        #expect(h.control.activeControls == [.chargingInhibited])

        h.power.update { $0.stateOfCharge = 10 }
        await h.engine.tick()
        #expect(h.control.activeControls.isEmpty)
        #expect(h.recorder.contains(.deactivated(.chargingInhibited, .interlock(.belowBatteryFloor))))
        #expect(await session.readState().interlocks == [.belowBatteryFloor, .belowAdapterFloor])

        h.power.update { $0.stateOfCharge = 14 }
        #expect(await reactivate(.chargingInhibited, h, session) == .blockedByInterlock)

        h.power.update { $0.stateOfCharge = 15 }
        #expect(await reactivate(.chargingInhibited, h, session) == .ok)
        #expect(await session.readState().interlocks == .belowAdapterFloor)
    }

    @Test("Without external power the charging inhibit is cleared, but not the adapter-disable (R18)")
    func notOnExternalPower() async {
        let (h, session) = await activeHarness()
        // A disabled adapter makes the Mac report battery power; it is
        // still physically connected.
        h.power.update { $0.isOnExternalPower = false }
        await h.engine.tick()
        #expect(h.control.activeControls == [.adapterDisabled])
        #expect(h.recorder.contains(.deactivated(.chargingInhibited, .interlock(.notOnExternalPower))))
        #expect(await reactivate(.chargingInhibited, h, session) == .blockedByInterlock)

        h.power.update { $0.isOnExternalPower = true }
        #expect(await reactivate(.chargingInhibited, h, session) == .ok)
    }

    @Test("A missing or unknown adapter clears and refuses the adapter-disable", arguments: [false, nil] as [Bool?])
    func adapterPresence(isAdapterPresent: Bool?) async {
        let (h, session) = await activeHarness()
        h.power.update { $0.isAdapterPresent = isAdapterPresent }
        await h.engine.tick()
        let interlock: HelperInterlocks = isAdapterPresent == nil ? .adapterPresenceUnknown : .adapterAbsent
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.readState().interlocks == interlock)
        #expect(h.recorder.contains(.deactivated(.adapterDisabled, .interlock(interlock))))
        #expect(await reactivate(.adapterDisabled, h, session) == .blockedByInterlock)

        h.power.update { $0.isAdapterPresent = true }
        #expect(await reactivate(.adapterDisabled, h, session) == .ok)
    }

    @Test("The adapter-disable has its own floor: cleared at 25%, refused until 30%")
    func adapterFloor() async {
        let (h, session) = await activeHarness()

        h.power.update { $0.stateOfCharge = 26 }
        await h.engine.tick()
        #expect(h.control.activeControls == [.chargingInhibited, .adapterDisabled])

        h.power.update { $0.stateOfCharge = 25 }
        await h.engine.tick()
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.readState().interlocks == .belowAdapterFloor)

        h.power.update { $0.stateOfCharge = 29 }
        #expect(await reactivate(.adapterDisabled, h, session) == .blockedByInterlock)

        h.power.update { $0.stateOfCharge = 30 }
        #expect(await reactivate(.adapterDisabled, h, session) == .ok)
        #expect(await session.readState().interlocks.isEmpty)
    }

    @Test("Thermal pressure clears the adapter-disable; the charging inhibit stays allowed (R21)")
    func thermalPressure() async {
        let (h, session) = await activeHarness()
        h.power.update { $0.isThermalPressureHigh = true }
        await h.engine.tick()
        #expect(h.control.activeControls == [.chargingInhibited])
        #expect(await session.readState().interlocks == .thermalPressure)
        #expect(await reactivate(.adapterDisabled, h, session) == .blockedByInterlock)
        _ = await session.setControl(control: HelperControl.chargingInhibited.rawValue, active: false)
        #expect(await reactivate(.chargingInhibited, h, session) == .ok)

        h.power.update { $0.isThermalPressureHigh = false }
        #expect(await reactivate(.adapterDisabled, h, session) == .ok)
    }

    @Test("Interlocks are checked on every request, not only on ticks")
    func checkedOnRequest() async {
        let (h, session) = await activeHarness()
        h.power.update { $0.isOnExternalPower = false }
        #expect(await session.readState().active == [.adapterDisabled])
    }
}
