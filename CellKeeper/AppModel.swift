import AppKit
import CellKeeperCore
import CellKeeperKit
import Observation

/// The control backends selectable in this build. Real hardware backends will
/// be added here only once implemented, verified, and opt-in.
enum ControlBackendChoice: String, CaseIterable, Identifiable {
    case simulated
    case readOnly

    var id: String { rawValue }

    /// The choice matching a backend descriptor, if any.
    init?(backendIdentifier: String) {
        switch backendIdentifier {
        case MockChargingBackend().descriptor.identifier: self = .simulated
        case ReadOnlyChargingBackend().descriptor.identifier: self = .readOnly
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .simulated: "Simulated"
        case .readOnly: "Read-only"
        }
    }

    func makeBackend() -> any ChargingBackend {
        switch self {
        case .simulated: MockChargingBackend()
        case .readOnly: ReadOnlyChargingBackend()
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

    private enum Command: Sendable {
        case evaluate(EvaluationTrigger)
        case apply(ChargingSettings)
        case startFullCharge
        case startDischarge
        case cancelOverride
        case switchBackend(ControlBackendChoice)
        case resetFault
    }

    static let backendChoiceKey = "controlBackend"
    static let periodicInterval: Duration = .seconds(60)
    /// macOS reports battery estimates as invalid for 30 s after wake
    /// (`BatteryInvalidWakeSeconds`), so re-read once that has passed.
    static let postWakeRereadDelay: Duration = .seconds(35)
    nonisolated static let terminationTimeout: Duration = .seconds(3)

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let telemetry: any TelemetryProvider
    @ObservationIgnored private let controller: ChargeController
    @ObservationIgnored private let commands: AsyncStream<Command>
    @ObservationIgnored private let commandSink: AsyncStream<Command>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(store: SettingsStore = SettingsStore(), telemetry: any TelemetryProvider = SystemTelemetryProvider()) {
        let loaded = store.loadChargingSettings()
        let choice = store.string(forKey: Self.backendChoiceKey).flatMap(ControlBackendChoice.init(rawValue:)) ?? .simulated
        self.store = store
        self.telemetry = telemetry
        self.settings = loaded.settings
        self.settingsRecoveryMessage = loaded.recoveryReason
        self.backendChoice = choice
        self.controller = ChargeController(telemetry: telemetry, backend: choice.makeBackend(), settings: loaded.settings)
        (commands, commandSink) = AsyncStream.makeStream(of: Command.self)
    }

    // MARK: - Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        CellKeeperLog.app.notice("CellKeeper starting with \(self.backendChoice.rawValue, privacy: .public) backend")

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
            Task { @MainActor in
                self?.send(.evaluate(.didWake))
                try? await Task.sleep(for: Self.postWakeRereadDelay)
                self?.send(.evaluate(.didWake))
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.send(.evaluate(.willSleep)) }
        })

        send(.evaluate(.launch))
    }

    /// Stops monitoring and command processing, returning the controller so
    /// the caller can restore defaults without involving the main actor.
    func stopForTermination() -> ChargeController {
        commandSink.finish()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        return controller
    }

    /// Restores macOS default charging and shuts the controller down, so no
    /// queued command can apply a restriction afterwards. Waits at most
    /// `timeout`. Runs entirely off the main actor.
    nonisolated static func shutDown(_ controller: ChargeController, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task.detached {
                await controller.shutdown(reason: "CellKeeper is quitting")
                gate.resume()
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                gate.resume()
            }
        }
    }

    // MARK: - User intents

    func refresh() {
        send(.evaluate(.manual))
    }

    /// Validates and applies a settings change. Invalid changes are rejected
    /// with an explanation and nothing is saved or applied.
    func updateSettings(_ change: (inout ChargingSettings) -> Void) {
        var proposed = settings
        change(&proposed)
        guard proposed != settings else { return }
        let issues = proposed.validationIssues
        guard issues.isEmpty else {
            settingsError = issues.map(\.description).joined(separator: "\n")
            return
        }
        do {
            try store.save(proposed)
        } catch {
            settingsError = "Could not save settings: \(error)"
            return
        }
        settingsError = nil
        settings = proposed
        send(.apply(proposed))
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

    func selectBackend(_ choice: ControlBackendChoice) {
        guard choice != backendChoice else { return }
        backendChoice = choice
        store.set(choice.rawValue, forKey: Self.backendChoiceKey)
        send(.switchBackend(choice))
    }

    func resetBackendFault() {
        send(.resetFault)
    }

    // MARK: - Command queue

    private func send(_ command: Command) {
        commandSink.yield(command)
    }

    private func perform(_ command: Command) async {
        switch command {
        case .evaluate(let trigger):
            status = await controller.evaluate(trigger)
        case .apply(let newSettings):
            do {
                status = try await controller.apply(settings: newSettings)
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
            let newStatus = await controller.switchBackend(to: choice.makeBackend())
            status = newStatus
            // The controller refuses a switch it cannot make safely; reflect
            // the backend actually in use.
            if let actual = ControlBackendChoice(backendIdentifier: newStatus.backend.identifier), actual != backendChoice {
                backendChoice = actual
                store.set(actual.rawValue, forKey: Self.backendChoiceKey)
            }
        case .resetFault:
            status = await controller.resetBackendFault()
        }
    }

    // MARK: - Presentation

    var menuBarSymbolName: String {
        guard let status, let decision = status.decision else { return "batteryblock" }
        if status.isBackendFaulted { return "exclamationmark.triangle" }
        switch decision.state {
        case .unmanaged: return "batteryblock.slash"
        case .failSafe: return "exclamationmark.triangle"
        case .temperaturePause: return "thermometer.high"
        case .holding, .onBattery: return "batteryblock"
        case .discharging: return "minus.plus.batteryblock"
        case .charging, .fullChargeOverride, .safetyFloor: return "bolt.batteryblock"
        }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
