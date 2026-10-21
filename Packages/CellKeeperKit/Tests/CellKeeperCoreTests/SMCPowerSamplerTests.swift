@testable import CellKeeperCore
import Foundation
import Testing

/// Drives a sampler with explicit instants, in seconds after
/// ``readClockOrigin``.
private struct Driver {
    var sampler: SMCPowerSampler

    init(verified: Bool = false, source: PowerSource? = .externalPower) {
        var configuration = SMCPowerSampler.Configuration()
        configuration.isBatteryPowerVerified = verified
        sampler = SMCPowerSampler(configuration: configuration)
        sampler.show()
        sampler.setPowerSource(source, at: readInstant(0))
    }

    /// Ticks at `seconds`, returning the generation of the batch begun, if
    /// any.
    @discardableResult
    mutating func tick(_ seconds: Double) -> Int? {
        sampler.tick(at: readInstant(seconds))
    }

    /// The batch in flight returns at `seconds`, with `generation` (the
    /// one it began with unless given).
    mutating func returns(_ seconds: Double, _ outcome: SMCPowerSampler.Outcome, generation: Int? = nil) {
        let carried = generation ?? sampler.inFlight?.generation ?? -1
        sampler.batchReturned(generation: carried, outcome: outcome, at: readInstant(seconds), collectedAt: referenceDate.addingTimeInterval(seconds))
    }

    /// A batch that begins at `began` and returns `outcome` `duration`
    /// seconds later.
    mutating func batch(at began: Double, taking duration: Double = 0.2, _ outcome: SMCPowerSampler.Outcome = .read(smcValues())) {
        let generation = tick(began)
        #expect(generation != nil, "a batch begins at \(began) s")
        returns(began + duration, outcome)
    }

    /// Three valid batches from `start`, a second apart: available.
    mutating func makeAvailable(from start: Double = 0) {
        for second in 0..<3 {
            batch(at: start + Double(second))
        }
        #expect(sampler.state == .available)
    }
}

private let invalid = SMCPowerSampler.Outcome.read(smcValues(macUse: nil))

@Suite("SMC power sampler: states")
struct SMCPowerSamplerStateTests {
    @Test("Starts probing; three valid batches in a row make it available")
    func probingToAvailable() {
        var driver = Driver()
        #expect(driver.sampler.state == .probing)
        driver.batch(at: 0)
        driver.batch(at: 1)
        #expect(driver.sampler.state == .probing)
        #expect(driver.sampler.consecutiveValid == 2)
        // Nothing is published while probing.
        #expect(driver.sampler.publish() == SMCPowerPublication(state: .probing, window: nil))
        // The counts are not the window's: the hand-out kept them.
        driver.batch(at: 2)
        #expect(driver.sampler.state == .available)
        #expect(driver.sampler.window.count == 1)
    }

    @Test("An invalid batch restarts the count while probing")
    func probingRestarts() {
        var driver = Driver()
        driver.batch(at: 0)
        driver.batch(at: 1)
        driver.batch(at: 2, invalid)
        driver.batch(at: 3)
        driver.batch(at: 4)
        #expect(driver.sampler.state == .probing)
        driver.batch(at: 5)
        #expect(driver.sampler.state == .available)
    }

    @Test("Available: three invalid batches in a row make it failing; two do not")
    func availableToFailing() {
        var driver = Driver()
        driver.makeAvailable()
        driver.batch(at: 3, invalid)
        driver.batch(at: 4, invalid)
        #expect(driver.sampler.state == .available)
        driver.batch(at: 5)
        driver.batch(at: 6, invalid)
        driver.batch(at: 7, invalid)
        #expect(driver.sampler.state == .available)
        driver.batch(at: 8, invalid)
        #expect(driver.sampler.state == .failing)
        #expect(driver.sampler.window.isEmpty)
        #expect(driver.sampler.publish() == SMCPowerPublication(state: .failing, window: nil))
    }

    @Test("Failing: three valid batches in a row make it available again")
    func failingRecovers() {
        var driver = Driver()
        driver.makeAvailable()
        for second in 3...5 { driver.batch(at: Double(second), invalid) }
        #expect(driver.sampler.state == .failing)
        driver.batch(at: 6)
        driver.batch(at: 7)
        #expect(driver.sampler.state == .failing)
        driver.batch(at: 8)
        #expect(driver.sampler.state == .available)
    }

