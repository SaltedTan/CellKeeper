import AppKit
import SwiftUI

@main
struct CellKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appDelegate.model)
        } label: {
            // One image either way, with the same label: the Battery style
            // draws its percentage into the image rather than adding a Text,
            // which the status item would show as a title of its own.
            let model = appDelegate.model
            switch model.menuBarIcon {
            case .symbol(let name):
                Image(systemName: name)
                    .accessibilityLabel(model.menuBarAccessibilityLabel)
            case .battery(let battery):
                Image(nsImage: MenuBarIconImage.image(for: battery))
                    .renderingMode(.template)
                    .accessibilityLabel(model.menuBarAccessibilityLabel)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        // Only now can Shortcuts actions run: start() has queued the
        // start-up work ahead of anything they send.
        ShortcutsActionHost.coordinator.attach(model)
    }

    /// Gives the controller a bounded chance to restore macOS default charging
    /// (with macOS's Charge Limit, the user's own limit) before the app exits.
    /// If that cannot be confirmed, the user is told what to set by hand
    /// before the app quits.
    ///
    /// The restore runs off the main actor and the reply is delivered through
    /// the run loop: `.terminateLater` spins a nested run loop, and if
    /// `terminate(_:)` was called from a main-queue job, main-actor tasks could
    /// not run until it returns.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = model.stopForTermination()
        let model = model
        Task.detached {
            let outcome = await AppModel.shutDown(controller, timeout: AppModel.terminationTimeout)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    switch outcome {
                    case .unresolved(let ownerLimit):
                        Self.warnUnrestoredLimit(ownerLimit)
                    case .restored(let keptOutsideChange):
                        if keptOutsideChange {
                            model.keepManagementOffAfterOutsideChange()
                        }
                    }
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        // After the restore has started: notifications come second when
        // quitting, although stopping them never waits.
        model.stopNotificationsForTermination()
        return .terminateLater
    }

    private static func warnUnrestoredLimit(_ ownerLimit: Int?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "CellKeeper could not confirm that your own Charge Limit was restored"
        let value = ownerLimit.map { "\($0)%" } ?? "your own limit"
        alert.informativeText = "macOS's Charge Limit may still be set to CellKeeper's value. Set it to \(value) in System Settings › Battery › Charging. CellKeeper will also try again the next time it starts."
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
    }
}
