import Foundation

/// The outcome of a command-line tool that ran to completion.
struct ProcessResult: Sendable, Equatable {
    var status: Int32
    var standardOutput: String
    var standardError: String
    /// False if output was cut off at ``ProcessRunner/outputLimit``, or if a
    /// stream was still open after the tool exited (a descendant may hold it).
    var isOutputComplete: Bool

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
/// input closed, a deadline, bounded output, and support for cancellation.
///
/// One thread polls both output streams and the process: at most
/// ``outputLimit`` bytes per stream are kept (the rest is read and
/// discarded), each poll reads a bounded amount so a flood of output cannot
/// delay the deadline or cancellation checks, the tool is stopped (SIGTERM,
/// then SIGKILL) at the deadline or when the calling task is cancelled, and
/// the runner never waits more than ``streamGracePeriod`` for streams a
/// descendant keeps open.
enum ProcessRunner {
    /// Output beyond this many bytes per stream is discarded.
    static let outputLimit = 256 * 1024
    /// After the tool exits, how long to wait for its output streams to close.
    static let streamGracePeriod: TimeInterval = 0.5
    /// After SIGTERM, how long before SIGKILL; after SIGKILL, how long before
    /// giving up waiting.
    static let stopGracePeriod: TimeInterval = 2

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Polling blocks a thread, so keep it off the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runBlocking(executable, arguments: arguments, timeout: timeout, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String], timeout: TimeInterval, cancellation: CancellationFlag) throws -> ProcessResult {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }

        let streams = [CapturedStream(output.fileHandleForReading), CapturedStream(errors.fileHandleForReading)]
        defer { streams.forEach { $0.close() } }
        let clock = { ProcessInfo.processInfo.systemUptime }
        let deadline = clock() + timeout
        var exitedAt: TimeInterval?
        var stopRequestedAt: TimeInterval?
        var killed = false
        var stoppedForCancellation = false

        while true {
            let now = clock()
            if exitedAt == nil, !process.isRunning {
                exitedAt = now
            }
            let open = streams.filter { !$0.isAtEnd }
            if let exited = exitedAt {
                if open.isEmpty || now - exited >= streamGracePeriod { break }
            } else if let requested = stopRequestedAt {
                if !killed, now - requested >= stopGracePeriod {
                    kill(process.processIdentifier, SIGKILL)
                    killed = true
                } else if killed, now - requested >= 2 * stopGracePeriod {
                    break
                }
            } else if cancellation.isCancelled || now >= deadline {
                stoppedForCancellation = cancellation.isCancelled
                process.terminate()
                stopRequestedAt = now
            }

            if open.isEmpty {
                usleep(20_000)
                continue
            }
            var descriptors = open.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
            _ = poll(&descriptors, nfds_t(descriptors.count), 50)
            for (stream, descriptor) in zip(open, descriptors) where descriptor.revents != 0 {
                stream.drain()
            }
        }

        if stopRequestedAt != nil {
            if stoppedForCancellation { throw CancellationError() }
            throw ProcessRunnerError.timedOut(seconds: Int(timeout.rounded(.up)))
        }
        if cancellation.isCancelled { throw CancellationError() }
        // A tool that finished after the deadline has not met it.
        if let exited = exitedAt, exited > deadline {
            throw ProcessRunnerError.timedOut(seconds: Int(timeout.rounded(.up)))
        }
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: streams[0].text,
            standardError: streams[1].text,
            isOutputComplete: streams.allSatisfy { $0.isAtEnd && !$0.isTruncated }
        )
    }
}

/// One output stream of the tool, read without blocking and kept up to
/// ``ProcessRunner/outputLimit`` bytes. Used by a single thread.
private final class CapturedStream {
    private let handle: FileHandle
    let descriptor: Int32
    private var data = Data()
    private(set) var isAtEnd = false
    private(set) var isTruncated = false

    init(_ handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    /// The most read from one stream in one poll.
    static let readsPerPoll = 4

    func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<Self.readsPerPoll where !isAtEnd {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let room = ProcessRunner.outputLimit - data.count
                if room > 0 {
                    data.append(contentsOf: buffer[0..<min(count, room)])
                }
                if count > room {
                    isTruncated = true
                }
            } else if count == 0 {
                isAtEnd = true
            } else if errno == EAGAIN || errno == EINTR {
                return
            } else {
                isAtEnd = true
                isTruncated = true
            }
        }
    }

    func close() {
        try? handle.close()
    }
}

/// Set from the cancellation handler, read by the polling thread.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
