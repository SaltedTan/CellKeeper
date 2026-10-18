import CellKeeperKit
import Foundation
import Testing

@Suite("Diagnostics report file")
struct DiagnosticsReportFileTests {
    @Test("The suggested name is the local date and time to the minute", arguments: [
        ("2026-10-18T14:32:59Z", "UTC", "CellKeeper Diagnostics 2026-10-18 1432.txt"),
        ("2027-01-05T09:07:00Z", "UTC", "CellKeeper Diagnostics 2027-01-05 0907.txt"),
        // The local day can differ from the report's "Generated" time, which
        // is in UTC.
        ("2026-10-18T22:30:00Z", "Asia/Singapore", "CellKeeper Diagnostics 2026-10-19 0630.txt"),
        ("2026-10-18T22:30:00Z", "America/Los_Angeles", "CellKeeper Diagnostics 2026-10-18 1530.txt"),
    ])
    func suggestedName(instant: String, timeZone: String, expected: String) throws {
        let date = try Date(instant, strategy: .iso8601)
        let zone = try #require(TimeZone(identifier: timeZone))
        #expect(DiagnosticsReportFile.suggestedName(for: date, timeZone: zone) == expected)
    }

    /// A fresh temporary directory, removed afterwards.
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellKeeperKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("The file holds exactly the report, as UTF-8")
    func contents() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("report.txt")
            let report = "CellKeeper diagnostics\nPause at 35 °C\nSystem Settings › Battery, “Charging”\n"
            try DiagnosticsReportFile.write(report, to: url)
            #expect(try Data(contentsOf: url) == Data(report.utf8))
        }
    }

    @Test("Saving over a file rewrites that file in place and leaves nothing of the old content")
    func replacesInPlace() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("report.txt")
            try Data(String(repeating: "old report line\n", count: 100).utf8).write(to: url)
            let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
            try DiagnosticsReportFile.write("new report\n", to: url)
            #expect(try String(contentsOf: url, encoding: .utf8) == "new report\n")
            // The same file: no temporary copy was written and renamed over it.
            let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
            #expect(before != nil && after == before)
        }
    }

    @Test("A failed save throws and creates nothing")
    func failure() throws {
        try withDirectory { directory in
            let missing = directory.appendingPathComponent("missing", isDirectory: true)
            #expect(throws: (any Error).self) {
                try DiagnosticsReportFile.write("report\n", to: missing.appendingPathComponent("report.txt"))
            }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }
}
