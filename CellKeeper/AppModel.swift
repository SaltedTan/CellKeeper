import AppKit
import CellKeeperCore
import CellKeeperKit
import Observation
import UniformTypeIdentifiers

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

    /// The identifier of the backend this choice makes.
    var backendIdentifier: String {
        switch self {
        case .simulated: MockChargingBackend().descriptor.identifier
        case .readOnly: ReadOnlyChargingBackend().descriptor.identifier
        case .nativeLimit: NativeChargeLimitBackend.identifier
        case .simulatedHelper: HelperChargingBackend.simulatedHelperIdentifier
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

/// The tabs of the Settings window, so the menu can open one.
enum SettingsTab: Hashable {
    case charging
    case control
    case activity
    case diagnostics
    case about
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
    /// Why the most recent scheduled full charge was not set.
    private(set) var scheduleError: String?
    /// Set when stored settings were unusable and defaults were loaded.
    private(set) var settingsRecoveryMessage: String?
    /// macOS's system-wide thermal state and Low Power Mode, shown for
    /// context. Not battery temperature; the charging policy does not use
    /// them.
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The Settings tab shown; the menu opens Control for the macOS Charge
    /// Limit steps.
    var settingsTab: SettingsTab = .charging
    /// Whether Settings › Control shows the steps for turning macOS's Charge
    /// Limit off.
    var isMacOSLimitGuideExpanded = false
    /// True from the moment Save Diagnostics… opens its panel until its write
    /// has ended, whatever the outcome; no second save starts meanwhile. Two
    /// saves at once could let an older report overwrite a newer one, or mix
    /// two direct writes in one file. Kept here, not in the view, so that it
    /// outlives the Settings view.
    private(set) var isSavingDiagnostics = false
    /// Why the last diagnostics save failed, until the user dismisses it.
    private(set) var diagnosticsSaveFailure: String?
    /// The user's opt-in to notifications and what macOS allows.
    private(set) var notificationOptIn: NotificationOptIn
    /// True once quitting has started; Shortcuts actions then refuse.
    private(set) var isTerminating = false
    /// Provided with the first status, for Shortcuts actions that need one.
    @ObservationIgnored let firstStatus = FirstValue<Bool>()
    /// The app's version, macOS and the model, read once: none of them
    /// changes while the app runs. The diagnostics report and Settings ›
    /// Diagnostics both use it.
    @ObservationIgnored let diagnosticsEnvironment = DiagnosticsEnvironment.current()

    private enum Command: Sendable {
        case evaluate(EvaluationTrigger)
        /// `adoptionsSeen`: outside changes the app had reflected when the
        /// change was made. `source` decides only how a refusal is shown.
        case apply(ChargingSettings, adoptionsSeen: Int, source: SettingsChangeSource)
        case startFullCharge
        case startDischarge
        case cancelOverride
        case setSchedule(FullChargeSchedule)
        case cancelSchedule
        case dismissScheduleOutcome
        case switchBackend(ControlBackendChoice)
        case resetFault
        case recheckBackend
        case confirmNoLimit
        case discardUnreadableRecord

        /// The evaluation this command runs, for the notification planner:
        /// the user's own commands never post a hold, a pause or an
        /// override's end.
        var trigger: EvaluationTrigger {
            switch self {
            case .evaluate(let trigger): trigger
            case .apply: .settingsChanged
            case .startFullCharge, .startDischarge, .cancelOverride: .overrideChanged
            case .setSchedule, .cancelSchedule, .dismissScheduleOutcome: .scheduleChanged
            case .switchBackend: .backendChanged
            case .resetFault, .recheckBackend, .confirmNoLimit, .discardUnreadableRecord: .manual
            }
        }
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
    /// Posts notifications from the statuses the app receives; it never
    /// sees the controller.
    @ObservationIgnored private let notifier: ChargingNotifier
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
    /// Notification observers, each with the center it was added to, so
    /// that stopping removes them all.
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    /// Outside changes to the Charge Limit already reflected in the settings.
    @ObservationIgnored private var handledAdoptionCount = 0
    /// The in-process helpers of the Simulated helper backends made in this
    /// session, held weakly: each lives only as long as its backend, and is
    /// told about sleep and wake.
    @ObservationIgnored private var inProcessHelpers: [WeakInProcessHelper] = []

    init(
        store: SettingsStore = SettingsStore(),
        telemetry: any TelemetryProvider = SystemTelemetryProvider(),
        scheduleStore: any FullChargeScheduleStoring = FullChargeScheduleStore(),
        notificationPoster: any NotificationPosting = SystemNotificationPoster()
    ) {
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
        self.controller = ChargeController(
            telemetry: telemetry,
            backend: backend,
            settings: loaded.settings,
            adoptionMarkerStore: FileOwnershipRecordStore.default,
            scheduleStore: scheduleStore
        )
        let notifier = ChargingNotifier(poster: notificationPoster, store: store)
        self.notifier = notifier
        self.notificationOptIn = notifier.optIn
        (commands, commandSink) = AsyncStream.makeStream(of: Command.self)
        noteInProcessHelper(of: backend)
        notifier.onChange = { [weak self] in self?.notificationOptIn = $0 }
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
        observe(NSWorkspace.didWakeNotification, on: center) { $0.didWake() }
        observe(NSWorkspace.willSleepNotification, on: center) { $0.willSleep() }

        let defaultCenter = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observe(name, on: defaultCenter) { $0.readSystemConditions() }
        }
        // A scheduled full charge's window is wall-clock time: check it again
        // at once when the clock or the time zone changes (research rule R22).
        for name in [Notification.Name.NSSystemClockDidChange, Notification.Name.NSSystemTimeZoneDidChange] {
            observe(name, on: defaultCenter) { $0.clockDidChange() }
        }
        // The user may change CellKeeper's notification settings in System
        // Settings and come back.
        observe(NSApplication.didBecomeActiveNotification, on: defaultCenter) { $0.refreshNotificationPermission() }
        refreshNotificationPermission()

        if let startupSwitch {
            CellKeeperLog.app.notice("An earlier session left macOS's Charge Limit changed; restoring it before switching to the \(startupSwitch.rawValue, privacy: .public) backend")
            send(.switchBackend(startupSwitch))
        }
        send(.evaluate(.launch))
    }

    /// Calls `handler` on the main actor for each `name` posted to `center`,
    /// and keeps the observer so that ``stopForTermination()`` removes it.
    private func observe(_ name: Notification.Name, on center: NotificationCenter, handler: @escaping @MainActor @Sendable (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
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

    private func clockDidChange() {
        // Foundation caches the system time zone; times are then shown in
        // the new one.
        NSTimeZone.resetSystemTimeZone()
        send(.evaluate(.clockChanged))
    }

    private func readSystemConditions() {
        thermalState = ProcessInfo.processInfo.thermalState
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Stops monitoring and command processing, returning the controller so
    /// the caller can restore defaults without involving the main actor.
    func stopForTermination() -> ChargeController {
        isTerminating = true
        commandSink.finish()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        postWakeReread?.cancel()
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        return controller
    }

    /// Stops notifications for quitting, once the restore of macOS default
    /// charging has started: every notification not yet handed to macOS is
    /// stopped, without waiting (one being handed over at that moment may
    /// still appear).
    func stopNotificationsForTermination() {
        notifier.shutdown()
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
    /// settings reach the disk asynchronously. Not the user's change, so it
    /// never touches the Settings banner, whichever command found the
    /// change; a failed save is logged. The menu's notice shows the kept
    /// change.
    func keepManagementOffAfterOutsideChange() {
        var proposed = settings
        proposed.isManagementEnabled = false
        changeSettings(proposed, source: .adoption)
    }

    // MARK: - User intents

    func refresh() {
        send(.evaluate(.manual))
    }

    /// Validates, saves and queues a settings change; an invalid one, or one
    /// that cannot be saved, is refused and nothing is saved or applied.
    /// Only the UI's changes (`source`) touch the Settings banner: a saved
    /// one clears it, a refused one shows why, an unchanged one leaves it.
    @discardableResult
    func changeSettings(_ proposed: ChargingSettings, source: SettingsChangeSource) -> SettingsChangeResult {
        let result = commitSettings(proposed, source: source)
        settingsError = SettingsReconciliation.banner(after: result, source: source).applied(to: settingsError)
        if let message = SettingsReconciliation.logMessage(after: result, source: source) {
            CellKeeperLog.settings.notice("\(message, privacy: .public)")
        }
        return result
    }

    private func commitSettings(_ proposed: ChargingSettings, source: SettingsChangeSource) -> SettingsChangeResult {
        guard proposed != settings else { return .unchanged }
        let issues = proposed.validationIssues
        guard issues.isEmpty else { return .refused(issues.map(\.description).joined(separator: "\n")) }
        do {
            try store.save(proposed)
        } catch {
            CellKeeperLog.settings.error("Could not save settings: \(String(describing: error), privacy: .private)")
            return .refused(SettingsChangeResult.saveFailed)
        }
        let previous = settings
        settings = proposed
        send(.apply(proposed, adoptionsSeen: handledAdoptionCount, source: source))
        return .saved(previous: previous)
    }

    /// A settings change from the UI. Returns true if the resulting settings
    /// are saved (including when nothing changed).
    @discardableResult
    func updateSettings(_ change: (inout ChargingSettings) -> Void) -> Bool {
        var proposed = settings
        change(&proposed)
        if case .refused = changeSettings(proposed, source: .ui) { return false }
        return true
    }

    /// Checked against the limits offered for the backend in charge, as Set
    /// CellKeeper Limit is, so a value is refused rather than clamped.
    func setChargeLimit(_ limit: Int) {
        switch ChargeLimitRequest(limit: limit, choices: chargeLimitChoices, settings: settings) {
        case .accepted(let proposed):
            changeSettings(proposed, source: .ui)
        case .refused(let text):
            settingsError = SettingsReconciliation.banner(after: .refused(text), source: .ui).applied(to: settingsError)
        }
    }

    /// Does nothing unless the menu's button would be enabled
    /// (``FullChargeStart``).
    func startFullCharge() {
        guard let status, FullChargeStart.refusal(settings: settings, status: status) == nil else { return }
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

    /// Arms a scheduled full charge from `start` to `end`, replacing any
    /// armed one. A schedule that is not valid now is not sent, and
    /// ``scheduleError`` says why.
    func setFullChargeSchedule(start: Date, end: Date) {
        let schedule = FullChargeSchedule(startsAt: start, endsAt: end)
        let issues = schedule.issues(settingAt: Date())
        guard issues.isEmpty else {
            scheduleError = issues.map(\.description).joined(separator: " ")
            return
        }
        scheduleError = nil
        send(.setSchedule(schedule))
    }

    func cancelFullChargeSchedule() {
        scheduleError = nil
        send(.cancelSchedule)
    }

    func dismissFullChargeScheduleOutcome() {
        send(.dismissScheduleOutcome)
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

    /// Shows the steps for turning macOS's Charge Limit off in Settings ›
    /// Control; the caller opens the Settings window.
    func showMacOSLimitGuide() {
        settingsTab = .control
        isMacOSLimitGuideExpanded = true
    }

    /// Opens System Settings › Battery, or System Settings itself if the
    /// Battery pane cannot be opened. CellKeeper changes nothing there.
    func openBatterySettings() {
        if !NSWorkspace.shared.open(BatterySettingsLink.batteryPane) {
            CellKeeperLog.app.notice("Could not open the Battery pane of System Settings; opening System Settings")
            NSWorkspace.shared.openApplication(at: BatterySettingsLink.systemSettingsApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Saves the user's notification choice. Turning notifications on asks
    /// macOS for permission (macOS prompts only the first time); turning
    /// them off always works, whatever macOS allows.
    func setNotificationsEnabled(_ enabled: Bool) {
        Task { await notifier.setEnabled(enabled) }
    }

    /// Reads again what macOS allows for CellKeeper's notifications, if the
    /// user opted in. Asks the user nothing.
    func refreshNotificationPermission() {
        Task { await notifier.refreshPermission() }
    }

    /// Opens System Settings › Notifications, or System Settings itself if
    /// that pane cannot be opened. CellKeeper changes nothing there.
    func openNotificationSettings() {
        if !NSWorkspace.shared.open(NotificationSettingsLink.notificationsPane) {
            CellKeeperLog.app.notice("Could not open the Notifications pane of System Settings; opening System Settings")
            NSWorkspace.shared.openApplication(at: BatterySettingsLink.systemSettingsApp, configuration: NSWorkspace.OpenConfiguration())
        }
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
        return DiagnosticsReport.text(status: status, environment: diagnosticsEnvironment, generatedAt: Date())
    }

    /// Asks where to save the diagnostics report, then writes it there. Does
    /// nothing while another save is under way.
    ///
    /// The save panel runs no modal loop, so the menu stays usable: it is a
    /// sheet on `settingsWindow`, the window that holds the button, while
    /// that window is on screen, and a window of its own otherwise. The
    /// report is generated when the user clicks Save, so it shows the state
    /// at that moment. Only the chosen file is written, off the main actor,
    /// so a slow volume does not hold up the menu.
    func saveDiagnosticsReport(attachingTo settingsWindow: NSWindow?) {
        guard !isSavingDiagnostics, status != nil else { return }
        isSavingDiagnostics = true
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics"
        panel.message = "A plain-text report of what CellKeeper sees and does, for a bug report. It contains no serial numbers or other identifiers."
        panel.nameFieldStringValue = DiagnosticsReportFile.suggestedName(for: Date())
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        Task {
            defer { isSavingDiagnostics = false }
            let response: NSApplication.ModalResponse
            if let settingsWindow, settingsWindow.isVisible {
                response = await panel.beginSheetModal(for: settingsWindow)
            } else {
                response = await panel.begin()
            }
            guard response == .OK, let url = panel.url else { return }
            // macOS starts security-scoped access on a URL a save panel
            // returns, as if the app had called
            // startAccessingSecurityScopedResource(), and the app stops it
            // when it has finished (Apple, "Accessing files from the macOS
            // App Sandbox"). Access never stopped leaks kernel resources, and
            // enough leaks keep the app from adding locations to its sandbox
            // until it is relaunched (that method's documentation). Stopped
            // once the write has ended, whatever the outcome.
            defer { url.stopAccessingSecurityScopedResource() }
            guard let report = diagnosticsReport() else {
                // Not reachable: the button needs a status, which stays once set.
                diagnosticsSaveFailure = "CellKeeper has not finished its first check yet. Try again in a moment."
                return
            }
            do {
                try await DiagnosticsReportFile.save(report, to: url)
            } catch {
                diagnosticsSaveFailure = "\(error.localizedDescription) A file this save left there may be incomplete. You can choose another location, or use Copy Diagnostics."
            }
        }
    }

    func dismissDiagnosticsSaveFailure() {
        diagnosticsSaveFailure = nil
    }

    /// The charge limits the UI offers for the backend in charge: every
    /// whole percentage from 20 to 100, or macOS's Charge Limit steps.
    var chargeLimitChoices: ChargeLimitChoices {
        ChargeLimitChoices.offered(capabilities: status?.capabilities, isNativeChosen: backendChoice == .nativeLimit)
    }

    /// True when the backend in charge sets macOS's own Charge Limit, so the
    /// UI should offer only what that limit can express.
    var usesNativeLimit: Bool {
        chargeLimitChoices.isNativeSteps
    }

    /// The charge limits the UI should offer with the native backend.
    var nativeLimitSteps: [Int] {
        chargeLimitChoices.isNativeSteps ? chargeLimitChoices.values : NativeChargeLimitBackend.supportedLimits
    }

    // MARK: - Command queue

    private func send(_ command: Command) {
        commandSink.yield(command)
    }

    private func perform(_ command: Command) async {
        switch command {
        case .evaluate(let trigger):
            status = await controller.evaluate(trigger)
        case .apply(let newSettings, let adoptionsSeen, let source):
            let applied: SettingsReconciliation.ControllerResult
            do {
                let newStatus = try await controller.apply(settings: newSettings, adoptionsSeen: adoptionsSeen)
                status = newStatus
                applied = .applied(isManagementEnabled: newStatus.settings.isManagementEnabled, managementRefusal: newStatus.managementRefusal)
            } catch {
                applied = .rejected(String(describing: error))
            }
            // The controller keeps management off if the change was made
            // before a kept outside change was seen, or that change cannot be
            // retired: show and save what is actually in effect, unless a
            // newer change is already on its way. Only the UI's changes are
            // shown in Settings.
            let outcome = SettingsReconciliation.outcome(sent: newSettings, current: settings, controller: applied, source: source)
            if outcome.keepsManagementOff {
                settings.isManagementEnabled = false
                do {
                    try store.save(settings)
                } catch {
                    CellKeeperLog.settings.error("Could not save settings: \(String(describing: error), privacy: .private)")
                }
            }
            settingsError = outcome.banner.applied(to: settingsError)
            if let message = outcome.logMessage {
                CellKeeperLog.settings.notice("\(message, privacy: .public)")
            }
        case .startFullCharge:
            status = await controller.startFullCharge()
        case .startDischarge:
            status = await controller.startDischargeToLimit()
        case .cancelOverride:
            status = await controller.cancelOverride()
        case .setSchedule(let schedule):
            do {
                let newStatus = try await controller.setFullChargeSchedule(schedule)
                status = newStatus
                // A schedule that started in the same evaluation is no longer
                // armed, but it was set.
                let wasUsed: Bool = switch newStatus.fullChargeScheduleOutcome {
                case .started(let used)?, .alreadyFull(let used)?, .windowPassed(let used, _)?,
                     .extendedRunning(let used)?, .keptRunning(let used)?:
                    used == schedule
                case .discarded?, nil:
                    false
                }
                if newStatus.fullChargeSchedule != schedule, !wasUsed {
                    scheduleError = "The schedule could not be set; Settings › Activity says why."
                }
            } catch {
                scheduleError = "The schedule was not set: \(error)"
            }
        case .cancelSchedule:
            status = await controller.cancelFullChargeSchedule()
        case .dismissScheduleOutcome:
            status = await controller.dismissFullChargeScheduleOutcome()
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
        // Plans at once and posts later; never waits.
        if let status {
            notifier.observe(status, trigger: command.trigger)
            firstStatus.provide(true)
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

/// What Shortcuts actions use: the same commands as the menu and Settings.
extension AppModel: ShortcutsActionTarget {
    var selectedBackendIdentifier: String {
        backendChoice.backendIdentifier
    }

    /// The menu's "Charge to 100% once", already checked by the caller.
    func queueFullCharge() {
        send(.startFullCharge)
    }

    /// The menu's Cancel.
    func queueCancelOverride() {
        send(.cancelOverride)
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