    @Test("Recovery with slow batches (1.5 s each): three in a row, though each window holds one or two")
    func slowBatches() {
        var driver = Driver()
        driver.makeAvailable()
        for second in 3...5 { driver.batch(at: Double(second), invalid) }
        #expect(driver.sampler.state == .failing)
        // The timer ticks every second; a batch taking 1.5 s lets one begin
        // every 2 s. The refresher asks for a window every 3 s.
        var windows: [Int] = []
        var returnsAt: Double?
        for tenth in stride(from: 60, through: 200, by: 5) {
            let now = Double(tenth) / 10
            if let due = returnsAt, now >= due {
                driver.returns(due, .read(smcValues()))
                returnsAt = nil
            }
            if now == now.rounded(), driver.tick(now) != nil {
                returnsAt = now + 1.5
            }
            if tenth % 30 == 0, let window = driver.sampler.publish().window {
                windows.append(window.batches)
            }
        }
        #expect(driver.sampler.state == .available)
        #expect(!windows.isEmpty)
        #expect(windows.allSatisfy { (1...2).contains($0) })
    }

    @Test("A failed open backs off 30 s, doubling to at most 5 minutes, and tries only while shown")
    func backingOff() {
        var driver = Driver()
        // Each failed open returns 0.2 s after it began; the wait counts
        // from then.
        driver.batch(at: 0, .openFailed)
        #expect(driver.sampler.state == .backingOff)
        #expect(driver.sampler.backoff == .seconds(30))
        var failedAt = 0.2
        var wait = 30.0
        for expected in [60.0, 120, 240, 300, 300] {
            #expect(driver.tick(failedAt + wait - 0.1) == nil)
            driver.batch(at: failedAt + wait, .openFailed)
            failedAt += wait + 0.2
            wait = expected
            #expect(driver.sampler.backoff == .seconds(expected))
            #expect(driver.sampler.state == .backingOff)
        }
        // Hidden, no attempt is made even when one is due.
        driver.sampler.hide()
        #expect(driver.tick(failedAt + wait + 10) == nil)
        driver.sampler.show()
        #expect(driver.tick(failedAt + wait + 11) != nil)
    }

    @Test("A successful open while backing off starts probing again, from no batches")
    func backingOffSucceeds() {
        var driver = Driver()
        driver.makeAvailable()
        driver.batch(at: 3, .openFailed)
        #expect(driver.sampler.state == .backingOff)
        #expect(driver.sampler.window.isEmpty)
        driver.batch(at: 33.2)
        #expect(driver.sampler.state == .probing)
        #expect(driver.sampler.backoff == nil)
        #expect(driver.sampler.consecutiveValid == 1)
        driver.batch(at: 34.2)
        driver.batch(at: 35.2)
        #expect(driver.sampler.state == .available)
        // A later failure backs off from 30 s again.
        driver.batch(at: 36.2, .openFailed)
        #expect(driver.sampler.backoff == .seconds(30))
    }

    @Test("A failed open backs off from any state")
    func failedOpenFromAnyState() {
        var probing = Driver()
        probing.batch(at: 0, .openFailed)
        #expect(probing.sampler.state == .backingOff)
        var failing = Driver()
        failing.makeAvailable()
        for second in 3...5 { failing.batch(at: Double(second), invalid) }
        failing.batch(at: 6, .openFailed)
        #expect(failing.sampler.state == .backingOff)
    }

    @Test("On external power a batch needs a valid PDTR; on battery it does not; B0AP never invalidates")
    func validity() {
        var plugged = Driver(verified: true, source: .externalPower)
        #expect(plugged.sampler.isValid(smcValues()))
        #expect(!plugged.sampler.isValid(smcValues(adapterInput: nil)))
        #expect(!plugged.sampler.isValid(smcValues(macUse: nil)))
        #expect(plugged.sampler.isValid(smcValues(battery: nil)))
        #expect(!plugged.sampler.isValid([.systemTotalPower: .success(rawFloat(20))]))
        #expect(!plugged.sampler.isValid([.systemTotalPower: .success(rawFloat(20)), .adapterInputPower: .success(rawFloat(-1))]))
        plugged.sampler.setPowerSource(.battery, at: readInstant(1))
        #expect(plugged.sampler.isValid(smcValues(adapterInput: nil)))
        #expect(plugged.sampler.isValid([.systemTotalPower: .success(rawFloat(20))]))
        #expect(!plugged.sampler.isValid(smcValues(macUse: nil)))
        let unknown = Driver(source: nil)
        #expect(unknown.sampler.isValid(smcValues(adapterInput: nil)))
    }

