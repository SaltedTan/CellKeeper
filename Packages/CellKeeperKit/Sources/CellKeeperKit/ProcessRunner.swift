import Foundation

/// The outcome of a command-line tool that ran to completion.
struct ProcessResult: Sendable, Equatable {
    var status: Int32
    var standardOutput: String
    var standardError: String

    /// The first non-empty line of standard error, shortened, for messages.
    var errorSummary: String {
        let line = standardError.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "exit status \(status)" }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}

enum ProcessRunnerError: Error, Sendable, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case timedOut(seconds: Int)

    var description: String {
        switch self {
        case .launchFailed(let message): "could not be started (\(message))"
        case .timedOut(let seconds): "did not finish within \(seconds) s and was stopped"
        }
    }
}

/// Runs a command-line tool directly, never through a shell, with standard
/// input closed, a deadline, and bounded output capture.
enum ProcessRunner {
    /// Output beyond this many bytes per stream is discarded.
    static let outputLimit = 256 * 1024

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            // Waiting blocks a thread, so keep it off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments: arguments, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }

        // Drain both pipes while the tool runs, so a full pipe cannot stall it.
        let collected = CollectedOutput()
        let readers = DispatchGroup()
        for (handle, isError) in [(Unchecked(output.fileHandleForReading), false), (Unchecked(errors.fileHandleForReading), true)] {
            DispatchQueue.global(qos: .utility).async(group: readers) {
                collected.store(handle.value.readDataToEndOfFile(), isError: isError)
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            _ = readers.wait(timeout: .now() + 1)
            throw ProcessRunnerError.timedOut(seconds: Int(timeout.rounded(.up)))
        }
        // A descendant that inherited a pipe could hold it open; do not wait
        // for it indefinitely.
        _ = readers.wait(timeout: .now() + 2)
        return ProcessResult(status: process.terminationStatus, standardOutput: collected.output, standardError: collected.error)
    }
}

/// Output gathered from the reader threads.
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()

    func store(_ data: Data, isError: Bool) {
        let bounded = data.prefix(ProcessRunner.outputLimit)
        lock.withLock {
            if isError { errorData = bounded } else { outputData = bounded }
        }
    }

    var output: String { lock.withLock { String(decoding: outputData, as: UTF8.self) } }
    var error: String { lock.withLock { String(decoding: errorData, as: UTF8.self) } }
}

/// Carries a value that is only used by one thread at a time across a
/// concurrency boundary (older SDKs do not mark `FileHandle` as `Sendable`).
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
