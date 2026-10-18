@testable import CellKeeperCore
import Foundation
import Testing

/// What notifications may contain: fixed phrases, numbers and backend names,
/// never the free-form text a status carries.
@Suite("Notification content")
struct NotificationContentTests {
    /// A path and an identifier, planted in every free-form text of a status.
    static let planted = "/Users/someone/Library/C02TESTSERIAL"

    private func status(native: Bool, availability: ControlAvailability, currentMode: ChargeControlMode?, own: ChargeControlMode?, desired: ChargeControlMode, state: PolicyState, reason: DecisionReason) -> ControllerStatus {
        let capabilities: ControlCapabilities = native
            ? .nativeLimit(availability: availability, steps: NativeChargeLimitBackend.supportedLimits)
            : {
                var capabilities = availability.acceptsRequests
                    ? ControlCapabilities(availability: availability, supportedModes: ChargeControlMode.chargingModes)
                    : .unavailable("unavailable: \(Self.planted)")
                capabilities.macOSChargeLimit = MacOSChargeLimitStatus(reportedLimit: nil, readAt: referenceDate, readProblem: Self.planted)
                return capabilities
            }()
        return ControllerStatus(
            snapshot: snapshot(percent: 80, charging: false, fullyCharged: true, temperature: 41),
            telemetryError: Self.planted,
            settings: .default,
            activeOverride: nil,
            backend: BackendDescriptor(identifier: Self.planted, displayName: "Test", summary: Self.planted),
            capabilities: capabilities,
            currentMode: currentMode,
            ownRestrictionMode: own,
            isReportedModeOwn: nil,
            nativeLimit: native ? NativeLimitStatus(reportedLimit: 80, readAt: referenceDate, readProblem: Self.planted, ownerLimit: 80, isRestoreUnfinished: true) : nil,
            adoptedChange: nil,
            adoptionCount: 0,
            managementRefusal: Self.planted,
            pendingBackend: BackendDescriptor(identifier: Self.planted, displayName: "Other backend", summary: Self.planted),
            decision: PolicyDecision(state: state, desiredMode: desired, action: .refuse(.controlUnavailable(Self.planted)), reason: reason, notes: [.dischargeUnsupported], memory: PolicyMemory(), overrideEnded: .interrupted),
            lastExecution: ExecutionRecord(date: referenceDate, action: .enableCharging, result: .failed(Self.planted)),
            consecutiveFailures: 3,
            isBackendFaulted: true,
            faultsRaised: 1,
            releasesConfirmed: 1,
            events: [ControlEvent(id: 0, date: referenceDate, kind: .safety, message: Self.planted)],
            lastEvaluation: referenceDate
        )
    }

    /// Every notification each kind of backend can produce for `status`.
    private func everyNotification(_ status: ControllerStatus) -> [PlannedNotification] {
        let override = ChargeOverride.dischargeToLimit(target: 80, at: referenceDate, uptime: 10_000)
        var all = [
            NotificationWording.limitReached(status, limit: 80, percent: 85),
            NotificationWording.temperaturePause(status),
            NotificationWording.backendFault(status),
            NotificationWording.restoreUnconfirmed(status),
        ]
        let change = AdoptedLimitChange(limit: 90, isNoLimit: false, previousOwnerLimit: 80, expectedLimit: 85, date: referenceDate)
        for resolution in [RestoreResolution.restored(limit: 80), .restored(limit: nil), .released, .keptOutsideChange(change), .keptOutsideChange(nil), .recordDiscarded] {
            all.append(NotificationWording.restoreResolved(resolution, status))
        }
        for kind in [ChargeOverride.Kind.fullCharge, .dischargeToLimit] {
            for ended in [OverrideEnd.completed, .expired, .unplugged, .interrupted] {
                all.append(NotificationWording.overrideEnded(kind, ended, override: override, status: status))
            }
        }
        return all
    }

