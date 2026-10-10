@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Helper daemon: what it ships with")
struct HelperDaemonSystemTests {
    @Test("The shipped daemon controls nothing: hello reports no capabilities, not simulated; setControl is unsupported (R12a)")
    func monitorOnly() async throws {
        let frontend = FakeFrontend()
        var environment = HelperDaemonEnvironment.system(frontend: frontend)
        #expect(environment.control is UnknownHardwareChargeControl)
        #expect(environment.power is DaemonPowerReading)
        #expect(environment.build == HelperBuild.number)
        #expect((environment.historyStore as? FileActivationHistoryStore)?.url == FileActivationHistoryStore.defaultURL)
        #expect(FileActivationHistoryStore.defaultURL.path == "/Library/Application Support/CellKeeper/Helper/activation-history.json")

        // Everything that would touch this Mac is replaced; the control is not.
        let clock = ManualClock()
        let exits = ExitRecorder()
        let signals = FakeTerminationSignals()
        environment.clock = clock
        environment.power = StubPower(clock: clock)
        environment.sleepNotifications = FakeSleepNotifications()
        environment.terminationSignals = signals
        environment.historyStore = InMemoryHistoryStore()
        environment.log = RecordingLog()
        environment.exit = { exits.record($0) }
        let daemon = HelperDaemon(environment: environment)
        let running = Task { await daemon.run() }
        let serving = await eventually { frontend.calls.contains(.start) }
        #expect(serving)

        let session = await daemon.engine.openSession()
        let hello = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        #expect(hello.status == .ok)
        #expect(hello.capabilities.isEmpty)
        #expect(hello.isSimulated == false)
        #expect(hello.build == HelperBuild.number)
        for control in HelperControl.allCases {
            #expect(await session.setControl(control: control.rawValue, active: true) == .unsupportedControl)
        }
        let state = await session.readState()
        #expect(state.status == .ok)
        #expect(state.activeControls.controls.isEmpty)

        signals.sendSIGTERM()
        #expect(await running.value == 0)
        #expect(exits.statuses == [0])
    }

    @Test("Without a listener, the daemon says it serves nobody")
    func noFrontend() throws {
        let log = RecordingLog()
        try NoFrontend().start(serving: HelperEngine(control: UnknownHardwareChargeControl(), power: DaemonPowerReading(), build: 1, uptime: HelperEngine.continuousUptime, events: { _ in }), log: log)
        #expect(log.lines == [RecordingLog.Line(level: .notice, category: .xpc, message: "No client listener is available in this build: serving nobody.")])
    }

    @Test("The service names are the agreed ones")
    func names() {
        #expect(HelperServiceName.label == "io.github.saltedtan.CellKeeper.Helper")
        #expect(HelperServiceName.machService == HelperServiceName.label)
        #expect(UnifiedHelperLog.subsystem == "io.github.saltedtan.CellKeeper.Helper")
        #expect(HelperLogCategory.allCases.map(\.rawValue) == ["lifecycle", "xpc", "control", "safety"])
    }

    @Test("Sleep notification messages have IOMessage.h's values")
    func sleepMessages() {
        #expect(SystemSleepNotifications.canSystemSleep == 0xE000_0270)
        #expect(SystemSleepNotifications.systemWillSleep == 0xE000_0280)
        #expect(SystemSleepNotifications.systemHasPoweredOn == 0xE000_0300)
    }
}
