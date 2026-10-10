import CellKeeperHelperCore
import Foundation
import os

/// Removes CellKeeper's helper daemon only after the helper itself has
/// confirmed that it restored defaults (safety precondition 9, research
/// rule R4).
///
/// The flow (``remove()``):
/// 1. Read the registration. No helper registered (`notRegistered`,
///    `notFound`): nothing to remove, and no helper is contacted.
/// 2. Otherwise connect, say `hello`, and ask the helper to
///    `restoreDefaultsAndExit`. Only a reply of `ok` confirms defaults: the
///    engine replies `hardwareError` when its restore did not read back
///    clean, and keeps retrying it. A helper that refuses `hello` still gets
///    the request, because restores need no introduction.
/// 3. Only after `ok`: unregister, then read the registration again. The
///    helper counts as removed only if it is then `notRegistered` or
///    `notFound`.
/// 4. A helper that answered but did not confirm defaults is never
///    unregistered, also with `force`: unregistering terminates the daemon,
///    which is the one process still retrying the restore.
/// 5. A helper that cannot be reached at all (the connection, or `hello`,
///    failed or did not answer in time) is not unregistered either, unless
///    the caller passes ``HelperRemovalForce`` to ``remove(force:)``: the
///    user has seen the recovery procedure and wants the helper removed
///    although its restore could not be confirmed. An unreachable helper can
///    be broken in a way that would block its removal forever, and
///    unregistering terminates a running daemon, whose SIGTERM path restores
///    defaults itself (D31). What remains is a mechanism whose state
///    outlives the helper, which is what the recovery procedure covers.
///
/// Every step has a deadline: ``helperDeadline`` for the whole
/// conversation with the helper (connecting, `hello` and the restore; the
/// NSXPC transport also times out each request on its own), and
/// ``registrationDeadline`` for each call to the registration. A helper
/// whose reply has not arrived when the deadline passes is treated as not
/// confirmed, and nothing is unregistered, even if it confirms later; a
/// helper whose `hello` had not arrived by then counts as unreachable, and
/// is not asked to exit afterwards. The flow ignores the caller's
/// cancellation, so it always finishes within its deadlines and reports
/// what happened.
///
/// The outcome (``HelperRemovalOutcome``) states only what was confirmed:
/// no case says defaults were restored unless the helper replied `ok`.
public struct HelperRemoval: Sendable {
    /// The default bound on the conversation with the helper: connecting,
    /// `hello` and `restoreDefaultsAndExit`, together. Two NSXPC requests at
    /// their own 10 s timeout fit in it.
    public static let defaultHelperDeadline: Duration = .seconds(20)
    /// The default bound on each call to the registration. Unregistering
    /// terminates a running daemon; whether `SMAppService` waits for it to
    /// exit is unverified (phase 4b), so this exceeds launchd's 10 s
    /// `ExitTimeOut` for the helper.
    public static let defaultRegistrationDeadline: Duration = .seconds(15)
    /// The title of the recovery procedure in `docs/safety.md`, which the
    /// outcomes refer to.
    public static let recoveryProcedureTitle = "Recovery if charging does not resume"

    public let transport: any HelperTransport
    public let registration: any HelperRegistration
    public let helperDeadline: Duration
    public let registrationDeadline: Duration

    public init(
        transport: any HelperTransport,
        registration: any HelperRegistration,
        helperDeadline: Duration = HelperRemoval.defaultHelperDeadline,
        registrationDeadline: Duration = HelperRemoval.defaultRegistrationDeadline
    ) {
        self.transport = transport
        self.registration = registration
        self.helperDeadline = helperDeadline
        self.registrationDeadline = registrationDeadline
    }

    /// Removes the helper if, and only if, it confirms that it restored
    /// defaults. Never unregisters a helper that did not confirm, including
    /// one that cannot be reached.
    public func remove() async -> HelperRemovalOutcome {
        await runDetached(force: nil)
    }

    /// As ``remove()``, but a helper that cannot be reached at all is
    /// unregistered anyway, and the outcome says that its restore was not
    /// confirmed. A helper that answers but does not confirm defaults is
    /// still never unregistered.
    public func remove(force: HelperRemovalForce) async -> HelperRemovalOutcome {
        await runDetached(force: force)
    }