    @Test("No path, identifier, error message, reason text or log entry reaches a notification, whatever the backend", arguments: [
        ControlAvailability.experimental, .simulated, .unavailable(reason: "unavailable /Users/someone/C02TESTSERIAL"),
    ])
    func nothingFreeForm(availability: ControlAvailability) {
        let statuses = [
            status(native: false, availability: availability, currentMode: nil, own: .inhibitCharging, desired: .normal, state: .failSafe, reason: .releaseRequired(.restoreUnfinished)),
            status(native: false, availability: availability, currentMode: .inhibitCharging, own: .inhibitCharging, desired: .inhibitCharging, state: .temperaturePause, reason: .temperatureHigh(celsius: 41, pauseAt: 40)),
            status(native: true, availability: availability, currentMode: .nativeLimit(percent: 80), own: nil, desired: .nativeLimit(percent: 80), state: .osEnforcedLimit, reason: .nativeLimitActive(limit: 80)),
            // A reason with free-form text is never quoted.
            status(native: false, availability: availability, currentMode: .inhibitCharging, own: .inhibitCharging, desired: .inhibitCharging, state: .holding, reason: .macOSChargeLimitUnknown(problem: Self.planted)),
        ]
        for status in statuses {
            for notification in everyNotification(status) {
                for text in [notification.title, notification.body] {
                    #expect(!text.contains("C02TESTSERIAL"), "\(notification.kind): \(text)")
                    #expect(!text.contains("/"), "\(notification.kind): \(text)")
                    #expect(!text.isEmpty)
                }
            }
        }
    }

    @Test("With a backend that accepts no requests, a restore warning does not say CellKeeper keeps asking")
    func unavailableRestoreWording() {
        let status = status(native: false, availability: .unavailable(reason: "test"), currentMode: nil, own: .inhibitCharging, desired: .normal, state: .failSafe, reason: .releaseRequired(.restoreUnfinished))
        let warning = NotificationWording.restoreUnconfirmed(status)
        #expect(warning.body == "CellKeeper's own restriction (a charging pause) may remain until a read-back shows it ended. Test accepts no requests right now, so CellKeeper cannot ask for its release.")
        #expect(!warning.body.contains("keeps asking"))
    }

    @Test("A native backend's notifications never call its control simulated, and a fault says it only gives back the user's own limit")
    func nativeWording() {
        let status = status(native: true, availability: .experimental, currentMode: .nativeLimit(percent: 80), own: nil, desired: .nativeLimit(percent: 80), state: .osEnforcedLimit, reason: .nativeLimitActive(limit: 80))
        for notification in everyNotification(status) {
            #expect(!notification.title.contains("Simulated"))
            #expect(!notification.body.contains("simulated"))
        }
        #expect(NotificationWording.backendFault(status) == PlannedNotification(
            kind: .backendFault,
            title: "Test backend faulted",
            body: "CellKeeper marked the backend faulted; Settings › Activity says why. Until you clear the fault in Settings › Control, CellKeeper only gives back your own Charge Limit."
        ))
    }

    @Test("Resolutions after a warning are in the past tense and say what was observed; only a read-back is called a confirmed restore")
    func resolutionWording() {
        let status = status(native: true, availability: .experimental, currentMode: .nativeLimit(percent: 85), own: nil, desired: .nativeLimit(percent: 85), state: .osEnforcedLimit, reason: .nativeLimitActive(limit: 85))
        let change = AdoptedLimitChange(limit: 100, isNoLimit: true, previousOwnerLimit: 80, expectedLimit: 85, date: referenceDate)
        #expect(NotificationWording.restoreResolved(.restored(limit: 80), status).body == "macOS reported your own Charge Limit of 80% again.")
        #expect(NotificationWording.restoreResolved(.keptOutsideChange(change), status).body == "macOS reported a Charge Limit of 100% (no limit) that CellKeeper did not set. CellKeeper kept it as your own limit, so it has nothing left to restore.")
        for resolution in [RestoreResolution.keptOutsideChange(change), .recordDiscarded] {
            let text = NotificationWording.restoreResolved(resolution, status)
            #expect(!text.title.contains("confirmed"))
            #expect(!text.body.contains("is back"))
        }
    }

    @Test("A Charge Limit of 100% reads as no limit, as in the menu")
    func limitValue() {
        #expect(NativeLimitWording.limit(80) == "80%")
        #expect(NativeLimitWording.limit(100) == "100% (no limit)")
    }

    @Test("A restore's confirmation replaces its warning in Notification Center; other kinds replace only their own")
    func replacementKeys() {
        let keys = NotificationKind.allCases.map(\.replacementKey)
        #expect(Set(keys).count == NotificationKind.allCases.count - 1)
        #expect(NotificationKind.restoreResolved.replacementKey == NotificationKind.restoreUnconfirmed.replacementKey)
    }
}
