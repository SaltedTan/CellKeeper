import CellKeeperCore
import Foundation
import Testing

private let started = CalibrationStamp(wall: Date(timeIntervalSince1970: 1_800_000_000), monotonic: 5_000, boot: "boot-A")

private func storedSession() -> CalibrationSession {
    CalibrationSession.start(
        id: UUID(),
        at: started,
        ownerLimit: 90,
        cellKeeperLimit: 80,
        before: CalibrationCapacities(fullChargeMilliampHours: 6150, nominalMilliampHours: 6302, designMilliampHours: 6249, cycleCount: 56),
        temperatureCheck: .ownerConfirmedCoolRoom,
        optimizedCharging: .boundAccepted
    )
}

@Suite("Calibration: store")
struct CalibrationStoreTests {
    let storage = InMemoryStorage()
    var store: CalibrationStore { CalibrationStore(defaults: storage) }

    @Test("Nothing stored is none; a session and a report round-trip under calibration.v1")
    func roundTrip() throws {
        #expect(store.loadCalibration() == .none)
        let session = storedSession()
        try store.saveCalibration(CalibrationStored(session: session))
        #expect(store.loadCalibration() == .stored(CalibrationStored(session: session)))
        #expect(storage.object(forKey: "calibration.v1") is Data)

        let report = CalibrationReport(session, end: .cancelled, at: started.wall.addingTimeInterval(60), after: nil)
        try store.saveCalibration(CalibrationStored(last: report))
        #expect(store.loadCalibration() == .stored(CalibrationStored(last: report)))
    }

    @Test("The ended mark replaces the session in one write: the report with the session's identity")
    func endedMark() throws {
        let session = storedSession()
        try store.saveCalibration(CalibrationStored(session: session))
        try store.saveCalibration(CalibrationStored(last: CalibrationReport(session, end: .cancelled, at: started.wall, after: nil)))
        guard case .stored(let stored) = store.loadCalibration() else {
            Issue.record("nothing stored")
            return
        }
        #expect(stored.session == nil)
        #expect(stored.last?.id == session.id)
        #expect(stored.last?.end == .cancelled)
    }

    @Test("An empty value removes the key and reads back the removal")
    func removal() throws {
        try store.saveCalibration(CalibrationStored(session: storedSession()))
        try store.saveCalibration(CalibrationStored())
        #expect(storage.object(forKey: CalibrationStore.key) == nil)
        #expect(store.loadCalibration() == .none)
    }

    @Test("A write that is dropped, or cannot be read back, throws; so does a removal that is not made")
    func readBack() throws {
        let flaky = FlakyStorage()
        let store = CalibrationStore(defaults: flaky)
        flaky.set(mode: .droppingWrites)
        #expect(throws: CalibrationStoreError.notReadBack) { try store.saveCalibration(CalibrationStored(session: storedSession())) }
        flaky.set(mode: .failingReads)
        #expect(throws: CalibrationStoreError.notReadBack) { try store.saveCalibration(CalibrationStored(session: storedSession())) }
        flaky.set(mode: .working)
        try store.saveCalibration(CalibrationStored(session: storedSession()))
        flaky.set(mode: .droppingWrites)
        #expect(throws: CalibrationStoreError.notRemoved) { try store.saveCalibration(CalibrationStored()) }
    }

    @Test("A value that is not a calibration record is unusable, never none")
    func unusable() throws {
        storage.set("text", forKey: CalibrationStore.key)
        #expect(store.loadCalibration() == .unusable(reason: "it is not a calibration record"))
        storage.set(Data("{".utf8), forKey: CalibrationStore.key)
        #expect(store.loadCalibration() == .unusable(reason: "it could not be read"))
        storage.set(Data(#"{"session":{"id":"x"}}"#.utf8), forKey: CalibrationStore.key)
        #expect(store.loadCalibration() == .unusable(reason: "it could not be read"))
        // Unknown keys are ignored.
        storage.set(Data(#"{"later":1}"#.utf8), forKey: CalibrationStore.key)
        #expect(store.loadCalibration() == .stored(CalibrationStored()))
    }

    @Test("Values out of range make a stored session unusable")
    func invalidValues() throws {
        func load(_ change: (inout CalibrationSession) -> Void) throws -> CalibrationLoad {
            var session = storedSession()
            change(&session)
            let data = try JSONEncoder().encode(CalibrationStored(session: session))
            storage.set(data, forKey: CalibrationStore.key)
            return store.loadCalibration()
        }
        #expect(try load { $0.ownerLimit = 77 } == .unusable(reason: "its record of your own Charge Limit is not valid"))
        #expect(try load { $0.cellKeeperLimit = 101 } == .unusable(reason: "its record of CellKeeper's limit is not valid"))
        #expect(try load { $0.step = .drain } == .unusable(reason: "its steps are not valid"))
        #expect(try load {
            $0.step = .restAtBottom
            $0.steps.append(CalibrationStepEntry(step: .restAtBottom, enteredAt: started.wall))
        } == .unusable(reason: "its rest has no time to plug in again"))
        #expect(try load {
            $0.lastRestReading = CalibrationReading(at: started.wall, percent: 101, powerSource: .battery)
        } == .unusable(reason: "its battery readings are not valid"))
        // A non-finite time cannot even be written.
        var broken = storedSession()
        broken.stepStartedAt.monotonic = .infinity
        #expect(throws: (any Error).self) { try store.saveCalibration(CalibrationStored(session: broken)) }
    }
}
