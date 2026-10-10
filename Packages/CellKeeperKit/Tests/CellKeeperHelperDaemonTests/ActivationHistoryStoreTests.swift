@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

@Suite("Activation history file")
struct ActivationHistoryStoreTests {
    /// A store in a fresh temporary directory, removed afterwards.
    private func withStore(_ body: (FileActivationHistoryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellKeeperHelperDaemonTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Helper/activation-history.json")
        try body(FileActivationHistoryStore(url: url), url)
    }

    private func records(_ count: Int, from start: TimeInterval = 1_000) -> [HelperActivationRecord] {
        (0..<count).map {
            HelperActivationRecord(control: $0.isMultiple(of: 2) ? .chargingInhibited : .adapterDisabled, uptime: start + Double($0) * 61)
        }
    }

    @Test("Saved records load back in the same boot")
    func roundTrip() throws {
        try withStore { store, url in
            #expect(store.load(boot: .testBoot, now: 5_000) == .missing)
            let saved = records(3)
            try store.save(saved, boot: .testBoot)
            #expect(store.load(boot: .testBoot, now: 5_000) == .loaded(saved))
            // Saving replaces the history and leaves no temporary file.
            try store.save(Array(saved.prefix(1)), boot: .testBoot)
            #expect(store.load(boot: .testBoot, now: 5_000) == .loaded(Array(saved.prefix(1))))
            let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            #expect(files == ["activation-history.json"])
        }
    }

    @Test("A history saved in another boot is discarded")
    func otherBoot() throws {
        try withStore { store, _ in
            try store.save(records(2), boot: .testBoot)
            #expect(store.load(boot: .otherBoot, now: 5_000) == .discarded(.otherBoot))
        }
    }

    @Test("A file larger than 64 KiB is refused unread")
    func oversized() throws {
        try withStore { store, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A valid history, padded with whitespace past the limit.
            var data = try ActivationHistoryFormat.encode(records(1), boot: .testBoot)
            data.append(Data(repeating: UInt8(ascii: " "), count: ActivationHistoryFormat.maximumSize))
            try data.write(to: url)
            #expect(store.load(boot: .testBoot, now: 5_000) == .discarded(.tooLarge))
        }
    }

    @Test("A corrupt or unexpected file is ignored", arguments: [
        "not json",
        "{}",
        // Version 1 keyed the history by kern.boottime.
        #"{"version":1,"boot":{"seconds":1790000000,"microseconds":123456},"records":[]}"#,
        #"{"version":3,"boot":{"sessionUUID":"6F2B1C3E-0A4D-4E5F-9A8B-1C2D3E4F5A6B"},"records":[]}"#,
        #"{"version":2,"boot":{"sessionUUID":"not a UUID"},"records":[]}"#,
        #"{"version":2,"boot":{"sessionUUID":"6F2B1C3E-0A4D-4E5F-9A8B-1C2D3E4F5A6B"},"records":[{"control":9,"uptime":10}]}"#,
        #"{"version":2,"boot":{"sessionUUID":"6F2B1C3E-0A4D-4E5F-9A8B-1C2D3E4F5A6B"},"records":[{"control":1}]}"#,
    ])
    func corrupt(contents: String) throws {
        try withStore { store, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            #expect(store.load(boot: .testBoot, now: 5_000) == .discarded(.corrupt))
        }
    }

    @Test("A record with an impossible time discards the history", arguments: [-1.0, 5_001.0])
    func implausible(uptime: Double) throws {
        try withStore { store, _ in
            try store.save(records(2) + [HelperActivationRecord(control: .chargingInhibited, uptime: uptime)], boot: .testBoot)
            #expect(store.load(boot: .testBoot, now: 5_000) == .discarded(.implausible))
        }
    }

    @Test("Only the latest 20 records are saved, and only the latest 20 are loaded")
    func boundedTo20() throws {
        try withStore { store, url in
            let many = records(25)
            try store.save(many.reversed(), boot: .testBoot)
            #expect(store.load(boot: .testBoot, now: 5_000) == .loaded(Array(many.suffix(20))))

            // A file with more records than the daemon writes still yields
            // the latest 20.
            let snapshot = ActivationHistoryFormat.Snapshot(version: ActivationHistoryFormat.version, boot: .testBoot, records: many)
            try JSONEncoder().encode(snapshot).write(to: url)
            #expect(store.load(boot: .testBoot, now: 5_000) == .loaded(Array(many.suffix(20))))
        }
    }

    @Test("A symbolic link or a directory is not read")
    func notARegularFile() throws {
        try withStore { store, url in
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("elsewhere.json")
            try ActivationHistoryFormat.encode(records(1), boot: .testBoot).write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(store.load(boot: .testBoot, now: 5_000) == .discarded(.notARegularFile))

            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(store.load(boot: .testBoot, now: 5_000) == .discarded(.notARegularFile))
        }
    }

    @Test("A FIFO is refused at once, without waiting for a writer")
    func fifo() throws {
        try withStore { store, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(mkfifo(url.path, 0o600) == 0)
            // On a thread of its own, so that a load stuck in open(2) shows
            // as a failure instead of hanging the tests.
            let result = LoadResult()
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                result.set(store.load(boot: .testBoot, now: 5_000))
                done.signal()
            }
            let finished = done.wait(timeout: .now() + 5) == .success
            if !finished {
                // Give the stuck reader a writer, so its thread can end.
                let writer = open(url.path, O_WRONLY | O_NONBLOCK)
                if writer >= 0 { close(writer) }
                _ = done.wait(timeout: .now() + 5)
            }
            #expect(finished)
            #expect(result.value == .discarded(.notARegularFile))
        }
    }

