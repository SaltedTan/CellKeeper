import AppKit
import CellKeeperCore
import CellKeeperKit
import Observation

/// The control backends selectable in this build. Real control backends are
/// added here only once implemented and verified, and are opt-in.
enum ControlBackendChoice: String, CaseIterable, Identifiable {
    case simulated
    case readOnly
    /// macOS's own Charge Limit, set through the user's shortcut. Experimental
    /// and opt-in: the UI asks for confirmation before selecting it.
    case nativeLimit
    /// CellKeeper's own charge control through its helper's logic, running
    /// in the app on a simulated control: nothing on the Mac changes, so no
    /// confirmation is needed.
    case simulatedHelper

    var id: String { rawValue }

    /// The choice matching a backend descriptor, if any.
    init?(backendIdentifier: String) {
        switch backendIdentifier {
        case MockChargingBackend().descriptor.identifier: self = .simulated
        case ReadOnlyChargingBackend().descriptor.identifier: self = .readOnly
        case NativeChargeLimitBackend.identifier: self = .nativeLimit
        case HelperChargingBackend.simulatedHelperIdentifier: self = .simulatedHelper
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .simulated: "Simulated"
        case .readOnly: "Read-only"
        case .nativeLimit: "macOS Charge Limit (through Shortcuts)"
        case .simulatedHelper: "Simulated helper (CellKeeper's own control)"
        }
    }

    func makeBackend() -> any ChargingBackend {
        switch self {
        case .simulated: MockChargingBackend()
        case .readOnly: ReadOnlyChargingBackend()
        case .nativeLimit: NativeChargeLimitBackend.system()
        case .simulatedHelper: HelperChargingBackend.simulatedHelper()
        }
    }
}

/// Main-actor state for the UI. Owns the ``ChargeController`` and feeds it
/// commands strictly in order through a single queue.
@MainActor
@Observable
final class AppModel {
    private(set) var status: ControllerStatus?
    private(set) var settings: ChargingSettings
    private(set) var backendChoice: ControlBackendChoice
    /// Validation or persistence problem with the most recent settings change.
    private(set) var settingsError: String?
    /// Set when stored settings were unusable and defaults were loaded.
    private(set) var settingsRecoveryMessage: String?
    /// macOS's system-wide thermal state and Low Power Mode, shown for
    /// context. Not battery temperature; the charging policy does not use
    /// them.
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private enum Command: Sendable {
        case evaluate(EvaluationTrigger)
        /// `adoptionsSeen`: outside changes the app had reflected when the
        /// user made this change.
        case apply(ChargingSettings, adoptionsSeen: Int)
        case startFullCharge
        case startDischarge
        case cancelOverride
        case switchBackend(ControlBackendChoice)
        case resetFault
        case recheckBackend
        case confirmNoLimit
        case discardUnreadableRecord
    }

    /// How quitting went for the user's own Charge Limit.
    enum TerminationOutcome: Sendable {
        /// Nothing is left changed, or the restore was confirmed.
        /// `keptOutsideChange` is true if CellKeeper found a limit set
        /// outside it, kept it as the user's own, and turned management off.
        case restored(keptOutsideChange: Bool)
        /// CellKeeper may have left the Charge Limit changed; `ownerLimit` is
        /// the value to set by hand, if known.
        case unresolved(ownerLimit: Int?)
    }

    static let backendChoiceKey = "controlBackend"
    static let periodicInterval: Duration = .seconds(60)
    /// macOS reports battery estimates as invalid for 30 s after wake
    /// (`BatteryInvalidWakeSeconds`), so re-read once that has passed.
    static let postWakeRereadDelay: Duration = .seconds(35)
    /// How long quitting waits for the user's own Charge Limit to be
    /// restored. In-flight tool runs are cancelled when quitting starts, and
    /// a restore normally takes well under a second.
    nonisolated static let terminationTimeout: Duration = .seconds(10)

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let telemetry: any TelemetryProvider
    @ObservationIgnored private let controller: ChargeController
    /// A backend to switch to as soon as the app starts: set when an earlier
    /// session left macOS's Charge Limit changed while another backend is
    /// selected, so the native backend can restore it first.
    @ObservationIgnored private var startupSwitch: ControlBackendChoice?
    @ObservationIgnored private let commands: AsyncStream<Command>
    @ObservationIgnored private let commandSink: AsyncStream<Command>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The pending re-read after a wake; cancelled if the Mac announces
    /// sleep again first.
    @ObservationIgnored private var postWakeReread: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Outside changes to the Charge Limit already reflected in the settings.
    @ObservationIgnored private var handledAdoptionCount = 0
    /// The in-process helpers of the Simulated helper backends made in this
    /// session, held weakly: each lives only as long as its backend, and is
    /// told about sleep and wake.
    @ObservationIgnored private var inProcessHelpers: [WeakInProcessHelper] = []

