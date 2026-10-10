@testable import CellKeeperHelperDaemon
import CellKeeperHelperCore
import Foundation
import Testing

/// The repository's root, found from this file.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // CellKeeperHelperDaemonTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // CellKeeperKit
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent()

@Suite("Helper daemon: launchd property list and build")
struct HelperDaemonPropertyListTests {
    private func propertyList() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("Config/LaunchDaemons/\(HelperServiceName.label).plist")
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("The property list's label, Mach service and ExitTimeOut match the code")
    func matchesCode() throws {
        let plist = try propertyList()
        #expect(plist["Label"] as? String == HelperServiceName.label)
        let machServices = try #require(plist["MachServices"] as? [String: Any])
        #expect(Array(machServices.keys) == [HelperServiceName.machService])
        #expect(machServices[HelperServiceName.machService] as? Bool == true)
        #expect(plist["ExitTimeOut"] as? Int == Int(HelperDaemon.exitTimeout))
        #expect(HelperDaemon.terminationDeadline < HelperDaemon.exitTimeout)
    }

    @Test("The property list holds exactly the agreed keys")
    func keys() throws {
        let plist = try propertyList()
        #expect(Set(plist.keys) == ["Label", "BundleProgram", "MachServices", "KeepAlive", "ProcessType", "ExitTimeOut", "AssociatedBundleIdentifiers"])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/CellKeeperHelper")
        let keepAlive = try #require(plist["KeepAlive"] as? [String: Bool])
        #expect(keepAlive == ["SuccessfulExit": false, "Crashed": true])
        #expect(plist["ProcessType"] as? String == "Adaptive")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["io.github.saltedtan.CellKeeper"])
        // No SpawnConstraint until signing (phase 4b): it needs a team ID.
        #expect(plist["SpawnConstraint"] == nil)
    }

    @Test("The daemon's build number is the app's")
    func buildNumber() throws {
        let settings = try String(contentsOf: repositoryRoot.appendingPathComponent("Config/CellKeeper.xcconfig"), encoding: .utf8)
        let line = try #require(settings.split(separator: "\n").first { $0.hasPrefix("CURRENT_PROJECT_VERSION") })
        let value = try #require(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces))
        #expect(Int(value) == HelperBuild.number)
    }
}