    @Test("Each batch asks for PSTR and PDTR, and B0AP only once its sign is verified (off by default)")
    func keysAsked() {
        #expect(SMCPowerSampler.isBatteryPowerVerified == false)
        #expect(SMCPowerSampler().keys == [.systemTotalPower, .adapterInputPower])
        #expect(Driver(verified: true).sampler.keys == [.systemTotalPower, .adapterInputPower, .batteryPower])
    }
}

@Suite("SMC power sampler: in flight, deadline and generations")
struct SMCPowerSamplerFlightTests {
    @Test("One batch at a time: none begins while one is in flight")
    func oneAtATime() {
        var driver = Driver()
        #expect(driver.tick(0) != nil)
        #expect(driver.tick(1) == nil)
        driver.returns(1.2, .read(smcValues()))
        #expect(driver.sampler.inFlight == nil)
        #expect(driver.tick(2) != nil)
    }

    @Test("A batch not back 2 s after it began is stalled: available becomes failing, and its late result is dropped")
    func stall() {
        var driver = Driver()
        driver.makeAvailable()
        driver.batch(at: 3)
        let generation = driver.tick(4)
        #expect(generation != nil)
        #expect(driver.tick(5) == nil)
        #expect(driver.sampler.state == .available)
        // Exactly 2 s after it began.
        #expect(driver.tick(6) == nil)
        #expect(driver.sampler.inFlight?.isStalled == true)
        #expect(driver.sampler.state == .failing)
        #expect(driver.sampler.generation != generation)
        #expect(driver.sampler.window.isEmpty)
        // Still in flight: nothing begins, and the stall counts once.
        #expect(driver.tick(7) == nil)
        #expect(driver.sampler.consecutiveInvalid == 1)
        // The late result is valid, but dropped.
        driver.returns(7.5, .read(smcValues()), generation: generation)
        #expect(driver.sampler.inFlight == nil)
        #expect(driver.sampler.consecutiveValid == 0)
        #expect(driver.sampler.state == .failing)
        #expect(driver.tick(8) != nil)
    }

    @Test("A read that returns past its deadline before any tick saw it is a stall: available becomes failing, and it publishes nothing")
    func lateReturnWithoutTick() {
        var driver = Driver()
        driver.makeAvailable()
        driver.publish()
        // Begins at 3 s; the next tick is not due before it returns at
        // 5.1 s, 2.1 s later.
        let generation = driver.tick(3)
        #expect(generation != nil)
        driver.returns(5.1, .read(smcValues(macUse: 50)))
        #expect(driver.sampler.inFlight == nil)
        #expect(driver.sampler.state == .failing)
        #expect(driver.sampler.window.isEmpty)
        #expect(driver.sampler.consecutiveInvalid == 1)
        #expect(driver.sampler.generation != generation)
        #expect(driver.sampler.publish() == SMCPowerPublication(state: .failing, window: nil))
    }

    @Test("The deadline at return: 1.9 s is accepted, exactly 2 s is a stall")
    func deadlineAtReturn() throws {
        var quick = Driver()
        quick.makeAvailable()
        quick.publish()
        quick.tick(3)
        quick.returns(4.9, .read(smcValues(macUse: 12)))
        #expect(quick.sampler.state == .available)
        let window = try #require(quick.sampler.publish().window)
        #expect(window.macUseWatts == Double(Float(12)))

        var exact = Driver()
        exact.makeAvailable()
        exact.publish()
        exact.tick(3)
        exact.returns(5, .read(smcValues()))
        #expect(exact.sampler.state == .failing)
        #expect(exact.sampler.publish().window == nil)
    }