    init(store: SettingsStore = SettingsStore(), telemetry: any TelemetryProvider = SystemTelemetryProvider()) {
        var loaded = store.loadChargingSettings()
        // While an adoption marker exists, CellKeeper kept a Charge Limit
        // changed outside it and the user has not turned management on
        // since. Settings are saved asynchronously, so they may not show
        // that yet: the marker decides.
        if let adopted = NativeChargeLimitBackend.pendingAdoption(in: FileOwnershipRecordStore.default),
           loaded.settings.isManagementEnabled {
            CellKeeperLog.safety.notice("CellKeeper kept a Charge Limit of \(adopted.limit)% set outside it; Manage charging stays off until you turn it on")
            loaded.settings.isManagementEnabled = false
            try? store.save(loaded.settings)
        }
        let choice = store.string(forKey: Self.backendChoiceKey).flatMap(ControlBackendChoice.init(rawValue:)) ?? .simulated
        self.store = store
        self.telemetry = telemetry
        self.settings = loaded.settings
        self.settingsRecoveryMessage = loaded.recoveryReason
        self.backendChoice = choice
        // Recovery must not depend on which backend is selected: if a record
        // of the user's own Charge Limit exists, start with the backend that
        // can restore it and switch once it has.
        let needsRecovery = choice != .nativeLimit && NativeChargeLimitBackend.hasOutstandingRecord(in: FileOwnershipRecordStore.default)
        self.startupSwitch = needsRecovery ? choice : nil
        let backend = needsRecovery ? ControlBackendChoice.nativeLimit.makeBackend() : choice.makeBackend()
        self.controller = ChargeController(telemetry: telemetry, backend: backend, settings: loaded.settings, adoptionMarkerStore: FileOwnershipRecordStore.default)
        (commands, commandSink) = AsyncStream.makeStream(of: Command.self)
        noteInProcessHelper(of: backend)
    }

    // MARK: - Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        let initialBackend = startupSwitch == nil ? backendChoice : .nativeLimit
        CellKeeperLog.app.notice("CellKeeper starting with \(initialBackend.rawValue, privacy: .public) backend")

