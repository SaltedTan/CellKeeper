import CellKeeperCore
import Foundation

public enum ShortcutsCommandError: Error, Sendable, Equatable, CustomStringConvertible {
    case failed(command: String, message: String)

    public var description: String {
        switch self {
        case .failed(let command, let message): "shortcuts \(command) failed: \(message)"
        }
    }
}

/// Runs the user's shortcuts with Apple's documented `shortcuts`
/// command-line tool (shortcuts(1); "Run shortcuts from the command line" in
/// the Shortcuts User Guide). It exits 0 on a successful run and 1 on error.
///
/// Verified on macOS 27.0.1 from inside the App Sandbox (research note 08):
/// the tool can be launched without extra entitlements, and the shortcut
/// itself runs in Shortcuts' own process. Input is passed as a text file:
/// the same value piped through standard input ran without error but did not
/// change the Charge Limit.
public struct ShortcutsCommandRunner: ShortcutRunning {
    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    /// A shortcut that asks a question waits for an answer; stop waiting
    /// after this long and treat the run as failed.
    public static let runTimeout: TimeInterval = 20
    public static let listTimeout: TimeInterval = 10

    public let executable: URL

    public init(executable: URL = ShortcutsCommandRunner.defaultExecutable) {
        self.executable = executable
    }

    public func shortcutNames() async throws -> [String] {
        let result = try await ProcessRunner.run(executable, arguments: ["list"], timeout: Self.listTimeout)
        guard result.status == 0 else {
            throw ShortcutsCommandError.failed(command: "list", message: result.errorSummary)
        }
        return result.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
    }

    public func runShortcut(named name: String, input: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellKeeper-shortcut-input", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        try Data(input.utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await ProcessRunner.run(executable, arguments: ["run", name, "-i", file.path], timeout: Self.runTimeout)
        guard result.status == 0 else {
            throw ShortcutsCommandError.failed(command: "run", message: result.errorSummary)
        }
    }
}
