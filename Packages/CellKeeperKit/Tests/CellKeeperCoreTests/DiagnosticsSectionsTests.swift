import CellKeeperCore
import Foundation
import Testing

/// The sections Settings › Diagnostics shows: the report's, with plain words
/// in place of identifiers.
@Suite("Diagnostics sections")
struct DiagnosticsSectionsTests {
    let environment = DiagnosticsFixture.environment

    /// Writes a moment as its offset from `referenceDate`, so a test sees
    /// which moment a value holds.
    static func offset(_ date: Date) -> String {
        "<\(Int(date.timeIntervalSince(referenceDate)))s>"
    }

    private func value(_ label: String, in title: String?, of sections: [DiagnosticsSection]) -> DiagnosticsValue? {
        sections.first { $0.title == title }?.rows.first { $0.label == label }?.value
    }

    private func plain(_ label: String, in title: String?, of sections: [DiagnosticsSection]) -> String? {
        value(label, in: title, of: sections)?.plainText(formattingTime: Self.offset)
    }

    @Test("The sections run from the app, macOS and the model to macOS Charge Limit, without the activity log")
    func titles() async {
        let simulated = DiagnosticsReport.sections(status: await DiagnosticsFixture.simulated(), environment: environment)
        #expect(simulated.map(\.title) == [nil, "Control", "Settings", "Battery", "Decision"])
        #expect(simulated.first?.rows.map(\.label) == ["App", "macOS", "Model"])
        let native = DiagnosticsReport.sections(status: await DiagnosticsFixture.nativeLimit(), environment: environment)
        #expect(native.map(\.title) == [nil, "Control", "Settings", "Battery", "Decision", "macOS Charge Limit"])
    }

    @Test("Plain text names backends, states, modes, power sources and charging statuses in words only; the report adds identifiers")
    func plainWords() async {
        let simulated = DiagnosticsReport.sections(status: await DiagnosticsFixture.simulated(), environment: environment)
        #expect(plain("Backend", in: "Control", of: simulated) == "Simulated")
        #expect(value("Backend", in: "Control", of: simulated)?.reportText == "Simulated (simulated)")
        #expect(plain("Style", in: "Control", of: simulated) == "switches charging, modes a discharge while plugged in, a charging pause, normal charging")
        #expect(plain("Reported mode", in: "Control", of: simulated) == "a charging pause")
        #expect(plain("Power source", in: "Battery", of: simulated) == "external power")
        #expect(plain("Charging status", in: "Battery", of: simulated) == "not charging")
        #expect(plain("State", in: "Decision", of: simulated) == "holding at the limit")
        #expect(value("State", in: "Decision", of: simulated)?.reportText == "holding at the limit (holding)")
        #expect(plain("Wants", in: "Decision", of: simulated) == "a charging pause")

        let native = DiagnosticsReport.sections(status: await DiagnosticsFixture.nativeLimit(), environment: environment)
        #expect(plain("Backend", in: "Control", of: native) == "macOS Charge Limit")
        #expect(plain("Reported mode", in: "Control", of: native) == "a macOS Charge Limit of 85%")
        #expect(value("Reported mode", in: "Control", of: native)?.reportText == "a macOS Charge Limit of 85% (nativeLimit(85%))")
    }

    @Test("Plain text writes moments as the caller formats them; the report writes ISO 8601")
    func moments() async throws {
        let simulated = DiagnosticsReport.sections(status: await DiagnosticsFixture.simulated(), environment: environment)
        #expect(plain("Last evaluation", in: "Decision", of: simulated) == "<60s>")
        #expect(value("Last evaluation", in: "Decision", of: simulated)?.reportText == "2027-01-15T08:01:00Z")
        #expect(plain("Driver updated", in: "Battery", of: simulated) == "<40s>")
        #expect(plain("Last action", in: "Decision", of: simulated) == "<60s> disable charging: simulated")

        let (armed, _) = try await DiagnosticsFixture.overrideAndSchedule()
        let sections = DiagnosticsReport.sections(status: armed, environment: environment)
        #expect(plain("Override", in: "Decision", of: sections) == "Temporary full charge, started <0s>, expires <43200s>")
        #expect(plain("Scheduled full charge", in: "Decision", of: sections) == "<3600s> to <10800s>")
    }

    @Test("In every fixture, each plain value is the report's value without its identifiers, with the caller's moments")
    func plainIsReportWithoutIdentifiers() async throws {
        let fixtures = try await DiagnosticsFixture.all()
        let modes = ["normal", "inhibitCharging", "forceDischarge"] + NativeChargeLimitBackend.supportedLimits.map { "nativeLimit(\($0)%)" }
        let vocabulary = modes + PolicyState.allCases.map(\.rawValue) + PowerSource.allCases.map(\.rawValue) + ChargingStatus.allCases.map(\.rawValue)
            + WeeklyFullChargeRecord.Result.allCases.map(\.rawValue) + ["notSaved", "notRemoved"]
        // Accepts both UTC ("Z") and an offset ("+01:00").
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        var withIdentifiers = 0
        var withMoments = 0
        var withOffsetMoments = 0
        for (name, status) in fixtures {
            let identifiers = vocabulary + [status.backend.identifier]
            for section in DiagnosticsReport.sections(status: status, environment: environment) {
                for row in section.rows {
                    let report = row.value.reportText
                    var words = report
                    for identifier in identifiers {
                        words = words.replacingOccurrences(of: " (\(identifier))", with: "")
                    }
                    if words != report { withIdentifiers += 1 }
                    let moments = words.matches(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)/)
                    withMoments += moments.isEmpty ? 0 : 1
                    withOffsetMoments += moments.contains { !words[$0.range].hasSuffix("Z") } ? 1 : 0
                    for moment in moments.reversed() {
                        let date = try #require(parser.date(from: String(words[moment.range])))
                        words.replaceSubrange(moment.range, with: Self.offset(date))
                    }
                    #expect(row.value.plainText(formattingTime: Self.offset) == words, "\(name), \(section.title ?? "top"): \(row.label)")
                }
            }
        }
        // Not vacuous: every status names its backend with an identifier,
        // and every evaluated one has a moment (at least the last
        // evaluation).
        #expect(withIdentifiers >= fixtures.count)
        #expect(withMoments >= fixtures.filter { $0.status.lastEvaluation != nil }.count)
        // The weekly rows' moments carry their UTC offset.
        #expect(withOffsetMoments >= 4)
    }

    @Test("Plain text does not name the macOS account either")
    func redactsAccountNames() async {
        let status = await DiagnosticsFixture.noTelemetry()
        #expect(status.telemetryError?.contains(DiagnosticsFixture.accountName) == true)
        let sections = DiagnosticsReport.sections(status: status, environment: environment)
        let telemetry = plain("Telemetry", in: "Battery", of: sections)
        #expect(telemetry?.contains("NSFilePath=/Users/<user>/Library/Containers/") == true)
        for row in sections.flatMap(\.rows) {
            #expect(!row.value.plainText(formattingTime: Self.offset).contains(DiagnosticsFixture.accountName))
            #expect(!row.value.reportText.contains(DiagnosticsFixture.accountName))
        }
    }
}
