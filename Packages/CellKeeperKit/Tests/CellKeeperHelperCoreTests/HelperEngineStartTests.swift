import CellKeeperHelperCore
import Testing

@Suite("Helper engine: start")
struct HelperEngineStartTests {
    @Test("Start restores defaults and reads them back before serving anything (R2)")
    func startRestores() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: [.chargingInhibited, .adapterDisabled]))

        #expect(await h.engine.start() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.control.writes == [.restoreDefaults])
        #expect(h.recorder.events == [
            .restored(.start),
            .started(capabilities: [.chargingInhibit, .adapterDisable], isSimulated: true),
        ])

        let session = await h.introducedSession()
        let state = await session.readState()
        #expect(state.status == .ok)
        #expect(state.active.isEmpty)
        #expect(state.interlocks.isEmpty)
        #expect(state.lastHardwareError == 0)
    }

    @Test("Before start, only restores are served")
    func requestsBeforeStart() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: [.chargingInhibited]))
        let session = await h.engine.openSession()

        let hello = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.status == .notReady)
        #expect(hello.helperProtocolVersion == HelperProtocolVersion.current)
        #expect(hello.capabilities.isEmpty)
        #expect(await session.readState().status == .notReady)
        #expect(await session.acquireOrRenewLease(control: 1, seconds: 60) == HelperLeaseReply(status: .notReady, grantedSeconds: 0))
        #expect(await session.setControl(control: 1, active: true) == .notReady)
        #expect(await session.setControl(control: 1, active: false) == .notReady)
        #expect(await session.releaseLease(control: 1) == .notReady)
        await h.engine.tick()
        await h.engine.systemWillSleep()
        await h.engine.systemDidWake()
        #expect(h.control.writeCount == 0)
        #expect(h.recorder.contains(.requestRejected(session.id, .hello, .notReady)))

        #expect(await session.restoreDefaults() == .ok)
        #expect(h.control.activeControls.isEmpty)
        #expect(h.control.writes == [.restoreDefaults])

        await h.engine.start()
        #expect(await session.hello(clientProtocolVersion: HelperProtocolVersion.current).status == .ok)
    }

    @Test("A failed start-up restore faults the engine until a restore reads back clean")
    func failedStartRestore() async {
        let h = Harness(control: SimulatedChargeControl(initiallyActive: [.chargingInhibited]))
        h.control.failNextRestores(1)

        #expect(await h.engine.start() == .hardwareError)
        #expect(h.recorder.contains(.restoreFailed(.start)))
        #expect(h.recorder.contains(.hardwareError(code: HelperHardwareError.simulatedFailure.code)))

        // Faulted, but still serving, so a client can see why.
        let session = await h.introducedSession()
        var state = await session.readState()
        #expect(state.interlocks.contains(.hardwareFault))
        #expect(state.active == [.chargingInhibited])
        #expect(state.lastHardwareError == HelperHardwareError.simulatedFailure.code)
        #expect(await h.activate(.adapterDisabled, on: session) == .blockedByInterlock)
        // Requests do not retry the restore; ticks do.
        #expect(h.control.writes == [.restoreDefaults])

        await h.engine.tick()
        #expect(h.control.writes == [.restoreDefaults, .restoreDefaults])
        #expect(h.recorder.contains(.restored(.faultRetry)))
        #expect(h.recorder.contains(.interlocksCleared(.hardwareFault)))
        state = await session.readState()
        #expect(state.active.isEmpty)
        #expect(state.interlocks.isEmpty)
        #expect(await session.setControl(control: HelperControl.adapterDisabled.rawValue, active: true) == .ok)
    }

    @Test("The shared uptime clock starts near zero and never goes backwards")
    func continuousUptime() {
        let first = HelperEngine.continuousUptime()
        let second = HelperEngine.continuousUptime()
        #expect(first >= 0)
        #expect(second >= first)
    }

    @Test("Starting twice changes nothing")
    func startTwice() async {
        let h = Harness()
        #expect(await h.engine.start() == .ok)
        #expect(await h.engine.start() == .ok)
        #expect(h.control.writeCount == 1)
    }

    @Test("Hello reports the helper's version, build and capabilities")
    func helloReply() async {
        let h = Harness(control: SimulatedChargeControl(capabilities: [.chargingInhibit]))
        await h.engine.start()
        let session = await h.engine.openSession()
        let reply = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(reply == HelperHelloReply(
            status: .ok,
            helperProtocolVersion: HelperProtocolVersion.current,
            build: 42,
            capabilities: [.chargingInhibit],
            isSimulated: true
        ))
    }

    @Test("Unknown hardware is monitor-only: no capabilities, no writes (R12a)")
    func unknownHardware() async {
        let h = Harness(chargeControl: UnknownHardwareChargeControl())
        #expect(await h.engine.start() == .ok)
        let session = await h.engine.openSession()
        let hello = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.capabilities.isEmpty)
        #expect(hello.isSimulated == false)

        for control in HelperControl.allCases {
            #expect(await session.acquireOrRenewLease(control: control.rawValue, seconds: 60).status == .unsupportedControl)
            #expect(await session.setControl(control: control.rawValue, active: true) == .unsupportedControl)
            #expect(await session.setControl(control: control.rawValue, active: false) == .ok)
        }
        #expect(await session.restoreDefaults() == .ok)
        let state = await session.readState()
        #expect(state.status == .ok)
        #expect(state.active.isEmpty)
    }
}
