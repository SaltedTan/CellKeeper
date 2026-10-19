import ProbeCore
import Testing

/// Records, in order, what the fakes for the release, the acknowledgement,
/// the record, the exit and the teardown steps were asked to do.
final class Calls: @unchecked Sendable {
    private(set) var log: [String] = []
    private(set) var recorded: [String] = []

    func note(_ call: String) { log.append(call) }

    func record(_ line: String) {
        recorded.append(line)
        log.append("record")
    }
}

@Suite("System sleep and the teardown")
struct SleepResponseTests {
    func willSleep(_ outcome: ReleaseOutcome, _ calls: Calls) -> ReleaseOutcome {
        SleepResponse.willSleep(
            assertion: .disableInflow,
            release: {
                calls.note("release")
                return outcome
            },
            acknowledge: { calls.note("acknowledge") },
            record: { calls.record($0) },
            terminate: { calls.note("terminate \($0)") }
        )
    }

    @Test("A successful release comes first, then the record, then the acknowledgement; no exit")
    func released() {
        let calls = Calls()
        #expect(willSleep(.released, calls) == .released)
        #expect(calls.log == ["release", "record", "acknowledge"])
        #expect(calls.recorded.first?.contains("released the DisableInflow assertion, then allowed the sleep") == true)
    }

    @Test("With nothing held, the sleep is allowed")
    func nothingHeld() {
        let calls = Calls()
        #expect(willSleep(.nothingHeld, calls) == .nothingHeld)
        #expect(calls.log == ["release", "record", "acknowledge"])
        #expect(calls.recorded.first?.contains("no DisableInflow assertion was held") == true)
    }

    @Test("A failed release: no acknowledgement, no claim that it was released, and an exit with the recovery status")
    func failedRelease() throws {
        let calls = Calls()
        let outcome = willSleep(.failed(result: Int32(bitPattern: 0xE000_02F0), attempts: 3), calls)
        #expect(outcome == .failed(result: Int32(bitPattern: 0xE000_02F0), attempts: 3))
        #expect(calls.log == ["release", "record", "terminate 3"])
        #expect(!calls.log.contains("acknowledge"))
        #expect(SleepResponse.failedReleaseExitStatus == 3)
        let line = try #require(calls.recorded.first)
        #expect(calls.recorded.count == 1)
        #expect(!line.lowercased().contains("released"))
        #expect(line.contains("failed 3 times (0xe00002f0 (kIOReturnNotFound))"))
        #expect(line.contains("does not allow the sleep and exits now"))
        #expect(line.contains("pmset -g assertions"))
        #expect(line.contains("docs/research/10-disable-inflow-probe.md §7"))
    }

    func teardown(_ calls: Calls) -> Teardown {
        Teardown(
            releasePrivate: {
                calls.note("private")
                return .released
            },
            releaseIdleSleep: { calls.note("idle sleep") },
            deregisterSleep: { calls.note("deregister") }
        )
    }

    @Test("The normal end tears down the private assertion, then the idle-sleep assertion, then the sleep notifications")
    func normalTeardown() {
        let calls = Calls()
        teardown(calls).finish()
        #expect(calls.log == ["private", "idle sleep", "deregister"])
    }

    @Test("A stop signal releases the private assertion at once; the rest follows in order when the run finishes")
    func signalTeardown() {
        let calls = Calls()
        let teardown = teardown(calls)
        #expect(teardown.stop() == .released)
        #expect(calls.log == ["private"])
        teardown.finish()
        #expect(calls.log == ["private", "private", "idle sleep", "deregister"])
    }

    @Test("A sleep notice goes through the same first step")
    func sleepTeardown() {
        let calls = Calls()
        let teardown = teardown(calls)
        SleepResponse.willSleep(
            assertion: .disableInflow,
            release: { teardown.stop() },
            acknowledge: { calls.note("acknowledge") },
            record: { calls.record($0) },
            terminate: { calls.note("terminate \($0)") }
        )
        teardown.finish()
        #expect(calls.log == ["private", "record", "acknowledge", "private", "idle sleep", "deregister"])
    }
}