    @Test("Saving where the daemon may not write throws, and loads nothing", .enabled(if: geteuid() != 0, "root may write anywhere"))
    func unwritable() throws {
        try withStore { _, url in
            let readOnly = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o555])
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
            let store = FileActivationHistoryStore(url: url)
            #expect(throws: (any Error).self) { try store.save(records(1), boot: .testBoot) }
            #expect(store.load(boot: .testBoot, now: 5_000) == .missing)
        }
    }

    @Test("The file is JSON with the boot session and the records; no wall-clock time")
    func format() throws {
        let data = try ActivationHistoryFormat.encode([HelperActivationRecord(control: .chargingInhibited, uptime: 12.5)], boot: .testBoot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"boot":{"sessionUUID":"6F2B1C3E-0A4D-4E5F-9A8B-1C2D3E4F5A6B"},"records":[{"control":1,"uptime":12.5}],"version":2}"#)
    }

    @Test("A history saved in this boot is kept whatever the wall clock says")
    func keptDespiteWallClock() throws {
        try withStore { store, url in
            let saved = records(2)
            try store.save(saved, boot: .testBoot)
            // Neither the file's dates nor the time of day take part.
            for date in [Date(timeIntervalSince1970: 0), Date(timeIntervalSinceNow: 10 * 365 * 86_400)] {
                try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                #expect(store.load(boot: .testBoot, now: 5_000) == .loaded(saved))
            }
            // Another boot session is another boot.
            #expect(store.load(boot: .otherBoot, now: 5_000) == .discarded(.otherBoot))
        }
    }

    @Test("This boot's identifier is kern.bootsessionuuid, a UUID, and stable")
    func bootIdentifier() throws {
        let boot = try #require(BootIdentifier.current())
        #expect(BootIdentifier.current() == boot)
        // The same value the sysctl tool reports (read-only).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "kern.bootsessionuuid"]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reported = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(BootIdentifier(sysctlValue: reported) == boot)
    }

    @Test("Only a UUID is a boot identifier", arguments: ["", "not a UUID", "1791289092", "{ sec = 1791289092, usec = 905426 }"])
    func notAUUID(text: String) {
        #expect(BootIdentifier(sysctlValue: text) == nil)
    }
}

/// The result of a load made on another thread.
final class LoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ActivationHistoryLoad?

    var value: ActivationHistoryLoad? {
        lock.withLock { result }
    }

    func set(_ value: ActivationHistoryLoad) {
        lock.withLock { result = value }
    }
}
