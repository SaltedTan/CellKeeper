import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Engine: deactivation only of the change a client expects")
struct HelperConditionalClearTests {
    private let inhibit = HelperControl.chargingInhibited
    private let adapter = HelperControl.adapterDisabled

    /// The session's hello reply, for its number and the helper's instance.
    private func introduce(_ h: Harness) async -> (HelperSession, HelperHelloReply) {
        let session = await h.engine.openSession()
        let reply = await session.hello(clientProtocolVersion: HelperProtocolVersion.current)
        return (session, reply)
    }

    @Test("The change the client names is still the latest: the control is cleared as the client's")
    func match() async {
        let h = Harness()
        await h.engine.start()
        let (session, hello) = await introduce(h)
        #expect(await h.activate(inhibit, on: session) == .ok)
        let set = await session.readState().change(for: inhibit)

        #expect(await session.clearControlIfUnchanged(control: inhibit.rawValue, generation: set.generation, helperInstance: hello.helperInstance) == .ok)
        #expect(h.control.activeControls.isEmpty)
        let state = await session.readState()
        #expect(state.change(for: inhibit) == HelperControlChange(generation: set.generation + 1, cause: .clearedByClient, interlocks: [], session: hello.sessionID))
        // The lease is the client's to end.
        #expect(state.chargingInhibitedLeaseSeconds > 0)
    }

    @Test("Another generation: nothing is written, and the refusal is its own status")
    func generationMismatch() async {
        let h = Harness()
        await h.engine.start()
        let (session, hello) = await introduce(h)
        #expect(await h.activate(inhibit, on: session) == .ok)
        let set = await session.readState().change(for: inhibit)
        let writes = h.control.writes.count

        #expect(await session.clearControlIfUnchanged(control: inhibit.rawValue, generation: set.generation - 1, helperInstance: hello.helperInstance) == .controlChanged)
        #expect(h.control.activeControls == [inhibit])
        #expect(h.control.writes.count == writes)
        #expect(h.recorder.contains(.requestRejected(session.id, .clearControlIfUnchanged, .controlChanged)))
        #expect(await session.readState().change(for: inhibit) == set)
    }

    @Test("Another helper process: nothing is written")
    func instanceMismatch() async {
        let h = Harness()
        await h.engine.start()
        let (session, hello) = await introduce(h)
        #expect(await h.activate(inhibit, on: session) == .ok)
        let set = await session.readState().change(for: inhibit)
        let writes = h.control.writes.count

        let otherInstance = hello.helperInstance &+ 1
        #expect(await session.clearControlIfUnchanged(control: inhibit.rawValue, generation: set.generation, helperInstance: otherInstance) == .controlChanged)
        #expect(h.control.activeControls == [inhibit])
        #expect(h.control.writes.count == writes)
    }

    @Test("A lease that ran out and another client's activation in between: the other client's control stays")
    func handoffInBetween() async {
        let h = Harness()
        await h.engine.start()
        let (first, hello) = await introduce(h)
        #expect(await h.activate(adapter, on: first) == .ok)
        let set = await first.readState().change(for: adapter)

        // The first client's lease runs out; another client takes the
        // adapter-disable before the first one asks to clear it.
        h.clock.advance(by: TimeInterval(adapter.maximumLeaseSeconds) + 1)
        let (second, secondHello) = await introduce(h)
        #expect(await h.activate(adapter, on: second) == .ok)
        let writes = h.control.writes.count

        #expect(await first.clearControlIfUnchanged(control: adapter.rawValue, generation: set.generation, helperInstance: hello.helperInstance) == .controlChanged)
        #expect(h.control.activeControls == [adapter])
        #expect(h.control.writes.count == writes)
        let state = await second.readState()
        #expect(state.isLeaseHolder)
        #expect(state.change(for: adapter) == HelperControlChange(generation: set.generation + 2, cause: .setByClient, interlocks: [], session: secondHello.sessionID))
        // An unconditional deactivation would have cleared it.
        #expect(await first.setControl(control: adapter.rawValue, active: false) == .ok)
        #expect(h.control.activeControls.isEmpty)
    }

    @Test("Not refused by the request budget, and an unknown control is an invalid argument")
    func budgetAndArguments() async {
        let h = Harness()
        await h.engine.start()
        let (session, hello) = await introduce(h)
        #expect(await h.activate(inhibit, on: session) == .ok)
        let set = await session.readState().change(for: inhibit)
        #expect(await session.clearControlIfUnchanged(control: 99, generation: set.generation, helperInstance: hello.helperInstance) == .invalidArgument)

        await h.exhaustBudget(of: session)
        #expect(await session.clearControlIfUnchanged(control: inhibit.rawValue, generation: set.generation, helperInstance: hello.helperInstance) == .ok)
        #expect(h.control.activeControls.isEmpty)
    }
}