    /// The registration as the system reports it, or
    /// ``HelperRegistrationStatus/unknown(_:)`` if it did not answer within
    /// ``registrationDeadline``.
    public func registrationStatus() async -> HelperRegistrationStatus {
        let registration = registration
        return await Self.withDeadline(registrationDeadline) { await registration.status() }
            ?? .unknown("no answer within \(Self.describe(registrationDeadline))")
    }

    // MARK: - The flow

    /// Runs the flow in a task of its own, so the caller's cancellation
    /// cannot interrupt it between a confirmed restore and the unregistering.
    private func runDetached(force: HelperRemovalForce?) async -> HelperRemovalOutcome {
        let removal = self
        return await Task { await removal.run(force: force) }.value
    }

    private func run(force: HelperRemovalForce?) async -> HelperRemovalOutcome {
        let before = await registrationStatus()
        guard !before.meansNoHelperRegistered else {
            return logged(.nothingToRemove(before))
        }
        CellKeeperLog.safety.notice("Helper removal: registration is \(before.description, privacy: .public); asking the helper to restore defaults and exit.")
        switch await askHelperToRestoreAndExit() {
        case .confirmed(let helper):
            let unregistering = await unregisterAndCheck()
            if unregistering.status.meansNoHelperRegistered {
                return logged(.removed(helper))
            }
            return logged(.unregisterIncomplete(helper, status: unregistering.status, error: unregistering.error))
        case .notConfirmed(let failure, let helper):
            return logged(.restoreNotConfirmed(failure, helper: helper))
        case .unreachable(let reason):
            guard force != nil else {
                return logged(.helperUnreachable(reason))
            }
            CellKeeperLog.safety.error("Helper removal: the helper cannot be reached (\(reason.description, privacy: .public)); unregistering it anyway at the user's request.")
            let unregistering = await unregisterAndCheck()
            if unregistering.status.meansNoHelperRegistered {
                return logged(.removedWithoutConfirmedRestore(reason))
            }
            return logged(.forcedUnregisterIncomplete(reason, status: unregistering.status, error: unregistering.error))
        }
    }

    private func logged(_ outcome: HelperRemovalOutcome) -> HelperRemovalOutcome {
        let level: OSLogType = switch outcome {
        case .nothingToRemove, .removed: .default
        case .unregisterIncomplete, .restoreNotConfirmed, .helperUnreachable, .removedWithoutConfirmedRestore, .forcedUnregisterIncomplete: .error
        }
        CellKeeperLog.safety.log(level: level, "Helper removal: \(outcome.summary, privacy: .public)")
        return outcome
    }

    /// Unregisters within ``registrationDeadline``, then reads the
    /// registration again. `error` describes a failed or unanswered
    /// unregistering; the status alone decides whether the helper is gone.
    private func unregisterAndCheck() async -> (status: HelperRegistrationStatus, error: String?) {
        let registration = registration
        let answer = await Self.withDeadline(registrationDeadline) { () async -> String? in
            do {
                try await registration.unregister()
                return nil
            } catch {
                return String(describing: error)
            }
        }
        let error: String? = switch answer {
        case .some(let failure): failure
        case .none: "no answer within \(Self.describe(registrationDeadline))"
        }
        return (await registrationStatus(), error)
    }

    /// What the conversation with the helper established.
    private enum Conversation: Sendable {
        case confirmed(HelperKind)
        case notConfirmed(HelperRestoreFailure, HelperKind)
        case unreachable(HelperUnreachableReason)
    }

    /// Connects, says hello, and asks the helper to restore defaults and
    /// exit, all within ``helperDeadline``.
    private func askHelperToRestoreAndExit() async -> Conversation {
        let progress = ConversationProgress()
        let transport = transport
        if let finished = await Self.withDeadline(helperDeadline, { await Self.converse(with: transport, progress: progress) }) {
            return finished
        }
        // The deadline passed first. A reply that has arrived by now (the
        // connection was still being closed) counts; a later one is ignored.
        let seen = progress.snapshot
        guard let hello = seen.hello else {
            return .unreachable(.noAnswer(helperDeadline))
        }
        let helper = HelperKind(hello: hello)
        switch seen.restore {
        case .ok?: return .confirmed(helper)
        case let status?: return .notConfirmed(.refused(status), helper)
        case nil: return .notConfirmed(.noReply(helperDeadline), helper)
        }
    }

