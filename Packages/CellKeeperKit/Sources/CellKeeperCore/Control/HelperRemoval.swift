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
///    `restoreDefaultsAndExit`. Only a reply of `ok` confirms defaults. A
///    helper that refuses `hello` still gets the request, because the engine
///    serves restores without an introduction.
/// 3. Only after `ok`: unregister, then read the registration again. The
///    helper counts as removed only if it is then `notRegistered` or
///    `notFound`.
/// 4. An explicit reply other than `ok` is never overridden, not even with
///    force. `hardwareError` means the helper's restore did not read back
///    clean and the helper keeps retrying it, so unregistering would stop
///    the one process that is restoring; `notIntroduced` and `rateLimited`
///    mean it refused the request.
/// 5. If nothing confirmed the restore because the transport failed or no
///    reply arrived in time, at any stage (connecting, `hello`, the
///    restore), the helper is not unregistered either, unless the caller
///    passes ``HelperRemovalForce`` to ``remove(force:)``: the user has seen
///    the recovery procedure and wants the helper removed although its
///    restore could not be confirmed. Such a helper can be broken in a way
///    that would block its removal forever. Unregistering terminates a
///    running daemon, whose SIGTERM path attempts the restore itself (D31),
///    but nothing confirms that attempt, a missing reply does not show that
///    the helper had stopped trying, and an unregistered helper does not
///    restore defaults at the next startup. The forced outcome says so; the
///    remaining risk is what the recovery procedure covers.
///
/// Every step has a deadline: ``helperDeadline`` for the whole
/// conversation with the helper (connecting, `hello` and the restore; the
/// NSXPC transport also times out each request on its own), and
/// ``registrationDeadline`` for each call to the registration. The
/// conversation's evidence and its deadline share one lock: whichever comes
/// first, conclusive evidence (a failure, or the restore's reply) or the
/// deadline, decides, and the evidence is frozen at that moment. A reply or
/// a `hello` recorded after the deadline authorises nothing: a late `ok`
/// never leads to unregistering, and a helper whose `hello` arrives late is
/// not asked to exit. The flow ignores the caller's cancellation, so it
/// always finishes within its deadlines and reports what happened. That
/// bounds the waiting, not the work behind it: a call that does not
/// cooperate with cancellation keeps running on its own, so the transport
/// and the registration must bound their own calls and clean-up.
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
    /// Returns once a deadline of the given length has passed; tests inject
    /// their own timer.
    let waitForDeadline: @Sendable (Duration) async -> Void

    public init(
        transport: any HelperTransport,
        registration: any HelperRegistration,
        helperDeadline: Duration = HelperRemoval.defaultHelperDeadline,
        registrationDeadline: Duration = HelperRemoval.defaultRegistrationDeadline
    ) {
        self.init(
            transport: transport,
            registration: registration,
            helperDeadline: helperDeadline,
            registrationDeadline: registrationDeadline,
            waitForDeadline: { try? await Task.sleep(for: $0) }
        )
    }

    init(
        transport: any HelperTransport,
        registration: any HelperRegistration,
        helperDeadline: Duration,
        registrationDeadline: Duration,
        waitForDeadline: @escaping @Sendable (Duration) async -> Void
    ) {
        self.transport = transport
        self.registration = registration
        self.helperDeadline = helperDeadline
        self.registrationDeadline = registrationDeadline
        self.waitForDeadline = waitForDeadline
    }

    /// Removes the helper if, and only if, it confirms that it restored
    /// defaults. Never unregisters a helper that did not confirm.
    public func remove() async -> HelperRemovalOutcome {
        await runDetached(force: nil)
    }

    /// As ``remove()``, but a helper whose restore went unconfirmed because
    /// the transport failed or no reply arrived in time is unregistered
    /// anyway, and the outcome says that its restore was not confirmed. A
    /// helper that replies with anything other than `ok` is still never
    /// unregistered.
    public func remove(force: HelperRemovalForce) async -> HelperRemovalOutcome {
        await runDetached(force: force)
    }

    /// The registration as the system reports it, or
    /// ``HelperRegistrationStatus/unknown(_:)`` if it did not answer within
    /// ``registrationDeadline``.
    public func registrationStatus() async -> HelperRegistrationStatus {
        let registration = registration
        return await withDeadline(registrationDeadline) { await registration.status() }
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
        case .refused(let status, let helper):
            return logged(.restoreRefused(status, helper: helper))
        case .unconfirmed(let reason):
            guard force != nil else {
                return logged(.restoreUnconfirmed(reason))
            }
            CellKeeperLog.safety.error("Helper removal: nothing confirmed the helper's restore (\(reason.description, privacy: .public)); unregistering it anyway at the user's request.")
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
        case .unregisterIncomplete, .restoreRefused, .restoreUnconfirmed, .removedWithoutConfirmedRestore, .forcedUnregisterIncomplete: .error
        }
        CellKeeperLog.safety.log(level: level, "Helper removal: \(outcome.summary, privacy: .public)")
        return outcome
    }

    /// Unregisters within ``registrationDeadline``, then reads the
    /// registration again. `error` describes a failed or unanswered
    /// unregistering; the status alone decides whether the helper is gone.
    private func unregisterAndCheck() async -> (status: HelperRegistrationStatus, error: String?) {
        let registration = registration
        let answer = await withDeadline(registrationDeadline) { () async -> String? in
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

    /// Connects, says hello, and asks the helper to restore defaults and
    /// exit. Conclusive evidence or ``helperDeadline``, whichever comes
    /// first, decides; see ``HelperConversation``.
    private func askHelperToRestoreAndExit() async -> HelperConversation.Result {
        let conversation = HelperConversation(deadline: helperDeadline)
        let transport = transport
        let wait = waitForDeadline
        let deadline = helperDeadline
        return await withCheckedContinuation { continuation in
            conversation.install(continuation)
            conversation.attach(work: Task { await Self.converse(with: transport, in: conversation) })
            conversation.attach(timer: Task {
                await wait(deadline)
                conversation.expire()
            })
        }
    }

    private static func converse(with transport: any HelperTransport, in conversation: HelperConversation) async {
        let connection: any HelperConnection
        do {
            connection = try await transport.connect()
        } catch {
            conversation.conclude(.unconfirmed(.connectFailed(String(describing: error))))
            return
        }
        let hello: HelperHelloReply
        do {
            hello = try await connection.hello(clientProtocolVersion: HelperProtocolVersion.current)
        } catch {
            conversation.conclude(.unconfirmed(.helloFailed(String(describing: error))))
            await connection.invalidate()
            return
        }
        // A hello recorded after the deadline authorises nothing: the
        // helper is not asked to exit.
        guard conversation.record(hello: hello) else {
            await connection.invalidate()
            return
        }
        let helper = HelperKind(hello: hello)
        let status: HelperStatus
        do {
            status = try await connection.restoreDefaultsAndExit()
        } catch {
            conversation.conclude(.unconfirmed(.restoreConnectionFailed(String(describing: error), helper: helper)))
            await connection.invalidate()
            return
        }
        // Decided before the connection is closed, so closing it cannot
        // delay a confirmation past the deadline.
        conversation.conclude(status == .ok ? .confirmed(helper) : .refused(status, helper))
        await connection.invalidate()
    }

    // MARK: - Deadlines

    /// Runs `operation` in a task of its own and returns its result, or nil
    /// if `deadline` passes first. The operation is then cancelled but not
    /// awaited: a call stuck in a transport keeps running on its own, and
    /// its result is dropped.
    func withDeadline<T: Sendable>(_ deadline: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let race = FirstResult<T>()
        let wait = waitForDeadline
        return await withCheckedContinuation { continuation in
            race.install(continuation)
            race.attach(Task { race.finish(await operation()) })
            race.attach(Task {
                await wait(deadline)
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

/// Consent to unregister a helper whose restore of defaults could not be
/// confirmed because the transport failed or no reply arrived in time. See
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

/// Why nothing confirmed the helper's restore although the helper did not
/// refuse it: the transport failed, or no reply arrived in time. Whether the
/// helper restored defaults, and whether it is still trying, is unknown.
public enum HelperNoConfirmationReason: Sendable, Equatable, CustomStringConvertible {
    /// Opening the connection failed.
    case connectFailed(String)
    /// The connection failed before the helper answered `hello` (over NSXPC,
    /// the first request is where a helper that cannot be reached shows).
    case helloFailed(String)
    /// `hello` was not answered within the deadline.
    case noHello(Duration)
    /// The helper answered `hello`, then the connection failed before the
    /// restore's reply arrived (the helper may have crashed or exited).
    case restoreConnectionFailed(String, helper: HelperKind)
    /// The helper answered `hello`, but the restore's reply did not arrive
    /// within the deadline.
    case noRestoreReply(Duration, helper: HelperKind)

    /// The helper's kind, if it answered `hello`.
    public var helper: HelperKind? {
        switch self {
        case .connectFailed, .helloFailed, .noHello: nil
        case .restoreConnectionFailed(_, let helper), .noRestoreReply(_, let helper): helper
        }
    }

    public var description: String {
        switch self {
        case .connectFailed(let detail): "the connection could not be opened (\(detail))"
        case .helloFailed(let detail): "the connection failed before the helper answered (\(detail))"
        case .noHello(let deadline): "the helper did not answer within \(HelperRemoval.describe(deadline))"
        case .restoreConnectionFailed(let detail, _): "the connection failed after the helper answered, before its reply to the restore (\(detail))"
        case .noRestoreReply(let deadline, _): "the helper answered, but its reply to the restore did not arrive within \(HelperRemoval.describe(deadline))"
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
    /// The helper replied to `restoreDefaultsAndExit` with this status
    /// instead of `ok`. It was not unregistered, and force never overrides
    /// such a reply. From the engine: `hardwareError` (its restore did not
    /// read back clean; it keeps retrying it), `notIntroduced` (the session
    /// no longer existed) or `rateLimited` (the request revoked the session
    /// for exceeding its request budget).
    case restoreRefused(HelperStatus, helper: HelperKind)
    /// Nothing confirmed the restore because the transport failed or no
    /// reply arrived in time; the helper was not unregistered.
    /// ``HelperRemoval/remove(force:)`` can remove it.
    case restoreUnconfirmed(HelperNoConfirmationReason)
    /// Forced: nothing confirmed the restore; the helper was unregistered,
    /// and the system no longer reports it registered.
    case removedWithoutConfirmedRestore(HelperNoConfirmationReason)
    /// Forced: nothing confirmed the restore, and unregistering did not
    /// complete either: the system still reports `status`.
    case forcedUnregisterIncomplete(HelperNoConfirmationReason, status: HelperRegistrationStatus, error: String?)

    /// True only if the helper replied `ok` to `restoreDefaultsAndExit`.
    public var isRestoreConfirmed: Bool {
        switch self {
        case .removed, .unregisterIncomplete: true
        case .nothingToRemove, .restoreRefused, .restoreUnconfirmed, .removedWithoutConfirmedRestore, .forcedUnregisterIncomplete: false
        }
    }

    /// True if the system no longer reports the helper registered after
    /// CellKeeper unregistered it.
    public var isHelperRemoved: Bool {
        switch self {
        case .removed, .removedWithoutConfirmedRestore: true
        case .nothingToRemove, .unregisterIncomplete, .restoreRefused, .restoreUnconfirmed, .forcedUnregisterIncomplete: false
        }
    }

    /// True if ``HelperRemoval/remove(force:)`` may remove the helper
    /// although its restore cannot be confirmed: only when the transport
    /// failed or no reply arrived in time, never after an explicit reply.
    public var offersForcedRemoval: Bool {
        if case .restoreUnconfirmed = self { return true }
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
        case .restoreRefused(.hardwareError, let helper):
            return "The helper replied that its restore of defaults did not read back clean (hardwareError). It keeps retrying the restore by itself, and removing it would stop that, so CellKeeper did not remove it.\(helper.simulatedNote) Try again later. \(recovery)"
        case .restoreRefused(let status, let helper):
            return "The helper refused the request to restore defaults and exit (\(status)), so nothing confirms that defaults are in effect. CellKeeper does not override a refusal and did not remove it.\(helper.simulatedNote) Try again later. \(recovery)"
        case .restoreUnconfirmed(let reason):
            return "Nothing confirmed that the helper restored defaults: \(reason). Whether it restored them, and whether it is still trying, is unknown, so CellKeeper did not remove it.\(reason.helper?.simulatedNote ?? "") Try again later. \(recovery) Once you have read it, you can remove the helper anyway."
        case .removedWithoutConfirmedRestore(let reason):
            return "Nothing confirmed that the helper restored defaults: \(reason). At your request CellKeeper unregistered it anyway, and the system no longer reports it registered. Unregistering stops a running helper, which then attempts the restore as it exits, but nothing confirmed that, and a missing reply does not show that the helper had stopped trying. Once unregistered, no helper starts at the next startup to restore defaults, and state that a charge-control mechanism wrote may outlast the helper.\(reason.helper?.simulatedNote ?? "") \(recovery)"
        case .forcedUnregisterIncomplete(let reason, let status, let error):
            return "Nothing confirmed that the helper restored defaults: \(reason). At your request CellKeeper tried to unregister it anyway, but that did not complete: the system still reports it \(status)\(Self.detail(error)). Nothing confirms that defaults are in effect.\(reason.helper?.simulatedNote ?? "") \(recovery)"
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

/// One conversation with the helper and its deadline, decided once under
/// one lock: by conclusive evidence (a failure, or the restore's reply) or
/// by the deadline, whichever comes first. The deadline decides from the
/// evidence recorded before it, and freezes it: nothing recorded afterwards
/// counts, and a `hello` that arrives afterwards is refused, so the helper
/// is not asked to exit.
final class HelperConversation: @unchecked Sendable {
    /// What the conversation established.
    enum Result: Sendable, Equatable {
        case confirmed(HelperKind)
        case refused(HelperStatus, HelperKind)
        case unconfirmed(HelperNoConfirmationReason)
    }

    private let lock = NSLock()
    private let deadline: Duration
    private var continuation: CheckedContinuation<Result, Never>?
    private var result: Result?
    private var hello: HelperHelloReply?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(deadline: Duration) {
        self.deadline = deadline
    }

    /// Called once, before the work and the timer start.
    func install(_ continuation: CheckedContinuation<Result, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    /// The task that talks to the helper; cancelled if the deadline decides.
    func attach(work task: Task<Void, Never>) {
        lock.withLock {
            if result == nil {
                work = task
            }
        }
    }

    /// The deadline's task; cancelled once the conversation is decided.
    func attach(timer task: Task<Void, Never>) {
        let isDecided = lock.withLock {
            if result == nil {
                timer = task
            }
            return result != nil
        }
        if isDecided {
            task.cancel()
        }
    }

    /// Records the helper's `hello`. False if the conversation is already
    /// decided: the deadline has passed, and the helper must not be asked
    /// anything more.
    func record(hello reply: HelperHelloReply) -> Bool {
        lock.withLock {
            guard result == nil else { return false }
            hello = reply
            return true
        }
    }

    /// Conclusive evidence from the conversation decides, unless the
    /// deadline already has.
    func conclude(_ evidence: Result) {
        decide(byDeadline: false) { _ in evidence }
    }

    /// The deadline decides from the evidence recorded so far, unless
    /// conclusive evidence already has.
    func expire() {
        let deadline = deadline
        decide(byDeadline: true) { hello in
            if let hello {
                .unconfirmed(.noRestoreReply(deadline, helper: HelperKind(hello: hello)))
            } else {
                .unconfirmed(.noHello(deadline))
            }
        }
    }

    private func decide(byDeadline: Bool, _ make: (HelperHelloReply?) -> Result) {
        var decided: Result?
        var resume: CheckedContinuation<Result, Never>?
        var stopping: [Task<Void, Never>] = []
        lock.withLock {
            guard result == nil else { return }
            let outcome = make(hello)
            result = outcome
            decided = outcome
            resume = continuation
            continuation = nil
            if let timer {
                stopping.append(timer)
            }
            if byDeadline, let work {
                // Too late: whatever it still records is ignored.
                stopping.append(work)
            }
            timer = nil
            work = nil
        }
        for task in stopping {
            task.cancel()
        }
        if let resume, let decided {
            resume.resume(returning: decided)
        }
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