    @Test("A late return counts once: a tick that already saw the stall leaves the return to be dropped")
    func lateReturnAfterTickStall() {
        var driver = Driver()
        driver.makeAvailable()
        let generation = driver.tick(3)
        driver.tick(5)
        #expect(driver.sampler.consecutiveInvalid == 1)
        driver.returns(5.5, .read(smcValues()), generation: generation)
        #expect(driver.sampler.consecutiveInvalid == 1)
        #expect(driver.sampler.consecutiveValid == 0)
    }

    @Test("An open attempt that returns past its deadline counts as a failed open, even when it succeeded")
    func lateOpenWhileBackingOff() {
        var driver = Driver()
        driver.batch(at: 0, .openFailed)
        #expect(driver.tick(30.2) != nil)
        driver.returns(32.5, .read(smcValues()))
        #expect(driver.sampler.state == .backingOff)
        #expect(driver.sampler.backoff == .seconds(60))
    }

    @Test("A stall while probing restarts its count; one while backing off counts as a failed open")
    func stallElsewhere() {
        var probing = Driver()
        probing.batch(at: 0)
        probing.batch(at: 1)
        probing.tick(2)
        probing.tick(4)
        #expect(probing.sampler.state == .probing)
        #expect(probing.sampler.consecutiveValid == 0)
        var backingOff = Driver()
        backingOff.batch(at: 0, .openFailed)
        #expect(backingOff.tick(30.2) != nil)
        backingOff.tick(32.2)
        #expect(backingOff.sampler.state == .backingOff)
        #expect(backingOff.sampler.backoff == .seconds(60))
    }

    @Test("One physical read across resets: a read stuck before sleep, after wake and after the menu reopens starts no second read, and its result is dropped")
    func inFlightAcrossResets() {
        var driver = Driver()
        driver.makeAvailable()
        let stuck = driver.tick(3)
        #expect(stuck != nil)
        // The Mac sleeps with the menu open: the menu closes.
        driver.sampler.hide()
        // It wakes, and the menu is opened again.
        driver.sampler.reset()
        driver.sampler.show()
        for second in 100...110 {
            #expect(driver.tick(Double(second)) == nil)
        }
        #expect(driver.sampler.inFlight?.generation == stuck)
        driver.returns(111, .read(smcValues(macUse: 99)), generation: stuck)
        #expect(driver.sampler.inFlight == nil)
        #expect(driver.sampler.window.isEmpty)
        #expect(driver.tick(112) != nil)
    }

    @Test("A reset retires the generation: a batch in flight is dropped; the state and counts stay")
    func resetRetires() {
        var driver = Driver()
        driver.makeAvailable()
        let generation = driver.tick(3)
        driver.sampler.reset()
        driver.returns(3.2, .read(smcValues()), generation: generation)
        #expect(driver.sampler.window.isEmpty)
        #expect(driver.sampler.state == .available)
        #expect(driver.sampler.consecutiveValid == 3)
    }
}

@Suite("SMC power sampler: windows")
struct SMCPowerSamplerWindowTests {
    @Test("A window averages its valid batches, each weighted equally, and is handed out once")
    func averages() throws {
        var driver = Driver()
        driver.makeAvailable()
        driver.publish()
        driver.batch(at: 3, .read(smcValues(macUse: 10, adapterInput: 12)))
        driver.batch(at: 4, .read(smcValues(macUse: 20, adapterInput: 24)))
        driver.batch(at: 5, taking: 0.5, .read(smcValues(macUse: 30, adapterInput: 30)))
        let window = try #require(driver.sampler.publish().window)
        #expect(window.batches == 3)
        #expect(window.macUseWatts == 20)
        #expect(window.adapterInputWatts == 22)
        #expect(window.batteryWatts == nil)
        #expect(window.firstBatchBegan == readInstant(3))
        #expect(window.lastBatchReturned == readInstant(5.5))
        #expect(window.collectedAt == referenceDate.addingTimeInterval(5.5))
        #expect(window.averagedOver == .seconds(3))
        // Handed out once.
        #expect(driver.sampler.publish() == SMCPowerPublication(state: .available, window: nil))
    }

    @Test("A partial window: one batch, published with its count")
    func partial() throws {
        var driver = Driver()
        driver.makeAvailable()
        driver.publish()
        driver.batch(at: 3, .read(smcValues(macUse: 12)))
        let window = try #require(driver.sampler.publish().window)
        #expect(window.batches == 1)
        #expect(window.macUseWatts == 12)
        #expect(window.averagedOver == .seconds(1))
    }