    private static func converse(with transport: any HelperTransport, progress: ConversationProgress) async -> Conversation {
        let connection: any HelperConnection
        do {
            connection = try await transport.connect()
        } catch {
            return .unreachable(.connectFailed(String(describing: error)))
        }
        let hello: HelperHelloReply
        do {
            hello = try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current)
        } catch {
            await connection.invalidate()
            return .unreachable(.helloFailed(String(describing: error)))
        }
        progress.record(hello: hello)
        let helper = HelperKind(hello: hello)
        guard !Task.isCancelled else {
            // Only the deadline cancels this task: the outcome has been
            // reported, and this result is dropped. The helper is not asked
            // to exit after that.
            await connection.invalidate()
            return .notConfirmed(.noReply(.zero), helper)
        }
        let status: HelperStatus
        do {
            status = try await connection.restoreDefaultsAndExit()
        } catch {
            await connection.invalidate()
            return .notConfirmed(.connectionFailed(String(describing: error)), helper)
        }
        progress.record(restore: status)
        await connection.invalidate()
        return status == .ok ? .confirmed(helper) : .notConfirmed(.refused(status), helper)
    }

    // MARK: - Deadlines

    /// Runs `operation` in a task of its own and returns its result, or nil
    /// if `deadline` passes first. The operation is then cancelled but not
    /// awaited: a call stuck in a transport keeps running on its own, and
    /// its result is dropped.
    static func withDeadline<T: Sendable>(_ deadline: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let race = FirstResult<T>()
        return await withCheckedContinuation { continuation in
            race.install(continuation)
            race.attach(Task { race.finish(await operation()) })
            race.attach(Task {
                try? await Task.sleep(for: deadline)
                race.finish(nil)
            })
        }
    }

    static func describe(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        if attoseconds == 0 {
            return "\(seconds) s"
        }
        return "\(Double(seconds) + Double(attoseconds) / 1e18) s"
    }
}

/// Consent to unregister a helper that could not be reached, so that its
/// restore of defaults could not be confirmed. See
/// ``HelperRemoval/remove(force:)``.
public enum HelperRemovalForce: Sendable, Equatable {
    /// The user has seen the recovery procedure ("Recovery if charging does
    /// not resume" in `docs/safety.md`) and wants the helper removed
    /// although its restore could not be confirmed.
    case userHasSeenRecoveryProcedure
}

/// What kind of helper answered, from its `hello`.
public enum HelperKind: Sendable, Equatable, CustomStringConvertible {
    /// Its control is simulated: nothing on the Mac changes (the Simulated
    /// helper).
    case simulated
    /// It reports no capabilities: it controls no charging on this Mac (the
    /// daemon of this phase, which runs `UnknownHardwareChargeControl`).
    case monitorOnly
    /// It reports at least one control of this Mac's charging.
    case controlsCharging
    /// It did not complete `hello`, so it did not say.
    case unknown

    init(hello: HelperHelloReply) {
        if hello.isSimulated {
            // Only a started helper whose control said so reports it.
            self = .simulated
        } else if hello.status != .ok {
            self = .unknown
        } else {
            self = hello.capabilities.isEmpty ? .monitorOnly : .controlsCharging
        }
    }

    public var description: String {
        switch self {
        case .simulated: "simulated"
        case .monitorOnly: "monitor-only"
        case .controlsCharging: "controls charging"
        case .unknown: "unknown"
        }
    }
}

/// Why a helper that answered did not confirm that it restored defaults.
public enum HelperRestoreFailure: Sendable, Equatable, CustomStringConvertible {
    /// It answered `restoreDefaultsAndExit` with this status instead of
    /// `ok`. The engine replies `hardwareError` when its restore did not
    /// read back clean (it keeps retrying it), `notIntroduced` when the
    /// session no longer existed (invalidated or revoked), and `rateLimited`
    /// when this request revoked the session for exceeding its request
    /// budget; restores are served before start and during shutdown, so
    /// `notReady` and `shuttingDown` do not occur. Any other status is
    /// reported as it is.
    case refused(HelperStatus)
    /// The connection failed after `hello`, before the reply arrived (for
    /// example, the helper crashed).
    case connectionFailed(String)
    /// No reply within the deadline.
    case noReply(Duration)

    public var description: String {
        switch self {
        case .refused(let status): "the helper replied \(status)"
        case .connectionFailed(let detail): "the connection failed: \(detail)"
        case .noReply(let deadline): "no reply within \(HelperRemoval.describe(deadline))"
        }
    }
}

