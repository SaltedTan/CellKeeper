import Foundation

/// The diagnostics report saved as a file (Settings › Activity › Save
/// Diagnostics…): plain UTF-8 text, written only to the file the user chose
/// in a save panel.
public enum DiagnosticsReportFile {
    /// The name the save panel suggests, for example
    /// "CellKeeper Diagnostics 2026-10-18 1432.txt": the local date and time
    /// to the minute, in the Gregorian calendar with ASCII digits whatever
    /// the user's locale, and nothing else. It has no colon, which Finder
    /// shows as a slash.
    public static func suggestedName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func digits(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let day = "\(digits(parts.year, 4))-\(digits(parts.month, 2))-\(digits(parts.day, 2))"
        return "CellKeeper Diagnostics \(day) \(digits(parts.hour, 2))\(digits(parts.minute, 2)).txt"
    }

    /// Writes `report` as UTF-8, without a byte order mark, to `url`,
    /// replacing the file there.
    ///
    /// The write goes straight to that file, so nothing is written anywhere
    /// else. An atomic write would first write a temporary copy elsewhere:
    /// inside the App Sandbox, Foundation puts it in an item replacement
    /// directory it creates on the destination's volume (swift-foundation,
    /// `Data+Writing.swift`). In exchange, a write that fails part of the
    /// way can leave an incomplete file; it throws.
    public static func write(_ report: String, to url: URL) throws {
        try Data(report.utf8).write(to: url)
    }
}