        tasks.append(Task { [weak self, commands] in
            for await command in commands {
                // Commands still buffered at quit must not run.
                guard !Task.isCancelled else { break }
                await self?.perform(command)
            }
        })
        tasks.append(Task { [weak self, telemetry] in
            for await _ in telemetry.powerSourceChanges() {
                self?.send(.evaluate(.powerSourceChanged))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicInterval)
                self?.send(.evaluate(.periodic))
            }
        })

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        })

        let defaultCenter = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(defaultCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.readSystemConditions() }
            })
        }

        if let startupSwitch {
            CellKeeperLog.app.notice("An earlier session left macOS's Charge Limit changed; restoring it before switching to the \(startupSwitch.rawValue, privacy: .public) backend")
            send(.switchBackend(startupSwitch))
        }
        send(.evaluate(.launch))
    }

    private func didWake() {
        forwardToInProcessHelpers { await $0.systemDidWake() }
        send(.evaluate(.didWake))
        postWakeReread?.cancel()
        postWakeReread = Task { [weak self] in
            try? await Task.sleep(for: Self.postWakeRereadDelay)
            guard !Task.isCancelled else { return }
            self?.send(.evaluate(.postWakeReread))
        }
    }

    private func willSleep() {
        postWakeReread?.cancel()
        postWakeReread = nil
        forwardToInProcessHelpers { await $0.systemWillSleep() }
        send(.evaluate(.willSleep))
    }

    /// Notes the in-process helper of a Simulated helper backend, so it is
    /// told about sleep and wake as the daemon will be.
    private func noteInProcessHelper(of backend: any ChargingBackend) {
        inProcessHelpers.removeAll { $0.transport == nil }
        if let transport = (backend as? HelperChargingBackend)?.transport as? InProcessHelperTransport {
            inProcessHelpers.append(WeakInProcessHelper(transport: transport))
        }
    }

    /// Delivers a system event to every in-process helper still alive. It
    /// does not wait for the command queue: the helper handles sleep and wake
    /// on its own, whatever the app is doing.
    private func forwardToInProcessHelpers(_ event: @escaping @Sendable (InProcessHelperTransport) async -> Void) {
        let transports = inProcessHelpers.compactMap(\.transport)
        guard !transports.isEmpty else { return }
        Task {
            for transport in transports {
                await event(transport)
            }
        }
    }

    private func readSystemConditions() {
        thermalState = ProcessInfo.processInfo.thermalState
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Stops monitoring and command processing, returning the controller so
    /// the caller can restore defaults without involving the main actor.
    func stopForTermination() -> ChargeController {
        commandSink.finish()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        postWakeReread?.cancel()
        return controller
    }

    /// Restores macOS default charging and shuts the controller down, so no
    /// queued command can apply a restriction afterwards. Waits at most
    /// `timeout`, then reports whether anything may be left changed. Runs
    /// entirely off the main actor.
    ///
    /// The durable record of the user's own Charge Limit decides the outcome,
    /// whether or not the restore finished in time: it is deleted only after
    /// a confirmed restore, so while it exists the limit may still be
    /// CellKeeper's.
    nonisolated static func shutDown(_ controller: ChargeController, timeout: Duration) async -> TerminationOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task.detached {
                await controller.shutdown(reason: "CellKeeper is quitting")
                gate.resume(returning: ())
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                gate.resume(returning: ())
            }
        }
        // A change kept in this session leaves nothing to restore, even if an
        // old record is still on disk because its marker could not be stored
        // (the next launch then keeps the change again).
        let status = await controller.status
        if status.adoptedChange != nil, !status.settings.isManagementEnabled {
            return .restored(keptOutsideChange: true)
        }
        guard let outstanding = NativeChargeLimitBackend.outstandingRecord(in: FileOwnershipRecordStore.default) else {
            return .restored(keptOutsideChange: false)
        }
        return .unresolved(ownerLimit: outstanding.ownerLimit)
    }

    /// Saves "Manage charging" as off after CellKeeper kept a Charge Limit
    /// set outside it. The backend's adoption marker also keeps it off at
    /// the next launch until the user turns management on again, because
    /// settings reach the disk asynchronously.
    func keepManagementOffAfterOutsideChange() {
        updateSettings { $0.isManagementEnabled = false }
    }

    // MARK: - User intents

    func refresh() {
        send(.evaluate(.manual))
    }

    /// Validates and applies a settings change. Invalid changes are rejected
    /// with an explanation and nothing is saved or applied. Returns true if
    /// the resulting settings are saved (including when nothing changed).
    @discardableResult
    func updateSettings(_ change: (inout ChargingSettings) -> Void) -> Bool {
        var proposed = settings
        change(&proposed)
        guard proposed != settings else { return true }
        let issues = proposed.validationIssues
        guard issues.isEmpty else {
            settingsError = issues.map(\.description).joined(separator: "\n")
            return false
        }
        do {
            try store.save(proposed)
        } catch {
            settingsError = "Could not save settings: \(error)"
            return false
        }
        settingsError = nil
        settings = proposed
        send(.apply(proposed, adoptionsSeen: handledAdoptionCount))
        return true
    }

    func setChargeLimit(_ limit: Int) {
        updateSettings { $0 = $0.withChargeLimit(limit) }
    }

    func startFullCharge() {
        send(.startFullCharge)
    }

    /// Starts a one-shot discharge to the charge limit. The UI must have
    /// obtained explicit confirmation first.
    func startDischargeToLimit() {
        send(.startDischarge)
    }

    func cancelOverride() {
        send(.cancelOverride)
    }

    /// Saves the choice at once: if the switch cannot complete in this
    /// session, the next launch restores the old backend's changes first and
    /// then switches.
    func selectBackend(_ choice: ControlBackendChoice) {
        guard choice != backendChoice else { return }
        backendChoice = choice
        store.set(choice.rawValue, forKey: Self.backendChoiceKey)
        send(.switchBackend(choice))
    }

    func resetBackendFault() {
        send(.resetFault)
    }

    /// Checks again what the backend depends on (the shortcut after the user
    /// created it, or macOS's Charge Limit after the user turned it off) and
    /// re-evaluates.
    func recheckBackend() {
        send(.recheckBackend)
    }

    /// The user confirmed that their own Charge Limit is 100%.
    func confirmNoLimitIsOwnerLimit() {
        send(.confirmNoLimit)
    }

    /// The user set their limit by hand and wants the unreadable record gone.
    func discardUnreadableRecord() {
        send(.discardUnreadableRecord)
    }

    /// A plain-text report of what CellKeeper sees and does, for bug reports.
    /// It contains no serial numbers or other device identifiers.
    func diagnosticsReport() -> String? {
        guard let status else { return nil }
        return DiagnosticsReport.text(status: status, environment: .current(), generatedAt: Date())
    }

    /// True when the selected backend sets macOS's own Charge Limit, so the
    /// UI should offer only what that limit can express.
    var usesNativeLimit: Bool {
        status?.capabilities.isEnforcedByMacOS ?? (backendChoice == .nativeLimit)
    }

    /// The charge limits the UI should offer with the native backend.
    var nativeLimitSteps: [Int] {
        let steps = status?.capabilities.nativeLimitSteps ?? []
        return steps.isEmpty ? NativeChargeLimitBackend.supportedLimits : steps
    }

    // MARK: - Command queue

    private func send(_ command: Command) {
        commandSink.yield(command)
    }

    private func perform(_ command: Command) async {
        switch command {
        case .evaluate(let trigger):
            status = await controller.evaluate(trigger)
        case .apply(let newSettings, let adoptionsSeen):
            do {
                let newStatus = try await controller.apply(settings: newSettings, adoptionsSeen: adoptionsSeen)
                status = newStatus
                // The controller keeps management off if the user had not seen
                // a kept outside change yet, or the change cannot be retired;
                // show and save what is actually in effect, unless a newer
                // change is already on its way.
                if newSettings.isManagementEnabled, !newStatus.settings.isManagementEnabled, settings == newSettings {
                    settings.isManagementEnabled = false
                    try? store.save(settings)
                    settingsError = newStatus.managementRefusal ?? "Manage charging stays off; Settings › Activity says why."
                }
            } catch {
                settingsError = "Settings were rejected: \(error)"
            }
        case .startFullCharge:
            status = await controller.startFullCharge()
        case .startDischarge:
            status = await controller.startDischargeToLimit()
        case .cancelOverride:
            status = await controller.cancelOverride()
        case .switchBackend(let choice):
            let backend = choice.makeBackend()
            noteInProcessHelper(of: backend)
            let newStatus = await controller.switchBackend(to: backend)
            status = newStatus
            // A switch the controller cannot make yet stays pending; anything
            // else is reflected as the backend actually in use.
            if newStatus.pendingBackend == nil,
               let actual = ControlBackendChoice(backendIdentifier: newStatus.backend.identifier), actual != backendChoice {
                backendChoice = actual
                store.set(actual.rawValue, forKey: Self.backendChoiceKey)
            }
        case .resetFault:
            status = await controller.resetBackendFault()
        case .recheckBackend:
            status = await controller.recheckBackendAvailability()
        case .confirmNoLimit:
            status = await controller.confirmNoLimitIsOwnerLimit()
        case .discardUnreadableRecord:
            status = await controller.discardUnreadableOwnershipRecord()
        }
        noteAdoptedChanges()
    }

    /// When the controller kept a Charge Limit set outside CellKeeper, it
    /// turned management off; save that too. Going through the command queue
    /// keeps the app's settings, the saved settings and the controller's in
    /// step, even if the user changed something meanwhile.
    private func noteAdoptedChanges() {
        guard let status, status.adoptionCount > handledAdoptionCount else { return }
        handledAdoptionCount = status.adoptionCount
        keepManagementOffAfterOutsideChange()
    }

    // MARK: - Presentation

    var menuBarSymbolName: String {
        guard let status, let decision = status.decision else { return "batteryblock" }
        if status.isBackendFaulted { return "exclamationmark.triangle" }
        switch decision.state {
        case .unmanaged: return "batteryblock.slash"
        case .failSafe: return "exclamationmark.triangle"
        case .temperaturePause: return "thermometer.high"
        case .discharging: return "minus.plus.batteryblock"
        case .holding, .onBattery, .charging, .fullChargeOverride, .safetyFloor, .osEnforcedLimit, .deferringToMacOS:
            // A state that allows charging does not mean the battery is
            // charging (unplugged at the safety floor, full at a 100% limit).
            return status.snapshot?.isCharging == true ? "bolt.batteryblock" : "batteryblock"
        }
    }

    /// What the menu bar icon shows, for VoiceOver: the charge, whether the
    /// battery is charging, and CellKeeper's state. The status item exposes
    /// only a title to accessibility, not a value, so it is all in the label.
    var menuBarAccessibilityLabel: String {
        guard let status else { return "CellKeeper, reading battery" }
        var parts = ["CellKeeper"]
        if let snapshot = status.snapshot, snapshot.isBatteryPresent {
            parts.append(snapshot.chargePercent.map { "\($0)%" } ?? "Charge unknown")
            parts.append(snapshot.chargingStatus.title)
        }
        if status.isBackendFaulted {
            parts.append("Control backend faulted")
        } else if let decision = status.decision {
            parts.append(decision.state.title(nativeLimit: status.capabilities.isEnforcedByMacOS))
        }
        return parts.joined(separator: ", ")
    }
}

/// An in-process helper, held without keeping it alive.
private struct WeakInProcessHelper {
    weak var transport: InProcessHelperTransport?
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