    @Test("A window's span is rounded up to whole seconds, at least one: each reading stands for the second until the next")
    func averagedOver() {
        let spans: [Double] = [0.2, 1, 2.01, 3, 3.5]
        #expect(spans.map { smcWindow(began: 0, span: $0).averagedOver } == [.seconds(1), .seconds(1), .seconds(3), .seconds(3), .seconds(4)])
    }

    @Test("On battery, PDTR's average is given only if every batch had one")
    func adapterOnBattery() throws {
        var driver = Driver(source: .battery)
        driver.makeAvailable()
        driver.publish()
        driver.batch(at: 3, .read(smcValues(adapterInput: 0.4)))
        driver.batch(at: 4, .read(smcValues(adapterInput: nil)))
        let window = try #require(driver.sampler.publish().window)
        #expect(window.batches == 2)
        #expect(window.adapterInputWatts == nil)
    }

    @Test("After O1: the battery's power is B0AP's average only if every batch has a valid one")
    func batteryPower() throws {
        var driver = Driver(verified: true)
        driver.makeAvailable()
        driver.publish()
        driver.batch(at: 3, .read(smcValues(battery: 10_000)))
        driver.batch(at: 4, .read(smcValues(battery: 20_000)))
        let window = try #require(driver.sampler.publish().window)
        #expect(window.batteryWatts == 15)
        driver.batch(at: 5, .read(smcValues(battery: 10_000)))
        driver.batch(at: 6, .read(smcValues(battery: nil)))
        driver.batch(at: 7, .read([.systemTotalPower: .success(rawFloat(20)), .adapterInputPower: .success(rawFloat(30)), .batteryPower: .success(rawInt32(5_000, type: "ui32"))]))
        let mixed = try #require(driver.sampler.publish().window)
        #expect(mixed.batches == 3)
        #expect(mixed.batteryWatts == nil)
    }

    @Test("Before O1, B0AP is neither asked for nor used")
    func batteryPowerUnverified() throws {
        var driver = Driver()
        driver.makeAvailable()
        driver.publish()
        driver.batch(at: 3, .read(smcValues(battery: 10_000)))
        let window = try #require(driver.sampler.publish().window)
        #expect(window.batteryWatts == nil)
    }

    @Test("The window resets when the section collapses or the menu closes, on wake, and on a power-source change")
    func resets() {
        for reset in ["hide", "wake", "power source"] {
            var driver = Driver()
            driver.makeAvailable()
            driver.batch(at: 3)
            #expect(!driver.sampler.window.isEmpty)
            switch reset {
            case "hide": driver.sampler.hide()
            case "wake": driver.sampler.reset()
            default: driver.sampler.setPowerSource(.battery, at: readInstant(3.5))
            }
            #expect(driver.sampler.window.isEmpty, "\(reset)")
            #expect(driver.sampler.publish().window == nil, "\(reset)")
        }
    }

    @Test("No batch begins within 1 s of a power-source change, so a window never mixes plugged-in and battery readings")
    func powerSourceChange() {
        var driver = Driver()
        driver.makeAvailable()
        let inFlight = driver.tick(3)
        driver.sampler.setPowerSource(.battery, at: readInstant(3.3))
        // The batch that began before the change is dropped.
        driver.returns(3.4, .read(smcValues()), generation: inFlight)
        #expect(driver.sampler.window.isEmpty)
        #expect(driver.tick(4) == nil)
        #expect(driver.tick(4.29) == nil)
        #expect(driver.tick(4.3) != nil)
        // Telling the same source again, or none, is not a change.
        driver.returns(4.5, .read(smcValues()))
        driver.sampler.setPowerSource(.battery, at: readInstant(4.6))
        driver.sampler.setPowerSource(nil, at: readInstant(4.7))
        #expect(driver.sampler.window.count == 1)
        #expect(driver.sampler.powerSource == .battery)
    }

    @Test("Nothing begins while hidden, nor before the first show")
    func hidden() {
        var sampler = SMCPowerSampler()
        #expect(sampler.tick(at: readInstant(0)) == nil)
        sampler.show()
        #expect(sampler.tick(at: readInstant(1)) != nil)
    }
}

extension Driver {
    mutating func publish() {
        _ = sampler.publish()
    }
}