/// Why the helper could not be reached at all.
public enum HelperUnreachableReason: Sendable, Equatable, CustomStringConvertible {
    /// Opening the connection failed.
    case connectFailed(String)
    /// The connection failed before the helper answered `hello` (over NSXPC,
    /// the first request is where a helper that cannot be reached shows).
    case helloFailed(String)
    /// No answer to `hello` within the deadline.
    case noAnswer(Duration)

    public var description: String {
        switch self {
        case .connectFailed(let detail): "the connection could not be opened: \(detail)"
        case .helloFailed(let detail): "the connection failed: \(detail)"
        case .noAnswer(let deadline): "no answer within \(HelperRemoval.describe(deadline))"
        }
    }
}

/// The result of ``HelperRemoval``. Each case states only what was
/// confirmed.
public enum HelperRemovalOutcome: Sendable, Equatable {
    /// The system reports no helper registered; no helper was contacted and
    /// nothing was changed.
    case nothingToRemove(HelperRegistrationStatus)
    /// The helper replied `ok` to `restoreDefaultsAndExit`, was unregistered,
    /// and the system no longer reports it registered.
    case removed(HelperKind)
    /// The helper replied `ok`, but unregistering did not complete: the
    /// system still reports `status`; `error` describes a failed or
    /// unanswered unregistering.
    case unregisterIncomplete(HelperKind, status: HelperRegistrationStatus, error: String?)
    /// The helper answered but did not confirm that it restored defaults,
    /// so it was not unregistered.
    case restoreNotConfirmed(HelperRestoreFailure, helper: HelperKind)
    /// The helper could not be reached, so nothing was confirmed and it was
    /// not unregistered. ``HelperRemoval/remove(force:)`` can remove it.
    case helperUnreachable(HelperUnreachableReason)
    /// Forced: the helper could not be reached, so its restore was not
    /// confirmed; it was unregistered, and the system no longer reports it
    /// registered.
    case removedWithoutConfirmedRestore(HelperUnreachableReason)
    /// Forced: the helper could not be reached, and unregistering it did not
    /// complete either: the system still reports `status`.
    case forcedUnregisterIncomplete(HelperUnreachableReason, status: HelperRegistrationStatus, error: String?)

    /// True only if the helper replied `ok` to `restoreDefaultsAndExit`.
    public var isRestoreConfirmed: Bool {
        switch self {
        case .removed, .unregisterIncomplete: true
        case .nothingToRemove, .restoreNotConfirmed, .helperUnreachable, .removedWithoutConfirmedRestore, .forcedUnregisterIncomplete: false
        }
    }

    /// True if the system no longer reports the helper registered after
    /// CellKeeper unregistered it.
    public var isHelperRemoved: Bool {
        switch self {
        case .removed, .removedWithoutConfirmedRestore: true
        case .nothingToRemove, .unregisterIncomplete, .restoreNotConfirmed, .helperUnreachable, .forcedUnregisterIncomplete: false
        }
    }

    /// True if ``HelperRemoval/remove(force:)`` may remove the helper
    /// although its restore cannot be confirmed: only when it could not be
    /// reached at all.
    public var offersForcedRemoval: Bool {
        if case .helperUnreachable = self { return true }
        return false
    }

    /// One honest paragraph for the user and the log.
    public var summary: String {
        let recovery = "If charging does not resume, follow \"\(HelperRemoval.recoveryProcedureTitle)\" in CellKeeper's safety documentation."
        switch self {
        case .nothingToRemove(let status):
            return "No helper is installed (the system reports it \(status)), so there is nothing to remove."
        case .removed(let helper):
            return "\(helper.confirmedRestore) The helper was then unregistered, and the system no longer reports it registered."
        case .unregisterIncomplete(let helper, let status, let error):
            return "\(helper.confirmedRestore) Unregistering the helper did not complete: the system still reports it \(status)\(Self.detail(error)). Try again, or turn off CellKeeper's background item in System Settings › General › Login Items & Extensions."
        case .restoreNotConfirmed(let failure, let helper):
            return "The helper did not confirm that it restored defaults (\(failure)), so CellKeeper did not remove it: it is the process that keeps retrying the restore, and removing it would stop that.\(helper.simulatedNote) Try again later. \(recovery)"
        case .helperUnreachable(let reason):
            return "CellKeeper could not reach the helper (\(reason)), so nothing confirms that the helper restored defaults, and CellKeeper did not remove it. \(recovery) Once you have read it, you can remove the helper anyway."
        case .removedWithoutConfirmedRestore(let reason):
            return "The helper could not be reached (\(reason)), so its restore of defaults was not confirmed. At your request CellKeeper unregistered it anyway, and the system no longer reports it registered. Unregistering stops a running helper, which is designed to restore defaults as it exits, but nothing confirmed that. \(recovery)"
        case .forcedUnregisterIncomplete(let reason, let status, let error):
            return "The helper could not be reached (\(reason)), so its restore of defaults was not confirmed. At your request CellKeeper tried to unregister it anyway, but that did not complete: the system still reports it \(status)\(Self.detail(error)). \(recovery)"
        }
    }

    private static func detail(_ error: String?) -> String {
        error.map { " (\($0))" } ?? ""
    }
}

/// The result of ``ChargeController/removeHelper(using:)``: CellKeeper's
/// own state first, then the helper. Each case states only what was
/// confirmed.
public enum HelperUninstallOutcome: Sendable, Equatable {
    /// The system reports no helper registered: nothing was restored,
    /// contacted or removed.
    case nothingToRemove(HelperRegistrationStatus)
    /// Normal charging could not be confirmed on CellKeeper's current
    /// backend (named), so the helper was not contacted and nothing was
    /// removed.
    case normalChargingNotConfirmed(backend: String)
    /// The controller has shut down (CellKeeper is quitting): nothing was
    /// contacted or removed.
    case controllerShutDown
    /// Normal charging was confirmed on CellKeeper's current backend; then
    /// the helper removal ran, with this outcome.
    case helperRemoval(HelperRemovalOutcome)

    /// One honest paragraph for the user and the log.
    public var summary: String {
        switch self {
        case .nothingToRemove(let status):
            "No helper is installed (the system reports it \(status)), so there is nothing to remove. CellKeeper's charging was left as it is."
        case .normalChargingNotConfirmed(let backend):
            "CellKeeper could not confirm normal charging on \(backend), so it did not contact the helper and removed nothing. The activity log says why; try again once normal charging is confirmed."
        case .controllerShutDown:
            "CellKeeper is quitting, so it did not contact the helper and removed nothing."
        case .helperRemoval(let outcome):
            "CellKeeper first confirmed normal charging on its current backend. " + outcome.summary
        }
    }
}

extension HelperKind {
    /// What a reply of `ok` to `restoreDefaultsAndExit` established.
    var confirmedRestore: String {
        switch self {
        case .simulated:
            "The Simulated helper restored its simulated controls to their defaults and confirmed it. Your Mac's charging was not changed: the helper's controls are simulated."
        case .monitorOnly:
            "The helper controls no charging on this Mac. It confirmed that none of its controls is active; it changed nothing."
        case .controlsCharging:
            "The helper restored macOS's default charging and confirmed it by reading its controls back."
        case .unknown:
            "The helper confirmed that its controls are back at their defaults."
        }
    }

    /// For outcomes without a confirmed restore.
    var simulatedNote: String {
        self == .simulated ? " Its controls are simulated, so your Mac's charging is not affected." : ""
    }
}

/// What the helper has answered so far, readable when the deadline passes.
private final class ConversationProgress: @unchecked Sendable {
    struct Seen {
        var hello: HelperHelloReply?
        var restore: HelperStatus?
    }

    private let lock = NSLock()
    private var seen = Seen()

    var snapshot: Seen {
        lock.withLock { seen }
    }

    func record(hello: HelperHelloReply) {
        lock.withLock { seen.hello = hello }
    }

    func record(restore: HelperStatus) {
        lock.withLock { seen.restore = restore }
    }
}

/// The first of several tasks to finish resumes one continuation; the
/// others are cancelled.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var isFinished = false
    private var tasks: [Task<Void, Never>] = []

    /// Called once, before any task that may finish is started.
    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Cancels `task` once the race is decided, or at once if it already is.
    func attach(_ task: Task<Void, Never>) {
        let isDecided = lock.withLock {
            if !isFinished {
                tasks.append(task)
            }
            return isFinished
        }
        if isDecided {
            task.cancel()
        }
    }

    /// The first call resumes the continuation with `value`; later calls do
    /// nothing.
    func finish(_ value: T?) {
        var winner: CheckedContinuation<T?, Never>?
        var losers: [Task<Void, Never>] = []
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            winner = continuation
            losers = tasks
            continuation = nil
            tasks = []
        }
        for task in losers {
            task.cancel()
        }
        winner?.resume(returning: value)
    }
}
